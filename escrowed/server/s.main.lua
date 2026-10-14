RZ = RZ or {}
RZ.Cleanup = {}
RZ.Sync = {}

local Store = RZ.Store
local started = false
local lastLoadHandled = {}

local function onPlayerLoaded(source)
    local now = GetGameTimer()
    if lastLoadHandled[source] and (now - lastLoadHandled[source]) < 3000 then return end
    lastLoadHandled[source] = now

    local citizenid = RZ.Fw.Identity(source)
    if not citizenid then return end
    Store.Track(source, citizenid)

    local name = (RZ.Fw.Name(source) or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if name ~= '' then
        RZ.Db.CacheCharName(citizenid, name, RZ.Now())
        RZ.Db.PrimeNameCache(citizenid, name)
    end

    SetTimeout(2000, function()
        if GetPlayerName(source) == nil then return end
        RZ.Access.Evaluate(source)
        RZ.Squads.PushState(source)
        RZ.Sync.PushWorld(source)
        RZ.LootBag.PushTo(source)
        RZ.AdminSync.PushTo(source)
    end)
end

RegisterNetEvent('QBCore:Server:OnPlayerLoaded', function()
    local src = source
    if type(src) == 'number' and src > 0 then onPlayerLoaded(src) end
end)

local function applyCombatLogCooldown(source, record, reason)
    if not (Config.Cooldown.applyOnQuitInZone and Config.Cooldown.minutes > 0) then return end

    local inFight, zoneId, why = RZ.LootBag.WasInFight(record)
    if not inFight then
        RZ.Log.Debug(('combat log: no lockout for %s — %s'):format(source, tostring(why)))
        return
    end

    if not record.citizenid then
        RZ.Log.Debug(('combat log: no lockout for %s — no citizen id on record'):format(source))
        return
    end

    RZ.Cooldowns.Apply(record.citizenid, zoneId, Config.Cooldown.minutes * 60 * 1000)
    RZ.Log.CombatLogCooldown(record.citizenid, zoneId, Config.Cooldown.minutes, reason)
end

function RZ.Cleanup.Player(source, reason)
    local record = Store.Get(source)

    if reason ~= 'character unload' then
        pcall(RZ.LootBag.OnDisconnect, source)
        pcall(applyCombatLogCooldown, source, record, reason)
    end

    RZ.Revive.CancelForReviver(source, 'reviver disconnected: ' .. reason)
    if record then
        RZ.Revive.CancelForTarget(source, 'target disconnected: ' .. reason)
        RZ.Reboot.CancelForTarget(source, 'target disconnected: ' .. reason)
    end
    RZ.Reboot.Cancel(source, 'actor disconnected: ' .. reason)

    RZ.Lock.ReleaseAllOwnedBy(source)
    RZ.Rate.Clear(source)
    RZ.AdminSessions.Destroy(source)
    lastLoadHandled[source] = nil
    Store.Untrack(source)
end

AddEventHandler('playerDropped', function(reason)
    local src = source
    if type(src) == 'number' then
        RZ.Cleanup.Player(src, tostring(reason))
    end
end)

AddEventHandler('QBCore:Server:OnPlayerUnload', function(source)
    if type(source) == 'number' then
        RZ.Cleanup.Player(source, 'character unload')
    end
end)

function RZ.Sync.PushWorld(source)
    if GetPlayerName(source) == nil then return end

    local zones = {}
    for zoneId, zone in pairs(Config.Zones) do
        if zone.enabled then
            zones[zoneId] = RZ.Schedule.IsOpen(zoneId)
        end
    end

    local record = Store.Get(source)
    local crate, crateTimer
    if record and record.zoneId then
        crate = RZ.Crate.GetPublicState(record.zoneId)
        crateTimer = RZ.Crate.GetTimerState(record.zoneId)
    end

    TriggerClientEvent(RZ.Event.SYNC_WORLD, source, {
        zones = zones,
        crate = crate or false,
        crateTimer = crateTimer,
    })
end

function RZ.Sync.PushWorldAll()
    for source in pairs(Store.All()) do
        RZ.Sync.PushWorld(source)
    end
end

function RZ.Sync.PushPeers()
    local anyInZone = false
    for _, record in pairs(Store.All()) do
        if record.zoneId then anyInZone = true break end
    end
    if not anyInZone then return end

    local byGroup = {}

    local pendingByZone = {}
    local function isClaimable(zoneId, deathId)
        local pending = pendingByZone[zoneId]
        if not pending then
            pending = {}
            local rows = RZ.Db.FetchPendingDeaths(zoneId) or {}
            for i = 1, #rows do pending[rows[i].death_id] = true end
            pendingByZone[zoneId] = pending
        end
        return pending[deathId] == true
    end

    for source, record in pairs(Store.All()) do
        if record.zoneId and record.groupId then
            local bucket = byGroup[record.groupId]
            if not bucket then
                bucket = { downed = {}, eliminated = {} }
                byGroup[record.groupId] = bucket
            end

            if record.state == RZ.State.DOWNED or record.state == RZ.State.BEING_REVIVED then
                bucket.downed[tostring(source)] = true
            elseif record.state == RZ.State.ELIMINATED and record.deathId then
                if isClaimable(record.zoneId, record.deathId) then
                    bucket.eliminated[tostring(source)] = record.deathId
                end
            end
        end
    end

    local timerByZone = {}

    for source, record in pairs(Store.All()) do
        if record.zoneId then
            local bucket = record.groupId and byGroup[record.groupId] or nil

            if timerByZone[record.zoneId] == nil then
                timerByZone[record.zoneId] = RZ.Crate.GetTimerState(record.zoneId)
            end

            TriggerClientEvent(RZ.Event.SYNC_WORLD, source, {
                downedPeers = bucket and bucket.downed or {},
                eliminatedPeers = bucket and bucket.eliminated or {},
                crateTimer = timerByZone[record.zoneId],
            })
        end
    end
end

lib.callback.register(RZ.Callback.SYNC_REQUEST, function(source)
    if not RZ.Guard(source, 'default') then return false end

    RZ.Sync.PushWorld(source)
    RZ.LootBag.PushTo(source)

    local record = Store.Get(source)
    if record then Store.Publish(record) end

    return true
end)

local function wireSchedule()
    RZ.Schedule.OnChange(function(zoneId, isOpen)
        RZ.Session.Refresh()

        if isOpen then
            RZ.Log.Info(('zone %s opened'):format(zoneId))
            RZ.Crate.Reset(zoneId)
        else
            RZ.Log.Info(('zone %s closed — evacuating'):format(zoneId))
            RZ.Revive.CancelAll('zone closed', zoneId)
            RZ.Reboot.CancelAll('zone closed', zoneId)
            RZ.Crate.Reset(zoneId)
            RZ.Access.EvacuateZone(zoneId)
        end

        RZ.Sync.PushWorldAll()
    end)

    RZ.Session.OnEnd(function(zoneId, endedSessionId)
        RZ.Squads.ClearSnapshotsForSession(endedSessionId)
        RZ.Elimination.InvalidateSessionRecords(zoneId, endedSessionId)
        RZ.AdminApply.FlushDeferred()
    end)

    RZ.Session.OnStart(function(zoneId, sessionId)
        RZ.Log.Info(('zone %s begins session %s — squad rosters will lock on first entry')
            :format(zoneId, sessionId))
    end)
end

local function wireGangUpdates()
    RZ.Gangs.RegisterUpdateHandlers(function(source)
        if source then
            if GetPlayerName(source) ~= nil then
                RZ.Access.Evaluate(source)
                RZ.Squads.PushState(source)
            end
            return
        end

        for src in pairs(Store.All()) do
            if GetPlayerName(src) ~= nil then
                RZ.Access.Evaluate(src)
            end
        end
    end)
end

local function wireRespawn()
    RZ.Medical.RegisterRespawnHandler(function(source)
        local record = Store.Get(source)
        if not record then return end

        if record.state ~= RZ.State.ELIMINATED then
            RZ.Log.LootBagSkip(source, 'respawn',
                ('state is "%s", not "eliminated" — they did not die through the RedZone knock system')
                :format(record.state))
            return
        end

        local zoneId = record.eliminationZoneId or record.zoneId
        if not zoneId then
            RZ.Log.LootBagSkip(source, 'respawn', 'no elimination zone recorded')
            return
        end

        if not Store.SetState(source, RZ.State.RESPAWN_BLOCKED, 'normal respawn after elimination') then
            RZ.Log.LootBagSkip(source, 'respawn', 'state transition to respawn_blocked was rejected')
            return
        end

        local durationMs = Config.Cooldown.minutes * 60 * 1000
        RZ.Cooldowns.Apply(record.citizenid, zoneId, durationMs)
        RZ.Log.RespawnCooldown(record.citizenid, zoneId, Config.Cooldown.minutes)
        RZ.Notify(source, 'access.cooldown', { RZ.Util.FormatDuration(durationMs) }, 'error')

        RZ.Elimination.ForfeitOnRespawn(source, zoneId)
        RZ.LootBag.OnRespawn(source)
        RZ.Knock.ClearPresentation(record)
    end)
end

local function startMaintenance()
    CreateThread(function()
        while started do
            Wait(2000)
            local ok, err = pcall(RZ.Sync.PushPeers)
            if not ok then
                RZ.Log.Integration('sync', 'PushPeers error: ' .. tostring(err))
            end
        end
    end)

    CreateThread(function()
        while started do
            RZ.Lock.Sweep()
            RZ.AdminSessions.Sweep()
            RZ.Squads.PruneInvites()
            RZ.Squads.CheckLeaderInactivity()
            RZ.Elimination.ExpireStale()
            Wait(15000)
        end
    end)

    CreateThread(function()
        while started do
            Wait(Config.Cooldown.cleanupIntervalMs)
            RZ.Cooldowns.Prune()

            if Config.Elimination.pruneAfterDays and Config.Elimination.pruneAfterDays > 0 then
                local cutoff = RZ.Now() - (Config.Elimination.pruneAfterDays * 86400 * 1000)
                local removed = RZ.Db.PruneOldDeaths(cutoff)
                if removed > 0 then
                    RZ.Log.Debug(('pruned %d old death record(s)'):format(removed))
                end
            end
        end
    end)
end

function RZ.ValidateConfig()
    local warnings = 0
    local function warn(fmt, ...)
        warnings = warnings + 1
        RZ.Log.Info('CONFIG WARNING: ' .. fmt:format(...))
    end

    for zoneId, zone in pairs(Config.Zones) do
        if zone.enabled then
            local function checkInside(label, coords)
                local p = vec3(coords.x, coords.y, coords.z)
                if not RZ.Geo.PointInPolygon(p, zone.points) then
                    local _, _, edge = RZ.Geo.NearestEdgePoint(p, zone.points)
                    warn('zone "%s": the %s is %.1fm OUTSIDE the zone edge — it cannot be used',
                        zoneId, label, edge)
                elseif zone.minZ and coords.z < zone.minZ then
                    warn('zone "%s": the %s sits %.1fm below the zone floor — it cannot be used',
                        zoneId, label, zone.minZ - coords.z)
                elseif zone.maxZ and coords.z > zone.maxZ then
                    warn('zone "%s": the %s sits %.1fm above the zone ceiling — it cannot be used',
                        zoneId, label, coords.z - zone.maxZ)
                end
            end

            checkInside('crate', zone.crate.coords)
            checkInside('seller', zone.seller.coords)

            for i, station in ipairs(zone.rebootStations) do
                checkInside(('reboot station #%d'):format(i), station.propCoords)
                checkInside(('reboot station #%d spawn'):format(i), station.playerSpawn)

                if Config.Reboot.maxDistance <= station.interactionDistance then
                    warn('reboot station #%d in "%s": Config.Reboot.maxDistance (%.1f) must be GREATER than interactionDistance (%.1f), or every reboot cancels immediately',
                        i, zoneId, Config.Reboot.maxDistance, station.interactionDistance)
                end

                local spawnGap = RZ.Geo.Dist2D(
                    vec3(station.playerSpawn.x, station.playerSpawn.y, station.playerSpawn.z),
                    vec3(station.propCoords.x, station.propCoords.y, station.propCoords.z))
                if spawnGap < 2.0 then
                    warn('reboot station #%d in "%s": playerSpawn is only %.2fm from propCoords — the rebooted player will likely spawn inside the prop. Stand clear of it and re-capture with /redzone_here',
                        i, zoneId, spawnGap)
                end

                if station.useExistingProp then
                    RZ.Log.Info(('reboot station #%d in "%s" attaches to the EXISTING map prop "%s" — nothing is spawned.')
                        :format(i, zoneId, tostring(station.prop)))
                end
            end
        end
    end

    local payload = RZ.Knock.BuildDownedPayload(Config.Knock.durationMs)
    if type(payload.crawl) ~= 'table' or type(payload.crawl.dict) ~= 'string' then
        warn('Config.Knock.crawl is missing or malformed — downed players will not be able to crawl')
    end
    if type(payload.crawlClipsets) ~= 'table' or #payload.crawlClipsets == 0 then
        warn('Config.Knock.crawlClipsets is empty — there is no fallback if the crawl dictionary fails to load')
    end
    if type(payload.crawlSpeed) ~= 'number' or payload.crawlSpeed <= 0 then
        warn('Config.Knock.crawlSpeed is missing or <= 0 — downed players would be unable to move')
    end

    for _, mat in ipairs(Config.Rewards.materials) do
        if RZ.Inv.ItemExists(mat.item) == false then
            warn('reward material "%s" does not exist in your inventory', mat.item)
        end
    end
    for _, item in pairs(Config.Items) do
        if RZ.Inv.ItemExists(item) == false then
            warn('item "%s" does not exist in your inventory — add it (see install/items.md)', item)
        end
    end

    if next(Config.Zones or {}) == nil then
        RZ.Log.Info('no zones exist yet. Draw one in-game with /redzonecreate.')
    end

    if warnings == 0 then
        RZ.Log.Info('config validated: no problems found.')
    else
        RZ.Log.Info(('config validated: %d warning(s) above.'):format(warnings))
    end
end

local function boot()
    if started then return end

    RZ.Log.Info('pr — REDZONE starting...')

    if not RZ.Db.EnsureSchema() then
        RZ.Log.Info('FATAL: database schema could not be created. The resource will not start.')
        return
    end

    started = true

    if RZ.Db.EnsureAdminSchema() then
        RZ.AdminStore.CaptureDefaults()
        local okStore, errStore = pcall(RZ.AdminStore.Load)
        if not okStore then
            RZ.Log.Integration('adminstore', 'load failed, using defaults: ' .. tostring(errStore))
            RZ.AdminStore.RebuildConfig({})
        end
    else
        RZ.Log.Integration('adminstore', 'admin tables unavailable — running on config defaults')
        RZ.AdminStore.CaptureDefaults()
        RZ.AdminStore.RebuildConfig({})
    end

    RZ.AdminAuth.ReportConfiguration()

    RZ.Schedule.Start()
    RZ.Session.Prime()

    RZ.Squads.LoadAll()
    RZ.Squads.PruneStaleSnapshots()
    RZ.Cooldowns.LoadAll()
    RZ.Elimination.ReconcilePending()

    local okValidate, errValidate = pcall(RZ.ValidateConfig)
    if not okValidate then
        RZ.Log.Integration('config', 'validation error: ' .. tostring(errValidate))
    end

    wireSchedule()
    wireGangUpdates()
    wireRespawn()

    RZ.Access.StartValidationLoop()
    RZ.Knock.StartTimerLoop()
    RZ.Revive.StartWatchdog()
    RZ.Reboot.StartWatchdog()
    RZ.Crate.StartLoop()
    RZ.LootBag.StartExpiryLoop()
    startMaintenance()

    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        if src then onPlayerLoaded(src) end
    end

    RZ.Log.Info('ready.')
end

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= RZ.RESOURCE then return end
    SetTimeout(1500, boot)
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= RZ.RESOURCE then return end

    started = false

    RZ.Access.StopValidationLoop()
    RZ.Knock.StopTimerLoop()
    RZ.Revive.StopWatchdog()
    RZ.Reboot.StopWatchdog()
    RZ.Crate.StopLoop()
    RZ.LootBag.StopExpiryLoop()

    RZ.LootBag.RemoveAll()

    RZ.Revive.CancelAll('resource stopping')
    RZ.Reboot.CancelAll('resource stopping')

    for source, record in pairs(Store.All()) do
        if record.state == RZ.State.DOWNED or record.state == RZ.State.BEING_REVIVED then
            RZ.Medical.ExitRedZoneDowned(source)
            RZ.Medical.ClearDeathState(source)
        end
        TriggerClientEvent(RZ.Event.RESTORE, source, { health = Config.Revive.revivedHealth })
        TriggerClientEvent(RZ.Event.SET_DOWNED, source, false)
    end

    RZ.AdminSessions.DestroyAll()
    RZ.AdminApply.ClearZoneOverrides()

    RZ.Lock.ReleaseAll()
    Store.Clear()

    RZ.Log.Info('stopped cleanly.')
end)

if Config.Debug then
    local function reply(source, message)
        if source == 0 then
            print(message)
        else
            TriggerClientEvent('chat:addMessage', source, { args = { '[redzone]', message } })
        end
    end

    local function isAdmin(source)
        if source == 0 then return true end
        if IsPlayerAceAllowed(source, Config.AdminAce) then return true end

        for _, group in ipairs({ 'admin', 'god' }) do
            local ok, has = pcall(RZ.Fw.HasPermission, source, group)
            if ok and has then return true end
        end

        return false
    end

    local function requireAdmin(source, command)
        if isAdmin(source) then return true end

        reply(source, ('permission denied for /%s.'):format(command))
        reply(source, ('add this to server.cfg then restart:  add_ace group.admin %s allow')
            :format(Config.AdminAce))
        RZ.Log.Suspicious(source, command, 'missing ace permission')
        return false
    end

    lib.addCommand('redzone_timetest', {
        help = 'Run the clock and schedule self-test',
        restricted = false,
    }, function(source)
        if not requireAdmin(source, 'redzone_timetest') then return end

        local results, failures = RZ.Schedule.SelfTest()
        reply(source, ('running %d schedule and clock assertions...'):format(#results))
        for _, r in ipairs(results) do
            reply(source, ('  [%s] %s — %s'):format(r.ok and 'PASS' or 'FAIL', r.name, r.detail))
        end
        reply(source, failures == 0
            and ('ALL %d ASSERTIONS PASSED'):format(#results)
            or ('%d ASSERTION(S) FAILED'):format(failures))

        local clock = RZ.Schedule.GetClock()
        reply(source, ('current server time: %04d-%02d-%02d %02d:%02d:%02d (%s)')
            :format(clock.year, clock.month, clock.day, clock.hour, clock.min, clock.sec,
                RZ.Time.OffsetLabel(clock.offset)))

        for zoneId in pairs(Config.Zones) do
            local zc = RZ.Schedule.GetClock(zoneId)
            reply(source, ('  zone "%s": %02d:%02d (%s)')
                :format(zoneId, zc.hour, zc.min, RZ.Time.OffsetLabel(zc.offset)))
        end
    end)

    lib.addCommand('redzone_status', {
        help = 'Print live RedZone state for every zone',
        restricted = false,
    }, function(source)
        if not requireAdmin(source, 'redzone_status') then return end

        for zoneId, zone in pairs(Config.Zones) do
            if zone.enabled then
                local open = RZ.Schedule.IsOpen(zoneId)
                local sessionId = RZ.Session.GetId(zoneId)
                local crate = RZ.Crate.Debug(zoneId)
                local secs = RZ.Schedule.SecondsUntilChange(zoneId)

                reply(source, ('zone %s: %s | session %s | next change in %s')
                    :format(zoneId, open and 'OPEN' or 'CLOSED', tostring(sessionId),
                        RZ.Util.FormatDuration(secs * 1000)))
                reply(source, ('  crate: %s | next in %s | alive groups: %d')
                    :format(crate.active and 'ACTIVE' or 'pending',
                        RZ.Util.FormatDuration(crate.remainingMs), crate.groupCount))

                for _, groupId in ipairs(crate.groups) do
                    reply(source, ('    %s -> %d alive'):format(groupId, crate.countsByGroup[groupId]))
                end
            end
        end

        local tracked = 0
        for _ in pairs(Store.All()) do tracked = tracked + 1 end
        reply(source, ('tracked players: %d'):format(tracked))

        if source ~= 0 then
            local record = Store.Get(source)
            if not record then
                reply(source, 'YOU: not tracked — is your character fully loaded?')
                return
            end

            reply(source, ('YOU: state=%s zone=%s group=%s gang=%s')
                :format(record.state, tostring(record.zoneId), tostring(record.groupId),
                    tostring(record.gangId)))

            local coords = RZ.Access.CoordsOf(source)
            if coords then
                local here = RZ.Access.ResolveZone(coords)
                reply(source, ('YOU: standing in zone %s, health %d')
                    :format(tostring(here), RZ.Medical.GetHealth(source)))

                if here then
                    local ok, reason = RZ.Access.CheckEligibility(source, here)
                    reply(source, ('YOU: eligible=%s%s')
                        :format(tostring(ok), ok and '' or (' reason=' .. tostring(reason))))
                else
                    reply(source, 'YOU: you are NOT inside any RedZone — walk to the centre first')
                end
            end

            local blocked, jobName = RZ.Access.HasBlockedJob(source)
            if blocked then
                reply(source, ('YOU: BLOCKED because your job is "%s"'):format(tostring(jobName)))
            end

            reply(source, ('YOU: knock threshold=%d downedHealth=%d — take damage below the threshold to be downed')
                :format(Config.Knock.lethalThreshold, Config.Knock.downedHealth))
        end
    end)

    lib.addCommand('redzone_here', {
        help = 'Print your current coordinates in config format',
        restricted = false,
    }, function(source)
        if not requireAdmin(source, 'redzone_here') then return end

        if source == 0 then
            reply(source, 'run this in-game, not from the console')
            return
        end

        local ped = GetPlayerPed(source)
        if not ped or ped == 0 then
            reply(source, 'could not read your ped')
            return
        end

        local c = GetEntityCoords(ped)
        local h = GetEntityHeading(ped)

        reply(source, ('vec3(%.2f, %.2f, %.2f)'):format(c.x, c.y, c.z))
        reply(source, ('vec4(%.2f, %.2f, %.2f, %.2f)'):format(c.x, c.y, c.z, h))

        local zoneId = RZ.Access.ResolveZone(c)
        if zoneId then
            local zone = Config.Zones[zoneId]
            local _, _, edge = RZ.Geo.NearestEdgePoint(c, zone.points)
            reply(source, ('inside zone "%s" — %.1fm from the nearest edge'):format(zoneId, edge))
        else
            local nearest, nearestDist
            for id, zone in pairs(Config.Zones) do
                if zone.enabled and type(zone.points) == 'table' and #zone.points >= 3 then
                    local _, _, d = RZ.Geo.NearestEdgePoint(c, zone.points)
                    if not nearestDist or d < nearestDist then
                        nearest, nearestDist = id, d
                    end
                end
            end
            if nearest then
                reply(source, ('OUTSIDE every zone — %.1fm from the edge of "%s"')
                    :format(nearestDist, nearest))
            end
        end
    end)

    lib.addCommand('redzone_testbag', {
        help = 'Drop your own hotbar as a loot bag (diagnostic)',
        restricted = false,
    }, function(source)
        if not requireAdmin(source, 'redzone_testbag') then return end

        local record = Store.Get(source)
        if not record then
            reply(source, 'you are not tracked — is your character loaded?')
            return
        end

        local zoneId = record.zoneId or record.eliminationZoneId
        reply(source, ('zone=%s  open=%s  state=%s')
            :format(tostring(zoneId), tostring(zoneId and RZ.Schedule.IsOpen(zoneId)), record.state))

        local coords = RZ.Access.CoordsOf(source)
        if not coords then
            reply(source, 'could not read your position')
            return
        end

        local dropId = RZ.LootBag.Drop(source, coords, zoneId, 'admin test')
        if dropId then
            reply(source, ('bag created (%s) — check the ground at your feet'):format(dropId))
        else
            reply(source, 'no bag was created. The reason is in the server console, tagged LootBagSkipped.')
        end
    end)

    lib.addCommand('redzone_clearcooldown', {
        help = 'Clear a player\'s RedZone lockout',
        restricted = false,
        params = {
            { name = 'id', help = 'player server id', type = 'playerId' },
        },
    }, function(source, args)
        if not requireAdmin(source, 'redzone_clearcooldown') then return end

        local target = tonumber(args.id)
        local record = target and Store.Get(target)
        if not record then
            reply(source, 'that player is not tracked')
            return
        end

        for zoneId, zone in pairs(Config.Zones) do
            if zone.enabled then
                RZ.Cooldowns.Clear(record.citizenid, zoneId)
            end
        end
        reply(source, ('cleared cooldowns for %s'):format(record.name))
    end)
end

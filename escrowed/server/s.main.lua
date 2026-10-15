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
        RZ.Access.RefreshVisibility(source, true)
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

-- =============================================================================
--  Combat log: a quit or a fake crash costs the bag; a genuine game crash does not.
--
--  Every client-side leave reaches the server as category CLIENT with a reason string
--  the client wrote, so the text is all there is to go on. What makes it workable:
--    - F8 `quit`, Alt+F4 and closing the game always send "Exiting".
--    - F8 `quit "anything"` is forced by FiveM (since April 2024) to send
--      "Quit: anything", so typing `quit "Game crashed: ..."` arrives as
--      "Quit: Game crashed: ..." and can never pass for a real crash.
--    - A real crash is reported by FiveM's own crash handler and STARTS with
--      "Game crashed: " in the player's game language.
--    - Killing the game or pulling the network sends nothing at all: the server drops
--      the player ~30s later as a timeout, a category of its own the client cannot fake.
--  A modified client can still forge a crash message, so genuine-looking crashes in a
--  fight are forgiven only a few times per player per day.
-- =============================================================================

RZ.CombatLog = {}
local CombatLog = RZ.CombatLog

-- playerDropped's third argument on FXServer 9423+ (Aug 2024). nil on older servers.
local DROP = {
    RESOURCE = 1, CLIENT = 2, SERVER = 3, CLIENT_REPLACED = 4,
    TIMED_OUT = 5, TIMED_OUT_PENDING = 6, SERVER_SHUTDOWN = 7,
    STATE_BAG_RATE_LIMIT = 8, NET_EVENT_RATE_LIMIT = 9, LATENT_NET_EVENT_RATE_LIMIT = 10,
    COMMAND_RATE_LIMIT = 11, ONESYNC_MISSED_FRAMES = 12, NET_GAME_EVENT_RATE_LIMIT = 13,
}

local SERVER_SIDE = {
    [DROP.RESOURCE] = true, [DROP.SERVER] = true, [DROP.SERVER_SHUTDOWN] = true,
}

-- Dropped for flooding the server. The flood comes from the client itself, so these are not
-- forgiven freely: command spam is something F8 alone can do, so it counts as a quit; the
-- rest could be a buggy resource, so they count against the crash allowance like an error.
local CLIENT_FLOOD = {
    [DROP.STATE_BAG_RATE_LIMIT] = 'error', [DROP.NET_EVENT_RATE_LIMIT] = 'error',
    [DROP.LATENT_NET_EVENT_RATE_LIMIT] = 'error', [DROP.COMMAND_RATE_LIMIT] = 'quit',
    [DROP.NET_GAME_EVENT_RATE_LIMIT] = 'error',
}

-- "Game crashed: " as FiveM's crash handler writes it in every client language that has
-- a translation; the rest fall back to English. Matched at the very start only.
local CRASH_PREFIXES = {
    'Game crashed: ', 'Spielabsturz: ', 'El juego crasheó: ', 'Le jeu a cessé de fonctionner : ',
    'Il gioco ha smesso di funzionare: ', 'O jogo crashou: ', 'Spel werkt niet meer: ',
    'Игра вылетела: ', 'Oyun çöktü: ', 'Spelet kraschade: ', 'Spillet krasjet: ',
    'A játék összeomlott: ', 'Pád hry: ', '게임 충돌: ', '游戏发生崩溃： ', '遊戲已崩潰: ',
    'تعطلت العبة: ',
}

-- Reasons a vanilla client sends when the player chose to leave.
local VOLUNTARY = {
    ['Exiting'] = true, ['Disconnected.'] = true, ['Dropped.'] = true,
    ['Connecting to another server.'] = true, ['Reloading game.'] = true,
    ['Entering Rockstar Editor'] = true,
}

local function startsWith(text, prefix)
    return text:sub(1, #prefix) == prefix
end

local function crashCfg()
    return Config.LootBag.crashCheck or {}
end

-- What kind of leave this was. Returns kind, detail, where kind is one of:
--   'quit' 'fake_crash' 'timeout'           -> punished (timeouts unless switched off)
--   'crash' 'error'                          -> spared, within the crash allowance
--   'freeze' 'congestion' 'server'           -> spared
function CombatLog.Kind(reason, category)
    local text = type(reason) == 'string' and reason:gsub('^%s+', ''):gsub('%s+$', '') or ''
    local cat = tonumber(category)

    if cat and CLIENT_FLOOD[cat] then return CLIENT_FLOOD[cat], 'dropped for flooding the server' end
    if cat and SERVER_SIDE[cat] then return 'server', 'removed by the server or a resource' end
    if cat == DROP.TIMED_OUT_PENDING then return 'congestion', 'server-side network congestion' end
    if cat == DROP.ONESYNC_MISSED_FRAMES then return 'freeze', 'the game stopped responding' end
    if cat == DROP.TIMED_OUT or cat == DROP.CLIENT_REPLACED then
        return 'timeout', 'game killed or network cut (no crash report was sent)'
    end

    if not cat then
        -- An older server sends no category, so read the server-written texts instead.
        -- A vanilla client cannot produce these: its own quit text starts with "Quit: ".
        if startsWith(text, 'Server shutting down') then return 'server', 'server shutting down' end
        if startsWith(text, 'Server->client connection timed out. Pending commands') then
            return 'congestion', 'server-side network congestion'
        end
        if startsWith(text, 'Server->client connection timed out') or text == 'Reconnecting' then
            return 'timeout', 'game killed or network cut (no crash report was sent)'
        end
        if startsWith(text, 'Timed out after 60 seconds') then return 'freeze', 'the game stopped responding' end
    end

    if startsWith(text, 'Quit:') then
        local body = text:sub(6):gsub('^%s+', '')
        for i = 1, #CRASH_PREFIXES do
            if startsWith(body, CRASH_PREFIXES[i]) then return 'fake_crash', 'typed a crash message into F8 quit' end
        end
        local rest = body:lower()
        if rest:find('crash', 1, true) or rest:find('timed out', 1, true) then
            return 'fake_crash', 'typed a crash message into F8 quit'
        end
        return 'quit', 'F8 quit with a custom message'
    end

    for i = 1, #CRASH_PREFIXES do
        if startsWith(text, CRASH_PREFIXES[i]) then return 'crash', 'game crash reported by FiveM' end
    end

    if VOLUNTARY[text] or text == '' then return 'quit', 'left the game (F8 quit, Alt+F4, closed the game)' end

    -- Any other text from the client: a non-fatal game error, or a modified client.
    return 'error', 'game error'
end

-- A forged crash message from a modified client looks exactly like a real one, so only so
-- many crashes in a fight are forgiven per player before they count as combat logs. Kept
-- in resource KVP so it survives restarts, and read without yielding.
local function crashAllowed(citizenid)
    local cfg = crashCfg()
    local allowance = tonumber(cfg.crashAllowance) or 2
    if allowance <= 0 then return false end
    if not citizenid then return true end

    local key = 'rz_crashes:' .. citizenid
    local windowMs = (tonumber(cfg.crashWindowHours) or 24) * 3600000
    local now = RZ.Now()
    local kept = {}
    local ok, stored = pcall(json.decode, GetResourceKvpString(key) or '[]')
    if ok and type(stored) == 'table' then
        for i = 1, #stored do
            local at = tonumber(stored[i])
            if at and now - at < windowMs then kept[#kept + 1] = at end
        end
    end

    local allowed = #kept < allowance
    kept[#kept + 1] = now
    SetResourceKvp(key, json.encode(kept))
    return allowed
end

-- punish (bool), kind, why
function CombatLog.Judge(source, record, reason, category)
    local kind, why = CombatLog.Kind(reason, category)
    local cfg = crashCfg()

    if cfg.enabled == false then return true, kind, 'crash check disabled: every leave counts' end

    if kind == 'quit' or kind == 'fake_crash' then return true, kind, why end
    if kind == 'timeout' then return cfg.punishTimeouts ~= false, kind, why end
    if kind == 'freeze' then return cfg.punishFreezes == true, kind, why end
    if kind == 'crash' or kind == 'error' then
        if not RZ.LootBag.WasInFight(record) then return false, kind, why end
        if crashAllowed(record and record.citizenid) then return false, kind, why end
        return true, 'repeat_crash', ('more than %d crash(es) mid-fight in %dh')
            :format(tonumber(cfg.crashAllowance) or 2, tonumber(cfg.crashWindowHours) or 24)
    end
    return false, kind, why
end

function RZ.Cleanup.Player(source, reason, category)
    local record = Store.Get(source)
    if record then
        -- The first cleanup can pause on the cooldown write; the validation loop may notice
        -- the player is gone meanwhile and call in again. Judge and clean up once.
        if record.cleaningUp then return end
        record.cleaningUp = true
    end

    if reason ~= 'character unload' then
        -- Everything up to the bag must run without yielding: ox_inventory unloads the
        -- player's inventory in its own playerDropped handler, and any wait here lets it.
        local punish, verdict, why = true, 'quit', nil
        if record then punish, verdict, why = CombatLog.Judge(source, record, reason, category) end
        if punish then
            pcall(RZ.LootBag.OnDisconnect, source, verdict)
            pcall(applyCombatLogCooldown, source, record, reason)
        elseif record and RZ.LootBag.WasInFight(record) then
            RZ.Log.LootBagSkip(source, 'disconnect', ('%s — kept their items (%s)'):format(verdict, why))
        end
        if record and verdict ~= 'quit' and RZ.LootBag.WasInFight(record) then
            RZ.Log.Debug(('combat log: %s left as "%s": %s (reason: %s)')
                :format(RZ.Log.Who(source), verdict, tostring(why), tostring(reason)))
        end
    end

    RZ.Lock.ReleaseAllOwnedBy(source)
    RZ.Rate.Clear(source)
    RZ.Gangs.Forget(source)
    RZ.AdminSessions.Destroy(source)
    lastLoadHandled[source] = nil
    Store.Untrack(source)
end

AddEventHandler('playerDropped', function(reason, _resourceName, clientDropReason)
    local src = source
    if type(src) == 'number' then
        RZ.Cleanup.Player(src, tostring(reason), clientDropReason)
    end
end)

AddEventHandler('QBCore:Server:OnPlayerUnload', function(source)
    if type(source) ~= 'number' then return end
    -- qb-core also fires this from inside its own playerDropped handler. Waiting a moment
    -- lets a real disconnect be judged by playerDropped, with its reason, instead of being
    -- mistaken for a character switch that quietly untracks the player first.
    SetTimeout(500, function()
        if GetPlayerName(source) == nil then return end
        RZ.Cleanup.Player(source, 'character unload')
    end)
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
        canSee = record ~= nil and record.canSee == true,
    })
end

function RZ.Sync.PushWorldAll()
    for source in pairs(Store.All()) do
        RZ.Sync.PushWorld(source)
    end
end

-- The crate countdown, pushed to everyone in a zone every couple of seconds.
function RZ.Sync.PushCrateTimers()
    local timerByZone = {}

    for source, record in pairs(Store.All()) do
        local zoneId = record.zoneId
        if zoneId then
            if timerByZone[zoneId] == nil then
                timerByZone[zoneId] = RZ.Crate.GetTimerState(zoneId)
            end
            TriggerClientEvent(RZ.Event.SYNC_WORLD, source, { crateTimer = timerByZone[zoneId] })
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
            RZ.Crate.Reset(zoneId)
            RZ.Access.EvacuateZone(zoneId)
        end

        RZ.Sync.PushWorldAll()
    end)

    RZ.Session.OnEnd(function(_zoneId, endedSessionId)
        -- Session ids are dates, so two zones open the same night share one. Only drop the
        -- squad roster locks once no zone is still running that night.
        if not RZ.Session.IsLiveAnywhere(endedSessionId) then
            RZ.Squads.ClearSnapshotsForSession(endedSessionId)
        end
        if RZ.AdminApply.QueueDue() then RZ.AdminApply.FlushDeferred() end
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
                RZ.Access.RefreshVisibility(source, true)
                RZ.Squads.PushState(source)
            end
            return
        end

        for src in pairs(Store.All()) do
            if GetPlayerName(src) ~= nil then
                RZ.Access.Evaluate(src)
                RZ.Access.RefreshVisibility(src, true)
            end
        end
    end)
end

function RZ.Cleanup.Respawned(source, via)
    local record = Store.Get(source)
    if not record or record.state ~= RZ.State.ELIMINATED then return end

    local zoneId = record.eliminationZoneId or record.zoneId
    if not zoneId then
        Store.ForceState(source, RZ.State.OUTSIDE, 'respawned with no elimination zone')
        RZ.Elimination.Clear(record)
        return
    end

    if not Store.SetState(source, RZ.State.RESPAWN_BLOCKED, via or 'normal respawn after elimination') then
        RZ.Log.LootBagSkip(source, 'respawn', 'state transition to respawn_blocked was rejected')
        return
    end

    local minutes = Config.Cooldown.minutes or 0
    if minutes > 0 then
        local durationMs = minutes * 60 * 1000
        RZ.Cooldowns.Apply(record.citizenid, zoneId, durationMs)
        RZ.Log.RespawnCooldown(record.citizenid, zoneId, minutes)
        RZ.Notify(source, 'access.cooldown', { RZ.Util.FormatDuration(durationMs) }, 'error')
    end

    RZ.LootBag.OnRespawn(source)
    RZ.Elimination.Clear(record)
end

local function wireRespawn()
    RZ.Medical.RegisterRespawnHandler(function(source)
        RZ.Cleanup.Respawned(source, 'normal respawn after elimination')
    end)
end

local function startMaintenance()
    CreateThread(function()
        while started do
            Wait(2000)
            local ok, err = pcall(RZ.Sync.PushCrateTimers)
            if not ok then
                RZ.Log.Integration('sync', 'PushCrateTimers error: ' .. tostring(err))
            end
        end
    end)

    CreateThread(function()
        while started do
            RZ.Lock.Sweep()
            RZ.AdminSessions.Sweep()
            RZ.Squads.PruneInvites()
            RZ.Squads.CheckLeaderInactivity()
            Wait(15000)
        end
    end)

    CreateThread(function()
        while started do
            Wait(Config.Cooldown.cleanupIntervalMs)
            RZ.Cooldowns.Prune()
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
        end
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
    RZ.AdminApply.PrimeKnownZones()
    RZ.Gangs.Detect()

    RZ.Schedule.Start()
    RZ.Session.Prime()

    RZ.Squads.LoadAll()
    RZ.Squads.PruneStaleSnapshots()
    RZ.Cooldowns.LoadAll()

    local okValidate, errValidate = pcall(RZ.ValidateConfig)
    if not okValidate then
        RZ.Log.Integration('config', 'validation error: ' .. tostring(errValidate))
    end

    wireSchedule()
    wireGangUpdates()
    wireRespawn()

    RZ.Access.StartValidationLoop()
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
    RZ.Crate.StopLoop()
    RZ.LootBag.StopExpiryLoop()

    RZ.LootBag.RemoveAll()

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

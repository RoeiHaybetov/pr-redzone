RZ = RZ or {}
RZ.Knock = {}
RZ.Revive = {}
RZ.Elimination = {}
RZ.Reboot = {}

local Knock = RZ.Knock
local Revive = RZ.Revive
local Elim = RZ.Elimination
local Reboot = RZ.Reboot
local Store = RZ.Store

local GRACE_MS = 2500

local function lockName(prefix, id)
    return prefix .. tostring(id)
end

local function deny(source, key)
    RZ.Notify(source, key, nil, 'error')
    return false
end

local function reject(source, action, detail)
    RZ.Log.Suspicious(source, action, detail)
    return false
end

local function buildDownedPayload(remainingMs)
    return {
        durationMs        = Config.Knock.durationMs,
        remainingMs       = remainingMs,
        crawl             = Config.Knock.crawl,
        crawlClipsets     = Config.Knock.crawlClipsets,
        crawlSpeed        = Config.Knock.crawlSpeed,
        downedHealth      = Config.Knock.downedHealth,
        immuneWhileDowned = Config.Knock.immuneWhileDowned and true or false,
        finishThreshold   = Config.Knock.finishThreshold or 5,
    }
end

Knock.BuildDownedPayload = buildDownedPayload

function Knock.EnterDowned(source, zoneId, cause)
    local record = Store.Get(source)
    if not record then return false end
    if record.state ~= RZ.State.ALIVE then return false end
    if not RZ.Schedule.IsOpen(zoneId) then return false end
    if record.zoneId ~= zoneId then return false end
    if not record.groupId then return false end
    if not Store.SetState(source, RZ.State.DOWNED, cause) then return false end

    record.knockRemainingMs = Config.Knock.durationMs
    record.knockDeadline = RZ.Mono() + Config.Knock.durationMs
    record.reviverSrc = nil
    RZ.Medical.EnterRedZoneDowned(source)
    TriggerClientEvent(RZ.Event.SET_DOWNED, source, true, buildDownedPayload(record.knockRemainingMs))
    Store.Publish(record)
    RZ.Log.Downed(source, zoneId)
    RZ.Notify(source, 'knock.downed', { RZ.Util.FormatDuration(Config.Knock.durationMs) }, 'error')
    return true
end

function Knock.PauseTimer(source)
    local record = Store.Get(source)
    if not record or not record.knockDeadline then return nil end

    local remaining = record.knockDeadline - RZ.Mono()
    if remaining < 0 then remaining = 0 end
    record.knockRemainingMs = remaining
    record.knockDeadline = nil
    Store.Publish(record)
    return remaining
end

function Knock.ResumeTimer(source)
    local record = Store.Get(source)
    if not record or record.knockDeadline then return end

    local remaining = record.knockRemainingMs or 0
    record.knockDeadline = RZ.Mono() + remaining
    Store.Publish(record)
    TriggerClientEvent(RZ.Event.SET_DOWNED, source, true, buildDownedPayload(remaining))
end

function Knock.GetRemaining(source)
    local record = Store.Get(source)
    if not record then return 0 end
    if not record.knockDeadline then return record.knockRemainingMs or 0 end

    local remaining = record.knockDeadline - RZ.Mono()
    return remaining > 0 and remaining or 0
end

function Knock.BeginHealthGrace(record)
    if not record then return end
    record.healthGraceUntil = RZ.Mono() + GRACE_MS
end

local function inHealthGrace(record, health)
    local graceUntil = record.healthGraceUntil
    if not graceUntil then return false end
    if health <= 0 or health > Config.Knock.lethalThreshold or RZ.Mono() >= graceUntil then
        record.healthGraceUntil = nil
        return false
    end
    return true
end

local function clearDownedPresentation(record)
    record.knockRemainingMs = nil
    record.knockDeadline = nil
    record.reviverSrc = nil
    TriggerClientEvent(RZ.Event.SET_DOWNED, record.src, false)
    Store.Publish(record)
end

Knock.ClearPresentation = clearDownedPresentation

function Knock.RestoreToAlive(source, health)
    local record = Store.Get(source)
    if not record then return false end

    Knock.BeginHealthGrace(record)
    if not Store.SetState(source, RZ.State.ALIVE, 'revived') then
        record.healthGraceUntil = nil
        return false
    end

    TriggerClientEvent(RZ.Event.RESTORE, source, { health = health })
    clearDownedPresentation(record)
    RZ.Medical.ExitRedZoneDowned(source)
    RZ.Medical.ClearDeathState(source)
    RZ.LootBag.ClearSnapshot(source)
    Store.Publish(record)
    return true
end

function Knock.ReleaseForIneligibility(source, reason)
    local record = Store.Get(source)
    if not record then return end

    if record.state == RZ.State.DOWNED or record.state == RZ.State.BEING_REVIVED then
        Revive.CancelForTarget(source, reason)
        clearDownedPresentation(record)
        RZ.Medical.ExitRedZoneDowned(source)
        RZ.Medical.ClearDeathState(source)
        TriggerClientEvent(RZ.Event.RESTORE, source, { health = Config.Revive.revivedHealth })
        Store.ForceState(source, RZ.State.OUTSIDE, 'released: ' .. reason)
    elseif record.state == RZ.State.BEING_REBOOTED then
        Reboot.CancelForTarget(source, reason)
    end
end

local loopRunning = false

function Knock.StartTimerLoop()
    if loopRunning then return end
    loopRunning = true

    CreateThread(function()
        while loopRunning do
            local now = RZ.Mono()
            for source, record in pairs(Store.All()) do
                if record.state == RZ.State.DOWNED and record.knockDeadline then
                    if now >= record.knockDeadline then
                        local ok, err = pcall(Elim.Eliminate, source, 'knock timer expired')
                        if not ok then
                            RZ.Log.Integration('knock', ('elimination of %s failed: %s'):format(source, tostring(err)))
                        end
                    end
                elseif record.state == RZ.State.BEING_REVIVED and record.knockRemainingMs == 0 then
                    Revive.CancelForTarget(source, 'timer exhausted')
                    local ok = pcall(Elim.Eliminate, source, 'knock timer expired during revive')
                    if not ok then
                        RZ.Log.Integration('knock', ('elimination during revive failed for %s'):format(source))
                    end
                end
            end
            Wait(250)
        end
    end)
end

function Knock.StopTimerLoop()
    loopRunning = false
end

function Knock.ServerHealthWatch(source, record, zoneId)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return end

    local health = GetEntityHealth(ped)
    local deathStates = RZ.Medical.DEATH_STATE

    if record.state == RZ.State.ALIVE then
        local medicalState = RZ.Medical.GetDeathState(source)
        if medicalState == deathStates.DEAD then
            RZ.Log.Suspicious(source, 'knock', 'reached qbx_medical DEAD while alive in zone — eliminating')
            Store.SetState(source, RZ.State.ELIMINATED, 'bypassed knock')
            Elim.RecordOnly(source, zoneId, 'bypassed knock')
            return
        end
        if inHealthGrace(record, health) then return end

        if medicalState == deathStates.LAST_STAND or (health > 0 and health <= Config.Knock.lethalThreshold) then
            Knock.EnterDowned(source, zoneId, 'server health watchdog')
        elseif health <= 0 then
            Knock.EnterDowned(source, zoneId, 'server watchdog: lethal damage')
        end
        return
    end

    if record.state ~= RZ.State.DOWNED and record.state ~= RZ.State.BEING_REVIVED then return end

    if not Config.Knock.immuneWhileDowned then
        local finished = health > 0 and health <= (Config.Knock.finishThreshold or 5)
        if finished or health <= 0 or RZ.Medical.GetDeathState(source) == deathStates.DEAD then
            local ok, err = pcall(Elim.Eliminate, source, 'finished while downed')
            if not ok then
                RZ.Log.Integration('knock', ('finish elimination failed for %s: %s'):format(source, tostring(err)))
            end
        end
        return
    end

    if RZ.Medical.IsDeadOrLastStand(source) then
        RZ.Medical.EnterRedZoneDowned(source)
    end
end

lib.callback.register(RZ.Callback.REQUEST_DOWNED, function(source)
    if not RZ.Guard(source, 'requestDowned') then return false end

    local record = Store.Get(source)
    if not record or not record.zoneId then return false end
    if record.state ~= RZ.State.ALIVE then return false end
    if not RZ.Access.IsInsideZone(source, record.zoneId) then
        return reject(source, 'requestDowned', 'claimed downed while outside the zone')
    end

    local health = RZ.Medical.GetHealth(source)
    if inHealthGrace(record, health) then return false end
    if health > Config.Knock.lethalThreshold then
        return reject(source, 'requestDowned',
            ('claimed lethal damage at health %d (threshold %d)'):format(health, Config.Knock.lethalThreshold))
    end

    return Knock.EnterDowned(source, record.zoneId, 'client lethal damage report')
end)

local function newTimedAction(cfgKey, waitMs, validate)
    local action = { active = {}, running = false }

    function action.LockTtl()
        local cfg = Config[cfgKey]
        return cfg.durationMs + cfg.watchdogGraceMs + 5000
    end

    function action.TooEarly(entry)
        local elapsed = RZ.Mono() - entry.startedAt
        return elapsed < (Config[cfgKey].durationMs - Config.Validation.completionToleranceMs), elapsed
    end

    function action.StartWatchdog()
        if action.running then return end
        action.running = true

        CreateThread(function()
            while action.running do
                local now = RZ.Mono()
                local cfg = Config[cfgKey]
                local stalledAfter = cfg.durationMs + cfg.watchdogGraceMs
                for key, entry in pairs(action.active) do
                    local ok, reason = validate(key, entry)
                    if not ok then
                        action.cancel(key, reason or 'validation failed')
                    elseif (now - entry.startedAt) > stalledAfter then
                        action.cancel(key, 'timed out without completion')
                    end
                end
                Wait(waitMs)
            end
        end)
    end

    function action.StopWatchdog()
        action.running = false
    end

    function action.CancelAll(reason, zoneId)
        for key, entry in pairs(action.active) do
            if not zoneId or entry.zoneId == zoneId then
                action.cancel(key, reason)
            end
        end
    end

    return action
end

local function reviveValidate(reviverSrc, targetSrc)
    if reviverSrc == targetSrc then return false, 'revive.self' end
    if GetPlayerName(reviverSrc) == nil then return false, 'reviver offline' end
    if GetPlayerName(targetSrc) == nil then return false, 'target offline' end

    local reviver = Store.Get(reviverSrc)
    local target = Store.Get(targetSrc)
    if not reviver or not target then return false, 'not tracked' end
    if reviver.state ~= RZ.State.ALIVE then return false, 'reviver not alive' end
    if RZ.Medical.IsDeadOrLastStand(reviverSrc) then return false, 'reviver dead' end
    if target.state ~= RZ.State.DOWNED and target.state ~= RZ.State.BEING_REVIVED then
        return false, 'target not downed'
    end

    local zoneId = target.zoneId
    if not zoneId then return false, 'target has no zone' end
    if reviver.zoneId ~= zoneId then return false, 'different zone' end
    if not RZ.Schedule.IsOpen(zoneId) then return false, 'zone closed' end
    if Config.Cooldown.blockReviveWhileOnCooldown and target.citizenid
        and RZ.Cooldowns.IsBlocked(target.citizenid, zoneId) then
        return false, 'target on cooldown'
    end
    if not RZ.Access.IsInsideZone(reviverSrc, zoneId) then return false, 'reviver left zone' end
    if not RZ.Access.IsInsideZone(targetSrc, zoneId) then return false, 'target left zone' end
    if not RZ.Groups.AreTeammates(reviverSrc, targetSrc, zoneId) then return false, 'different group' end

    local reviverCoords = RZ.Access.CoordsOf(reviverSrc)
    local targetCoords = RZ.Access.CoordsOf(targetSrc)
    if not reviverCoords or not targetCoords then return false, 'no coords' end
    if RZ.Geo.Dist3D(reviverCoords, targetCoords) > Config.Revive.maxDistance then return false, 'too far' end
    return true
end

Revive.Validate = reviveValidate

local reviveAction = newTimedAction('Revive', 400, function(targetSrc, entry)
    return reviveValidate(entry.reviverSrc, targetSrc)
end)

local reviveActive = reviveAction.active

function Revive.CancelForTarget(targetSrc, reason)
    local entry = reviveActive[targetSrc]
    if not entry then return end

    reviveActive[targetSrc] = nil
    RZ.Lock.Release(lockName('revive:', targetSrc), entry.reviverSrc)

    local target = Store.Get(targetSrc)
    if target then
        target.reviverSrc = nil
        if target.state == RZ.State.BEING_REVIVED
            and Store.SetState(targetSrc, RZ.State.DOWNED, 'revive cancelled') then
            Knock.ResumeTimer(targetSrc)
        end
    end

    RZ.Log.ReviveCancelled(entry.reviverSrc, targetSrc, reason)
    if GetPlayerName(entry.reviverSrc) ~= nil then
        TriggerClientEvent(RZ.Event.CANCEL_ACTION, entry.reviverSrc, 'revive')
        RZ.Notify(entry.reviverSrc, 'revive.cancelled', nil, 'error')
    end
end

reviveAction.cancel = Revive.CancelForTarget

function Revive.CancelForReviver(reviverSrc, reason)
    for targetSrc, entry in pairs(reviveActive) do
        if entry.reviverSrc == reviverSrc then
            Revive.CancelForTarget(targetSrc, reason)
        end
    end
end

Revive.CancelAll = reviveAction.CancelAll
Revive.StartWatchdog = reviveAction.StartWatchdog
Revive.StopWatchdog = reviveAction.StopWatchdog

local function scoreMinigame(reportedHits)
    local mg = Config.Revive.minigame
    if not mg or not mg.enabled then return true, 0, 0, 1.0 end

    local beatInterval = 60000.0 / math.max(1, mg.bpm)
    local totalBeats = math.floor(Config.Revive.durationMs / beatInterval)
    if totalBeats < 1 then totalBeats = 1 end

    local hits = tonumber(reportedHits) or 0
    if hits ~= hits or hits == math.huge or hits == -math.huge then hits = 0 end
    hits = math.min(math.max(math.floor(hits), 0), totalBeats)

    local accuracy = hits / totalBeats
    return accuracy >= (mg.requiredAccuracy or 0), hits, totalBeats, accuracy
end

Revive.ScoreMinigame = scoreMinigame

local REVIVE_REJECT_NOTIFY = {
    ['different group']    = 'revive.wrong_gang',
    ['target not downed']  = 'revive.not_downed',
    ['too far']            = 'revive.too_far',
    ['target on cooldown'] = 'revive.target_cooldown',
}

lib.callback.register(RZ.Callback.BEGIN_REVIVE, function(source, targetSrc)
    if not RZ.Guard(source, 'beginRevive') then return false end
    if type(targetSrc) ~= 'number' then return reject(source, 'beginRevive', 'non-numeric target') end

    local valid, reason = reviveValidate(source, targetSrc)
    if not valid then
        RZ.Log.Suspicious(source, 'beginRevive', reason or 'validation failed')
        return deny(source, REVIVE_REJECT_NOTIFY[reason] or 'error.generic')
    end

    local key = lockName('revive:', targetSrc)
    if not RZ.Lock.Acquire(key, source, reviveAction.LockTtl()) then
        return deny(source, 'revive.already_busy')
    end
    if not Store.SetState(targetSrc, RZ.State.BEING_REVIVED, 'revive started') then
        RZ.Lock.Release(key, source)
        return false
    end

    local remaining = Knock.PauseTimer(targetSrc)
    local token = RZ.Id.New('rev')
    local entry = {
        token = token,
        reviverSrc = source,
        startedAt = RZ.Mono(),
        zoneId = Store.Get(targetSrc).zoneId,
    }
    reviveActive[targetSrc] = entry

    local target = Store.Get(targetSrc)
    if target then target.reviverSrc = source end

    RZ.Log.ReviveStarted(source, targetSrc, entry.zoneId)
    RZ.Notify(source, 'revive.started')
    RZ.Log.Debug(('revive paused %s timer at %s ms remaining'):format(targetSrc, tostring(remaining)))

    local mg = Config.Revive.minigame
    return {
        token = token,
        durationMs = Config.Revive.durationMs,
        minigame = mg and mg.enabled and {
            enabled = true,
            bpm = mg.bpm,
            hitWindowMs = mg.hitWindowMs,
            requiredAccuracy = mg.requiredAccuracy,
            control = mg.control,
            maxConsecutiveMisses = mg.maxConsecutiveMisses,
        } or nil,
    }
end)

lib.callback.register(RZ.Callback.COMPLETE_REVIVE, function(source, targetSrc, token, reportedHits)
    if not RZ.Guard(source, 'completeRevive') then return false end
    if type(targetSrc) ~= 'number' or type(token) ~= 'string' then
        return reject(source, 'completeRevive', 'malformed arguments')
    end

    local entry = reviveActive[targetSrc]
    if not entry then return reject(source, 'completeRevive', 'no active revive for that target') end
    if entry.token ~= token or entry.reviverSrc ~= source then
        return reject(source, 'completeRevive', 'token/owner mismatch')
    end

    local tooEarly, elapsed = reviveAction.TooEarly(entry)
    if tooEarly then
        RZ.Log.Suspicious(source, 'completeRevive',
            ('completed after only %d ms of a %d ms action'):format(elapsed, Config.Revive.durationMs))
        Revive.CancelForTarget(targetSrc, 'completed too early')
        return false
    end

    local valid, reason = reviveValidate(source, targetSrc)
    if not valid then
        Revive.CancelForTarget(targetSrc, reason or 'validation failed at completion')
        return false
    end

    local passed, hits, totalBeats, accuracy = scoreMinigame(reportedHits)
    if not passed then
        Revive.CancelForTarget(targetSrc,
            ('CPR failed: %d/%d compressions (%.0f%%)'):format(hits, totalBeats, accuracy * 100))
        RZ.Notify(source, 'revive.cpr_failed', { math.floor(accuracy * 100) }, 'error')
        return false
    end

    reviveActive[targetSrc] = nil
    RZ.Lock.Release(lockName('revive:', targetSrc), source)
    if not Knock.RestoreToAlive(targetSrc, Config.Revive.revivedHealth) then
        RZ.Log.Integration('revive', ('failed to restore %s to alive'):format(targetSrc))
        return false
    end

    RZ.Log.ReviveSuccess(source, targetSrc, entry.zoneId)
    RZ.Notify(source, 'revive.success', nil, 'success')
    RZ.Notify(targetSrc, 'revive.wpr_revived', nil, 'success')
    return true
end)

lib.callback.register(RZ.Callback.CANCEL_REVIVE, function(source, targetSrc, token)
    if not RZ.Guard(source, 'completeRevive') then return false end
    if type(targetSrc) ~= 'number' or type(token) ~= 'string' then return false end

    local entry = reviveActive[targetSrc]
    if not entry or entry.token ~= token or entry.reviverSrc ~= source then return false end

    Revive.CancelForTarget(targetSrc, 'cancelled by reviver')
    return true
end)

function Elim.CreateRecord(source, zoneId, cause)
    local record = Store.Get(source)
    if not record then return nil end
    if record.deathId then
        local existing = RZ.Db.GetDeath(record.deathId)
        if existing and existing.status == RZ.DeathStatus.PENDING then return record.deathId end
    end

    local coords = RZ.Access.CoordsOf(source) or vec3(0.0, 0.0, 0.0)
    local group = RZ.Groups.GetPlayerGroup(source, zoneId)
    if not group then
        RZ.Log.Integration('elimination',
            ('%s eliminated with no resolvable combat group — no record created'):format(RZ.Log.Who(source)))
        return nil
    end

    local charName = record.name
    if RZ.Fw.IsLoaded(source) then
        local resolved = (RZ.Fw.Name(source) or ''):gsub('^%s+', ''):gsub('%s+$', '')
        if resolved ~= '' then charName = resolved end
    end

    local now = RZ.Now()
    local expiresAt = nil
    if Config.Elimination.expiryMinutes and Config.Elimination.expiryMinutes > 0 then
        expiresAt = now + (Config.Elimination.expiryMinutes * 60 * 1000)
    end

    local deathId = RZ.Id.New('dth')
    local inserted = RZ.Db.InsertDeath({
        death_id = deathId,
        citizenid = record.citizenid,
        license = record.license,
        char_name = charName,
        gang_id = group.id,
        zone_id = zoneId,
        pos_x = coords.x,
        pos_y = coords.y,
        pos_z = coords.z,
        created_at = now,
        expires_at = expiresAt,
    })
    if not inserted then
        RZ.Log.Integration('elimination', ('death id collision for %s'):format(deathId))
        return nil
    end

    record.deathId = deathId
    record.eliminationZoneId = zoneId
    record.deathCoords = vec3(coords.x, coords.y, coords.z)
    RZ.Db.CacheCharName(record.citizenid, charName, now)
    RZ.Db.PrimeNameCache(record.citizenid, charName)
    Elim.BroadcastPeers(zoneId)
    RZ.Log.Elimination(source, zoneId, deathId)
    return deathId
end

function Elim.RecordOnly(source, zoneId, cause)
    local deathId = Elim.CreateRecord(source, zoneId, cause)

    local record = Store.Get(source)
    if record then clearDownedPresentation(record) end

    RZ.LootBag.SnapshotOnElimination(source, zoneId)
    return deathId
end

function Elim.Eliminate(source, cause)
    local record = Store.Get(source)
    if not record then return end
    if record.state ~= RZ.State.DOWNED and record.state ~= RZ.State.BEING_REVIVED then return end

    local zoneId = record.zoneId
    if not zoneId then return end
    if record.state == RZ.State.BEING_REVIVED then
        Revive.CancelForTarget(source, 'target eliminated')
    end
    if not Store.SetState(source, RZ.State.ELIMINATED, cause) then return end

    clearDownedPresentation(record)
    Elim.CreateRecord(source, zoneId, cause)
    RZ.LootBag.SnapshotOnElimination(source, zoneId)
    RZ.Medical.MarkFullyDead(source)
    RZ.Notify(source, 'knock.eliminated', nil, 'error')
end

function Elim.ForfeitOnRespawn(source, zoneId)
    local record = Store.Get(source)
    if not record or not record.deathId then return end

    local deathId = record.deathId
    if RZ.Db.ForfeitDeath(deathId) then
        RZ.Log.Debug(('death %s forfeited: %s respawned instead of waiting for a reboot')
            :format(deathId, RZ.Log.Who(source)))
    end

    record.deathId = nil
    Elim.BroadcastPeers(zoneId)
end

function Elim.BroadcastPeers(zoneId)
    if RZ.Sync and RZ.Sync.PushPeers then pcall(RZ.Sync.PushPeers) end
end

function Elim.RemovePickup(deathId, zoneId)
    Elim.BroadcastPeers(zoneId)
end

function Elim.ReconcilePending()
    local total = 0
    for zoneId, zone in pairs(Config.Zones) do
        if zone.enabled then total = total + #RZ.Db.FetchPendingDeaths(zoneId) end
    end
    RZ.Log.Info(('elimination: %d unresolved death record(s) carried over'):format(total))
end

function Elim.ExpireStale()
    local expired = RZ.Db.ExpirePendingDeaths(RZ.Now())
    if #expired > 0 then
        RZ.Log.Debug(('elimination: expired %d pending record(s)'):format(#expired))
        Elim.BroadcastPeers()
    end
end

function Elim.InvalidateSessionRecords(zoneId, endedSessionId)
    if not Config.SoloSquads.enabled or not Config.SoloSquads.dnaExpiresAtSessionEnd then return end

    Elim.BroadcastPeers(zoneId)
    RZ.Log.Debug(('elimination: solo-squad records from session %s are no longer usable')
        :format(endedSessionId))
end

local function acquireDna(source, citizenid, deathId)
    local record = Store.Get(source)
    if not record then return false, 'error.generic' end

    local zoneId = record.zoneId
    if not zoneId then return false, 'error.generic' end
    if not RZ.Schedule.IsOpen(zoneId) then return false, 'zone.closed' end
    if record.state ~= RZ.State.ALIVE then return false, 'error.not_alive' end
    if not RZ.Access.IsInsideZone(source, zoneId) then return false, 'error.too_far' end

    local row = RZ.Db.GetDeath(deathId)
    if not row then
        RZ.Log.DnaDuplicate(source, tostring(deathId), 'no such death record')
        return false, 'dna.invalid'
    end
    if row.zone_id ~= zoneId then
        RZ.Log.Suspicious(source, 'acquireDna', 'death record belongs to another zone')
        return false, 'dna.invalid'
    end
    if row.status ~= RZ.DeathStatus.PENDING then
        RZ.Log.DnaDuplicate(source, deathId, 'record already ' .. tostring(row.status))
        return false, 'dna.already_acquired'
    end
    if row.expires_at and row.expires_at <= RZ.Now() then return false, 'dna.expired' end
    if not RZ.Groups.SourceMatchesGroupId(source, row.gang_id, zoneId) then
        RZ.Log.Suspicious(source, 'acquireDna', 'group mismatch on death record')
        return false, 'dna.wrong_gang'
    end

    local targetRecord = Store.GetByCitizenId(row.citizenid)
    local bodyCoords = vec3(row.pos_x, row.pos_y, row.pos_z)
    if targetRecord and GetPlayerName(targetRecord.src) ~= nil then
        local live = RZ.Access.CoordsOf(targetRecord.src)
        if live then bodyCoords = live end
    end
    if RZ.Access.DistanceTo(source, bodyCoords) > Config.Elimination.acquireDistance then
        return false, 'dna.too_far'
    end

    local key = lockName('death:', deathId)
    if not RZ.Lock.Acquire(key, source, 8000) then return false, 'dna.already_acquired' end

    local serial = RZ.Id.New('head')
    if not RZ.Db.ClaimDeath(deathId, serial, citizenid, RZ.Now()) then
        RZ.Lock.Release(key, source)
        RZ.Log.DnaDuplicate(source, deathId, 'lost the claim race')
        return false, 'dna.already_acquired'
    end

    local metadata = {
        serial = serial,
        deathId = deathId,
        targetCitizenId = row.citizenid,
        targetName = row.char_name,
        groupId = row.gang_id,
        groupType = RZ.Groups.IsSoloSquadGroupId(row.gang_id) and RZ.Groups.TYPE_SOLO_SQUAD or RZ.Groups.TYPE_GANG,
        zoneId = row.zone_id,
        createdAt = RZ.Now(),
        description = ('Recovered from %s'):format(row.char_name),
    }

    local squadId, sessionId = RZ.Groups.SplitSoloSquadGroupId(row.gang_id)
    if squadId then
        metadata.squadId = squadId
        metadata.sessionId = sessionId
    end

    local added, addErr = RZ.Inv.Add(source, Config.Items.teammateDna, 1, metadata)
    if not added then
        RZ.Db.ReleaseDeathClaim(deathId, serial)
        RZ.Lock.Release(key, source)
        RZ.Log.Debug(('head acquisition rolled back for %s: %s'):format(deathId, tostring(addErr)))
        return false, 'dna.inventory_full'
    end

    RZ.Lock.Release(key, source)
    Elim.RemovePickup(deathId, zoneId)
    RZ.Log.DnaAcquired(source, deathId, row.char_name)
    return true, nil, row.char_name
end

Elim.AcquireDna = acquireDna

lib.callback.register(RZ.Callback.ACQUIRE_HEAD, function(source, deathId)
    local ok, citizenid = RZ.Guard(source, 'acquireDna')
    if not ok then return false end
    if type(deathId) ~= 'string' or #deathId > 96 then
        return reject(source, 'acquireDna', 'malformed death id')
    end

    local acquired, errKey, targetName = acquireDna(source, citizenid, deathId)
    if not acquired then return deny(source, errKey or 'error.generic') end

    RZ.Notify(source, 'dna.acquired', { targetName }, 'success')
    return true
end)

local function stationPoint(station)
    return vec3(station.propCoords.x, station.propCoords.y, station.propCoords.z)
end

function Reboot.ResolveStation(source, zoneId)
    local zone = Config.Zones[zoneId]
    if not zone then return nil end

    local coords = RZ.Access.CoordsOf(source)
    if not coords then return nil end

    for index = 1, #zone.rebootStations do
        local station = zone.rebootStations[index]
        if RZ.Geo.Dist3D(coords, stationPoint(station)) <= station.interactionDistance then
            return index, station
        end
    end
    return nil
end

function Reboot.ResolveDna(source, serial, zoneId)
    if type(serial) ~= 'string' or serial == '' or #serial > 96 then
        return nil, nil, 'reboot.invalid_item'
    end

    local slot = RZ.Inv.FindSlotBySerial(source, Config.Items.teammateDna, serial)
    if not slot then return nil, nil, 'reboot.invalid_item' end

    local row = RZ.Db.GetDeathBySerial(serial)
    if not row then
        RZ.Log.DnaDuplicate(source, tostring(slot.metadata and slot.metadata.deathId),
            'serial not present in any death record')
        return nil, nil, 'reboot.invalid_item'
    end

    local meta = slot.metadata or {}
    if meta.deathId ~= row.death_id then
        RZ.Log.Suspicious(source, 'reboot', 'item deathId does not match the record for its serial')
        return nil, nil, 'reboot.invalid_item'
    end
    if meta.targetCitizenId ~= row.citizenid then
        RZ.Log.Suspicious(source, 'reboot', 'item targetCitizenId does not match the record')
        return nil, nil, 'reboot.invalid_item'
    end
    if row.status ~= RZ.DeathStatus.ACQUIRED then return nil, nil, 'reboot.already_used' end
    if row.zone_id ~= zoneId then return nil, nil, 'reboot.invalid_item' end
    if not RZ.Groups.SourceMatchesGroupId(source, row.gang_id, zoneId) then
        return nil, nil, 'reboot.invalid_item'
    end
    if not RZ.Groups.IsGroupIdCurrent(row.gang_id, zoneId) then return nil, nil, 'reboot.already_used' end

    return slot, row
end

local function rebootValidate(actorSrc, entry)
    if GetPlayerName(actorSrc) == nil then return false, 'actor offline' end

    local actor = Store.Get(actorSrc)
    if not actor then return false, 'actor not tracked' end
    if actor.state ~= RZ.State.ALIVE then return false, 'actor not alive' end
    if actor.zoneId ~= entry.zoneId then return false, 'actor left zone' end
    if not RZ.Schedule.IsOpen(entry.zoneId) then return false, 'zone closed' end
    if not RZ.Access.IsInsideZone(actorSrc, entry.zoneId) then return false, 'actor outside zone' end

    local zone = Config.Zones[entry.zoneId]
    local station = zone and zone.rebootStations[entry.stationIndex]
    if not station then return false, 'station gone' end
    if RZ.Access.DistanceTo(actorSrc, stationPoint(station)) > Config.Reboot.maxDistance then
        return false, 'moved away from station'
    end

    local slot, row, err = Reboot.ResolveDna(actorSrc, entry.serial, entry.zoneId)
    if not slot or not row then return false, err or 'item gone' end
    if row.death_id ~= entry.deathId then return false, 'item changed' end

    local targetRecord = Store.GetByCitizenId(entry.targetCitizenId)
    if not targetRecord then return false, 'target offline' end
    if GetPlayerName(targetRecord.src) == nil then return false, 'target offline' end

    local targetState = targetRecord.state
    if targetState ~= RZ.State.ELIMINATED
        and targetState ~= RZ.State.RESPAWN_BLOCKED
        and targetState ~= RZ.State.BEING_REBOOTED then
        return false, 'target not eligible'
    end
    return true
end

Reboot.Validate = rebootValidate

local rebootAction = newTimedAction('Reboot', 500, rebootValidate)
local rebootActive = rebootAction.active

function Reboot.Cancel(actorSrc, reason)
    local entry = rebootActive[actorSrc]
    if not entry then return end

    rebootActive[actorSrc] = nil
    RZ.Lock.Release(lockName('reboot:', entry.deathId), actorSrc)

    local targetRecord = Store.GetByCitizenId(entry.targetCitizenId)
    if targetRecord and targetRecord.state == RZ.State.BEING_REBOOTED then
        Store.ForceState(targetRecord.src, entry.targetPriorState or RZ.State.ELIMINATED, 'reboot cancelled')
    end

    RZ.Log.RebootCancelled(actorSrc, entry.serial, reason)
    if GetPlayerName(actorSrc) ~= nil then
        TriggerClientEvent(RZ.Event.CANCEL_ACTION, actorSrc, 'reboot')
        RZ.Notify(actorSrc, 'reboot.cancelled', nil, 'error')
    end
end

rebootAction.cancel = Reboot.Cancel

function Reboot.CancelForTarget(targetSrc, reason)
    local record = Store.Get(targetSrc)
    if not record then return end

    for actorSrc, entry in pairs(rebootActive) do
        if entry.targetCitizenId == record.citizenid then
            Reboot.Cancel(actorSrc, reason)
        end
    end
end

Reboot.CancelAll = rebootAction.CancelAll
Reboot.StartWatchdog = rebootAction.StartWatchdog
Reboot.StopWatchdog = rebootAction.StopWatchdog

lib.callback.register(RZ.Callback.LIST_DNA, function(source)
    if not RZ.Guard(source, 'listDna') then return {} end

    local record = Store.Get(source)
    if not record or not record.zoneId then return {} end

    local zoneId = record.zoneId
    local slots = RZ.Inv.FindAllSlots(source, Config.Items.teammateDna)
    local out = {}
    for i = 1, #slots do
        local meta = slots[i].metadata
        if meta and type(meta.serial) == 'string' then
            local _, row = Reboot.ResolveDna(source, meta.serial, zoneId)
            if row then
                local targetRecord = Store.GetByCitizenId(row.citizenid)
                out[#out + 1] = {
                    serial = meta.serial,
                    targetName = row.char_name,
                    online = targetRecord ~= nil and GetPlayerName(targetRecord.src) ~= nil,
                    eliminatedAgoMs = RZ.Now() - row.created_at,
                }
            end
        end
    end
    return out
end)

lib.callback.register(RZ.Callback.BEGIN_REBOOT, function(source, serial)
    if not RZ.Guard(source, 'beginReboot') then return false end

    local record = Store.Get(source)
    if not record or not record.zoneId then return false end
    if record.state ~= RZ.State.ALIVE then return deny(source, 'error.not_alive') end

    local zoneId = record.zoneId
    if not RZ.Schedule.IsOpen(zoneId) then return deny(source, 'zone.closed') end

    local stationIndex, station = Reboot.ResolveStation(source, zoneId)
    if not stationIndex or not station then return deny(source, 'error.too_far') end

    local slot, row, err = Reboot.ResolveDna(source, serial, zoneId)
    if not slot or not row then return deny(source, err or 'reboot.invalid_item') end

    local targetRecord = Store.GetByCitizenId(row.citizenid)
    if not targetRecord or GetPlayerName(targetRecord.src) == nil then
        return deny(source, 'reboot.target_offline')
    end
    if targetRecord.state ~= RZ.State.ELIMINATED and targetRecord.state ~= RZ.State.RESPAWN_BLOCKED then
        return deny(source, 'reboot.target_not_eligible')
    end

    local key = lockName('reboot:', row.death_id)
    if not RZ.Lock.Acquire(key, source, rebootAction.LockTtl()) then
        return deny(source, 'error.locked')
    end

    local priorState = targetRecord.state
    if not Store.SetState(targetRecord.src, RZ.State.BEING_REBOOTED, 'reboot started') then
        RZ.Lock.Release(key, source)
        return false
    end

    local token = RZ.Id.New('reb')
    rebootActive[source] = {
        token = token,
        deathId = row.death_id,
        serial = serial,
        targetCitizenId = row.citizenid,
        targetPriorState = priorState,
        zoneId = zoneId,
        stationIndex = stationIndex,
        startedAt = RZ.Mono(),
    }

    RZ.Log.RebootStarted(source, row.citizenid, serial)
    RZ.Notify(source, 'reboot.started', { row.char_name })
    return { token = token, durationMs = Config.Reboot.durationMs }
end)

lib.callback.register(RZ.Callback.COMPLETE_REBOOT, function(source, token)
    if not RZ.Guard(source, 'completeReboot') then return false end

    local entry = rebootActive[source]
    if not entry or type(token) ~= 'string' or entry.token ~= token then
        return reject(source, 'completeReboot', 'no matching in-flight reboot')
    end

    local tooEarly, elapsed = rebootAction.TooEarly(entry)
    if tooEarly then
        RZ.Log.Suspicious(source, 'completeReboot',
            ('completed after only %d ms of a %d ms action'):format(elapsed, Config.Reboot.durationMs))
        Reboot.Cancel(source, 'completed too early')
        return false
    end

    local valid, reason = rebootValidate(source, entry)
    if not valid then
        Reboot.Cancel(source, reason or 'validation failed at completion')
        return false
    end

    local targetRecord = Store.GetByCitizenId(entry.targetCitizenId)
    if not targetRecord then
        Reboot.Cancel(source, 'target vanished')
        return false
    end

    local zone = Config.Zones[entry.zoneId]
    local station = zone.rebootStations[entry.stationIndex]
    if not RZ.Db.ConsumeDeathForReboot(entry.deathId, entry.serial, RZ.Now()) then
        Reboot.Cancel(source, 'death record already resolved')
        return deny(source, 'reboot.already_used')
    end

    local slot = RZ.Inv.FindSlotBySerial(source, Config.Items.teammateDna, entry.serial)
    if not slot then
        RZ.Db.RestoreDeathAfterFailedReboot(entry.deathId, entry.serial)
        Reboot.Cancel(source, 'item disappeared before consumption')
        return false
    end
    if not RZ.Inv.Remove(source, Config.Items.teammateDna, 1, nil, slot.slot) then
        RZ.Db.RestoreDeathAfterFailedReboot(entry.deathId, entry.serial)
        Reboot.Cancel(source, 'could not consume the head item')
        RZ.Log.Integration('reboot', ('failed to remove head %s from %s'):format(entry.serial, RZ.Log.Who(source)))
        return false
    end

    local deathId = entry.deathId
    local targetSrc = targetRecord.src
    rebootActive[source] = nil
    RZ.Lock.Release(lockName('reboot:', deathId), source)
    RZ.Cooldowns.Clear(entry.targetCitizenId, entry.zoneId)
    RZ.Medical.ClearDeathState(targetSrc)
    Knock.BeginHealthGrace(targetRecord)

    if not RZ.Medical.Revive(targetSrc, station.playerSpawn, Config.Reboot.rebootedHealth) then
        RZ.Log.Integration('reboot',
            ('death resource revive failed for %s after head %s was consumed — completed on RedZone restore alone')
            :format(RZ.Log.Who(targetSrc), entry.serial))
    end

    Store.ForceState(targetSrc, RZ.State.ALIVE, 'rebooted')
    targetRecord.deathId = nil
    clearDownedPresentation(targetRecord)
    RZ.LootBag.ClearSnapshot(targetSrc)
    Elim.RemovePickup(deathId, entry.zoneId)

    RZ.Log.RebootSuccess(source, targetSrc, deathId)
    RZ.Notify(source, 'reboot.success', { targetRecord.name }, 'success')
    RZ.Notify(targetSrc, 'reboot.wpr_rebooted', nil, 'success')
    return true
end)

lib.callback.register(RZ.Callback.CANCEL_REBOOT, function(source, token)
    if not RZ.Guard(source, 'completeReboot') then return false end

    local entry = rebootActive[source]
    if not entry or type(token) ~= 'string' or entry.token ~= token then return false end

    Reboot.Cancel(source, 'cancelled by actor')
    return true
end)

RZ = RZ or {}

RZ.Store = {}
RZ.Schedule = {}
RZ.Session = {}
RZ.Cooldowns = {}

local Store = RZ.Store
local Schedule = RZ.Schedule
local Session = RZ.Session
local Cooldowns = RZ.Cooldowns

local players = {}
local byCitizen = {}

function Store.Track(source, citizenid)
    local existing = players[source]
    if existing and existing.citizenid == citizenid then
        return existing
    end
    if existing and byCitizen[existing.citizenid] == existing then
        byCitizen[existing.citizenid] = nil
    end

    local record = {
        src = source,
        citizenid = citizenid,
        name = GetPlayerName(source) or ('player_' .. tostring(source)),
        license = nil,
        state = RZ.State.OUTSIDE,
        stateSince = RZ.Now(),
        zoneId = nil, gangId = nil, groupId = nil, groupType = nil,
        lastOutsideCoords = nil, lastEjectAt = 0, ejectCount = 0,
        lastBurnAt = nil, lastBurnWarnAt = nil, burnDown = nil,
        burnLastHealth = nil, burnIgnored = nil, bagSnapshot = nil,
        deathId = nil, deathCoords = nil, eliminationZoneId = nil,
        knockRemainingMs = nil, knockDeadline = nil, reviverSrc = nil,
        healthGraceUntil = nil, downedAt = nil, lastReclaimAt = nil, medicalTookOver = nil,
        eliminatedAt = nil, elimSeenDead = nil, elimKillResent = nil,
        affiliation = nil, canSee = nil, visibilityCheckedAt = 0,
        lastHitAt = nil, lastAttackAt = nil,
    }

    for _, id in ipairs(GetPlayerIdentifiers(source) or {}) do
        if id:sub(1, 8) == 'license:' then
            record.license = id
            break
        end
    end

    players[source] = record
    if citizenid then byCitizen[citizenid] = record end
    return record
end

function Store.Untrack(source)
    local record = players[source]
    if record and record.citizenid and byCitizen[record.citizenid] == record then
        byCitizen[record.citizenid] = nil
    end
    players[source] = nil
end

function Store.Get(source)
    return players[source]
end

function Store.All()
    return players
end

function Store.GetByCitizenId(citizenid)
    if citizenid == nil then return nil end
    return byCitizen[citizenid]
end

function Store.Clear()
    players = {}
    byCitizen = {}
end

local function publish(record)
    local ply = Player(record.src)
    if ply then
        ply.state:set(RZ.STATE_BAG, record.state, true)
    end

    TriggerClientEvent(RZ.Event.SYNC_SELF, record.src, {
        state = record.state,
        zoneId = record.zoneId,
        knockRemainingMs = record.knockRemainingMs,
        knockDeadline = record.knockDeadline,
        serverMono = RZ.Mono(),
    })
end

Store.Publish = publish

function Store.NameOf(source)
    local record = players[source]
    return record and record.name or tostring(source)
end

function Store.StateOf(source)
    local record = players[source]
    return record and record.state or RZ.State.OUTSIDE
end

function Store.SetState(source, newState, reason)
    local record = players[source]
    if not record then return false end
    if record.state == newState then return true end

    local allowed = RZ.Transitions[record.state]
    if not allowed or not allowed[newState] then
        RZ.Log.Suspicious(source, 'stateTransition',
            ('illegal transition %s -> %s (%s)'):format(record.state, newState, reason or 'no reason'))
        return false
    end

    if Config.Debug then
        RZ.Log.Debug(('state %s: %s -> %s (%s)'):format(Store.NameOf(source), record.state, newState, reason or '-'))
    end
    record.state = newState
    record.stateSince = RZ.Now()
    publish(record)
    return true
end

function Store.ForceState(source, newState, reason)
    local record = players[source]
    if not record then return end
    if record.state == newState then return end
    if Config.Debug then
        RZ.Log.Debug(('state FORCE %s: %s -> %s (%s)'):format(Store.NameOf(source), record.state, newState, reason))
    end
    record.state = newState
    record.stateSince = RZ.Now()
    publish(record)
end

function Store.SetZone(source, zoneId)
    local record = players[source]
    if not record then return end
    if record.zoneId == zoneId then return end
    record.zoneId = zoneId
    publish(record)
end

function Store.GetAlivePlayersInZone(zoneId)
    local out = {}
    for _, record in pairs(players) do
        if record.zoneId == zoneId
            and RZ.CountsForControl[record.state]
            and record.groupId ~= nil
        then
            out[#out + 1] = record
        end
    end
    return out
end

function Store.GetAliveGangIdsInZone(zoneId)
    local seen, ids, counts = {}, {}, {}
    for _, record in pairs(players) do
        if record.zoneId == zoneId
            and RZ.CountsForControl[record.state]
            and record.gangId ~= nil
        then
            if not seen[record.gangId] then
                seen[record.gangId] = true
                ids[#ids + 1] = record.gangId
                counts[record.gangId] = 0
            end
            counts[record.gangId] = counts[record.gangId] + 1
        end
    end
    return ids, counts
end

function Store.GetAliveGangCount(zoneId)
    return #(Store.GetAliveGangIdsInZone(zoneId))
end

function Store.IsExactlyOneGangControlling(zoneId)
    return RZ.Groups.IsExactlyOneGroupControlling(zoneId)
end

exports('GetAlivePlayersInZone', function(zoneId)
    local records = Store.GetAlivePlayersInZone(zoneId)
    local out = {}
    for i = 1, #records do
        out[i] = {
            source = records[i].src,
            gangId = records[i].gangId,
            groupId = records[i].groupId,
            groupType = records[i].groupType,
        }
    end
    return out
end)

exports('GetAliveGangIdsInZone', function(zoneId)
    return RZ.Util.CopyArray((Store.GetAliveGangIdsInZone(zoneId)))
end)

exports('GetAliveGangCount', function(zoneId)
    return Store.GetAliveGangCount(zoneId)
end)

exports('IsExactlyOneGangControlling', function(zoneId)
    return (Store.IsExactlyOneGangControlling(zoneId))
end)

local openState = {}
local scheduleListeners = {}

function Schedule.PruneZone(zoneId)
    openState[zoneId] = nil
end

function Schedule.OffsetOf(zoneId)
    local zone = zoneId and Config.Zones[zoneId]
    local hours = zone and zone.schedule and zone.schedule.utcOffset
    if hours == nil then hours = Config.Schedule.utcOffset end
    return math.floor((tonumber(hours) or 0) * 3600 + 0.5)
end

function Schedule.GetClock(zoneId)
    return RZ.Time.ClockAt(RZ.Time.NowUtc(), Schedule.OffsetOf(zoneId))
end

local function activeZone(zoneId)
    local zone = Config.Zones[zoneId]
    if not zone or not zone.enabled then return nil end
    return zone
end

function Schedule.IsForcedOpen()
    return Config.Debug == true and Config.Schedule.alwaysOpenInDebug == true
end

function Schedule.ComputeIsOpen(zoneId)
    local zone = activeZone(zoneId)
    if not zone then return false end

    if RZ.AdminApply then
        local forced = RZ.AdminApply.GetZoneOverride(zoneId)
        if forced ~= nil then return forced end
    end
    if Schedule.IsForcedOpen() then return true end

    local clock = Schedule.GetClock(zoneId)
    return RZ.Time.IsHourInWindow(clock.hour, zone.schedule.openHour, zone.schedule.closeHour)
end

function Schedule.IsOpen(zoneId)
    return openState[zoneId] == true
end

function Schedule.SecondsUntilChange(zoneId)
    local zone = activeZone(zoneId)
    if not zone then return 3600, false end
    if Schedule.IsForcedOpen() then return 86400, true end
    local clock = Schedule.GetClock(zoneId)
    return RZ.Time.SecondsUntilScheduleChange(clock, zone.schedule.openHour, zone.schedule.closeHour)
end

function Schedule.OnChange(callback)
    scheduleListeners[#scheduleListeners + 1] = callback
end

local function fireSchedule(zoneId, isOpen)
    for i = 1, #scheduleListeners do
        local ok, err = pcall(scheduleListeners[i], zoneId, isOpen)
        if not ok then
            RZ.Log.Integration('schedule', ('listener error for %s: %s'):format(zoneId, tostring(err)))
        end
    end
end

function Schedule.Refresh(announce)
    for zoneId, zone in pairs(Config.Zones) do
        if zone.enabled then
            local shouldBeOpen = Schedule.ComputeIsOpen(zoneId)
            if openState[zoneId] == nil then
                openState[zoneId] = shouldBeOpen
            elseif openState[zoneId] ~= shouldBeOpen then
                openState[zoneId] = shouldBeOpen
                if announce then
                    RZ.Log.Info(('zone %s is now %s'):format(zoneId, shouldBeOpen and 'OPEN' or 'CLOSED'))
                end
                fireSchedule(zoneId, shouldBeOpen)
            end
        elseif openState[zoneId] ~= false then
            local wasOpen = openState[zoneId]
            openState[zoneId] = false
            if wasOpen then
                if announce then
                    RZ.Log.Info(('zone %s is now CLOSED (disabled)'):format(zoneId))
                end
                fireSchedule(zoneId, false)
            end
        end
    end
end

local scheduleStarted = false

function Schedule.Start()
    if scheduleStarted then return end
    scheduleStarted = true

    for zoneId, zone in pairs(Config.Zones) do
        openState[zoneId] = zone.enabled and Schedule.ComputeIsOpen(zoneId) or false
    end

    local clock = Schedule.GetClock()
    RZ.Log.Info(('schedule: server time is %04d-%02d-%02d %02d:%02d:%02d (%s)')
        :format(clock.year, clock.month, clock.day, clock.hour, clock.min, clock.sec,
            RZ.Time.OffsetLabel(clock.offset)))

    if Schedule.IsForcedOpen() then
        RZ.Log.Info('======================================================================')
        RZ.Log.Info(' DEBUG OVERRIDE ACTIVE: every zone is held OPEN 24/7.')
        RZ.Log.Info(' The 20:00-06:00 schedule is being IGNORED.')
        RZ.Log.Info(' Set Config.Debug = false (or alwaysOpenInDebug = false) for production.')
        RZ.Log.Info('======================================================================')
    end

    for zoneId in pairs(Config.Zones) do
        if openState[zoneId] ~= nil then
            local secs = Schedule.SecondsUntilChange(zoneId)
            RZ.Log.Info(('schedule: zone %s starts %s (next change in %s)')
                :format(zoneId, openState[zoneId] and 'OPEN' or 'CLOSED', RZ.Util.FormatDuration(secs * 1000)))
        end
    end

    CreateThread(function()
        while true do
            Wait(Config.Schedule.pollIntervalMs)
            Schedule.Refresh(true)
        end
    end)
end

function Schedule.SelfTest()
    local Time = RZ.Time
    local window = Time.IsHourInWindow
    local OPEN, CLOSE = 20, 6
    local REF = 1787140800
    local function stamp(utc, offset)
        local c = Time.ClockAt(utc, offset)
        return ('%04d-%02d-%02d %02d:%02d:%02d'):format(c.year, c.month, c.day, c.hour, c.min, c.sec)
    end

    local sessionClock = Time.ClockAt(REF, 3 * 3600)
    local pastMidnight = Time.ClockAt(REF + 14 * 3600, 3 * 3600)
    local cases = {
        { '19:00 closed', window(19, OPEN, CLOSE), false },
        { '20:00 open', window(20, OPEN, CLOSE), true },
        { '23:00 open', window(23, OPEN, CLOSE), true },
        { '00:00 open', window(0, OPEN, CLOSE), true },
        { '05:00 open', window(5, OPEN, CLOSE), true },
        { '06:00 closed', window(6, OPEN, CLOSE), false },
        { '12:00 closed', window(12, OPEN, CLOSE), false },
        { 'UTC+0 reads the raw instant', stamp(REF, 0), '2026-08-19 12:00:00' },
        { 'UTC+3 is three hours ahead', stamp(REF, 3 * 3600), '2026-08-19 15:00:00' },
        { 'UTC-5 is five hours behind', stamp(REF, -5 * 3600), '2026-08-19 07:00:00' },
        { 'a half-hour offset works', stamp(REF, 5 * 3600 + 1800), '2026-08-19 17:30:00' },
        { 'a positive offset can roll the date forward', stamp(REF, 13 * 3600), '2026-08-20 01:00:00' },
        { 'a negative offset can roll the date back', stamp(REF, -13 * 3600), '2026-08-18 23:00:00' },
        { 'weekday survives the offset', Time.ClockAt(REF, 0).wday, 3 },
        { 'offset label, whole hours', Time.OffsetLabel(3 * 3600), 'UTC+3' },
        { 'offset label, negative', Time.OffsetLabel(-5 * 3600), 'UTC-5' },
        { 'offset label, half hour', Time.OffsetLabel(5 * 3600 + 1800), 'UTC+5:30' },
        { 'offset label, zero', Time.OffsetLabel(0), 'UTC' },
        { 'session id is the opening date', Time.SessionIdUnchecked(sessionClock, 20, 6), '2026-08-19' },
        { 'past midnight belongs to the previous session',
            Time.SessionIdUnchecked(pastMidnight, 20, 6), '2026-08-19' },
    }

    local results, failures = {}, 0
    for i = 1, #cases do
        local name, actual, expected = cases[i][1], cases[i][2], cases[i][3]
        local ok = actual == expected
        if not ok then failures = failures + 1 end
        results[i] = {
            name = name,
            ok = ok,
            detail = ('got %s, expected %s'):format(tostring(actual), tostring(expected)),
        }
    end

    return results, failures
end

local current = {}
local startListeners = {}
local endListeners = {}

function Session.Compute(zoneId)
    local zone = Config.Zones[zoneId]
    if not zone or not zone.enabled then return nil end

    local clock = Schedule.GetClock(zoneId)
    if Schedule.IsForcedOpen() then
        return RZ.Time.SessionIdUnchecked(clock, zone.schedule.openHour, zone.schedule.closeHour)
    end

    return RZ.Time.SessionId(clock, zone.schedule.openHour, zone.schedule.closeHour)
end

function Session.GetId(zoneId)
    return current[zoneId]
end

function Session.IsCurrent(zoneId, sessionId)
    if type(sessionId) ~= 'string' or sessionId == '' then return false end
    return current[zoneId] == sessionId
end

function Session.IsLiveAnywhere(sessionId)
    for _, live in pairs(current) do
        if live == sessionId then return true end
    end
    return false
end

function Session.OnStart(callback)
    startListeners[#startListeners + 1] = callback
end

function Session.OnEnd(callback)
    endListeners[#endListeners + 1] = callback
end

local function fireSession(listeners, zoneId, sessionId)
    for i = 1, #listeners do
        local ok, err = pcall(listeners[i], zoneId, sessionId)
        if not ok then
            RZ.Log.Integration('session', ('listener error for %s: %s'):format(zoneId, tostring(err)))
        end
    end
end

function Session.Refresh()
    for zoneId, zone in pairs(Config.Zones) do
        if zone.enabled then
            local computed = Session.Compute(zoneId)
            local existing = current[zoneId]
            if existing ~= computed then
                if existing then
                    RZ.Log.Info(('session %s ended for zone %s'):format(existing, zoneId))
                    current[zoneId] = nil
                    fireSession(endListeners, zoneId, existing)
                end

                if computed then
                    current[zoneId] = computed
                    RZ.Log.Info(('session %s started for zone %s'):format(computed, zoneId))
                    fireSession(startListeners, zoneId, computed)
                end
            end
        elseif current[zoneId] then
            local ended = current[zoneId]
            current[zoneId] = nil
            fireSession(endListeners, zoneId, ended)
        end
    end
end

function Session.PruneZone(zoneId)
    local ended = current[zoneId]
    if not ended then return end
    current[zoneId] = nil
    RZ.Log.Info(('session %s ended for zone %s (zone deleted)'):format(ended, zoneId))
    fireSession(endListeners, zoneId, ended)
end

function Session.Prime()
    for zoneId, zone in pairs(Config.Zones) do
        current[zoneId] = zone.enabled and Session.Compute(zoneId) or nil
        if current[zoneId] then
            RZ.Log.Info(('session %s is already in progress for zone %s'):format(current[zoneId], zoneId))
        end
    end
end

local cooldownCache = {}

local function dropCooldown(citizenid, zoneId)
    local byZone = cooldownCache[citizenid]
    if not byZone then return end
    byZone[zoneId] = nil
    if next(byZone) == nil then cooldownCache[citizenid] = nil end
end

function Cooldowns.LoadAll()
    cooldownCache = {}
    local rows = RZ.Db.FetchActiveCooldowns(RZ.Now())
    local count = 0
    for i = 1, #rows do
        local row = rows[i]
        cooldownCache[row.citizenid] = cooldownCache[row.citizenid] or {}
        cooldownCache[row.citizenid][row.zone_id] = row.expires_at
        count = count + 1
    end

    RZ.Log.Info(('cooldowns: loaded %d active lockout(s) from the database'):format(count))
end

function Cooldowns.GetRemaining(citizenid, zoneId)
    local byZone = cooldownCache[citizenid]
    if not byZone then return 0 end

    local expiresAt = byZone[zoneId]
    if not expiresAt then return 0 end
    local remaining = expiresAt - RZ.Now()
    if remaining <= 0 then
        dropCooldown(citizenid, zoneId)
        return 0
    end

    return remaining
end

function Cooldowns.IsBlocked(citizenid, zoneId)
    return Cooldowns.GetRemaining(citizenid, zoneId) > 0
end

function Cooldowns.Apply(citizenid, zoneId, durationMs)
    local now = RZ.Now()
    local expiresAt = now + durationMs
    cooldownCache[citizenid] = cooldownCache[citizenid] or {}
    local existing = cooldownCache[citizenid][zoneId]
    if existing and existing > expiresAt then
        expiresAt = existing
    end
    cooldownCache[citizenid][zoneId] = expiresAt

    RZ.Db.UpsertCooldown(citizenid, zoneId, expiresAt, now)
    return expiresAt
end

function Cooldowns.Clear(citizenid, zoneId)
    dropCooldown(citizenid, zoneId)
    RZ.Db.ClearCooldown(citizenid, zoneId)
end

function Cooldowns.Prune()
    local now = RZ.Now()
    for citizenid, byZone in pairs(cooldownCache) do
        for zoneId, expiresAt in pairs(byZone) do
            if expiresAt <= now then
                byZone[zoneId] = nil
            end
        end
        if next(byZone) == nil then
            cooldownCache[citizenid] = nil
        end
    end

    local removed = RZ.Db.PruneExpiredCooldowns(now)
    if removed > 0 then
        RZ.Log.Debug(('cooldowns: pruned %d expired row(s)'):format(removed))
    end
end

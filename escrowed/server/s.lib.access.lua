RZ = RZ or {}
RZ.Access = {}

local Access = RZ.Access
local Store = RZ.Store

local IN_FLOW = {
    [RZ.State.DOWNED]         = true,
    [RZ.State.BEING_REVIVED]  = true,
    [RZ.State.ELIMINATED]     = true,
    [RZ.State.BEING_REBOOTED] = true,
}

local REJECT_NOTIFY = {
    [RZ.Reject.SOLO]                    = 'access.solo_denied',
    [RZ.Reject.NO_GANG]                 = 'access.gang_only',
    [RZ.Reject.INVALID_GANG]            = 'access.invalid_gang',
    [RZ.Reject.UNVERIFIABLE]            = 'access.unverifiable',
    [RZ.Reject.ZONE_CLOSED]             = 'zone.ejected_closed',
    [RZ.Reject.BLOCKED_JOB]             = 'access.blocked_job',
    [RZ.Reject.NO_SQUAD]                = 'squad.entry_requires_squad',
    [RZ.Reject.SQUAD_JOINED_AFTER_LOCK] = 'squad.joined_after_lock',
    [RZ.Reject.SQUAD_NOT_LOCKED]        = 'squad.entry_requires_squad',
}

local sortedIds, sortedFor = {}, nil

function Access.SortedZoneIds()
    if sortedFor == Config.Zones then return sortedIds end
    sortedIds = {}
    for zoneId in pairs(Config.Zones) do
        sortedIds[#sortedIds + 1] = zoneId
    end
    table.sort(sortedIds)
    sortedFor = Config.Zones
    return sortedIds
end

local function enabledZone(zoneId)
    local zone = Config.Zones[zoneId]
    if zone and zone.enabled then return zone end
    return nil
end

function Access.ResolveZone(coords)
    for _, zoneId in ipairs(Access.SortedZoneIds()) do
        local zone = enabledZone(zoneId)
        if zone then
            local b = zone.bounds
            if not b
                or (coords.x >= b.minX and coords.x <= b.maxX
                    and coords.y >= b.minY and coords.y <= b.maxY) then
                if RZ.Geo.InZone(coords, zone) then return zoneId end
            end
        end
    end
    return nil
end

local function coordsOf(source)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

Access.CoordsOf = coordsOf

function Access.DistanceTo(source, target)
    local coords = coordsOf(source)
    if not coords then return math.huge end
    return RZ.Geo.Dist3D(coords, target)
end

function Access.IsInsideZone(source, zoneId)
    local zone = enabledZone(zoneId)
    if not zone then return false end
    local coords = coordsOf(source)
    if not coords then return false end
    return RZ.Geo.InZone(coords, zone)
end

function Access.HasBlockedJob(source)
    local cfg = Config.BlockedJobs
    if not cfg.enabled then return false end
    if not RZ.Fw.GetPlayer(source) then return false end

    local job = RZ.Fw.Job(source)
    if not job or type(job.name) ~= 'string' then return false end
    if cfg.onlyWhenOnDuty and job.onduty == false then return false end

    for i = 1, #cfg.types do
        if job.type == cfg.types[i] then return true, job.name end
    end
    for i = 1, #cfg.names do
        if job.name == cfg.names[i] then return true, job.name end
    end
    return false
end

local VISIBILITY_RECHECK_MS = 3000

-- Whether the RedZone exists for this player at all. Regular citizens with no gang never
-- see it on the map; they are pushed out like anyone else who is not allowed in.
-- Whitelisted RedZone admins always see it, so they can find the zones they manage.
function Access.CanSee(source)
    if RZ.AdminAuth and RZ.AdminAuth.Check and RZ.AdminAuth.Check(source) then return true end
    if Access.HasBlockedJob(source) then return false end
    return RZ.Gangs.IsAffiliated(source) == true
end

function Access.RefreshVisibility(source, force)
    local record = Store.Get(source)
    if not record then return end

    local now = RZ.Mono()
    if not force and (now - (record.visibilityCheckedAt or 0)) < VISIBILITY_RECHECK_MS then return end
    record.visibilityCheckedAt = now

    local ok, canSee = pcall(Access.CanSee, source)
    canSee = ok and canSee == true
    if record.canSee == canSee then return end

    record.canSee = canSee
    TriggerClientEvent(RZ.Event.SYNC_WORLD, source, { canSee = canSee })
end

function Access.CheckEligibility(source, zoneId)
    if not enabledZone(zoneId) then return false, RZ.Reject.ZONE_CLOSED end
    if not RZ.Schedule.IsOpen(zoneId) then return false, RZ.Reject.ZONE_CLOSED end

    local record = Store.Get(source)
    if not record then return false, RZ.Reject.UNVERIFIABLE end

    if Access.HasBlockedJob(source) then
        return false, RZ.Reject.BLOCKED_JOB, nil
    end

    local remaining = RZ.Cooldowns.GetRemaining(record.citizenid, zoneId)
    if remaining > 0 then
        return false, RZ.Reject.COOLDOWN, nil, remaining
    end

    local valid, gangReason, gangId = RZ.Gangs.IsValidGangMember(source)
    if valid then return true, nil, gangId, 0 end

    if Config.SoloSquads.enabled and gangReason == RZ.Reject.SOLO then
        local squadOk, squadReason = Access.CheckSquadEligibility(source, record, zoneId)
        if squadOk then return true, nil, nil, 0 end
        return false, squadReason, nil
    end

    return false, gangReason, nil
end

function Access.CheckSquadEligibility(source, record, zoneId)
    local sessionId = RZ.Session.GetId(zoneId)
    if not sessionId then return false, RZ.Reject.ZONE_CLOSED end

    local squad = RZ.Squads.GetSquadByCitizenId(record.citizenid)
    if not squad then
        if Config.SoloSquads.requireSquadForEntry then
            return false, RZ.Reject.NO_SQUAD
        end
        return true
    end

    if not Config.SoloSquads.lockRosterAfterFirstEntry then return true end

    local snapshot = RZ.Squads.GetSnapshot(sessionId, squad.id)
    if not snapshot then
        snapshot = RZ.Squads.CreateSnapshot(sessionId, squad)
        if not snapshot then return false, RZ.Reject.SQUAD_NOT_LOCKED end
    end

    if not snapshot.members[record.citizenid] then
        return false, RZ.Reject.SQUAD_JOINED_AFTER_LOCK
    end
    return true
end

local function resolveEjectTarget(record, zone, coords)
    local padding = zone.boundary.ejectPadding
    local last = record.lastOutsideCoords

    if last and not RZ.Geo.InZone(last, zone) then
        local _, _, edgeDist = RZ.Geo.NearestEdgePoint(last, zone.points)
        if edgeDist >= padding and RZ.Geo.Dist2D(last, coords) <= 150.0 then
            return last
        end
    end

    local x, y = RZ.Geo.EjectFromPolygon(coords, zone.points, padding)
    return vec3(x, y, coords.z)
end

local function placeEntity(entity, target)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return end
    SetEntityCoords(entity, target.x, target.y, target.z)
end

local function buildPedIndex()
    local index = {}
    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        if src then
            local p = GetPlayerPed(src)
            if p and p ~= 0 then index[p] = src end
        end
    end
    return index
end

function Access.VehicleHasOtherEligibleOccupant(vehicle, excludePed, zoneId)
    local index = buildPedIndex()

    for seat = -1, 6 do
        local occupant = GetPedInVehicleSeat(vehicle, seat)
        if occupant and occupant ~= 0 and occupant ~= excludePed then
            local otherSrc = index[occupant]
            if otherSrc and Access.CheckEligibility(otherSrc, zoneId) then
                return true
            end
        end
    end

    return false
end

local function forceEject(source, target, leaveVehicle)
    TriggerClientEvent(RZ.Event.FORCE_EJECT, source, {
        x = target.x, y = target.y, z = target.z, leaveVehicle = leaveVehicle,
    })
end

function Access.Eject(source, zoneId, reason, cooldownRemainingMs)
    local record = Store.Get(source)
    local zone = Config.Zones[zoneId]
    if not record or not zone then return end

    local coords = coordsOf(source)
    if not coords then return end

    local ped = GetPlayerPed(source)
    local target = resolveEjectTarget(record, zone, coords)
    local now = RZ.Mono()
    local shouldNotify = (now - record.lastEjectAt) >= Config.Validation.ejectCooldownMs

    if shouldNotify then
        record.ejectCount = record.ejectCount + 1
        record.lastEjectAt = now
        RZ.Log.InvalidEntry(source, zoneId, reason)
        if record.ejectCount >= 3 then
            RZ.Log.RepeatedEntry(source, zoneId, record.ejectCount)
        end
        if reason == RZ.Reject.COOLDOWN and cooldownRemainingMs then
            RZ.Notify(source, 'access.cooldown', { RZ.Util.FormatDuration(cooldownRemainingMs) })
        else
            RZ.Notify(source, REJECT_NOTIFY[reason] or 'access.ejected')
        end
    end

    local vehicle = GetVehiclePedIsIn(ped, false)

    if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
        local driver = GetPedInVehicleSeat(vehicle, -1)
        if driver ~= ped and Access.VehicleHasOtherEligibleOccupant(vehicle, ped, zoneId) then
            forceEject(source, target, true)
            if shouldNotify then RZ.Notify(source, 'access.ejected_vehicle') end
        else
            placeEntity(vehicle, target)
            placeEntity(ped, target)
        end
    else
        forceEject(source, target, false)
        placeEntity(ped, target)
    end

    Store.SetZone(source, nil)
    Access.VerifyEjection(source, zoneId, target, 1)
end

function Access.VerifyEjection(source, zoneId, target, attempt)
    if attempt > Config.Validation.ejectRetries then
        RZ.Log.Suspicious(source, 'eject',
            ('still inside %s after %d correction attempts'):format(zoneId, Config.Validation.ejectRetries))
        return
    end

    SetTimeout(Config.Validation.ejectRetryDelayMs, function()
        if GetPlayerName(source) == nil then return end
        if not Access.IsInsideZone(source, zoneId) then return end
        if Access.CheckEligibility(source, zoneId) then return end

        local ped = GetPlayerPed(source)
        local vehicle = GetVehiclePedIsIn(ped, false)
        if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
            placeEntity(vehicle, target)
        end
        placeEntity(ped, target)

        Access.VerifyEjection(source, zoneId, target, attempt + 1)
    end)
end

local function clearBurn(record)
    record.lastBurnAt = nil
    record.lastBurnWarnAt = nil
    record.burnDown = nil
    record.burnLastHealth = nil
    record.burnIgnored = nil
end

Access.ClearBurn = clearBurn

function Access.ApplyCooldownBurn(source, record, zoneId, remainingMs)
    local cfg = Config.Cooldown.damage
    local now = RZ.Mono()

    if record.lastBurnAt and (now - record.lastBurnAt) < (cfg.intervalMs or 1000) then return end
    record.lastBurnAt = now

    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return end

    local health = GetEntityHealth(ped)
    if health <= 0 or RZ.Medical.IsDeadOrLastStand(source) then
        record.burnDown = true
        return
    end

    if record.burnDown and Config.Cooldown.blockReviveWhileOnCooldown then
        TriggerClientEvent(RZ.Event.COOLDOWN_BURN, source, { kill = true })
        RZ.Notify(source, 'access.cooldown_revive_blocked',
            { RZ.Util.FormatDuration(remainingMs or 0) }, 'error')
        RZ.Log.InvalidEntry(source, zoneId, 'revived while locked out — put back down')
        return
    end

    if record.burnLastHealth and health >= record.burnLastHealth then
        record.burnIgnored = (record.burnIgnored or 0) + 1
        if record.burnIgnored >= (cfg.ejectAfterIgnoredTicks or 3) then
            RZ.Log.Suspicious(source, 'cooldownBurn',
                ('health did not fall across %d burn ticks — ejecting instead'):format(record.burnIgnored))
            clearBurn(record)
            Access.Eject(source, zoneId, RZ.Reject.COOLDOWN, remainingMs)
            return
        end
    else
        record.burnIgnored = 0
    end

    record.burnLastHealth = health
    TriggerClientEvent(RZ.Event.COOLDOWN_BURN, source, { amount = cfg.amount or 20 })

    local warnEvery = cfg.warnIntervalMs or 3000
    if not record.lastBurnWarnAt or (now - record.lastBurnWarnAt) >= warnEvery then
        record.lastBurnWarnAt = now
        RZ.Notify(source, 'access.cooldown_burn',
            { RZ.Util.FormatDuration(remainingMs or 0) }, 'error')
    end

    if record.ejectCount == 0 then
        record.ejectCount = 1
        RZ.Log.InvalidEntry(source, zoneId, 'cooldown (burning)')
    end
end

local function pedAlive(source)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 or GetEntityHealth(ped) <= 0 then return false end
    return not RZ.Medical.IsDeadOrLastStand(source)
end

function Access.Evaluate(source)
    local record = Store.Get(source)
    if not record then return end

    local coords = coordsOf(source)
    if not coords then return end

    if record.state == RZ.State.ELIMINATED then
        RZ.Elimination.WatchEliminated(source, record)
    end

    local zoneId = Access.ResolveZone(coords)
    if zoneId then
        record.gangId = RZ.Gangs.GetStableGangId(source)
    end

    if not zoneId then
        record.lastOutsideCoords = coords
        record.ejectCount = 0
        clearBurn(record)

        -- A downed player who crawls over the line, or a corpse that ragdolls across it, is
        -- still in that zone's fight: keep the zone so the bleed-out, revive, DNA and reboot
        -- all still resolve. Dropping it here used to strand them downed forever.
        if IN_FLOW[record.state] then
            if record.zoneId then RZ.Knock.ServerHealthWatch(source, record, record.zoneId) end
            return
        end

        record.gangId = nil
        record.groupId = nil
        record.groupType = nil
        if record.zoneId ~= nil then
            Store.SetZone(source, nil)
            RZ.Sync.PushWorld(source)
        end
        -- RESPAWN_BLOCKED stays as it is out here: a teammate may still be carrying their
        -- DNA to a station. The in-zone gate below lets them back in once allowed.
        if record.state == RZ.State.ALIVE then
            Store.SetState(source, RZ.State.OUTSIDE, 'left zone')
        end
        return
    end

    if not RZ.Schedule.IsOpen(zoneId) then
        if IN_FLOW[record.state] then
            RZ.Knock.ReleaseForIneligibility(source, RZ.Reject.ZONE_CLOSED)
        end
        if record.zoneId ~= nil then Store.SetZone(source, nil) end
        if record.state == RZ.State.ALIVE or record.state == RZ.State.RESPAWN_BLOCKED then
            Store.SetState(source, RZ.State.OUTSIDE, 'zone closed')
        end
        record.groupId = nil
        record.groupType = nil
        record.ejectCount = 0
        clearBurn(record)
        record.lastOutsideCoords = coords
        return
    end

    local eligible, reason, _, cooldownRemaining = Access.CheckEligibility(source, zoneId)

    if not eligible then
        if IN_FLOW[record.state] then
            RZ.Knock.ReleaseForIneligibility(source, reason)
        end
        local burn = Config.Cooldown.damage
        if reason == RZ.Reject.COOLDOWN and burn and burn.enabled and not burn.ejectInstead then
            Access.ApplyCooldownBurn(source, record, zoneId, cooldownRemaining)
            return
        end
        Access.Eject(source, zoneId, reason, cooldownRemaining)
        return
    end

    record.ejectCount = 0
    clearBurn(record)
    if record.zoneId ~= zoneId then Store.SetZone(source, zoneId) end

    local group = RZ.Groups.GetPlayerGroup(source, zoneId)
    record.groupId = group and group.id or nil
    record.groupType = group and group.type or nil

    -- Only a living ped joins the fight. A body carried or ragdolled in from outside stays a
    -- spectator until it is alive, so death outside the zone can never become a free knock.
    if (record.state == RZ.State.OUTSIDE or record.state == RZ.State.RESPAWN_BLOCKED)
        and pedAlive(source) then
        Store.SetState(source, RZ.State.ALIVE, 'entered zone')
        RZ.Sync.PushWorld(source)
    end

    RZ.Knock.ServerHealthWatch(source, record, zoneId)
end

local tickRunning = false

local function tickInterval()
    local interval = Config.Validation.intervalMs

    for _, zone in pairs(Config.Zones) do
        local wanted = zone.enabled and zone.boundary.serverValidationInterval
        if wanted and wanted < interval then interval = wanted end
    end

    return interval
end

local function tickPlayer(source)
    if not Store.Get(source) then
        local identity = RZ.Fw.Identity(source)
        if identity then
            Store.Track(source, identity)
            RZ.Log.Debug(('adopted untracked player %s'):format(source))
            RZ.Sync.PushWorld(source)
        end
    end

    if Store.Get(source) then
        local ok, err = pcall(Access.Evaluate, source)
        if not ok then
            RZ.Log.Integration('access', ('evaluate(%s) error: %s'):format(source, tostring(err)))
        end
        Access.RefreshVisibility(source)
    end
end

function Access.StartValidationLoop()
    if tickRunning then return end
    tickRunning = true

    CreateThread(function()
        while tickRunning do
            local interval = tickInterval()

            for _, playerId in ipairs(GetPlayers()) do
                local source = tonumber(playerId)
                if source then tickPlayer(source) end
            end

            for source in pairs(Store.All()) do
                if GetPlayerName(source) == nil then
                    RZ.Cleanup.Player(source, 'missing')
                end
            end

            Wait(interval)
        end
    end)
end

function Access.StopValidationLoop()
    tickRunning = false
end

function Access.EvacuateZone(zoneId)
    local released = 0

    for source, record in pairs(Store.All()) do
        if record.zoneId == zoneId then
            if IN_FLOW[record.state] then
                RZ.Knock.ReleaseForIneligibility(source, RZ.Reject.ZONE_CLOSED)
            end

            RZ.Notify(source, 'zone.closed_broadcast', nil, 'inform')
            released = released + 1

            Store.ForceState(source, RZ.State.OUTSIDE, 'zone closed')
            Store.SetZone(source, nil)
            record.groupId = nil
            record.groupType = nil
        end
    end

    if released > 0 then
        RZ.Log.Info(('zone %s closed — released %d player(s) in place (no ejections)')
            :format(zoneId, released))
    end
end

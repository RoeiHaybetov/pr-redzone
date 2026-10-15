RZ = RZ or {}
RZ.Elimination = {}

local Elim = RZ.Elimination
local Store = RZ.Store

-- Dying inside an open zone takes a player out of the fight. The server's own death script
-- (or plain GTA) handles the death itself; this only notes where and when it happened, so
-- the loot bag and the respawn lockout know about it.

-- A player back on their feet this close to where they fell, still inside the zone, was
-- picked up where they lay (EMS, a medkit, /revive) rather than respawned somewhere else.
local REVIVED_IN_PLACE_M = 25.0

-- Death scripts resurrect the ped for their last-stand animation a moment before they
-- publish the down state, so one living sample is not yet a return.
local ALIVE_CONFIRM_MS = 3000

local function isDown(source, ped)
    return GetEntityHealth(ped) <= 0 or RZ.Medical.IsDeadOrLastStand(source)
end

function Elim.Clear(record)
    record.eliminationZoneId = nil
    record.deathCoords = nil
    record.aliveSince = nil
end

function Elim.OnDeath(source, record, zoneId, cause)
    if record.state ~= RZ.State.ALIVE then return false end
    if not record.groupId or not RZ.Schedule.IsOpen(zoneId) then return false end
    if not Store.SetState(source, RZ.State.ELIMINATED, cause) then return false end

    local coords = RZ.Access.CoordsOf(source)
    record.eliminationZoneId = zoneId
    record.deathCoords = coords and vec3(coords.x, coords.y, coords.z) or nil
    record.aliveSince = nil
    RZ.LootBag.SnapshotOnElimination(source, zoneId)
    RZ.Log.Elimination(source, zoneId)
    RZ.Notify(source, 'death.eliminated', nil, 'error')
    return true
end

function Elim.WatchAlive(source, record, zoneId)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return end
    if isDown(source, ped) then Elim.OnDeath(source, record, zoneId, 'died in zone') end
end

-- The death script's respawn hook ends an elimination straight away. This catches every
-- other way back: a revive where they fell keeps them in the fight, anything else (a
-- hospital respawn with no hook we know, /revive somewhere else) counts as a respawn.
function Elim.WatchEliminated(source, record)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return end

    if isDown(source, ped) then
        record.aliveSince = nil
        return
    end

    local now = RZ.Mono()
    record.aliveSince = record.aliveSince or now
    if (now - record.aliveSince) < ALIVE_CONFIRM_MS then return end

    local zoneId = record.eliminationZoneId or record.zoneId
    local coords = RZ.Access.CoordsOf(source)
    if zoneId and coords and record.deathCoords and RZ.Schedule.IsOpen(zoneId)
        and RZ.Geo.Dist3D(coords, record.deathCoords) <= REVIVED_IN_PLACE_M
        and RZ.Access.IsInsideZone(source, zoneId) then
        if Store.SetState(source, RZ.State.ALIVE, 'revived where they fell') then
            Elim.Clear(record)
            RZ.LootBag.ClearSnapshot(source)
        end
        return
    end

    RZ.Cleanup.Respawned(source, 'alive again away from where they died')
end

-- Who was in a fight and when: the combat-log check on disconnect reads these.
local function playerFromNetId(netId)
    if type(netId) ~= 'number' or netId == 0 then return nil end
    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end
    if GetEntityType(entity) ~= 1 or not IsPedAPlayer(entity) then return nil end
    local owner = NetworkGetEntityOwner(entity)
    if type(owner) ~= 'number' or owner <= 0 or GetPlayerPed(owner) ~= entity then return nil end
    return owner
end

AddEventHandler('weaponDamageEvent', function(sender, data)
    if type(data) ~= 'table' then return end

    local netId = data.hitGlobalId
    if (not netId or netId == 0) and type(data.hitGlobalIds) == 'table' then netId = data.hitGlobalIds[1] end
    local victim = playerFromNetId(netId)
    if not victim or victim == sender then return end

    local now = RZ.Mono()
    local attacker = type(sender) == 'number' and Store.Get(sender) or nil
    if attacker then attacker.lastAttackAt = now end

    local record = Store.Get(victim)
    if record then record.lastHitAt = now end
end)

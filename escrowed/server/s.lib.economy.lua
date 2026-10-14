RZ = RZ or {}
RZ.Crate = {}
RZ.Seller = {}
RZ.LootBag = {}

local Crate = RZ.Crate
local Bag = RZ.LootBag

math.randomseed(os.time() ~ GetGameTimer())
for _ = 1, 8 do math.random() end

local function deny(source, key)
    RZ.Notify(source, key, nil, 'error')
    return false
end

local function checkPresence(source, zoneId, record)
    if record.state ~= RZ.State.ALIVE then return 'error.not_alive' end
    if not RZ.Access.IsInsideZone(source, zoneId) then return 'error.too_far' end
end

local function checkDistance(source, coords, interactionDistance, action, what)
    local point = vec3(coords.x, coords.y, coords.z)
    if RZ.Access.DistanceTo(source, point) > interactionDistance + 1.5 then
        RZ.Log.Suspicious(source, action, 'too far from the ' .. what)
        return 'error.too_far'
    end
end

local function eachInZone(zoneId, fn)
    for source, record in pairs(RZ.Store.All()) do
        if record.zoneId == zoneId then fn(source, record) end
    end
end

local state = {}
local loopRunning = false

local function lockKey(zoneId)
    return 'crate:' .. tostring(zoneId)
end

local function intervalMs(zone)
    return (zone and zone.crate.spawnInterval or 300) * 1000
end

local function freshState(zoneId)
    return { remainingMs = intervalMs(Config.Zones[zoneId]), lastTick = RZ.Mono(), active = false }
end

local function getState(zoneId)
    local existing = state[zoneId]
    if not existing then
        existing = freshState(zoneId)
        state[zoneId] = existing
    end
    return existing
end

function Crate.GetPublicState(zoneId)
    local s = state[zoneId]
    if not s or not s.active then return nil end
    local crate = Config.Zones[zoneId].crate
    local c = crate.coords
    return { x = c.x, y = c.y, z = c.z, w = c.w, prop = crate.prop, blipEnabled = crate.blipEnabled }
end

function Crate.GetTimerState(zoneId)
    local s = getState(zoneId)
    local groupCount = #RZ.Groups.GetAliveGroupsInZone(zoneId)
    return {
        active = s.active,
        remainingMs = math.max(0, s.remainingMs),
        intervalMs = intervalMs(Config.Zones[zoneId]),
        running = (not s.active) and groupCount == 1,
        groupCount = groupCount,
    }
end

function Crate.Broadcast(zoneId)
    local public = Crate.GetPublicState(zoneId)
    eachInZone(zoneId, function(source)
        TriggerClientEvent(RZ.Event.SYNC_WORLD, source, { crate = public or false })
    end)
end

local function spawnCrate(zoneId, controllingGroupId)
    local s = getState(zoneId)
    if s.active then return end

    s.active = true
    s.controllingGroupId = controllingGroupId
    s.remainingMs = 0
    RZ.Log.CrateSpawn(zoneId, controllingGroupId)
    Crate.Broadcast(zoneId)
    eachInZone(zoneId, function(source)
        RZ.Notify(source, 'crate.available', nil, 'inform')
    end)
end

function Crate.Despawn(zoneId, resetTimer)
    local s = getState(zoneId)
    if not s.active and not resetTimer then return end

    local zone = Config.Zones[zoneId]
    s.active = false
    s.controllingGroupId = nil

    if resetTimer then
        s.remainingMs = zone.crate.spawnInterval * 1000
        s.lastTick = RZ.Mono()
    end
    Crate.Broadcast(zoneId)
end

function Crate.StartLoop()
    if loopRunning then return end
    loopRunning = true

    CreateThread(function()
        while loopRunning do
            for zoneId, zone in pairs(Config.Zones) do
                if zone.enabled and RZ.Schedule.IsOpen(zoneId) then
                    local s = getState(zoneId)
                    local now = RZ.Mono()
                    local delta = now - s.lastTick
                    s.lastTick = now

                    if delta < 0 then delta = 0 end
                    if delta > 2000 then delta = 2000 end

                    if not s.active then
                        local controlling, groupId = RZ.Groups.IsExactlyOneGroupControlling(zoneId)
                        if controlling then
                            s.remainingMs = s.remainingMs - delta
                            if s.remainingMs <= 0 then spawnCrate(zoneId, groupId) end
                        end
                    end
                elseif zone.enabled then
                    getState(zoneId).lastTick = RZ.Mono()
                end
            end

            Wait(1000)
        end
    end)
end

function Crate.StopLoop()
    loopRunning = false
end

function Crate.PruneZone(zoneId)
    state[zoneId] = nil
    RZ.Lock.Release(lockKey(zoneId))
end

function Crate.Reset(zoneId)
    if not Config.Zones[zoneId] then return end
    state[zoneId] = freshState(zoneId)
    RZ.Lock.Release(lockKey(zoneId))
    Crate.Broadcast(zoneId)
end

function Crate.Debug(zoneId)
    local s = getState(zoneId)
    local groups, counts = RZ.Groups.GetAliveGroupsInZone(zoneId)
    return {
        active = s.active,
        remainingMs = s.remainingMs,
        groupCount = #groups,
        groups = groups,
        countsByGroup = counts,
    }
end

lib.callback.register(RZ.Callback.LOOT_CRATE, function(source)
    if not RZ.Guard(source, 'lootCrate') then return false end

    local record = RZ.Store.Get(source)
    if not record or not record.zoneId then return false end

    local zoneId = record.zoneId
    local zone = Config.Zones[zoneId]
    if not zone then return false end

    if not RZ.Schedule.IsOpen(zoneId) then return deny(source, 'zone.closed') end
    local s = getState(zoneId)
    if not s.active then return deny(source, 'crate.already_taken') end
    local reject = checkPresence(source, zoneId, record)
    if reject then return deny(source, reject) end
    if not RZ.Groups.GetStableGroupId(source, zoneId) then return deny(source, 'error.generic') end
    reject = checkDistance(source, zone.crate.coords, zone.crate.interactionDistance, 'lootCrate', 'crate')
    if reject then return deny(source, reject) end
    if not RZ.Lock.Acquire(lockKey(zoneId), source, 5000) then
        return deny(source, 'crate.already_taken')
    end

    local function release(key)
        RZ.Lock.Release(lockKey(zoneId), source)
        return deny(source, key)
    end

    if not s.active then return release('crate.already_taken') end
    if not RZ.Inv.CanCarry(source, zone.crate.rewardItem, zone.crate.rewardAmount) then
        return release('crate.inventory_full')
    end
    if not RZ.Inv.Add(source, zone.crate.rewardItem, zone.crate.rewardAmount) then
        return release('crate.inventory_full')
    end

    Crate.Despawn(zoneId, true)
    RZ.Lock.Release(lockKey(zoneId), source)

    RZ.Log.CrateLooted(source, zoneId)
    RZ.Notify(source, 'crate.looted', nil, 'success')
    return true
end)

local function saleLockKey(source)
    return 'sale:' .. tostring(source)
end

local function buildRewards(groupType)
    local rewards = {}
    local isSquad = groupType == RZ.Groups.TYPE_SOLO_SQUAD

    if (not isSquad) or Config.SoloSquads.allowMaterialsReward then
        for i = 1, #Config.Rewards.materials do
            local mat = Config.Rewards.materials[i]
            rewards[#rewards + 1] = { item = mat.item, amount = mat.amount }
        end
    end

    local allowCard = (not isSquad) or Config.SoloSquads.allowKeycardReward
    local wonCard = false
    if allowCard and Config.Rewards.keycardChancePercent > 0 then
        wonCard = math.random(1, 100) <= Config.Rewards.keycardChancePercent
        if wonCard then
            rewards[#rewards + 1] = { item = Config.Items.keycard, amount = Config.Rewards.keycardAmount }
        end
    end

    return rewards, wonCard
end

lib.callback.register(RZ.Callback.SELL_PACKAGE, function(source)
    if not RZ.Guard(source, 'sellPackage') then return false end

    if not RZ.Lock.Acquire(saleLockKey(source), source, 10000) then
        return deny(source, 'error.locked')
    end

    local function fail(key, logDetail)
        RZ.Lock.Release(saleLockKey(source), source)
        if logDetail then
            RZ.Log.Debug(('sale rejected for %s: %s'):format(RZ.Log.Who(source), logDetail))
        end
        return deny(source, key)
    end

    local record = RZ.Store.Get(source)
    if not record or not record.zoneId then return fail('error.generic', 'not in a zone') end

    local zoneId = record.zoneId
    local zone = Config.Zones[zoneId]
    if not zone then return fail('error.generic', 'unknown zone') end

    if not RZ.Schedule.IsOpen(zoneId) then return fail('zone.closed', 'zone closed') end
    local reject = checkPresence(source, zoneId, record)
    if reject then
        return fail(reject, reject == 'error.not_alive' and 'not alive' or 'outside the zone')
    end

    reject = checkDistance(source, zone.seller.coords, zone.seller.interactionDistance, 'sellPackage', 'seller')
    if reject then return fail(reject, 'too far from the seller') end
    local group = RZ.Groups.GetPlayerGroup(source, zoneId)
    if not group then return fail('error.generic', 'no combat group') end
    local packageItem = RZ.Util.PackageFor(zoneId)
    if RZ.Inv.Count(source, packageItem) < 1 then
        return fail('seller.missing_package', 'no package')
    end
    local rewards, wonCard = buildRewards(group.type)

    local canCarry, blockingItem = RZ.Inv.CanCarryAll(source, rewards)
    if not canCarry then
        return fail('seller.inventory_full', 'cannot carry ' .. tostring(blockingItem))
    end
    if not RZ.Inv.Remove(source, packageItem, 1) then
        return fail('seller.missing_package', 'package removal failed')
    end
    local granted, failedItem, grantedList = RZ.Inv.GrantAll(source, rewards)
    if not granted then
        if not RZ.Inv.Add(source, packageItem, 1) then
            RZ.Log.Integration('seller',
                ('CRITICAL: could not return the package to %s after a failed payout'):format(RZ.Log.Who(source)))
        end
        RZ.Log.Integration('seller', ('payout failed on %s, sale rolled back'):format(tostring(failedItem)))
        return fail('seller.failed', 'payout failed')
    end

    RZ.Lock.Release(saleLockKey(source), source)

    RZ.Log.PackageSold(source, zoneId, group.id)
    RZ.Log.Rewards(source, grantedList)
    if wonCard then RZ.Log.Card(source, Config.Items.keycard) end

    RZ.Notify(source, 'seller.rewards', nil, 'success')
    if wonCard then RZ.Notify(source, 'seller.card_bonus', nil, 'success') end

    return true
end)

local active = {}
local expiryRunning = false

local PARTICIPANT = {
    [RZ.State.ALIVE] = true, [RZ.State.DOWNED] = true, [RZ.State.BEING_REVIVED] = true,
    [RZ.State.ELIMINATED] = true, [RZ.State.BEING_REBOOTED] = true,
}

local function skip(source, trigger, reason)
    RZ.Log.LootBagSkip(source, trigger, reason)
    return nil
end

local function bagList()
    local list = {}
    for dropId, entry in pairs(active) do
        if entry.coords then
            list[#list + 1] = { id = dropId, coords = entry.coords }
        end
    end
    return list
end

function Bag.Broadcast()
    TriggerClientEvent(RZ.Event.SYNC_BAGS, -1, bagList())
end

function Bag.PushTo(source)
    TriggerClientEvent(RZ.Event.SYNC_BAGS, source, bagList())
end

function Bag.PruneZone(zoneId)
    local removed = 0
    for dropId, entry in pairs(active) do
        if entry.zoneId == zoneId then
            RZ.Inv.RemoveDrop(dropId)
            active[dropId] = nil
            removed = removed + 1
        end
    end
    if removed > 0 then
        Bag.Broadcast()
        RZ.Log.Info(('loot bags: removed %d bag(s) belonging to deleted zone %s'):format(removed, zoneId))
    end
end

local function isWeapon(name)
    if type(name) ~= 'string' then return false end
    local ok, def = pcall(RZ.Inv.GetItem, name)
    if ok and type(def) == 'table' and def.weapon then return true end
    return name:upper():sub(1, 7) == 'WEAPON_'
end

Bag.IsWeapon = isWeapon

local function readLoadout(source)
    local hotbarSlots = Config.LootBag.hotbarSlots or 5
    local takeWeapons = Config.LootBag.takeWeaponsAnywhere ~= false

    local ok, items = pcall(RZ.Inv.GetAllItems, source)
    if not ok or type(items) ~= 'table' then
        RZ.Log.Integration('lootbag',
            ('could not read the inventory of %s: %s'):format(source, tostring(items)))
        return {}, false
    end

    local entries, hasWeapon = {}, false
    for slot, slotData in pairs(items) do
        if type(slotData) == 'table' and slotData.name then
            local weapon = isWeapon(slotData.name)
            local inHotbar = type(slot) == 'number' and slot <= hotbarSlots
            if inHotbar or (weapon and takeWeapons) then
                entries[#entries + 1] = {
                    item = slotData.name, count = slotData.count or 1,
                    metadata = slotData.metadata, slot = slot,
                }
                if weapon then hasWeapon = true end
            end
        end
    end

    table.sort(entries, function(a, b) return a.slot < b.slot end)
    return entries, hasWeapon
end

function Bag.WasInFight(record)
    if not record then return false, nil, 'not tracked' end

    local zoneId = record.zoneId or record.eliminationZoneId
    if not zoneId then return false, nil, 'not in a RedZone' end
    if not RZ.Schedule.IsOpen(zoneId) then return false, zoneId, 'zone is closed' end

    if not PARTICIPANT[record.state] then
        return false, zoneId, ('state is "%s", not a live participant'):format(tostring(record.state))
    end

    return true, zoneId
end

local function isEligible(record)
    if not Config.LootBag.enabled then return false, 'disabled' end
    if not record then return false, 'not tracked' end

    local zoneId = record.zoneId or record.eliminationZoneId
    if Config.LootBag.zoneOnly then
        if not zoneId then return false, 'not in a RedZone' end
        if not RZ.Schedule.IsOpen(zoneId) then return false, 'zone is closed' end
    end

    return true, nil, zoneId
end

function Bag.SnapshotOnElimination(source, zoneId)
    if not Config.LootBag.enabled then return end

    local record = RZ.Store.Get(source)
    if not record then return end
    local entries, hasWeapon = readLoadout(source)
    if #entries == 0 then
        record.bagSnapshot = nil
        RZ.Log.Debug(('loot bag: %s died carrying nothing worth taking, nothing to note'):format(source))
        return
    end

    record.bagSnapshot = { entries = entries, hasWeapon = hasWeapon, zoneId = zoneId }
    RZ.Log.Debug(('loot bag: noted %d item(s) for %s at death (weapon: %s)')
        :format(#entries, source, tostring(hasWeapon)))
end

function Bag.ClearSnapshot(source)
    local record = RZ.Store.Get(source)
    if record then record.bagSnapshot = nil end
end

local function collect(source, entries)
    local taken = {}
    for i = 1, #entries do
        local e = entries[i]
        local ok, slotData = pcall(RZ.Inv.GetSlot, source, e.slot)
        local stillHeld = ok and type(slotData) == 'table' and slotData.name == e.item

        if not stillHeld then
            taken[#taken + 1] = { e.item, e.count, e.metadata }
        elseif RZ.Inv.Remove(source, e.item, e.count, nil, e.slot) then
            taken[#taken + 1] = { e.item, e.count, e.metadata }
        else
            RZ.Log.Debug(('loot bag: could not remove %s x%d from slot %d, leaving it with them')
                :format(e.item, e.count, e.slot))
        end
    end
    return taken
end

function Bag.Drop(source, coords, zoneId, reason, snapshot)
    local invBackend = RZ.Inv.Backend()
    if not RZ.Inv.Caps.drops then
        return skip(source, reason,
            ('%s has no drop inventories, so a bag cannot be created — loot bags require ox_inventory. Nothing was taken off the player.')
            :format(invBackend == 'ox' and 'ox_inventory'
                or invBackend == 'qb' and 'qb-inventory'
                or 'the framework inventory'))
    end
    local entries, hasWeapon
    if snapshot then
        entries, hasWeapon = snapshot.entries, snapshot.hasWeapon
    else
        entries, hasWeapon = readLoadout(source)
    end

    if #entries == 0 then
        return skip(source, reason,
            ('nothing to take — hotbar slots 1-%d are empty and no weapon is stashed elsewhere')
            :format(Config.LootBag.hotbarSlots or 5))
    end
    if Config.LootBag.requireWeapon and not hasWeapon then
        return skip(source, reason,
            ('no weapon among the %d item(s) carried (requireWeapon is on)'):format(#entries))
    end
    local taken = collect(source, entries)
    if #taken == 0 then
        return skip(source, reason,
            ('none of the %d item(s) could be taken off the player'):format(#entries))
    end
    local ok, dropId = pcall(RZ.Inv.CreateDrop, 'Loot Bag', taken, vec3(coords.x, coords.y, coords.z),
        math.max(Config.LootBag.slots or 5, #taken), Config.LootBag.maxWeight, nil, Config.LootBag.prop)
    if not ok or not dropId then
        RZ.Log.Integration('lootbag', 'CustomDrop failed, returning items: ' .. tostring(dropId))

        local lost = {}
        for i = 1, #taken do
            local t = taken[i]
            if not RZ.Inv.Add(source, t[1], t[2], t[3]) then
                lost[#lost + 1] = ('%s x%s'):format(tostring(t[1]), tostring(t[2]))
            end
        end

        if #lost > 0 then
            RZ.Log.Integration('lootbag',
                ('ITEMS LOST: %s was %s and %d of %d line(s) could not be returned after the failed %s bag — %s')
                :format(tostring(source),
                    GetPlayerName(source) == nil and 'already gone' or 'still connected',
                    #lost, #taken, reason, table.concat(lost, ', ')))
        end

        return nil
    end

    active[dropId] = {
        expiresAt = RZ.Mono() + (Config.LootBag.despawnMinutes * 60000),
        zoneId = zoneId,
        coords = vec3(coords.x, coords.y, coords.z),
    }
    Bag.Broadcast()
    RZ.Log.LootBag(source, zoneId, reason, #taken)
    return dropId
end

function Bag.OnRespawn(source)
    if not Config.LootBag.onRespawn then
        return skip(source, 'respawn', 'Config.LootBag.onRespawn is off')
    end
    local record = RZ.Store.Get(source)
    local ok, reason, zoneId = isEligible(record)
    if not ok then return skip(source, 'respawn', tostring(reason)) end
    local snapshot = record.bagSnapshot
    record.bagSnapshot = nil

    if not snapshot then
        return skip(source, 'respawn',
            'nothing was noted at their death (empty hotbar, or they died before this was installed)')
    end
    local coords = record.deathCoords or RZ.Access.CoordsOf(source)
    if not coords then
        return skip(source, 'respawn', 'no death coordinates and no live position')
    end
    Bag.Drop(source, coords, zoneId or snapshot.zoneId, 'respawn', snapshot)
end

function Bag.OnDisconnect(source)
    if not Config.LootBag.onDisconnect then
        return skip(source, 'disconnect', 'Config.LootBag.onDisconnect is off')
    end
    local record = RZ.Store.Get(source)
    local zoneId, reason

    if Config.LootBag.zoneOnly then
        local inFight
        inFight, zoneId, reason = Bag.WasInFight(record)
        if not inFight then return skip(source, 'disconnect', tostring(reason)) end
    else
        local ok
        ok, reason, zoneId = isEligible(record)
        if not ok then return skip(source, 'disconnect', tostring(reason)) end
    end
    local coords = RZ.Access.CoordsOf(source)
    if not coords then
        return skip(source, 'disconnect', 'no live position (they were already gone)')
    end
    Bag.Drop(source, coords, zoneId, 'disconnect')
end

function Bag.StartExpiryLoop()
    if expiryRunning then return end
    expiryRunning = true

    CreateThread(function()
        while expiryRunning do
            Wait(30000)
            local now = RZ.Mono()
            local removed = false
            for dropId, entry in pairs(active) do
                if now >= entry.expiresAt then
                    active[dropId] = nil
                    removed = true
                    pcall(RZ.Inv.RemoveDrop, dropId)
                    RZ.Log.Debug(('loot bag %s expired'):format(dropId))
                end
            end
            if removed then Bag.Broadcast() end
        end
    end)
end

function Bag.StopExpiryLoop()
    expiryRunning = false
end

function Bag.RemoveAll()
    for dropId in pairs(active) do
        pcall(RZ.Inv.RemoveDrop, dropId)
    end
    active = {}
    Bag.Broadcast()
end

function Bag.Count()
    local n = 0
    for _ in pairs(active) do n = n + 1 end
    return n
end

RZ = RZ or {}
RZ.Fw = {}
RZ.Gangs = {}
RZ.Inv = {}
RZ.Medical = {}

local Fw = RZ.Fw
local Gangs = RZ.Gangs
local Inv = RZ.Inv
local Medical = RZ.Medical

local NO_GANG = 'none'

local flavour = nil
local core = nil
local warnedBadFramework = false

local function started(resource)
    local state = GetResourceState(resource)
    return state == 'started' or state == 'starting'
end

local function fetchQbCore()
    local ok, obj = pcall(function() return exports['qb-core']:GetCoreObject() end)
    return ok and obj or nil
end

local function qbxUsable()
    local ok, jobs = pcall(function() return exports.qbx_core:GetJobs() end)
    return ok and type(jobs) == 'table'
end

local function fetchEsx()
    local ok, obj = pcall(function() return exports['es_extended']:getSharedObject() end)
    if ok and type(obj) == 'table' then return obj end

    local legacy
    pcall(function() TriggerEvent('esx:getSharedObject', function(o) legacy = o end) end)
    return type(legacy) == 'table' and legacy or nil
end

local EXPLICIT_FLAVOUR = { qbx = true, qb = true, esx = true, standalone = true }

local FLAVOUR_LABEL = {
    qbx = 'qbx_core',
    qb = 'qb-core',
    esx = 'es_extended',
    standalone = 'standalone',
}

local function resolve()
    if flavour then
        if flavour == 'qb' and not core then core = fetchQbCore() end
        if flavour == 'esx' and not core then core = fetchEsx() end
        return flavour
    end

    local forced = Config.Framework
    if type(forced) == 'string' and forced ~= '' and forced ~= 'auto' and not EXPLICIT_FLAVOUR[forced] then
        if not warnedBadFramework then
            warnedBadFramework = true
            print(('^1[pr-redzone] Config.Framework = %q is not a valid value. Use auto, qbx, qb, esx or standalone. Falling back to auto-detection.^0')
                :format(forced))
        end
        forced = 'auto'
    end

    if type(forced) == 'string' and forced ~= '' and forced ~= 'auto' then
        if forced == 'qb' then core = fetchQbCore() end
        if forced == 'esx' then core = fetchEsx() end
        flavour = forced
        return flavour
    end

    if started('qbx_core') then
        if GetResourceState('qbx_core') == 'started' or qbxUsable() then flavour = 'qbx' end
    elseif started('qb-core') then
        core = fetchQbCore()
        if core then flavour = 'qb' end
    elseif started('es_extended') then
        core = fetchEsx()
        if core then flavour = 'esx' end
    end

    return flavour or 'standalone'
end

AddEventHandler('QBCore:Server:UpdateObject', function()
    if flavour ~= 'qb' then return end
    core = fetchQbCore() or core
end)

function Fw.Flavour()
    return resolve()
end

function Fw.Describe()
    return FLAVOUR_LABEL[resolve()] or 'standalone'
end

function Fw.IsStandalone()
    return resolve() == 'standalone'
end

local GET_PLAYER = {
    qbx = function(source) return exports.qbx_core:GetPlayer(source) end,
    qb = function(source) return exports['qb-core']:GetPlayer(source) end,
    esx = function(source) return core and core.GetPlayerFromId(source) end,
}

function Fw.GetPlayer(source)
    local fn = GET_PLAYER[resolve()]
    if not fn then return nil end
    local ok, player = pcall(fn, source)
    if not ok then return nil end
    return player
end

local GET_BY_IDENTITY = {
    qbx = function(identity) return exports.qbx_core:GetPlayerByCitizenId(identity) end,
    qb = function(identity) return exports['qb-core']:GetPlayerByCitizenId(identity) end,
    esx = function(identity) return core and core.GetPlayerFromIdentifier(identity) end,
}

function Fw.GetPlayerByIdentity(identity)
    if type(identity) ~= 'string' then return nil end
    local fn = GET_BY_IDENTITY[resolve()]
    if not fn then return nil end
    local ok, player = pcall(fn, identity)
    if not ok then return nil end
    return player
end

Fw.GetPlayerByCitizenId = Fw.GetPlayerByIdentity

function Fw.Identity(source)
    local f = resolve()

    if f == 'standalone' then
        local license = GetPlayerIdentifierByType(source, 'license')
        return license and (license:gsub('^license:', '')) or nil
    end

    local player = Fw.GetPlayer(source)
    if not player then return nil end

    if f == 'esx' then return player.identifier end

    local data = player.PlayerData
    return data and data.citizenid or nil
end

function Fw.Name(source)
    local f = resolve()

    if f ~= 'standalone' then
        local player = Fw.GetPlayer(source)

        if player and f == 'esx' then
            local ok, name = pcall(function() return player.getName() end)
            if ok and type(name) == 'string' and name ~= '' then return name end
        elseif player and player.PlayerData then
            local info = player.PlayerData.charinfo
            if type(info) == 'table' and info.firstname then
                return ('%s %s'):format(info.firstname, info.lastname or '')
            end
        end
    end

    return GetPlayerName(source) or ('player:%s'):format(tostring(source))
end

function Fw.IsLoaded(source)
    if resolve() == 'standalone' then
        return GetPlayerName(source) ~= nil
    end
    return Fw.Identity(source) ~= nil
end

local function unaffiliated()
    return { name = NO_GANG, label = 'No Gang' }, true
end

function Fw.Gang(source)
    local f = resolve()

    if f == 'standalone' then
        if GetPlayerName(source) == nil then return nil, false end
        return unaffiliated()
    end

    local player = Fw.GetPlayer(source)
    if not player then return nil, false end

    if f == 'esx' then
        local job = player.job
        if type(job) ~= 'table' or type(job.name) ~= 'string' then return unaffiliated() end
        local excluded = Config.Gangs and Config.Gangs.notGangs
        if type(excluded) == 'table' then
            for i = 1, #excluded do
                if excluded[i] == job.name then return unaffiliated() end
            end
        end

        return { name = job.name, label = job.label or job.name }, true
    end

    local data = player.PlayerData
    if not data then return nil, false end
    return data.gang, true
end

local GET_GANG = {
    qbx = function(name)
        local ok, gang = pcall(function() return exports.qbx_core:GetGang(name) end)
        return ok and gang or nil
    end,
    qb = function(name)
        local shared = core and core.Shared
        local gangs = shared and shared.Gangs
        return gangs and gangs[name] or nil
    end,
    esx = function(name)
        return Fw.GetJobs()[name]
    end,
}

function Fw.GetGang(name)
    if type(name) ~= 'string' or name == '' then return nil end
    local fn = GET_GANG[resolve()]
    return fn and fn(name) or nil
end

local GET_JOBS = {
    qbx = function()
        local ok, jobs = pcall(function() return exports.qbx_core:GetJobs() end)
        return (ok and type(jobs) == 'table') and jobs or nil
    end,
    qb = function()
        local shared = core and core.Shared
        return shared and shared.Jobs or nil
    end,
    esx = function()
        if not core then return nil end
        local ok, jobs = pcall(function() return core.GetJobs() end)
        return (ok and type(jobs) == 'table') and jobs or nil
    end,
}

function Fw.GetJobs()
    local fn = GET_JOBS[resolve()]
    return fn and fn() or {}
end

local GET_ITEMS = {
    qbx = function()
        local ok, items = pcall(function() return exports.qbx_core:GetItems() end)
        return (ok and type(items) == 'table') and items or nil
    end,
    qb = function()
        local shared = core and core.Shared
        return shared and shared.Items or nil
    end,
}

function Fw.GetItems()
    local fn = GET_ITEMS[resolve()]
    return fn and fn() or {}
end

function Fw.Job(source)
    local f = resolve()
    if f == 'standalone' then return nil end

    local player = Fw.GetPlayer(source)
    if not player then return nil end

    if f == 'esx' then
        local job = player.job
        if type(job) ~= 'table' then return nil end
        return { name = job.name, type = nil, onduty = job.onDuty, grade = job.grade }
    end

    local data = player.PlayerData
    local job = data and data.job
    if type(job) ~= 'table' then return nil end

    local jobType = job.type
    if jobType == nil or jobType == '' or jobType == 'none' then
        local def = job.name and Fw.GetJobs()[job.name]
        if type(def) == 'table' and type(def.type) == 'string' and def.type ~= '' then
            jobType = def.type
        end
    end

    return { name = job.name, type = jobType, onduty = job.onduty, grade = job.grade }
end

function Fw.GetMeta(source, key)
    if resolve() == 'standalone' then return nil end
    local player = Fw.GetPlayer(source)
    local data = player and player.PlayerData
    local meta = data and data.metadata
    if type(meta) ~= 'table' then return nil end
    return meta[key]
end

function Fw.SetMeta(source, key, value)
    if resolve() == 'standalone' then return false end
    local player = Fw.GetPlayer(source)
    local fns = player and player.Functions
    if not fns or not fns.SetMetaData then return false end

    return (pcall(fns.SetMetaData, key, value))
end

local NOTIFY = {
    qbx = function(source, message, kind) exports.qbx_core:Notify(source, message, kind) end,
    qb = function(source, message, kind) exports['qb-core']:Notify(source, message, kind) end,
    esx = function(source, message) TriggerClientEvent('esx:showNotification', source, message) end,
}

function Fw.Notify(source, message, kind)
    kind = kind or 'inform'
    local fn = NOTIFY[resolve()]
    if fn and pcall(fn, source, message, kind) then return end

    TriggerClientEvent('ox_lib:notify', source, { description = message, type = kind })
end

local Has_PERMISSION = {
    qbx = function(source, permission)
        local ok, allowed = pcall(function() return exports.qbx_core:HasPermission(source, permission) end)
        if ok then return allowed == true end
        return nil
    end,
    qb = function(source, permission)
        local ok, allowed = pcall(function() return exports['qb-core']:HasPermission(source, permission) end)
        if ok then return allowed == true end
        return nil
    end,
    esx = function(source, permission)
        local player = Fw.GetPlayer(source)
        if not player then return nil end
        local ok, group = pcall(function() return player.getGroup() end)
        if ok and (group == permission or group == 'superadmin') then return true end
        return nil
    end,
}

function Fw.HasPermission(source, permission)
    local fn = Has_PERMISSION[resolve()]
    if fn then
        local decided = fn(source, permission)
        if decided ~= nil then return decided end
    end
    return IsPlayerAceAllowed(source, permission)
end

local function probeEsxPlayerShape()
    CreateThread(function()
        while true do
            Wait(5000)
            local players = GetPlayers()
            if #players > 0 then
                local probe = Fw.GetPlayer(tonumber(players[1]))
                if probe then
                    local bad = {}
                    if type(probe.identifier) ~= 'string' then bad[#bad + 1] = 'xPlayer.identifier' end
                    if type(probe.job) ~= 'table' then bad[#bad + 1] = 'xPlayer.job' end
                    if type(probe.getName) ~= 'function' then bad[#bad + 1] = 'xPlayer.getName()' end
                    if type(probe.getGroup) ~= 'function' then bad[#bad + 1] = 'xPlayer.getGroup()' end

                    if #bad > 0 then
                        print(('^1[pr-redzone] the ESX player object is missing: %s — the adapter will misbehave.^0')
                            :format(table.concat(bad, ', ')))
                    end
                    return
                end
            end
        end
    end)
end

CreateThread(function()
    Wait(0)

    local f = resolve()
    if f == 'standalone' and flavour == nil
        and (started('qbx_core') or started('qb-core') or started('es_extended')) then
        for _ = 1, 20 do
            Wait(500)
            f = resolve()
            if f ~= 'standalone' then break end
        end
    end

    local missing = {}

    if f == 'qb' then
        if not core then
            missing[#missing + 1] = 'qb-core:GetCoreObject() returned nothing'
        elseif type(core.Shared) ~= 'table' or type(core.Shared.Gangs) ~= 'table' then
            missing[#missing + 1] = 'QBCore.Shared.Gangs'
        end
    elseif f == 'esx' then
        if not core then
            missing[#missing + 1] = 'es_extended:getSharedObject() returned nothing'
        else
            for _, name in ipairs({ 'GetPlayerFromId', 'GetPlayerFromIdentifier', 'GetJobs' }) do
                if type(core[name]) ~= 'function' then missing[#missing + 1] = 'ESX.' .. name end
            end
        end

        probeEsxPlayerShape()

        local blocked = Config.BlockedJobs
        if blocked and type(blocked.types) == 'table' and #blocked.types > 0 then
            print('^3[pr-redzone] Config.BlockedJobs.types is set, but ESX jobs have no `type` field — it will never match. Use Config.BlockedJobs.names on ESX.^0')
        end
    end

    if #missing == 0 then
        local forcedTo = Config.Framework
        local how = EXPLICIT_FLAVOUR[forcedTo] and 'forced by Config.Framework' or 'auto-detected'
        print(('[pr-redzone] framework: %s (%s)'):format(Fw.Describe(), how))

        if f == 'standalone' then
            print('[pr-redzone] standalone: no gangs, so every player is Solo and the RedZone runs on Solo Squads.')
        end
        return
    end

    print(('^1[pr-redzone] resolved %s but these are missing: %s^0')
        :format(Fw.Describe(), table.concat(missing, ', ')))
    print('^1[pr-redzone] set Config.Framework explicitly, or report the above — the resource will misbehave until this is fixed.^0')
end)

function Gangs.GetPlayerGang(source)
    return RZ.Fw.Gang(source)
end

local function resolveGang(source)
    local gang, loaded = RZ.Fw.Gang(source)
    if not loaded then return nil, RZ.Reject.UNVERIFIABLE end
    if not gang or type(gang.name) ~= 'string' or gang.name == '' then
        return nil, RZ.Reject.UNVERIFIABLE
    end
    if gang.name == NO_GANG then return nil, RZ.Reject.SOLO end
    if not RZ.Fw.GetGang(gang.name) then return nil, RZ.Reject.INVALID_GANG end
    return gang.name, nil
end

function Gangs.GetStableGangId(source)
    return (resolveGang(source))
end

function Gangs.GetGangLabel(gangId)
    local gang = RZ.Fw.GetGang(gangId)
    return (gang and gang.label) or gangId
end

function Gangs.IsSolo(source)
    return resolveGang(source) == nil
end

function Gangs.IsValidGangMember(source)
    local gangId, reason = resolveGang(source)
    if gangId then return true, nil, gangId end
    return false, reason, nil
end

function Gangs.AreSameGang(sourceA, sourceB)
    local a = Gangs.GetStableGangId(sourceA)
    if not a then return false end
    local b = Gangs.GetStableGangId(sourceB)
    if not b then return false end
    return a == b
end

local updateCallbacks = {}

function Gangs.RegisterUpdateHandlers(callback)
    updateCallbacks[#updateCallbacks + 1] = callback
end

local function fireUpdate(source)
    for i = 1, #updateCallbacks do
        local ok, err = pcall(updateCallbacks[i], source)
        if not ok then
            RZ.Log.Integration('gangs', 'update callback error: ' .. tostring(err))
        end
    end
end

AddEventHandler('QBCore:Server:OnGangUpdate', function(source, _gang)
    if type(source) ~= 'number' then return end
    fireUpdate(source)
end)

AddEventHandler('qbx_core:server:onGangUpdate', function(_gangName, _gang)
    fireUpdate(nil)
end)

RegisterNetEvent('QBCore:Server:OnPlayerLoaded', function()
    local src = source
    if type(src) == 'number' and src > 0 then fireUpdate(src) end
end)

AddEventHandler('QBCore:Server:OnPlayerUnload', function(source)
    if type(source) == 'number' then fireUpdate(source) end
end)

local backend = nil

Inv.Caps = { metadata = false, drops = false }

local function invStarted(resource)
    return GetResourceState(resource) == 'started'
end

local function resolveInv()
    if backend then return backend end

    local forced = Config.Inventory
    if forced == 'ox' or forced == 'qb' or forced == 'esx' then
        backend = forced
    elseif invStarted('ox_inventory') then
        backend = 'ox'
    elseif invStarted('qb-inventory') then
        backend = 'qb'
    elseif RZ.Fw.Flavour() == 'esx' then
        backend = 'esx'
    else
        backend = 'ox'
    end

    Inv.Caps.metadata = backend == 'ox' or backend == 'qb'
    Inv.Caps.drops = backend == 'ox'

    return backend
end

function Inv.Backend()
    return resolveInv()
end

local INV = {
    ox = {
        label = 'ox_inventory',
        report = 'ox_inventory',
        canCarry = function(source, item, count, metadata)
            return exports.ox_inventory:CanCarryItem(source, item, count, metadata)
        end,
        count = function(source, item, metadata, strict)
            return exports.ox_inventory:GetItemCount(source, item, metadata, strict)
        end,
        slots = function(source, item)
            return exports.ox_inventory:GetSlotsWithItem(source, item, nil, false)
        end,
        add = function(source, item, count, metadata)
            return exports.ox_inventory:AddItem(source, item, count, metadata)
        end,
        remove = function(source, item, count, metadata, slot)
            return exports.ox_inventory:RemoveItem(source, item, count, metadata, slot)
        end,
    },
    qb = {
        label = 'qb-core shared/items.lua',
        report = 'qb-inventory',
        canCarry = function(source, item, count)
            return exports['qb-inventory']:CanAddItem(source, item, count)
        end,
        count = function(source, item)
            return exports['qb-inventory']:GetItemCount(source, item)
        end,
        slots = function(source, item)
            return exports['qb-inventory']:GetItemsByName(source, item)
        end,
        add = function(source, item, count, metadata)
            return exports['qb-inventory']:AddItem(source, item, count, nil, metadata, RZ.RESOURCE)
        end,
        remove = function(source, item, count, _metadata, slot)
            return exports['qb-inventory']:RemoveItem(source, item, count, slot, RZ.RESOURCE)
        end,
    },
    esx = {
        label = 'your inventory resource',
        report = 'framework native',
        canCarry = function(source, item, count)
            local player = RZ.Fw.GetPlayer(source)
            return player and player.canCarryItem(item, count) or false
        end,
        count = function(source, item)
            local player = RZ.Fw.GetPlayer(source)
            local entry = player and player.getInventoryItem(item)
            return entry and entry.count or 0
        end,
        slots = function() return nil end,
        add = function(source, item, count)
            local player = RZ.Fw.GetPlayer(source)
            if not player then return false end
            player.addInventoryItem(item, count)
            return true
        end,
        remove = function(source, item, count)
            local player = RZ.Fw.GetPlayer(source)
            if not player then return false end
            player.removeInventoryItem(item, count)
            return true
        end,
    },
}

function Inv.SourceLabel()
    return INV[resolveInv()].label
end

function Inv.CanCarry(source, item, count, metadata)
    local ok, res = pcall(INV[resolveInv()].canCarry, source, item, count, metadata)
    if not ok then
        RZ.Log.Integration('inventory', ('CanCarry(%s) failed: %s'):format(item, tostring(res)))
        return false
    end
    return res == true
end

function Inv.CanCarryAll(source, rewards)
    for i = 1, #rewards do
        local r = rewards[i]
        if not Inv.CanCarry(source, r.item, r.amount, r.metadata) then
            return false, r.item
        end
    end
    return true
end

function Inv.Count(source, item, metadata, strict)
    local ok, res = pcall(INV[resolveInv()].count, source, item, metadata, strict)
    if not ok then
        RZ.Log.Integration('inventory', ('Count(%s) failed: %s'):format(item, tostring(res)))
        return 0
    end
    return tonumber(res) or 0
end

function Inv.FindAllSlots(source, item)
    local b = resolveInv()
    local ok, res = pcall(INV[b].slots, source, item)
    if not ok then
        RZ.Log.Integration('inventory', ('FindAllSlots(%s) failed: %s'):format(item, tostring(res)))
        return {}
    end
    if type(res) ~= 'table' then return {} end
    if b ~= 'qb' then return res end

    local out = {}
    for i = 1, #res do
        local entry = res[i]
        out[i] = {
            slot = entry.slot,
            count = entry.amount or entry.count,
            metadata = entry.info,
        }
    end
    return out
end

function Inv.FindSlotBySerial(source, item, serial)
    if type(serial) ~= 'string' or serial == '' then return nil end
    if not Inv.Caps.metadata then return nil end
    local slots = Inv.FindAllSlots(source, item)
    for i = 1, #slots do
        local slot = slots[i]
        if slot.metadata and slot.metadata.serial == serial then
            return slot
        end
    end
    return nil
end

local function lookupItem(name)
    local b = resolveInv()
    if b == 'ox' then
        local ok, item = pcall(function() return exports.ox_inventory:Items(name) end)
        if not ok then return nil, true end
        return item, false
    end

    if b == 'qb' then
        local items = RZ.Fw.GetItems()
        if type(items) ~= 'table' then return nil, true end
        return items[name], false
    end

    return nil, true
end

function Inv.GetItem(name)
    if type(name) ~= 'string' or name == '' then return nil end
    return (lookupItem(name))
end

function Inv.ItemExists(name)
    if type(name) ~= 'string' or name == '' then return false end
    local def, unknown = lookupItem(name)
    if unknown then return nil end
    return def ~= nil
end

function Inv.Add(source, item, count, metadata)
    local b = resolveInv()

    if metadata and not Inv.Caps.metadata then
        RZ.Log.Integration('inventory',
            ('%s was granted WITHOUT metadata: the %s backend cannot store it'):format(item, b))
    end

    local ok, success, response = pcall(INV[b].add, source, item, count, metadata)
    if not ok then
        RZ.Log.Integration('inventory', ('Add(%s) threw: %s'):format(item, tostring(success)))
        return false, 'exception'
    end
    if success ~= true then
        return false, tostring(response)
    end
    return true
end

function Inv.Remove(source, item, count, metadata, slot)
    local ok, success, response = pcall(INV[resolveInv()].remove, source, item, count, metadata, slot)
    if not ok then
        RZ.Log.Integration('inventory', ('Remove(%s) threw: %s'):format(item, tostring(success)))
        return false, 'exception'
    end
    if success ~= true then
        return false, tostring(response)
    end
    return true
end

function Inv.GetAllItems(source)
    if resolveInv() ~= 'ox' then return nil end
    local ok, res = pcall(function() return exports.ox_inventory:GetInventoryItems(source) end)
    return ok and res or nil
end

function Inv.GetSlot(source, slot)
    if resolveInv() ~= 'ox' then return nil end
    local ok, res = pcall(function() return exports.ox_inventory:GetSlot(source, slot) end)
    return ok and res or nil
end

function Inv.CreateDrop(prefix, items, coords, slots, maxWeight, instance, model)
    if not Inv.Caps.drops then return nil end
    local ok, res = pcall(function()
        return exports.ox_inventory:CustomDrop(prefix, items, coords, slots, maxWeight, instance, model)
    end)
    return ok and res or nil
end

function Inv.RemoveDrop(dropId)
    if not Inv.Caps.drops then return end
    pcall(function() exports.ox_inventory:RemoveInventory(dropId) end)
end

function Inv.GrantAll(source, rewards)
    local granted = {}

    for i = 1, #rewards do
        local r = rewards[i]
        local ok, err = Inv.Add(source, r.item, r.amount, r.metadata)
        if not ok then
            RZ.Log.Integration('inventory',
                ('reward grant failed for %s x%d (%s) — rolling back %d line(s)')
                :format(r.item, r.amount, tostring(err), #granted))

            for j = #granted, 1, -1 do
                local g = granted[j]
                local undone = Inv.Remove(source, g.item, g.amount, g.metadata)
                if not undone then
                    RZ.Log.Integration('inventory',
                        ('ROLLBACK INCOMPLETE: could not remove %s x%d from %s')
                        :format(g.item, g.amount, tostring(source)))
                end
            end

            return false, r.item, {}
        end

        granted[#granted + 1] = { item = r.item, amount = r.amount, metadata = r.metadata }
    end

    return true, nil, granted
end

CreateThread(function()
    Wait(0)

    local b = resolveInv()
    print(('[pr-redzone] inventory: %s (metadata %s, drops %s)'):format(
        INV[b].report,
        Inv.Caps.metadata and 'yes' or 'NO',
        Inv.Caps.drops and 'yes' or 'NO'))

    if not Inv.Caps.drops then
        print('^3[pr-redzone] loot bags are DISABLED: this inventory has no drop inventories. Eliminated players keep their items.^0')
    end

    if not Inv.Caps.metadata then
        print('^3[pr-redzone] teammate DNA and the reboot station are DISABLED: this inventory cannot store a per-item serial, so a head cannot be tied to a death record.^0')
    end
end)

local DEATH_STATE_BAG = 'qbx_medical:deathState'

local DEATH_STATE = {
    ALIVE = 1,
    LAST_STAND = 2,
    DEAD = 3,
}

Medical.DEATH_STATE = DEATH_STATE

function Medical.GetDeathState(source)
    if RZ.Fw.Flavour() == 'qb' then
        if not RZ.Fw.IsLoaded(source) then return nil end
        if RZ.Fw.GetMeta(source, 'isdead') then return DEATH_STATE.DEAD end
        if RZ.Fw.GetMeta(source, 'inlaststand') then return DEATH_STATE.LAST_STAND end
        return DEATH_STATE.ALIVE
    end

    local ply = Player(source)
    if not ply then return nil end
    local value = ply.state[DEATH_STATE_BAG]
    if type(value) ~= 'number' then return nil end
    return value
end

function Medical.IsDeadOrLastStand(source)
    local state = Medical.GetDeathState(source)
    return state == DEATH_STATE.DEAD or state == DEATH_STATE.LAST_STAND
end

function Medical.IsNormallyRespawning(source)
    return Medical.GetDeathState(source) == DEATH_STATE.DEAD
end

function Medical.GetHealth(source)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return 0 end
    return GetEntityHealth(ped)
end

local function setDeathState(source, state)
    local f = RZ.Fw.Flavour()

    if f == 'qb' then
        RZ.Fw.SetMeta(source, 'isdead', state == DEATH_STATE.DEAD)
        RZ.Fw.SetMeta(source, 'inlaststand', state == DEATH_STATE.LAST_STAND)
        return
    end

    if f ~= 'qbx' then return end

    local ply = Player(source)
    if not ply then return end
    ply.state:set(DEATH_STATE_BAG, state, true)
end

function Medical.ClearDeathState(source)
    setDeathState(source, DEATH_STATE.ALIVE)
end

Medical.ExitRedZoneDowned = Medical.ClearDeathState

function Medical.EnterRedZoneDowned(source)
    if Medical.GetDeathState(source) ~= DEATH_STATE.ALIVE then
        setDeathState(source, DEATH_STATE.ALIVE)
    end
end

function Medical.MarkFullyDead(source)
    TriggerClientEvent(RZ.Event.KILL_LOCAL, source)
end

function Medical.Revive(source, coords, health)
    local f = RZ.Fw.Flavour()
    local handedOff = true

    if f == 'qbx' or f == 'qb' then
        local ok, err = pcall(function()
            if f == 'qb' then
                TriggerClientEvent('hospital:client:Revive', source)
            else
                exports.qbx_medical:Revive(source)
            end
        end)
        if not ok then
            RZ.Log.Integration('medical', 'Revive failed: ' .. tostring(err))
            handedOff = false
        end
    end

    SetTimeout(250, function()
        if GetPlayerName(source) == nil then return end
        Medical.ClearDeathState(source)
        TriggerClientEvent(RZ.Event.RESTORE, source, {
            coords = coords and { x = coords.x, y = coords.y, z = coords.z, w = coords.w } or nil,
            health = health,
        })
    end)

    return handedOff
end

local respawnCallbacks = {}

function Medical.RegisterRespawnHandler(callback)
    respawnCallbacks[#respawnCallbacks + 1] = callback
end

local function fireRespawn(source)
    if type(source) ~= 'number' or source <= 0 then return end
    for i = 1, #respawnCallbacks do
        local ok, err = pcall(respawnCallbacks[i], source)
        if not ok then
            RZ.Log.Integration('medical', 'respawn callback error: ' .. tostring(err))
        end
    end
end

AddEventHandler('qbx_medical:server:playerRespawned', function(source)
    fireRespawn(source)
end)

RegisterNetEvent('hospital:server:RespawnAtHospital', function()
    if RZ.Fw.Flavour() ~= 'qb' then return end
    fireRespawn(source)
end)

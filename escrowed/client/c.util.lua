RZ = RZ or {}
RZ.Notify = {}
RZ.Progress = {}
RZ.Target = {}

local Notify = RZ.Notify
local Progress = RZ.Progress
local Target = RZ.Target

local function started(resource)
    local state = GetResourceState(resource)
    return state == 'started' or state == 'starting'
end

local notifyBackend = nil

function Notify.Show(key, args, notifyType)
    local text = (args and #args > 0) and locale(key, table.unpack(args)) or locale(key)
    local kind = notifyType or 'inform'

    if notifyBackend == nil then
        notifyBackend = started('qbx_core') and 'qbx' or started('qb-core') and 'qb' or 'ox'
    end

    if notifyBackend == 'qbx' then
        if pcall(function() exports.qbx_core:Notify(text, kind) end) then return end
        notifyBackend = 'ox'
    elseif notifyBackend == 'qb' then
        if pcall(function()
            TriggerEvent('QBCore:Notify', text, kind == 'inform' and 'primary' or kind)
        end) then return end
        notifyBackend = 'ox'
    end

    lib.notify({ description = text, type = kind })
end

RegisterNetEvent(RZ.Event.NOTIFY, function(key, args, notifyType)
    if type(key) ~= 'string' then return end
    Notify.Show(key, args, notifyType)
end)

function Progress.Run(opts, watcher)
    local cancelled = false

    if watcher then
        CreateThread(function()
            while not cancelled do
                Wait(250)
                if not cancelled then
                    local ok, result = pcall(watcher)
                    if not ok or result == false then
                        cancelled = true
                        lib.cancelProgress()
                        return
                    end
                end
            end
        end)
    end

    local completed = lib.progressBar({
        duration = opts.duration,
        label = opts.label,
        useWhileDead = false,
        canCancel = true,
        allowRagdoll = false,
        allowSwimming = false,
        disable = {
            move = opts.disableMovement == true,
            car = true,
            combat = true,
            mouse = false,
        },
        anim = opts.anim,
    })

    cancelled = true
    return completed == true
end

function Progress.Cancel()
    lib.cancelProgress()
end

local targetFlavour = nil

local function resolveTarget()
    if targetFlavour then return targetFlavour end
    targetFlavour = started('ox_target') and 'ox' or started('qb-target') and 'qb' or nil
    return targetFlavour
end

local registeredEntities = {}
local registeredModels = {}
local registeredZones = {}

local function qbKey(option)
    return option.label or option.name
end

local function toQb(option)
    local canInteract = option.canInteract
    local onSelect = option.onSelect

    return {
        label = qbKey(option),
        icon = option.icon,
        distance = option.distance,
        canInteract = canInteract and function(entity, distance)
            return canInteract(entity, distance, nil, option.name) and true or false
        end or nil,
        action = function(entity)
            if not onSelect then return end
            onSelect({
                entity = entity,
                coords = (entity and entity ~= 0 and DoesEntityExist(entity))
                    and GetEntityCoords(entity) or nil,
            })
        end,
    }
end

local function translate(options)
    local out, keys = {}, {}
    for i = 1, #options do
        out[i] = toQb(options[i])
        keys[i] = qbKey(options[i])
    end
    return out, keys
end

local function optionNames(options)
    local names = {}
    for i = 1, #options do names[#names + 1] = options[i].name end
    return names
end

local warnedDistance = false

local function maxDistance(options)
    local best = 0
    for i = 1, #options do
        local d = tonumber(options[i].distance) or 0
        if d > best then best = d end
    end
    best = best > 0 and best or 2.5

    if resolveTarget() == 'qb' and not warnedDistance then
        local ceiling = tonumber(GetConvar('qb-target:maxDistance', '7.0')) or 7.0
        if best > ceiling then
            warnedDistance = true
            lib.print.warn(('[pr-redzone] an interaction is configured at %.1fm but qb-target caps every option at its Config.MaxDistance (~%.1fm). Lower the distance in configs/sh.config.lua or raise qb-target\'s limit.')
                :format(best, ceiling))
        end
    end

    return best
end

function Target.AddEntity(entity, options)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return end

    if resolveTarget() == 'qb' then
        local translated, keys = translate(options)
        registeredEntities[entity] = keys
        exports['qb-target']:AddTargetEntity(entity, { distance = maxDistance(options), options = translated })
        return
    end

    registeredEntities[entity] = optionNames(options)
    exports.ox_target:addLocalEntity(entity, options)
end

function Target.RemoveEntity(entity)
    local names = registeredEntities[entity]
    if not names then return end
    registeredEntities[entity] = nil

    pcall(function()
        if resolveTarget() == 'qb' then
            exports['qb-target']:RemoveTargetEntity(entity, names)
        else
            exports.ox_target:removeLocalEntity(entity, names)
        end
    end)
end

function Target.AddModel(model, options)
    local hash = type(model) == 'string' and joaat(model) or model

    if resolveTarget() == 'qb' then
        local translated, keys = translate(options)
        registeredModels[hash] = keys
        exports['qb-target']:AddTargetModel(hash, { distance = maxDistance(options), options = translated })
        return
    end

    registeredModels[hash] = optionNames(options)
    exports.ox_target:addModel(hash, options)
end

function Target.RemoveModel(model)
    local hash = type(model) == 'string' and joaat(model) or model
    local names = registeredModels[hash]
    if not names then return end
    registeredModels[hash] = nil

    pcall(function()
        if resolveTarget() == 'qb' then
            exports['qb-target']:RemoveTargetModel(hash, names)
        else
            exports.ox_target:removeModel(hash, names)
        end
    end)
end

function Target.RemoveAllModels()
    for hash in pairs(registeredModels) do
        Target.RemoveModel(hash)
    end
end

function Target.AddSphere(key, data)
    Target.RemoveSphere(key)

    if resolveTarget() == 'qb' then
        local options = data.options or {}
        local translated = translate(options)
        exports['qb-target']:AddCircleZone(
            key,
            data.coords,
            data.radius or 1.0,
            { name = key, useZ = true, debugPoly = data.debug or false },
            { distance = maxDistance(options), options = translated }
        )
        registeredZones[key] = key
        return
    end

    registeredZones[key] = exports.ox_target:addSphereZone(data)
end

function Target.RemoveSphere(key)
    local id = registeredZones[key]
    if not id then return end
    registeredZones[key] = nil

    pcall(function()
        if resolveTarget() == 'qb' then
            exports['qb-target']:RemoveZone(id)
        else
            exports.ox_target:removeZone(id, true)
        end
    end)
end

function Target.RemoveAllSpheres()
    for key in pairs(registeredZones) do
        Target.RemoveSphere(key)
    end
end

function Target.RemoveAll()
    for entity in pairs(registeredEntities) do
        Target.RemoveEntity(entity)
    end
    Target.RemoveAllModels()
    Target.RemoveAllSpheres()
end

CreateThread(function()
    Wait(0)
    if resolveTarget() then return end
    lib.print.error('[pr-redzone] no targeting resource found. ox_target or qb-target must be started.')
end)

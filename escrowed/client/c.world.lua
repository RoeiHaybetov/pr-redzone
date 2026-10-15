RZ = RZ or {}
RZ.Zones = {}
RZ.Blips = {}
RZ.Entities = {}

local Zones = RZ.Zones
local Blips = RZ.Blips
local Entities = RZ.Entities

local WALL_DRAW_DISTANCE = 150.0
local WALL_HEIGHT = 4.0

local zoneObjects = {}
local inside = {}
local markerRunning = false

function Zones.IsInside(zoneId)
    return inside[zoneId] == true
end

function Zones.Current()
    for zoneId, isIn in pairs(inside) do
        if isIn then return zoneId end
    end
    return nil
end

local function distanceToSegment(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local lenSq = dx * dx + dy * dy
    local t = 0.0
    if lenSq > 0.0 then
        t = math.max(0.0, math.min(1.0, ((px - ax) * dx + (py - ay) * dy) / lenSq))
    end
    local ox, oy = px - (ax + dx * t), py - (ay + dy * t)
    return math.sqrt(ox * ox + oy * oy)
end

local function startMarker(zoneId)
    local zone = Config.Zones[zoneId]
    if markerRunning or not RZ.Client.canSee then return end
    if not zone or not zone.boundary or not zone.boundary.drawMarker then return end
    if type(zone.points) ~= 'table' or #zone.points < 3 then return end
    markerRunning = true

    CreateThread(function()
        local colour = zone.boundary.markerColor
        local r, g, b, alpha = colour.r, colour.g, colour.b, colour.a
        local pts = zone.points
        local n = #pts

        while markerRunning and inside[zoneId] and RZ.Client.canSee do
            local me = GetEntityCoords(PlayerPedId())
            local base = me.z - 1.0
            local top = base + WALL_HEIGHT
            local j = n

            for i = 1, n do
                local p, q = pts[j], pts[i]
                if distanceToSegment(me.x, me.y, p.x, p.y, q.x, q.y) <= WALL_DRAW_DISTANCE then
                    DrawPoly(p.x, p.y, base, q.x, q.y, base, q.x, q.y, top, r, g, b, alpha)
                    DrawPoly(q.x, q.y, top, p.x, p.y, top, p.x, p.y, base, r, g, b, alpha)
                    DrawPoly(q.x, q.y, top, q.x, q.y, base, p.x, p.y, base, r, g, b, alpha)
                    DrawPoly(p.x, p.y, base, p.x, p.y, top, q.x, q.y, top, r, g, b, alpha)
                end
                j = i
            end

            Wait(0)
        end
        markerRunning = false
    end)
end

local function removeZoneObjects()
    for zoneId, obj in pairs(zoneObjects) do
        if obj and obj.remove then
            pcall(function() obj:remove() end)
        end
        zoneObjects[zoneId] = nil
        inside[zoneId] = false
    end
    markerRunning = false
end

function Zones.Setup()
    removeZoneObjects()

    for zoneId, zone in pairs(Config.Zones) do
        if zone.enabled and type(zone.points) == 'table' and #zone.points >= 3 then
            local ok, err = pcall(function()
                local minZ = zone.minZ or -1000.0
                local maxZ = zone.maxZ or 3000.0
                local midZ = (minZ + maxZ) * 0.5
                local flat = {}

                for i = 1, #zone.points do
                    local p = zone.points[i]
                    flat[i] = vec3(p.x, p.y, midZ)
                end

                zoneObjects[zoneId] = lib.zones.poly({
                    points = flat,
                    thickness = (maxZ - minZ) * 2.0,
                    debug = zone.boundary and zone.boundary.debugPoly == true,
                    onEnter = function()
                        inside[zoneId] = true
                        TriggerEvent(RZ.Local.ENTERED_ZONE, zoneId)
                        startMarker(zoneId)
                    end,
                    onExit = function()
                        inside[zoneId] = false
                        TriggerEvent(RZ.Local.LEFT_ZONE, zoneId)
                    end,
                })
            end)

            if not ok then
                lib.print.error(('[pr-redzone] zone "%s" could not be built and was skipped: %s')
                    :format(zoneId, tostring(err)))
            end
        end
    end
end

local zoneBlips = {}
local crateBlip = nil

local function removeBlip(handle)
    if handle and DoesBlipExist(handle) then RemoveBlip(handle) end
end

local function nameBlip(handle, text)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandSetBlipName(handle)
end

local function removeZoneBlips(zoneId)
    local handles = zoneBlips[zoneId]
    if not handles then return end
    for i = 1, #handles do
        removeBlip(handles[i])
    end
    zoneBlips[zoneId] = nil
end

local function createZoneBlips(zoneId, zone)
    removeZoneBlips(zoneId)

    local cfg = zone.blip
    if not cfg.enabled then return end

    local handles = {}
    local z = zone.center.z + 0.0

    if cfg.style == 'circle' then
        -- A clean disc instead of the traced shape: easier on the eye, but approximate. Its
        -- radius reaches the furthest corner, so it never shows less ground than the zone.
        local radius = AddBlipForRadius(zone.center.x, zone.center.y, z, (zone.radius or 50.0) + 0.0)
        SetBlipColour(radius, cfg.color)
        SetBlipAlpha(radius, cfg.alpha)
        SetBlipAsShortRange(radius, true)
        handles[#handles + 1] = radius
    else
        if cfg.style == 'filled' then
            local parts = RZ.Geo.PolygonBlipParts(zone.points, cfg.detail, cfg.maxParts)
            for i = 1, #parts do
                local part = parts[i]
                local area = AddBlipForArea(part.x, part.y, z, part.w, part.h)
                SetBlipColour(area, cfg.color)
                SetBlipAlpha(area, cfg.alpha)
                SetBlipAsShortRange(area, true)
                handles[#handles + 1] = area
            end
        end

        -- The border is near-opaque so where two edges overlap at a corner it does not show
        -- as a darker blot, and each edge runs half its width past both ends so corners close
        -- instead of leaving a notch between two separate lines.
        local edgeAlpha = math.min(255, cfg.alpha + 150)
        local width = cfg.outlineWidth + 0.0
        local pts = zone.points
        local n = #pts
        local j = n

        for i = 1, n do
            local a, b = pts[j], pts[i]
            local dx, dy = b.x - a.x, b.y - a.y
            local length = math.sqrt(dx * dx + dy * dy)
            if length > 0.01 then
                local heading = GetHeadingFromVector_2d(dx, dy)
                local edge = AddBlipForArea((a.x + b.x) * 0.5, (a.y + b.y) * 0.5, z, width, length + width)
                SetBlipRotation(edge, math.floor(heading + 0.5))
                pcall(SetBlipSquaredRotation, edge, heading + 0.0)
                SetBlipColour(edge, cfg.color)
                SetBlipAlpha(edge, edgeAlpha)
                SetBlipAsShortRange(edge, true)
                handles[#handles + 1] = edge
            end
            j = i
        end
    end

    local center = AddBlipForCoord(zone.center.x, zone.center.y, z)
    SetBlipSprite(center, cfg.centerSprite)
    SetBlipColour(center, cfg.centerColor)
    SetBlipScale(center, cfg.centerScale + 0.0)
    SetBlipAsShortRange(center, true)
    SetBlipDisplay(center, 4)
    nameBlip(center, cfg.centerLabel)
    handles[#handles + 1] = center

    zoneBlips[zoneId] = handles
end

function Blips.Refresh()
    local canSee = RZ.Client.canSee == true
    for zoneId in pairs(zoneBlips) do
        if not Config.Zones[zoneId] then removeZoneBlips(zoneId) end
    end
    for zoneId, zone in pairs(Config.Zones) do
        local cfg = zone.blip
        local show = canSee and zone.enabled and cfg.enabled
            and (RZ.Client.zonesOpen[zoneId] == true or cfg.showWhenClosed)

        if show then
            if not zoneBlips[zoneId] then createZoneBlips(zoneId, zone) end
        else
            removeZoneBlips(zoneId)
        end
    end
end

function Blips.RefreshCrate()
    local crate = RZ.Client.crate
    if not crate or not crate.blipEnabled then
        removeBlip(crateBlip)
        crateBlip = nil
        return
    end
    if crateBlip and DoesBlipExist(crateBlip) then return end

    local zone = RZ.Client.zoneId and Config.Zones[RZ.Client.zoneId]
    local cfg = zone and zone.crate or {}

    crateBlip = AddBlipForCoord(crate.x, crate.y, crate.z)
    SetBlipSprite(crateBlip, cfg.blipSprite or 478)
    SetBlipColour(crateBlip, cfg.blipColor or 5)
    SetBlipScale(crateBlip, (cfg.blipScale or 0.8) + 0.0)
    SetBlipAsShortRange(crateBlip, false)
    SetBlipFlashes(crateBlip, true)
    nameBlip(crateBlip, locale('crate.blip_label'))
end

function Blips.RemoveAll()
    for zoneId in pairs(zoneBlips) do
        removeZoneBlips(zoneId)
    end
    removeBlip(crateBlip)
    crateBlip = nil
end

local sellerPeds = {}
local crateProp = nil
local failedModels = {}
local reportedModels = {}

function Entities.TryLoadModel(candidate, timeoutMs)
    local hash = type(candidate) == 'string' and joaat(candidate) or candidate
    if failedModels[hash] then return nil, failedModels[hash] end
    if not IsModelValid(hash) then
        return nil, 'not a valid model (wrong name, or not a spawnable archetype)'
    end

    local ok = pcall(lib.requestModel, hash, timeoutMs or 3000)
    if not ok or not HasModelLoaded(hash) then
        failedModels[hash] = 'valid name but could not be streamed in (map-only or cutscene asset?)'
        return nil, failedModels[hash]
    end

    return hash, 'ok'
end

local function loadModel(model, kind)
    local hash, reason = Entities.TryLoadModel(model)
    if hash then return hash end

    local fallback = (kind == 'ped') and Config.Fallbacks.ped or Config.Fallbacks.prop
    local badHash = type(model) == 'string' and joaat(model) or model

    if not reportedModels[badHash] then
        reportedModels[badHash] = true
        lib.print.error(('[pr-redzone] model "%s" could not be loaded (%s) - using "%s" instead. Test alternatives with /redzone_testmodel <name>.')
            :format(tostring(model), reason, tostring(fallback)))
    end

    hash = Entities.TryLoadModel(fallback)
    if not hash then
        lib.print.error(('[pr-redzone] FALLBACK model "%s" is also invalid - check Config.Fallbacks.')
            :format(tostring(fallback)))
    end
    return hash
end

if Config.Debug then
    RegisterCommand('redzone_testmodel', function(_, args)
        local name = args[1]
        if not name then
            print('^3usage: /redzone_testmodel <modelname>^7')
            return
        end

        local key = joaat(name)
        failedModels[key] = nil
        reportedModels[key] = nil

        local hash, reason = Entities.TryLoadModel(name, 5000)
        if hash then
            print(('^2"%s" LOADS OK^7 - safe to use in the config'):format(name))
            SetModelAsNoLongerNeeded(hash)
        else
            print(('^1"%s" FAILED^7 - %s'):format(name, reason))
        end
    end, false)
end

local function makeStatic(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return end
    FreezeEntityPosition(entity, true)
    SetEntityInvincible(entity, true)
    SetEntityAsMissionEntity(entity, true, true)
    SetEntityCanBeDamaged(entity, false)
end

local function placeProp(entity, coords)
    SetEntityCoordsNoOffset(entity, coords.x, coords.y, coords.z, false, false, false)
    if coords.w then SetEntityHeading(entity, coords.w) end
    PlaceObjectOnGroundProperly(entity)

    local drop = math.abs(GetEntityCoords(entity).z - coords.z)
    if drop > (Config.Fallbacks.maxGroundSnap or 3.0) then
        SetEntityCoordsNoOffset(entity, coords.x, coords.y, coords.z, false, false, false)
    end
end

local function destroy(entity)
    if entity and entity ~= 0 and DoesEntityExist(entity) then
        RZ.Target.RemoveEntity(entity)
        SetEntityAsMissionEntity(entity, true, true)
        DeleteEntity(entity)
    end
end

function Entities.SpawnSeller(zoneId)
    local existing = sellerPeds[zoneId]
    if existing and DoesEntityExist(existing) then return end

    local zone = Config.Zones[zoneId]
    if not zone then return end

    local cfg = zone.seller
    local hash = loadModel(cfg.model, 'ped')
    if not hash then return end

    -- "Use my position" saves the ped's body-centre height and "Place in world" saves ground
    -- height. The seller is frozen at spawn, so settle it on the ground either way or it floats.
    local c = cfg.coords
    local z = c.z + 0.0
    local found, groundZ = GetGroundZFor_3dCoord(c.x + 0.0, c.y + 0.0, z + 0.5, false)
    if found and groundZ and z - groundZ <= 1.5 then z = groundZ end

    local ped = CreatePed(4, hash, c.x, c.y, z, c.w, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not ped or ped == 0 then
        sellerPeds[zoneId] = nil
        return
    end

    sellerPeds[zoneId] = ped
    makeStatic(ped)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
    SetPedDiesWhenInjured(ped, false)
    SetPedFleeAttributes(ped, 0, false)
    SetPedCombatAttributes(ped, 46, false)
    SetPedAsEnemy(ped, false)

    if cfg.scenario and cfg.scenario ~= '' then
        TaskStartScenarioInPlace(ped, cfg.scenario, 0, true)
    end

    RZ.Interactions.AttachSeller(ped, zoneId)
end

function Entities.RemoveSeller()
    for zoneId, ped in pairs(sellerPeds) do
        destroy(ped)
        sellerPeds[zoneId] = nil
    end
end

function Entities.RefreshCrate()
    local crate = RZ.Client.crate
    if not crate then
        destroy(crateProp)
        crateProp = nil
        return
    end
    if crateProp and DoesEntityExist(crateProp) then return end

    local hash = loadModel(crate.prop, 'prop')
    if not hash then return end

    crateProp = CreateObject(hash, crate.x, crate.y, crate.z, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not crateProp or crateProp == 0 then
        crateProp = nil
        return
    end

    placeProp(crateProp, { x = crate.x, y = crate.y, z = crate.z, w = crate.w or 0.0 })
    makeStatic(crateProp)
    RZ.Interactions.AttachCrate(crateProp)
end

function Entities.SpawnForZone(zoneId)
    Entities.SpawnSeller(zoneId)
    Entities.RefreshCrate()
end

function Entities.RemoveAll()
    Entities.RemoveSeller()
    destroy(crateProp)
    crateProp = nil
end

local function reconcile()
    local zoneId = Zones.Current()
    if zoneId and RZ.Client.zonesOpen[zoneId] == true then
        Entities.SpawnForZone(zoneId)
    else
        Entities.RemoveAll()
    end
end

Entities.Reconcile = reconcile

AddEventHandler(RZ.Local.ENTERED_ZONE, reconcile)
AddEventHandler(RZ.Local.LEFT_ZONE, reconcile)

AddEventHandler(RZ.Local.ZONES_CHANGED, function()
    Blips.Refresh()
    reconcile()
    local current = Zones.Current()
    if current and RZ.Client.canSee then startMarker(current) end
end)

AddEventHandler(RZ.Local.CRATE_CHANGED, function()
    Blips.RefreshCrate()
    if Zones.Current() then Entities.RefreshCrate() end
end)

AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName ~= RZ.RESOURCE then return end
    Zones.Setup()
end)

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= RZ.RESOURCE then return end
    removeZoneObjects()
end)

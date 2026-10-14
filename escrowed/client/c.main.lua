RZ = RZ or {}

RZ.Client = {
    state = RZ.State.OUTSIDE,
    serverMonoOffset = 0,
    zonesOpen = {},
    canSee = false,
    crateTimerAt = 0,
    downedPeers = {},
    eliminatedPeers = {},
}
RZ.ConfigSync = {}
RZ.Hud = {}
RZ.LootBagUi = {}

local C = RZ.Client
local Sync = RZ.ConfigSync
local Hud = RZ.Hud
local Ui = RZ.LootBagUi
local S = RZ.Serializer

function C.IsInOpenZone()
    return C.zoneId ~= nil and C.zonesOpen[C.zoneId] == true
end

function C.IsAlive()
    return C.state == RZ.State.ALIVE
end

function C.IsDowned()
    return C.state == RZ.State.DOWNED or C.state == RZ.State.BEING_REVIVED
end

function C.GetKnockRemaining()
    if not C.knockDeadline then return C.knockRemainingMs or 0 end
    local remaining = C.knockDeadline - (GetGameTimer() + C.serverMonoOffset)
    return remaining > 0 and remaining or 0
end

function C.RequestSync()
    CreateThread(function()
        Wait(1000)
        pcall(function()
            lib.callback.await(RZ.Callback.SYNC_REQUEST, false)
        end)
    end)
end

local function snapZ(x, y, z)
    local found, groundZ = GetGroundZFor_3dCoord(x, y, z + 25.0, false)
    if found and groundZ then return groundZ + 1.0 end
    return z
end

local function releasePed(ped)
    SetEntityInvincible(ped, false)
    ResetPedMovementClipset(ped, 0.0)
    SetPedMoveRateOverride(ped, 1.0)
    SetPlayerSprint(PlayerId(), true)
    ClearPedTasks(ped)
end

RegisterNetEvent(RZ.Event.SYNC_SELF, function(data)
    if type(data) ~= 'table' then return end
    local previousState = C.state
    C.state = data.state or RZ.State.OUTSIDE
    C.zoneId = data.zoneId
    C.knockRemainingMs = data.knockRemainingMs
    C.knockDeadline = data.knockDeadline
    if data.serverMono then
        C.serverMonoOffset = data.serverMono - GetGameTimer()
    end

    if previousState ~= C.state then
        TriggerEvent(RZ.Local.STATE_CHANGED, C.state, previousState)
    end
end)

RegisterNetEvent(RZ.Event.SYNC_WORLD, function(data)
    if type(data) ~= 'table' then return end
    local zonesChanged = false
    if data.zones then
        C.zonesOpen = data.zones
        zonesChanged = true
    end
    if data.canSee ~= nil and (data.canSee == true) ~= C.canSee then
        C.canSee = data.canSee == true
        zonesChanged = true
    end
    if zonesChanged then TriggerEvent(RZ.Local.ZONES_CHANGED) end

    if data.crate ~= nil then
        C.crate = data.crate ~= false and data.crate or nil
        TriggerEvent(RZ.Local.CRATE_CHANGED)
    end

    if data.crateTimer then
        C.crateTimer = data.crateTimer
        C.crateTimerAt = GetGameTimer()
    end

    C.downedPeers = data.downedPeers or C.downedPeers
    C.eliminatedPeers = data.eliminatedPeers or C.eliminatedPeers
end)

RegisterNetEvent(RZ.Event.RESTORE, function(data)
    data = type(data) == 'table' and data or {}
    local ped = PlayerPedId()
    RZ.Knock.ClearLocalDowned()

    if data.coords then
        if RZ.AdminPlacement and RZ.AdminPlacement.IsActive() then
            RZ.AdminPlacement.Cancel()
        end

        local x, y = data.coords.x + 0.0, data.coords.y + 0.0
        local z = snapZ(x, y, data.coords.z + 0.0)

        if IsEntityDead(ped) then
            local heading = data.coords.w and (data.coords.w + 0.0) or GetEntityHeading(ped)
            NetworkResurrectLocalPlayer(x, y, z, heading, true, false)
            ped = PlayerPedId()
        end

        FreezeEntityPosition(ped, false)
        RenderScriptCams(false, false, 0, true, true)
        ClearFocus()
        SetEntityCoords(ped, x, y, z, false, false, false, false)
        if data.coords.w then
            SetEntityHeading(ped, data.coords.w + 0.0)
        end
    end

    local health = data.health and math.floor(data.health) or 0
    if health > 0 then
        RZ.Knock.BeginRestoreGrace()
        SetEntityHealth(ped, health)
    end

    releasePed(ped)

    if data.coords and (IsScreenFadedOut() or IsScreenFadingOut()) then
        CreateThread(function()
            local deadline = GetGameTimer() + 3000
            while IsScreenFadingOut() and GetGameTimer() < deadline do
                Wait(50)
            end

            local dwell = GetGameTimer() + 250
            while GetGameTimer() < dwell do
                if not IsScreenFadedOut() then return end
                Wait(50)
            end

            if IsScreenFadedOut() then DoScreenFadeIn(500) end
        end)
    end

    LocalPlayer.state:set('invBusy', false, true)
end)

RegisterNetEvent(RZ.Event.COOLDOWN_BURN, function(data)
    if type(data) ~= 'table' then return end
    local ped = PlayerPedId()
    if not DoesEntityExist(ped) or IsEntityDead(ped) then return end

    if data.kill then
        SetEntityHealth(ped, 0)
        return
    end

    local amount = tonumber(data.amount)
    if not amount or amount ~= amount or amount <= 0 then return end
    SetEntityHealth(ped, math.max(0, GetEntityHealth(ped) - math.floor(amount)))
end)

RegisterNetEvent(RZ.Event.FORCE_EJECT, function(data)
    if type(data) ~= 'table' or type(data.x) ~= 'number' then return end
    local ped = PlayerPedId()
    if data.leaveVehicle and IsPedInAnyVehicle(ped, false) then
        ClearPedTasksImmediately(ped)
    end

    local x, y = data.x + 0.0, data.y + 0.0
    SetEntityCoords(ped, x, y, snapZ(x, y, data.z + 0.0), false, false, false, false)
end)

RegisterNetEvent(RZ.Event.KILL_LOCAL, function()
    RZ.Knock.ClearLocalDowned()
    CreateThread(function()
        RZ.MedicalCl.SeedDeathTime(Config.Elimination.autoRespawnSeconds)
        if not RZ.MedicalCl.KillPlayer() then
            SetEntityHealth(PlayerPedId(), 0)
            return
        end

        local deadline = GetGameTimer() + 2500
        while GetGameTimer() < deadline do
            Wait(100)
            if RZ.MedicalCl.IsLastStand() then
                RZ.MedicalCl.KillPlayer()
                return
            end
        end
    end)
end)

RegisterNetEvent(RZ.Event.CANCEL_ACTION, function(_action)
    RZ.Progress.Cancel()
end)

AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName == RZ.RESOURCE then C.RequestSync() end
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', C.RequestSync)
AddEventHandler('playerSpawned', C.RequestSync)

local revision, build = -1, -1

function Sync.GetRevision() return revision end

local function keepFields(dst, src, fields)
    for i = 1, #fields do
        local k = fields[i]
        dst[k] = src[k] or dst[k]
    end
end

local function mergeIntoConfig(payload)
    if type(payload.Zones) == 'table' then
        local zones = {}
        for zoneId, zone in pairs(payload.Zones) do
            local existing = Config.Zones and Config.Zones[zoneId] or {}
            local merged = S.Copy(existing)

            merged.enabled = zone.enabled
            merged.center = S.JsonToVector(zone.center) or merged.center
            keepFields(merged, zone, { 'label', 'radius', 'minZ', 'maxZ', 'blip' })

            if type(zone.points) == 'table' then
                local pts = {}
                for i = 1, #zone.points do
                    local v = S.JsonToVector(zone.points[i])
                    if v then pts[#pts + 1] = v end
                end
                if #pts >= 3 and #pts == #zone.points then
                    merged.points = pts
                end
            end

            merged.boundary = merged.boundary or {}
            if zone.boundary then
                local b = merged.boundary
                b.drawMarker = zone.boundary.drawMarker
                b.markerColor = zone.boundary.markerColor or b.markerColor
                b.debugPoly = zone.boundary.debugPoly
            end

            merged.crate = merged.crate or {}
            if zone.crate then
                merged.crate.coords = S.JsonToVector(zone.crate.coords) or merged.crate.coords
                merged.crate.blipEnabled = zone.crate.blipEnabled
                keepFields(merged.crate, zone.crate, { 'prop', 'interactionDistance',
                    'lootDuration', 'blipSprite', 'blipColor', 'blipScale' })
            end

            merged.seller = merged.seller or {}
            if zone.seller then
                merged.seller.coords = S.JsonToVector(zone.seller.coords) or merged.seller.coords
                keepFields(merged.seller, zone.seller, { 'model', 'scenario', 'interactionDistance' })
            end

            local stations = {}
            for i = 1, #(zone.rebootStations or {}) do
                local st = zone.rebootStations[i]
                local prev = (existing.rebootStations or {})[i] or {}
                stations[i] = {
                    propCoords = S.JsonToVector(st.propCoords) or prev.propCoords,
                    prop = st.prop or prev.prop,
                    useExistingProp = st.useExistingProp,
                    interactionDistance = st.interactionDistance or prev.interactionDistance,
                    playerSpawn = prev.playerSpawn,
                }
            end
            merged.rebootStations = stations
            if RZ.Defaults and RZ.Defaults.ApplyZone then
                RZ.Defaults.ApplyZone(merged)
            end

            zones[zoneId] = merged
        end

        Config.Zones = zones
    end

    for _, name in ipairs({ 'Knock', 'Revive', 'Reboot', 'Elimination', 'Hud', 'Fallbacks' }) do
        if type(payload[name]) == 'table' then
            for k, v in pairs(payload[name]) do Config[name][k] = v end
        end
    end
end

function Sync.Apply(payload)
    if type(payload) ~= 'table' then return end
    local incoming = tonumber(payload.revision) or 0
    local incomingBuild = tonumber(payload.build) or 0
    if incoming == revision and incomingBuild == build then return end

    mergeIntoConfig(payload)
    revision, build = incoming, incomingBuild

    RZ.Entities.RemoveAll()
    Ui.Clear()
    RZ.Target.RemoveAll()
    RZ.Blips.RemoveAll()

    RZ.Zones.Setup()
    RZ.Interactions.RegisterPlayerOptions()
    RZ.Blips.Refresh()
    RZ.Blips.RefreshCrate()
    RZ.Entities.Reconcile()

    Hud.Invalidate()
    C.RequestSync()

    lib.print.info(('[pr-redzone] applied configuration revision %d'):format(revision))
end

RegisterNetEvent(RZ.Event.CONFIG_SYNC, function(payload)
    if type(payload) ~= 'table' then return end
    Sync.Apply(payload)
end)

local hudRunning, lastCrateKey, lastKnockKey = false, nil, nil

local function hideOverlay(action, key)
    if key == 'hidden' then return key end
    SendNUIMessage({ action = action, data = { visible = false } })
    return 'hidden'
end

local function pushCrate()
    local t = C.crateTimer
    if not (Config.Hud.enabled and C.IsInOpenZone() and t ~= nil) then
        lastCrateKey = hideOverlay('rzCrate', lastCrateKey)
        return
    end

    local status = t.active and 'active'
        or t.running and 'running'
        or (t.groupCount or 0) == 0 and 'empty'
        or 'contested'

    local remaining = t.remainingMs
    if t.running then
        remaining = math.max(0, remaining - (GetGameTimer() - C.crateTimerAt))
    end

    local key = ('%s|%d|%d'):format(status, math.floor(remaining / 1000), t.groupCount or 0)
    if key == lastCrateKey then return end
    lastCrateKey = key
    SendNUIMessage({
        action = 'rzCrate',
        data = {
            visible = true,
            status = status,
            remainingMs = remaining,
            intervalMs = t.intervalMs or 300000,
            groupCount = t.groupCount or 0,
            position = Config.Hud.position or 'bottom-right',
            scale = Config.Hud.scale or 1.0,
            labels = {
                title = locale('crate.hud_title'),
                running = locale('crate.hud_running'),
                active = locale('crate.hud_active'),
                contested = locale('crate.hud_contested_short'),
                empty = locale('crate.hud_empty_short'),
            },
        },
    })
end

local function pushKnock()
    if not (RZ.Knock and RZ.Knock.IsLocallyDowned()) then
        lastKnockKey = hideOverlay('rzKnock', lastKnockKey)
        return
    end

    local remaining = C.GetKnockRemaining()
    local paused = C.knockDeadline == nil
    local key = ('%d|%s'):format(math.floor(remaining / 1000), tostring(paused))
    if key == lastKnockKey then return end
    lastKnockKey = key
    SendNUIMessage({
        action = 'rzKnock',
        data = {
            visible = true,
            remainingMs = remaining,
            durationMs = Config.Knock.durationMs,
            paused = paused,
            labels = {
                title = locale('knock.hud_title'),
                paused = locale('knock.hud_reviving'),
                hint = locale('knock.hud_hint'),
            },
        },
    })
end

function Hud.Start()
    if hudRunning then return end
    hudRunning = true
    CreateThread(function()
        while hudRunning do
            if C.IsInOpenZone() or (RZ.Knock and RZ.Knock.IsLocallyDowned()) then
                pushCrate()
                pushKnock()
                Wait(250)
            else
                if lastCrateKey ~= 'hidden' or lastKnockKey ~= 'hidden' then
                    pushCrate()
                    pushKnock()
                end
                Wait(1000)
            end
        end
    end)
end

function Hud.Invalidate()
    lastCrateKey = nil
    lastKnockKey = nil
end

function Hud.Stop()
    hudRunning = false
    hideOverlay('rzCrate', nil)
    hideOverlay('rzKnock', nil)
end

local shownBags = {}

local function bagKey(dropId)
    return 'rz_bag_' .. tostring(dropId)
end

local function openBag(dropId)
    local ok = pcall(function()
        if GetResourceState('ox_inventory') ~= 'started' then return end
        exports.ox_inventory:openInventory('drop', dropId)
    end)
    if not ok then
        RZ.Notify.Show('lootbag.open_failed', nil, 'error')
    end
end

function Ui.Apply(list)
    local wanted = {}
    for i = 1, #list do
        local dropId, coords = list[i].id, list[i].coords
        if type(dropId) == 'string' and type(coords) == 'table' and coords.x then
            wanted[dropId] = true
            if not shownBags[dropId] then
                shownBags[dropId] = true
                RZ.Target.AddSphere(bagKey(dropId), {
                    coords = vec3(coords.x + 0.0, coords.y + 0.0, coords.z + 0.0),
                    radius = 1.2,
                    debug = false,
                    options = { {
                        name = bagKey(dropId),
                        label = locale('lootbag.option'),
                        icon = 'fa-solid fa-briefcase',
                        distance = 2.0,
                        onSelect = function() openBag(dropId) end,
                    } },
                })
            end
        end
    end

    for dropId in pairs(shownBags) do
        if not wanted[dropId] then
            shownBags[dropId] = nil
            RZ.Target.RemoveSphere(bagKey(dropId))
        end
    end
end

function Ui.Clear()
    for dropId in pairs(shownBags) do
        RZ.Target.RemoveSphere(bagKey(dropId))
    end
    shownBags = {}
end

RegisterNetEvent(RZ.Event.SYNC_BAGS, function(list)
    if type(list) ~= 'table' then return end
    Ui.Apply(list)
end)

Hud.Start()

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= RZ.RESOURCE then return end
    hudRunning = false
    RZ.Knock.ClearLocalDowned()
    RZ.Entities.RemoveAll()
    RZ.Blips.RemoveAll()
    Ui.Clear()
    RZ.Target.RemoveAll()

    local ped = PlayerPedId()
    if DoesEntityExist(ped) then releasePed(ped) end
    LocalPlayer.state:set('invBusy', false, true)
end)

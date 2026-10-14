RZ = RZ or {}

RZ.AdminPreview = {}
RZ.AdminPlacement = {}
RZ.AdminUI = {}

local Preview = RZ.AdminPreview
local P = RZ.AdminPlacement
local UI = RZ.AdminUI

local entities = {}
local polyPoints = nil
local polyThread = false

local function destroy(entity)
    if entity and entity ~= 0 and DoesEntityExist(entity) then
        SetEntityAsMissionEntity(entity, true, true)
        DeleteEntity(entity)
    end
end

local function makeGhost(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return end
    SetEntityAlpha(entity, 160, false)
    SetEntityCollision(entity, false, false)
    SetEntityInvincible(entity, true)
    FreezeEntityPosition(entity, true)
    SetEntityAsMissionEntity(entity, true, true)
    SetCanClimbOnEntity(entity, false)
end

Preview.MakeGhost = makeGhost

function Preview.Clear(key)
    local entity = entities[key]
    if entity then
        destroy(entity)
        entities[key] = nil
    end
end

function Preview.Get(key)
    local entity = entities[key]
    if entity and DoesEntityExist(entity) then return entity end
    return nil
end

function Preview.Show(data)
    local key = tostring(data.key or 'preview')
    local c = data.coords
    if type(c) ~= 'table' or type(c.x) ~= 'number' then
        return { ok = false, error = 'Invalid coordinates.' }
    end

    Preview.Clear(key)

    local hash, reason = RZ.Entities.TryLoadModel(data.model, 4000)
    if not hash then return { ok = false, error = reason } end
    local entity
    if data.kind == 'ped' then
        entity = CreatePed(4, hash, c.x + 0.0, c.y + 0.0, (c.z or 0.0) - 1.0, c.w or 0.0, false, false)
        if entity and entity ~= 0 then
            SetBlockingOfNonTemporaryEvents(entity, true)
            SetPedCanRagdoll(entity, false)
            if data.scenario and data.scenario ~= '' then
                TaskStartScenarioInPlace(entity, data.scenario, 0, true)
            end
        end
    else
        entity = CreateObject(hash, c.x + 0.0, c.y + 0.0, (c.z or 0.0) - 1.0, false, false, false)
        if entity and entity ~= 0 then
            SetEntityHeading(entity, c.w or 0.0)
            PlaceObjectOnGroundProperly(entity)
        end
    end

    SetModelAsNoLongerNeeded(hash)

    if not entity or entity == 0 then
        return { ok = false, error = 'Could not create the preview.' }
    end

    makeGhost(entity)
    entities[key] = entity
    return { ok = true }
end

function Preview.SetPolygon(points)
    if type(points) ~= 'table' or #points < 1 then
        polyPoints = nil
        return
    end

    polyPoints = points
    if polyThread then return end
    polyThread = true
    CreateThread(function()
        while polyPoints do
            local pts = polyPoints
            local n = #pts

            for i = 1, n do
                local p = pts[i]
                DrawLine(p.x, p.y, p.z, p.x, p.y, p.z + 6.0, 224, 52, 60, 200)
                DrawMarker(28, p.x, p.y, p.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                    0.4, 0.4, 0.4, 224, 52, 60, 180, false, false, 2, false, nil, nil, false)

                if n >= 2 then
                    local q = pts[i % n + 1]
                    DrawLine(p.x, p.y, p.z, q.x, q.y, q.z, 224, 52, 60, 220)

                    if n >= 3 then
                        DrawPoly(p.x, p.y, p.z, q.x, q.y, q.z, q.x, q.y, q.z + 4.0, 224, 52, 60, 60)
                        DrawPoly(q.x, q.y, q.z + 4.0, p.x, p.y, p.z + 4.0, p.x, p.y, p.z, 224, 52, 60, 60)
                        DrawPoly(q.x, q.y, q.z + 4.0, q.x, q.y, q.z, p.x, p.y, p.z, 224, 52, 60, 60)
                        DrawPoly(p.x, p.y, p.z, p.x, p.y, p.z + 4.0, q.x, q.y, q.z + 4.0, 224, 52, 60, 60)
                    end
                end
            end

            Wait(0)
        end
        polyThread = false
    end)
end

function Preview.ClearAll()
    for key in pairs(entities) do
        Preview.Clear(key)
    end
    Preview.SetPolygon(nil)
end

local active = false
local state = nil
local polygon = nil
local cam = nil
local camYaw, camPitch = 0.0, 0.0

local REACH = 300.0
local MAX_POINTS = 64
local LOOK_X, LOOK_Y = 1, 2

local KEY = {
    forward = 32, back = 33, left = 34, right = 35,
    up = 44, down = 46, rotL = 174, rotR = 175,
    slow = 36, fast = 21, snap = 47, confirm = 191,
    cancel = 194, undo = 47, clear = 178, finish = 23,
}

local BLOCKED = {
    KEY.forward, KEY.back, KEY.left, KEY.right, KEY.up, KEY.down,
    24, 25, 22, 23, 47, 178, 199, 200,
}

local function round(value, fmt)
    return tonumber(fmt:format(value))
end

local function startCamera()
    if cam then return end

    local pos = GetEntityCoords(PlayerPedId())
    local rot = GetGameplayCamRot(2)
    camYaw, camPitch = rot.z + 0.0, rot.x + 0.0
    cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamCoord(cam, pos.x, pos.y, pos.z + 1.0)
    SetCamRot(cam, camPitch, 0.0, camYaw, 2)
    SetCamFov(cam, 60.0)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)
end

local function stopCamera()
    if not cam then return end
    ClearFocus()
    RenderScriptCams(false, false, 0, true, true)
    DestroyCam(cam, false)
    cam = nil
end

P.StopCamera = stopCamera

local function updateCameraLook()
    if not cam then return end
    camYaw = camYaw - GetDisabledControlNormal(0, LOOK_X) * 8.0
    camPitch = camPitch - GetDisabledControlNormal(0, LOOK_Y) * 8.0
    if camPitch > 89.0 then camPitch = 89.0 elseif camPitch < -89.0 then camPitch = -89.0 end
    SetCamRot(cam, camPitch, 0.0, camYaw, 2)
end

local function camForward()
    local rz, rx = math.rad(camYaw), math.rad(camPitch)
    local cosRx = math.cos(rx)
    return -math.sin(rz) * cosRx, math.cos(rz) * cosRx, math.sin(rx)
end

local function aimPoint()
    local origin = GetCamCoord(cam)
    local fx, fy, fz = camForward()
    local dx, dy, dz = origin.x + fx * REACH, origin.y + fy * REACH, origin.z + fz * REACH

    local handle = StartExpensiveSynchronousShapeTestLosProbe(
        origin.x, origin.y, origin.z, dx, dy, dz, 1 + 16 + 256, PlayerPedId(), 4)
    local _, hit, endCoords = GetShapeTestResult(handle)
    if hit == 1 or hit == true then
        return vec3(endCoords.x, endCoords.y, endCoords.z)
    end
    return vec3(dx, dy, dz)
end

local function cameraDelta(speed)
    local rad = math.rad(cam and camYaw or GetGameplayCamRot(2).z)
    local fx, fy = -math.sin(rad), math.cos(rad)
    local rx, ry = math.cos(rad), math.sin(rad)
    local dx, dy = 0.0, 0.0
    if IsDisabledControlPressed(0, KEY.forward) then dx = dx + fx * speed; dy = dy + fy * speed end
    if IsDisabledControlPressed(0, KEY.back)    then dx = dx - fx * speed; dy = dy - fy * speed end
    if IsDisabledControlPressed(0, KEY.right)   then dx = dx + rx * speed; dy = dy + ry * speed end
    if IsDisabledControlPressed(0, KEY.left)    then dx = dx - rx * speed; dy = dy - ry * speed end
    return dx, dy
end

function P.BlockControls()
    for i = 1, #BLOCKED do
        DisableControlAction(0, BLOCKED[i], true)
    end
end

function P.FlyCamera(speed)
    if not cam then return end

    local pos = GetCamCoord(cam)
    local dx, dy = cameraDelta(speed * 12.0)
    local dz = 0.0
    if IsDisabledControlPressed(0, KEY.up) then dz = dz + speed * 12.0 end
    if IsDisabledControlPressed(0, KEY.down) then dz = dz - speed * 12.0 end
    local nx, ny, nz = pos.x + dx, pos.y + dy, pos.z + dz
    SetCamCoord(cam, nx, ny, nz)
    SetFocusPosAndVel(nx, ny, nz, 0.0, 0.0, 0.0)
end

local function frameStep()
    local slow = IsDisabledControlPressed(0, KEY.slow)
    local fast = IsDisabledControlPressed(0, KEY.fast)
    local speed = slow and 0.02 or (fast and 0.35 or 0.08)
    P.BlockControls()
    updateCameraLook()
    P.FlyCamera(speed)
    return slow, aimPoint()
end

local function drawLines(lines, startY)
    local y = startY
    for i = 1, #lines do
        SetTextFont(4)
        SetTextScale(0.0, 0.42)
        SetTextColour(235, 235, 235, 235)
        SetTextOutline()
        SetTextCentre(true)
        SetTextEntry('STRING')
        AddTextComponentSubstringPlayerName(lines[i])
        DrawText(0.5, y)
        y = y + 0.028
    end
end

local PLACEMENT_HELP = {
    '~r~PLACEMENT MODE~s~',
    'W A S D  move        Q / E  up / down',
    '~y~<~s~ ~y~>~s~  rotate       G  snap to ground',
    'SHIFT  faster        CTRL  slower',
    '~g~ENTER~s~  confirm      ~r~BACKSPACE~s~  cancel',
}

local function polygonHelp(count)
    drawLines({
        '~r~ZONE EDITOR~s~',
        ('points placed: ~y~%d~s~   (minimum 3, maximum %d)'):format(count, MAX_POINTS),
        'W A S D  fly        Q / E  up / down        mouse  look',
        'SHIFT  faster       CTRL  slower',
        '~g~ENTER~s~  add point    ~y~G~s~  undo    ~y~DELETE~s~  clear',
        '~g~F~s~  finish shape     ~r~BACKSPACE~s~  cancel',
    }, 0.70)
end

function P.Begin(data)
    if active then return { ok = false, error = 'Placement is already active.' } end

    local c = data.coords
    if type(c) ~= 'table' or type(c.x) ~= 'number' then
        local ped = PlayerPedId()
        local pc = GetEntityCoords(ped)
        c = { x = pc.x, y = pc.y, z = pc.z, w = GetEntityHeading(ped) }
    end

    state = {
        path = data.path, slot = data.slot, patchKey = data.patchKey,
        kind = data.kind or 'coords', model = data.model, scenario = data.scenario,
        original = { x = c.x, y = c.y, z = c.z, w = c.w or 0.0 },
        current = { x = c.x, y = c.y, z = c.z, w = c.w or 0.0 },
    }

    if state.kind ~= 'coords' and state.model then
        Preview.Show({
            key = 'placement', model = state.model, kind = state.kind,
            coords = state.current, scenario = state.scenario,
        })
    end

    active = true
    UI.SetHidden(true)
    startCamera()

    CreateThread(function()
        while active do
            local slow, aim = frameStep()
            local cur = state.current
            cur.x, cur.y, cur.z = aim.x, aim.y, aim.z

            if IsDisabledControlPressed(0, KEY.rotL) then cur.w = (cur.w + (slow and 0.4 or 1.6)) % 360 end
            if IsDisabledControlPressed(0, KEY.rotR) then cur.w = (cur.w - (slow and 0.4 or 1.6)) % 360 end

            if IsDisabledControlJustPressed(0, KEY.snap) then
                local found, groundZ = GetGroundZFor_3dCoord(cur.x, cur.y, cur.z + 5.0, false)
                if found and groundZ then cur.z = groundZ end
            end

            local ghost = Preview.Get('placement')
            if ghost then
                SetEntityCoords(ghost, cur.x, cur.y, cur.z, false, false, false, false)
                SetEntityHeading(ghost, cur.w)
            else
                DrawMarker(1, cur.x, cur.y, cur.z - 0.9, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                    0.8, 0.8, 1.2, 62, 207, 142, 150, false, false, 2, false, nil, nil, false)
                local rad = math.rad(cur.w)
                DrawLine(cur.x, cur.y, cur.z, cur.x - math.sin(rad) * 1.5, cur.y + math.cos(rad) * 1.5,
                    cur.z, 62, 207, 142, 200)
            end

            drawLines(PLACEMENT_HELP, 0.72)

            if IsDisabledControlJustPressed(0, KEY.confirm) then
                return P.Finish(true)
            end
            if IsDisabledControlJustPressed(0, KEY.cancel) then
                return P.Finish(false)
            end

            Wait(0)
        end
    end)

    return { ok = true }
end

function P.Finish(confirmed)
    if not active then return end

    active = false
    local result = state
    state = nil
    stopCamera()
    Preview.Clear('placement')
    UI.SetHidden(false)

    if not result then return end

    local cur = result.current
    local coords = confirmed and {
        x = round(cur.x, '%.4f'), y = round(cur.y, '%.4f'),
        z = round(cur.z, '%.4f'), w = round(cur.w, '%.4f'),
    } or result.original

    local payload = { confirmed = confirmed == true, coords = coords }

    if result.slot then
        payload.slot = result.slot
        payload.patch = result.patchKey and { [result.patchKey] = coords } or nil
        SendNUIMessage({ action = 'rzAdminCreatePlacementDone', data = payload })
        return
    end

    payload.path = result.path
    SendNUIMessage({ action = 'rzAdminPlacementDone', data = payload })
end

function P.BeginPolygon(data)
    if active then return { ok = false, error = 'Something is already being edited in the world.' } end

    polygon = {}
    for i = 1, #((data and data.points) or {}) do
        local p = data.points[i]
        if type(p) == 'table' and type(p.x) == 'number' then
            polygon[#polygon + 1] = { x = p.x + 0.0, y = p.y + 0.0, z = p.z + 0.0 }
        end
    end

    active = true
    UI.SetHidden(true)
    startCamera()

    CreateThread(function()
        while active do
            local _, aim = frameStep()

            DrawMarker(1, aim.x, aim.y, aim.z - 0.9, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                1.2, 1.2, 1.6, 62, 207, 142, 140, false, false, 2, false, nil, nil, false)

            local n = #polygon
            if n > 0 then
                local last = polygon[n]
                DrawLine(last.x, last.y, last.z, aim.x, aim.y, aim.z, 62, 207, 142, 160)
                if n >= 2 then
                    local first = polygon[1]
                    DrawLine(aim.x, aim.y, aim.z, first.x, first.y, first.z, 62, 207, 142, 90)
                end
            end

            Preview.SetPolygon(polygon)
            polygonHelp(n)

            if IsDisabledControlJustPressed(0, KEY.confirm) then
                if n >= MAX_POINTS then
                    RZ.Notify.Show('admin.denied_raw', { ('A zone may have at most %d points.'):format(MAX_POINTS) }, 'error')
                else
                    polygon[#polygon + 1] = { x = aim.x, y = aim.y, z = aim.z }
                end
            end

            if IsDisabledControlJustPressed(0, KEY.undo) and #polygon > 0 then
                polygon[#polygon] = nil
            end

            if IsDisabledControlJustPressed(0, KEY.clear) then
                polygon = {}
            end

            if IsDisabledControlJustPressed(0, KEY.finish) then
                P.FinishPolygon(true)
                if not active then return end
            end

            if IsDisabledControlJustPressed(0, KEY.cancel) then
                return P.FinishPolygon(false)
            end

            Wait(0)
        end
    end)

    return { ok = true }
end

function P.FinishPolygon(confirmed)
    if not active then return end

    local points = polygon or {}

    if confirmed then
        if #points < 3 then
            RZ.Notify.Show('admin.denied_raw', { 'A zone needs at least 3 points.' }, 'error')
            return
        end
        local simple, why = RZ.Geo.IsSimplePolygon(points)
        if not simple then
            RZ.Notify.Show('admin.denied_raw', { 'That shape is not valid: ' .. tostring(why) }, 'error')
            return
        end
    end

    active = false
    polygon = nil
    stopCamera()
    Preview.SetPolygon(nil)
    UI.SetHidden(false)

    local minZ, maxZ = math.huge, -math.huge
    local out = {}
    for i = 1, #points do
        local p = points[i]
        if p.z < minZ then minZ = p.z end
        if p.z > maxZ then maxZ = p.z end
        out[i] = { x = round(p.x, '%.4f'), y = round(p.y, '%.4f'), z = round(p.z, '%.4f') }
    end
    if minZ == math.huge then minZ, maxZ = 0.0, 0.0 end

    SendNUIMessage({ action = 'rzAdminPolygonDone', data = {
        confirmed = confirmed == true,
        points = out,
        minZ = round(minZ - 100.0, '%.2f'),
        maxZ = round(maxZ + 500.0, '%.2f'),
    } })
end

function P.Cancel()
    if not active then return end
    if polygon then P.FinishPolygon(false) else P.Finish(false) end
end

function P.IsActive() return active end

local isOpen = false
local token = nil

function UI.Open(view)
    if isOpen then return end

    local grant = lib.callback.await(RZ.AdminCallback.OPEN, false)
    if type(grant) ~= 'table' or grant.ok ~= true then
        if grant and grant.message then
            RZ.Notify.Show('admin.denied_raw', { grant.message }, 'error')
        end
        return
    end

    token = grant.token
    isOpen = true
    local config = lib.callback.await(RZ.AdminCallback.GET_CONFIG, false, token)
    if type(config) ~= 'table' or config.ok ~= true then
        UI.Close()
        return
    end

    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'rzAdminOpen', data = {
        revision = grant.revision,
        schemaVersion = grant.schemaVersion,
        capabilities = grant.capabilities,
        config = config,
        view = view,
    } })
end

function UI.Close()
    if not isOpen then return end

    isOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'rzAdminClose' })
    P.Cancel()
    P.StopCamera()
    Preview.ClearAll()

    if token then
        local t = token
        token = nil
        CreateThread(function()
            pcall(function() lib.callback.await(RZ.AdminCallback.CLOSE, false, t) end)
        end)
    end
end

function UI.IsOpen() return isOpen end

function UI.Token() return token end

function UI.SetHidden(hidden)
    if not isOpen then return end
    SetNuiFocus(not hidden, not hidden)
    SendNUIMessage({ action = 'rzAdminHidden', data = { hidden = hidden } })
end

RegisterNetEvent(RZ.AdminEvent.OPEN, function(view)
    CreateThread(function() UI.Open(type(view) == 'string' and view or nil) end)
end)

local function callback(name, handler)
    RegisterNUICallback(name, function(data, cb)
        local ok, result = pcall(handler, type(data) == 'table' and data or {})
        if not ok then
            lib.print.error('[pr-redzone] admin UI error: ' .. tostring(result))
            cb({ ok = false, error = 'Client error.' })
            return
        end
        cb(result or { ok = false })
    end)
end

local FORWARDS = {
    rzAdminRefresh      = { 'GET_CONFIG' },
    rzAdminDashboard    = { 'DASHBOARD' },
    rzAdminInspect      = { 'INSPECT' },
    rzAdminDiagnostics  = { 'DIAGNOSTICS' },
    rzAdminValidate     = { 'VALIDATE', 'draft' },
    rzAdminPublish      = { 'PUBLISH', 'draft', 'opts' },
    rzAdminHistory      = { 'HISTORY', 'limit' },
    rzAdminLoadRevision = { 'LOAD_REVISION', 'revision' },
    rzAdminExport       = { 'EXPORT' },
    rzAdminSetWebhook   = { 'SET_WEBHOOK', 'url' },
    rzAdminTestLog      = { 'TEST_LOG' },
    rzAdminControl      = { 'CONTROL', 'action', 'payload' },
}

for name, route in pairs(FORWARDS) do
    callback(name, function(data)
        local args = { token }
        for i = 2, #route do args[i] = data[route[i]] end
        return lib.callback.await(RZ.AdminCallback[route[1]], false, table.unpack(args, 1, #route))
    end)
end

callback('rzAdminClose', function()
    UI.Close()
    return { ok = true }
end)

callback('rzAdminGetPosition', function()
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    return { ok = true, coords = { x = c.x, y = c.y, z = c.z, w = GetEntityHeading(ped) } }
end)

callback('rzAdminTeleport', function(data)
    local c = data.coords
    if type(c) ~= 'table' or type(c.x) ~= 'number' then return { ok = false } end

    local ped = PlayerPedId()
    local z = c.z + 0.0
    local found, groundZ = GetGroundZFor_3dCoord(c.x + 0.0, c.y + 0.0, z + 25.0, false)
    if found and groundZ then z = groundZ + 1.0 end

    SetEntityCoords(ped, c.x + 0.0, c.y + 0.0, z, false, false, false, false)
    if c.w then SetEntityHeading(ped, c.w + 0.0) end
    return { ok = true }
end)

callback('rzAdminValidateModel', function(data)
    local name = data.model
    if type(name) ~= 'string' or name == '' then
        return { ok = false, error = 'Enter a model name.' }
    end

    local hash, reason = RZ.Entities.TryLoadModel(name, 4000)
    if not hash then return { ok = false, error = reason } end

    local isPed = IsModelAPed(hash)
    SetModelAsNoLongerNeeded(hash)
    return {
        ok = true,
        isPed = isPed,
        expected = data.expect,
        mismatch = (data.expect == 'ped' and not isPed) or (data.expect == 'prop' and isPed),
    }
end)

callback('rzAdminPreview', function(data)
    if data.clear then
        Preview.ClearAll()
        return { ok = true }
    end
    return Preview.Show(data)
end)

callback('rzAdminPolygonPreview', function(data)
    Preview.SetPolygon(data.points)
    return { ok = true }
end)

local PLACEMENT_FIELDS = {
    rzAdminPlacement   = { 'path', 'kind', 'model', 'coords', 'scenario' },
    rzAdminCreatePlace = { 'slot', 'patchKey', 'kind', 'model' },
}

for name, fields in pairs(PLACEMENT_FIELDS) do
    callback(name, function(data)
        if not isOpen then return { ok = false } end
        local args = {}
        for i = 1, #fields do args[fields[i]] = data[fields[i]] end
        return P.Begin(args)
    end)
end

callback('rzAdminPolygon', function(data)
    if not isOpen then return { ok = false } end
    return P.BeginPolygon(data)
end)

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= RZ.RESOURCE then return end

    active = false
    state = nil
    polygon = nil
    stopCamera()
    polyPoints = nil
    for key in pairs(entities) do
        destroy(entities[key])
        entities[key] = nil
    end

    if isOpen then
        SetNuiFocus(false, false)
        isOpen = false
    end
end)

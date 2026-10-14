RZ = RZ or {}
RZ.SquadUI = {}

local UI = RZ.SquadUI
local Squad = RZ.SquadCallback

local LOCALE_PREFIXES = { 'squad.', 'error.' }

local isOpen = false

local function open(state)
    if isOpen then
        UI.Push(state)
        return
    end

    isOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open', data = state, locales = UI.GetLocales() })
end

local function close()
    if not isOpen then return end
    isOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

UI.Close = close

function UI.Push(state)
    SendNUIMessage({ action = 'state', data = state })
end

function UI.GetLocales()
    local out = {}

    for key, text in pairs(lib.getLocales()) do
        for i = 1, #LOCALE_PREFIXES do
            local prefix = LOCALE_PREFIXES[i]
            if key:sub(1, #prefix) == prefix then
                out[key] = text
                break
            end
        end
    end

    return out
end

RegisterNetEvent(RZ.SquadEvent.OPEN, function(state)
    if type(state) ~= 'table' then return end
    open(state)
end)

RegisterNetEvent(RZ.SquadEvent.STATE, function(state)
    if type(state) ~= 'table' then return end
    if isOpen then UI.Push(state) end
end)

RegisterNetEvent(RZ.SquadEvent.INVITE, function(data)
    if type(data) ~= 'table' or type(data.inviteId) ~= 'string' then return end

    SendNUIMessage({
        action = isOpen and 'invite' or 'inviteToast',
        data = data,
        locales = UI.GetLocales(),
    })

    RZ.Notify.Show('squad.invite_received_body', { data.squadName or '?' }, 'inform')

    SetTimeout((data.expiresInMs or 30000) + 1000, function()
        SendNUIMessage({ action = 'inviteExpired', data = { inviteId = data.inviteId } })
    end)
end)

local forwards = {
    { 'create', Squad.CREATE, function(d) return d.name or nil end },
    { 'invite', Squad.INVITE, function(d) return tonumber(d.serverId) or nil end },
    { 'respond', Squad.RESPOND, function(d) return d.inviteId or nil, d.accept == true end },
    { 'kick', Squad.KICK, function(d) return d.citizenid or nil end },
    { 'leave', Squad.LEAVE },
    { 'transfer', Squad.TRANSFER, function(d) return d.citizenid or nil end },
    { 'rename', Squad.RENAME, function(d) return d.name or nil end },
    { 'disband', Squad.DISBAND },
}

RegisterNUICallback('close', function(_, cb)
    close()
    cb({ ok = true })
end)

RegisterNUICallback('refresh', function(_, cb)
    cb(lib.callback.await(Squad.GET_STATE, false) or { eligible = false })
end)

for i = 1, #forwards do
    local name, callback, extract = forwards[i][1], forwards[i][2], forwards[i][3]

    RegisterNUICallback(name, function(data, cb)
        if type(data) ~= 'table' then data = {} end

        local result
        if extract then
            result = lib.callback.await(callback, false, extract(data))
        else
            result = lib.callback.await(callback, false)
        end

        cb(result or { ok = false, error = 'error.generic' })
    end)
end

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= RZ.RESOURCE then return end
    if isOpen then
        SetNuiFocus(false, false)
        isOpen = false
    end
end)

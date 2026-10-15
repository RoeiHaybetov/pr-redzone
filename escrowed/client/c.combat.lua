RZ = RZ or {}
RZ.Interactions = {}

local I = RZ.Interactions

local busy = false

local function once(fn)
    if busy then return end
    busy = true
    CreateThread(function()
        local ok, err = pcall(fn)
        if not ok then
            lib.print.error('[pr-redzone] interaction error: ' .. tostring(err))
        end
        busy = false
    end)
end

local function aliveInZone()
    return RZ.Client.IsInOpenZone() and RZ.Client.IsAlive()
end

local function crateReady()
    return aliveInZone() and RZ.Client.crate ~= nil
end

local function progressCallback(opts, watcher, callback, ...)
    if RZ.Progress.Run(opts, watcher) then
        lib.callback.await(callback, false, ...)
    end
end

function I.AttachCrate(prop)
    local zoneId = RZ.Zones.Current()
    local zone = zoneId and Config.Zones[zoneId]
    if not zone then return end
    RZ.Target.AddEntity(prop, { {
        name = 'pr_redzone_crate',
        icon = 'fa-solid fa-box-open',
        label = locale('crate.option'),
        distance = zone.crate.interactionDistance,
        canInteract = crateReady,
        onSelect = function()
            once(function()
                progressCallback({
                    label = locale('crate.progress'),
                    duration = zone.crate.lootDuration,
                    disableMovement = true,
                    anim = { dict = 'anim@heists@box_carry@', clip = 'idle', flag = 1 },
                }, crateReady, RZ.Callback.LOOT_CRATE)
            end)
        end,
    } })
end

function I.AttachSeller(ped, zoneId)
    local zone = Config.Zones[zoneId]
    if not zone then return end
    RZ.Target.AddEntity(ped, { {
        name = 'pr_redzone_sell',
        icon = 'fa-solid fa-sack-dollar',
        label = locale('seller.option'),
        distance = zone.seller.interactionDistance,
        canInteract = aliveInZone,
        onSelect = function()
            once(function()
                progressCallback({
                    label = locale('seller.progress'),
                    duration = 2500,
                    disableMovement = true,
                    anim = { dict = 'mp_common', clip = 'givetake1_a', flag = 1 },
                }, aliveInZone, RZ.Callback.SELL_PACKAGE)
            end)
        end,
    } })
end

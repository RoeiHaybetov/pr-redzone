RZ = RZ or {}
RZ.Knock = {}
RZ.Minigame = {}
RZ.Interactions = {}

local Knock = RZ.Knock
local Minigame = RZ.Minigame
local I = RZ.Interactions

local isDowned, downedConfig, requestInFlight = false, nil, false
local watchRunning, presentRunning = false, false
local activeClipset, crawlDictLoaded, crawlMode = nil, false, nil
local reviveGraceUntil = 0

local DISABLED_CONTROLS = {
    24, 25, 47, 58, 140, 141, 142, 143, 257, 263, 264,
    21, 22, 23, 75, 44, 37,
    157, 158, 159, 160, 161, 162, 163, 164, 165,
    288, 289, 170, 167, 73, 59, 60, 71, 72,
}
local MOVEMENT_CONTROLS = { 30, 31, 32, 33, 34, 35 }

local function debugInfo(msg) if Config.Debug then lib.print.info(msg) end end
local function debugWarn(msg) if Config.Debug then lib.print.warn(msg) end end

local function applyDownedControls()
    local playerId = PlayerId()
    for i = 1, #DISABLED_CONTROLS do
        DisableControlAction(0, DISABLED_CONTROLS[i], true)
    end
    if crawlDictLoaded then
        for i = 1, #MOVEMENT_CONTROLS do
            DisableControlAction(0, MOVEMENT_CONTROLS[i], true)
        end
    end
    DisablePlayerFiring(playerId, true)
    SetPlayerSprint(playerId, false)
    SetPedCanPlayAmbientAnims(PlayerPedId(), false)
end

function Knock.TryLoadClipset(name, timeoutMs)
    if type(name) ~= 'string' or name == '' then return false end
    local ok = pcall(lib.requestAnimSet, name, timeoutMs or 2000)
    return ok and HasAnimSetLoaded(name)
end

local function applyCrawl()
    local ped = PlayerPedId()
    local cfg = downedConfig
    if not cfg then return end
    activeClipset = nil
    crawlDictLoaded = false
    crawlMode = nil
    local crawl = cfg.crawl
    if crawl and crawl.dict then
        local ok = pcall(lib.requestAnimDict, crawl.dict, 3000)
        crawlDictLoaded = ok and HasAnimDictLoaded(crawl.dict)
    end
    if crawlDictLoaded then
        debugInfo(('[pr-redzone] crawl: GROUND CRAWL using dict "%s"'):format(crawl.dict))
        SetPedMoveRateOverride(ped, cfg.crawlSpeed + 0.0)
        return
    end
    debugWarn(('[pr-redzone] crawl: dict "%s" did NOT load — falling back to a movement clipset (this is a walk, not a crawl). Run /redzone_findcrawl to find a working asset.')
        :format(tostring(crawl and crawl.dict)))
    local candidates = cfg.crawlClipsets or {}
    for i = 1, #candidates do
        if Knock.TryLoadClipset(candidates[i]) then
            activeClipset = candidates[i]
            SetPedMovementClipset(ped, activeClipset, 1.0)
            break
        end
    end
    if activeClipset then
        debugInfo(('[pr-redzone] crawl: fallback clipset "%s" active'):format(activeClipset))
    else
        lib.print.warn(('[pr-redzone] crawl dictionary "%s" and every fallback clipset failed to load. Run /redzone_findcrawl.')
            :format(tostring(crawl and crawl.dict)))
    end
    SetPedMoveRateOverride(ped, cfg.crawlSpeed + 0.0)
end

local function updateCrawl(ped, cfg)
    local crawl = cfg.crawl
    local fwd = IsDisabledControlPressed(0, 32)
    local bwd = IsDisabledControlPressed(0, 33)
    local left = IsDisabledControlPressed(0, 34)
    local right = IsDisabledControlPressed(0, 35)
    if left or right then
        local turn = crawl.turnRate or 1.5
        SetEntityHeading(ped, GetEntityHeading(ped) + (left and turn or -turn))
    end
    local mode, dict, clip
    if fwd then
        mode, dict, clip = 'fwd', crawl.dict, crawl.forward
    elseif bwd then
        mode, dict, clip = 'bwd', crawl.dict, crawl.backward
    else
        mode, dict, clip = 'idle', crawl.idleDict, crawl.idleClip
    end
    if crawlMode ~= mode or not IsEntityPlayingAnim(ped, dict, clip, 3) then
        crawlMode = mode
        if not HasAnimDictLoaded(dict) then
            pcall(lib.requestAnimDict, dict, 1000)
        end
        TaskPlayAnim(ped, dict, clip, 8.0, -8.0, -1, 1, 0.0, false, false, false)
    end
end

-- Brings a dead ped back where it lies. NetworkResurrectLocalPlayer can hand back a new ped
-- handle, so callers must re-read PlayerPedId() afterwards.
local function resurrectInPlace(ped)
    if not IsEntityDead(ped) then return ped end
    local pos = GetEntityCoords(ped)
    local z = pos.z
    local found, groundZ = GetGroundZFor_3dCoord(pos.x, pos.y, pos.z + 2.0, false)
    if found and groundZ then z = groundZ + 0.15 end
    NetworkResurrectLocalPlayer(pos.x, pos.y, z, GetEntityHeading(ped), true, false)
    return PlayerPedId()
end

-- The death resource (or something else) took the ped while it was down: put it back on the
-- ground at downed health and restart the crawl, without restarting the presentation loop.
local function reassertDowned(cfg)
    local ped = resurrectInPlace(PlayerPedId())
    ClearPedTasksImmediately(ped)
    SetPedCanRagdoll(ped, false)
    SetEntityHealth(ped, cfg.downedHealth)
    RZ.MedicalCl.AssertAlive()
    SetCurrentPedWeapon(ped, joaat('WEAPON_UNARMED'), true)
    crawlMode = nil
end

local function enterLocalDowned(cfg)
    if isDowned then
        downedConfig = cfg
        if cfg.reassert then reassertDowned(cfg) end
        return
    end
    isDowned = true
    downedConfig = cfg
    local ped = resurrectInPlace(PlayerPedId())
    ClearPedTasksImmediately(ped)
    SetPedCanRagdoll(ped, false)
    SetEntityHealth(ped, cfg.downedHealth)
    RZ.MedicalCl.AssertAlive()
    LocalPlayer.state:set('invBusy', true, true)
    SetCurrentPedWeapon(ped, joaat('WEAPON_UNARMED'), true)
    applyCrawl()
    if presentRunning then return end
    presentRunning = true
    local lastMedicalCheck = 0
    local takeovers = 0
    CreateThread(function()
        while isDowned do
            local now = GetGameTimer()
            applyDownedControls()
            if crawlDictLoaded and downedConfig then
                updateCrawl(PlayerPedId(), downedConfig)
            end
            local p = PlayerPedId()
            local health = GetEntityHealth(p)
            if downedConfig.immuneWhileDowned then
                if health < downedConfig.downedHealth then
                    SetEntityHealth(p, downedConfig.downedHealth)
                end
            elseif health > 0 and health <= (downedConfig.finishThreshold or 5) then
                SetEntityHealth(p, 1)
            end
            SetPedMoveRateOverride(p, downedConfig.crawlSpeed + 0.0)
            if IsPedRagdoll(p) then
                ClearPedTasksImmediately(p)
            end
            if now - lastMedicalCheck >= 250 then
                lastMedicalCheck = now
                if RZ.MedicalCl.WasTakenOver() then
                    RZ.MedicalCl.AssertAlive()
                    takeovers = takeovers + 1
                    if takeovers == 8 then
                        lib.print.warn('[pr-redzone] another resource keeps changing the death state while you are downed. The knock system is holding it at ALIVE, but something is contesting it.')
                    end
                end
            end
            Wait(0)
        end
        presentRunning = false
    end)
end

function Knock.ClearLocalDowned()
    if not isDowned then
        local ped = PlayerPedId()
        if DoesEntityExist(ped) then
            SetPedMoveRateOverride(ped, 1.0)
            SetPedCanPlayAmbientAnims(ped, true)
        end
        return
    end
    isDowned = false
    local cfg = downedConfig
    downedConfig = nil
    crawlDictLoaded = false
    crawlMode = nil
    activeClipset = nil
    local ped = PlayerPedId()
    if DoesEntityExist(ped) then
        ResetPedMovementClipset(ped, 0.0)
        SetPedMoveRateOverride(ped, 1.0)
        SetPedCanPlayAmbientAnims(ped, true)
        SetPedCanRagdoll(ped, true)
        SetPlayerSprint(PlayerId(), true)
        if cfg and cfg.crawl then
            local c = cfg.crawl
            StopAnimTask(ped, c.dict, c.forward, 3.0)
            StopAnimTask(ped, c.dict, c.backward, 3.0)
            StopAnimTask(ped, c.idleDict, c.idleClip, 3.0)
        end
        ClearPedTasks(ped)
    end
    LocalPlayer.state:set('invBusy', false, true)
    RZ.Knock.remainingLabel = nil
end

function Knock.IsLocallyDowned()
    return isDowned
end

function Knock.BeginRestoreGrace(ms)
    reviveGraceUntil = GetGameTimer() + (ms or 3000)
end

RegisterNetEvent(RZ.Event.SET_DOWNED, function(enabled, cfg)
    if enabled and type(cfg) == 'table' then
        enterLocalDowned(cfg)
    else
        Knock.ClearLocalDowned()
    end
end)

local function requestDowned()
    if requestInFlight then return end
    requestInFlight = true
    CreateThread(function()
        local ok = pcall(function()
            return lib.callback.await(RZ.Callback.REQUEST_DOWNED, false)
        end)
        if not ok then
            RZ.Client.RequestSync()
        end
        Wait(500)
        requestInFlight = false
    end)
end

local function evaluateHealth()
    if not RZ.Client.IsInOpenZone() or not RZ.Client.IsAlive() or isDowned then return end
    local ped = PlayerPedId()
    local health = GetEntityHealth(ped)
    if reviveGraceUntil > 0 then
        if health > Config.Knock.lethalThreshold or GetGameTimer() >= reviveGraceUntil then
            reviveGraceUntil = 0
        else
            return
        end
    end
    if IsEntityDead(ped) or health <= 0 then
        requestDowned()
    elseif health <= Config.Knock.lethalThreshold then
        SetEntityHealth(ped, Config.Knock.downedHealth)
        requestDowned()
    end
end

local function startWatch()
    if watchRunning then return end
    watchRunning = true

    AddEventHandler('gameEventTriggered', function(event, data)
        if event ~= 'CEventNetworkEntityDamage' then return end
        if not watchRunning then return end
        if data[1] ~= PlayerPedId() then return end
        evaluateHealth()
    end)

    CreateThread(function()
        while watchRunning do
            if RZ.Client.IsInOpenZone() and RZ.Client.IsAlive() and not isDowned then
                evaluateHealth()
                Wait(200)
            else
                Wait(1000)
            end
        end
    end)
end

startWatch()

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName == RZ.RESOURCE then
        watchRunning = false
    end
end)

if Config.Debug then
    local function clipExists(dict, clip)
        local duration = GetAnimDuration(dict, clip)
        return duration and duration > 0, duration
    end

    RegisterCommand('redzone_testanim', function(_, args)
        local name = args[1]
        if not name then
            print('^3usage: /redzone_testanim <name>^7')
            print('^3  tests it as BOTH an animation dictionary and a movement clipset^7')
            print('^3  e.g.  /redzone_testanim move_crawl^7')
            return
        end
        local dictOk = pcall(lib.requestAnimDict, name, 4000)
        dictOk = dictOk and HasAnimDictLoaded(name)
        if dictOk then
            print(('^2"%s" loads as an ANIM DICTIONARY^7 — usable in Config.Knock.crawl.dict'):format(name))
            RemoveAnimDict(name)
        else
            print(('^1"%s" is not a valid anim dictionary^7'):format(name))
        end
        if Knock.TryLoadClipset(name, 4000) then
            print(('^2"%s" loads as a MOVEMENT CLIPSET^7 — usable in Config.Knock.crawlClipsets'):format(name))
            RemoveAnimSet(name)
        else
            print(('^1"%s" is not a valid movement clipset^7'):format(name))
        end
    end, false)

    RegisterCommand('redzone_findcrawl', function()
        local clipsets = {
            'move_injured_ground', 'move_crawl', 'move_prone',
            'move_m@injured', 'move_f@injured', 'move_m@drunk@verydrunk',
        }
        local dicts = {
            { 'move_crawl',           { 'onfront_fwd', 'onfront_bwd', 'onback_fwd', 'onback_bwd' } },
            { 'anim@move_crawl',      { 'onfront_fwd', 'onfront_bwd' } },
            { 'combat@damage@writhe', { 'writhe_loop', 'writhe_fwd', 'writhe_bwd', 'writhe_left', 'writhe_right' } },
            { 'move_injured_ground',  { 'onfront_fwd', 'onfront_bwd' } },
            { 'random@dealgonewrong', { 'idle_a' } },
        }

        print('^5================ pr-redzone crawl asset probe ================^7')
        print('^5-- movement clipsets (Config.Knock.crawlClipsets) --^7')
        local goodSets = {}
        for i = 1, #clipsets do
            local name = clipsets[i]
            if Knock.TryLoadClipset(name, 2500) then
                goodSets[#goodSets + 1] = name
                print(('  ^2LOADS^7  %s'):format(name))
                RemoveAnimSet(name)
            else
                print(('  ^1fail ^7  %s'):format(name))
            end
        end

        print('^5-- anim dictionaries + clips (Config.Knock.crawl) --^7')
        local goodClips = {}
        for i = 1, #dicts do
            local dict, clips = dicts[i][1], dicts[i][2]
            local ok = pcall(lib.requestAnimDict, dict, 2500)
            if ok and HasAnimDictLoaded(dict) then
                print(('  ^2DICT^7   %s'):format(dict))
                for j = 1, #clips do
                    local exists, dur = clipExists(dict, clips[j])
                    if exists then
                        goodClips[#goodClips + 1] = { dict = dict, clip = clips[j] }
                        print(('    ^2clip^7  %s  (%.2fs)'):format(clips[j], dur))
                    else
                        print(('    ^1----^7  %s'):format(clips[j]))
                    end
                end
                RemoveAnimDict(dict)
            else
                print(('  ^1fail ^7  %s'):format(dict))
            end
        end

        print('^5-- recommendation --^7')
        if #goodClips > 0 then
            print('  Put this in Config.Knock.crawl (pick a fwd/bwd pair from the same dict):')
            for i = 1, math.min(#goodClips, 8) do
                print(('    dict = \'%s\',  clip = \'%s\''):format(goodClips[i].dict, goodClips[i].clip))
            end
        else
            print('  ^1No crawl dictionary is available on this build.^7')
            print('  The ped will use a movement clipset instead (a walk, not a crawl).')
        end
        if #goodSets > 0 then
            print(('  Working clipsets: %s'):format(table.concat(goodSets, ', ')))
        end
        print('^5==============================================================^7')
    end, false)

    RegisterCommand('redzone_testclip', function(_, args)
        local dict, clip = args[1], args[2]
        if not dict or not clip then
            print('^3usage: /redzone_testclip <dict> <clip>   e.g. move_crawl onfront_fwd^7')
            return
        end
        local ok = pcall(lib.requestAnimDict, dict, 4000)
        if not (ok and HasAnimDictLoaded(dict)) then
            print(('^1dictionary "%s" failed to load^7'):format(dict))
            return
        end
        local exists, duration = clipExists(dict, clip)
        if exists then
            print(('^2"%s / %s" EXISTS^7 (%.2fs)'):format(dict, clip, duration))
        else
            print(('^1"%s / %s" does not exist in that dictionary^7'):format(dict, clip))
        end
        RemoveAnimDict(dict)
    end, false)
end

local cprActive = false
local CPR_DICT, CPR_CLIP = 'mini@cpr@char_a@cpr_str', 'cpr_pumpchest'

local function grade(offset, window)
    if offset <= window * 0.34 then return 'perfect', true end
    if offset <= window * 0.67 then return 'good', true end
    if offset <= window then return 'late', true end
    return 'miss', false
end

local function pushBeat(g, hits, misses, streak)
    SendNUIMessage({ action = 'rzCprBeat', data = { grade = g, hits = hits, misses = misses, streak = streak } })
end

function Minigame.RunCpr(opts, watcher)
    if cprActive then return false, 0, 0 end
    cprActive = true
    local control = opts.control or 22
    local beatInterval = 60000.0 / math.max(1, opts.bpm)
    local totalBeats = math.floor(opts.durationMs / beatInterval)
    if totalBeats < 1 then totalBeats = 1 end
    local startTime = GetGameTimer()
    local hits, misses, streak, consecutiveMisses = 0, 0, 0, 0
    local resolved = 0
    SendNUIMessage({
        action = 'rzCpr',
        data = {
            visible = true,
            durationMs = opts.durationMs,
            beatIntervalMs = beatInterval,
            totalBeats = totalBeats,
            hitWindowMs = opts.hitWindowMs,
            requiredAccuracy = opts.requiredAccuracy,
        },
    })
    local ped = PlayerPedId()
    if pcall(lib.requestAnimDict, CPR_DICT, 2000) then
        TaskPlayAnim(ped, CPR_DICT, CPR_CLIP, 8.0, -8.0, -1, 1, 0.0, false, false, false)
    end
    local completed = true
    while true do
        local now = GetGameTimer()
        local elapsed = now - startTime
        if elapsed >= opts.durationMs then break end
        if watcher and not watcher() then
            completed = false
            break
        end
        DisableControlAction(0, control, true)
        DisableControlAction(0, 24, true)
        DisableControlAction(0, 25, true)
        local beatIndex = math.floor(elapsed / beatInterval + 0.5)
        if beatIndex < 1 then beatIndex = 1 end
        if beatIndex > totalBeats then beatIndex = totalBeats end
        local beatTime = beatIndex * beatInterval
        local offset = math.abs(elapsed - beatTime)
        if resolved < beatIndex - 1 then
            local skipped = (beatIndex - 1) - resolved
            misses = misses + skipped
            consecutiveMisses = consecutiveMisses + skipped
            streak = 0
            resolved = beatIndex - 1
            pushBeat('miss', hits, misses, streak)
        end
        if IsDisabledControlJustPressed(0, control) then
            if resolved >= beatIndex then
                misses = misses + 1
                consecutiveMisses = consecutiveMisses + 1
                streak = 0
                pushBeat('early', hits, misses, streak)
            else
                local g, isHit = grade(offset, opts.hitWindowMs)
                resolved = beatIndex
                if isHit then
                    hits = hits + 1
                    streak = streak + 1
                    consecutiveMisses = 0
                    if not IsEntityPlayingAnim(ped, CPR_DICT, CPR_CLIP, 3) then
                        TaskPlayAnim(ped, CPR_DICT, CPR_CLIP, 8.0, -8.0, -1, 1, 0.0, false, false, false)
                    end
                else
                    misses = misses + 1
                    consecutiveMisses = consecutiveMisses + 1
                    streak = 0
                end
                pushBeat(g, hits, misses, streak)
            end
        end
        local limit = opts.maxConsecutiveMisses or 0
        if limit > 0 and consecutiveMisses >= limit then
            completed = false
            break
        end
        Wait(0)
    end
    cprActive = false
    SendNUIMessage({ action = 'rzCpr', data = { visible = false } })
    StopAnimTask(ped, CPR_DICT, CPR_CLIP, 2.0)
    return completed, hits, totalBeats
end

function Minigame.IsActive() return cprActive end

function Minigame.Abort()
    cprActive = false
    SendNUIMessage({ action = 'rzCpr', data = { visible = false } })
end

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName == RZ.RESOURCE then
        cprActive = false
    end
end)

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

local function peer(map, serverId)
    return map[tostring(serverId)] or map[serverId]
end

local function serverIdOf(entity)
    if not entity or entity == 0 then return nil end
    local playerIdx = NetworkGetPlayerIndexFromPed(entity)
    if not playerIdx or playerIdx == -1 then return nil end
    local serverId = GetPlayerServerId(playerIdx)
    if serverId <= 0 then return nil end
    return serverId
end

local function progressCallback(opts, watcher, callback, ...)
    if RZ.Progress.Run(opts, watcher) then
        lib.callback.await(callback, false, ...)
    end
end

function I.RegisterPlayerOptions()
    RZ.Target.AddPlayerOptions({
        {
            name = 'pr_redzone_revive',
            icon = 'fa-solid fa-hand-holding-medical',
            label = locale('revive.option'),
            distance = Config.Revive.maxDistance,
            canInteract = function(entity)
                if not aliveInZone() then return false end
                if RZ.Knock.IsLocallyDowned() then return false end
                local serverId = serverIdOf(entity)
                if not serverId then return false end
                return peer(RZ.Client.downedPeers, serverId) == true
            end,
            onSelect = function(data)
                local serverId = serverIdOf(data.entity)
                if not serverId then return end
                once(function() I.RunRevive(serverId) end)
            end,
        },
        {
            name = 'pr_redzone_acquire_head',
            icon = 'fa-solid fa-skull',
            label = locale('dna.option'),
            distance = Config.Elimination.acquireDistance,
            canInteract = function(entity)
                if not aliveInZone() then return false end
                local serverId = serverIdOf(entity)
                if not serverId then return false end
                return peer(RZ.Client.eliminatedPeers, serverId) ~= nil
            end,
            onSelect = function(data)
                local serverId = serverIdOf(data.entity)
                if not serverId then return end
                local deathId = peer(RZ.Client.eliminatedPeers, serverId)
                if not deathId then return end
                once(function() I.RunAcquireDna(deathId) end)
            end,
        },
    })
end

function I.RunRevive(targetServerId)
    local grant = lib.callback.await(RZ.Callback.BEGIN_REVIVE, false, targetServerId)
    if type(grant) ~= 'table' or not grant.token then return end
    local targetPed = GetPlayerPed(GetPlayerFromServerId(targetServerId))
    local function stillValid()
        if not aliveInZone() then return false end
        if RZ.Knock.IsLocallyDowned() then return false end
        if not DoesEntityExist(targetPed) then return false end
        local distance = #(GetEntityCoords(PlayerPedId()) - GetEntityCoords(targetPed))
        return distance <= Config.Revive.maxDistance
    end
    local completed, hits = false, nil
    if grant.minigame and grant.minigame.enabled then
        completed, hits = RZ.Minigame.RunCpr({
            durationMs = grant.durationMs,
            bpm = grant.minigame.bpm,
            hitWindowMs = grant.minigame.hitWindowMs,
            requiredAccuracy = grant.minigame.requiredAccuracy,
            control = grant.minigame.control,
            maxConsecutiveMisses = grant.minigame.maxConsecutiveMisses,
        }, stillValid)
    else
        completed = RZ.Progress.Run({
            label = locale('revive.progress'),
            duration = grant.durationMs,
            disableMovement = true,
            anim = { dict = 'mini@cpr@char_a@cpr_str', clip = 'cpr_pumpchest', flag = 1 },
        }, stillValid)
    end
    if completed then
        lib.callback.await(RZ.Callback.COMPLETE_REVIVE, false, targetServerId, grant.token, hits)
    else
        lib.callback.await(RZ.Callback.CANCEL_REVIVE, false, targetServerId, grant.token)
    end
end

function I.RunAcquireDna(deathId)
    progressCallback({
        label = locale('dna.option'),
        duration = 3000,
        disableMovement = true,
        anim = { dict = 'anim@gangops@facility@servers@bodysearch@', clip = 'player_search', flag = 1 },
    }, aliveInZone, RZ.Callback.ACQUIRE_HEAD, deathId)
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

local function stationOf(zoneId, stationIndex)
    local zone = Config.Zones[zoneId]
    return zone and zone.rebootStations[stationIndex]
end

local function buildStationOption(stationIndex, station)
    return {
        name = 'pr_redzone_station_' .. stationIndex,
        icon = 'fa-solid fa-server',
        label = locale('reboot.option'),
        distance = station.interactionDistance,
        canInteract = aliveInZone,
        onSelect = function()
            once(function() I.RunReboot() end)
        end,
    }
end

function I.AttachStation(prop, zoneId, stationIndex)
    local station = stationOf(zoneId, stationIndex)
    if not station then return end
    RZ.Target.AddEntity(prop, { buildStationOption(stationIndex, station) })
end

function I.AttachStationModel(model, zoneId, stationIndex)
    local station = stationOf(zoneId, stationIndex)
    if not station then return end
    RZ.Target.AddSphere('station:' .. RZ.Entities.StationKey(zoneId, stationIndex), {
        coords = vec3(station.propCoords.x, station.propCoords.y, station.propCoords.z),
        radius = station.interactionDistance,
        debug = false,
        options = { buildStationOption(stationIndex, station) },
    })
end

function I.RunReboot()
    local heads = lib.callback.await(RZ.Callback.LIST_DNA, false)
    if type(heads) ~= 'table' or #heads == 0 then
        RZ.Notify.Show('reboot.no_dna', nil, 'error')
        return
    end
    local options = {}
    for i = 1, #heads do
        local head = heads[i]
        options[#options + 1] = {
            title = locale('reboot.menu_entry', head.targetName),
            description = locale('reboot.menu_entry_desc', RZ.Util.FormatDuration(head.eliminatedAgoMs)),
            icon = head.online and 'fa-solid fa-user-check' or 'fa-solid fa-user-slash',
            disabled = not head.online,
            onSelect = function()
                once(function() I.StartReboot(head.serial) end)
            end,
        }
    end
    lib.registerContext({
        id = 'pr_redzone_reboot_menu',
        title = locale('reboot.menu_title'),
        options = options,
    })
    lib.showContext('pr_redzone_reboot_menu')
end

function I.StartReboot(serial)
    local grant = lib.callback.await(RZ.Callback.BEGIN_REBOOT, false, serial)
    if type(grant) ~= 'table' or not grant.token then return end
    local startCoords = GetEntityCoords(PlayerPedId())
    local completed = RZ.Progress.Run({
        label = locale('reboot.progress'),
        duration = grant.durationMs,
        disableMovement = true,
        anim = { dict = 'anim@heists@prison_heiststation@cop_reactions', clip = 'cop_b_idle', flag = 1 },
    }, function()
        if not aliveInZone() then return false end
        if RZ.Knock.IsLocallyDowned() then return false end
        return #(GetEntityCoords(PlayerPedId()) - startCoords) <= Config.Reboot.maxDistance
    end)
    if completed then
        lib.callback.await(RZ.Callback.COMPLETE_REBOOT, false, grant.token)
    else
        lib.callback.await(RZ.Callback.CANCEL_REBOOT, false, grant.token)
    end
end

AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName ~= RZ.RESOURCE then return end
    I.RegisterPlayerOptions()
end)

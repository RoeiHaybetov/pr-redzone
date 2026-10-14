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
        local excluded = Config.Gangs and Config.Gangs.notGangs
        local function usable(job)
            if type(job) ~= 'table' or type(job.name) ~= 'string' or job.name == '' then return false end
            if type(excluded) == 'table' then
                for i = 1, #excluded do
                    if excluded[i] == job.name then return false end
                end
            end
            return true
        end

        -- ESX has no gangs. Servers that run gangs on ESX almost always put them in a second
        -- job slot (esx_job2 and its forks), so that wins over the regular job when present.
        local job2 = player.job2
        if usable(job2) then return { name = job2.name, label = job2.label or job2.name }, true end
        if usable(player.job) then return { name = player.job.name, label = player.job.label or player.job.name }, true end
        return unaffiliated()
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

-- The full job table crosses a resource boundary on every call (it is serialised each
-- time), and the blocked-job check can ask for it per player per tick. Jobs change rarely,
-- so one copy is reused for a while.
local JOBS_CACHE_MS = 30000
local jobsCache, jobsCachedAt = nil, 0

function Fw.GetJobs()
    local now = GetGameTimer()
    if jobsCache and (now - jobsCachedAt) < JOBS_CACHE_MS then return jobsCache end
    local fn = GET_JOBS[resolve()]
    local jobs = fn and fn() or nil
    if type(jobs) ~= 'table' then return {} end
    jobsCache, jobsCachedAt = jobs, now
    return jobs
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

-- =============================================================================
--  Gang source detection
--
--  The gang a player belongs to can live in the framework (Qbox/QBCore PlayerData.gang,
--  an ESX second job) or in a separate gang resource with its own exports. At start-up,
--  and again whenever another resource starts or stops, every running resource that looks
--  like a gang system is probed for a player-gang export, and the first one that answers
--  becomes the primary source. The framework is always kept as the fallback, so a wrong
--  guess can only ever add gangs, never hide the ones the framework already knows.
-- =============================================================================

local KNOWN_GANG_RESOURCES = {
    'rcore_gangs', 'cs_gangs', 'brutal_gangs', 'ak47_gangs', 'ak47_qb_gangs', 'op-crime',
    'origen_ilegal', 'lunar_gangs', 'kibra-gangs', 'codem-gangs', '0r-gangs', 'jg-gangs',
    'tk_gangs', 'zat-gangs', 'qs-gangs', 'mGangs', 'drc_gangs', 'esx_gangs', 'pug-gangs',
}

-- Player-centric names only. A bare GetGang usually means "look a gang up by name", and
-- calling it with a server id would quietly report nobody as being in a gang.
local GANG_EXPORT_GUESSES = {
    'GetPlayerGang', 'getPlayerGang', 'GetPlayerGangData', 'getPlayerGangData',
    'GetGangByPlayer', 'getGangByPlayer', 'GetPlayerGangName', 'getPlayerGangName',
    'GetPlayerOrganisation', 'getPlayerOrganisation', 'GetPlayerOrganization', 'getPlayerOrganization',
    'GetPlayerOrg', 'getPlayerOrg', 'GetPlayerCrew', 'getPlayerCrew',
    'GetPlayerFaction', 'getPlayerFaction', 'GetPlayerFamily', 'getPlayerFamily',
}

local GANG_NAME_HINTS = { 'gang', 'crime', 'organi', 'faction', 'crew', 'mafia', 'cartel', 'famil', 'ilegal', 'illegal' }

local NOT_GANG_SOURCES = {
    ['qb-gangs'] = true, ['qb-gangmenu'] = true, ['qb-management'] = true, ['qbx_management'] = true,
    ['qb-bossmenu'] = true, ['esx_society'] = true,
}

local gangSource = nil   -- { resource, export, label } or false when only the framework is used
local gangArgMode = nil  -- 'source' | 'identity', learned from the first real answer
local gangCache = {}
local GANG_CACHE_MS = 2000
local labelCache = {}

local function cfgGangs()
    return Config.Gangs or {}
end

local function exportExists(resource, name)
    local ok, err = pcall(function() return exports[resource][name](exports[resource], -1) end)
    if ok then return true end
    err = tostring(err)
    return not (err:find('No such export', 1, true) or err:find('does not exist', 1, true))
end

local function looksLikeGangResource(name)
    local lowered = name:lower()
    for i = 1, #GANG_NAME_HINTS do
        if lowered:find(GANG_NAME_HINTS[i], 1, true) then return true end
    end
    return false
end

local function candidateResources()
    local list, seen = {}, {}
    local function add(name)
        if seen[name] or name == RZ.RESOURCE or NOT_GANG_SOURCES[name] then return end
        if GetResourceState(name) ~= 'started' then return end
        seen[name] = true
        list[#list + 1] = name
    end
    for i = 1, #KNOWN_GANG_RESOURCES do add(KNOWN_GANG_RESOURCES[i]) end
    for i = 0, GetNumResources() - 1 do
        local name = GetResourceByFindIndex(i)
        if type(name) == 'string' and looksLikeGangResource(name) then add(name) end
    end
    return list
end

function Gangs.Detect(quiet)
    gangCache = {}
    gangArgMode = nil

    local cfg = cfgGangs()
    if type(cfg.resource) == 'string' and cfg.resource ~= '' and cfg.resource ~= 'auto' then
        if cfg.resource == 'framework' then
            gangSource = false
        elseif GetResourceState(cfg.resource) == 'started' then
            local export = cfg.export
            if type(export) ~= 'string' or export == '' then
                for i = 1, #GANG_EXPORT_GUESSES do
                    if exportExists(cfg.resource, GANG_EXPORT_GUESSES[i]) then
                        export = GANG_EXPORT_GUESSES[i]
                        break
                    end
                end
            end
            gangSource = export and { resource = cfg.resource, export = export } or false
        else
            gangSource = false
            print(('^3[pr-redzone] Config.Gangs.resource is "%s" but that resource is not started — using framework gangs.^0')
                :format(cfg.resource))
        end
    else
        gangSource = false
        local candidates = candidateResources()
        for i = 1, #candidates do
            local resource = candidates[i]
            for j = 1, #GANG_EXPORT_GUESSES do
                if exportExists(resource, GANG_EXPORT_GUESSES[j]) then
                    gangSource = { resource = resource, export = GANG_EXPORT_GUESSES[j] }
                    break
                end
            end
            if gangSource then break end
        end
    end

    if quiet then return gangSource end

    local fallback = ('%s gangs'):format(Fw.Describe())
    if Fw.Flavour() == 'esx' then fallback = 'es_extended job2 / job' end
    if gangSource then
        print(('[pr-redzone] gangs: reading exports["%s"]:%s(player), with %s as the fallback.')
            :format(gangSource.resource, gangSource.export, fallback))
    else
        print(('[pr-redzone] gangs: no separate gang resource found — using %s.'):format(fallback))
    end

    local solo = cfg.soloGangs
    local soloText = type(solo) == 'table' and #solo > 0 and table.concat(solo, ', ') or '(none)'
    if cfg.requireGang ~= false then
        print(('[pr-redzone] gangs: players with no gang cannot see or enter the RedZone. Solo gang: %s.')
            :format(soloText))
    else
        print('[pr-redzone] gangs: players with no gang fight as Solo Squads (Config.Gangs.requireGang = false).')
    end
    return gangSource
end

local function normalizeGang(value, depth)
    local t = type(value)
    if t == 'string' then
        if value == '' then return nil end
        return { name = value, label = value }
    end
    if t ~= 'table' or (depth or 0) > 2 then return nil end

    for _, key in ipairs({ 'name', 'gang', 'gangName', 'gang_name', 'organisation', 'organization', 'tag', 'label', 'id' }) do
        local v = value[key]
        if type(v) == 'number' then v = tostring(v) end
        if type(v) == 'string' and v ~= '' then
            local label = value.label or value.title or value.displayName or value.display or v
            return { name = v, label = type(label) == 'string' and label or v }
        end
    end

    for _, key in ipairs({ 'gang', 'data', 'organisation', 'organization' }) do
        if type(value[key]) == 'table' then return normalizeGang(value[key], (depth or 0) + 1) end
    end
    return nil
end

local function callGangExport(source)
    if not gangSource then return nil end
    local resource, export = gangSource.resource, gangSource.export
    if GetResourceState(resource) ~= 'started' then return nil end

    local function call(arg)
        local ok, res = pcall(function() return exports[resource][export](exports[resource], arg) end)
        if not ok then return nil, false end
        return normalizeGang(res), true
    end

    if gangArgMode ~= 'identity' then
        local gang = call(source)
        if gang then gangArgMode = 'source' return gang end
        if gangArgMode == 'source' then return nil end
    end

    local identity = Fw.Identity(source)
    if identity then
        local gang = call(identity)
        if gang then gangArgMode = 'identity' return gang end
    end
    return nil
end

local function frameworkGang(source)
    local gang, loaded = Fw.Gang(source)
    if not loaded then return nil, false end
    return normalizeGang(gang), true
end

local function readGang(source)
    if gangSource == nil then Gangs.Detect(true) end

    local fromExport = callGangExport(source)
    local fromFramework, loaded = frameworkGang(source)

    if not loaded and Fw.IsStandalone() then
        loaded = GetPlayerName(source) ~= nil
    end
    if not loaded then return nil, false end

    local function real(g)
        if not g then return false end
        local n = g.name:lower()
        return n ~= NO_GANG and n ~= 'unemployed'
    end

    if real(fromExport) then return fromExport, true end
    if real(fromFramework) then return fromFramework, true end

    local ply = Player(source)
    local bag = ply and ply.state and (ply.state.gang or ply.state.gangName)
    local fromBag = normalizeGang(bag)
    if real(fromBag) then return fromBag, true end

    return fromExport or fromFramework or fromBag, true
end

local function matchesList(gang, list)
    if type(list) ~= 'table' then return false end
    local name = gang.name:lower()
    local label = type(gang.label) == 'string' and gang.label:lower() or nil
    for i = 1, #list do
        local entry = tostring(list[i]):lower()
        if entry == name or entry == label then return true end
    end
    return false
end

local function gangExists(name)
    if gangSource then return true end
    local f = Fw.Flavour()
    if f ~= 'qbx' and f ~= 'qb' then return true end
    return Fw.GetGang(name) ~= nil
end

-- 'gang' | 'solo' | 'none' | 'invalid', or nil when the player's data is not loaded yet.
function Gangs.Classify(source)
    local now = GetGameTimer()
    local cached = gangCache[source]
    if cached and (now - cached.at) < GANG_CACHE_MS then
        return cached.kind, cached.name, cached.label
    end

    local gang, loaded = readGang(source)
    local kind, name, label
    if loaded then
        local cfg = cfgGangs()
        if not gang or gang.name == '' or gang.name:lower() == NO_GANG
            or matchesList(gang, cfg.notGangs) then
            kind = 'none'
        elseif matchesList(gang, cfg.soloGangs) then
            kind, name, label = 'solo', gang.name, gang.label
        elseif not gangExists(gang.name) then
            kind, name = 'invalid', gang.name
        else
            kind, name, label = 'gang', gang.name, gang.label
            labelCache[name] = label
        end
    end

    gangCache[source] = { at = now, kind = kind, name = name, label = label }
    return kind, name, label
end

function Gangs.Describe()
    if gangSource == nil then Gangs.Detect(true) end
    if gangSource then
        return ('exports["%s"]:%s, framework as fallback'):format(gangSource.resource, gangSource.export), true
    end
    return ('%s gangs'):format(Fw.Describe()), false
end

function Gangs.Forget(source)
    if source then gangCache[source] = nil else gangCache = {} end
end

function Gangs.GetPlayerGang(source)
    local kind, name, label = Gangs.Classify(source)
    if kind == nil then return nil, false end
    if kind == 'none' then return { name = NO_GANG, label = 'No Gang' }, true end
    return { name = name, label = label or name }, true
end

function Gangs.Exists(gangId)
    if type(gangId) ~= 'string' or gangId == '' then return false end
    return gangExists(gangId)
end

local function resolveGang(source)
    local kind, name = Gangs.Classify(source)
    if kind == nil then return nil, RZ.Reject.UNVERIFIABLE end
    if kind == 'gang' then return name, nil end
    if kind == 'solo' then return nil, RZ.Reject.SOLO end
    if kind == 'invalid' then return nil, RZ.Reject.INVALID_GANG end
    if cfgGangs().requireGang ~= false then return nil, RZ.Reject.NO_GANG end
    return nil, RZ.Reject.SOLO
end

function Gangs.GetStableGangId(source)
    return (resolveGang(source))
end

function Gangs.GetGangLabel(gangId)
    if labelCache[gangId] then return labelCache[gangId] end
    local gang = (not gangSource) and RZ.Fw.GetGang(gangId) or nil
    return (gang and gang.label) or gangId
end

-- True only for a player who plays as a Solo Squad: someone in a configured solo gang,
-- or, with requireGang off, anyone with no gang at all.
function Gangs.IsSolo(source)
    local _, reason = resolveGang(source)
    return reason == RZ.Reject.SOLO
end

-- The RedZone exists for this player at all: in a real gang, or a solo player while Solo
-- Squads are on. Everyone else neither sees the zone nor is let into it.
function Gangs.IsAffiliated(source)
    local gangId, reason = resolveGang(source)
    if gangId then return true end
    return reason == RZ.Reject.SOLO and Config.SoloSquads.enabled == true
end

AddEventHandler('onResourceStart', function(resource)
    if resource == RZ.RESOURCE or gangSource == nil then return end
    if looksLikeGangResource(resource) or resource == cfgGangs().resource then
        SetTimeout(1000, function() Gangs.Detect() end)
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == RZ.RESOURCE then return end
    if gangSource and gangSource.resource == resource then
        SetTimeout(500, function() Gangs.Detect() end)
    end
end)

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
    Gangs.Forget(source)
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

-- qb-ambulancejob keeps its laststand and death screen in client-local variables, so
-- clearing the metadata alone leaves its timer running and it kills the player later. Its
-- own revive event is the only thing that resets those, so it is fired before ours.
function Medical.ReleaseClient(source)
    if RZ.Fw.Flavour() ~= 'qb' then return end
    TriggerClientEvent('hospital:client:Revive', source)
end

function Medical.ReclaimDowned(source)
    setDeathState(source, DEATH_STATE.ALIVE)
    Medical.ReleaseClient(source)
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

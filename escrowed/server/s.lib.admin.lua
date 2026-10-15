RZ = RZ or {}

RZ.AdminAuth, RZ.AdminSessions, RZ.AdminAudit, RZ.AdminValidate = {}, {}, {}, {}
RZ.AdminStore, RZ.AdminApply, RZ.AdminSync = {}, {}, {}
RZ.AdminPublish, RZ.AdminDiag, RZ.AdminControls = {}, {}, {}

local Auth, Sessions, Audit, V = RZ.AdminAuth, RZ.AdminSessions, RZ.AdminAudit, RZ.AdminValidate
local Store, Apply, Sync = RZ.AdminStore, RZ.AdminApply, RZ.AdminSync
local P, Diag, Controls = RZ.AdminPublish, RZ.AdminDiag, RZ.AdminControls
local S = RZ.Serializer

local SPECIAL_PATHS = { ['Logging.webhook'] = { sensitive = true, preserved = true } }

local function online(source) return GetPlayerName(source) ~= nil end

local function safe(fn, fallback)
    local ok, value = pcall(fn)
    if ok and value ~= nil then return value end
    return fallback
end

local function fail(result, message)
    result.errors[#result.errors + 1] = message
    return result
end

Auth.Deny = { DISABLED = 'disabled', NO_DISCORD = 'no_discord', NOT_ALLOWED = 'not_allowed', BAD_SOURCE = 'bad_source' }

function Auth.GetDiscordId(source)
    if type(source) ~= 'number' or source <= 0 then return nil end
    local identifiers = GetPlayerIdentifiers(source)
    if not identifiers then return nil end
    for i = 1, #identifiers do
        local id = identifiers[i]
        if type(id) == 'string' and id:sub(1, 8) == 'discord:' then
            local raw = id:sub(9)
            if raw ~= '' then return raw end
        end
    end
    return nil
end

function Auth.IsWhitelisted(discordId)
    if type(discordId) ~= 'string' or discordId == '' then return false end
    local list = Config.AdminMenu and Config.AdminMenu.allowedDiscordIds
    if type(list) ~= 'table' then return false end
    for i = 1, #list do
        if (tostring(list[i]):gsub('^discord:', '')) == discordId then return true end
    end
    return false
end

function Auth.Check(source)
    if type(source) ~= 'number' or source <= 0 or not online(source) then return false, Auth.Deny.BAD_SOURCE end
    if not Config.AdminMenu or Config.AdminMenu.enabled ~= true then return false, Auth.Deny.DISABLED end
    local discordId = Auth.GetDiscordId(source)
    if not discordId then return false, Auth.Deny.NO_DISCORD end
    if not Auth.IsWhitelisted(discordId) then return false, Auth.Deny.NOT_ALLOWED end
    return true, discordId
end

function Auth.DenyMessage(reason)
    if reason == Auth.Deny.DISABLED then return 'The RedZone Administration Menu is currently disabled.' end
    if reason == Auth.Deny.NO_DISCORD then return 'Access denied. Your Discord account could not be verified.' end
    return 'Access denied. You are not authorized to use the RedZone Administration Menu.'
end

function Auth.Mask(discordId)
    if type(discordId) ~= 'string' or #discordId < 6 then return '••••' end
    return ('%s••••%s'):format(discordId:sub(1, 4), discordId:sub(-3))
end

function Auth.ReportConfiguration()
    if not Config.AdminMenu or Config.AdminMenu.enabled ~= true then
        RZ.Log.Info('admin menu: disabled in config.')
        return
    end
    local list = Config.AdminMenu.allowedDiscordIds or {}
    if #list == 0 then
        RZ.Log.Info('admin menu: ENABLED but the Discord whitelist is EMPTY — nobody can open it.')
        RZ.Log.Info('admin menu: add raw Discord user ids to Config.AdminMenu.allowedDiscordIds.')
        return
    end
    local malformed = 0
    for i = 1, #list do
        if not tostring(list[i]):gsub('^discord:', ''):match('^%d+$') then malformed = malformed + 1 end
    end
    RZ.Log.Info(('admin menu: enabled, %d Discord id(s) whitelisted.'):format(#list))
    if malformed > 0 then
        RZ.Log.Info(('admin menu: WARNING — %d whitelisted id(s) are not plain numbers. A Discord user id is all digits.'):format(malformed))
    end
end

local sessions = {}

local function timeoutMs()
    return math.max(1, (Config.AdminMenu and Config.AdminMenu.sessionTimeoutMinutes) or 30) * 60 * 1000
end

function Sessions.Create(source, discordId)
    local now = RZ.Mono()
    local session = {
        source = source, discordId = discordId,
        citizenid = RZ.Fw.Identity(source),
        name = GetPlayerName(source) or ('player_' .. tostring(source)),
        token = RZ.Id.New('adm'),
        createdAt = now, lastActivity = now, expiresAt = now + timeoutMs(),
    }
    sessions[source] = session
    return session
end

function Sessions.Get(source)
    local session = sessions[source]
    if not session then return nil end
    if RZ.Mono() > session.expiresAt then
        sessions[source] = nil
        return nil
    end
    return session
end

function Sessions.Touch(source)
    local session = sessions[source]
    if not session then return end
    session.lastActivity = RZ.Mono()
    session.expiresAt = session.lastActivity + timeoutMs()
end

function Sessions.Destroy(source) sessions[source] = nil end

function Sessions.DestroyAll() sessions = {} end

function Sessions.Sweep()
    local now = RZ.Mono()
    for source, session in pairs(sessions) do
        if now > session.expiresAt or not online(source) then sessions[source] = nil end
    end
end

function Sessions.Count()
    local n = 0
    for _ in pairs(sessions) do n = n + 1 end
    return n
end

function Sessions.Guard(source, action, token)
    if type(source) ~= 'number' or source <= 0 or not online(source) then return false, 'bad_source' end

    local authorised, discordId = Auth.Check(source)
    if not authorised then
        RZ.Log.Suspicious(source, action, 'admin action without authorisation: ' .. tostring(discordId))
        return false, discordId
    end

    if not RZ.Rate.Consume(source, action) then
        RZ.Log.Suspicious(source, action, 'admin rate limit exceeded')
        return false, 'rate_limited'
    end

    local session = Sessions.Get(source)
    if not session then return false, 'no_session' end

    if session.discordId ~= discordId then
        Sessions.Destroy(source)
        RZ.Log.Suspicious(source, action, 'admin session Discord id changed — session destroyed')
        return false, 'identity_changed'
    end

    if token ~= nil and session.token ~= token then
        RZ.Log.Suspicious(source, action, 'admin session token mismatch')
        return false, 'bad_token'
    end

    Sessions.Touch(source)
    return true, session
end

function Audit.Write(session, action, zoneId, detail, success, failureReason, revision)
    local discordId = session and session.discordId or 'unknown'
    local name = session and session.name or nil
    RZ.Db.InsertAdminAudit({
        discord_id = discordId, player_name = name,
        citizenid = session and session.citizenid or nil,
        action = action, zone_id = zoneId, detail = detail,
        success = success ~= false, failure_reason = failureReason, revision = revision,
    })
    local line = ('[admin] %s by %s (%s)%s%s'):format(action, name or 'unknown', Auth.Mask(discordId),
        zoneId and (' zone=' .. zoneId) or '', detail and (' — ' .. detail) or '')
    if success == false then
        RZ.Log.Suspicious(session and session.source or 0, 'admin:' .. action, (failureReason or 'failed') .. ' — ' .. line)
    else
        RZ.Log.Write('adminAction', 'AdminAction', line, 'blue')
    end
end

function Audit.Denied(source, reason)
    local discordId = Auth.GetDiscordId(source) or 'none'
    RZ.Db.InsertAdminAudit({
        discord_id = discordId, player_name = GetPlayerName(source), citizenid = nil,
        action = 'access_denied', zone_id = nil, detail = nil,
        success = false, failure_reason = reason, revision = nil,
    })
    RZ.Log.Suspicious(source, 'adminMenu',
        ('refused admin menu access (%s), discord=%s'):format(reason, Auth.Mask(discordId)))
end

local WORLD_LIMIT = 20000.0
local WORLD_Z_MIN, WORLD_Z_MAX = -1000.0, 5000.0
local MAX_POINTS, MAX_ZONE_ID = 64, 32

local function isFiniteNumber(n)
    return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end

local function validateString(s, maxLength)
    local max = maxLength or 128
    if type(s) ~= 'string' then return false, 'expected text' end
    if #s > max then return false, ('too long (max %d)'):format(max) end
    if s:find('[%z\1-\31\127]') then return false, 'contains control characters' end
    if s:find('[<>]') then return false, 'HTML tags are not allowed' end
    local lower = s:lower()
    if lower:find('javascript:') or lower:find('</') then return false, 'script content is not allowed' end
    return true
end

local function validateIdentifier(s, maxLength)
    local ok, err = validateString(s, maxLength or 64)
    if not ok then return false, err end
    if s == '' then return false, 'cannot be empty' end
    if not s:match('^[%w_%-@%.]+$') then return false, 'may only contain letters, numbers, _ - @ .' end
    return true
end

V.IsFiniteNumber, V.ValidateString, V.ValidateIdentifier = isFiniteNumber, validateString, validateIdentifier

local function checkNumber(field, value)
    if not isFiniteNumber(value) then return false, 'must be a finite number' end
    if field.type == 'int' and value ~= math.floor(value) then return false, 'must be a whole number' end
    if field.min and value < field.min then return false, ('minimum is %s'):format(field.min) end
    if field.max and value > field.max then return false, ('maximum is %s'):format(field.max) end
    return true
end

local function checkVector(field, value)
    local isVec, hasW = S.IsVector(value)
    if not isVec then return false, 'expected coordinates' end
    if field.type == 'vec4' and not hasW then return false, 'a heading is required' end
    for _, key in ipairs({ 'x', 'y' }) do
        local n = value[key]
        if not isFiniteNumber(n) then return false, key .. ' is not a number' end
        if math.abs(n) > WORLD_LIMIT then return false, key .. ' is outside the world' end
    end
    if not isFiniteNumber(value.z) then return false, 'z is not a number' end
    if value.z < WORLD_Z_MIN or value.z > WORLD_Z_MAX then return false, 'z is outside the world' end
    if hasW and not isFiniteNumber(value.w) then return false, 'heading is not a number' end
    return true
end

local function checkTagList(field, value)
    if type(value) ~= 'table' then return false, 'expected a list' end
    local max, count = field.maxItems or 64, 0
    for _, v in ipairs(value) do
        count = count + 1
        if count > max then return false, ('too many entries (max %d)'):format(max) end
        local ok, err = validateString(v, field.maxLength or 64)
        if not ok then return false, ('entry "%s": %s'):format(tostring(v), err) end
    end
    return true
end

local fieldCheck = {
    number = checkNumber, int = checkNumber,
    vec3 = checkVector, vec4 = checkVector,
    tags = checkTagList, clipsets = checkTagList,

    bool = function(_, value)
        if type(value) ~= 'boolean' then return false, 'expected true or false' end
        return true
    end,

    string = function(field, value)
        if field.modelCheck or field.itemCheck then return validateIdentifier(value, field.maxLength) end
        return validateString(value, field.maxLength or 128)
    end,

    select = function(field, value)
        if type(value) ~= 'string' then return false, 'expected a choice' end
        local options = field.options or {}
        for i = 1, #options do
            if options[i] == value then return true end
        end
        return false, 'not one of the allowed options'
    end,

    rewards = function(field, value)
        if type(value) ~= 'table' then return false, 'expected a list' end
        local seen, count = {}, 0
        for _, row in ipairs(value) do
            count = count + 1
            if count > (field.maxItems or 12) then return false, 'too many reward rows' end
            if type(row) ~= 'table' then return false, 'malformed reward row' end
            local okItem, errItem = validateIdentifier(row.item, 64)
            if not okItem then return false, ('reward item: %s'):format(errItem) end
            if not isFiniteNumber(row.amount) or row.amount ~= math.floor(row.amount) then
                return false, ('reward "%s": amount must be a whole number'):format(row.item)
            end
            if row.amount < 1 or row.amount > 100000 then
                return false, ('reward "%s": amount must be between 1 and 100000'):format(row.item)
            end
            if seen[row.item] then return false, ('duplicate reward item "%s"'):format(row.item) end
            seen[row.item] = true
        end
        return true
    end,

    ratelimits = function(_, value)
        if type(value) ~= 'table' then return false, 'expected a table' end
        for action, limit in pairs(value) do
            if not validateIdentifier(action, 48) then return false, ('bad action name "%s"'):format(tostring(action)) end
            if type(limit) ~= 'table' then return false, ('%s: malformed'):format(action) end
            if not isFiniteNumber(limit.max) or limit.max ~= math.floor(limit.max)
                or limit.max < 1 or limit.max > 1000 then
                return false, ('%s: max must be a whole number from 1 to 1000'):format(action)
            end
            if not isFiniteNumber(limit.windowMs) or limit.windowMs ~= math.floor(limit.windowMs)
                or limit.windowMs < 500 or limit.windowMs > 3600000 then
                return false, ('%s: window must be from 500 to 3600000 ms'):format(action)
            end
        end
        return true
    end,

    boolmap = function(_, value)
        if type(value) ~= 'table' then return false, 'expected a table' end
        for key, v in pairs(value) do
            if not validateIdentifier(key, 48) then return false, ('bad key "%s"'):format(tostring(key)) end
            if type(v) ~= 'boolean' then return false, ('%s must be true or false'):format(key) end
        end
        return true
    end,
}

function V.Field(field, value)
    if type(field) ~= 'table' then return false, 'unknown field' end
    local check = fieldCheck[field.type]
    if not check then return false, ('unsupported field type "%s"'):format(tostring(field.type)) end
    return check(field, value)
end

local function checkInside(err, zone, zoneId, label, coords)
    if not S.IsVector(coords) then
        err('Zone "%s": %s is not a valid coordinate.', zoneId, label)
        return
    end
    local p = vec3(coords.x, coords.y, coords.z)
    if not RZ.Geo.PointInPolygon(p, zone.points) then
        local _, _, edge = RZ.Geo.NearestEdgePoint(p, zone.points)
        err('Zone "%s": the %s is %.1fm OUTSIDE the zone edge — it would be unusable.', zoneId, label, edge)
    elseif isFiniteNumber(zone.minZ) and coords.z < zone.minZ then
        err('Zone "%s": the %s sits %.1fm below the zone floor — it would be unusable.', zoneId, label, zone.minZ - coords.z)
    elseif isFiniteNumber(zone.maxZ) and coords.z > zone.maxZ then
        err('Zone "%s": the %s sits %.1fm above the zone ceiling — it would be unusable.', zoneId, label, coords.z - zone.maxZ)
    end
end

local function checkZoneShape(err, zone, zoneId)
    local points = zone.points
    if type(points) ~= 'table' or #points < 3 then
        err('Zone "%s": needs at least 3 points. Draw its shape with /redzonecreate.', zoneId)
        return false
    end
    if #points > MAX_POINTS then
        err('Zone "%s": %d points is too many (max %d).', zoneId, #points, MAX_POINTS)
        return false
    end
    for i = 1, #points do
        if not S.IsVector(points[i]) then
            err('Zone "%s": point %d is not a valid coordinate.', zoneId, i)
            return false
        end
    end
    local simple, why = RZ.Geo.IsSimplePolygon(points)
    if not simple then
        err('Zone "%s": the shape is invalid (%s). Edges may not cross and points may not sit on top of each other.',
            zoneId, tostring(why))
        return false
    end
    return true
end

local function crossZone(err, warn, candidate, zoneId, zone)
    if type(zoneId) ~= 'string' or not zoneId:match('^[%w_%-]+$') then
        err('Zone id "%s" may only contain letters, numbers, underscores and hyphens.', tostring(zoneId))
    elseif #zoneId > MAX_ZONE_ID then
        err('Zone id "%s" is too long (max %d characters).', zoneId, MAX_ZONE_ID)
    end

    if type(zone) ~= 'table' then
        err('Zone "%s" is not a table.', tostring(zoneId))
        zone = {}
    end

    local shapeOk = checkZoneShape(err, zone, zoneId)
    if isFiniteNumber(zone.minZ) and isFiniteNumber(zone.maxZ) and zone.minZ >= zone.maxZ then
        err('Zone "%s": the floor height (%.1f) must be below the ceiling height (%.1f).', zoneId, zone.minZ, zone.maxZ)
        shapeOk = false
    end

    if shapeOk then
        if zone.crate then checkInside(err, zone, zoneId, 'crate', zone.crate.coords) end
        if zone.seller then checkInside(err, zone, zoneId, 'seller', zone.seller.coords) end
    end

    -- Zone data arrives whole (wizard, import, history), never field by field, so the
    -- schedule is checked here: a text hour would break the schedule comparison outright.
    local sched = type(zone.schedule) == 'table' and zone.schedule or {}
    local function badHour(h)
        return h ~= nil and not (isFiniteNumber(h) and h == math.floor(h) and h >= 0 and h <= 23)
    end
    if badHour(sched.openHour) or badHour(sched.closeHour) then
        err('Zone "%s": open and close hours must be whole hours from 0 to 23.', zoneId)
    elseif sched.openHour ~= nil and sched.openHour == sched.closeHour then
        warn('Zone "%s": open and close hours are identical, so the zone is always open.', zoneId)
    end
    if sched.utcOffset ~= nil and not (isFiniteNumber(sched.utcOffset)
        and sched.utcOffset >= -12 and sched.utcOffset <= 14) then
        err('Zone "%s": the UTC offset must be a number from -12 to 14.', zoneId)
    end
end

function V.Cross(candidate)
    local errors, warnings = {}, {}
    local function err(fmt, ...) errors[#errors + 1] = fmt:format(...) end
    local function warn(fmt, ...) warnings[#warnings + 1] = fmt:format(...) end

    local val = candidate.Validation or {}
    if val.intervalMs and val.intervalMs < 250 then
        warn('Validation: an interval of %sms is very aggressive and will cost server performance.', val.intervalMs)
    end

    for zoneId, zone in pairs(candidate.Zones or {}) do
        crossZone(err, warn, candidate, zoneId, zone)
    end

    local squads = candidate.SoloSquads or {}
    if squads.name and squads.name.minLength and squads.name.maxLength
        and squads.name.minLength > squads.name.maxLength then
        err('Solo Squads: name minimum length is greater than the maximum.')
    end

    return errors, warnings
end

function V.ItemExists(name)
    if type(name) ~= 'string' or name == '' then return false end
    return safe(function() return RZ.Inv.ItemExists(name) end, true) ~= false
end

function V.CheckItems(candidate)
    local errors = {}
    local itemSource = safe(function() return RZ.Inv.SourceLabel() end, 'your inventory resource')
    local function check(label, name)
        if not name then return end
        if not V.ItemExists(name) then
            errors[#errors + 1] = ('%s: item "%s" does not exist in %s.'):format(label, name, itemSource)
        end
    end
    local items = candidate.Items or {}
    check('Package item', items.package)
    check('Keycard item', items.keycard)
    for _, row in ipairs((candidate.Rewards or {}).materials or {}) do
        check('Material reward', row.item)
    end
    for zoneId, zone in pairs(candidate.Zones or {}) do
        if zone.crate then check(('Zone "%s" crate reward'):format(zoneId), zone.crate.rewardItem) end
        if zone.package and zone.package ~= (zone.crate and zone.crate.rewardItem) then
            check(('Zone "%s" sellable package'):format(zoneId), zone.package)
        end
    end
    return errors
end

local defaults
local overrides = {}
local revision = 0
local degraded = false

function Store.CaptureDefaults()
    if defaults then return end
    defaults = S.Copy(Config)
end

function Store.GetDefaults()
    Store.CaptureDefaults()
    return defaults
end

function Store.GetRevision() return revision end

function Store.IsDegraded() return degraded end

function Store.GetOverrides() return overrides end

local function retireZone(zoneId)
    RZ.Log.Info(('zone %s no longer exists — standing it down'):format(zoneId))
    if RZ.Access and RZ.Access.EvacuateZone then RZ.Access.EvacuateZone(zoneId) end
    if RZ.Session and RZ.Session.PruneZone then RZ.Session.PruneZone(zoneId) end
    if RZ.Schedule and RZ.Schedule.PruneZone then RZ.Schedule.PruneZone(zoneId) end
    if RZ.Crate and RZ.Crate.PruneZone then RZ.Crate.PruneZone(zoneId) end
    if RZ.LootBag and RZ.LootBag.PruneZone then RZ.LootBag.PruneZone(zoneId) end
    if RZ.AdminApply and RZ.AdminApply.PruneZone then RZ.AdminApply.PruneZone(zoneId) end
end

local function rebuildConfig(newOverrides)
    Store.CaptureDefaults()
    local before = {}
    for zoneId in pairs(Config.Zones or {}) do before[zoneId] = true end
    local merged = S.Copy(defaults)
    S.DeepMerge(merged, newOverrides)
    if type(newOverrides.Zones) == 'table' then merged.Zones = S.Copy(newOverrides.Zones) end
    for k in pairs(Config) do
        if merged[k] == nil then Config[k] = nil end
    end
    for k, v in pairs(merged) do Config[k] = v end
    if RZ.Defaults and RZ.Defaults.Apply then RZ.Defaults.Apply(Config) end
    RZ.AdminSchema.Reindex(Config)
    for zoneId, zone in pairs(Config.Zones) do
        if zone.__needsShape then
            zone.__needsShape = nil
            RZ.Log.Info(('zone "%s" has no shape and has been switched off. It was probably saved '
                .. 'by an older version that used a centre and radius — redraw it with /redzonecreate.'):format(zoneId))
        end
    end
    for zoneId in pairs(before) do
        if Config.Zones[zoneId] == nil then retireZone(zoneId) end
    end
end

Store.RebuildConfig = rebuildConfig

-- Settings of systems that were removed (knock, revive, DNA and reboot). Older saves still
-- carry them; they are dropped quietly instead of being reported as rejected.
local RETIRED = {
    '^Knock%.', '^Revive%.', '^Reboot%.', '^Elimination%.', '%.rebootStations%.',
    '^Items%.teammateDna$', '^SoloSquads%.dnaExpiresAtSessionEnd$', '^Validation%.completionToleranceMs$',
}

local function retired(path)
    for i = 1, #RETIRED do
        if path:find(RETIRED[i]) then return true end
    end
    return false
end

local function filterOverrides(raw)
    local accepted, rejected = {}, {}
    if type(raw) ~= 'table' then return accepted, rejected end
    if type(raw.__zones) == 'table' then accepted.__zones = S.FromJson(raw.__zones) end
    for path, jsonValue in pairs(raw.fields or {}) do
        local field = RZ.AdminSchema.GetField(path)
        if not field and retired(path) then
            -- dropped
        elseif not field then
            rejected[#rejected + 1] = ('%s (not an editable path)'):format(path)
        else
            local value = S.FromJson(jsonValue)
            local ok, err = V.Field(field, value)
            if ok then
                accepted[path] = value
            else
                rejected[#rejected + 1] = ('%s (%s)'):format(path, tostring(err))
            end
        end
    end
    return accepted, rejected
end

Store.FilterOverrides = filterOverrides

local function applyOverrideSet(flat, zoneStructure)
    local nested = {}
    if zoneStructure then nested.Zones = S.Copy(zoneStructure) end
    local liveZones = zoneStructure or (defaults and defaults.Zones) or {}
    local dropped = 0
    for path, value in pairs(flat) do
        if path ~= '__zones' then
            local zoneId = path:match('^Zones%.([^%.]+)%.')
            if zoneId and liveZones[zoneId] == nil then
                dropped = dropped + 1
            else
                S.Set(nested, path, value)
            end
        end
    end
    if dropped > 0 then
        RZ.Log.Info(('admin store: dropped %d stored setting(s) belonging to zones that no longer exist.'):format(dropped))
    end
    overrides = nested
    rebuildConfig(nested)
end

Store.ApplyOverrideSet = applyOverrideSet

function Store.Rollback(previousFlat, previousZones)
    applyOverrideSet(previousFlat, previousZones)
end

function Store.EncodeOverrides(flat, zoneStructure)
    local fields = {}
    for path, value in pairs(flat) do
        if path ~= '__zones' then fields[path] = S.ToJson(value) end
    end
    return json.encode({
        schemaVersion = RZ.AdminSchema.SCHEMA_VERSION, fields = fields,
        __zones = zoneStructure and S.ToJson(zoneStructure) or nil,
    })
end

function Store.CurrentFlat()
    local flat = {}
    for path in pairs(RZ.AdminSchema.AllFields()) do
        local overrideValue = S.Get(overrides, path)
        if overrideValue ~= nil then flat[path] = overrideValue end
    end
    for path, spec in pairs(SPECIAL_PATHS) do
        if spec.preserved then
            local stored = S.Get(overrides, path)
            if stored ~= nil then flat[path] = stored end
        end
    end
    return flat, overrides.Zones
end

local function loadBlob(blob)
    local decoded = blob and json.decode(blob) or nil
    if type(decoded) ~= 'table' then return false, {} end
    local storedVersion = tonumber(decoded.schemaVersion) or 0
    if storedVersion > RZ.AdminSchema.SCHEMA_VERSION then
        RZ.Log.Integration('adminstore', ('stored config schema v%d is NEWER than this resource (v%d) — refusing to load it')
            :format(storedVersion, RZ.AdminSchema.SCHEMA_VERSION))
        return false, {}
    end
    local zoneStructure = nil
    if type(decoded.__zones) == 'table' then
        zoneStructure = S.FromJson(decoded.__zones)
        local probe = S.Copy(defaults)
        probe.Zones = zoneStructure
        RZ.AdminSchema.Reindex(probe)
    end
    local accepted, rejected = filterOverrides(decoded)
    accepted.__zones = nil
    applyOverrideSet(accepted, zoneStructure)
    return true, rejected
end

function Store.Load()
    Store.CaptureDefaults()
    degraded = false

    if not Config.AdminMenu or Config.AdminMenu.enabled ~= true then
        RZ.Log.Info('admin store: menu disabled, using config.lua defaults only.')
        return rebuildConfig({})
    end

    local row = RZ.Db.FetchRuntimeConfig()
    if not row then
        RZ.Log.Info('admin store: no published configuration yet, using config.lua defaults.')
        return rebuildConfig({})
    end

    local ok, rejected = loadBlob(row.config_json)
    if ok then
        revision = tonumber(row.revision) or 0
        RZ.Log.Info(('admin store: loaded published revision %d.'):format(revision))
        if #rejected > 0 then
            RZ.Log.Integration('adminstore', ('%d stored value(s) were rejected and fell back to defaults:'):format(#rejected))
            for i = 1, math.min(#rejected, 20) do
                RZ.Log.Integration('adminstore', '  rejected: ' .. rejected[i])
            end
        end
        return
    end

    RZ.Log.Integration('adminstore', 'published configuration is corrupt — trying last known good revision')

    local goodBlob, goodRevision = RZ.Db.FetchLatestGoodHistory()
    if goodBlob and loadBlob(goodBlob) then
        revision = tonumber(goodRevision) or 0
        degraded = true
        RZ.Log.Integration('adminstore', ('recovered from history revision %d. Republish to repair the live row.'):format(revision))
        return
    end

    degraded = true
    revision = 0
    rebuildConfig({})
    RZ.Log.Integration('adminstore', 'CRITICAL: no usable stored configuration. Running on config.lua defaults.')
end

-- Saves flat/zoneStructure as the published revision. `apply` decides what goes live now:
-- true applies exactly what was saved, a { flat, zones } table applies that instead (the
-- live half of a change made while another is queued), and false keeps the running config
-- untouched — the saved state then waits in AdminApply's queue for the next session.
--
-- Queuing used to apply the new state and immediately roll it back. Applying a deletion
-- retires the zone (evacuates it, ends its session, prunes its crate), and the rollback
-- then brought the zone straight back half-dismantled — the "delete did nothing" bug.
function Store.Commit(flat, zoneStructure, discordId, name, apply)
    local newRevision = revision + 1
    local blob = Store.EncodeOverrides(flat, zoneStructure)
    if not RZ.Db.SaveRuntimeConfig(RZ.AdminSchema.SCHEMA_VERSION, newRevision, blob, discordId, name) then
        return false, revision
    end
    revision = newRevision
    degraded = false
    if apply == true then
        applyOverrideSet(flat, zoneStructure)
    elseif type(apply) == 'table' then
        applyOverrideSet(apply.flat, apply.zones)
    end
    return true, newRevision
end

-- The state the next commit builds on: whatever is queued for the next session if anything
-- is, otherwise what is live. Building on the live state while something was queued meant
-- the next publish silently threw the queued change away.
function Store.PendingState()
    local queued = Apply.GetDeferred()
    if queued then
        return S.Copy(queued.flat), queued.zones and S.Copy(queued.zones) or nil, queued
    end
    local flat, zones = Store.CurrentFlat()
    return S.Copy(flat), zones and S.Copy(zones) or nil, nil
end

-- Zones as the editor should see them: the queued shapes when a reshape is waiting, with
-- the same derived fields (centre, radius, bounds) the live config carries.
function Store.PendingZones()
    local queued = Apply.GetDeferred()
    if not queued or not queued.zones then return Config.Zones end
    local out = {}
    for zoneId, zone in pairs(queued.zones) do
        local copy = S.Copy(zone)
        if RZ.Defaults and RZ.Defaults.ApplyZone then RZ.Defaults.ApplyZone(copy) end
        out[zoneId] = copy
    end
    return out
end

local APPLY_LOCK = 'admin:apply'
local deferred = nil
local knownZones = {}
local zoneOverrides = {}

function Apply.Lock(owner, ttlMs) return RZ.Lock.Acquire(APPLY_LOCK, owner, ttlMs or 30000) end

function Apply.Unlock(owner) RZ.Lock.Release(APPLY_LOCK, owner) end

function Apply.IsLocked() return RZ.Lock.IsHeld(APPLY_LOCK) end

-- Compares two zone structures. Only a reshape of a zone that already exists moves the
-- ground under the players standing in it; adding or deleting a zone never has to wait.
function Apply.ClassifyZones(before, after)
    local change = { added = 0, removed = 0, reshaped = 0 }
    before, after = before or {}, after or {}
    for zoneId, zone in pairs(after) do
        local old = before[zoneId]
        if not old then
            change.added = change.added + 1
        elseif not S.Equal(old.points, zone.points)
            or not S.Equal(old.minZ, zone.minZ) or not S.Equal(old.maxZ, zone.maxZ) then
            change.reshaped = change.reshaped + 1
        end
    end
    for zoneId in pairs(before) do
        if after[zoneId] == nil then change.removed = change.removed + 1 end
    end
    return change
end

function Apply.ModeFor(paths, zoneChange)
    local mode = 'live'
    for i = 1, #paths do
        if paths[i] == 'Zones' and (not zoneChange or zoneChange.reshaped > 0) then mode = 'session' end
        local field = RZ.AdminSchema.GetField(paths[i])
        local fieldMode = field and field.apply or 'live'
        if fieldMode == 'restart' then
            return 'restart'
        elseif fieldMode == 'session' then
            mode = 'session'
        end
    end
    return mode
end

function Apply.Rebuild(changedPaths)
    local ok, err = pcall(function()
        RZ.Schedule.Refresh(false)
        RZ.Session.Refresh()

        local structural = false
        for i = 1, #changedPaths do
            if changedPaths[i] == 'Zones' then
                structural = true
                break
            end
        end

        for zoneId, zone in pairs(Config.Zones) do
            if zone.enabled then
                local touched = structural and knownZones[zoneId] == nil
                if not touched then
                    local pattern = '^Zones%.' .. zoneId:gsub('(%W)', '%%%1') .. '%.crate'
                    for i = 1, #changedPaths do
                        if changedPaths[i]:find(pattern) then
                            touched = true
                            break
                        end
                    end
                end
                if touched then RZ.Crate.Reset(zoneId) end
            end
        end

        knownZones = {}
        for zoneId in pairs(Config.Zones) do knownZones[zoneId] = true end

        RZ.AdminSync.BroadcastConfig()
        RZ.Gangs.Forget()

        for source in pairs(RZ.Store.All()) do
            if online(source) then
                pcall(RZ.Access.Evaluate, source)
                pcall(RZ.Access.RefreshVisibility, source, true)
            end
        end

        RZ.Sync.PushWorldAll()
    end)

    if not ok then return false, tostring(err) end
    return true
end

-- Remembers which zones exist, so the first structural publish after a start only resets
-- the crates of zones it actually added instead of every crate on the server.
function Apply.PrimeKnownZones()
    knownZones = {}
    for zoneId in pairs(Config.Zones or {}) do knownZones[zoneId] = true end
end

local function mergePaths(a, b)
    local seen, out = {}, {}
    for _, list in ipairs({ a or {}, b or {} }) do
        for i = 1, #list do
            if not seen[list[i]] then
                seen[list[i]] = true
                out[#out + 1] = list[i]
            end
        end
    end
    return out
end

Apply.MergePaths = mergePaths

function Apply.Defer(payload)
    if payload.waitFor == nil then
        payload.waitFor = {}
        for zoneId, zone in pairs(Config.Zones or {}) do
            local sessionId = zone.enabled and RZ.Session.GetId(zoneId) or nil
            if sessionId then payload.waitFor[zoneId] = sessionId end
        end
    end
    deferred = payload
    RZ.Log.Info(('admin: revision %d queued for the next RedZone session.'):format(payload.revision or 0))
end

-- A queue was made because some session was running; it applies once every one of those
-- sessions has ended, not when the first zone happens to close.
function Apply.QueueDue()
    if not deferred then return false end
    for zoneId, sessionId in pairs(deferred.waitFor or {}) do
        if RZ.Session.GetId(zoneId) == sessionId then return false end
    end
    return true
end

function Apply.GetDeferred() return deferred end

function Apply.ClearDeferred() deferred = nil end

function Apply.FlushDeferred()
    if not deferred then return end
    local payload = deferred
    deferred = nil
    RZ.Log.Info(('admin: applying deferred revision %d now that the session has ended.'):format(payload.revision or 0))
    local owner = 'deferred'
    if not Apply.Lock(owner, 30000) then
        RZ.Log.Integration('adminapply', 'could not take the apply lock for deferred changes')
        deferred = payload
        return
    end
    RZ.AdminStore.ApplyOverrideSet(payload.flat, payload.zones)
    local ok, err = Apply.Rebuild(payload.changedPaths or {})
    Apply.Unlock(owner)
    if not ok then RZ.Log.Integration('adminapply', 'deferred apply failed: ' .. tostring(err)) end
end

function Apply.SetZoneOverride(zoneId, state, minutes, discordId)
    if state == 'schedule' then
        zoneOverrides[zoneId] = nil
    else
        zoneOverrides[zoneId] = {
            state = state, by = discordId,
            expiresAt = (minutes and minutes > 0) and (RZ.Mono() + minutes * 60000) or nil,
        }
    end
    RZ.Schedule.Refresh(true)
    RZ.Session.Refresh()
    RZ.Sync.PushWorldAll()
end

function Apply.GetZoneOverride(zoneId)
    local entry = zoneOverrides[zoneId]
    if not entry then return nil end
    if entry.expiresAt and RZ.Mono() > entry.expiresAt then
        zoneOverrides[zoneId] = nil
        return nil
    end
    return entry.state == 'open'
end

function Apply.GetZoneOverrides()
    local out, now = {}, RZ.Mono()
    for zoneId, entry in pairs(zoneOverrides) do
        if not entry.expiresAt or now <= entry.expiresAt then
            out[zoneId] = { state = entry.state,
                expiresInMs = entry.expiresAt and math.max(0, entry.expiresAt - now) or nil }
        end
    end
    return out
end

function Apply.ClearZoneOverrides() zoneOverrides = {} end

function Apply.PruneZone(zoneId) zoneOverrides[zoneId] = nil end

local cached
local cachedRevision = -1

-- Bumped on every rebuild. Clients compare it, not the revision: a change queued for the
-- next session bumps the revision while the live config stays the same, and a client that
-- synced in that window would otherwise ignore the real change when the queue flushed.
local build = 0

function Sync.Build()
    local zones = {}

    for zoneId, zone in pairs(Config.Zones or {}) do
        if zone.enabled then
            local points = {}
            for i = 1, #(zone.points or {}) do points[i] = S.VectorToJson(zone.points[i]) end

            zones[zoneId] = {
                enabled = true, label = zone.label, points = points,
                minZ = zone.minZ, maxZ = zone.maxZ,
                center = S.VectorToJson(zone.center), radius = zone.radius,
                blip = zone.blip,
                boundary = {
                    drawMarker = zone.boundary.drawMarker, markerColor = zone.boundary.markerColor,
                    debugPoly = zone.boundary.debugPoly,
                },
                crate = {
                    coords = S.VectorToJson(zone.crate.coords), prop = zone.crate.prop,
                    interactionDistance = zone.crate.interactionDistance,
                    lootDuration = zone.crate.lootDuration,
                    blipEnabled = zone.crate.blipEnabled, blipSprite = zone.crate.blipSprite,
                    blipColor = zone.crate.blipColor, blipScale = zone.crate.blipScale,
                },
                seller = {
                    coords = S.VectorToJson(zone.seller.coords), model = zone.seller.model,
                    scenario = zone.seller.scenario,
                    interactionDistance = zone.seller.interactionDistance,
                },
            }
        end
    end

    build = build + 1

    return {
        revision = RZ.AdminStore.GetRevision(),
        build = build,
        Zones = zones,
        Hud = Config.Hud,
        Fallbacks = Config.Fallbacks,
    }
end

function Sync.Get()
    local rev = RZ.AdminStore.GetRevision()
    if not cached or cachedRevision ~= rev then
        cached = Sync.Build()
        cachedRevision = rev
    end
    return cached
end

function Sync.Invalidate()
    cached = nil
    cachedRevision = -1
end

function Sync.PushTo(source)
    if not online(source) then return end
    TriggerClientEvent(RZ.Event.CONFIG_SYNC, source, Sync.Get())
end

function Sync.BroadcastConfig()
    Sync.Invalidate()
    local payload = Sync.Get()
    TriggerClientEvent(RZ.Event.CONFIG_SYNC, -1, payload)
    RZ.Log.Info(('admin: pushed configuration revision %d to all clients.'):format(payload.revision))
end

function P.BuildDiff(candidate, changedPaths)
    local diff = {}
    for i = 1, #changedPaths do
        local path = changedPaths[i]
        local field = RZ.AdminSchema.GetField(path)
        local spec = SPECIAL_PATHS[path]
        local before = S.Get(Config, path)
        local after = S.Get(candidate, path)
        if spec and spec.sensitive then
            diff[#diff + 1] = {
                path = path, label = field and field.label or path,
                before = (before and before ~= '') and 'Configured' or 'Not configured',
                after = (after and after ~= '') and 'Replaced' or 'Cleared',
                sensitive = true,
            }
        else
            diff[#diff + 1] = {
                path = path, label = field and field.label or path,
                zoneId = field and field.zoneId or nil,
                before = S.Describe(before), after = S.Describe(after),
                apply = field and field.apply or 'live',
            }
        end
    end
    table.sort(diff, function(a, b) return a.path < b.path end)
    return diff
end

-- Per-zone settings of a zone the candidate no longer has are skipped, the same rule
-- applyOverrideSet uses: writing them would rebuild the deleted zone as a shapeless ghost.
local function zoneOfPath(path)
    return path:match('^Zones%.([^%.]+)%.')
end

function P.BuildCandidate(flat, zones)
    local candidate = S.Copy(RZ.AdminStore.GetDefaults())
    if zones then candidate.Zones = S.Copy(zones) end
    local present = candidate.Zones or {}
    for path, value in pairs(flat) do
        local zoneId = zoneOfPath(path)
        if path ~= '__zones' and not (zoneId and present[zoneId] == nil) then
            S.Set(candidate, path, value)
        end
    end
    return candidate
end

function P.ValidateDraft(draft)
    local result = { ok = false, fieldErrors = {}, errors = {}, warnings = {}, changed = {}, diff = {}, applyMode = 'live' }

    if type(draft) ~= 'table' then return fail(result, 'Malformed draft.') end

    local zones = RZ.AdminStore.PendingZones()
    if draft.zones ~= nil then
        if type(draft.zones) ~= 'table' then return fail(result, 'Malformed zone data.') end
        zones = S.FromJson(draft.zones)
        local probe = S.Copy(RZ.AdminStore.GetDefaults())
        probe.Zones = zones
        RZ.AdminSchema.Reindex(probe)
    end

    local flat = RZ.AdminStore.PendingState()

    for path, jsonValue in pairs(draft.fields or {}) do
        local field = RZ.AdminSchema.GetField(path)
        if not field then
            result.fieldErrors[path] = 'This setting cannot be edited.'
            fail(result, ('Rejected unknown setting "%s".'):format(tostring(path)))
        else
            local value = S.FromJson(jsonValue)
            local ok, err = RZ.AdminValidate.Field(field, value)
            if ok then
                flat[path] = value
            else
                result.fieldErrors[path] = err
            end
        end
    end

    if next(result.fieldErrors) ~= nil then
        RZ.AdminSchema.Reindex(Config)
        return result
    end

    local candidate = P.BuildCandidate(flat, zones)

    local changed = {}
    for path in pairs(draft.fields or {}) do
        if RZ.AdminSchema.GetField(path) and not S.Equal(S.Get(Config, path), flat[path]) then
            changed[#changed + 1] = path
        end
    end
    local zoneChange = nil
    if draft.zones ~= nil and not S.Equal(Config.Zones, zones) then
        changed[#changed + 1] = 'Zones'
        zoneChange = RZ.AdminApply.ClassifyZones(Config.Zones, zones)
    end
    table.sort(changed)
    result.changed = changed
    result.zoneChange = zoneChange

    local errors, warnings = RZ.AdminValidate.Cross(candidate)
    table.move(errors, 1, #errors, #result.errors + 1, result.errors)
    table.move(warnings, 1, #warnings, #result.warnings + 1, result.warnings)

    local itemErrors = RZ.AdminValidate.CheckItems(candidate)
    table.move(itemErrors, 1, #itemErrors, #result.errors + 1, result.errors)

    result.diff = P.BuildDiff(candidate, changed)
    if zoneChange then
        local function add(count, what)
            if count > 0 then
                result.diff[#result.diff + 1] = {
                    path = 'Zones', label = ('%d zone(s) %s'):format(count, what),
                    before = '', after = what, apply = (what == 'reshaped') and 'session' or 'live',
                }
            end
        end
        add(zoneChange.added, 'added')
        add(zoneChange.removed, 'deleted')
        add(zoneChange.reshaped, 'reshaped')
    end
    local queued = RZ.AdminApply.GetDeferred()
    if queued then
        -- Applying now also applies whatever is queued, so its mode counts too.
        result.applyMode = RZ.AdminApply.ModeFor(RZ.AdminApply.MergePaths(queued.changedPaths, changed),
            RZ.AdminApply.ClassifyZones(Config.Zones, zones))
    else
        result.applyMode = RZ.AdminApply.ModeFor(changed, zoneChange)
    end
    result.ok = #result.errors == 0

    RZ.AdminSchema.Reindex(Config)
    return result
end

function P.AnySessionLive()
    for zoneId, zone in pairs(Config.Zones or {}) do
        if zone.enabled and RZ.Session.GetId(zoneId) ~= nil then return true end
    end
    return false
end

function P.WriteHistory(session, revisionId, previousRevision, reason, diff, flat, zones)
    local cleanReason = nil
    if type(reason) == 'string' and reason ~= '' and RZ.AdminValidate.ValidateString(reason, 255) then
        cleanReason = reason
    end
    RZ.Db.InsertConfigHistory({
        revision = revisionId, previous_revision = previousRevision,
        changed_by_discord = session.discordId, changed_by_name = session.name,
        change_reason = cleanReason, diff_json = json.encode(diff),
        full_config_json = RZ.AdminStore.EncodeOverrides(flat, zones),
    })
end

function P.Publish(session, draft, opts)
    opts = opts or {}
    local result = { ok = false, errors = {}, warnings = {} }

    local liveRevision = RZ.AdminStore.GetRevision()
    if tonumber(opts.baseRevision) ~= liveRevision then
        result.stale, result.revision = true, liveRevision
        return fail(result, 'The RedZone configuration was changed by another administrator. Reload the latest revision before publishing.')
    end

    local validation = P.ValidateDraft(draft)
    if not validation.ok then
        result.errors = validation.errors
        result.fieldErrors = validation.fieldErrors
        return result
    end

    if #validation.warnings > 0 and not opts.acknowledgeWarnings then
        result.needsWarningAck = true
        result.warnings = validation.warnings
        result.diff = validation.diff
        return result
    end

    if #validation.changed == 0 then
        result.ok, result.revision, result.noChanges = true, liveRevision, true
        return result
    end

    local owner = session.source
    if not RZ.AdminApply.Lock(owner, 45000) then
        return fail(result, 'Another configuration change is being applied. Try again in a moment.')
    end

    local previousFlat, previousZones = RZ.AdminStore.CurrentFlat()
    previousFlat = S.Copy(previousFlat)
    previousZones = previousZones and S.Copy(previousZones) or nil

    local flat, baseZones, queued = RZ.AdminStore.PendingState()
    for path, jsonValue in pairs(draft.fields or {}) do flat[path] = S.FromJson(jsonValue) end
    local zones = draft.zones and S.FromJson(draft.zones) or baseZones

    if zones and RZ.Defaults and RZ.Defaults.StripZone then
        local lean = {}
        for zoneId, zone in pairs(zones) do lean[zoneId] = RZ.Defaults.StripZone(S.Copy(zone)) end
        zones = lean
    end

    if zones then
        for path in pairs(flat) do
            local zoneId = zoneOfPath(path)
            if zoneId and zones[zoneId] == nil then flat[path] = nil end
        end
    end

    local mode = opts.applyMode or validation.applyMode
    local changedPaths = RZ.AdminApply.MergePaths(queued and queued.changedPaths, validation.changed)

    if mode == 'session' and P.AnySessionLive() then
        local ok, newRevision = RZ.AdminStore.Commit(flat, zones, session.discordId, session.name, false)
        if not ok then
            RZ.AdminApply.Unlock(owner)
            return fail(result, 'Could not save the configuration. Nothing was changed.')
        end

        RZ.AdminApply.Defer({ revision = newRevision, flat = flat, zones = zones, changedPaths = changedPaths })
        P.WriteHistory(session, newRevision, liveRevision, opts.reason, validation.diff, flat, zones)
        RZ.AdminApply.Unlock(owner)
        RZ.AdminAudit.Write(session, 'publish', nil, ('%d field(s) queued for next session'):format(#validation.changed),
            true, nil, newRevision)

        result.ok, result.revision, result.deferred, result.diff = true, newRevision, true, validation.diff
        return result
    end

    -- Applying now also applies anything that was waiting for the next session: it is
    -- already part of what is being saved, and leaving it queued would let the session end
    -- re-apply an older state on top of this one.
    if queued then RZ.AdminApply.ClearDeferred() end

    local ok, newRevision = RZ.AdminStore.Commit(flat, zones, session.discordId, session.name, true)
    if not ok then
        if queued then RZ.AdminApply.Defer(queued) end
        RZ.AdminApply.Unlock(owner)
        return fail(result, 'Could not save the configuration. Nothing was changed.')
    end

    local applied, applyErr = RZ.AdminApply.Rebuild(changedPaths)
    if not applied then
        RZ.AdminStore.Rollback(previousFlat, previousZones)
        if queued then RZ.AdminApply.Defer(queued) end
        pcall(RZ.AdminApply.Rebuild, changedPaths)
        RZ.AdminApply.Unlock(owner)
        RZ.Log.Integration('adminpublish', 'runtime apply failed, rolled back: ' .. tostring(applyErr))
        RZ.AdminAudit.Write(session, 'publish', nil, 'runtime apply failed', false, tostring(applyErr), newRevision)
        return fail(result, 'The configuration was saved but could not be applied. The previous settings have been restored.')
    end

    P.WriteHistory(session, newRevision, liveRevision, opts.reason, validation.diff, flat, zones)
    RZ.AdminApply.Unlock(owner)
    RZ.AdminAudit.Write(session, 'publish', nil, ('%d field(s) changed'):format(#validation.changed), true, nil, newRevision)

    result.ok, result.revision = true, newRevision
    result.diff, result.applyMode = validation.diff, mode
    result.flushedQueued = queued ~= nil
    return result
end

function P.LoadRevisionAsDraft(revisionId)
    local blob = RZ.Db.FetchConfigRevision(revisionId)
    if not blob then return nil, 'That revision could not be found.' end
    local decoded = json.decode(blob)
    if type(decoded) ~= 'table' then return nil, 'That revision is corrupt and cannot be restored.' end
    if (tonumber(decoded.schemaVersion) or 0) > RZ.AdminSchema.SCHEMA_VERSION then
        return nil, 'That revision was written by a newer version of the resource.'
    end
    -- A revision stores only what was overridden at the time. Rebuild its full effective
    -- config, so restoring it also undoes settings (and zones) changed after it instead of
    -- leaving them at today's values.
    local defaults = RZ.AdminStore.GetDefaults()
    local zones = type(decoded.__zones) == 'table' and S.FromJson(decoded.__zones) or S.Copy(defaults.Zones or {})
    local probe = S.Copy(defaults)
    probe.Zones = zones
    RZ.AdminSchema.Reindex(probe)

    local flat, dropped = {}, {}
    for path, value in pairs(decoded.fields or {}) do
        if RZ.AdminSchema.GetField(path) then
            flat[path] = S.FromJson(value)
        else
            dropped[#dropped + 1] = path
        end
    end

    local candidate = P.BuildCandidate(flat, zones)
    if RZ.Defaults and RZ.Defaults.Apply then RZ.Defaults.Apply(candidate) end
    local fields = {}
    for path in pairs(RZ.AdminSchema.AllFields()) do
        if not SPECIAL_PATHS[path] then
            local value = S.Get(candidate, path)
            if value ~= nil then fields[path] = S.ToJson(value) end
        end
    end

    RZ.AdminSchema.Reindex(Config)
    return { fields = fields, zones = S.ToJson(zones), dropped = dropped }
end

local OK, WARN, ERR, NA = 'ok', 'warning', 'error', 'na'

local function resourceStarted(name)
    return safe(function() return GetResourceState(name) end) == 'started'
end

function Diag.Run()
    local checks = {}
    local function add(group, label, status, detail)
        checks[#checks + 1] = { group = group, label = label, status = status, detail = detail }
    end

    for _, dep in ipairs({ 'ox_lib', 'ox_inventory', 'oxmysql' }) do
        local started = resourceStarted(dep)
        add('Dependencies', dep, started and OK or ERR,
            started and 'started' or 'not started — the RedZone cannot work without it')
    end

    local function addBackend(label, options, adapterNote)
        for _, option in ipairs(options) do
            if resourceStarted(option) then
                add('Dependencies', label, OK, ('%s — resolved at runtime'):format(option))
                return option
            end
        end
        add('Dependencies', label, ERR, ('none of %s is started. %s'):format(table.concat(options, ' / '), adapterNote))
        return nil
    end

    local standalone = RZ.Fw.IsStandalone()
    local framework = standalone and 'standalone'
        or addBackend('Framework', { 'qbx_core', 'qb-core', 'es_extended' }, 'See the framework adapter.')

    addBackend('Targeting', { 'ox_target', 'qb-target' }, 'See the targeting adapter.')

    if standalone then
        add('Dependencies', 'Death / respawn', NA,
            'standalone — deaths and respawns are read from the ped itself, so no death resource is needed')
    else
        addBackend('Death / respawn', { 'qbx_medical', 'qb-ambulancejob' }, 'See the medical adapter.')
    end

    local resolved = RZ.Fw.Describe()
    if standalone then
        add('Dependencies', 'Framework adapter', OK,
            'standalone — no framework, so every player is Solo and the mode runs on Solo Squads')
    elseif framework and resolved ~= framework then
        add('Dependencies', 'Framework adapter', WARN,
            ('RZ.Fw resolved %s but %s is the started core.'):format(resolved, framework))
    else
        add('Dependencies', 'Framework adapter', OK, ('RZ.Fw is using %s'):format(resolved))
    end

    local gangText = RZ.Gangs.Describe()
    add('Dependencies', 'Gang source', OK, ('auto-detected: %s'):format(gangText))
    local soloGangs = Config.Gangs and Config.Gangs.soloGangs
    add('Dependencies', 'Gang access', OK, (not RZ.Gangs.RequiresGang())
        and 'players with no gang fight as Solo Squads'
        or ('gang members only; solo gang: %s'):format(type(soloGangs) == 'table' and #soloGangs > 0
            and table.concat(soloGangs, ', ') or 'none set'))

    local runtimeRow = RZ.Db.FetchRuntimeConfig()
    add('Database', 'Runtime config table', runtimeRow and OK or WARN,
        runtimeRow and ('revision %s'):format(runtimeRow.revision)
            or 'no published revision yet — running on config.lua defaults')

    local isDegraded = RZ.AdminStore.IsDegraded()
    add('Database', 'Config integrity', isDegraded and ERR or OK,
        isDegraded and 'the published configuration could not be loaded; defaults or a recovered revision are active'
            or 'loaded cleanly')

    add('Database', 'Schema version', OK, ('v%d'):format(RZ.AdminSchema.SCHEMA_VERSION))

    local itemErrors = RZ.AdminValidate.CheckItems(Config)
    if #itemErrors == 0 then
        add('Items', 'Configured items', OK, ('every configured item exists in %s')
            :format(safe(function() return RZ.Inv.SourceLabel() end, 'the inventory backend')))
    else
        for i = 1, #itemErrors do add('Items', 'Item check', ERR, itemErrors[i]) end
    end

    local errors, warnings = RZ.AdminValidate.Cross(Config)
    if #errors == 0 and #warnings == 0 then
        add('Configuration', 'Cross-field invariants', OK, 'no problems found')
    end
    for i = 1, #errors do add('Configuration', 'Invariant', ERR, errors[i]) end
    for i = 1, #warnings do add('Configuration', 'Advisory', WARN, warnings[i]) end

    local clock = RZ.Schedule.GetClock()
    add('Schedule', 'Server time', OK, ('%04d-%02d-%02d %02d:%02d:%02d (%s)'):format(clock.year, clock.month,
        clock.day, clock.hour, clock.min, clock.sec, RZ.Time.OffsetLabel(clock.offset)))

    local failures = select(2, RZ.Schedule.SelfTest())
    add('Schedule', 'Clock self-test', failures == 0 and OK or ERR,
        failures == 0 and 'all schedule and offset assertions pass' or ('%d assertion(s) failed'):format(failures))

    if RZ.Schedule.IsForcedOpen() then
        add('Schedule', 'Debug override', WARN, 'every zone is forced OPEN 24/7 because Config.Debug is true')
    end

    local zoneCount, enabledCount = 0, 0
    for zoneId, zone in pairs(Config.Zones or {}) do
        zoneCount = zoneCount + 1
        if zone.enabled then
            enabledCount = enabledCount + 1
            add('Zones', zoneId, OK, ('%s, radius %.1f'):format(
                RZ.Schedule.IsOpen(zoneId) and 'OPEN' or 'closed', zone.radius or 0))
        else
            add('Zones', zoneId, NA, 'disabled')
        end
    end
    if zoneCount == 0 then
        add('Zones', 'Configured zones', ERR, 'no zones are configured')
    elseif enabledCount == 0 then
        add('Zones', 'Enabled zones', WARN, 'every zone is disabled')
    end

    local webhook = Config.Logging and Config.Logging.webhook
    local hasWebhook = webhook and webhook ~= ''
    add('Logging', 'Discord webhook', hasWebhook and OK or NA, hasWebhook and 'Configured' or 'Not configured')

    return { checks = checks, generatedAt = RZ.Now() }
end

function Diag.Dashboard()
    local clock = RZ.Schedule.GetClock()
    local tracked = RZ.Store.All()
    local activeOverrides = RZ.AdminApply.GetZoneOverrides()

    local zones = {}
    local totalTracked, totalEliminated = 0, 0

    for zoneId, zone in pairs(Config.Zones or {}) do
        if zone.enabled then
            local players, eliminated, blocked = 0, 0, 0
            for _, record in pairs(tracked) do
                if record.zoneId == zoneId then
                    players = players + 1
                    if record.state == RZ.State.ELIMINATED then
                        eliminated = eliminated + 1
                    elseif record.state == RZ.State.RESPAWN_BLOCKED then
                        blocked = blocked + 1
                    end
                end
            end

            local crate = RZ.Crate.GetTimerState(zoneId)
            totalTracked = totalTracked + players
            totalEliminated = totalEliminated + eliminated

            zones[#zones + 1] = {
                id = zoneId, label = zone.label, enabled = true,
                open = RZ.Schedule.IsOpen(zoneId), sessionId = RZ.Session.GetId(zoneId),
                players = players, eliminated = eliminated, blocked = blocked,
                aliveGroups = #RZ.Groups.GetAliveGroupsInZone(zoneId),
                crateActive = crate.active, crateRunning = crate.running,
                crateRemainingMs = crate.remainingMs, crateIntervalMs = crate.intervalMs,
                override = activeOverrides[zoneId],
                secondsUntilChange = select(1, RZ.Schedule.SecondsUntilChange(zoneId)),
            }
        else
            zones[#zones + 1] = { id = zoneId, label = zone.label, enabled = false }
        end
    end

    table.sort(zones, function(a, b) return a.id < b.id end)

    return {
        revision = RZ.AdminStore.GetRevision(), degraded = RZ.AdminStore.IsDegraded(),
        schemaVersion = RZ.AdminSchema.SCHEMA_VERSION,
        serverTime = ('%04d-%02d-%02d %02d:%02d:%02d'):format(clock.year, clock.month, clock.day,
            clock.hour, clock.min, clock.sec),
        utcOffset = RZ.Time.OffsetLabel(clock.offset),
        forcedOpen = RZ.Schedule.IsForcedOpen(), debug = Config.Debug == true, zones = zones,
        totals = { tracked = totalTracked, eliminated = totalEliminated,
            adminSessions = RZ.AdminSessions.Count() },
        deferred = RZ.AdminApply.GetDeferred() and true or false,
    }
end

function Diag.Inspect()
    local rows = {}
    for source, record in pairs(RZ.Store.All()) do
        if online(source) then
            local zoneId = record.zoneId
            local eligible, reason = true, nil
            if zoneId then
                eligible, reason = RZ.Access.CheckEligibility(source, zoneId)
            else
                eligible, reason = false, 'outside'
            end
            local cooldownMs = 0
            for id, zone in pairs(Config.Zones or {}) do
                if zone.enabled then
                    local remaining = RZ.Cooldowns.GetRemaining(record.citizenid, id)
                    if remaining > cooldownMs then cooldownMs = remaining end
                end
            end
            local groupLabel = 'none'
            if record.groupType == RZ.Groups.TYPE_GANG and record.gangId then
                groupLabel = 'gang: ' .. RZ.Gangs.GetGangLabel(record.gangId)
            elseif record.groupType == RZ.Groups.TYPE_SOLO_SQUAD then
                local squad = RZ.Squads.GetSquadByCitizenId(record.citizenid)
                groupLabel = 'squad: ' .. (squad and squad.name or '?')
            end
            rows[#rows + 1] = {
                source = source, name = record.name, state = record.state,
                zoneId = zoneId, inside = zoneId ~= nil,
                eligible = eligible == true, reason = reason,
                groupType = record.groupType, group = groupLabel, cooldownMs = cooldownMs,
                blockedJob = select(2, RZ.Access.HasBlockedJob(source)),
                lastEjectAgoMs = record.lastEjectAt > 0 and (RZ.Mono() - record.lastEjectAt) or nil,
            }
        end
    end
    table.sort(rows, function(a, b) return a.source < b.source end)
    return rows
end

local DESTRUCTIVE = { crate_reset = true, crate_despawn = true, zone_force_close = true, rebuild_all = true }

function Controls.IsDestructive(action) return DESTRUCTIVE[action] == true end

local function frameworkJobs()
    local jobs = safe(function() return RZ.Fw.GetJobs() end)
    return type(jobs) == 'table' and jobs or nil
end

function Controls.JobTypes()
    local out, seen, jobs = {}, {}, frameworkJobs()
    if not jobs then return out end
    for _, job in pairs(jobs) do
        if type(job) == 'table' and type(job.type) == 'string' and not seen[job.type] then
            seen[job.type] = true
            out[#out + 1] = job.type
        end
    end
    table.sort(out)
    return out
end

function Controls.JobNames()
    local out, jobs = {}, frameworkJobs()
    if not jobs then return out end
    for name in pairs(jobs) do out[#out + 1] = name end
    table.sort(out)
    return out
end

local function validZone(zoneId)
    if type(zoneId) ~= 'string' or not Config.Zones[zoneId] then return nil end
    return zoneId
end

local OVERRIDE_STATES = { zone_force_open = 'open', zone_force_close = 'closed', zone_schedule = 'schedule' }

local function zoneOverrideAction(session, payload, zoneId, action)
    if not zoneId then return { ok = false, error = 'Unknown zone.' } end
    local state = OVERRIDE_STATES[action]
    local minutes = tonumber(payload.minutes)
    if minutes and (minutes < 0 or minutes > 1440) then
        return { ok = false, error = 'Duration must be between 0 and 1440 minutes.' }
    end
    RZ.AdminApply.SetZoneOverride(zoneId, state, minutes, session.discordId)
    return {
        ok = true, message = ('Zone "%s" set to %s.'):format(zoneId, state),
        audit = { 'zone_override', zoneId,
            ('%s%s'):format(state, minutes and minutes > 0 and (' for ' .. minutes .. 'm') or '') },
    }
end

local actions = {
    zone_force_open = zoneOverrideAction,
    zone_force_close = zoneOverrideAction,
    zone_schedule = zoneOverrideAction,

    crate_reset = function(_, _, zoneId)
        if not zoneId then return { ok = false, error = 'Unknown zone.' } end
        RZ.Crate.Reset(zoneId)
        return { ok = true, message = 'Crate timer reset to the full interval.', audit = { 'crate_reset', zoneId } }
    end,

    crate_despawn = function(_, _, zoneId)
        if not zoneId then return { ok = false, error = 'Unknown zone.' } end
        RZ.Crate.Despawn(zoneId, true)
        return { ok = true, message = 'Active crate removed and the timer restarted.', audit = { 'crate_despawn', zoneId } }
    end,

    rebuild_all = function(session)
        local owner = session.source
        if not RZ.AdminApply.Lock(owner, 20000) then
            return { ok = false, error = 'A configuration change is already being applied.' }
        end
        local ok, err = RZ.AdminApply.Rebuild({})
        RZ.AdminApply.Unlock(owner)

        local audit = { 'rebuild', nil, nil, ok, ok and nil or tostring(err) }
        if not ok then return { ok = false, error = 'Rebuild failed: ' .. tostring(err), audit = audit } end
        return { ok = true, message = 'Zones, entities and blips rebuilt for every client.', audit = audit }
    end,

    revalidate_all = function()
        local count = 0
        for src in pairs(RZ.Store.All()) do
            if online(src) then
                pcall(RZ.Access.Evaluate, src)
                count = count + 1
            end
        end
        return {
            ok = true, message = ('Revalidated %d player(s).'):format(count),
            audit = { 'revalidate_all', nil, ('%d player(s)'):format(count) },
        }
    end,

    revalidate_player = function(_, payload)
        local target = tonumber(payload.target)
        if not target or not online(target) then return { ok = false, error = 'That player is not online.' } end
        pcall(RZ.Access.Evaluate, target)
        return {
            ok = true, message = ('Revalidated %s.'):format(GetPlayerName(target)),
            audit = { 'revalidate_player', nil, ('source %d'):format(target) },
        }
    end,

    flush_deferred = function()
        if not RZ.AdminApply.GetDeferred() then
            return { ok = false, error = 'Nothing is queued for the next session.' }
        end
        RZ.AdminApply.FlushDeferred()
        return { ok = true, message = 'Queued configuration applied now.', audit = { 'flush_deferred' } }
    end,

    cancel_deferred = function(session)
        if not RZ.AdminApply.GetDeferred() then
            return { ok = false, error = 'Nothing is queued for the next session.' }
        end
        if not RZ.AdminApply.Lock(session.source, 15000) then
            return { ok = false, error = 'A configuration change is being applied. Try again in a moment.' }
        end
        -- The queued state is what is saved, so a restart would apply it: save the live state
        -- back over it before forgetting the queue.
        local flat, zones = RZ.AdminStore.CurrentFlat()
        local ok = RZ.AdminStore.Commit(S.Copy(flat), zones and S.Copy(zones) or nil,
            session.discordId, session.name, false)
        if ok then RZ.AdminApply.ClearDeferred() end
        RZ.AdminApply.Unlock(session.source)
        if not ok then return { ok = false, error = 'Could not save the live configuration; the queue was kept.' } end
        return { ok = true, message = 'Queued configuration discarded.', audit = { 'cancel_deferred' } }
    end,

    cooldown_prune = function()
        RZ.Cooldowns.Prune()
        return { ok = true, message = 'Expired cooldowns pruned.', audit = { 'cooldown_prune' } }
    end,
}

function Controls.Run(session, action, payload)
    if type(action) ~= 'string' then return { ok = false, error = 'Unknown action.' } end
    local zoneId = validZone(payload.zoneId)
    local handler = actions[action]
    if not handler then return { ok = false, error = 'Unknown action.' } end
    local result = handler(session, payload, zoneId, action)
    local audit = result.audit
    if audit then
        result.audit = nil
        RZ.AdminAudit.Write(session, audit[1], audit[2], audit[3], audit[4], audit[5])
    end
    return result
end

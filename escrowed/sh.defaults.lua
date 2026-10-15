RZ = RZ or {}
RZ.Defaults = {}

local D = {}

D.AdminMenu = {
    allowCommandAlias = true, requirePublishConfirmation = true,
    allowLiveDebugToggle = false, allowWebhookReplacement = true,
    allowWhitelistEditingInUi = false,
    sessionTimeoutMinutes = 30, maxPayloadBytes = 262144,
}

D.Logging = {
    useQbxLogger = true,
    events = {
        invalidEntry = true, repeatedEntry = true,
        elimination = true, respawnCooldown = true,
        crateSpawn = true, crateLooted = true, packageSold = true,
        rewardsGranted = true, cardGranted = true, suspicious = true, integrationError = true,
        squadCreated = true, squadInvite = true, squadJoin = true, squadLeave = true,
        squadKick = true, squadTransfer = true, squadRename = true, squadDisband = true,
        squadSnapshot = true, adminAction = true, lootBag = true,
    },
}

D.Gangs = {
    resource = 'auto', requireGang = true,
    soloGangs = { 'solo' }, notGangs = { 'none', 'unemployed', 'unemployed2' },
}

D.Cooldown = {
    cleanupIntervalMs = 300000,
    damage = { warnIntervalMs = 3000, ejectAfterIgnoredTicks = 3 },
}

D.LootBag = {
    zoneOnly = true, prop = 'prop_cs_heist_bag_01', slots = 5, maxWeight = 60000,
    crashCheck = {
        enabled = true, punishTimeouts = true, punishFreezes = false,
        crashAllowance = 2, crashWindowHours = 24,
    },
}

D.SoloSquads = {
    inviteExpirationSeconds = 30, inviteCooldownSeconds = 5,
    persistSquads = true,
    allowMaterialsReward = true, allowKeycardReward = true,
    autoTransferLeaderAfterMinutes = 0,
    name = { minLength = 3, maxLength = 24, renameLimit = 3, renameWindowMs = 60000 },
    rateLimits = {
        squadUi       = { max = 20, windowMs = 10000 },
        squadCreate   = { max = 3,  windowMs = 30000 },
        squadInvite   = { max = 6,  windowMs = 30000 },
        squadRespond  = { max = 10, windowMs = 30000 },
        squadKick     = { max = 10, windowMs = 30000 },
        squadLeave    = { max = 5,  windowMs = 30000 },
        squadTransfer = { max = 5,  windowMs = 60000 },
        squadRename   = { max = 3,  windowMs = 60000 },
        squadDisband  = { max = 3,  windowMs = 60000 },
    },
}

D.Schedule = { utcOffset = 0, pollIntervalMs = 15000, alwaysOpenInDebug = true }

D.Validation = {
    intervalMs = 750, ejectRetries = 3, ejectRetryDelayMs = 1500,
    ejectCooldownMs = 4000,
    rateLimits = {
        default        = { max = 8,  windowMs = 10000 },
        lootCrate      = { max = 4,  windowMs = 10000 },
        sellPackage    = { max = 6,  windowMs = 15000 },
        -- Admin menu: browsing tabs reads the dashboard, inspector and config each time.
        adminOpen      = { max = 6,  windowMs = 10000 },
        adminRead      = { max = 60, windowMs = 10000 },
        adminDiag      = { max = 10, windowMs = 10000 },
        adminValidate  = { max = 20, windowMs = 10000 },
        adminPublish   = { max = 6,  windowMs = 10000 },
        adminControl   = { max = 20, windowMs = 10000 },
    },
}

D.Fallbacks = { prop = 'ex_prop_crate_gems_bc', ped = 'a_m_m_farmer_01', maxGroundSnap = 3.0 }

local Z_BELOW, Z_ABOVE = 100.0, 500.0

local ZONE = {
    points = {},
    blip = {
        enabled = true, showWhenClosed = false,
        style = 'filled', color = 1, alpha = 80,
        outlineWidth = 5.0, detail = 6.0, maxParts = 96,
        centerSprite = 84, centerColor = 1, centerScale = 0.9,
    },
    boundary = {
        ejectPadding = 4.0, serverValidationInterval = 750,
        drawMarker = false, markerColor = { r = 200, g = 30, b = 30, a = 90 },
        debugPoly = false,
    },
    schedule = { openHour = 20, closeHour = 6 },
    crate = {
        prop = 'ex_prop_crate_gems_bc',
        spawnInterval = 180, interactionDistance = 4.0,
        lootDuration = 5000, rewardAmount = 1,
        blipEnabled = true, blipSprite = 478, blipColor = 5, blipScale = 0.8,
    },
    seller = {
        model = 's_m_y_dealer_01', scenario = 'WORLD_HUMAN_STAND_IMPATIENT',
        interactionDistance = 2.0,
    },
}

local function isList(t)
    return next(t) ~= nil and t[1] ~= nil
end

local function fill(target, defaults)
    for k, v in pairs(defaults) do
        local current = target[k]
        if current == nil then
            if type(v) == 'table' then
                local copy = {}
                fill(copy, v)
                target[k] = copy
            else
                target[k] = v
            end
        elseif type(current) == 'table' and type(v) == 'table' and not isList(v) and not isList(current) then
            fill(current, v)
        end
    end
end

local function strip(value, template)
    if type(value) ~= 'table' or type(template) ~= 'table' then return value end
    if isList(value) then return value end

    local out = {}
    for k, v in pairs(value) do
        local t = template[k]
        if type(v) == 'table' and type(t) == 'table' and not isList(v) then
            local sub = strip(v, t)
            if next(sub) ~= nil then out[k] = sub end
        elseif v ~= t then
            out[k] = v
        end
    end
    return out
end

function RZ.Defaults.ApplyZone(zone)
    if type(zone) ~= 'table' then return zone end

    fill(zone, ZONE)

    -- Reboot stations were removed; older saved zones may still carry them.
    zone.rebootStations = nil

    zone.crate.rewardItem = zone.crate.rewardItem
        or zone.package
        or (Config.Items and Config.Items.package)
    zone.package = zone.crate.rewardItem

    local points = zone.points
    if zone.enabled and (type(points) ~= 'table' or #points < 3) then
        zone.enabled = false
        zone.__needsShape = true
    end

    if type(points) == 'table' and #points >= 3 then
        local minZ, maxZ = math.huge, -math.huge
        for i = 1, #points do
            local pz = points[i].z
            if pz then
                if pz < minZ then minZ = pz end
                if pz > maxZ then maxZ = pz end
            end
        end
        if minZ == math.huge then minZ, maxZ = 0.0, 0.0 end

        if zone.minZ == nil then zone.minZ = minZ - Z_BELOW end
        if zone.maxZ == nil then zone.maxZ = maxZ + Z_ABOVE end

        zone.center = RZ.Geo.DerivedCenter(points, minZ)
        zone.radius = RZ.Geo.DerivedRadius(points)

        local bMinX, bMinY, bMaxX, bMaxY = RZ.Geo.Bounds(points)
        zone.bounds = { minX = bMinX, minY = bMinY, maxX = bMaxX, maxY = bMaxY }
    end

    zone.blip.centerLabel = zone.blip.centerLabel or zone.label
    return zone
end

function RZ.Defaults.StripZone(zone)
    if type(zone) ~= 'table' then return zone end

    local minimal = strip(zone, ZONE)

    minimal.rebootStations = nil
    minimal.center, minimal.radius, minimal.bounds, minimal.__needsShape = nil, nil, nil, nil

    minimal.points = zone.points
    minimal.enabled = zone.enabled

    return minimal
end

function RZ.Defaults.Apply(config)
    config = config or Config
    fill(config, D)
    for _, zone in pairs(config.Zones or {}) do
        RZ.Defaults.ApplyZone(zone)
    end
    return config
end

RZ.Defaults.Apply(Config)

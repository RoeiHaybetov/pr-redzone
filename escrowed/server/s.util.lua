RZ = RZ or {}

local EPOCH_MS, EPOCH_MONO = os.time() * 1000, GetGameTimer()

function RZ.Now()
    return EPOCH_MS + (GetGameTimer() - EPOCH_MONO)
end

function RZ.Mono()
    return GetGameTimer()
end

RZ.Log = {}

local Log = RZ.Log
local qbxLogger

local function getLogger()
    if qbxLogger ~= nil then return qbxLogger or nil end
    local ok, mod = pcall(require, '@qbx_core.modules.logger')
    if ok and type(mod) == 'table' and type(mod.log) == 'function' then
        qbxLogger = mod
    else
        qbxLogger = false
    end
    return qbxLogger or nil
end

local function enabled(category)
    if not Config.Logging.enabled then return false end
    return Config.Logging.events[category] ~= false
end

local EMBED_COLOR = { red = 15158332, orange = 15105570, green = 3066993, yellow = 15844367 }
local DEFAULT_COLOR, MAX_EMBEDS, MAX_QUEUE, POST_INTERVAL_MS = 3447003, 10, 100, 2000

local nextAllowedAt, queue, queueDropped, pumping = 0, {}, 0, false

local function postWebhook(event, message, color)
    local url = Config.Logging.webhook
    if type(url) ~= 'string' or url == '' then return end

    if #queue >= MAX_QUEUE then
        queueDropped = queueDropped + 1
        return
    end

    queue[#queue + 1] = { event = event, message = message, color = color }
    if pumping then return end
    pumping = true

    CreateThread(function()
        while true do
            local batch = {}

            if queueDropped > 0 then
                batch[1] = {
                    title = 'LogsDropped',
                    description = ('%d log line(s) were dropped because the queue was full.')
                        :format(queueDropped),
                    color = EMBED_COLOR.orange,
                }
                queueDropped = 0
            end

            while #batch < MAX_EMBEDS do
                local entry = table.remove(queue, 1)
                if not entry then break end
                batch[#batch + 1] = {
                    title = entry.event,
                    description = entry.message,
                    color = EMBED_COLOR[entry.color or ''] or DEFAULT_COLOR,
                }
            end

            if #batch > 0 then
                local waitFor = nextAllowedAt - GetGameTimer()
                if waitFor > 0 then Wait(waitFor) end

                local target = Config.Logging.webhook
                if type(target) == 'string' and target ~= '' then
                    pcall(PerformHttpRequest, target, function(status, _body, responseHeaders)
                        if status ~= 429 then return end
                        local retryAfter = responseHeaders
                            and (responseHeaders['retry-after'] or responseHeaders['Retry-After'])
                        local ms = math.floor((tonumber(retryAfter) or 1) * 1000)
                        nextAllowedAt = GetGameTimer() + math.max(ms, POST_INTERVAL_MS)
                    end, 'POST',
                        json.encode({ username = 'pr', embeds = batch }),
                        { ['Content-Type'] = 'application/json' })
                end

                nextAllowedAt = GetGameTimer() + POST_INTERVAL_MS
                Wait(POST_INTERVAL_MS)
            end

            if #queue == 0 and queueDropped == 0 then
                pumping = false
                if #queue == 0 and queueDropped == 0 then return end
                pumping = true
            end
        end
    end)
end

local function write(category, event, message, color)
    if not enabled(category) then return end

    if Config.Debug then
        print(('[pr-redzone][%s] %s'):format(event, message))
    end

    local logger = Config.Logging.useQbxLogger and getLogger() or nil
    if logger then
        local payload = { source = 'pr-redzone', event = event, message = message }
        if Config.Logging.webhook and Config.Logging.webhook ~= '' then
            payload.webhook = Config.Logging.webhook
            payload.color = color
        end
        pcall(logger.log, payload)
        return
    end

    postWebhook(event, message, color)
end

Log.Write = write

local function who(source)
    local name = GetPlayerName(source)
    return ('%s(%s)'):format(name or 'unknown', tostring(source))
end

Log.Who = who

local defs = {
    { 'InvalidEntry', 'invalidEntry', who = 1, fmt = '%s tried to enter %s — rejected: %s' },
    { 'RepeatedEntry', 'repeatedEntry', who = 1, color = 'orange',
        fmt = '%s bounced off %s boundary %d times' },
    { 'Elimination', 'elimination', who = 1, color = 'red', fmt = '%s died in %s' },
    { 'RespawnCooldown', 'respawnCooldown', color = 'orange',
        fmt = '%s locked out of %s for %d minutes' },
    { 'CombatLogCooldown', 'respawnCooldown', 'CombatLog', order = { 1, 2, 4, 3 }, color = 'orange',
        fmt = '%s quit inside %s (%s) — locked out for %d minutes' },
    { 'CrateSpawn', 'crateSpawn', fmt = 'crate spawned in %s (controlled by %s)' },
    { 'CrateLooted', 'crateLooted', who = 1, color = 'green', fmt = '%s looted the crate in %s' },
    { 'PackageSold', 'packageSold', who = 1, fmt = '%s sold a package in %s for gang %s' },
    { 'Card', 'cardGranted', 'CardReward', who = 1, color = 'yellow', fmt = '%s won the bonus %s' },
    { 'Suspicious', 'suspicious', who = 1, color = 'red', fmt = '%s rejected on %s: %s' },
    { 'SquadCreated', 'squadCreated', who = 1, fmt = '%s created squad %s ("%s")' },
    { 'SquadInvite', 'squadInvite', who = 2, fmt = '%s invited %s to squad %s' },
    { 'SquadJoin', 'squadJoin', who = 1, fmt = '%s joined squad %s' },
    { 'SquadLeave', 'squadLeave', who = 1, fmt = '%s left squad %s' },
    { 'SquadKick', 'squadKick', who = 1, order = { 1, 3, 2 }, fmt = '%s kicked %s from squad %s' },
    { 'SquadTransfer', 'squadTransfer', who = 1, fmt = '%s transferred squad %s to %s' },
    { 'SquadRename', 'squadRename', who = 1, fmt = '%s renamed squad %s to "%s"' },
    { 'SquadDisband', 'squadDisband', who = 1, color = 'orange', fmt = '%s disbanded squad %s' },
    { 'SquadSnapshot', 'squadSnapshot', 'SquadRosterLocked',
        fmt = 'squad %s locked its roster for session %s with %d member(s)' },
    { 'LootBag', 'lootBag', who = 1, color = 'orange',
        fmt = '%s dropped a loot bag in %s (%s) with %d item(s)' },
    { 'LootBagSkip', 'lootBag', 'LootBagSkipped', who = 1, fmt = 'no bag for %s on %s — %s' },
    { 'Integration', 'integrationError', 'IntegrationFailure', color = 'red', fmt = '[%s] %s' },
}

for i = 1, #defs do
    local def = defs[i]
    local cat, event, fmt, color = def[2], def[3] or def[1], def.fmt, def.color
    local whoCount, order = def.who or 0, def.order
    local arity = order and #order or select(2, fmt:gsub('%%%a', ''))

    Log[def[1]] = function(...)
        local a = { ... }
        for n = 1, whoCount do
            a[n] = who(a[n])
        end
        if order then
            local picked = {}
            for n = 1, arity do picked[n] = a[order[n]] end
            a = picked
        end
        write(cat, event, fmt:format(table.unpack(a, 1, arity)), color)
    end
end

function Log.Rewards(source, granted)
    if not enabled('rewardsGranted') then return end

    local parts = {}
    for i = 1, #granted do
        parts[#parts + 1] = ('%s x%d'):format(granted[i].item, granted[i].amount)
    end

    write('rewardsGranted', 'Rewards', ('%s received %s'):format(who(source), table.concat(parts, ', ')))
end

function Log.Info(message)
    print(('[pr-redzone] %s'):format(message))
end

function Log.Debug(message)
    if Config.Debug then
        print(('[pr-redzone][debug] %s'):format(message))
    end
end

function RZ.Notify(source, key, args, notifyType)
    if type(source) ~= 'number' or GetPlayerName(source) == nil then return end
    TriggerClientEvent(RZ.Event.NOTIFY, source, key, args, notifyType)
end

RZ.Lock = {}

local locks = {}

function RZ.Lock.Acquire(key, owner, ttlMs)
    local now = RZ.Mono()
    local existing = locks[key]
    if existing and existing.expires > now then return false end

    locks[key] = { owner = owner, expires = now + (ttlMs or 30000) }
    return true
end

function RZ.Lock.Release(key, owner)
    local existing = locks[key]
    if not existing then return end
    if owner ~= nil and existing.owner ~= owner then return end
    locks[key] = nil
end

function RZ.Lock.IsHeld(key)
    local existing = locks[key]
    if not existing then return false end
    if existing.expires <= RZ.Mono() then
        locks[key] = nil
        return false
    end
    return true
end

function RZ.Lock.Owner(key)
    local existing = locks[key]
    if not existing or existing.expires <= RZ.Mono() then return nil end
    return existing.owner
end

function RZ.Lock.ReleaseAllOwnedBy(owner)
    for key, lock in pairs(locks) do
        if lock.owner == owner then locks[key] = nil end
    end
end

function RZ.Lock.ReleaseAll()
    locks = {}
end

function RZ.Lock.Sweep()
    local now = RZ.Mono()
    for key, lock in pairs(locks) do
        if lock.expires <= now then locks[key] = nil end
    end
end

RZ.Rate = {}

local buckets = {}

function RZ.Rate.Consume(source, action)
    local limit = Config.Validation.rateLimits[action]
        or (Config.SoloSquads and Config.SoloSquads.rateLimits and Config.SoloSquads.rateLimits[action])
        or Config.Validation.rateLimits.default
    local now = RZ.Mono()

    local perPlayer = buckets[source]
    if not perPlayer then
        perPlayer = {}
        buckets[source] = perPlayer
    end

    local bucket = perPlayer[action]
    if not bucket or (now - bucket.windowStart) >= limit.windowMs then
        perPlayer[action] = { count = 1, windowStart = now }
        return true
    end

    if bucket.count >= limit.max then return false end

    bucket.count = bucket.count + 1
    return true
end

function RZ.Rate.Clear(source)
    buckets[source] = nil
end

function RZ.Guard(source, action)
    if type(source) ~= 'number' or source <= 0 then
        return false, RZ.Reject.UNVERIFIABLE
    end

    if GetPlayerName(source) == nil then
        return false, RZ.Reject.UNVERIFIABLE
    end

    if not RZ.Rate.Consume(source, action) then
        Log.Suspicious(source, action, 'rate limit exceeded')
        return false, RZ.Reject.RATE_LIMITED
    end

    local identity = RZ.Fw.Identity(source)
    if not identity then
        Log.Suspicious(source, action, 'no loaded framework player')
        return false, RZ.Reject.UNVERIFIABLE
    end

    return true, identity
end

RZ = RZ or {}

local Squads = RZ.Squads
local Cooldowns = RZ.Cooldowns
local S = RZ.Serializer

local function squadGuard(source, action)
    local ok, citizenid = RZ.Guard(source, action)
    if not ok then return false, citizenid end

    if not Config.SoloSquads.enabled then
        return false, 'squad.disabled'
    end

    local eligible, reason = Squads.IsEligible(source)
    if not eligible then
        RZ.Log.Suspicious(source, action, 'squad action by a non-solo player: ' .. tostring(reason))
        return false, 'squad.access_denied'
    end

    return true, citizenid
end

lib.callback.register(RZ.SquadCallback.GET_STATE, function(source)
    local ok, citizenid = RZ.Guard(source, 'squadUi')
    if not ok then return { eligible = false, reason = citizenid } end

    if not Config.SoloSquads.enabled then
        return { eligible = false, reason = 'squad.disabled' }
    end

    return Squads.BuildState(source, citizenid)
end)

local squadActions = {
    [RZ.SquadCallback.CREATE] = { bucket = 'squadCreate', run = function(source, citizenid, name)
        return Squads.Create(source, citizenid, name)
    end },
    [RZ.SquadCallback.INVITE] = { bucket = 'squadInvite', run = function(source, citizenid, targetServerId)
        local targetSrc = tonumber(targetServerId)
        if not targetSrc then return nil, 'squad.invite_bad_id' end
        return Squads.Invite(source, citizenid, targetSrc)
    end },
    [RZ.SquadCallback.RESPOND] = { bucket = 'squadRespond', run = function(source, citizenid, inviteId, accept)
        return Squads.RespondToInvite(source, citizenid, inviteId, accept == true)
    end },
    [RZ.SquadCallback.KICK] = { bucket = 'squadKick', run = function(source, citizenid, targetCitizenId)
        return Squads.Kick(source, citizenid, targetCitizenId)
    end },
    [RZ.SquadCallback.LEAVE] = { bucket = 'squadLeave', run = function(source, citizenid)
        return Squads.Leave(source, citizenid)
    end },
    [RZ.SquadCallback.TRANSFER] = { bucket = 'squadTransfer', run = function(source, citizenid, targetCitizenId)
        return Squads.TransferLeadership(source, citizenid, targetCitizenId)
    end },
    [RZ.SquadCallback.RENAME] = { bucket = 'squadRename', run = function(source, citizenid, name)
        return Squads.Rename(source, citizenid, name)
    end },
    [RZ.SquadCallback.DISBAND] = { bucket = 'squadDisband', run = function(source, citizenid)
        return Squads.Disband(source, citizenid)
    end },
}

for const, spec in pairs(squadActions) do
    lib.callback.register(const, function(source, a, b)
        local ok, citizenid = squadGuard(source, spec.bucket)
        if not ok then return { ok = false, error = citizenid } end

        local done, err = spec.run(source, citizenid, a, b)
        if done == nil then return { ok = false, error = err } end

        Squads.PushState(source)
        return { ok = done, error = err }
    end)
end

lib.addCommand('rzsquad', {
    help = 'Open the RedZone Solo Squad manager',
}, function(source)
    if not Config.SoloSquads.enabled then
        RZ.Notify(source, 'squad.disabled', nil, 'error')
        return
    end

    local identity = RZ.Fw.Identity(source)
    if not identity then return end

    local eligible = Squads.IsEligible(source)
    if not eligible then
        RZ.Notify(source, 'squad.access_denied', nil, 'error')
        return
    end

    TriggerClientEvent(RZ.SquadEvent.OPEN, source, Squads.BuildState(source, identity))
end)

local NOT_AUTHORIZED = 'Not authorized.'

local function maxPayload()
    return (Config.AdminMenu and Config.AdminMenu.maxPayloadBytes) or 262144
end

local function checkPayload(payload)
    if payload == nil then return true end
    if type(payload) ~= 'table' then return false, 'malformed payload' end

    local ok, encoded = pcall(json.encode, payload)
    if not ok or type(encoded) ~= 'string' then return false, 'unserialisable payload' end
    if #encoded > maxPayload() then return false, 'payload too large' end

    return true
end

local function register(const, bucket, denyKey, handler)
    lib.callback.register(const, function(source, token, a, b)
        local ok, session = RZ.AdminSessions.Guard(source, bucket, token)
        if not ok then
            if denyKey == 'errors' then return { ok = false, errors = { NOT_AUTHORIZED } } end
            if denyKey == 'error' then return { ok = false, error = NOT_AUTHORIZED } end
            return { ok = false }
        end
        return handler(source, session, a, b)
    end)
end

lib.callback.register(RZ.AdminCallback.OPEN, function(source)
    local authorised, discordId = RZ.AdminAuth.Check(source)

    if not authorised then
        RZ.AdminAudit.Denied(source, discordId)
        return { ok = false, message = RZ.AdminAuth.DenyMessage(discordId) }
    end

    if not RZ.Rate.Consume(source, 'adminOpen') then
        return { ok = false, message = 'Slow down.' }
    end

    local session = RZ.AdminSessions.Create(source, discordId)
    RZ.AdminAudit.Write(session, 'menu_open', nil, nil, true, nil, RZ.AdminStore.GetRevision())

    return {
        ok = true,
        token = session.token,
        revision = RZ.AdminStore.GetRevision(),
        schemaVersion = RZ.AdminSchema.SCHEMA_VERSION,
        capabilities = {
            allowLiveDebugToggle = Config.AdminMenu.allowLiveDebugToggle == true,
            allowWebhookReplacement = Config.AdminMenu.allowWebhookReplacement == true,
            allowWhitelistEditingInUi = Config.AdminMenu.allowWhitelistEditingInUi == true,
            requirePublishConfirmation = Config.AdminMenu.requirePublishConfirmation ~= false,
        },
    }
end)

lib.callback.register(RZ.AdminCallback.CLOSE, function(source, token)
    if type(source) ~= 'number' or source <= 0 then return { ok = false } end
    if not RZ.Rate.Consume(source, 'adminOpen') then return { ok = false } end

    local session = RZ.AdminSessions.Get(source)
    if session and (token == nil or session.token == token) then
        RZ.AdminAudit.Write(session, 'menu_close', nil, nil, true)
    end
    RZ.AdminSessions.Destroy(source)
    return { ok = true }
end)

register(RZ.AdminCallback.GET_CONFIG, 'adminRead', nil, function()
    RZ.AdminSchema.Reindex(Config)
    local fields = RZ.AdminSchema.BuildFields(Config)

    local out = {}
    for i = 1, #fields do
        local f = fields[i]
        local entry = {}
        for key, value in pairs(f) do entry[key] = value end

        entry.apply = f.apply or 'live'
        entry.confirm = f.confirm == true
        entry.danger = f.danger == true
        entry.itemCheck = f.itemCheck == true
        entry.advanced = f.advanced == true
        entry.value = S.ToJson(S.Get(Config, f.path))

        out[i] = entry
    end

    local webhook = Config.Logging and Config.Logging.webhook
    local zoneIds = {}
    for zoneId in pairs(Config.Zones or {}) do zoneIds[#zoneIds + 1] = zoneId end
    table.sort(zoneIds)

    return {
        ok = true,
        revision = RZ.AdminStore.GetRevision(),
        sections = RZ.AdminSchema.sections,
        fields = out,
        zones = zoneIds,
        zoneStructure = S.ToJson(RZ.AdminStore.PendingZones()),
        queued = RZ.AdminApply.GetDeferred() ~= nil,
        webhookConfigured = (webhook ~= nil and webhook ~= ''),
        suggestions = {
            jobTypes = RZ.AdminControls.JobTypes(),
            jobNames = RZ.AdminControls.JobNames(),
        },
    }
end)

register(RZ.AdminCallback.DASHBOARD, 'adminRead', nil, function()
    return { ok = true, data = RZ.AdminDiag.Dashboard() }
end)

register(RZ.AdminCallback.INSPECT, 'adminRead', nil, function()
    return { ok = true, rows = RZ.AdminDiag.Inspect() }
end)

register(RZ.AdminCallback.DIAGNOSTICS, 'adminDiag', nil, function(source, session)
    RZ.AdminAudit.Write(session, 'diagnostics', nil, nil, true, nil, RZ.AdminStore.GetRevision())
    return { ok = true, data = RZ.AdminDiag.Run() }
end)

register(RZ.AdminCallback.VALIDATE, 'adminValidate', nil, function(source, session, draft)
    local sane, err = checkPayload(draft)
    if not sane then
        RZ.Log.Suspicious(source, 'adminValidate', err)
        return { ok = false, errors = { 'Rejected: ' .. err } }
    end

    return RZ.AdminPublish.ValidateDraft(draft)
end)

register(RZ.AdminCallback.PUBLISH, 'adminPublish', 'errors', function(source, session, draft, opts)
    local sane, err = checkPayload(draft)
    if not sane then
        RZ.Log.Suspicious(source, 'adminPublish', err)
        RZ.AdminAudit.Write(session, 'publish', nil, nil, false, err)
        return { ok = false, errors = { 'Rejected: ' .. err } }
    end

    opts = type(opts) == 'table' and opts or {}
    return RZ.AdminPublish.Publish(session, draft, {
        baseRevision = tonumber(opts.baseRevision) or -1,
        reason = type(opts.reason) == 'string' and opts.reason or nil,
        applyMode = (opts.applyMode == 'session' or opts.applyMode == 'live') and opts.applyMode or nil,
        acknowledgeWarnings = opts.acknowledgeWarnings == true,
    })
end)

register(RZ.AdminCallback.HISTORY, 'adminRead', nil, function(source, session, limit)
    local rows = RZ.Db.FetchConfigHistory(tonumber(limit) or 25)
    local out = {}

    for i = 1, #rows do
        local row = rows[i]
        local diff = row.diff_json and json.decode(row.diff_json) or {}
        out[i] = {
            revision = row.revision,
            previousRevision = row.previous_revision,
            by = row.changed_by_name,
            byDiscord = RZ.AdminAuth.Mask(row.changed_by_discord),
            reason = row.change_reason,
            createdAt = tostring(row.created_at),
            fieldCount = type(diff) == 'table' and #diff or 0,
            diff = diff,
        }
    end

    return { ok = true, rows = out }
end)

register(RZ.AdminCallback.LOAD_REVISION, 'adminRead', nil, function(source, session, revision)
    local rev = tonumber(revision)
    if not rev then return { ok = false, error = 'Invalid revision.' } end

    local draft, err = RZ.AdminPublish.LoadRevisionAsDraft(rev)
    if not draft then return { ok = false, error = err } end

    RZ.AdminAudit.Write(session, 'load_revision', nil, ('revision %d'):format(rev), true)
    return { ok = true, draft = draft }
end)

register(RZ.AdminCallback.EXPORT, 'adminRead', nil, function(source, session)
    local flat, zones = RZ.AdminStore.CurrentFlat()
    local fields = {}
    for path, value in pairs(flat) do
        if path ~= 'Logging.webhook' then
            fields[path] = S.ToJson(value)
        end
    end

    RZ.AdminAudit.Write(session, 'export', nil, nil, true, nil, RZ.AdminStore.GetRevision())

    return {
        ok = true,
        payload = {
            schemaVersion = RZ.AdminSchema.SCHEMA_VERSION,
            revision = RZ.AdminStore.GetRevision(),
            exportedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
            fields = fields,
            zones = zones and S.ToJson(zones) or nil,
        },
    }
end)

register(RZ.AdminCallback.SET_WEBHOOK, 'adminPublish', 'error', function(source, session, url)
    if Config.AdminMenu.allowWebhookReplacement ~= true then
        return { ok = false, error = 'Webhook replacement is disabled in config.' }
    end

    local clearing = (url == nil or url == '')

    if not clearing then
        if type(url) ~= 'string' or #url > 300 then
            return { ok = false, error = 'That does not look like a webhook URL.' }
        end
        if not url:match('^https://discord%.com/api/webhooks/%d+/[%w%-_]+$')
            and not url:match('^https://discordapp%.com/api/webhooks/%d+/[%w%-_]+$') then
            return { ok = false, error = 'Only Discord webhook URLs are accepted.' }
        end
    end

    local value = clearing and '' or url
    local flat, zones, queued = RZ.AdminStore.PendingState()
    flat['Logging.webhook'] = value

    -- The webhook goes live now even while a zone change waits for the next session, so the
    -- saved state carries both and only the webhook half is applied to the running config.
    local apply = true
    if queued then
        local liveFlat, liveZones = RZ.AdminStore.CurrentFlat()
        liveFlat = S.Copy(liveFlat)
        liveFlat['Logging.webhook'] = value
        apply = { flat = liveFlat, zones = liveZones and S.Copy(liveZones) or nil }
    end

    local committed, revision = RZ.AdminStore.Commit(flat, zones, session.discordId, session.name, apply)
    if committed and queued then
        queued.flat = flat
        queued.revision = revision
    end
    if not committed then
        RZ.AdminAudit.Write(session, 'webhook', nil, nil, false, 'save failed')
        return { ok = false, error = 'Could not save the webhook.' }
    end

    RZ.AdminAudit.Write(session, 'webhook', nil,
        clearing and 'cleared' or 'replaced', true, nil, revision)

    return { ok = true, configured = not clearing, revision = revision }
end)

register(RZ.AdminCallback.TEST_LOG, 'adminDiag', nil, function(source, session)
    RZ.Log.Write('adminAction', 'AdminTestLog',
        ('Test log requested by %s (%s)'):format(session.name, RZ.AdminAuth.Mask(session.discordId)), 'blue')
    RZ.AdminAudit.Write(session, 'test_log', nil, nil, true)

    return { ok = true }
end)

register(RZ.AdminCallback.CONTROL, 'adminControl', 'error', function(source, session, action, payload)
    local sane, err = checkPayload(payload)
    if not sane then
        RZ.Log.Suspicious(source, 'adminControl', err)
        return { ok = false, error = 'Rejected: ' .. err }
    end

    return RZ.AdminControls.Run(session, action, payload or {})
end)

local function tell(source, message)
    local ok = pcall(function()
        RZ.Fw.Notify(source, message, 'error')
    end)
    if not ok then
        TriggerClientEvent('chat:addMessage', source, { args = { '[redzone]', message } })
    end
end

local function openMenu(source, view)
    if source == 0 then
        print('[pr-redzone] the admin menu must be opened in-game, not from the console.')
        return
    end

    local authorised, discordIdOrReason = RZ.AdminAuth.Check(source)

    if not authorised then
        RZ.AdminAudit.Denied(source, discordIdOrReason)
        tell(source, RZ.AdminAuth.DenyMessage(discordIdOrReason))
        return
    end

    TriggerClientEvent(RZ.AdminEvent.OPEN, source, view)
end

RZ.AdminOpenMenu = openMenu

CreateThread(function()
    Wait(0)

    if not Config.AdminMenu then return end

    local commandName = Config.AdminMenu.command
    if type(commandName) ~= 'string' or commandName == '' then
        commandName = 'redzonemenu'
    end

    RegisterCommand(commandName, function(source)
        openMenu(source)
    end, false)

    RegisterCommand('redzonecreate', function(source)
        openMenu(source, 'create')
    end, false)

    if Config.AdminMenu.allowCommandAlias == true then
        RegisterCommand('redzone', function(source, args)
            local sub = args and args[1] and tostring(args[1]):lower() or nil

            if sub == 'menu' then
                openMenu(source)
                return
            end

            if sub == 'create' then
                openMenu(source, 'create')
                return
            end

            if source ~= 0 then
                tell(source, 'Usage: /redzone menu | /redzone create')
            else
                print('[pr-redzone] usage: /redzone menu (in-game only)')
            end
        end, false)
    end
end)

CreateThread(function()
    Wait(0)

    local name = (Config.Cooldown and Config.Cooldown.command) or 'cooldown'
    if type(name) ~= 'string' or name == '' then return end

    lib.addCommand(name, {
        help = 'Check your remaining RedZone lockout',
    }, function(source)
        if type(source) ~= 'number' or source <= 0 then return end

        local citizenid = RZ.Fw.Identity(source)
        if not citizenid then return end

        local longest = 0

        for zoneId, zone in pairs(Config.Zones) do
            if zone.enabled then
                local remaining = Cooldowns.GetRemaining(citizenid, zoneId)
                if remaining > longest then
                    longest = remaining
                end
            end
        end

        if longest <= 0 then
            RZ.Notify(source, 'cooldown.none', nil, 'success')
            return
        end

        RZ.Notify(source, 'cooldown.remaining', { RZ.Util.FormatDuration(longest) }, 'error')
    end)
end)

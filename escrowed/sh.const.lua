RZ = RZ or {}

RZ.RESOURCE = GetCurrentResourceName()

if not RZ.Defaults then
    local where = IsDuplicityVersion and IsDuplicityVersion() and 'server' or 'client'
    print(('^1[pr-redzone] FATAL (%s): escrowed/sh.defaults.lua did not load.^7'):format(where))
    print('^1  Every optional setting is missing. Cooldowns, zone boundaries and the^7')
    print('^1  validation loop will all misbehave in unrelated-looking ways.^7')
    print('^3  Fix: run "refresh" then "restart pr-redzone" (adding a file to^7')
    print('^3  fxmanifest requires refresh; restart alone keeps the cached manifest).^7')
end

RZ.STATE_BAG = 'rzState'

RZ.State = {
    OUTSIDE = 'outside', ALIVE = 'alive',
    ELIMINATED = 'eliminated', RESPAWN_BLOCKED = 'respawn_blocked',
}

local S = RZ.State

RZ.Transitions = {
    [S.OUTSIDE] = { [S.ALIVE] = true, [S.RESPAWN_BLOCKED] = true },
    [S.ALIVE] = { [S.OUTSIDE] = true, [S.ELIMINATED] = true },
    [S.ELIMINATED] = { [S.RESPAWN_BLOCKED] = true, [S.ALIVE] = true, [S.OUTSIDE] = true },
    [S.RESPAWN_BLOCKED] = { [S.OUTSIDE] = true, [S.ALIVE] = true },
}

RZ.CountsForControl = { [S.ALIVE] = true }

RZ.Reject = {
    ZONE_CLOSED = 'zone_closed', NO_GANG = 'no_gang', SOLO = 'solo',
    INVALID_GANG = 'invalid_gang', UNVERIFIABLE = 'unverifiable', COOLDOWN = 'cooldown',
    NOT_ALIVE = 'not_alive', TOO_FAR = 'too_far', WRONG_GANG = 'wrong_gang',
    LOCKED = 'locked', NO_ITEM = 'no_item', INVENTORY_FULL = 'inventory_full',
    RATE_LIMITED = 'rate_limited', TARGET_OFFLINE = 'target_offline',
    ALREADY_TAKEN = 'already_taken', INVALID_RECORD = 'invalid_record',
    INTEGRATION = 'integration_failure',
    NO_SQUAD = 'no_squad', SQUAD_NOT_LOCKED = 'squad_not_locked',
    SQUAD_JOINED_AFTER_LOCK = 'squad_joined_after_lock', SQUAD_FULL = 'squad_full',
    NOT_SOLO = 'not_solo', NOT_LEADER = 'not_leader', BLOCKED_JOB = 'blocked_job',
}

local NS = RZ.RESOURCE

RZ.Local = {
    ENTERED_ZONE  = NS .. ':client:enteredZone',
    LEFT_ZONE     = NS .. ':client:leftZone',
    ZONES_CHANGED = NS .. ':client:zonesChanged',
    CRATE_CHANGED = NS .. ':client:crateChanged',
    STATE_CHANGED = NS .. ':client:stateChanged',
}

RZ.Callback = {
    LOOT_CRATE   = NS .. ':sv:lootCrate',
    SELL_PACKAGE = NS .. ':sv:sellPackage',
    SYNC_REQUEST = NS .. ':sv:syncRequest',
}

RZ.Event = {
    SYNC_WORLD    = NS .. ':cl:syncWorld',
    SYNC_SELF     = NS .. ':cl:syncSelf',
    FORCE_EJECT   = NS .. ':cl:forceEject',
    NOTIFY        = NS .. ':cl:notify',
    COOLDOWN_BURN = NS .. ':cl:cooldownBurn',
    SYNC_BAGS     = NS .. ':cl:syncBags',
    CONFIG_SYNC   = NS .. ':cl:configSync',
}

RZ.SquadCallback = {
    GET_STATE = NS .. ':sv:squadGetState',
    CREATE    = NS .. ':sv:squadCreate',
    INVITE    = NS .. ':sv:squadInvite',
    RESPOND   = NS .. ':sv:squadRespond',
    KICK      = NS .. ':sv:squadKick',
    LEAVE     = NS .. ':sv:squadLeave',
    TRANSFER  = NS .. ':sv:squadTransfer',
    RENAME    = NS .. ':sv:squadRename',
    DISBAND   = NS .. ':sv:squadDisband',
}

RZ.SquadEvent = {
    STATE  = NS .. ':cl:squadState',
    INVITE = NS .. ':cl:squadInvite',
    OPEN   = NS .. ':cl:squadOpen',
}

RZ.AdminCallback = {
    OPEN          = NS .. ':sv:adminOpen',
    CLOSE         = NS .. ':sv:adminClose',
    GET_CONFIG    = NS .. ':sv:adminGetConfig',
    DASHBOARD     = NS .. ':sv:adminDashboard',
    INSPECT       = NS .. ':sv:adminInspect',
    DIAGNOSTICS   = NS .. ':sv:adminDiagnostics',
    VALIDATE      = NS .. ':sv:adminValidate',
    PUBLISH       = NS .. ':sv:adminPublish',
    HISTORY       = NS .. ':sv:adminHistory',
    LOAD_REVISION = NS .. ':sv:adminLoadRevision',
    EXPORT        = NS .. ':sv:adminExport',
    SET_WEBHOOK   = NS .. ':sv:adminSetWebhook',
    TEST_LOG      = NS .. ':sv:adminTestLog',
    CONTROL       = NS .. ':sv:adminControl',
}

RZ.AdminEvent = {
    OPEN = NS .. ':cl:adminOpen',
}

RZ = RZ or {}
RZ.AdminSchema = {}

local A = RZ.AdminSchema

A.SCHEMA_VERSION = 2

A.sections = {
    { id = 'overview', label = 'Overview', icon = 'gauge',      virtual = true },
    { id = 'zones',    label = 'Zones',    icon = 'map',        virtual = true },
    { id = 'combat',   label = 'Combat',   icon = 'crosshairs' },
    { id = 'economy',  label = 'Economy',  icon = 'cash' },
    { id = 'players',  label = 'Players',  icon = 'users' },
    { id = 'server',   label = 'Server',   icon = 'sliders' },
}

A.fields = {}
A.zoneTemplate = {}

local function push(target, section, group, list, advanced)
    for i = 1, #list do
        local f = list[i]
        f.section, f.group = section, group
        if advanced then f.advanced = true end
        target[#target + 1] = f
    end
end

push(A.fields, 'combat', 'Knock', {
    { path = 'Knock.durationMs', label = 'Bleed-out duration', desc = 'How long a downed player has before elimination.',
      type = 'int', min = 3000, max = 300000, step = 1000, unit = 'ms', apply = 'session' },
    { path = 'Knock.downedHealth', label = 'Downed health', desc = 'Health the ped is pinned to while downed. Must stay above 0 so the ped never dies.',
      type = 'int', min = 10, max = 199, step = 5, apply = 'live' },
    { path = 'Knock.lethalThreshold', label = 'Lethal threshold', desc = 'Damage below this health triggers the knock. Must be above downed health.',
      type = 'int', min = 10, max = 199, step = 5, apply = 'live' },
    { path = 'Knock.crawlSpeed', label = 'Crawl speed', desc = 'Move-rate multiplier while downed. Below ~0.4 feels stuck.', type = 'number', min = 0.1, max = 1.0, step = 0.05, apply = 'live' },
    { path = 'Knock.immuneWhileDowned', label = 'Immune while downed', desc = 'Further damage cannot shorten the bleed-out timer. Turn OFF to let enemies finish a downed player.',
      type = 'bool', apply = 'live' },
    { path = 'Knock.finishThreshold', label = 'Finish threshold', desc = 'Only when immunity is off. Health at or below this counts as finished; the ped is floored at 1 hp and never allowed to actually die.',
      type = 'int', min = 1, max = 50, step = 1, unit = 'hp', apply = 'live' },
})

push(A.fields, 'combat', 'Revive', {
    { path = 'Revive.durationMs', label = 'Revive duration', type = 'int', min = 500, max = 60000, step = 500, unit = 'ms', apply = 'live' },
    { path = 'Revive.revivedHealth', label = 'Revived health', type = 'int', min = 1, max = 200, step = 5, apply = 'live' },
    { path = 'Revive.maxDistance', label = 'Max distance', desc = 'Reviver and target must stay within this range.', type = 'number', min = 0.5, max = 20.0, step = 0.5, unit = 'm', apply = 'live' },
    { path = 'Revive.watchdogGraceMs', label = 'Watchdog grace', type = 'int', min = 500, max = 30000, step = 500, unit = 'ms', apply = 'live', advanced = true },
})

push(A.fields, 'combat', 'CPR minigame', {
    { path = 'Revive.minigame.enabled', label = 'Rhythm minigame', desc = 'Off falls back to a plain progress bar.', type = 'bool', apply = 'live' },
    { path = 'Revive.minigame.bpm', label = 'Compressions per minute', desc = 'Clinical CPR is 100-120.', type = 'int', min = 40, max = 200, step = 5, apply = 'live' },
    { path = 'Revive.minigame.hitWindowMs', label = 'Hit window', desc = 'Milliseconds either side of the beat that still count. Tighter is harder.',
      type = 'int', min = 60, max = 500, step = 10, unit = 'ms', apply = 'live' },
    { path = 'Revive.minigame.requiredAccuracy', label = 'Required accuracy', desc = 'Fraction of compressions that must land. 0.6 = 60%.',
      type = 'number', min = 0.0, max = 1.0, step = 0.05, apply = 'live' },
    { path = 'Revive.minigame.control', label = 'Compression key', desc = 'FiveM control id. 22 = SPACE.', type = 'int', min = 1, max = 400, step = 1, apply = 'live', advanced = true },
    { path = 'Revive.minigame.maxConsecutiveMisses', label = 'Abandon after N misses', desc = '0 disables, so only the final accuracy matters.',
      type = 'int', min = 0, max = 50, step = 1, apply = 'live', advanced = true },
})

push(A.fields, 'combat', 'Reboot', {
    { path = 'Reboot.durationMs', label = 'Reboot duration', type = 'int', min = 1000, max = 120000, step = 500, unit = 'ms', apply = 'live' },
    { path = 'Reboot.rebootedHealth', label = 'Rebooted health', type = 'int', min = 1, max = 200, step = 5, apply = 'live' },
    { path = 'Reboot.maxDistance', label = 'Max station distance', desc = 'MUST exceed every station interaction distance, or reboots self-cancel.',
      type = 'number', min = 1.0, max = 50.0, step = 0.5, unit = 'm', apply = 'live' },
    { path = 'Reboot.watchdogGraceMs', label = 'Watchdog grace', type = 'int', min = 500, max = 30000, step = 500, unit = 'ms', apply = 'live', advanced = true },
})

push(A.fields, 'combat', 'Elimination', {
    { path = 'Elimination.acquireDistance', label = 'DNA acquire distance', type = 'number', min = 0.5, max = 15.0, step = 0.5, unit = 'm', apply = 'live' },
    { path = 'Elimination.autoRespawnSeconds', label = 'Auto-respawn', desc = 'Ceiling before qbx_medical respawns a corpse. Must allow time for a teammate to reach it.',
      type = 'int', min = 30, max = 3600, step = 30, unit = 's', apply = 'live' },
    { path = 'Elimination.expiryMinutes', label = 'Record expiry', desc = 'Should match the DNA item degrade time in ox_inventory.',
      type = 'int', min = 0, max = 1440, step = 5, unit = 'm', apply = 'live' },
    { path = 'Elimination.pruneAfterDays', label = 'Prune resolved records after', type = 'int', min = 0, max = 365, step = 1, unit = 'd', apply = 'live', advanced = true },
})

push(A.fields, 'combat', 'Cooldown', {
    { path = 'Cooldown.minutes', label = 'Lockout minutes', desc = 'Applied after elimination + normal respawn.',
      type = 'int', min = 0, max = 1440, step = 5, unit = 'm', apply = 'live', confirm = true },
    { path = 'Cooldown.applyOnQuitInZone', label = 'Lock out combat loggers', desc = 'Disconnecting inside an open zone costs the same lockout as dying. Crashes count — they cannot be told apart from a rage-quit.',
      type = 'bool', apply = 'live' },
    { path = 'Cooldown.blockReviveWhileOnCooldown', label = 'No revive while locked out', desc = 'Teammates cannot pick up a locked-out player, and a revive from another script is undone.',
      type = 'bool', apply = 'live' },
    { path = 'Cooldown.cleanupIntervalMs', label = 'Cleanup interval', type = 'int', min = 30000, max = 3600000, step = 30000, unit = 'ms', apply = 'live', advanced = true },
})

push(A.fields, 'combat', 'Lockout burn', {
    { path = 'Cooldown.damage.enabled', label = 'Burn instead of eject', desc = 'A locked-out player who stands in the zone loses health until they die, rather than being teleported out.',
      type = 'bool', apply = 'live' },
    { path = 'Cooldown.damage.amount', label = 'Health per tick', desc = 'Player health runs 0-200, so 20 is ten seconds of standing.',
      type = 'int', min = 1, max = 200, step = 1, unit = 'hp', apply = 'live' },
    { path = 'Cooldown.damage.intervalMs', label = 'Tick interval', type = 'int', min = 250, max = 10000, step = 250, unit = 'ms', apply = 'live' },
    { path = 'Cooldown.damage.ejectInstead', label = 'Force the old ejection', desc = 'Teleport locked-out players out instead of burning them. Overrides the burn.', type = 'bool', apply = 'live' },
    { path = 'Cooldown.damage.warnIntervalMs', label = 'Warning interval', desc = 'How often they are told why, so it does not spam every tick.',
      type = 'int', min = 1000, max = 30000, step = 500, unit = 'ms', apply = 'live', advanced = true },
    { path = 'Cooldown.damage.ejectAfterIgnoredTicks', label = 'Eject after ignored ticks', desc = "The damage lands on the player's own client. If the server sees their health fail to fall this many ticks running, it teleports them out instead.",
      type = 'int', min = 1, max = 20, step = 1, apply = 'live', advanced = true },
})

push(A.fields, 'combat', 'Loot bag', {
    { path = 'LootBag.enabled', label = 'Enabled', type = 'bool', apply = 'live' },
    { path = 'LootBag.onRespawn', label = 'Drop on respawn', type = 'bool', apply = 'live' },
    { path = 'LootBag.onDisconnect', label = 'Drop on disconnect', desc = 'Covers F8 quit, crashes and timeouts.', type = 'bool', apply = 'live' },
    { path = 'LootBag.zoneOnly', label = 'RedZone only', desc = 'Leave this ON. Off makes every disconnect anywhere on the map drop a bag.', type = 'bool', apply = 'live', confirm = true },
    { path = 'LootBag.requireWeapon', label = 'Only if armed', desc = 'No bag from an unarmed player leaving.', type = 'bool', apply = 'live' },
    { path = 'LootBag.hotbarSlots', label = 'Hotbar slots', desc = "How many slots count as the hotbar. Everything in them goes in the bag. ox_inventory's default is 5.",
      type = 'int', min = 1, max = 10, step = 1, apply = 'live' },
    { path = 'LootBag.takeWeaponsAnywhere', label = 'Take stashed weapons too', desc = 'Also take every weapon found outside the hotbar, so a rifle cannot be hidden in a back slot. Non-weapon items outside the hotbar are never touched.',
      type = 'bool', apply = 'live' },
    { path = 'LootBag.despawnMinutes', label = 'Despawn after', type = 'int', min = 1, max = 120, step = 1, unit = 'm', apply = 'live' },
    { path = 'LootBag.crashCheck.enabled', label = 'Spare genuine crashes', desc = 'A real game crash mid-fight keeps the bag and skips the lockout. F8 quit, Alt+F4 and faked crashes still count. Off: every disconnect counts.',
      type = 'bool', apply = 'live' },
    { path = 'LootBag.crashCheck.punishTimeouts', label = 'Punish timeouts', desc = 'The game was killed or the network pulled, so no crash report arrived. This is the usual way to fake a crash.',
      type = 'bool', apply = 'live' },
    { path = 'LootBag.crashCheck.punishFreezes', label = 'Punish freezes', desc = 'The game froze and stopped answering for 60 seconds. Usually a real hang.',
      type = 'bool', apply = 'live', advanced = true },
    { path = 'LootBag.crashCheck.crashAllowance', label = 'Crashes forgiven', desc = 'A cheat client can forge a crash report, so only this many crashes in a fight are forgiven per player in the window. 0 forgives none.',
      type = 'int', min = 0, max = 20, step = 1, apply = 'live' },
    { path = 'LootBag.crashCheck.crashWindowHours', label = 'Crash window', type = 'int', min = 1, max = 720, step = 1, unit = 'h', apply = 'live', advanced = true },
    { path = 'LootBag.prop', label = 'Bag prop', type = 'string', maxLength = 64, apply = 'live', modelCheck = 'prop', advanced = true },
    { path = 'LootBag.slots', label = 'Bag slots', type = 'int', min = 1, max = 50, step = 1, apply = 'live', advanced = true },
    { path = 'LootBag.maxWeight', label = 'Bag max weight', type = 'int', min = 1000, max = 500000, step = 1000, apply = 'live', advanced = true },
})

push(A.fields, 'combat', 'Crawl animation', {
    { path = 'Knock.crawl.dict', label = 'Crawl dictionary', desc = 'Animation dictionary with root motion. Verify with /redzone_findcrawl.', type = 'string', maxLength = 64, apply = 'live' },
    { path = 'Knock.crawl.forward', label = 'Forward clip', type = 'string', maxLength = 64, apply = 'live' },
    { path = 'Knock.crawl.backward', label = 'Backward clip', type = 'string', maxLength = 64, apply = 'live' },
    { path = 'Knock.crawl.idleDict', label = 'Idle dictionary', type = 'string', maxLength = 64, apply = 'live' },
    { path = 'Knock.crawl.idleClip', label = 'Idle clip', type = 'string', maxLength = 64, apply = 'live' },
    { path = 'Knock.crawl.turnRate', label = 'Turn rate', desc = 'Degrees of heading change per frame while crawling.', type = 'number', min = 0.1, max = 10.0, step = 0.1, apply = 'live' },
    { path = 'Knock.crawlClipsets', label = 'Fallback clipsets', desc = 'Tried in order if the crawl dictionary fails to load.', type = 'tags', maxItems = 8, maxLength = 64, apply = 'live' },
}, true)

push(A.fields, 'economy', 'Items', {
    { path = 'Items.package', label = 'Package item', desc = 'Must exist in ox_inventory.', type = 'string', maxLength = 64, apply = 'live', confirm = true, itemCheck = true },
    { path = 'Items.teammateDna', label = 'Teammate DNA item', desc = 'Must be unique (stack = false). Changing this invalidates DNA already carried.',
      type = 'string', maxLength = 64, apply = 'live', confirm = true, itemCheck = true },
    { path = 'Items.keycard', label = 'Keycard item', type = 'string', maxLength = 64, apply = 'live', confirm = true, itemCheck = true },
})

push(A.fields, 'economy', 'Seller payout', {
    { path = 'Rewards.materials', label = 'Material rewards', desc = 'Granted per package sold. Every item must exist in ox_inventory.', type = 'rewards', maxItems = 12, apply = 'live' },
    { path = 'Rewards.keycardChancePercent', label = 'Keycard chance', type = 'number', min = 0, max = 100, step = 1, unit = '%', apply = 'live' },
    { path = 'Rewards.keycardAmount', label = 'Keycard amount', type = 'int', min = 1, max = 100, step = 1, apply = 'live' },
})

push(A.fields, 'players', 'Gang access', {
    { path = 'Gangs.requireGang', label = 'Gang members only', desc = 'On: a player with no gang cannot see the RedZone on the map and is pushed out of it. Off: no gang plays as Solo.',
      type = 'bool', apply = 'live', confirm = true },
    { path = 'Gangs.soloGangs', label = 'Solo gangs', desc = 'Members of these gangs fight as Solo Squads and are the only ones who can use /rzsquad. Name or label, any case.',
      type = 'tags', maxItems = 16, maxLength = 48, apply = 'live' },
    { path = 'Gangs.notGangs', label = 'Not a gang', desc = 'Gang (or, on ESX, job) names that count as no gang at all.',
      type = 'tags', maxItems = 64, maxLength = 48, apply = 'live' },
})

push(A.fields, 'players', 'Solo squads', {
    { path = 'SoloSquads.enabled', label = 'Enabled', type = 'bool', apply = 'session', confirm = true },
    { path = 'SoloSquads.requireSquadForEntry', label = 'Require squad for entry', type = 'bool', apply = 'session' },
    { path = 'SoloSquads.maxMembers', label = 'Max members', desc = 'Includes the leader. Lowering this never deletes existing members.',
      type = 'int', min = 1, max = 64, step = 1, apply = 'session', confirm = true },
    { path = 'SoloSquads.lockRosterAfterFirstEntry', label = 'Lock roster on first entry', desc = 'Changing this mid-session applies next session; active snapshots are never mutated.',
      type = 'bool', apply = 'session', confirm = true },
    { path = 'SoloSquads.persistSquads', label = 'Persist squads', type = 'bool', apply = 'restart' },
    { path = 'SoloSquads.inviteExpirationSeconds', label = 'Invite expiry', type = 'int', min = 5, max = 600, step = 5, unit = 's', apply = 'live' },
    { path = 'SoloSquads.inviteCooldownSeconds', label = 'Invite cooldown', type = 'int', min = 0, max = 300, step = 1, unit = 's', apply = 'live' },
    { path = 'SoloSquads.allowMaterialsReward', label = 'Allow materials', type = 'bool', apply = 'live' },
    { path = 'SoloSquads.allowKeycardReward', label = 'Allow keycard', type = 'bool', apply = 'live' },
    { path = 'SoloSquads.dnaExpiresAtSessionEnd', label = 'DNA expires at session end', type = 'bool', apply = 'session' },
    { path = 'SoloSquads.autoTransferLeaderAfterMinutes', label = 'Auto-transfer leader after', desc = '0 disables. An offline leader keeps the role.',
      type = 'int', min = 0, max = 10080, step = 5, unit = 'm', apply = 'live' },
})

push(A.fields, 'players', 'Squad naming', {
    { path = 'SoloSquads.name.blockedWords', label = 'Blocked words', type = 'tags', maxItems = 200, maxLength = 48, apply = 'live' },
    { path = 'SoloSquads.name.minLength', label = 'Name min length', type = 'int', min = 1, max = 32, step = 1, apply = 'live', advanced = true },
    { path = 'SoloSquads.name.maxLength', label = 'Name max length', type = 'int', min = 2, max = 64, step = 1, apply = 'live', advanced = true },
    { path = 'SoloSquads.name.renameLimit', label = 'Rename limit', type = 'int', min = 1, max = 50, step = 1, apply = 'live', advanced = true },
    { path = 'SoloSquads.name.renameWindowMs', label = 'Rename window', type = 'int', min = 1000, max = 3600000, step = 1000, unit = 'ms', apply = 'live', advanced = true },
})

push(A.fields, 'players', 'Blocked jobs', {
    { path = 'BlockedJobs.enabled', label = 'Enabled', type = 'bool', apply = 'live' },
    { path = 'BlockedJobs.types', label = 'Blocked job types', desc = "'leo' covers police, bcso and sasp.", type = 'tags', maxItems = 32, maxLength = 32, apply = 'live', suggest = 'jobTypes' },
    { path = 'BlockedJobs.names', label = 'Blocked job names', type = 'tags', maxItems = 64, maxLength = 32, apply = 'live', suggest = 'jobNames' },
    { path = 'BlockedJobs.onlyWhenOnDuty', label = 'Only while on duty', desc = 'Off means an off-duty officer is still refused.', type = 'bool', apply = 'live' },
})

push(A.fields, 'players', 'Squad rate limits', {
    { path = 'SoloSquads.rateLimits', label = 'Squad action rate limits', type = 'ratelimits', apply = 'live' },
}, true)

push(A.fields, 'server', 'HUD', {
    { path = 'Hud.enabled', label = 'HUD enabled', type = 'bool', apply = 'live' },
    { path = 'Hud.position', label = 'HUD position', type = 'select', options = { 'bottom-right', 'bottom-left', 'bottom-center', 'top-right', 'top-left', 'top-center' }, apply = 'live' },
    { path = 'Hud.scale', label = 'HUD scale', type = 'number', min = 0.5, max = 2.5, step = 0.05, apply = 'live' },
})

push(A.fields, 'server', 'Model fallbacks', {
    { path = 'Fallbacks.prop', label = 'Fallback prop', desc = 'Used when a configured prop cannot be streamed.', type = 'string', maxLength = 64, apply = 'live', modelCheck = 'prop' },
    { path = 'Fallbacks.ped', label = 'Fallback ped', type = 'string', maxLength = 64, apply = 'live', modelCheck = 'ped' },
})

push(A.fields, 'server', 'Schedule', {
    { path = 'Schedule.utcOffset', label = 'Server UTC offset', desc = 'Hours ahead of UTC that schedule hours are read in. Zones without their own offset follow this. No daylight saving is applied.',
      type = 'number', min = -12.0, max = 14.0, step = 0.5, unit = 'h', apply = 'live' },
    { path = 'Schedule.pollIntervalMs', label = 'Poll interval', type = 'int', min = 1000, max = 600000, step = 1000, unit = 'ms', apply = 'live', advanced = true },
    { path = 'Schedule.alwaysOpenInDebug', label = 'Always open while debug', desc = 'Only has any effect when Config.Debug is true.', type = 'bool', apply = 'live', advanced = true },
})

push(A.fields, 'server', 'Security', {
    { path = 'Validation.intervalMs', label = 'Server validation interval', desc = 'Lower is stricter but costs more. Never zero.',
      type = 'int', min = 100, max = 10000, step = 50, unit = 'ms', apply = 'live', confirm = true },
    { path = 'Validation.ejectRetries', label = 'Eject retries', type = 'int', min = 0, max = 10, step = 1, apply = 'live', advanced = true },
    { path = 'Validation.ejectRetryDelayMs', label = 'Eject retry delay', type = 'int', min = 200, max = 30000, step = 100, unit = 'ms', apply = 'live', advanced = true },
    { path = 'Validation.ejectCooldownMs', label = 'Eject notify cooldown', type = 'int', min = 500, max = 60000, step = 500, unit = 'ms', apply = 'live', advanced = true },
    { path = 'Validation.completionToleranceMs', label = 'Progress completion tolerance', desc = 'Slack allowed when a client reports a progress bar finished.',
      type = 'int', min = 0, max = 2000, step = 50, unit = 'ms', apply = 'live', confirm = true, advanced = true },
    { path = 'Validation.rateLimits', label = 'Action rate limits', type = 'ratelimits', apply = 'live', advanced = true },
})

push(A.fields, 'server', 'Logging', {
    { path = 'Logging.enabled', label = 'Logging enabled', type = 'bool', apply = 'live' },
    { path = 'Logging.useQbxLogger', label = 'Use qbx_core logger', type = 'bool', apply = 'live', advanced = true },
    { path = 'Logging.events', label = 'Event categories', type = 'boolmap', apply = 'live', advanced = true },
})

push(A.zoneTemplate, 'zones', 'Zone', {
    { suffix = 'enabled', label = 'Enabled', type = 'bool', apply = 'session', confirm = true },
    { suffix = 'label', label = 'Display label', type = 'string', maxLength = 64, apply = 'live' },
})

push(A.zoneTemplate, 'zones', 'Area', {
    { suffix = 'minZ', label = 'Floor height', type = 'number', min = -2000.0, max = 2000.0, step = 1.0, unit = 'm', apply = 'session', confirm = true },
    { suffix = 'maxZ', label = 'Ceiling height', type = 'number', min = -2000.0, max = 5000.0, step = 1.0, unit = 'm', apply = 'session', confirm = true },
})

push(A.zoneTemplate, 'zones', 'Hours', {
    { suffix = 'schedule.openHour', label = 'Open hour', type = 'int', min = 0, max = 23, step = 1, apply = 'live', confirm = true },
    { suffix = 'schedule.closeHour', label = 'Close hour', type = 'int', min = 0, max = 23, step = 1, apply = 'live', confirm = true },
    { suffix = 'schedule.utcOffset', label = 'Zone UTC offset', desc = 'Leave blank to follow the server offset.',
      type = 'number', min = -12.0, max = 14.0, step = 0.5, unit = 'h', apply = 'live', optional = true },
})

push(A.zoneTemplate, 'zones', 'Crate', {
    { suffix = 'crate.coords', label = 'Crate position', type = 'vec4', apply = 'live', placement = 'prop' },
    { suffix = 'crate.prop', label = 'Crate prop', type = 'string', maxLength = 64, apply = 'live', modelCheck = 'prop' },
    { suffix = 'crate.spawnInterval', label = 'Spawn interval', type = 'int', min = 10, max = 7200, step = 10, unit = 's', apply = 'live', confirm = true },
    { suffix = 'crate.interactionDistance', label = 'Interaction distance', type = 'number', min = 0.5, max = 25.0, step = 0.5, unit = 'm', apply = 'live' },
    { suffix = 'crate.lootDuration', label = 'Loot duration', type = 'int', min = 500, max = 60000, step = 500, unit = 'ms', apply = 'live' },
    { suffix = 'crate.rewardItem', label = 'Reward item', type = 'string', maxLength = 64, apply = 'live', itemCheck = true },
    { suffix = 'crate.rewardAmount', label = 'Reward amount', type = 'int', min = 1, max = 100, step = 1, apply = 'live' },
})

push(A.zoneTemplate, 'zones', 'Seller', {
    { suffix = 'seller.coords', label = 'Seller position', type = 'vec4', apply = 'live', placement = 'ped' },
    { suffix = 'seller.model', label = 'Seller ped', type = 'string', maxLength = 64, apply = 'live', modelCheck = 'ped' },
    { suffix = 'seller.scenario', label = 'Scenario', type = 'string', maxLength = 64, apply = 'live' },
    { suffix = 'seller.interactionDistance', label = 'Interaction distance', type = 'number', min = 0.5, max = 25.0, step = 0.5, unit = 'm', apply = 'live' },
})

push(A.zoneTemplate, 'zones', 'Map blip', {
    { suffix = 'blip.enabled', label = 'Blip enabled', type = 'bool', apply = 'live' },
    { suffix = 'blip.showWhenClosed', label = 'Show while closed', type = 'bool', apply = 'live' },
    { suffix = 'blip.style', label = 'Blip style', desc = 'Filled shades the traced shape with a border. Outline draws the border only. Circle is a clean disc reaching the furthest corner: tidier, but not the exact shape.', type = 'select', options = { 'filled', 'outline', 'circle' }, apply = 'live' },
    { suffix = 'blip.color', label = 'Blip colour', type = 'int', min = 0, max = 85, step = 1, apply = 'live' },
    { suffix = 'blip.alpha', label = 'Blip alpha', type = 'int', min = 0, max = 255, step = 5, apply = 'live' },
    { suffix = 'blip.outlineWidth', label = 'Outline width', desc = 'Thickness of the border traced along each edge of the zone.',
      type = 'number', min = 1.0, max = 25.0, step = 0.5, unit = 'm', apply = 'live', advanced = true },
    { suffix = 'blip.detail', label = 'Fill detail', desc = 'Widest step allowed along a slanted edge, in metres. Keep it near the outline width so the border hides the steps. The inside of the zone is always one solid piece.',
      type = 'number', min = 2.0, max = 40.0, step = 0.5, unit = 'm', apply = 'live', advanced = true },
    { suffix = 'blip.maxParts', label = 'Fill blip budget', desc = 'Ceiling on the blips one zone fill may use. The step coarsens until the shape fits.',
      type = 'int', min = 8, max = 200, step = 1, apply = 'live', advanced = true },
    { suffix = 'blip.centerSprite', label = 'Centre sprite', type = 'int', min = 1, max = 826, step = 1, apply = 'live', advanced = true },
    { suffix = 'blip.centerColor', label = 'Centre colour', type = 'int', min = 0, max = 85, step = 1, apply = 'live', advanced = true },
    { suffix = 'blip.centerScale', label = 'Centre scale', type = 'number', min = 0.1, max = 3.0, step = 0.05, apply = 'live', advanced = true },
    { suffix = 'blip.centerLabel', label = 'Centre label', type = 'string', maxLength = 64, apply = 'live', advanced = true },
})

push(A.zoneTemplate, 'zones', 'Boundary', {
    { suffix = 'boundary.ejectPadding', label = 'Eject padding', type = 'number', min = 0.5, max = 50.0, step = 0.5, unit = 'm', apply = 'live' },
    { suffix = 'boundary.serverValidationInterval', label = 'Zone validation interval', type = 'int', min = 100, max = 10000, step = 50, unit = 'ms', apply = 'live' },
    { suffix = 'boundary.drawMarker', label = 'Draw edge marker', type = 'bool', apply = 'live' },
    { suffix = 'boundary.debugPoly', label = 'Draw zone wireframe', type = 'bool', apply = 'live' },
}, true)

push(A.zoneTemplate, 'zones', 'Crate blip', {
    { suffix = 'crate.blipEnabled', label = 'Crate blip', type = 'bool', apply = 'live' },
    { suffix = 'crate.blipSprite', label = 'Blip sprite', type = 'int', min = 1, max = 826, step = 1, apply = 'live' },
    { suffix = 'crate.blipColor', label = 'Blip colour', type = 'int', min = 0, max = 85, step = 1, apply = 'live' },
    { suffix = 'crate.blipScale', label = 'Blip scale', type = 'number', min = 0.1, max = 3.0, step = 0.05, apply = 'live' },
}, true)

A.stationTemplate = {
    { suffix = 'propCoords', label = 'Prop position', type = 'vec4', apply = 'live', placement = 'prop' },
    { suffix = 'prop', label = 'Prop model', type = 'string', maxLength = 64, apply = 'live', modelCheck = 'prop' },
    { suffix = 'useExistingProp', label = 'Use existing world prop', desc = 'On for map geometry (nothing is spawned). Off to spawn and manage our own prop.', type = 'bool', apply = 'live' },
    { suffix = 'playerSpawn', label = 'Rebooted player spawn', desc = 'Must be clear of the prop footprint.', type = 'vec4', apply = 'live', placement = 'coords' },
    { suffix = 'interactionDistance', label = 'Interaction distance', desc = 'Measured to the prop ORIGIN server-side. Size it to the prop, and keep Reboot.maxDistance above it.',
      type = 'number', min = 0.5, max = 40.0, step = 0.5, unit = 'm', apply = 'live' },
}

A.gatedFields = {
    {
        gate = 'allowLiveDebugToggle',
        field = { section = 'server', group = 'Danger zone', path = 'Debug', label = 'Debug mode',
                  desc = 'DANGER: also forces every zone open 24/7 and registers test commands. Never leave on in production.',
                  type = 'bool', apply = 'restart', confirm = true, danger = true },
    },
}

local index

local function instantiate(tpl, path, zoneId)
    local copy = {}
    for k, v in pairs(tpl) do copy[k] = v end
    copy.path, copy.zoneId, copy.suffix = path, zoneId, nil
    return copy
end

function A.BuildFields(config)
    local out = {}

    for i = 1, #A.fields do
        out[#out + 1] = A.fields[i]
    end

    for i = 1, #A.gatedFields do
        local entry = A.gatedFields[i]
        if Config.AdminMenu and Config.AdminMenu[entry.gate] == true then
            out[#out + 1] = entry.field
        end
    end

    for zoneId, zone in pairs(config.Zones or {}) do
        for i = 1, #A.zoneTemplate do
            local tpl = A.zoneTemplate[i]
            out[#out + 1] = instantiate(tpl, ('Zones.%s.%s'):format(zoneId, tpl.suffix), zoneId)
        end

        for idx = 1, #(zone.rebootStations or {}) do
            for i = 1, #A.stationTemplate do
                local tpl = A.stationTemplate[i]
                local copy = instantiate(tpl, ('Zones.%s.rebootStations.%d.%s'):format(zoneId, idx, tpl.suffix), zoneId)
                copy.section = 'zones'
                copy.group = ('%s — station %d'):format(zoneId, idx)
                copy.stationIndex = idx
                out[#out + 1] = copy
            end
        end
    end

    return out
end

function A.Reindex(config)
    index = {}
    local fields = A.BuildFields(config)
    for i = 1, #fields do
        index[fields[i].path] = fields[i]
    end
end

function A.GetField(path)
    if not index then A.Reindex(Config) end
    return index[path]
end

function A.AllFields()
    if not index then A.Reindex(Config) end
    return index
end

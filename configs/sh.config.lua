--[[
    pr — REDZONE

    Durations are MILLISECONDS unless the name ends in Seconds / Minutes / Hour.
    Distances are metres. Models are plain strings; the resource hashes them itself.

    This file holds what a server owner actually changes. Advanced tuning — animation
    dictionaries, rate limits, watchdog grace, blip cosmetics — is filled in by the
    resource's own defaults. To change any of it, copy the key into the matching table
    below; what you write here always wins, and every one of those values is also
    editable live from /redzonemenu.

    To capture coordinates: set Config.Debug = true, stand where you want something,
    run /redzone_here and paste what it prints. A slightly wrong Z self-corrects.
]]

if not Config then Config = {} end

-- ====== GLOBAL =============================================================

--- 'auto' | 'qbx' | 'qb' | 'esx' | 'standalone'. Set explicitly only if auto guesses wrong.
--- 'standalone' means THIS resource needs no framework; ox_inventory still needs one of its
--- own, so in practice that is an ox_core or ND_Core server.
Config.Framework = 'auto'

--- 'auto' | 'ox' | 'qb' | 'esx'. Loot bags need ox_inventory; teammate DNA needs per-item
--- metadata (ox or qb). The resource prints what it can and cannot do at boot.
Config.Inventory = 'auto'

--- Verbose console output, admin debug commands, and every zone held open 24/7 instead of
--- following its schedule. MUST be false in production.
Config.Debug = false

--- Ace required for the debug commands, which are registered only while Debug is true.
--- Grant with:  add_ace group.admin pr_redzone.admin allow
Config.AdminAce = 'pr_redzone.admin'

--- ESX only: ESX has no gangs, so a job IS the gang. Jobs listed here are not gangs and
--- their holders count as Solo. Ignored on Qbox/QBCore/standalone.
Config.Gangs = { notGangs = { 'unemployed' } }

--- Real-time configuration menu. ACCESS IS BY DISCORD ID ONLY — not ace, not god, not a
--- job. The server reads the real `discord:` identifier, so a client is never asked who it
--- is, and the player needs Discord linked to FiveM.
Config.AdminMenu = {
    enabled = true,
    command = 'redzonemenu',

    --- LEAVE EMPTY. This is a SHARED file, so anything here is downloaded by every client.
    --- The real list lives in configs/s.secrets.lua, which is server-only.
    allowedDiscordIds = {},
}

Config.Logging = {
    enabled = true,

    --- !! THE URL ITSELF LIVES IN configs/s.secrets.lua, NOT HERE. !!
    --- A webhook written here is shipped to every client, and anyone holding it can post to
    --- your channel or delete the hook. Leave as '' to disable Discord logging.
    webhook = '',
}

Config.Hud = {
    enabled = true,
    --- 'bottom-right' 'bottom-left' 'bottom-center' 'top-right' 'top-left' 'top-center'
    position = 'bottom-right',
    scale = 1.0,
}

-- ====== ITEMS & REWARDS ====================================================
-- Every name here must exist in your inventory's item list — ox_inventory/data/items.lua, or
-- qb-core/shared/items.lua on qb-inventory. The materials ship with ox_inventory already; the
-- rest are added by this resource, see install/items.md.

Config.Items = {
    --- Fallback only: each zone names its own package and that one wins.
    package = 'hippy_meth_box',

    --- Unique, non-stackable proof of an elimination. Required to reboot a teammate.
    teammateDna = 'teammate_dna',

    keycard = 'vangelico_keycard',
}

Config.Rewards = {
    --- Guaranteed materials per package sold. Add or remove freely.
    materials = {
        { item = 'metalscrap', amount = 50 },
        { item = 'copper',     amount = 50 },
        { item = 'aluminum',   amount = 50 },
        { item = 'steel',      amount = 50 },
    },

    --- Independent chance (0-100) of also receiving Config.Items.keycard. Rolled
    --- server-side, once per package sold.
    keycardChancePercent = 8,
    keycardAmount = 1,
}

-- ====== KNOCK / REVIVE / REBOOT ============================================

Config.Knock = {
    --- How long a downed player has before elimination. Server-timed.
    durationMs = 30000,

    --- Health the player is pinned to while downed, and the incoming-damage threshold that
    --- triggers the downed state. Both stay above 0 so the ped never reaches GTA's death
    --- state and never hands control to the medical resource's last stand.
    downedHealth = 125,
    lethalThreshold = 135,

    --- Crawl speed. 1.0 is a normal walk; below ~0.4 reads as "stuck" rather than "slow".
    crawlSpeed = 0.5,

    --- True makes a downed player immune, guaranteeing the full timer. False lets enemies
    --- finish them off.
    immuneWhileDowned = false,
}

Config.Revive = {
    --- Deliberately long: real CPR is not a five-second job and the minigame needs beats.
    durationMs = 15000,
    revivedHealth = 150,

    --- Reviver and target must stay this close for the whole progress bar.
    maxDistance = 3.0,

    --- A ring closes on the target and you press SPACE as it lands. The server computes the
    --- beat count itself, so a client cannot inflate its own accuracy. Failing resumes the
    --- casualty's bleed-out from where it paused.
    minigame = {
        enabled = true,
        bpm = 110,                -- 100-120 is the real clinical range
        hitWindowMs = 170,        -- tolerance either side of the beat; below ~90 is punishing
        requiredAccuracy = 0.6,   -- fraction of beats that must land, 0.0-1.0
    },
}

Config.Reboot = {
    durationMs = 10000,
    rebootedHealth = 175,

    --- The actor must stay this close to the station throughout. MUST be larger than the
    --- station's own interactionDistance — both measure to the same point, but this one is
    --- re-checked every tick, so a smaller value cancels the reboot instantly. Checked at
    --- start-up, and the server warns if you get it wrong.
    maxDistance = 8.0,
}

Config.Elimination = {
    --- DNA is taken from the CORPSE, not from a dropped prop, so respawning forfeits it.
    acquireDistance = 2.5,

    --- Ceiling on how long you lie dead before an automatic respawn; you can always hold E
    --- to go sooner. Long enough for a teammate to reach the body and get to a station.
    --- Qbox only — elsewhere the death resource's own timer applies.
    autoRespawnSeconds = 600,

    --- An unclaimed elimination record expires after this long, matching the DNA item's own
    --- decay so a sample never outlives the record behind it. 0 disables expiry.
    expiryMinutes = 30,
}

Config.Cooldown = {
    --- Zone lockout after being eliminated and respawning.
    minutes = 30,
    command = 'cooldown', -- players check their own remaining lockout with this

    --- Disconnecting inside an open zone earns the same lockout as dying, so quitting costs
    --- what losing costs. Applies to every disconnect — a rage-quit cannot be told from a
    --- crash.
    applyOnQuitInZone = true,

    --- Without this a squad could keep a locked-out member on their feet indefinitely.
    blockReviveWhileOnCooldown = true,

    --- Burn-out: a locked-out player standing in the zone loses health rather than being
    --- teleported, so there is no boundary bouncing. They are not a participant, so dying to
    --- it is an ordinary death and adds no further cooldown.
    damage = {
        enabled = true,
        amount = 20,          -- health runs 0-200, so 20 is ten seconds of standing
        intervalMs = 1000,
        ejectInstead = false, -- true reverts to teleporting them out
    },
}

-- ====== LOOT BAG ===========================================================
-- A player who leaves the fight armed drops their hotbar for someone else to take. The bag
-- is a real ox_inventory drop, so REQUIRES ox_inventory; on any other inventory loot bags
-- are disabled and eliminated players keep their items.

Config.LootBag = {
    enabled = true,
    onRespawn = true,
    onDisconnect = true,

    --- Only drop if they were carrying a weapon at all, so an unarmed player does not litter.
    requireWeapon = true,

    --- Slots counted as the hotbar. Everything in them goes in the bag, weapon or not.
    hotbarSlots = 5,

    --- Also take weapons stashed elsewhere in the inventory. Without this, fighting with a
    --- pistol while a rifle sits in slot 20 costs almost nothing. Non-weapons outside the
    --- hotbar are never touched — cash, food, medkits and the phone stay with the player.
    takeWeaponsAnywhere = true,

    despawnMinutes = 10,
}

-- ====== ACCESS =============================================================

--- Law enforcement never fights in the RedZone. Blocked players are ejected like any other
--- ineligible player, never dropped. Checked before gang and squad eligibility, so a cop
--- who also holds a gang is still refused.
Config.BlockedJobs = {
    enabled = true,

    --- By job TYPE — 'leo' covers police, bcso and sasp at once. Add 'ems' to keep the
    --- ambulance service out too. ESX has no job types; use `names` there.
    types = { 'leo' },

    --- By exact job name, for jobs with no type set.
    names = {},

    --- True means a blocked job only counts while clocked on, which allows the obvious
    --- "clock off at the gate" bypass.
    onlyWhenOnDuty = false,
}

--- Players with no gang fight as their own combat group.
Config.SoloSquads = {
    enabled = true,

    --- Solo players must create or join a squad before entering. A squad of one is valid,
    --- so lone-wolf play is still possible.
    requireSquadForEntry = true,

    --- Hard cap including the leader.
    maxMembers = 15,

    --- Freeze the roster for the rest of the session once the first member enters. This is
    --- what stops squads swapping in fresh players mid-fight.
    lockRosterAfterFirstEntry = true,

    --- Optional profanity list for squad names. Case-insensitive, substring matched.
    name = { blockedWords = {} },
}

-- ====== SCHEDULE ===========================================================

Config.Schedule = {
    --- Hours ahead of UTC that every zone's opening and closing hours are read in.
    --- Whole or fractional: 5.5 for India, -3.5 for Newfoundland, 0 for UTC.
    ---
    --- No daylight saving is applied. If your region observes it, change this by 1 when the
    --- clocks change — deliberately, rather than trusting a rule set that would be wrong for
    --- most of the world. A zone can override this with its own offset in the creator.
    utcOffset = 0,
}

-- ====== ZONES ==============================================================
-- Zones are drawn IN-GAME, not written here. Open /redzonemenu and use the Zones tab, or go
-- straight to the editor with /redzonecreate, fly the freecam around the area and drop the
-- points that make its shape. What you draw is saved to the database, survives restarts and
-- syncs to every player without a restart.
--
-- A zone is a POLYGON: an ordered ring of at least 3 points, plus a floor and ceiling height.
-- Its centre and radius are worked out from the shape itself, every time the config loads.
--
-- Everything below is ONE EXAMPLE zone, kept so a fresh install has something to fight over
-- before anyone has drawn anything. Delete it once you have made your own; nothing else in
-- the resource refers to it. Every subsystem — crate timer, seller, stations, records,
-- cooldowns — is keyed per zone id, so several zones can run at once.

Config.Zones = {
    main = {
        enabled = true,
        label   = 'MethZone',

        --- Opens at openHour:00 and closes at closeHour:00. Open > close crosses midnight.
        schedule = { openHour = 20, closeHour = 6 },

        --- The ring, in order. The closing edge from the last point back to the first is
        --- implicit — never repeat the first point at the end.
        points = {
            vec3(2515.3173, 2636.6076, 46.6539),
            vec3(2417.9020, 2734.0229, 46.6539),
            vec3(2280.1360, 2734.0229, 46.6539),
            vec3(2182.7207, 2636.6076, 46.6539),
            vec3(2182.7207, 2498.8416, 46.6539),
            vec3(2280.1360, 2401.4263, 46.6539),
            vec3(2417.9020, 2401.4263, 46.6539),
            vec3(2515.3173, 2498.8416, 46.6539),
        },

        --- The vertical band. Left unset, a zone reaches 100m below its lowest point and
        --- 500m above its highest, which is loose enough that aircraft overhead still count
        --- as inside. Tighten it deliberately, not by accident.
        minZ = -53.0,
        maxZ = 547.0,

        --- The map blip traces the polygon you drew — no circle, no approximation.
        ---   style   'filled' shades the whole area, 'outline' draws the edges only.
        ---   detail  metres per fill step. Lower is smoother and costs more blips; the shape
        ---           is always exact wherever an edge runs straight north-south.
        blip = {
            style = 'filled',
            color = 1,   -- blip colour index; 1 is red
            alpha = 80,  -- 0-255
        },

        --- The item this zone's crate gives and its seller buys. They are the same thing on
        --- purpose: change the crate reward and the seller follows it.
        package = 'hippy_meth_box',

        crate = {
            coords = vec4(2348.9478, 2567.7144, 46.6524, 343.1064),

            --- Seconds of UNCONTESTED control required before a crate spawns. Only counts
            --- down while exactly one combat group holds the zone.
            spawnInterval = 180,
            lootDuration = 5000,
        },

        seller = { coords = vec4(2324.6887, 2517.0310, 46.6677, 77.0554) },

        rebootStations = { {
            --- useExistingProp attaches to map geometry already in the world instead of
            --- spawning a copy, which would clip through the original.
            propCoords = vec4(2328.6340, 2570.5862, 46.5677, 56.2384),
            useExistingProp = true,

            --- Where the rebooted teammate is placed. MUST be clear of the prop's footprint
            --- or they spawn inside it.
            playerSpawn = vec4(2328.1997, 2571.9749, 46.6766, 242.8819),

            --- Size this to the PROP, not to arm's reach: the server measures to the prop's
            --- origin, which for a large model sits in its middle. A crate needs ~4, an 11 m
            --- bus needs ~8. Too small and it is unreachable.
            interactionDistance = 4.0,
        } },
    },
}

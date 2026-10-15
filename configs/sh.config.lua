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

--- 'auto' | 'ox' | 'qb' | 'esx'. Loot bags need ox_inventory. The resource prints what it
--- can and cannot do at boot.
Config.Inventory = 'auto'

--- Verbose console output, admin debug commands, and every zone held open 24/7 instead of
--- following its schedule. MUST be false in production.
Config.Debug = false

--- Ace required for the debug commands, which are registered only while Debug is true.
--- Grant with:  add_ace group.admin pr_redzone.admin allow
Config.AdminAce = 'pr_redzone.admin'

--- Who the RedZone is for, and where their gang is read from.
Config.Gangs = {
    --- 'auto' finds your gang system by itself every time the resource starts: it looks
    --- through the running resources for a gang script that answers a player-gang export
    --- (rcore_gangs, brutal_gangs, op-crime and the like) and reads gangs from it. The
    --- framework's own gangs (Qbox/QBCore PlayerData.gang, ESX job2 then job) are always
    --- the fallback. The console says at start-up which one it picked.
    --- Put a resource name here to force it, or 'framework' to ignore gang scripts.
    resource = 'auto',

    --- Only for a forced resource whose export the auto-probe does not recognise, e.g.
    --- 'GetPlayerGang'. It is called with the player's server id, then their citizen id.
    export = nil,

    --- true: a player with no gang is a regular citizen. The RedZone is hidden from their
    --- map and they are pushed out if they walk in. false: no gang plays as Solo, as before.
    requireGang = true,

    --- Players in these gangs fight as Solo Squads, and they are the only ones who can open
    --- /rzsquad. Matched against the gang's name or label, ignoring case.
    soloGangs = { 'solo' },

    --- These count as having no gang at all. On ESX (no gangs, so a job is the gang) list
    --- every job that is not a gang here.
    notGangs = { 'none', 'unemployed', 'unemployed2' },
}

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

Config.Cooldown = {
    --- Zone lockout after dying in the zone and respawning. A player picked back up where
    --- they fell (EMS, a medkit) is still in the fight and gets no lockout.
    minutes = 30,
    command = 'cooldown', -- players check their own remaining lockout with this

    --- Disconnecting inside an open zone earns the same lockout as dying, so quitting costs
    --- what losing costs. Applies to every disconnect — a rage-quit cannot be told from a
    --- crash.
    applyOnQuitInZone = true,

    --- A locked-out player revived inside the zone by another script is put back down.
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

    --- Leaving mid-fight is judged from how the game left. Quitting (F8 quit, Alt+F4, closing
    --- the game) and faking a crash (typing a crash message into F8 quit, killing the game in
    --- Task Manager, pulling the network) drop the bag and earn the lockout. A real game crash,
    --- which FiveM reports itself, keeps both. Server kicks and restarts never count.
    crashCheck = {
        enabled = true,          -- false: every disconnect mid-fight counts, crash or not
        punishTimeouts = true,   -- game killed / network pulled: no crash report was sent
        punishFreezes = false,   -- the game froze and stopped answering (OneSync 60s timeout)

        --- A cheat client can forge a crash report, so only this many real-looking crashes
        --- in a fight are forgiven per player in the window; after that they count.
        crashAllowance = 2,
        crashWindowHours = 24,
    },
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
-- the resource refers to it. Every subsystem — crate timer, seller, loot bags, cooldowns —
-- is keyed per zone id, so several zones can run at once.

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

        --- The map blip traces the polygon you drew. Only players who can enter (gang
        --- members, the solo gang) and RedZone admins see it.
        ---   style   'filled' shades the shape with a crisp border, 'outline' draws the border
        ---           only, 'circle' is a tidy disc reaching the furthest corner (not exact).
        ---   detail  widest step along a slanted edge, in metres. The inside of the zone is
        ---           always one solid piece; only the slanted borders are stepped, and the
        ---           border line drawn over them hides the steps.
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
    },
}

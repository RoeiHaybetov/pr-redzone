# pr — REDZONE

A scheduled, server-authoritative gang war zone. Draw the battlefield in-game as a polygon,
open it on a timer, and let gangs fight over a loot crate they have to hold ground to earn.

**Version 2.0.0** — restructured, condensed, and rebuilt on `@pr/ui`.

---

## What it does

- **Polygon zones, drawn in-game.** Fly a free-cam around the area, drop a point at each
  corner, and that shape *is* the zone — membership, ejection, walls and the map blip all
  follow the ring you drew. No coordinates to type, no radius to guess.
- **A schedule.** Each zone opens and closes on its own hours, in its own timezone.
- **Custom knock and revive.** Taking lethal damage inside the zone puts you on the ground
  crawling with a server-timed bleed-out instead of killing you. A teammate picks you up with
  a CPR rhythm minigame the server scores.
- **Elimination and reboot.** Run out of time and you are out — unless a teammate takes DNA
  from your corpse and carries it to a reboot station inside the zone.
- **A contested crate.** It only counts down while exactly one combat group holds the zone.
  Loot it, carry the package to a hidden seller, get paid in materials and a chance at a
  keycard.
- **Loot bags.** Leave the fight armed — respawn, F8 quit, a faked crash — and your hotbar
  (slots 1-5) plus every gun you carry drops as a real `ox_inventory` bag for whoever finds it.
  A genuine game crash keeps your items.
- **A lockout.** Dying and respawning locks you out of every zone for a while. Standing in
  one anyway burns your health rather than teleporting you around the boundary.
- **Gang members only.** A regular citizen with no gang never sees the RedZone on the map and
  is pushed out if they walk in. The gang system is found automatically at start-up.
- **Solo Squads.** Players in the solo gang (`solo` by default) form a squad and fight as one
  combat group. The roster freezes once the first member walks in, so nobody swaps in fresh
  players mid-fight.
- **Police are blocked**, by job type or exact name, checked before anything else.
- **A live admin menu** — `/redzonemenu` — that edits every setting, draws new zones, and
  publishes without a restart.

---

## Requirements

Hard requirements, declared in `fxmanifest.lua`:

| | |
|---|---|
| `ox_lib` | 3.39.0+ |
| `oxmysql` | 2.14.1+ |
| `ox_inventory` | 2.41.0 (pinned — 2.42.0 dropped the qb bridge) |

Everything else is resolved **at runtime**, from the started resource list, so naming a
resource you do not have can never stop this one from starting:

| role | detected |
|---|---|
| framework | `qbx_core` · `qb-core` · ESX · standalone |
| gangs | any gang resource with a player-gang export (rcore_gangs, brutal_gangs, op-crime…), else the framework's own gangs |
| targeting | `ox_target` · `qb-target` |
| death | `qbx_medical` · `qb-ambulancejob` |

Each adapter prints a clear line at boot saying what it found and what it therefore cannot
do. On any inventory other than `ox_inventory`, loot bags switch themselves off and
eliminated players keep their items.

---

## Install

**1. Copy the folder** to `resources/[custom]/pr-redzone`.

**2. Import the database.** Run `sql/install.sql`. It creates nine tables, all
`CREATE TABLE IF NOT EXISTS`, so it is safe to re-run.

> Upgrading from the old resource name? The top of `install.sql` carries a commented-out
> `RENAME TABLE` block for the three `aba_redzone_*` tables. Run it **before** the file's
> `CREATE` statements to keep your saved configuration, history and audit log.

**3. Add the items.** See `install/items.md` — it lists exactly what to paste into
`ox_inventory/data/items.lua` (or `qb-core/shared/items.lua`). `teammate_dna` **must** be
unique and non-stackable, or two eliminations collapse into one item.

**4. `server.cfg`.** Start it after your framework, `ox_lib`, `oxmysql`, `ox_inventory` and
your targeting resource:

```cfg
ensure pr-redzone
```

**5. Optional ace**, only needed if you turn on debug:

```cfg
add_ace group.admin pr_redzone.admin allow
```

**6. Grant yourself the menu.** Put your raw Discord ID in
`configs/s.secrets.lua` → `Config.AdminMenu.allowedDiscordIds`. Access is by Discord ID and
**nothing else** — not ace, not god, not a job. Then `/redzonemenu` in game.

**7. Draw a zone.** `/redzonecreate`, or the Zones tab of the menu. The example zone that
ships in `configs/sh.config.lua` exists only so a fresh install has something to fight over;
delete it once you have your own.

---

## Configuration

Two files, and only two:

- **`configs/sh.config.lua`** — everything a server owner changes, documented inline. This is
  the manual.
- **`configs/s.secrets.lua`** — the Discord webhook and the admin whitelist. Server-only, so
  neither is ever sent to a client.

> Anything in `sh.config.lua` is downloaded by every player who connects. Never put a webhook
> or a whitelist there. A Discord webhook URL is a bearer credential — whoever holds it can
> post to your channel or delete the hook.

Advanced tuning — animation dictionaries, rate limits, watchdog grace, blip cosmetics — is
filled in by the resource's own defaults and does not clutter the config. Every one of those
values is still editable live from `/redzonemenu`, and anything you write in `sh.config.lua`
always wins.

---

## The admin menu — `/redzonemenu`

Six tabs.

| tab | what lives there |
|---|---|
| **Overview** | live zone state, the player inspector, health checks, maintenance actions, the Discord webhook |
| **Zones** | one card per zone — shape, hours, crate, seller, reboot stations, map blip — plus force open/close, crate controls, and the creation wizard |
| **Combat** | knock, revive, CPR, reboot, elimination, cooldown, loot bags |
| **Economy** | items and the seller payout |
| **Players** | Solo Squads and blocked jobs |
| **Server** | HUD, schedule, security, logging, history and rollback, import/export |

A zone is edited as **one thing**. Everything about it — including its own hours, blip and
boundary — sits inside that zone's card, not scattered across five menus.

Settings an operator does not touch on a normal day are marked advanced and fold into a
single **Advanced** row per section. The search box ignores the fold, so if you know a
setting's name you can always type it.

### Draft → validate → publish

Nothing you change is live until you publish. On publish the server validates every value
against the schema, shows you a diff, and tells you whether the change applies immediately,
at the next session, or needs a restart. Zone geometry changes always offer "next session",
because reshaping a zone moves the ground under anyone standing in it.

Every revision is stored. **History & rollback** loads an old one back as a draft — settings
*and* zone geometry — so you can review it before putting it live.

### Security

- Access is re-derived from the real `discord:` identifier on **every** call. There is no
  cached "is admin" flag and no client-supplied identity.
- A setting is editable **only** if it appears in the schema allowlist. There is no generic
  path writer, no table introspection, no wildcard — so a crafted NUI payload cannot reach
  the webhook or the whitelist.
- Bounds (min, max, length, item count) are enforced server-side, not in the browser.
- Every action is audited with the Discord ID that performed it.
- The webhook is never sent to the browser. You can replace or clear it, never read it.

---

## Zones

A zone is an ordered ring of at least 3 points plus a floor and a ceiling. Its centre and
radius are derived from the shape on every load, so they can never drift away from it.

**The map blip traces the polygon you drew.** Filled by default: the inside is one solid
piece per band and only the slanted edges are stepped, under a crisp near-opaque border, so
there are no stripes across the zone. `blip.style = 'outline'` draws the border only, and
`'circle'` draws a tidy disc reaching the furthest corner (cleaner, not exact). `blip.detail`
is the widest step allowed along a slanted edge; `blip.maxParts` caps how many blips one zone
may use.

**In debug, every zone is held open 24/7** and nothing else changes — the same eligibility,
the same crate timer, the same lockouts.

**Deleting or adding a zone** applies the moment you publish: anyone inside a deleted zone is
released, and its crate, loot bags, overrides and session end. Only **reshaping** an existing
zone offers to wait for the next session, because it moves the ground under the players
standing in it — and "Apply now" is always there too.

**Who sees a zone.** Only players who can enter it — gang members, the solo gang while Solo
Squads are on — and whitelisted RedZone admins see its blip. Everyone else is pushed out.

---

## Gangs

`Config.Gangs` in `configs/sh.config.lua` decides who the RedZone is for.

- **`resource = 'auto'`** (default) — at every start the resource looks through the running
  resources for a gang script that answers a player-gang export (`GetPlayerGang`,
  `getPlayerOrganisation` and friends), calling it with the server id and then the citizen id.
  The framework's own gangs (Qbox/QBCore `PlayerData.gang`, ESX `job2` then `job`) are always
  the fallback. The console prints which source it picked, and Overview → Health checks shows
  it too. Name a resource to force it, or `'framework'` to ignore gang scripts.
- **`requireGang = true`** — no gang means regular citizen: no blip, pushed out on entry.
- **`soloGangs = { 'solo' }`** — members of these gangs fight as Solo Squads and are the only
  players who can open `/rzsquad`.
- **`notGangs`** — names that count as no gang at all.

All three access settings are also editable live under Players → Gang access.

## Commands

**Players**

| command | |
|---|---|
| `/cooldown` | how long your lockout has left (name configurable) |
| `/rzsquad` | open the Solo Squad panel (solo gang only) |

**Administration** (Discord whitelist)

| command | |
|---|---|
| `/redzonemenu` | open the menu (name configurable) |
| `/redzonecreate` | jump straight to the zone creator |
| `/redzone menu` / `/redzone create` | alias, if enabled |

**Debug** — registered only while `Config.Debug = true`, and gated on `pr_redzone.admin`:

`/redzone_here` · `/redzone_status` · `/redzone_timetest` · `/redzone_testbag` ·
`/redzone_clearcooldown` · `/redzone_testmodel` · `/redzone_testanim` ·
`/redzone_findcrawl` · `/redzone_testclip`

---

## Layout

```
pr-redzone/
├─ fxmanifest.lua
├─ configs/          sh.config.lua · s.secrets.lua
├─ escrowed/
│  ├─ sh.*.lua       shared: util · defaults · const · schema
│  ├─ client/        c.util · c.main · c.world · c.combat · c.squad · c.admin
│  └─ server/        s.util · s.lib.* · s.main · s.events
├─ locales/          en.json · he.json
├─ sql/              install.sql
├─ install/          items.md
└─ ui/               src/ + dist/ (Vite + React, built on @pr/ui)
```

Rebuild the interface with `cd ui && npm install && npm run build`. The UI uses the Rajdhani
and Barlow fonts (`@fontsource/rajdhani`, `@fontsource/barlow`), bundled into `ui/dist`.

---

## How a few things work

**The knock system never lets the ped die.** A weapon hit that would take a player inside an
open zone to or below `lethalThreshold` is stopped on the server before it lands, and the
player goes down instead — so GTA never reaches its death state and the medical resource's
last stand never starts. Damage that is not a weapon hit (falls, vehicles, explosions) is
caught by the client report and a server watchdog; if the death resource grabs the player
anyway, the knock takes them back. The first second after going down absorbs every hit, so
one burst cannot knock and finish in the same instant.

**Eliminated players always come back clean.** Whether they respawn, get revived by EMS or an
admin, or their death script has no respawn hook at all, the server notices the ped is alive
again, applies the lockout, and returns them to normal — so they can be knocked again next
time.

**The CPR minigame is scored server-side.** The client reports which beats it hit; the server
computes how many beats there should have been from its own clock and refuses an inflated
claim. Failing resumes the casualty's bleed-out from exactly where it paused.

**Loot bags use `ox_inventory`'s own drop.** Not a prop with a fake inventory bolted on — a
real drop, so it works with every inventory feature your players already know.

**Combat logging versus crashing.** When a player leaves mid-fight the server reads how the
game left, using FiveM's own drop category and reason:

| how they left | what FiveM reports | result |
|---|---|---|
| F8 `quit`, Alt+F4, closing the game | `Exiting` | bag + lockout |
| F8 `quit "Game crashed: …"` (fake) | FiveM forces `Quit: Game crashed: …` | bag + lockout |
| game killed in Task Manager, network pulled | a timeout ~30s later (no crash report) | bag + lockout |
| a real game crash | FiveM's crash handler: `Game crashed: …` (any language) | keeps everything |
| kicked, server restart, game froze | server-side categories | keeps everything |

A cheat client could forge a crash report, so only `crashAllowance` (default 2) crashes in a
fight are forgiven per player per `crashWindowHours` (24); after that they count as combat
logs. All of it is under `Config.LootBag.crashCheck` and Combat → Loot bag in the menu. The
bag is taken in the very first moment of the disconnect, before `ox_inventory` unloads the
player's inventory.

**DNA is taken from the corpse, not from a dropped prop.** Respawn and you forfeit it. An
unclaimed record expires on the same clock as the item, so a sample can never outlive the
record behind it.

**Ejection is polygon-accurate.** A player outside the ring is pushed to the nearest edge
plus a padding, with a cooldown between attempts so they never bounce along the boundary.

**Combat groups.** A gang is a group. A Solo Squad is a group, keyed to the session it was
locked in. Group identity is what the crate timer counts, what teammate checks read, and what
gets written next to every elimination.

---

## Limits worth knowing

- **No daylight saving.** `utcOffset` is a fixed number of hours. If your region observes
  DST, change it by one when the clocks change — deliberately, rather than trusting a rule
  set that would be wrong for most of the world.
- **A forged crash report looks real.** A normal player cannot fake one (F8 `quit` text is
  always prefixed with `Quit: `), but a modified client can, which is what `crashAllowance`
  limits. A genuine connection drop with no crash report counts as a timeout; turn off
  `punishTimeouts` to forgive those too.
- **Loot bags need `ox_inventory`.** On anything else the feature disables itself and says so
  at boot.
- **`ox_inventory` is pinned to 2.41.0.** 2.42.0 removed the qb bridge this resource's
  inventory adapter relies on for QBCore servers.
- **GTA has no filled-polygon blip native.** The zone fill is built from area blips, so it
  steps by `blip.detail` metres wherever an edge runs diagonally. The outline on top is exact.

---

© pr

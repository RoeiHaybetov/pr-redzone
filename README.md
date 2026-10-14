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
- **Loot bags.** Leave the fight armed — respawn, disconnect, rage-quit — and your hotbar
  drops as a real `ox_inventory` bag for whoever finds it.
- **A lockout.** Dying and respawning locks you out of every zone for a while. Standing in
  one anyway burns your health rather than teleporting you around the boundary.
- **Solo Squads.** Players with no gang form a squad and fight as one combat group. The
  roster freezes once the first member walks in, so nobody swaps in fresh players mid-fight.
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

**The map blip traces the polygon you drew.** Filled by default, with a crisp outline on
every edge; set `blip.style = 'outline'` for edges only. `blip.detail` is metres per fill
step — lower is smoother and costs more blips, and the fill is exact wherever an edge runs
straight north–south. `blip.maxParts` caps how many blips one zone may use.

**In debug, every zone is held open 24/7** and nothing else changes — the same eligibility,
the same crate timer, the same lockouts.

**Deleting a zone** evacuates anyone inside it, ends its session, and prunes its crate, loot
bags and overrides. It takes effect when you publish, not when you press the button.

---

## Commands

**Players**

| command | |
|---|---|
| `/cooldown` | how long your lockout has left (name configurable) |
| `/rzsquad` | open the Solo Squad panel |

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

Rebuild the interface with `cd ui && npm install && npm run build`.

---

## How a few things work

**The knock system never lets the ped die.** Health is pinned above zero the whole time you
are down, so GTA never reaches its death state and the medical resource's last stand never
takes over. That is why `downedHealth` and `lethalThreshold` both sit well above 0 — lower
them to 0 and you hand control back to the death script.

**The CPR minigame is scored server-side.** The client reports which beats it hit; the server
computes how many beats there should have been from its own clock and refuses an inflated
claim. Failing resumes the casualty's bleed-out from exactly where it paused.

**Loot bags use `ox_inventory`'s own drop.** Not a prop with a fake inventory bolted on — a
real drop, so it works with every inventory feature your players already know.

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
- **Disconnecting is treated as quitting.** A crash cannot be told apart from a rage-quit, so
  both cost the same lockout when `applyOnQuitInZone` is on.
- **Loot bags need `ox_inventory`.** On anything else the feature disables itself and says so
  at boot.
- **`ox_inventory` is pinned to 2.41.0.** 2.42.0 removed the qb bridge this resource's
  inventory adapter relies on for QBCore servers.
- **GTA has no filled-polygon blip native.** The zone fill is built from area blips, so it
  steps by `blip.detail` metres wherever an edge runs diagonally. The outline on top is exact.

---

© pr

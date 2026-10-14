# Item definitions — `pr-redzone`

pr

This resource needs **six** items that do not ship with an inventory by default. Define them
before first start: the boot check and every admin-panel publish validate that each configured
item exists, and name the missing one in the console if it does not.

Where they go:

```
ox_inventory   resources/[ox]/ox_inventory/data/items.lua
qb-inventory   resources/[qb]/qb-core/shared/items.lua
```

`teammate_dna` is the only one with a hard requirement beyond existing: it **must be
non-stackable**, because two samples would otherwise merge into one stack and share a single
piece of metadata. That is `stack = false` on ox_inventory and `unique = true` on qb-core.

The four reward materials (`metalscrap`, `copper`, `aluminum`, `steel`) already ship with
ox_inventory and are used pr-is. Rename them in `config.lua` under `Config.Rewards.materials`
if yours differ.

Item images are not included — drop a PNG per item into your inventory's image folder. The
items work without them; the slot icon is simply blank.

The rest of this document is the reference: the definitions to copy, and why each one is
shaped the way it is.

---

## 1. Items that already exist — nothing to do

These ship with ox_inventory and are used pr-is for the seller payout — nothing to add:

| Item         | Label        |
|--------------|--------------|
| `steel`      | Steel        |
| `copper`     | Copper       |
| `aluminum`   | Aluminium    |
| `metalscrap` | Metal Scrap  |

### Note on "metal"

The reward spec asked for 50 **metal**. There is no item called `metal` in this
ox_inventory install — the closest is `metalscrap`. Rather than invent a duplicate
material, `Config.Rewards.materials` maps the metal reward onto `metalscrap`.

If you later define a distinct `metal` item, change one line in `config.lua`:

```lua
{ item = 'metalscrap', amount = 50 },   -->   { item = 'metal', amount = 50 },
```

---

## 2. Items that were added

This is the exact block that was inserted, immediately after the `['glass']` entry. Reproduced
here so you can review it, re-apply it after an ox_inventory update, or port it to another
server.

```lua
    ---------------------------------------------------------------------------
    -- pr-redzone
    ---------------------------------------------------------------------------

    ['redzone_package'] = {
        label = 'RedZone Package',
        weight = 0,
        stack = true,
        close = true,
        description = 'A sealed package recovered from a RedZone supply crate. Someone inside the zone will buy it.',
        client = {
            image = 'redzone_package.png',
        },
    },

    -- Per-location packages. The zone rotates daily between three places and each one
    -- gives it its own flavour. Mechanically IDENTICAL to redzone_package — weightless alike,
    -- same stacking, same seller, same payout — so which one a zone uses changes the name and
    -- icon, not the balance. redzone_package is the fallback for a zone that names none.
    ['hippy_meth_box'] = {
        label = 'Hippy Meth Box',
        weight = 0,
        stack = true,
        close = true,
        description = 'A crate of product lifted from the trailer park cook. Someone inside the zone will buy it.',
        client = {
            image = 'meth_tray.png',
        },
    },

    ['stolen_hay_bale'] = {
        label = 'Stolen Hay Bale',
        weight = 0,
        stack = true,
        close = true,
        description = 'A bale that walked off a farm trailer. Worth more than it looks to the right buyer.',
        client = {
            image = 'redzone_package.png',
        },
    },

    ['university_booze'] = {
        label = 'University Booze',
        weight = 0,
        stack = true,
        close = true,
        description = 'Crated spirits liberated from a campus store room. Someone inside the zone will buy it.',
        client = {
            image = 'whiskey.png',
        },
    },

    -- Unique proof of an elimination. Non-stackable so every head is its own slot and
    -- carries its own server-generated metadata.
    --
    -- Deliberately NOT useable: there is no client use-event, because reviving anyone must
    -- only ever happen through the reboot station's server-validated flow.
    ['teammate_dna'] = {
        label = 'Teammate DNA',
        weight = 200,
        -- Samples decay. ox_inventory 'degrade' is in MINUTES: the item is destroyed 30
        -- minutes after it is created, matching Config.Elimination.expiryMinutes.
        degrade = 30,
        stack = false,
        close = true,
        description = 'A genetic sample taken from a fallen teammate. Degrades in 30 minutes. Take it to a RedZone reboot station.',
        client = {
            image = 'teammate_dna.png',
        },
    },

    ['vangelico_keycard'] = {
        label = 'Vangelico Keycard',
        weight = 50,
        stack = false,
        close = true,
        description = 'A cloned Vangelico security keycard. Rarely handed out by RedZone dealers.',
        client = {
            image = 'vangelico_keycard.png',
        },
    },
```

### Why `teammate_dna` has no `useable` / use handler

Rule: no client event may grant a revive. The head does nothing when used. Its only effect
is at a reboot station, where the server:

1. resolves the serial to a concrete inventory slot with `strict` metadata matching,
2. cross-checks that serial against the `redzone_deaths` row,
3. confirms the combat group, session and zone,
4. consumes the record with a conditional `UPDATE`,
5. and only then removes the item and revives the target.

### Showing the teammate's name in the tooltip

`server/elimination.lua` writes a `description` key into the item metadata at creation time:

```lua
description = ('Recovered from %s'):format(row.char_name)
```

ox_inventory renders `metadata.description` in the item tooltip, overriding the static item
description, so each head shows whose it is. The name is written **server-side** from the
database record — it never comes from the client and cannot be edited into something else
without failing validation at the reboot station.

---

## 3. Item images

ox_inventory loads images from:

```
resources/[ox]/ox_inventory/web/images/
```

Add three PNGs, named exactly:

```
web/images/redzone_package.png
web/images/teammate_dna.png
web/images/vangelico_keycard.png
```

The three optional packages deliberately point at art ox_inventory **already ships**
(`meth_tray.png`, `redzone_package.png`, `whiskey.png`), so none of them renders a blank slot
out of the box. If you want bespoke icons, drop in `hippy_meth_box.png`, `stolen_hay_bale.png`
and `university_booze.png` and change the `image` field on each item to match.

**These are not included** — binary image files cannot be generated as part of this
implementation. Until you add them the items work perfectly; ox_inventory simply renders a
blank slot icon.

Recommended: 100×100 px, transparent PNG, to match the existing item art.

Quick placeholder if you want something visible immediately: copy any existing icon, e.g.

```
copy web\images\garbage.png       web\images\redzone_package.png
copy web\images\bandage.png      web\images\teammate_dna.png
copy web\images\gatecrack.png     web\images\vangelico_keycard.png
```

---

## 4. After editing

```
restart ox_inventory
restart pr-redzone
```

Verify with the ox_inventory admin menu or:

```
/giveitem <id> redzone_package 1
```

If an item name is missing, the resource fails **safely**: the seller refuses the sale and
logs an integration error rather than consuming the package.

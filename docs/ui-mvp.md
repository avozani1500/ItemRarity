# UI MVP — Item Rarity

## Purpose

The visual MVP presents the already-calculated tier directly in inventory and
container item names. It is visual only: it does not change item properties,
loot tables, spawn behavior, or item ModData.

## Confirmed in Build 42.20.2

- `ISToolTipInv` is the vanilla tooltip used for inventory and container items.
- It renders the native `InventoryItem:DoTooltip()` output itself and exposes
  no item-tooltip event.
- Global `ModData` is the vanilla mechanism used by the game to publish server
  data to clients; vanilla Foraging uses `ModData.getOrCreate()` plus
  `ModData.transmit()` and clients receive it through `OnInitGlobalModData`.
- Inventory-name drawing happens inside `ISInventoryPane:render()`. No safe
  narrow hook was found for replacing only the name color.

## Architecture

```text
server scanner/calculator
        -> compact ItemRarity registry
        -> ModData["ItemRarity.Registry.v1"]
        -> client registry cache
        -> O(1) ItemRarity.get(item)
        -> inventory-name color lookup
```

`RarityAPI.lua` is shared and is the public lookup surface:

```lua
local rarity = ItemRarity.get(item)
local rarity = ItemRarity.getByFullType("Base.Katana")
```

It returns presentation data including `tier` (the final visual tier),
`baseScarcityTier`, `finalRarityTier`, Utility debug metadata, `percentile`,
`tableAvailability`, `confidence`, `occurrenceCoverage`, and `poolCoverage`.
Unknown full types return `nil`; the UI shows nothing and does
not infer a tier.

## Inventory names

The client wraps only `ISInventoryPane:renderdetails()`. For the duration of
the native draw pass it replaces the color argument of eligible text draws in
the **Item** column. Everything else remains native: list construction,
selection, dragging, clipping, sorting, stack count, context actions, and
container behavior. COMMON remains vanilla. UNCOMMON, RARE, EPIC, and EXOTIC
use the centralized configured colors.

The extension protects vanilla red invalid-drop feedback, and if two distinct
types have the same displayed name with different tiers, their name remains
vanilla rather than showing an ambiguous color.

This covers both player inventory and opened container inventory because both
use `ISInventoryPane`.

## Tooltip

The client wraps one vanilla method, `ISToolTipInv:render()`. It first calls
the untouched vanilla renderer, then appends a small matching panel containing
`Rarity: <tier>` in the configured tier color. The border and footer are
separate client-side options, both enabled by default. This covers player
inventory and opened containers. Hotbar tooltips intentionally use a border
only: Build 42 can measure a hotbar weapon tooltip before all native lines are
drawn, so adding a footer there could overlap vanilla text.

The footer is idempotent: repeated renders of the same tooltip do not
accumulate height. There is no replacement of `InventoryItem:DoTooltip()` and
no duplicate loot scan on the client. `debugTooltip` remains a
development-only setting and defaults to `false`.

## Colors and localization

Colors, canonical labels, and translation keys reside only in
`RarityConfig.visuals`; UI consumers do not maintain color tables of their
own. COMMON is near vanilla; UNCOMMON, RARE, EPIC, and EXOTIC progress through
green, blue, purple, and gold. User-visible labels and options are translated
through B42 JSON resources for English and Brazilian Portuguese.

## Inventory name color

Implemented through a narrow draw-time color adapter, not by replacing the
large `ISInventoryPane` implementation. Clean UI 42.19+ itself replaces the
inventory class, so this mod also checks and patches its public active class at
game start. That compatibility path needs runtime validation with Clean UI
enabled.

## Performance

The scanner still runs once after `OnPostDistributionMerge`, server-side. The
UI only performs a hash-table lookup by `fullType` plus a few text draws. It
does not recalculate Strategy D, tiers, or coverage. The compact registry has
one entry per classified type (currently 3,416); exact serialized network size
is intentionally left for multiplayer validation rather than guessed.

## Multiplayer status

Singleplayer is the tested target for this MVP. The implementation uses the
vanilla global-ModData replication path, so a connected client with the mod can
receive the server-built registry when both sides load the mod. Dedicated
server/network timing, mod-version mismatches, transfer size, and rescan
updates have not yet been validated and therefore remain pending work. Clients
must not independently compute a registry, otherwise their enabled loot mods
could diverge from the server.

## Manual test

1. Enable Item Rarity and start a new or existing singleplayer world.
2. Wait until the log says `Registry ready: 3416 items.` (the number depends on
   active loot mods).
3. In Debug mode, use the Item List to add the listed items to your inventory;
   use an opened container as a second target.
4. Verify names in both the player inventory and an opened container: COMMON
   remains vanilla; UNCOMMON is green; RARE blue; EPIC purple; EXOTIC gold.
5. Test `Base.Money`, `Base.Screwdriver`, and `Base.Axe` (COMMON);
   `Base.Sledgehammer` and `Base.Katana` (RARE);
   `Base.HollowBook_Handgun` (EXOTIC); and the LB/LK/LTW items from the tier
   report. Verify the same name colors in player inventory and container loot.
6. In **Options > Mods > Item Rarity**, toggle each visual option. The change
   applies to client presentation only and must not trigger a loot rescan.
7. To inspect diagnostics, set `ItemRarityConfig.debugTooltip = true`, restart
   the world, and restore it to `false` afterwards.

## Scope limits

Strategy D, percentile thresholds, tier assignment, gameplay, Sandbox options,
and final multiplayer validation are outside this UI layer.
# Final tier UI

The server registry publishes `baseScarcityTier`, Utility debug metadata and
`finalRarityTier`. Normal name colors and the normal tooltip use the final tier
only. The client performs a `fullType -> registry` lookup; it does not run
Strategy D, Utility, ranking or percentile calculations.

With `ItemRarityConfig.debugTooltip = true`, the tooltip additionally exposes
the base tier, Scarcity percentile, Utility, Utility confidence, subgroup,
subgroup rank, parent percentile, adjustment reason and final tier.

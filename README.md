# Item Rarity

Item Rarity adds five visual tiers to Project Zomboid items:

- `COMMON`
- `UNCOMMON`
- `RARE`
- `EPIC`
- `EXOTIC`

Version `1.0.0-rc1` targets Project Zomboid Build `42.20.2`.

## How rarity is determined

The mod scans the final, already-merged loot distributions after all enabled
mods have applied their changes.  Scarcity is therefore structural: it is
derived from the loaded distribution routes and weights, rather than from a
single hardcoded vanilla table.

Where reliable runtime data exists, category-specific Utility policies provide
the primary mechanical value.  These policies are intentionally not one
generic formula: firearms, clothing, food, fish, literature, containers,
medical items, light/fire items, explosives and other supported families use
the data appropriate to their function.  Categories without enough trustworthy
runtime data retain the structural Scarcity fallback.

The published `FinalRarityTier` is calculated once by the host and consumed by
the client UI.  The UI never rescans loot tables or recalculates Scarcity or
Utility while rendering.

## Difficulty and sandbox

The scanner observes the loaded distribution definitions, before the game
rolls individual loot containers.  Difficulty presets and sandbox loot
multipliers affect generation frequency, not this structural item classification.
For an unchanged mod list and loot-table set, tiers remain stable across
Apocalypse, Survivor, Builder, and common loot-abundance sandbox settings.

## Vanilla and mods

Vanilla items and items introduced by loaded mods are scanned together.  Loot
Scarcity uses the final loaded universe.  Several Utilities use a stable
vanilla reference population so unusually strong modded items are evaluated
against that reference rather than redefining it.

## UI options

Open **Options > Mods > Item Rarity** to change client-only presentation:

- Color item names in inventory.
- Show the rarity border in item tooltips.
- Show the `Rarity` footer in item tooltips.
- Show rarity borders/markers in the hotbar.
- Keep `COMMON` inventory names in the vanilla color.

All options default to enabled. They apply to presentation only: changing an
option does not trigger a rescan and cannot change loot, a registry entry, or a
tier.

## Optional UI compatibility

Item Rarity does not require any other mod.

- **Clean UI**: inventory names and normal tooltips remain additive and use the
  published registry data.
- **Clean HotBar**: the hotbar wrapper detects replacement renderers and draws
  its rarity overlay after them. It follows Clean HotBar slot geometry,
  scale, hidden empty-slot behavior, and the show/hide reservation.

Load order is not intended to be a requirement for either compatibility path.

## Known limitations

Some families deliberately use structural Scarcity/fallback because a reliable
absolute Utility is not exposed by the current B42 runtime bridge. Examples
include weapon parts, vehicle parts, recipe-dependent tools/materials,
specialized cases, capture traps, fluid/hydration containers, several Medical
and Literature special cases, and Food items requiring preparation or recipe
context.

This is intentional: an unmeasurable effect is not guessed or hardcoded as a
value. Diagnostics remain available for development, but do not load, run, or
write files during normal gameplay.

## Release candidate status

`1.0.0-rc1` is the first release candidate. It keeps the established structural
rarity baseline and focuses on packaging, documentation, optional UI settings,
and runtime/diagnostic separation.

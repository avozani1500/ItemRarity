# Item Rarity — Workshop copy

This file is publication text only. It describes the stable 1.0.0 release and
does not define runtime behavior.

## Short description (English)

Structural COMMON, UNCOMMON, RARE, EPIC and EXOTIC tiers for Project Zomboid
Build 42.20.2. Rarity uses final loaded loot distributions and category-specific
mechanical Utility, with optional inventory, tooltip and hotbar visuals.

## Short description (PT-BR)

Tiers estruturais COMMON, UNCOMMON, RARE, EPIC e EXOTIC para Project Zomboid
Build 42.20.2. A raridade usa as distribuições finais de loot carregadas e
Utility mecânica por categoria, com visuais opcionais no inventário, tooltip e
hotbar.

## Long description

**Item Rarity** adds a clear five-tier rarity presentation to Project Zomboid:
COMMON, UNCOMMON, RARE, EPIC and EXOTIC.

It does not use a static item-name list. On the host, Item Rarity scans the
final merged loot distributions after enabled mods have applied their changes.
It combines that structural Scarcity information with category-specific
mechanical Utility where reliable runtime data exists. The resulting tier is
published once and the client UI only consumes that registry.

### Features

- Structural Scarcity from final loaded loot distributions and routes.
- Category-specific Utility for supported gameplay families, including melee
  weapons, firearms, magazines, direct ammo, clothing, containers, medical,
  food, fish, literature, maps, light/fire sources, explosives, incendiaries
  and noise makers.
- Vanilla and loaded mod items are evaluated together; compatible modded loot
  enters through the same merged distribution scan.
- Stable structural tiers across Apocalypse, Survivor, Builder and normal
  sandbox loot-abundance settings when the loaded loot-table set is unchanged.
- Inventory name colors, tooltip border, tooltip rarity footer and hotbar
  markers.
- Five client-side visual options, all enabled by default.
- Optional, load-order-resilient compatibility with Clean UI and Clean HotBar.

### Compatibility

No dependency is required.

- **Clean UI** is supported as an optional additive UI path.
- **Clean HotBar** is supported as an optional additive hotbar-overlay path.
- Existing saves and new worlds are supported. The initial scan runs after
  final distribution merge; a manual rescan is available for diagnostics.

### Known limitations

Some effects intentionally retain structural Scarcity/fallback instead of a
guessed score: weapon parts, vehicle parts, specialized cases, capture traps,
fluid/hydration containers, recipe-dependent Food/Medical/Literature cases,
and some low-confidence accessories.

Tools and materials whose value mainly comes from crafting, construction,
farming or world actions can be underestimated. ToolUtility and CraftingValue
were intentionally excluded from 1.0 because the Build 42 bridge does not yet
reliably expose the Tool/Input/alternative and world-action relationships
needed to score them safely. This is a known limitation, not a per-item bug.

### Roadmap: 1.1

- Revisit ToolUtility and CraftingValue only if the runtime bridge can expose
  reliable recipe-tool/input and world-action relationships.
- Continue conservative category coverage where structural data supports a
  generic, mod-compatible rule.
- Preserve the principle of no item-name hardcodes and no guessed mechanical
  effects.

## Suggested Workshop tags

`Balance`, `User Interface`, `Quality of Life`, `Build 42`

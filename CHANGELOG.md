# Changelog

## 1.0.0

First stable release for Project Zomboid Build 42.20.2.

### ClothingUtility V2 closure

- Corrected structural Clothing/Accessory classification so bodywear no longer
  falls into `UNKNOWN` through display-category aliases.
- Replaced vulnerable within-slot component rankings with calibrated absolute,
  centred coverage/mobility/weather components in the validated clothing
  macro groups; HEAD also uses absolute senses.
- Kept the Clothing C1 Scarcity adjustment bounded to ±5 score points.
- Added conservative `COMMON` handling for unambiguous trivial cosmetics while
  keeping watches, belts, holsters, slings and sheaths out of guessed Utility.
- Added `docs/clothing-utility.md` as the Clothing V2 reference.

### Release preparation

- Removed the public `Experimental` label and set the mod version to
  `1.0.0`.
- Added release README documentation for structural Scarcity, category Utility,
  sandbox/difficulty behavior, optional UI compatibility, and limitations.
- Added client-side presentation options through the built-in B42 Mod Options
  system, including PT-BR and English UI text.
- Kept Clean UI and Clean HotBar integration optional and load-order resilient.
- Replaced obsolete experimental rarity/Utility documentation with the active
  Strategy D and category-specific Utility model.

### Runtime/diagnostic separation

- Removed `LightFireClientAudit` from the normal client registry load path.
- Removed automatic RegistrySnapshot writes from `ItemRarity.rescan()`.
- Snapshot generation remains available only through its explicit development
  command.

### Deferred safely to 1.1

- Investigated a conservative `ToolUtility V1` using reusable-tool tags,
  durability, carry cost and lifecycle signals.
- Did not integrate it: the B42 bridge does not reliably expose tool action
  breadth, recipe/tool alternatives or comparable world-action opportunities.
- Kept `ToolUtility` and generic `CraftingValue` out of 1.0 rather than
  double-counting WeaponUtility or guessing value from item names, rarity or
  recipe counts.

### Earlier RC compatibility baseline

- Functional baseline: `365586:746779767:1457786657`.
- Expected published registry: `3416` item types and `97818` loot occurrences.

That baseline belongs to its original LB/LK/LTW loaded universe. The final
post-Clothing-V2 audit for the current loaded universe is recorded in
`docs/release-candidate-audit.md`.

### Known limitations

See the **Known limitations** section in `README.md`. Unsupported or
partially-observable effects remain on the structural fallback rather than
receiving guessed mechanical Utility.

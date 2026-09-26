# Batch 3: Magazine / Ammo / Fish / Literature

Source: canonical repository, `develop/1.1`. No global baseline accepted and
no batch-3 commit. Pending AmmoType/Firearm investigation remains separate.

## Boundaries

- Magazine: existing discovery boundary; validate capacity and declared GunType /
  AmmoType before scoring. Validate compatible firearm scores before including
  them. Item-local scoring barrier; no relative magazine population. GunType
  resolver, capacity formula and ceiling unchanged.
- Ammo: existing discovery boundary and optional no-loot discovery barrier;
  validate relationship key and referenced firearm tier before inheritance.
  No numerical Ammo score, no new relationship resolver or fallback, no scarcity
  invention. Exact AmmoType resolver pending in the working tree is unchanged.
- Fish: validate Fishing configurations before contributing to bait denominators
  or species scales. Candidate, reference, scoring and assignment boundaries;
  remove failed species and rebuild pure scores/denominators after late failures.
  Fishing references still include valid species without loot. Existing Fishing
  size default and declared calorie fallback are preserved, not new substitutions.
  Malformed/missing required measurements do not become zeros. Optional no-loot
  candidate discovery is protected; publication semantics are unchanged.
- Literature: existing discovery boundary captures the actual builder; local
  metric reader preserves invalid/absent values as error/absence. Quantitative
  recipe/mood inputs are validated before arithmetic. Final policy admission is
  distinct from comparative ranking (there is no relative population). Known
  Map, SkillBook, static LearnedRecipes, SPECIAL_PARTIAL and trivial policies
  retain their normal outputs. Missing required recipe scarcity does not receive
  an invented neutral value. Missing mood measurements cannot prove triviality.

Global coefficient/threshold failures remain explicit, outside item guards.
No edits to thresholds, weights, GunType resolution, AmmoType identity resolution,
Firearm formulas, Container V3 or Visual Options.

## Synthetic checkpoint

Tests run in the game's Kahlua VM, without a world or real InventoryItem/OnCreate.
Healthy rows are compared against the pinned pre-containment calculator and
against cohorts with malformed data. Names in fixtures are test identities only.

| Utility | Healthy compared | Failure isolated | Healthy regression | Population contamination | Item-caused global fatal |
| --- | ---: | --- | ---: | ---: | ---: |
| Magazine | 2 | yes | 0 | 0 | 0 |
| Ammo | 2 | yes | 0 | 0 | 0 |
| Fish | 2 | yes | 0 | 0 | 0 |
| Literature | 5 + 1 preserved SPECIAL_PARTIAL | yes | 0 | 0 | 0 |

Fixtures cover missing fields, strings, booleans, userdata, nonfinite values,
late item exceptions and repeat-warning deduplication. Fish additionally tests
the actual UTILITY_ONLY augmentation with two species: unchanged utility/tier,
Scarcity absent, RouteWeighted skipped. Literature tests actual mock-script
builders, including static recipe deduplication, maps and trivial literature.
All ten current Utility fixture gates pass, including previous batches.

## Real checkpoint: approved, 2026-09-26

Controlled PRE = current facts/code minus batch-3 containment; POST = current.
Two same-session shadow runs compared 417 entries, including absent augmentation
candidates. Added/removed/Utility/score/tier changes = 0; healthy registry diff = 0;
invalid/partial public diff = 0; membership and Fish reference differences = 0;
POST-versus-real output diff = 0; global fatals = 0. Second rescan MATCH.
This approves batch-3 hardening only. The observed signature
`346359:1830660975:944611722` is evidence, not an accepted global baseline.
Ammo temporary-reference and Literature LitE/LitS coverage issues remain OPEN.

## Earlier same-session A/B procedure (not historical PRE/POST)

After synchronization and a full game restart, use the same save/modset:

```lua
require "ItemRarity/Diagnostics/BatchComparison"; ItemRarityBatchComparison.run("A", 3)
ItemRarityBatchComparison.run("B", 3)
```

The diagnostic keeps snapshots in memory, with no writer dependency. Ammo is
healthy by valid tier inheritance, not by a nonexistent numerical Utility.
Fish snapshots include observed Fishing API reference metrics and components,
including no-loot species. Per-Utility contamination remains UNKNOWN after a
late failed admission/scoring path unless the observation proves exclusion;
fixtures, not A/B alone, prove the controlled rebuild behavior. A/B establishes
same-session stability, not pre-patch equivalence for the entire real modset or
cross-session determinism. No live result is claimed before the user runs it.

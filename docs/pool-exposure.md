# Pool exposure and Strategy D

`PoolExposure` is a normalized structural measure derived from final runtime
loot tables. It answers “how broadly is this pool reachable through the known
room/container selector routes?” It does **not** answer how many matching rooms
or containers physically exist in Kentucky.

## Confirmed in local Build 42.20.2 code

The scanner observes final `SuburbsDistributions`, `VehicleDistributions`, and
`ProceduralDistributions.list` after `OnPostDistributionMerge`.

Procedural routes have the observed chain:

`room key -> container key -> procList entry -> named procedural distribution -> items/junk -> item`.

Observed selector fields are `name`, `min`, `max`, `weightChance`,
`forceForItems`, `forceForZones`, `forceForTiles`, and `forceForRooms`.
`ItemPickerJava.rollProceduralItemInternal` builds eligible candidates and
`getDistribInHashMap` selects proportionally to their `weightChance`; omitted or
non-positive values become `1`. When a `forceFor*` condition matches, the Java
code takes a separate forced-candidate path. `min`/`max` also gate procedural
reuse inside a room.

## Registry

Every scanned section (`items` and `junk` remain separate pools) receives a
registry entry with `referencedByRooms`, `referencedByContainers`, routes,
selectors, condition records, unique room/container counts, exclusivity flags,
and an experimental normalized exposure score. Static table entries have a
direct known path; procedural entries retain their selector metadata.

## Strategy D — RouteWeighted

For each item and each pool, Strategy D first uses the same neutral,
roll-adjusted occurrence availability as Strategy B. It multiplies that pool
availability by `PoolExposure`, then combines pools as a saturating union:

`D = 1 - product(1 - poolOccurrenceAvailability * poolExposure)`.

`PoolExposure` itself is `routeReachability * coverage`.

- `routeReachability` is a union of known route selector shares, so repeated
  routes saturate rather than scale linearly.
- `coverage` is a 50/50 combination of logarithmically normalized unique room
  and container counts.
- Any `forceFor*` route receives the configurable 0.45 contextual factor.
  This is an **approximation**, not a claim that a condition occurs 45% of the
  time.

The configuration lives in `RarityConfig.lua`; it affects only analysis.
Percentile D is computed within functional category.

## Boundaries

**Confirmed:** table paths, selector fields, selector weighting and final-table
timing. **Approximation:** coverage normalization, equal footprint of room and
container names, and the conditional-route factor. **Not determined:** map
counts, geographic distribution, actual frequency of rooms/containers,
condition frequency, loot-zone density and all runtime state. Therefore neither
PoolExposure nor Strategy D is WorldAvailability or an actual find probability.

The runtime report logs complete pool summaries and all known route records for
Katana, Axe, and the selected modded items, plus stage timings. It runs once at
initialization and reuses the scanner cache.

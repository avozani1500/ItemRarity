# Loot analysis — Project Zomboid Build 42 installation

## Scope and evidence

This document records an inspection of the local Steam installation at `C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\media` on 2026-08-13. Its local log identifies the installed game as **42.20.2** (`revision=ffe7a8a4b1`). It describes the files actually present in that installation; it does not rely on Build 41 examples.

The relevant source files are:

- `media/lua/server/Items/ProceduralDistributions.lua`
- `media/lua/server/Items/Distributions.lua`
- `media/lua/server/Items/SuburbsDistributions.lua`
- `media/lua/server/Items/ItemPicker.lua`
- `media/lua/server/Vehicles/VehicleDistributions.lua`
- `media/lua/client/ISUI/AdminPanel/LootZed/SpawnRateChecker.lua`

## Findings

### 1. Where are vanilla loot tables?

Vanilla world-container tables are Lua source under `media/lua/server/Items/`:

- `ProceduralDistributions.lua` creates `ProceduralDistributions.list`. It is the large catalog of named item pools, such as `AmbulanceDriverTools`.
- `Distributions.lua` creates the base room/container map, stores it in `Distributions[1]`, and exposes it initially as `SuburbsDistributions`.
- `SuburbsDistributions.lua` merges tables supplied by mods into `Distributions[1]` and registers the merge on `Events.OnDistributionMerge`.
- Vehicle containers have a separate family in `media/lua/server/Vehicles/VehicleDistributions.lua`.

Build 42 still has `ItemPicker.lua`, but its entire implementation is `ItemPicker = ItemPickerJava`: the actual picker/parser is Java-backed. Local logs show `ItemPickerJava.Parse() start` and `ItemPickerJava.Parse() end` after the Lua distribution loading.

### 2. How is an item represented?

Entries in vanilla `items` arrays are alternating name/weight pairs, for example:

```lua
items = {
    "Axe", 0.5,
    "Hammer", 8,
}
```

Vanilla commonly uses unqualified names such as `Axe`; these resolve to the `Base` module in normal vanilla data. Mods may use qualified names such as `MyMod.CustomSword`. The experimental scanner asks the verified runtime API `getScriptManager():FindItem(itemName)` for its canonical `getFullName()` and otherwise retains an already-qualified value or uses `Base.` as a diagnostic fallback.

### 3. How are weight and chance represented?

The number after each item is a raw distribution weight. A table also supplies `rolls`; the bundled Build 42 admin diagnostic derives per-roll chance as `(itemWeight * ItemPickerJava.getLootModifier(itemName)) / 100.0`, then combines rolls as `1 - (1 - chance)^rolls`. This is evidence that a raw weight alone is not a world-wide spawn probability.

`junk` is a second item pool with its own rolls. The Java picker applies loot modifiers; the admin diagnostic treats junk specially. The MVP scanner records raw weights and pool section, but does not yet claim to compute final spawn probabilities.

### 4. Can an item occur in multiple distributions?

Yes. The same item can appear repeatedly in one table and in many named procedural, static, and vehicle distributions. The scanner keeps both `occurrences` and a distinct list/count of source distributions.

### 5. Are distributions nested?

Yes, in two different ways:

- A room/container entry can be `procedural = true` and contain a `procList` of named pools.
- The room/container structure itself is nested (room → container → distribution), and vehicle tables add another hierarchy.

The first scanner enumerates actual named `ProceduralDistributions.list` pools plus direct `items` pools found recursively in `SuburbsDistributions` and `VehicleDistributions`. It intentionally does not turn every `procList` reference into a weighted world-frequency estimate yet.

### 6. Are there conditional modifiers?

Yes. `procList` entries include `min`, `max`, `weightChance`, `forceForZones`, `forceForTiles`, `forceForRooms`, and `forceForItems`. Examples in the installed tables use zone conditions such as `Rich`/`Poor` and tile-specific forced pools. These conditions are a reason the first delivery only collects statistics rather than claiming an exact rarity score.

### 7. Are residential, commercial, and military loot meaningfully different?

Yes. `Distributions.lua` is organized by room/business names and container types; it includes distinct spaces such as residential rooms, stores, medical spaces, mechanics, and military lockers. Those room/container contexts select different procedural pools and direct tables.

### 8. Do SandboxVars alter tables or multiply results later?

The inspected Lua tables are static definitions and do not embed the sandbox abundance values. The bundled admin diagnostic obtains a per-item modifier through `ItemPickerJava.getLootModifier(itemName)`, and local logs identify Java parsing after the tables are loaded. This supports the current conclusion that at least part of abundance handling is applied by the picker after Lua tables are defined. Exact category-to-item behavior belongs to a later calibration pass; the MVP scanner records unmodified source data.

### 9. Can runtime Lua access loaded distributions?

Yes. The loaded globals `ProceduralDistributions.list`, `SuburbsDistributions`, and `VehicleDistributions` are directly read by the bundled Build 42 admin diagnostic (`SpawnRateChecker.lua`). The scanner reads the same globals only after `Events.OnPostDistributionMerge`, an event registered by vanilla directly after the merge callback.

### 10. Can it see loot added by other mods?

For mods that add a distribution table to `Distributions`, vanilla's `MergeDistributionRecursive` merges their content into `SuburbsDistributions` during `Events.OnDistributionMerge`; a scan scheduled on `OnPostDistributionMerge` can observe that merged result. It also sees items added to the global procedural list before that event.

Limit: a third-party mod that mutates a table after `OnPostDistributionMerge`, or populates loot only through custom Java/runtime code, is outside this first scanner's guaranteed observation point. Load-order and late-mutation behavior must be tested with a real third-party mod before making an absolute compatibility claim.

## Chosen first-delivery execution point

`Events.OnPostDistributionMerge` is verified in the installed `SuburbsDistributions.lua` and is later than vanilla's `OnDistributionMerge` handler. The scanner runs once and caches results in memory. It does not run during rendering, inventory opening, or per item.

## What the experimental logs mean

The scanner logs total distinct item types and the 20 highest/lowest entries by **raw aggregate weight**. This is diagnostic output only, not a rarity decision. It makes malformed name/weight pairs visible without stopping world generation, and it preserves enough data for the next phase to compare occurrence count, distinct distribution count, raw total, average, minimum, and maximum weight.

## Known limits before a rarity algorithm

- Direct procedural-pool statistics do not yet include the probability of every room/container selecting that pool.
- `weightChance`, rolls, conditions, vehicle frequency, map density, and Java-side loot modifiers are not yet folded into a world-frequency model.
- The scanner uses a `Base.` fallback only for reporting an unresolved short name; item validation/filtering is deliberately deferred.
- No rarity registry, UI, sandbox option, item mutation, network synchronization, or loot-table modification exists in this delivery.

## Expanded scanner model (second investigation pass)

### Confirmed

- Each `items` array remains an alternating `itemName, weight` sequence. The scanner records the raw weight, item count, total raw weight, duplicate count, `rolls` field when present, `junk` section, and relative raw weight (`itemWeight / poolTotalWeight`) for every valid occurrence.
- A named procedural pool has a direct definition in `ProceduralDistributions.list`. World room/container tables select it through `procedural = true` and `procList` entries. The scanner records the observed routes from `SuburbsDistributions` and `VehicleDistributions`, including the room/container path and explicit `min`, `max`, `weightChance`, and `forceFor*` fields when present.
- Static pools are direct `items` tables in `SuburbsDistributions` or `VehicleDistributions`. Their source path is recorded as the currently observable room/container route.
- `rolls` is a numeric field on the pool definition when supplied. It is captured as source data only. The bundled admin diagnostic confirms that the Java picker uses it when combining rolls, but the scanner deliberately does not call the result a final world probability.
- Script item resolution produces canonical full types at runtime. The scanner preserves all modules, counts non-`Base` modules as modded, and sends them through exactly the same aggregation pipeline as vanilla items.

### Hypothesis / not yet a rarity formula

- `weight / poolTotalWeight` is a useful within-pool composition metric, but it is not by itself an absolute chance: the Java picker also uses rolls and loot modifiers, and a pool's real availability depends on how often its containers occur in the map.
- A later effective-availability model can combine relative weight, rolls, observed routes, container/world frequency, conditional entries, and category. This delivery deliberately makes those inputs available without selecting a formula.

### Not determined / not covered by the current scanner

- Map population counts of rooms and containers; therefore the number of real opportunities for a pool to spawn is not known.
- Java-side implementation details of `ItemPickerJava` beyond what the bundled Lua admin diagnostic exposes, including exact Sandbox abundance behavior per item/category.
- Loot produced outside the scanned container families: foraging, fishing, farming, recipes/crafting, world stories, zombie/outfit systems, vehicle mechanics, server commands, and custom Java mod code may create items without appearing in these tables.
- An existing ScriptItem with no scanned occurrence is reported as `NO_LOOT_DATA`; it is not inferred to be rare, craft-only, special, or debug-only.

### Practical definitions used by the scanner

- `NATURAL_LOOT`: at least one occurrence in the scanned distribution families.
- `NO_LOOT_DATA`: the ScriptItem exists but no occurrence was observed; no rarity conclusion follows.
- `UNKNOWN`: no ScriptItem or loot observation could be resolved.

The functional category is preliminary. It is derived from the runtime ScriptItem display category only when that API reports one; otherwise it remains `UNKNOWN`. No full-type allowlist is used.

## Runtime validation — 2026-08-13

### Confirmed in the active 42.20.2 world

- Scan result: **3,368** unique item types, **97,402** valid occurrences, **1,420** procedural distributions, and **827** static distributions.
- The current loaded loot tables contained **3,368 `Base` types and 0 non-`Base` types**. This run therefore validates the vanilla pipeline, not a third-party loot insertion.
- One malformed item/weight pair was ignored without stopping the scan.
- The scan and aggregation completed in roughly 1.4 seconds in the active modded installation; the diagnostic report printed 50 representative items afterwards.
- Example observed pool composition: `BankDeposit` has `rolls = 4`, total raw weight `595.7`, and `Base.Money` entries of raw weights `100` (16.787% of the pool) and `50` (8.393%). Duplicate entries are intentionally retained because they are part of the source data.
- Example observed route data: `ArmyBunkerLockers` has one discovered procedural route and contains `Base.Paperwork` at raw weight `10` in a pool total of `10`, with `rolls = 1`.

### Modded-loot test status

Not run by user choice for this stage. The scanner has no mod-specific code: any future non-`Base` full type found in the same runtime tables will be kept, tagged with its module, and aggregated like a vanilla type. A separate test with a known loot-adding mod remains required before claiming verified third-party compatibility.

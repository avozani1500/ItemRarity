# TableAvailability / Strategy D

This document describes the active structural table-analysis model. It is deliberately **not** a
prediction of how often a player will find an item while exploring the world.
The scanner observes the final Lua tables after compatible mods have loaded;
it does not edit distributions, Sandbox settings, or items.

## Confirmed in the local Project Zomboid 42.20.2 code

`zombie.inventory.ItemPickerJava.doRollItemInternal` computes effective rolls
as `max(1, floor(container.rolls * SandboxOptions.rollsMultiplier))`.  For each
one of those rolls it iterates every `ItemPickerItem` in the section and draws
`Rand.Next(10000)`.  An item is added when that draw is below its actual spawn
chance.  Therefore the entries are not a single weighted choice and more than
one item can succeed during one roll; the same item can also succeed again on
a later roll.

`getActualSpawnChance` uses the item table value as the base chance, then
applies item-type loot modifier, optional no-zombie multiplier, zombie-density
term, and the current location's loot multiplier.  These contextual terms mean
that a complete world probability cannot be derived from the distribution table
alone.  Fractional declared rolls are truncated by `floor` after the Sandbox
roll multiplier.  A separate `junk` section is a separate container roll path;
the scanner preserves it as its own pool.

Procedural pool selection itself also has route conditions (`min`, `max`,
`weightChance`, `forceFor*`), so its real selection frequency is outside this
score.  Static pools, vehicles, nested containers, special item behavior and
other runtime hooks likewise remain outside it.

## Scores

All scores are reported on 0--100 and all three are retained for comparison.
The configuration at `common/media/lua/shared/ItemRarity/RarityConfig.lua`
selects which strategy is marked as selected; default is `A`.

- **A — RelativeWeightOnly:** mean of `entry weight / sum of weights in that
  section`. It is a useful composition baseline only, not picker probability.
- **B — NominalRollAware:** uses confirmed repeated-roll behavior with the
  neutral table chance `min(weight / 100, 1)` and
  `1 - (1 - p)^declaredRolls`. It intentionally excludes live Sandbox,
  item-type and zombie-density adjustments.
- **C — EqualPoolAggregate:** first combines duplicate entries within a pool,
  then combines the pool chances as `1 - product(1 - poolChance)`. This is an
  explicit equal-exposure approximation: every reachable pool is treated as if
  it were observed once. It does not multiply by distribution count.

Percentiles are calculated independently within the scanner's functional
category.  A high percentile therefore means “high relative to other observed
items in this category under this strategy”, not globally common and not
world-common.

## Runtime validation output

The bounded debug report includes eight fixed vanilla comparison items,
non-Base examples when present, and anomaly samples: few-table/high-score,
many-table/low-score, near-100% relative entries, junk-only exposure, and high
declared rolls.  The separate modded summary distinguishes **registered item
data** from items actually **found in final loot tables**: an enabled mod that
adds no table entry will not appear in the latter summary.

The calculation runs once after final tables are available and reuses the
scanner cache.  It has no UI and no gameplay effect.

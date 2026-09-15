# Rarity tiers and Strategy D

Item Rarity publishes one visual tier for every scanned full type:
`COMMON`, `UNCOMMON`, `RARE`, `EPIC`, or `EXOTIC`.

`BaseScarcityTier` is derived from **Strategy D / RouteWeighted** availability
inside the item's functional category. Lower modeled availability means a
rarer scarcity tier:

| Strategy D percentile | Base scarcity tier |
| --- | --- |
| 0 to <5 | `EXOTIC` |
| 5 to <15 | `EPIC` |
| 15 to <35 | `RARE` |
| 35 to <65 | `UNCOMMON` |
| 65 to 100 | `COMMON` |

Strategy D combines declared table chance and neutral effective rolls with
the normalized structural reach of each final merged loot-table route. It is
not a world-frequency prediction: it intentionally excludes map population,
room counts, seed effects and contextual Sandbox generation multipliers.

## FinalRarityTier

`FinalRarityTier` is the sole tier consumed by the UI. It is calculated by the
host after scarcity and functional classification. Its policy is
category-specific:

- categories with validated deterministic mechanics use their approved Utility
  policy (for example Food, Fish, Clothing, Firearms, Literature and Light/
  Fire devices);
- categories without sufficient structural data keep the Scarcity fallback;
- special/trivial policies may apply an explicit conservative tier ceiling.

There is no generic Scarcity × Utility matrix that overrides these policies.
The tier is not a drop-rate modifier and Item Rarity never changes loot tables
or gameplay stats.

## Determinism and loaded mods

The scan runs after `OnPostDistributionMerge`, so it sees vanilla tables plus
the final contributions of enabled mods. Utility rules use item structure and
declared/runtime attributes; they do not use item display names or hand-picked
full-type rules. Where a Utility has a vanilla reference population, modded
items are evaluated against it rather than changing its scale.

Sandbox difficulty and loot abundance influence actual generation at runtime,
but Strategy D uses neutral structural inputs. For an unchanged loaded
distribution universe, rarity tiers remain stable across difficulty presets and
normal sandbox loot multipliers.

## Coverage and limitations

Route coverage is diagnostic only:

```text
OccurrenceCoverage = modeled occurrences / all occurrences * 100
PoolCoverage       = modeled unique pools / all unique pools * 100
```

Unresolved pools receive no invented route exposure. Categories whose effect
cannot yet be measured safely remain on the fallback instead of receiving
guessed Utility. See `README.md` for the release-facing limitations and the
individual Utility documents for their frozen models.

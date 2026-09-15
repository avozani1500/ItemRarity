# ClothingUtility V2

ClothingUtility V2 evaluates clothing from deterministic item attributes and
publishes only `FinalRarityTier` to the client. It never derives a tier from
the current condition of an equipped item.

## Taxonomy and precedence

The classifier first preserves functional categories such as containers. It
then uses structural clothing evidence (`ClothBody`, `ClothLeg`, `ClothFeet`,
`ClothUnder`, body location and blood-clothing coverage) to classify bodywear
as `CLOTHING`. Cosmetic/accessory locations are classified as `ACCESSORY`.

Backpacks, satchels and other structural containers remain `CONTAINER`; the
clothing fallback cannot capture them. This distinction is intentionally made
from runtime/script structure, never from item names or full types.

## Score and scarcity

The existing Clothing score retains its protection, durability, weight,
discomfort and senses/cost axes. Direct-slot non-trivial clothing uses the C1
combiner:

```text
ScarcityAdjustment = (ScarcityStrength - 50) / 10
AdjustedScore = clamp(ClothingScore + ScarcityAdjustment, 0, 100)
```

Scarcity therefore changes the score by at most five points; it cannot directly
promote or cap a clothing tier. Clothing that is structurally
`MECHANICALLY_TRIVIAL` is always `COMMON`.

## Absolute components

Where the data has a safe anatomy model, V2 replaces local slot-percentiles
with absolute, centred components. This prevents a small population in one
slot from turning a 2% movement difference into a large Utility change.

- `LOWER_BODY`, `UPPER_BODY`, `OUTERWEAR`, `FEET`, `HANDS` and `HEAD` use
  anatomy-aware coverage plus absolute movement/weather components.
- `LIMB_LOWER` uses thigh/shin coverage with centred movement and weather.
- `FULL_BODY` uses its full structural coverage set with centred movement,
  weather and senses.
- `HEAD` uses absolute senses:

```text
SensesRaw = 0.50 * VisionModifier + 0.50 * HearingModifier
AbsoluteSenses = clamp(50 + 100 * (SensesRaw - 1), 0, 100)
```

The exact coverage weights belong to anatomy, not to an individual item.
Small movement penalties remain small; broader coverage is rewarded only when
the item has relevant defensive or climate attributes.

`LOWER_BODY` and `HEAD` use their approved score cuts of 40 / 50 / 60 / 75.
Other groups retain their established cuts unless explicitly documented by a
future calibration task.

## Conservative exclusions

`ACCESSORY + MECHANICALLY_TRIVIAL` is forced to `COMMON` only for unambiguous
cosmetic anatomy. Timepieces remain special/partial because their gameplay
effects are not safely exposed. Belts, holsters, slings and sheaths likewise
remain outside that ceiling when their attachment/carry behavior is ambiguous.

Low-confidence direct-slot macro groups (`LIMB_UPPER`, `TORSO_ACCESSORY`,
`OTHER_DIRECT` and `PROTECTIVE_ACCESSORY`) retain their validated existing
path. This is deliberate: V2 does not invent anatomy or a population ranking
where the runtime evidence is insufficient.

## Validation state

The current loaded-universe Clothing V2 baseline is
`339579:1646489189:664133968`, with 3,505 published types and 100,820 loot
occurrences. A second scan matched that signature. Baselines naturally differ
when the enabled mod and loot-table universe differs.

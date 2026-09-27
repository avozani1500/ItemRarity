# Batch 4: item-level containment

Scope: LightFire, Explosive, Incendiary, NoiseMaker and Accessory. No coverage fixes, formula calibration or global baseline acceptance.

## Boundaries

- Discovery validates acquired metrics before numeric comparisons. Existing unsupported-state exclusions remain in place.
- LightFire admission requires calculable duration and emitted-light metrics for the functions actually present. Failed members are excluded before maxima/profile calculation; a late scoring failure rebuilds those references using survivors.
- Explosive requires positive ExplosionPower and ExplosionRange. Incendiary requires positive FireRange. NoiseMaker requires positive NoiseRange and preserves the configured ceiling.
- Incendiary/NoiseMaker discovery cannot prove exclusion of competing effects from missing values: missing exclusion metrics defer the candidate, rather than inventing zero.
- Absolute-effect scorers isolate each item and rebuild profile counts after late failure.
- Accessory resolves proven trivial structural policy before unrelated metric barriers. Missing core benefit metrics remain partial, not zero. Special/timepiece exclusions remain conservative.
- Invalid global scoring configuration still raises an error. Item warnings use the existing deduplication key.

## Controlled validation

Run `scripts/test-item-isolation.ps1`. Batch 4 healthy scoring oracle is commit `2fb7ebc`, with identical controlled inputs on both sides.

| Utility | Healthy controls |
| --- | ---: |
| LightFire | 4 |
| Explosive | 2 |
| Incendiary | 2 |
| NoiseMaker | 2 |
| Accessory | 4 |

Fixtures cover missing/non-numeric/boolean/userdata/non-finite values, warning deduplication, late scoring failures, healthy score/tier preservation, structural precedence and unsupported-state exclusions. These are controlled tests, not a historical world registry comparison.

## Real-world checkpoint (approved)

Same-session A/B: 30 LightFire and 165 Accessory healthy rows, zero changes and observed contamination, no scan fatal, second rescan MATCH. Explosive/Incendiary/NoiseMaker have no admitted candidates in this modset; preservation is established by the controlled PRE/POST fixtures above, not by claiming real healthy observations.

Separate functional issues remain OPEN: `EXPLOSIVE_COVERAGE_GAP`, `INCENDIARY_COVERAGE_GAP`, `NOISEMAKER_COVERAGE_GAP`. Active WepBomb/Elec metadata maps to UNKNOWN; the preexisting builders require AMMO and Explosives. No classification/coverage fix is included. Missing ScriptItem effect getters are unknown, not zero. The raw aggregate A/B contamination field remains UNKNOWN; approval combines per-Utility observations with controlled fixtures.

After synchronizing and restarting the game, load the same save/modset. Run each command separately:

```lua
require "ItemRarity/Diagnostics/BatchComparison"
ItemRarityBatchComparison.run("A", 4)
ItemRarityBatchComparison.run("B", 4)
```

The explicit diagnostic stores A/B in Lua memory; no file writer is required. It reports per-Utility healthy counts, regressions and observed population contamination, and the second rescan signature comparison. Zero healthy observations are not a pass. Late failures without sufficient runtime rebuild evidence remain UNKNOWN.

Approval requires healthy regression 0, population contamination 0, no global fatal and second rescan MATCH. Same-session A/B tests repeatability of the patched runtime; pre/post scoring equivalence is separately exercised by the fixtures. No global baseline is accepted by this checkpoint.

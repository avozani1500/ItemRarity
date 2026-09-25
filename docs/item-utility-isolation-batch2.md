# Batch 2: Clothing / Food / Medical

Batch 1 is committed as `2702bc6`; unrelated Ammo and Firearm/parser development
remains uncommitted. Batch 2 passed the scoped real-world checkpoint. No global
baseline is accepted. Utilities outside these six and UTILITY_ONLY still need
their own gates.

## Boundaries and populations

- Clothing: normal discovery uses the existing item boundary. Required numeric
  attributes, anatomy and comparison identity are checked before shared scales.
  Coverage, mechanical benefit, grouping, preparation, slot admission, scoring,
  assignment and mechanical policy have item-local boundaries. A late failure
  rebuilds shared inputs and slot populations without repeating discovery.
- Food: required direct-consumption data/flags and item Scarcity inputs are
  validated before samples. Samples, representative scores and member assignment
  are item-local. A failed member/representative is excluded before rebuilding
  mood caps, rankings and scores. Cooking time is required only for cookable food.
- Medical: effect, uses and comparison identity are validated before treatment
  populations. Representative scoring and member assignment are item-local;
  missing/nonfinite percentiles are not multiplied. A late failure rebuilds the
  treatment group without that candidate.

No coefficients, tier thresholds or functional-family rules were recalibrated.
Previously defaulted missing required measurements now defer rather than joining
a comparison as zero/neutral. Existing global configuration errors propagate.
Retries remove failed candidates and rerun pure scoring only, not the scan,
registry or runtime callbacks. Warnings use the existing session deduplication.

## Synthetic gates

`scripts/test-item-isolation.ps1` runs all six Utility gates in game Kahlua.
The healthy oracle is pinned to `4c8a0a6a5a2af71f8df695ecbdcfb9139c71d9ef`.
Complete published rows are compared with that oracle and with clean cohorts.

| Utility | Item isolated | Item-induced global fatals | Healthy regression | Population contamination | Error fixtures | Partial fixtures |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Clothing | yes | 0 | 0 | 0 | 6 | 14 |
| Food | yes | 0 | 0 | 0 | 6 | 14 |
| Medical | yes | 0 | 0 | 0 | 12 | 2 |

Counts cover the primary malformed-input cohorts only. Additional tests cover
late failures, repeat-warning deduplication, and propagation of invalid global
configuration. Clothing controls exercise lower body, head, feet, hands, torso,
outerwear and full body. Food and Medical include independent control groups.
No InventoryItem, OnCreate or live world is used by these tests.

## Real checkpoint

The first world checkpoint was rejected: 216 Clothing candidates were deferred
(116 missing biteDefense, 100 missing anatomical regions). The latter group
contained 64 items with all six defense/weather values explicitly zero and 36
with a measured nonzero benefit. These are log-derived pre-correction counts;
special-function exclusions and final outcomes require the corrected world run.

Clothing now separates structural-policy eligibility from ranking eligibility.
Six measured defense/weather zeroes with no known special function resolve the
existing trivial Clothing policy before quantitative admission. Missing values
never prove zero. These resolved candidates keep their Clothing identity and
COMMON policy, but have no numeric Utility or ranking membership. Remaining
incomplete mechanical candidates stay deferred. Accessory policies are unchanged.

The diagnostic derives effective state from final scoring/policy, not Clothing's
initial discovery `utilityEligible=false`. It compares structural policy,
ranking eligibility/membership, effective state, scores and final tier. It also
tabulates the prior rejection predicates against current outcomes and prints
the two requested underwear sanity references (diagnostics only, no item rule).
Rejection before any observed admission is evidence of non-participation;
late failures still require separate anchor-rebuild evidence.

New fixtures include zero-benefit underwear without anatomy, the same attributes
under an arbitrary mod fullType, complete zero-benefit clothing, missing defense,
unknown-coverage warm clothing, special-function exclusions, and the existing
accessory cosmetic policy. Healthy mechanical controls match the clean cohort
when structural-only/incomplete candidates are added. This does not claim that
removing previously admitted trivial references preserves all historical ranks.
No new calibration or threshold adjustment compensates for a changed population.

After DEV synchronization, restart the game and open the same save/modset with
Item Rarity DEV alone (not simultaneously with release). Execute explicitly:

```lua
require "ItemRarity/Diagnostics/BatchComparison"; ItemRarityBatchComparison.run("A", 2)
ItemRarityBatchComparison.run("B", 2)
```

The diagnostic performs two normal rescans with temporary observers, restores
observers on success/error, and retains deep A/B snapshots in Lua memory. It has
no file-writer dependency. It reports membership observations and reconstructed
reference identities, not a direct view into private anchor arrays. If isolated
failures require additional anchor evidence, contamination stays UNKNOWN rather
than printing an unjustified zero. A/B demonstrates same-session stability, not
pre-patch equivalence or cross-session determinism. Existing fixtures supply the
controlled pre-patch and malformed-input comparisons.

### Approved checkpoint evidence (2026-09-25)

Existing in-memory A/B comparison: 1050 healthy items, zero healthy regressions,
zero missing observations and zero population/reference membership changes.
Both scans completed with zero global fatals; B returned MATCH. The observed
signature `346359:1830660975:944611722` is not an accepted global baseline.

| Utility | Healthy compared | Population contamination | Healthy A/B regression |
| --- | ---: | ---: | ---: |
| Clothing | 561 (481 mechanical, 80 structural) | 0 | 0 |
| Food | 326 | 0 | 0 |
| Medical | 17 | 0 | 0 |

Food/Medical zeroes are conclusions from the existing A/B evidence, not new
literal log fields: the comparator compares every captured population field,
including reconstructed reference identities, and reported zero differences
and zero missing observations. The session log contains no Food/Medical
PARTIAL_DEFER or ERROR_ISOLATED warning; all 152 such records are Clothing.
The aggregate UNKNOWN is consequently not a Food/Medical contamination finding.
Controlled fixtures separately compare pre-containment healthy cohorts and
inject invalid/late-failing candidates, checking that healthy outputs remain
unchanged. Real A/B is not a replay of the entire pre-patch world population.

Of the previous 216 Clothing deferrals, 64 now resolve structurally; 116 missing
biteDefense and 36 missing anatomy remain excluded from mechanical populations.
Both underwear sanity cases are COMMON. Accessory healthy count is 146.

`BATCH_2_APPROVED = yes` within these gates. No runtime changes, additional world
rescans, synchronization, release generation or global-baseline acceptance were
performed to close this reporting checkpoint.

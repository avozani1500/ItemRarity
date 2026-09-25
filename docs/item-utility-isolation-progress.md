# Item-local containment: implementation status

This is an incomplete implementation, not a universal-compatibility claim.
DEV batch 1 was synchronized and its same-session world checkpoint approved.
No release generation or global baseline acceptance was performed.

## Approved batch 1 world checkpoint (2026-09-25)

Two full rescans completed: 3573 registry rows, revision 230. The in-memory A/B
diagnostic compared 60 healthy candidates (34 Container, 23 Firearm, 3 Melee):
zero A/B differences, zero missing observations, zero membership changes, and
second rescan MATCH. No isolated/partial failures occurred in that world run;
invalid-input containment and warning deduplication were exercised in fixtures.
Reference identities are reconstructed from observed admission, not direct
inspection of private anchor arrays. This is a same-session stability checkpoint,
not proof of cross-session determinism or a new global baseline.

The test oracle is pinned to pre-containment commit
`4c8a0a6a5a2af71f8df695ecbdcfb9139c71d9ef`, rather than moving HEAD.

## Incremental gates (2026-09-24)

Container, Firearm and Melee have passed the synthetic gates: **3/15**.
The other twelve Utilities, UTILITY_ONLY, fallback-wide and registry tests remain
pending. This is not a completed universal-containment implementation.

| Utility | Discovery / metrics | Item scoring boundary | Population protection |
| --- | --- | --- | --- |
| Container | Protected normal discovery; required weighted metrics/directions before admission | Individual V2 score | Reject invalid references before ranks; score references first; rebuild local ranks if a reference fails late |
| Firearm | Protected normal discovery; all eleven active metrics and comparison identity before admission | Components and final score | Rebuild absolute/family anchors after a failed reference; never rescan/recreate items |
| Melee | Protected normal discovery; all nine active metrics before admission | Final V2 score | Remove incomplete profiles before ranks; rebuild local ranks after a failed representative |

The retries are explicit, bounded by reference removals, and local to pure
scoring. They are not exception barriers around the scanner, registry or an
entire Utility batch. They never rerun CandidateDiscovery or OnCreate.
No score formulas, coefficients, tier thresholds or AmmoType relationships were
changed. Healthy controls also match the committed HEAD scorers, not merely a
second run of the new implementation.

Warnings are deduplicated for the Lua session by fullType + stage + reason;
per-scan observations are still counted. ERROR_ISOLATED and PARTIAL are now
distinct counts, unlike the previous inclusive partial counter. Logs expose
state and typed offending values. Errors in global coefficients propagate.

Run `scripts/test-item-isolation.ps1` to execute all three gates using the game's
Kahlua. No mod sync, game-world interaction or InventoryItem construction occurs.

| Primary fixture cohort | ERROR_ISOLATED | PARTIAL | Unsupported | Fatal | Healthy regression | Population contamination |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Container/discovery | 5 | 2 | 0 | 0 | 0 | 0 |
| Firearm | 7 | 12 | 0 | 0 | 0 | 0 |
| Melee | 6 | 9 | 0 | 0 | 0 | 0 |
| Primary cohorts total | 18 | 23 | 0 | 0 | 0 | 0 |

These totals exclude additional fault-injection/replay assertions (late reference
failures, malformed global configuration, warning deduplication and complete
calculate fixtures). They are **test counts**, not counts from the user's world.
Firearm/Melee controls compare all published candidate fields, and Firearm also
compares its full normalization-bound snapshot. Container compares scores,
final tiers, metric percentiles, reference profile count and ranking confidence.

## Implemented

- `UtilityIsolation.lua` is explicitly required by the calculator.
- Normal `calculate` candidate discovery is protected per item; present malformed
  numeric metrics are rejected before joining reference populations. Missing
  values remain missing; strings/booleans/userdata are not converted to zero.
- Container V2 validates global weights outside the local exception boundary.
  Invalid global configuration still throws.
- Container inputs/reference bounds and percentile operands are checked before
  arithmetic. Missing required inputs/ranks defer the whole Utility, rather than
  scoring a reduced denominator or fabricating a percentile.
- Container scoring exceptions are contained per member, with typed values and
  item identity logged. The complete vanilla reference population is preserved.
- Failed candidates cannot execute specific Utility tier policies. Their Utility
  is absent, support is `UTILITY_PARTIAL`, and an independently calculated
  loot-backed Scarcity tier remains the existing fallback. No Scarcity is created.
- The explicit Container audit reports deferred/isolated targets as unresolved,
  rather than counting a successful `pcall` as a successful score.

## Reproduction and tests

Executed using the installed Project Zomboid Kahlua, without InventoryItem
construction or OnCreate callbacks. The complete calculator also compiles under
the engine's local-variable limits.

The unchanged Steam scorer reproduces `nil * 0.35`: capacity 15 lies between
winsorized references 10.5 and 19.5, but exact percentile lookup returns nil.
This does not require a malformed mod property.

`scripts/tests/ItemIsolationProbe.java` executes the actual Container scorer and
the complete `calculate` sequence with a test-only discovery injection. Fixtures:
missing percentile, invalid string, boolean, real Java userdata, missing capacity,
throwing observer, throwing candidate discovery. Results:

| Assertion | Result |
| --- | --- |
| Isolated exceptions across focused fixtures | 5 |
| Partial/deferred items across focused fixtures (excludes exceptions) | 2 |
| Item-induced fatal errors in these fixtures | 0 |
| Container batch completes | yes |
| Complete calculate sequence with malformed Container fixtures completes | yes |
| Healthy control Utilities and final tiers unchanged | yes |
| Global configuration error propagates | yes |
| Real world/full scanner/registry validation | batch 1 A/B approved; see scope above |

The unchanged release repro remains available through `ContainerV2Probe.java`
with its optional Steam source argument. The new source uses containment fixtures.

## Still required before accepting the architectural invariant

- Individually verified boundaries inside the remaining Utility evaluation
  loops (without replacing full reference populations with singleton scoring).
- Coverage of UTILITY_ONLY discovery/augmentation and item-level classification.
- Representative propagation, Fish configuration references and mixed-family
  malformed-input fixtures across all active Utilities.
- Global scanner, route and publisher fault-propagation tests.
- Real-world scan, registry and tier comparison.

A bulk loop transformation was rejected by the safety review due to its size and
an initially missing module load. It was not applied. The module load is fixed;
the broad change remains unapplied. Proceed through smaller reviewed/tested
boundaries before claiming `GLOBAL_SCAN_FATAL_FROM_ITEM_FAILURE = 0`.

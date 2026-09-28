# Final robustness checkpoint

Batch 4 is committed as `1b6ae4c`. Its coverage issues remain separate and open.

## Scope

- Utility-only: isolate ScriptItem identity, per-item discovery/reference preparation and synthetic-row publication. Preserve the existing authorized families (Firearm, Fish, direct Ammo); no new relationship/coverage resolver.
- Scorers retain the previously validated admission/population protections. No unknown Scarcity value or RouteWeighted execution is introduced.
- Fallback: existing isolated-Utility path retains an independently available Scarcity tier and removes Utility. Without tier evidence it leaves the final tier absent, rather than inventing COMMON or zero.
- Registry: validate/copy a row under a local boundary before insertion. Missing/invalid tier, identity, nonfinite/nonserializable values and invalid utility-only provenance omit the row with a deduplicated warning. No all-registry pcall. Invalid global results/sink/storage continue to fail explicitly.

## Controlled checks

`scripts/test-item-isolation.ps1 -Utility final` uses real Kahlua and calls the actual augmentation, fallback and publisher. Healthy Fish augmentation and registry entries are compared with `1b6ae4c`; no pending Ammo/Firearm change is claimed as validated by this oracle. It tests missing Fish metrics, malformed ScriptItem access, invalid registry rows, cycles, unsupported userdata, invalid score types and global storage failure. Final diagnostic A/B is tested with controlled rescans and observer cleanup.

The full prior suite must also pass. No baseline is accepted.

## Approved mixed-working-tree checkpoint; committed-only recheck pending

The approved same-session checkpoint compared 3,573 registry entries, 2 Utility-only Fish and 2,634 fallback entries: zero registry/Utility-only/fallback differences, zero publication omissions, zero global scan fatals and second rescan MATCH. This observation predates extraction of unrelated pending functional changes, so it is NOT automatically a validation of the committed-only deployment.

The 23 late failures were PUBLISHED_FIREARM_REFERENCE_PROXY objects in augmentation, not public result rows. They passed Firearm:ReferenceAdmission and later failed Ammo:FirearmReference for missing firearmAmmoType. Firearm population admission != Ammo reference admission. They were rejected before insertion into the Ammo lookup; no Ammo consumer used them, no existing row changed, and augmentation published zero new firearms. Temporary Firearm calculations were not replacements for published entries and the normalization bounds were restored.

For that checkpoint THIRD_PARTY_EFFECT=no and POPULATION_CONTAMINATION=0 are evidence-based conclusions about published results, not a rewrite of the raw UNKNOWN_LATE_FAILURE diagnostic. No runtime barrier is moved because of this finding. The conclusion is scoped to the observed universe, not every future modset.

Open functional issues, deliberately excluded: AMMO_TEMP_REFERENCE_GAP, LITERATURE_COVERAGE_GAP, EXPLOSIVE_COVERAGE_GAP, INCENDIARY_COVERAGE_GAP, NOISEMAKER_COVERAGE_GAP. Firearm determinism/parser and Ammo functional coverage remain separate. No new global baseline.

## Live test after DEV sync and full restart

Run separately in the same save/modset:

```lua
require "ItemRarity/Diagnostics/BatchComparison"
ItemRarityBatchComparison.runFinal("A")
ItemRarityBatchComparison.runFinal("B")
```

Snapshots are in memory. Whole-registry A/B, Utility-only and fallback differences are reported separately. This is patched-runtime repeatability, not historical PRE/POST. Fixtures establish healthy preservation. Late admitted failures remain UNKNOWN for population contamination rather than a fabricated pass. Publication omissions are reported separately and must be inspected before approval.

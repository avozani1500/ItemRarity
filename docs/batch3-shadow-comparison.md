# Batch 3 controlled shadow comparison

Explicit DEV-only entry: `ItemRarityBatch3Shadow.run()`.

`scripts/build-batch3-shadow.cjs` generates both evaluator factories from the
current complete UtilityCalculator. PRE replaces only eight batch-3 function
blocks with their pre-hardening bodies; POST uses the current bodies. PRE uses
the previous Isolation module. Pending Firearm/Ammo changes remain in the source.
The generator records both source hashes and names every restored block.

Scope: same already-built candidate facts, four Utility scoring paths, public
candidate fields and final-tier application. This is NOT a historical world boot
or a second candidate-discovery execution. Builder admission is separately tested
by fixtures. The shadow entry never calls calculate, augmentation, a builder,
RegistryPublisher, OnCreate or RouteWeighted. Its environment has no engine APIs.

One normal current scan captures candidates and finalized firearm references.
Loot-backed and augmentation reference populations are kept separate. In
particular, the augmentation's empty AmmoType proxies remain empty on BOTH sides;
no coverage fix is smuggled into PRE or POST. Fishing configuration and skill
limits are cloned identically. Each evaluator receives independent Lua copies.

The output includes PRE/POST field differences, candidate states/membership,
Fish reference-metrics comparison, and POST shadow versus actual scanner output.
The latter must be zero before the replay can be trusted. LitE/LitS rows are
included for comparison without changing their classifier or admission.

Unpublished augmentation candidates remain in both input cohorts, represented
as registry absence when no tier is produced. A dedicated fixture verifies that
neither evaluator nor the driver creates a real row for such an item.

Invalid facts, a collision with an existing loot-backed row, inaccessible facts, an
evaluator exception or any POST-versus-real mismatch blocks approval. No numeric
defaults or forced tiers repair a replay mismatch. No automatic commit is made.

The generated file and driver live under Diagnostics and are excluded from release.
The generator does not overwrite production modules. Test:
`scripts/test-item-isolation.ps1 -Utility batch3-shadow`.

Current status (2026-09-26): controlled harness PASS; two live-world shadow runs
PASS. 417 entries compared, all five registry delta counters zero, healthy diff
zero, POST-versus-real zero, population membership/Fish references unchanged,
global fatals zero; SECOND_RESCAN=MATCH. Batch-3 hardening approved. No global
baseline accepted and neither preexisting coverage issue was fixed.

# Release candidate audit — 1.0.0-rc1

Audit date: 2026-09-10. This record is an audit of the currently loaded
universe, not a promise that every enabled-mod combination has the same
signature.

## Deterministic runtime check

| Check | Result |
| --- | --- |
| Active availability model | Strategy D / RouteWeighted |
| First final scan | `339579:1646489189:664133968` |
| Second manual rescan | `MATCH` |
| Published types | 3,505 (3,414 Base, 91 modded) |
| Loot occurrences | 100,820 |
| Registry revision | 34 |
| Known warning | one pre-existing malformed item/weight pair |
| New Lua errors observed | none |

The previous `339555:1192322902:548244541` baseline predates the final
Clothing V2 profile-key, LIMB_LOWER and FULL_BODY integrations. The current
signature is the correct post-closure baseline for this loaded universe.

## Timing check

| Segment | Scan A | Scan B |
| --- | ---: | ---: |
| Route collection | 23 ms | 23 ms |
| Table scan | 690 ms | 800 ms |
| Exposure | 250 ms | 272 ms |
| Availability / Strategy D | 4,504 ms | 4,573 ms |
| Total pipeline | 5,467 ms | 5,668 ms |

There is no coarse performance regression against the approximately 5.7 s
historical manual-scan baseline. Development reports were disabled in both
scans.

## Invariant review

- Strategy D is the only active availability calculation; A/B/C are explicit
  development comparisons.
- The host publishes `FinalRarityTier`; client presentation reads the registry
  and does not calculate Scarcity or Utility.
- Registry snapshots are explicit (`snapshot` command) and are not written by
  `rescan()`.
- Diagnostic modules are loaded only by explicit diagnostics or by the
  disabled `devReportsEnabled` path; normal scans do not load reports or write
  files.
- Functional rules use structural/runtime data. Full-type lists retained in
  source are validation/report targets or declared compatibility metadata, not
  per-item tier rules.
- Clothing profile keys include every raw attribute used by the score, so a
  deduplicated representative cannot propagate incompatible attributes.
- Cosmetic accessory and Clothing trivial ceilings are structural. The five
  unresolved accessory roles remain conservative architectural limitations.

## Manual smoke matrix

The following presentation paths were visually verified during RC work:
inventory coloring, tooltip border/footer idempotence, UI options, Clean UI,
and Clean HotBar overlay geometry. They require one final gameplay pass after
packaging because a game window was not available to automation in this audit
session.

| Scenario | Status for final gameplay pass |
| --- | --- |
| Vanilla-only new world | pending manual pass |
| Modded existing save | pending manual pass |
| LB / LK / LTW loaded | deterministic scan passed; visual smoke pending |
| Clean UI | previously verified; final package pass pending |
| Clean HotBar | previously verified; final package pass pending |
| UI options ON/OFF | previously verified; final package pass pending |
| Inventory cache / tooltip repeated renders | previously verified; final package pass pending |

## Result

```text
RELEASE_BLOCKER = 0
REGRESSION      = 0
KNOWN_LIMITATION = 5 accessory roles with intentionally unresolved bridge data
CLEAN           = deterministic pipeline, registry and static UI architecture
```

`Item Rarity 1.0.0-rc1` is ready for final gameplay validation.

# Cleanup baseline — 2026-08-14

This is the functional baseline recorded before the runtime/diagnostics cleanup.
Every cleanup phase must preserve these outputs unless it stops and explains a
real dependency change.

| Signal | Baseline |
|---|---:|
| Item types | 3416 (3368 Base, 48 modded) |
| Loot occurrences | 97818 |
| Procedural distributions | 1420 |
| Static distributions | 826 |
| Registry/result signature | `335860:840511515:2147432102` |
| Manual rescan time | 5702 ms |

## Final tier distribution

| Tier | Items |
|---|---:|
| Common | 1185 |
| Uncommon | 993 |
| Rare | 1178 |
| Epic | 48 |
| Exotic | 12 |

## Required sentinels

- `Base.Katana`: `RARE` Scarcity, WeaponUtility V2 `73.44`, percentile `96.94`, `HIGH`, Final `EPIC`.
- `Base.HollowBook_Handgun`: `EXOTIC` Scarcity, `UTILITY_UNSUPPORTED`, Final `RARE`.
- Clothing final: Common `147`, Uncommon `139`, Rare `151`, Epic `9`, Exotic `4`.
- `Base.Cuirass_Metal`: `EPIC`.
- `Base.Vambrace_Left`: `EXOTIC`.
- `Base.Shoulderpad_Articulated_L_Metal`: `EXOTIC`.
- `Base.Shirt_Crafted_Burlap`: `RARE`.
- `Base.Shoes_WorkBoots`: `UNCOMMON`.

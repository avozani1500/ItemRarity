# Release polish — 1.0.0

This checklist covers presentation and packaging only. It must not change
Scarcity, Utility, `FinalRarityTier`, registry publication, or the structural
baseline.

## UI review

| Area | Current state | Recommendation | Release status |
|---|---|---|---|
| Inventory names | Registry-only color lookup; pane-local cache; COMMON can remain vanilla. | Keep. | KEEP |
| Tooltip | Additive border and idempotent footer. Hotbar uses a border only to avoid B42 measurement overlap. | Keep. | KEEP |
| Hotbar | Additive post-render overlay with vanilla and Clean HotBar geometry paths. | Keep. | KEEP |
| Options | Five client-only toggles, persisted through Mod Options. | Group under **Visuals** and use concise labels. | POLISH |
| Palette | One shared visual definition for all UI paths. Green/blue/purple/gold remain distinct on dark inventory and tooltip backgrounds. | No preset or custom-color UI for 1.0. | KEEP |
| Tier preview | Mod Options exposes titles, descriptions and controls, but no verified clean custom-color preview API. | Do not create a custom renderer. | DEFER_1_1 |

Clean UI and Clean HotBar are optional compatibility paths, not dependencies.
The presentation layer only looks up published registry data and never scans,
scores, or derives a tier during rendering.

## Localization

English and Brazilian Portuguese resources cover:

- tier labels;
- the tooltip rarity label;
- Mod Options title, section, descriptions and all five options.

The internal identifiers `COMMON`, `UNCOMMON`, `RARE`, `EPIC`, and
`EXOTIC` remain canonical. Adding another language means adding the same keys
in that language's B42 `Translate/<locale>/ItemRarity.json`; no Lua logic
should be changed.

## Steam Workshop copy

**Short description**

> Adds structural COMMON, UNCOMMON, RARE, EPIC and EXOTIC item tiers to Project
> Zomboid Build 42.20.2. Rarity is calculated from final loaded loot tables and
> category-specific runtime Utility, with optional inventory, tooltip and
> hotbar visuals.

## Manual screenshots

1. **Inventory overview** — player inventory plus an opened container; show
   COMMON alongside all four colored tiers.
2. **Tooltip** — a non-COMMON item with the colored border and `Rarity` footer
   fully visible.
3. **Hotbar** — occupied slots with at least three tiers; show the small
   marker and border aligned to slots.
4. **Options** — Options > Mods > Item Rarity, with the **Visuals** section
   and all five toggles visible.
5. **Vanilla item** — a recognizable vanilla item, its name color, and its
   tooltip.
6. **Modded item** — a loaded-mod item with a published tier in an inventory
   pane.
7. **Tier comparison** — five otherwise unobstructed items or tooltip shots
   demonstrating COMMON through EXOTIC in order.

## Package proposal

**Allowlist**

- `42.20/` and `common/` runtime media;
- `42.20/mod.info` and `42.20/poster.png`;
- required `Translate/EN` and `Translate/PTBR` JSON resources;
- optional release-facing `README.md`, `CHANGELOG.md`, and selected `docs/`.

**Do not package**

- `.git/`, `.codex/`, editor/IDE folders and local backups;
- `Zomboid/Lua/ItemRarity_*.txt` or `ItemRarity_*.tsv` reports;
- generated snapshots, profiler output, dumps and temporary files;
- development source outside the B42 package roots, unless a separate
  development-source archive is intentionally published.

Diagnostics may remain in the source repository. They are excluded from normal
gameplay because each is required and run only by an explicit development
command; none should create reports during a normal scan or UI render.

## Deferred 1.1 decisions

| Area | 1.0 decision | Reason |
|---|---|---|
| ToolUtility | Do not integrate. | Tags/lifecycle identify candidates, but cannot measure action breadth, alternatives or world opportunities; combining with WeaponUtility risks double-counting. |
| CraftingValue | Do not integrate. | `CraftRecipe` enumeration is available, while reliable Input/Output/Tool relationships and action conditions are not. |

Both are known bridge limitations, not reasons to introduce per-item rules.

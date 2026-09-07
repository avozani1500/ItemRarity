# Changelog

## 1.0.0-rc1

First release candidate for Project Zomboid Build 42.20.2.

### Release preparation

- Removed the public `Experimental` label and set the mod version to
  `1.0.0-rc1`.
- Added release README documentation for structural Scarcity, category Utility,
  sandbox/difficulty behavior, optional UI compatibility, and limitations.
- Added client-side presentation options through the built-in B42 Mod Options
  system, including PT-BR and English UI text.
- Kept Clean UI and Clean HotBar integration optional and load-order resilient.

### Runtime/diagnostic separation

- Removed `LightFireClientAudit` from the normal client registry load path.
- Removed automatic RegistrySnapshot writes from `ItemRarity.rescan()`.
- Snapshot generation remains available only through its explicit development
  command.

### Compatibility baseline

- Functional baseline: `365586:746779767:1457786657`.
- Expected published registry: `3416` item types and `97818` loot occurrences.

### Known limitations

See the **Known limitations** section in `README.md`. Unsupported or
partially-observable effects remain on the structural fallback rather than
receiving guessed mechanical Utility.

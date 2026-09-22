# Item Rarity development workflow

## Source of truth

`C:\Users\Natan\Documents\ItemRarity_DEV` is the only editable source of truth. The active development branch is `develop/1.1`.

Never make a functional edit directly in an installed mod, a release folder or a Workshop staging folder. The legacy checkout at `C:\Users\Natan\Documents\GitHub\item-rarity` is not an active development source and must not be used for new work.

## Directory roles

| Directory | Role |
| --- | --- |
| `C:\Users\Natan\Documents\ItemRarity_DEV` | Canonical repository: code, diagnostics, audits, documentation and scripts. |
| `C:\Users\Natan\Zomboid\mods\ItemRarity_DEV` | Disposable local test installation, synchronized from the repository. |
| `release\ItemRarity-*` | Generated distributable package; never edited as a source. |
| `C:\Users\Natan\Zomboid\Workshop\ItemRarity` | Workshop staging/upload wrapper; never a development source and never published automatically. |

## Synchronization rule

The only supported direction is: `REPOSITORY -> DEV INSTALLATION -> TEST`.

Run `scripts\sync-dev.ps1 -Check` before a synchronization and `scripts\sync-dev.ps1 -Apply` only after reviewing the repository state. The DEV installation must not contain unique edits. If it does, do not copy them back automatically: stop, compare and report the divergence before changing anything.

## Diagnostics and release packaging

Diagnostics and audits belong in the repository under `42.20\media\lua\server\ItemRarity\Diagnostics`. They must be explicit development commands only: no automatic scans, writes, reloads or runtime side effects. `scripts\build-release.ps1` excludes that directory and all source documentation/tooling from the distributed package.

Build a release only from the canonical repository. Workshop staging receives a copy of a generated package plus its Workshop metadata and preview asset; it is not a place to fix code or metadata ad hoc.

## Divergence safety rule

If any unexpected difference exists among the repository, DEV installation, release package or Workshop staging, stop and report it before editing. Never apply unrelated hunks independently to multiple copies.

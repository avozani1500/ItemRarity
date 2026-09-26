# Open functional issues — excluded from batch 3 containment

## AMMO-TEMP-REFERENCE — OPEN

Augmentation constructs temporary loot-backed firearm references through the
legacy string reader instead of the already-resolved FirearmCandidate key.
Absent runtime becomes the string `nil`, canonicalized to an empty key.
The old inheritance pass silently skipped it; containment reports the deferral.
The observed 23 keys are recoverable in simulation, not 23 proven new ammo items.

Future isolated change: reuse the resolved candidate AmmoType while preserving
exact-key compatibility and maximum published firearm tier. Shared readString,
Magazine, WeaponPart and ammo boxes stay outside this issue. No fix included.

## LITERATURE-DISPLAY-CATEGORY — OPEN

The unchanged classifier recognizes SkillBook/Literature, not observed LitE/LitS.
Exact lookup succeeds for Book, Magazine, BookCarpentry1 and BookFirstAid1, but
their display categories produce UNKNOWN before the Literature builder reads
mechanical fields. BookPotterySet uses SkillBook and reaches SPECIAL_PARTIAL.

Future independent investigation must validate structural admission without
name/fullType rules. No classifier or coverage change is included here.

## Acceptance evidence

These issues do not by themselves disqualify containment. They remain open if
hardening is approved. However, zero healthy observations cannot establish
preservation: admitted fixtures and real-registry PRE/POST evidence are separate
requirements. POST/POST equality is not historical PRE/POST equality.

Controlled batch-3 tests now use calculator AND isolation from d660f37 as PRE.
Ammo: two healthy controls unchanged; missing/empty/boolean/userdata firearm
references isolated without changing the valid control. Literature: five healthy
policies plus SPECIAL_PARTIAL preserved; existing SkillBook classification tested,
LitS deliberately remains UNKNOWN. Magazine and Fish fixtures also pass.

No full historical PRE registry snapshot was available. Therefore acceptance
used the subsequently authorized controlled shadow: current state minus only
batch-3 containment versus current state, on identical captured inputs. Two
real-world runs compared 417 entries with zero registry/Utility/score/tier or
population differences, zero POST-versus-real differences, zero fatals and a
second rescan MATCH. Batch-3 hardening is approved; both functional issues above
remain OPEN. No global baseline was accepted.

---
phase: requirements
title: Requirements & Problem Understanding
description: M3 — Dirac, the listening modes, lip sync and macros
---

# Requirements & Problem Understanding — M3

M1 (control) and M2 (feedback) are merged and working on hardware. M3 adds the unit's processing
controls to Control4 programming, and ships alongside the Documentation tab already on this branch.

## In scope

| # | Requirement | MSO path | Domain |
|---|---|---|---|
| R1 | Dirac on / off / bypass | `/cal/diracactive` | `"off"` / `"on"` / `"bypass"` |
| R2 | Select the Dirac filter slot | `/cal/currentdiracslot` | integer, six slots |
| R3 | Loudness on / off / toggle | `/loudness` | `"off"` / `"on"` |
| R4 | Night mode off / auto / on | `/night` | `"off"` / `"auto"` / `"on"` |
| R5 | Dialog Enhance level | `/dialogEnh` | integer 0–6 |
| R6 | Bass Enhance on / off / toggle | `/bassenhance` | `"off"` / `"on"` |
| R7 | Lip-sync delay | `/cal/lipsync` **and** the current input's delay | integer 0–340 ms |
| R8 | Run one of the unit's stored macros | `/svronly/<slot>` replayed as `changemso` | slot keys with user names |
| R9 | Report all of the above as variables, and keep the Documentation tab current | — | — |

All values confirmed against both live units and the vendor's own web client.

## Decisions taken before planning

**Loudness goes through the proxy, not only through programming.** The `receiver` proxy natively
defines `LOUDNESS_ON`, `LOUDNESS_OFF` and `LOUDNESS_TOGGLE` — confirmed in its command vocabulary —
so loudness becomes a real room-UI control rather than a programming-only command. This flips
`has_discrete_loudness_control` and `has_toggle_loudness_control` to `True`, which the M1 design
explicitly deferred to M3 on the grounds that a declared capability with no handler is a dead button.
The handlers now exist, so the flags may move.

**Lip sync writes two paths, not one.** The vendor's own `setLipsyncDelay` writes `/cal/lipsync`
*and* `/inputs/<current input>/delay` together. Writing only the first would leave the driver
disagreeing with the unit's own display for the selected input. The driver matches the vendor.

**Macros are exposed as a dynamic list.** The unit stores macros in fixed slots (`cmda`–`cmdd`,
`preset1`–`preset4`, `cmdcustom1`–`cmdcustom16`) with names the owner sets, in
`/svronly/macroNames`. A `DYNAMIC_LIST` property populated by `C4:UpdatePropertyList` shows the real
names, and a command runs the selected one. Chosen over a fixed list of slot keys on 2026-08-05
because a key like `cmdb` tells an installer nothing, and the names track renames on the unit.

**A macro is executed by replaying its stored operations.** `/svronly/<slot>` holds an array of
JSON-patch operations; the unit has no "run macro" verb. This is exactly what the vendor's web client
does. The driver sends the stored operations as one `changemso`.

## Out of scope

- Editing or creating macros. The driver replays what the unit stores; authoring belongs to the
  unit's own UI.
- Loudness calibration and curve (`/loudnessCal`, `/loudnessCurve`), speaker configuration, PEQ, bass
  management, Dirac filter transfer. The unit's UI owns these.
- Anything requiring a write the owner has not sanctioned on the live units.

## Constraints

Unchanged and still binding:

- Lua 5.1; no `bit` library; no `\x` escapes.
- **No polling.** Every new control is a write on demand and a read from pushes already handled.
- Debug logging off by default; caught errors always logged with a traceback.
- **Privacy, with a new hazard.** Dirac slot names are site data — one unit's slots carry names its
  owner chose. Macro names are site data for the same reason. They may pass through the driver at
  runtime and appear in Composer, but must never enter a fixture, a test, a doc or a commit message.
- Connection ids, property names and variable names already in the field are a compatibility
  contract. `POWER_STATE` remains off-limits: it belongs to the proxy.

## Success criteria

With the driver bound in a real room: each control changes the unit and the corresponding variable
follows; changing the same setting on the unit's front panel updates Control4 without a command;
loudness appears in the room UI and works from it; the macro list shows the owner's real macro names
and the selected one runs; and the Documentation tab describes every new property, command and
variable — enforced by the test added with the Documentation tab, which fails if anything
user-facing ships undocumented.

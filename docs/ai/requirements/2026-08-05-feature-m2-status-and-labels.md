---
phase: requirements
title: Requirements & Problem Understanding
description: M2 — read-only status feedback, driver events, and input labels
---

# Requirements & Problem Understanding — M2

M1 shipped as v1.0.1 and is working on hardware: the driver arrives in a room unbound, and volume and
mute feedback reach Navigator and the handheld remotes.

M2 adds what Control4 programming and touchscreens can *read* from the unit, and settles what can be
done about the unit's own input labels.

## In scope

| # | Requirement | Acceptance |
|---|---|---|
| R1 | Expose the unit's decode and encode status as driver variables | Surround mode, decoded source program and format, encoded listening format, and sample rate are readable in programming and update when the unit changes |
| R2 | Expose video status as driver variables | Resolution, colour space and HDR status |
| R3 | Expose core state as driver variables | Power, input id, input label, volume in dB and percent, mute, surround mode, connection state |
| R4 | Fire driver events on real transitions | Connected, Disconnected, Powered On, Powered Off, Input Changed, Surround Mode Changed — each only on an actual change, never on a redundant push |
| R5 | Report the unit's input labels | A Composer action lists every input with the unit's own label and whether the unit considers it visible |

## Out of scope, and why

**Renaming Control4's inputs from the unit's labels.** The original design (M1, R11) said Control4
input names would follow the unit's labels. That is not achievable. Confirmed by extracting the
`receiver` proxy's full command vocabulary from `receiver.c4d.dll`: it has `SET_INPUT`, `INPUT_SET`,
`INPUT_TOGGLE`, `CURRENT_INPUT`, `GetInputs`, `LoadInputs` and `GetOutputName`, but no command that
lets a driver set an input's name. Input names come from `<connectionname>` in `driver.xml`, and the
DriverWorks API has no rename call — a scan of all 148 shipped drivers in the local library found
only `C4:AddDynamicBinding`, which names a binding at creation.

Switching the inputs to dynamic bindings would allow true auto-naming, but it replaces the static
connections and every source in the working install would have to be re-bound. Rejected by the owner
on 2026-08-05 in favour of reporting the labels so they can be applied by hand.

**Hiding inputs the unit marks invisible.** Same reason: `<hidden>` is static XML and there is no
runtime equivalent. Visibility is reported, not enforced.

**Everything in M3** — Dirac, loudness, night, dialog enhance, bass enhance, lip sync and macros.

## Constraints

Unchanged from M1, and all still binding:

- Lua 5.1 dialect; no `bit` library; no `\x` escapes.
- No polling. The variables are updated from the pushes the driver already receives — M2 must not add
  a single request to the wire.
- Debug logging off by default; caught errors always logged with a traceback.
- Privacy: no real identifiers anywhere in the repository. Note that **input labels and the unit name
  are site data** — they may pass through the driver at runtime but must never enter a fixture, a
  test, a doc or a commit message.
- Connection ids and property names already in the field are a compatibility contract.

## Success criteria

With the driver bound in a real room: every variable in R1–R3 is visible in Composer programming and
carries a correct value; changing the source on the unit's front panel updates the format and
resolution variables without a Control4 command; the events in R4 fire once per real transition; and
the Composer action prints each input with the unit's label and visibility.

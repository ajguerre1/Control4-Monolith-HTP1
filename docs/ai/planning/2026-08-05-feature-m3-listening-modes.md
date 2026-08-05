---
phase: planning
title: Project Planning & Task Breakdown
description: Task-by-task plan for M3 — Dirac, listening modes, lip sync and macros
---

# M3 Implementation Plan — Dirac, listening modes, lip sync and macros

Four tasks on the `feature-m3` branch, which already carries the Documentation tab.

## Global Constraints

- **Lua 5.1 only.** `unpack` exists, `table.unpack` does not. No `goto`, no `\x` escapes, no integer
  division.
- **No `bit` library.**
- **No polling.** Every control is a write on demand; every reading comes from pushes already handled.
- **Privacy, and M3 is the milestone where this bites.** Dirac slot names and macro names are site
  data — real names the owner chose, sitting in the document the driver already reads. They may reach
  Composer at runtime but must never enter a fixture, a test, a doc or a commit message. Invented
  fixture names only.
- **Compatibility.** Connection ids, property names and variable names in the field are a contract.
  `POWER_STATE` is the proxy's; ours is `UNIT_POWER`.
- **The documentation test will fail** the moment a new property, action, variable or event ships
  without a mention in `www/documentation/index.html`. Update the page in the task that adds the
  thing, not at the end.
- `luajit` is on PATH; run `luajit tests/run.lua`. Issue commands standalone, never `cd "..." && ...`.
- Composer sends actions as `ExecuteCommand("LUA_ACTION", { ACTION = "<command>" })`. Programming
  commands declared in `<commands>` arrive as `ExecuteCommand("<command name>", tParams)`. **Verify
  the real shape of any new entry point against shipped drivers before writing its test** — a test
  that invokes an entry point the way the implementation expects proves nothing about whether the
  platform will ever reach it. That mistake shipped three dead actions through two releases.

---

### Task 1: Project and expose the processing state

**Files:** `htp1/state.lua`, `tests/fixtures.lua`, `tests/test_state.lua`, `driver.lua`,
`tests/test_driver.lua`, `www/documentation/index.html`

State fields to add, all from paths the unit already pushes:

| field | path | domain |
|---|---|---|
| `loudness` | `/loudness` | `"off"` / `"on"` |
| `night` | `/night` | `"off"` / `"auto"` / `"on"` |
| `dialogEnhance` | `/dialogEnh` | integer 0–6 |
| `bassEnhance` | `/bassenhance` | `"off"` / `"on"` |
| `diracSlot` | `/cal/currentdiracslot` | integer |
| `lipSync` | `/cal/lipsync` | integer 0–340 |

`diracState` (`/cal/diracactive`) already exists from M2.

- [ ] Add the six paths to `SCALAR_PATHS`. `/cal` is already a container prefix; `/loudness`,
      `/night`, `/dialogEnh` and `/bassenhance` are top-level scalars needing no new prefix.
- [ ] Extend both fixtures. The modern fixture already carries `loudness`, `night`, `dialogEnh` and
      `bassenhance` as unused keys — they become tracked, so check the existing values still make
      sense. Add `cal.lipsync` and `cal.slots`.
- [ ] **`cal.slots` is an array of six objects each with a `name`, and those names are SITE DATA.**
      Track slot *names* so the Dirac slot list can show them, but every fixture name must be
      invented — "Slot 1", "Calibrated", "Flat". Never copy a real one.
- [ ] Add the matching variables: `LOUDNESS`, `NIGHT_MODE`, `DIALOG_ENHANCE`, `BASS_ENHANCE`,
      `DIRAC_SLOT`, `LIP_SYNC_MS`. They join the existing `VARIABLES` table, so creation and update
      come free.
- [ ] Document all six in the Documentation tab's variable table.
- [ ] Tests: each field projects; a targeted push updates only its own variable; a `/cal` container
      replace re-derives the two under it; an absent field leaves the variable empty rather than
      inventing a value.
- [ ] `luajit tests/run.lua` green, then commit.

---

### Task 2: Loudness through the proxy, and the simple mode commands

**Files:** `driver.xml`, `htp1/proxy.lua`, `driver.lua`, `tests/test_proxy.lua`,
`tests/test_driver.lua`, `tests/test_manifest.lua`, `www/documentation/index.html`

**Loudness is a proxy control.** The `receiver` proxy defines `LOUDNESS_ON`, `LOUDNESS_OFF` and
`LOUDNESS_TOGGLE`. Handle them in `htp1/proxy.lua` alongside the mute handlers and flip
`has_discrete_loudness_control` and `has_toggle_loudness_control` to `True`.

**The rest are programming commands**, declared in `<commands>`:

| Command | Param |
|---|---|
| Set Dirac | LIST: Off / On / Bypass |
| Set Night Mode | LIST: Off / Auto / On |
| Set Dialog Enhance | RANGED_INTEGER 0–6 |
| Set Bass Enhance | LIST: Off / On |
| Toggle Bass Enhance | none |
| Set Lip Sync Delay | RANGED_INTEGER 0–340 |

- [ ] Declare the commands in `driver.xml` with `<name>`, `<description>` and `<params>`, following
      the shape shipped drivers use (`RANGED_INTEGER` carries `<minimum>` and `<maximum>`).
- [ ] **Confirm how a programming command reaches the driver before writing its test.** Check shipped
      drivers that declare `<commands>` and see what `ExecuteCommand` receives — the command name, or
      something else, and how parameters are keyed. Write the test against what the platform actually
      sends.
- [ ] Lip sync writes BOTH `/cal/lipsync` and `/inputs/<current input>/delay`, matching the vendor's
      own client. Skip the per-input write when no input is known rather than writing to a nil key.
- [ ] Reject out-of-domain values rather than passing them through: the unit is the authority, but a
      command that sends nonsense earns a log line, not a silent write.
- [ ] Document every command, and move the loudness note in the docs from "not yet" to how it works.
- [ ] Tests: each command writes the right path and value; loudness works from the proxy; an
      out-of-range value is refused; lip sync writes both paths and only one when no input is known;
      the manifest test gains a check that every declared command has a handler.
- [ ] Green, then commit.

---

### Task 3: Dirac slot selection

**Files:** `driver.xml`, `driver.lua`, `tests/test_driver.lua`, `www/documentation/index.html`

The unit exposes six filter slots, each with a name the owner set. Selecting one is
`/cal/currentdiracslot`.

- [ ] A `DYNAMIC_LIST` property, **Dirac Filter**, populated with `C4:UpdatePropertyList` from the
      slot names the unit reported, showing the slot number where a slot has no name.
- [ ] Repopulate whenever the slot names change, and select the entry matching
      `/cal/currentdiracslot` so the property reflects the unit rather than drifting.
- [ ] Changing the property writes the slot; a change from the unit updates the property. Guard
      against the loop that pattern invites — a write that comes back as a push must not be treated
      as a fresh user action.
- [ ] A `Set Dirac Slot` programming command taking a RANGED_INTEGER, for programming that wants a
      slot by number rather than by name.
- [ ] Tests: the list is populated from the unit; an unnamed slot still appears; selecting writes the
      right slot; a push from the unit moves the property without writing back.
- [ ] Green, then commit.

---

### Task 4: Macros

**Files:** `htp1/state.lua`, `driver.xml`, `driver.lua`, `htp1/session.lua` (if a multi-op write
needs it), tests, `www/documentation/index.html`

The unit stores macros in fixed slots — `cmda`–`cmdd`, `preset1`–`preset4`,
`cmdcustom1`–`cmdcustom16` — each an array of JSON-patch operations, with names in
`/svronly/macroNames`. There is no "run macro" verb: running one means replaying its operations,
which is what the vendor's client does.

- [ ] Track `/svronly/macroNames` and the stored operation arrays. **Both are site data** — invented
      names only in fixtures.
- [ ] A `DYNAMIC_LIST` property, **Macro**, listing the macros the unit actually has, by name.
- [ ] A `Run Selected Macro` action, and a `Run Macro` programming command taking the macro name.
- [ ] Running one sends its stored operations as a single `changemso`. Check `Session:write`
      coalesces by path — a macro touching several paths must send them all, and a macro touching one
      path twice must send the later value only.
- [ ] A macro whose slot is empty, or whose name does not exist, logs and does nothing. It must not
      send an empty `changemso`: an empty array encodes as `{}` rather than `[]` and the unit rejects
      it.
- [ ] Document the macro list, the action and the command, and say plainly that the driver replays
      what the unit stores and cannot author macros.
- [ ] Tests: the list reflects the unit; running sends the stored operations; an empty or unknown
      macro sends nothing and says why; a macro with two operations on one path sends the last.
- [ ] Green, then commit.

---

## Exit criteria

- [ ] `luajit tests/run.lua` green, real output in the implementation doc.
- [ ] `powershell -File tools/build-c4z.ps1` builds; 12 entries; `auto_update: false`.
- [ ] `driver.xml` version `104` (already bumped with the Documentation tab).
- [ ] The documentation test passes, which means every new property, command and variable is written
      up.
- [ ] Owner-verified on hardware: each control moves the unit; each reads back; loudness works from
      the room UI; the Dirac and macro lists show the owner's real names.

## Not in M3

Editing macros, loudness calibration and curve, speaker configuration, PEQ, bass management and
Dirac filter transfer. The unit's own UI owns all of them.

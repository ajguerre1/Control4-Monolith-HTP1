---
phase: planning
title: Project Planning & Task Breakdown
description: Task-by-task plan for M2 — status variables, events, and input labels
---

# M2 Implementation Plan — status, events and input labels

Three tasks on top of v1.0.1. Small compared with M1: no new transport, no new protocol, no new
proxy commands. Everything M2 reports comes from pushes the driver already receives.

## Global Constraints

Unchanged from M1 and still binding:

- **Lua 5.1 dialect only.** `unpack` exists, `table.unpack` does not. No `goto`, no `\x` escapes, no
  integer division.
- **No `bit` library.**
- **No polling, and no new requests.** M2 must not add a single message to the wire. Every value comes
  from the `mso` document and the `msoupdate` pushes already being handled.
- **Privacy.** Input labels and the unit name are site data. They may pass through the driver at
  runtime but must never enter a fixture, a test, a doc or a commit message. Fixtures use invented
  labels only.
- **Compatibility.** Connection ids and existing property names are a field contract — the driver is
  installed and working.
- `luajit` is on PATH; run the suite as `luajit tests/run.lua`. Issue commands standalone, never as
  `cd "..." && ...`, which does not match the permission allowlist.

## What the unit actually reports

Read from both live units. `status` carries:
`SurroundMode`, `DECSourceProgram`, `DECProgramFormat`, `DECSampleRate`, `ENCListeningFormat`,
`ENCSampleRate`, `DiracState`, and **`raw`**. `videostat` carries `VideoResolution`,
`VideoColorSpace`, `HDRstatus`, `VideoMode`, `VideoBitDepth`, `Video3D`.

**Track the named leaves, not `/status/*` as a wildcard.** The M1 design wrote the whitelist as
`/status/*` and `/videostat/*`; `status.raw` is a large nested object of decoder internals, and
mirroring it would undo the projection principle the whole state layer exists for.

---

### Task 1: Project the status and video fields

**Files:** `htp1/state.lua`, `tests/fixtures.lua`, `tests/test_state.lua`

**Produces:** these `state.fields` entries, all strings —
`surroundMode`, `decSourceProgram`, `decProgramFormat`, `decSampleRate`, `encListeningFormat`,
`encSampleRate`, `diracState`, `videoResolution`, `videoColorSpace`, `videoHdr`.

- [ ] Add each to `SCALAR_PATHS` under its JSON pointer (`/status/SurroundMode`,
      `/status/DECSourceProgram`, `/status/DECProgramFormat`, `/status/DECSampleRate`,
      `/status/ENCListeningFormat`, `/status/ENCSampleRate`, `/status/DiracState`,
      `/videostat/VideoResolution`, `/videostat/VideoColorSpace`, `/videostat/HDRstatus`).
- [ ] Add `"/status"` and `"/videostat"` to `CONTAINER_PREFIXES`, so a wholesale replace of either
      container re-derives everything beneath it — the unit does send container replaces.
- [ ] Extend both fixtures with a `status` and `videostat` block. **Include a `raw` sub-table in
      `status`** so a test can prove it is ignored.
- [ ] Tests: every field projects from a document; a targeted `msoupdate` on one status leaf updates
      only it; a container replace of `/status` re-derives; **`/status/raw/...` operations are
      ignored and `state.fields.raw` never exists**; an absent `videostat` leaves the fields nil
      rather than erroring.
- [ ] Run `luajit tests/run.lua`, green, then commit.

---

### Task 2: Variables and events

**Files:** `driver.xml`, `driver.lua`, `tests/test_driver.lua`, `tests/test_manifest.lua`

**Variables**, created once at init with `C4:AddVariable(name, value, "STRING")` and updated from the
existing change set. All strings, so Composer sees consistent types:

`CONNECTED`, `POWER_STATE`, `INPUT_ID`, `INPUT_LABEL`, `VOLUME_DB`, `VOLUME_PERCENT`, `MUTED`,
`SURROUND_MODE`, `INPUT_FORMAT`, `INPUT_PROGRAM`, `INPUT_SAMPLE_RATE`, `OUTPUT_FORMAT`,
`OUTPUT_SAMPLE_RATE`, `VIDEO_RESOLUTION`, `VIDEO_COLORSPACE`, `VIDEO_HDR`, `DIRAC_STATE`.

`SURROUND_MODE` takes the unit's own `status.SurroundMode` text, which is richer than the Control4
surround id — it reads "Native Dolby ATMOS" where the proxy only knows "Dolby Surround".

**Events**, declared in `driver.xml` and fired with `C4:FireEvent(name)`:

| id | name |
|---|---|
| 1 | Connected |
| 2 | Disconnected |
| 3 | Powered On |
| 4 | Powered Off |
| 5 | Input Changed |
| 6 | Surround Mode Changed |

- [ ] Declare the six events in `driver.xml`, following the shipped `<events><event><id><name>
      <description>` shape.
- [ ] In `driver.lua`, add a variables module-level table mapping variable name → a function of
      `state` returning its string value, so creation and update share one definition and cannot
      drift apart.
- [ ] Create every variable at init with its current value, so Composer never shows a variable that
      does not exist yet.
- [ ] Update from `onChanges`: only variables whose value actually changed get written. Fire the
      matching events on the same transitions.
- [ ] `Connected` / `Disconnected` fire from the existing `onConnected` callback, not from the change
      set.
- [ ] Tests: every declared variable exists after init; a document updates them; an `msoupdate` on a
      status field updates the matching variable and nothing else; each event fires exactly once on
      its transition and **not** on a redundant push; the manifest test gains a check that every
      event the Lua fires is declared in the XML, and vice versa.
- [ ] Run the suite, green, then commit.

---

### Task 3: Input labels

**Files:** `driver.xml`, `driver.lua`, `htp1/proxy.lua` (if the label variable lives there),
`tests/test_driver.lua`, `tests/test_manifest.lua`

The driver cannot rename Control4's inputs — see the requirements doc for the evidence. It reports
instead.

- [ ] Replace the `ADOPT_INPUT_LABELS` action with `PRINT_INPUT_LABELS`, named
      **"Print Input Labels"** in the XML. Its handler prints one line per input the unit reported:
      the Control4 connection id and name, the unit's key, the unit's label, and whether the unit
      considers it visible. Inputs the driver does not model — Roon — are printed too, marked as
      unmapped, since knowing the unit has a label for something Control4 cannot select is useful.
- [ ] Remove the **"Adopt Input Labels"** property. It promises something the driver cannot do, and
      leaving a dead Yes/No in the property grid is worse than not having it.
- [ ] `INPUT_LABEL` (from Task 2) carries the unit's label for the *current* input, falling back to
      the connection name when the unit reported none.
- [ ] Tests: the action prints a line per reported input including the unmapped one; the property is
      gone from the XML and nothing in the Lua reads it; `INPUT_LABEL` follows an input change and
      falls back when the unit has no label.
- [ ] Run the suite, green, then commit.

---

## Exit criteria

- [ ] `luajit tests/run.lua` green, with the real output pasted into the implementation doc.
- [ ] `powershell -File tools/build-c4z.ps1` builds, 11 entries, `auto_update: false`.
- [ ] `driver.xml` version bumped to `102` for `v1.0.2`.
- [ ] Owner-verified on hardware: the variables appear in Composer programming with correct values;
      changing the source on the unit's front panel moves the format and resolution variables with no
      Control4 command; the events fire; the Print Input Labels action lists the inputs.

## Explicitly not in M2

Dirac control, loudness, night, dialog enhance, bass enhance, lip sync and macros are M3.
`DIRAC_STATE` here is a read-only status variable only — the control comes later.

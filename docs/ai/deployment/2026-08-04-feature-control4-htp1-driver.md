---
phase: deployment
title: Deployment Strategy
description: How the Monolith HTP-1 driver is built, installed and rolled back
---

# Deployment Strategy

## Build

```
powershell -File tools/build-c4z.ps1
```

Produces `build/Monolith.HTP1.c4z` and prints the archive layout. The archive contains `driver.xml`,
`driver.lua`, `htp1/*.lua` and `module/json.lua` and nothing else — no `docs/`, `tests/`, `tools/`,
`.ai-devkit.json`, `.claude/`, `CLAUDE.md`, `.vscode/` or `build/`.

Following the convention of the sibling drivers, the build **fails rather than warns** on a missing
payload file, on a `require` that resolves to something not in the payload, and on a payload file git
does not track. The third check exists because a sibling driver shipped two builds containing files a
global gitignore silently excluded, and the repository could not reproduce its own releases.

**The build never installs.** It writes to `build/` and stops. Copying anything into
`Documents\Control4\Drivers` is the owner's action, not the build's.

Composer identifies a driver by file name, so the archive name must stay `Monolith.HTP1.c4z` — a
build under a different name adds a second driver instead of updating the installed one.

## Install

The owner performs every step below; this repository produces the artefact and the instructions.

1. Copy `build/Monolith.HTP1.c4z` into `Documents\Control4\Drivers\`.
2. In Composer Pro: **Driver → Add or Update Driver**, then refresh the driver list.
3. Add the driver to the room, set its IP address on the network connection (binding 6001).
4. Bind sources to the HDMI inputs, the display to an HDMI output, and the amplifiers to the audio
   output. Bind the room to the type-7 end-point (7000).
5. Confirm the driver's Connection Status property reads connected and the Firmware Version property
   is populated — those two together prove the websocket opened and `getmso` was parsed.

## Rollback

Remove the driver from the project, or install the previous `.c4z` over it. The driver holds no
persisted state that survives removal, and it never writes to the unit unless commanded, so removing
it leaves the HTP-1 exactly as it was.

## Update hazard

Unlike the Control4-HA drivers, this driver declares no `<auto_update>` and no upstream release URL,
so Composer Pro's **Update Connected Drivers** action cannot silently replace it with someone else's
build. Keep it that way.

## Release

Releases are cut from `main` after the gate passes. Tag `vN.N.N`, attach `Monolith.HTP1.c4z` to a
GitHub release. The `<version>` element in `driver.xml` is bumped in the same commit as the tag —
Composer uses it to decide whether an installed driver is stale, so a release with an unbumped version
will appear to install and change nothing.

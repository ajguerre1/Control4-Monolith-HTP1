# Control4 driver — Monoprice Monolith HTP-1

A [Control4](https://www.control4.com/) DriverWorks driver that exposes the Monoprice Monolith HTP-1
AV processor as a `receiver`-class device over IP.

> **Status: v1.0.1 pre-release. In trial on real hardware.**
> The driver is complete for its first milestone, has 205 offline tests, and has been installed in a
> real Control4 project — v1.0.1 fixes the first three findings from that install. It is not yet
> proven in daily use. See [Known unknowns](#known-unknowns).

## What it does today

The HTP-1 acts as the AV hub of its room: sources connect to its HDMI inputs, it switches video and
audio, drives the display and feeds the amplifiers. The driver gives Control4 the core functions it
defines for AV receivers, with feedback in both directions — changes made from a Control4 remote,
keypad or touchscreen reach the unit, and changes made from the front panel, the handheld remote or
the unit's own web UI reach Control4.

- Power on, standby and sleep
- Input selection across the HDMI, analog, coax, optical, AES/EBU, eARC, Bluetooth and USB inputs
- Discrete volume, hold-to-ramp and mute
- Listening-mode selection across all seven upmixers, as Control4 surround modes
- Unattended reconnection after a unit reboot, a network drop or a controller restart

## Planned

Not in this release. Each lands as its own milestone:

- **M2** — read-only status variables (surround mode, decoded and encoded formats, sample rate, video
  resolution, colour space, HDR), and adopting the unit's own input labels
- **M3** — Dirac on/off/bypass and slot selection; Loudness, Night, Dialog Enhance and Bass Enhance;
  lip-sync delay; the unit's stored macros and presets by their own names

Zone 2, the Roon input and per-input gain trim are deliberately out of scope.

## How it talks to the unit

One persistent WebSocket to `ws://<host>/ws/controller`. The driver is entirely event-driven and never
polls: an idle connection carries no traffic beyond a keepalive ping every 30 seconds. State arrives
as JSON-patch pushes, so anything changed by another controller, the front panel or the web UI shows
up in Control4 too.

There is no REST API on the unit — `/api`, `/mso` and `/status` all return 404 — and DriverWorks has
no native WebSocket support, so the RFC 6455 codec is written from scratch in Lua. It is
cross-validated byte-for-byte against Python's `websockets` in both directions.

## Requirements

- Control4 OS 3.x
- Monolith HTP-1 on firmware 1.13.x or 2.1.x, reachable on the network

## Building

```
powershell -File tools/build-c4z.ps1
```

produces `build/Monolith.HTP1.c4z`. The build never installs — it writes to `build/` and stops. It
fails rather than warns on a missing payload file, a `require` that resolves outside the payload, or a
payload file git does not track.

The archive name is load-bearing: Composer identifies a driver by file name, so building under a
different name adds a second driver instead of updating the installed one.

## Installing

1. Copy `build/Monolith.HTP1.c4z` into `Documents\Control4\Drivers\`.
2. Composer Pro → **Driver → Add or Update Driver**, then refresh the driver list.
3. Add the driver to the room and set its IP address on the network connection (binding 6001).
4. Bind sources to the HDMI inputs, the display to an HDMI output, the amplifiers to the audio output,
   and the room to the type-7 end-point (7000).

**Connection Status**, **Firmware Version** and **Serial Number** populating together is the proof
that the socket opened and the unit's document parsed.

## Testing

```
luajit tests/run.lua
```

202 tests, no controller and no device required: the framing, protocol, state and mapping layers have
no dependency on the Control4 API, and the transport and proxy layers run against a mocked C4 API with
virtual time. `tools/fake-htp1.py` serves the real protocol locally, with deliberate fault injection
(mid-frame disconnects, byte-at-a-time delivery, a device that stops answering pings).

## Known unknowns

These cannot be settled without a controller, and are the first things to check on a trial:

- **Whether the empty `<roomAutoBind>` actually suppresses auto-binding.** The `receiver` proxy claims
  every room endpoint the moment the driver joins a room, and an empty element in this driver's own
  manifest is the only available lever. Nothing on a development machine can prove Composer honours
  the override, so confirm it by adding the driver to a fresh room and checking it arrives unbound.
- Connection 7000 is the only proxy-addressed connection without `proxybindingid="5001"`. If room
  volume and mute feedback do not appear, check this first.
- Whether the unit keeps its network stack alive with `powerIsOn` false. Both reference units report
  `fastStart: "on"`, which suggests yes; if not, power-on needs Wake-on-LAN.
- `C4:GetBindingAddress` semantics, and whether `keep_connection` makes Director re-establish the
  socket behind the driver's own state machine.
- Whether Director accepts non-string values in proxy notification parameters, and whether
  `SendToNetwork` / `ReceivedFromNetwork` are binary-clean.

The full list, with every review finding and its disposition, is in
`docs/ai/implementation/2026-08-04-feature-control4-htp1-driver-ledger.md`.

## Documentation

`docs/ai/` carries the requirements, design, plan, deployment and monitoring notes for the work.

## Licence

Not yet chosen — no licence file, so default copyright applies and all rights are reserved.

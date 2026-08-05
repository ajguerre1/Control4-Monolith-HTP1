# Control4 driver — Monoprice Monolith HTP-1

A [Control4](https://www.control4.com/) DriverWorks driver that exposes the Monoprice Monolith HTP-1
AV processor as a `receiver`-class device over IP.

## What it does

The HTP-1 acts as the AV hub of its room: sources connect to its HDMI inputs, it switches video and
audio, drives the display and feeds the amplifiers. The driver gives Control4 the functions it defines
for AV receivers, with feedback in both directions — changes made from a Control4 remote, keypad or
touchscreen reach the unit, and changes made from the front panel, the handheld remote or the unit's
own web UI reach Control4.

- Power on, standby and sleep
- Input selection across the HDMI, analog, coax, optical, AES/EBU, eARC, Bluetooth and USB inputs
- Discrete volume, hold-to-ramp, and mute
- Listening-mode selection across all seven upmixers
- Dirac on / off / bypass and slot selection
- Loudness, Night, Dialog Enhance, Bass Enhance and lip-sync delay
- The unit's stored macros and presets, by their own names
- Read-only status: surround mode, decoded and encoded formats, sample rate, video resolution,
  colour space and HDR

## How it talks to the unit

One persistent WebSocket to `ws://<host>/ws/controller`. The driver is entirely event-driven and never
polls: an idle connection carries no traffic beyond a keepalive ping every 30 seconds. State arrives
as JSON-patch pushes from the unit, so anything changed by any other controller, the front panel or
the web UI shows up in Control4 too.

## Requirements

- Control4 OS 3.x
- Monolith HTP-1 on firmware 1.13.x or 2.1.x, reachable on the network

## Building

```
powershell -File tools/build-c4z.ps1
```

produces `build/Monolith.HTP1.c4z`. Add it to Composer Pro through **Driver → Add or Update Driver**.

## Testing

```
luajit tests/run.lua
```

The protocol, framing, state and mapping layers have no dependency on the Control4 API and run without
a controller or a device. `tools/fake-htp1.py` serves the real protocol locally for transport testing.

## Status

In development. See `docs/ai/` for the requirements, design and plan.

## Licence

MIT

---
phase: monitoring
title: Monitoring & Observability
description: How the Monolith HTP-1 driver reports its own health
---

# Monitoring & Observability

There is no telemetry and no external monitoring system. Observability is what an installer can see in
Composer Pro and the Director log, and it is deliberately quiet by default.

## What is visible without turning anything on

| Signal | Where | Meaning |
|---|---|---|
| `Connection Status` property | Composer property grid | Connected / connecting / disconnected, with the reason for the last failure |
| `CONNECTED` variable | Programming | Same state, usable in programs to gate actions on the unit being reachable |
| `Firmware Version`, `Serial Number`, `Model` | Composer property grid | Non-empty only after a `getmso` has been parsed, so they double as a proof of a healthy session |
| `Connected` / `Disconnected` events | Programming | Lets the owner drive a notification if a unit drops |

## Logging policy

Debug Mode is **Off** by default and has an **On for 15 minutes** setting that cancels itself, so a
driver left in debug does not fill the Director log indefinitely.

- **Off**: only genuine faults reach `C4:ErrorLog` — a failed handshake, a rejected `changemso`, a
  caught Lua error with its traceback. A quiet log with debug off is a success criterion.
- **On**: connection lifecycle transitions, every verb sent and received with payload sizes, patch
  operations kept and discarded, and proxy notifications.

Caught errors are always logged with their traceback. Handlers are wrapped so a Lua error cannot take
the driver down, but nothing is swallowed — this workspace already recorded the failure mode where a
bare `pcall` hid handler bugs for weeks.

## What to check when something is wrong

1. `Connection Status` — if it is not connected, the problem is the network or the unit, not the
   driver's logic.
2. Whether the unit answers `getmso` at all. The unit serves several concurrent connections, so a
   second client can be pointed at it without disturbing the driver.
3. Whether the room is bound to the type-7 end-point (7000). Volume and mute commands do not reach a
   driver that is not bound there.
4. Firmware version. 1.13.x and 2.1.x documents differ; a feature that works on one unit and not the
   other is a firmware-tolerance bug and belongs in the fixture suite.

## Deliberate non-goals

No `C4:Statsd*` metrics. The Snap One WebSocket library emits them; this driver does not use that
library and does not add its own. No periodic health polling — the unit pushes state and answers
pings, and adding a poll would break the stated noise requirement to gain nothing.

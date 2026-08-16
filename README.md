# Control4 driver — Monoprice Monolith HTP-1

A Control4 driver for the Monoprice Monolith HTP-1 AV processor. It controls the unit over your
network and keeps Control4 in step with it: changes made on the front panel, the unit's own remote or
its web page appear in Control4 without being asked for.

Working on real hardware. The current version is on the [releases page](../../releases/latest).

## Features

- Power on and sleep
- Input selection across all 20 inputs, under the names the unit gives them
- Volume, hold-to-ramp, and mute
- Loudness from the room's own control
- Listening mode selection
- Dirac Live on and off, and filter selection by slot name
- Night mode, dialog enhancement, bass enhancement and lip sync delay
- Runs the macros already stored on the unit
- Status for programming: input, volume, formats, sample rates and video
- Reports the unit's Fast Start setting
- Events for connection, power, input and surround mode changes
- Reconnects on its own after a network drop or a unit restart
- Built-in documentation, in Composer's Documentation tab

## Requirements

- Control4 OS 3.x
- Monolith HTP-1 on firmware 1.13.x or 2.1.x
- The unit reachable on the network, at a fixed address or a DHCP reservation

## Installation

1. Download `Monolith.HTP1.c4z` from the [latest release](../../releases/latest).
2. In Composer Pro: **Driver › Add or Update Driver or Agent…**, and select the file.
3. Add the driver to a room.
4. On the **Connections** tab, enter the unit's IP address.
5. Bind your sources to the HDMI inputs, the display to an HDMI output, and the amplifiers to the
   audio output.
6. Bind the room to the **Room Selection** end-point.

The driver claims no room end-points on its own. Every binding is yours to make.

**Connection Status** showing *Connected*, with the version and serial fields filled in, confirms it
is working.

Full documentation is in the driver's **Documentation** tab in Composer.

## License

[MIT](LICENSE).

The Monolith name and logo are Monoprice's, used here to identify the product this driver controls.
This project is not affiliated with or endorsed by Monoprice.

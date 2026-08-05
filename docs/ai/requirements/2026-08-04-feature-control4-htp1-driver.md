---
phase: requirements
title: Requirements & Problem Understanding
description: Control4 DriverWorks IP driver for the Monoprice Monolith HTP-1 AV processor
---

# Requirements & Problem Understanding

## Problem

Control4 has no driver for the Monoprice Monolith HTP-1 AV processor. The unit is the AV hub of
its room: sources connect to its HDMI inputs, it switches video and audio, drives the display over
HDMI and feeds the amplifiers. Without a driver, Control4 cannot select an input, set volume, mute,
choose a listening mode, or reflect any of that back to a keypad, remote or touchscreen.

## Goal

A DriverWorks driver exposing the HTP-1 as a Control4 `receiver`-class device over IP, covering the
functions Control4 defines for AV receivers, with feedback in both directions: changes made from
Control4 reach the unit, and changes made from the front panel, handheld remote or the unit's own
web UI reach Control4.

## In scope

| # | Requirement | Acceptance |
|---|---|---|
| R1 | Power on, standby and sleep | Room on/off drives the unit; unit power changes reach Control4 |
| R2 | Input selection across all physical inputs | Selecting a Control4 input switches the unit; external input changes update Control4 |
| R3 | Discrete volume and hold-to-ramp | Room volume bar tracks the unit; remote ramp is smooth; external volume changes update Control4 |
| R4 | Mute, discrete and toggle | Both directions |
| R5 | Listening-mode select | All seven upmixers selectable as Control4 surround modes, both directions |
| R6 | Dirac on / off / bypass and slot select | Programming commands; state exposed as a variable |
| R7 | Loudness, Night, Dialog Enhance, Bass Enhance | Programming commands; state exposed as variables |
| R8 | Lip-sync delay | Programming command; current value exposed as a variable |
| R9 | Stored macros and presets | The unit's named macros appear as Control4 commands and can be fired |
| R10 | Read-only status feedback | Surround mode, decoded and encoded formats, sample rate, video resolution, colour space, HDR |
| R11 | Adopt the unit's input labels | Control4 input names follow the unit's own labels; inputs the unit hides are hidden |
| R12 | Connection resilience | Survives unit reboot, network loss and controller restart without manual intervention |
| R13 | Two concurrent instances | Both units driven from one controller without interference |
| R14 | Firmware tolerance | Works on 1.13.x and 2.1.x; absent fields degrade rather than fail |

## Out of scope

Decided during brainstorming on 2026-08-04:

- **Zone 2 / secondary volume.** Neither unit uses it and the physical mapping is unverified. This
  also removes the `secondVolume` (1.13.x) versus `secondaryVolume` (2.1.x) firmware special case.
- **Roon input.** Not applicable to this installation. No connection is declared for it. If the unit
  is switched to Roon externally, the driver reports the label truthfully and notifies the proxy with
  `INPUT = -1` rather than fabricating a selected input.
- **Per-input gain trim and channel trim.** Calibration values, not runtime controls. Exposing them
  to programming risks a stray program permanently detuning an input.
- **Speaker configuration, PEQ, bass management, Dirac filter transfer, network configuration.** The
  unit's own web UI owns these. A control system has no business editing them.

## Constraints

- **Read-only against live hardware.** Both units are in service. The driver may open the control
  websocket and observe, but must not send `changemso` outside a session where the owner has asked
  for it. Writes are verified with the owner present.
- **Composer Pro is driven by the owner.** Builds and instructions are produced here; Composer clicks
  and Director logs come from the owner.
- **Privacy.** The repository is private but is treated as public. No IP addresses, unit names, room
  names, input labels, serial numbers, MAC addresses or hostnames anywhere in it.
- **Minimal noise and resource usage** is a stated requirement, not a preference. Measured baseline:
  an idle connection sends nothing for 90 seconds. The driver must not introduce polling.

## Success criteria

Installed on the controller, bound to a real room, both units driven concurrently: every function in
R1–R11 works from a Control4 remote, keypad and touchscreen; every corresponding change made on the
unit is reflected in Control4 within a second; the driver reconnects unattended after the unit is
rebooted and after the network is interrupted; and the Director log is quiet with debug off.

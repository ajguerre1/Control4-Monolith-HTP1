# Control4 Monolith HTP-1 — working agreement

A Control4 DriverWorks driver exposing the Monoprice Monolith HTP-1 AV processor as a `receiver`-class
device over IP.

**Treat this as a public repository.** It is private today; that is not a privacy control. Read the
privacy rules below before writing anything to it.

## Development lifecycle

All feature work follows the [AI DevKit](https://github.com/codeaholicguy/ai-devkit) lifecycle.
Phase docs live in `docs/ai/<phase>/`, one file per feature.

```
setup → 1 new requirement → 2 review requirements → 3 review design → 4 create plan
      → 5 execute plan → 6 update planning (after each task) → 7 check implementation
      → 8 write tests → 9 code review
```

Route phases through the `dev-lifecycle` skill; use `tdd` for implementation tasks and `verify`
before any completion claim. Advance between phases automatically — stop only for a decision that
genuinely cannot be inferred.

Discover the docs path with `npx ai-devkit@latest lint` / `lint --feature <name>`; do not hardcode it.
New feature docs come from `npx ai-devkit@latest docs init-feature <name>`.

Durable knowledge goes to the memory CLI at scope `project:control4-ha`. Run `memory store` from a
**bash** shell — PowerShell mangles long `--content` arguments.

## Environment

Control4 DriverWorks runs **Lua 5.1**. Develop and test against LuaJIT 2.1, which is the same dialect
(`unpack` exists, `table.unpack` does not).

No submodules. This driver shares no code with the Control4-HA drivers.

`gh` must always be given an explicit repository — several Control4 repos share this workspace and it
resolves the wrong one otherwise:

```
gh <command> -R ajguerre1/Control4-Monolith-HTP1
```

## The device

- Control path is a WebSocket at `ws://<host>/ws/controller`, port 80, no authentication. There is no
  REST API: `/api`, `/mso` and `/status` return 404.
- Text frames of `verb[ space JSON ]`. `getmso` → `mso {…}`; `changemso [ops]` applies RFC 6902
  JSON-patch operations; the unit pushes `msoupdate [ops]` on every change from any source.
- The unit answers WebSocket pings, serves several concurrent connections independently, and replies
  `error "bad-verb"` to junk without dropping the connection.
- An idle connection is silent. **Never add polling.**
- Two firmware families are supported, 1.13.x and 2.1.x, and their documents differ. Every read is
  absence-tolerant.

### Live units — read-only

Two units are reachable on the owner's LAN and are **in daily use**. Reading (`getmso`, observing
`msoupdate`, WebSocket pings) is permitted. **Never send `changemso` unless the owner has asked for it
in that session.** Their addresses are site data and belong nowhere in this repository.

## Gate

This repository has no CI. The gate is:

```
luajit tests/run.lua                        # all tests green
powershell -File tools/build-c4z.ps1        # packages build/Monolith.HTP1.c4z and prints its layout
```

Run both and paste the real output before claiming anything works.

## Packaging

A `.c4z` is a plain zip. The layout is:

```
driver.xml
driver.lua
htp1/*.lua
module/json.lua
```

Development-only paths (`docs/`, `tests/`, `tools/`, `.ai-devkit.json`, `.claude/`, `CLAUDE.md`,
`.vscode/`, `build/`) must never end up inside the archive.

## Privacy rules

Nothing below is negotiable.

- **No real identifiers.** No IP addresses, MAC addresses, hostnames, serial numbers, unit names,
  room names, area names or input labels — in code, tests, fixtures, docs, commit messages, issue text
  or PR text.
- **No captured device state.** Real `mso` documents contain input labels and the unit's name.
  `.gitignore` blocks `mso_*.json`; scrub captures into invented equivalents before they become
  fixtures.
- **Invented test fixtures only**, e.g. input label `"Streamer"`, unit name `"Processor"`.
- **Scrub before pasting.** Composer Pro output, Director logs and screenshots get redacted before
  they enter the repository.

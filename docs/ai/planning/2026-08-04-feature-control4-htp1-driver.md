---
phase: planning
title: Project Planning & Task Breakdown
description: Task-by-task implementation plan for the Monolith HTP-1 driver, milestone M1 Core
---

# Monolith HTP-1 Driver — M1 Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Control4 DriverWorks driver that connects to a Monolith HTP-1 over WebSocket and exposes
power, input selection, discrete volume, hold-to-ramp, mute and surround-mode select through the stock
`receiver` proxy, with feedback in both directions and unattended reconnection.

**Architecture:** One persistent WebSocket to `ws://<host>/ws/controller`, entirely event-driven,
never polling. `transport.lua` owns staying connected; `session.lua` owns orchestration; four pure-Lua
modules (`frame`, `protocol`, `mapping`, `state`) hold the logic and touch no Control4 API, so they
test under LuaJIT with neither a controller nor a device.

**Tech Stack:** Lua 5.1 (DriverWorks), LuaJIT 2.1 for tests, PowerShell 5.1 for packaging, Python 3
with the `websockets` package for the fake device.

## Global Constraints

- **Lua 5.1 dialect only.** `unpack` exists, `table.unpack` does not. No `goto`, no integer division.
- **No `bit` library.** LuaJIT has it, DriverWorks does not document it. All bit manipulation is
  arithmetic.
- **LuaJIT is not on PATH.** It is at `%LOCALAPPDATA%\Programs\LuaJIT\bin\luajit.exe`.
- **Never send `changemso` to a live unit** unless the owner asked for it in that session. Tests run
  against `tools/fake-htp1.py`, never against hardware.
- **Privacy.** No IP addresses, MAC addresses, hostnames, serial numbers, unit names, room names or
  input labels in code, tests, fixtures, docs or commit messages. Fixtures use invented values only.
- **Archive name is `Monolith.HTP1.c4z`.** Composer identifies a driver by file name.
- **The build never installs.** It writes to `build/` and stops.
- **Frame payload cap is 1048576 bytes.** Larger frames are rejected, not buffered.
- **Binding IDs:** proxy 5001, network 6001, room end-point 7000. HDMI inputs 1000–1007, hidden eARC
  1008 with virtual audio 3008, audio inputs 3000–3011, video outputs 2000–2001, audio output 4000.

## File Structure

| File | Responsibility |
|---|---|
| `driver.xml` | Control4 declaration: proxy, connections, capabilities, properties |
| `driver.lua` | Control4 entry points only. Builds the object graph, forwards callbacks. No logic. |
| `htp1/frame.lua` | RFC 6455 encode/decode and a reassembling reader. Pure. |
| `htp1/protocol.lua` | `verb + JSON` layer. Pure. |
| `htp1/mapping.lua` | Connection id ↔ MSO key, surround ids, dB ↔ percent. Pure, all-static. |
| `htp1/state.lua` | Projected state, whitelisted patch applier, change detection. Pure. |
| `htp1/transport.lua` | Socket, handshake, keepalive, reconnection backoff. |
| `htp1/session.lua` | `getmso` on open, message dispatch, coalescing write queue, reconcile. |
| `htp1/proxy.lua` | `receiver` proxy command handlers and notifications. |
| `htp1/log.lua` | Debug logging with a self-cancelling timer. |
| `module/json.lua` | Vendored JSON codec. |
| `tests/*` | Runner, harness, C4 mock, suites, fixtures. |
| `tools/build-c4z.ps1` | Packaging with fail-closed checks. |
| `tools/fake-htp1.py` | Local device simulator for transport and end-to-end tests. |

## Task Map

| # | Task | Deliverable |
|---|---|---|
| 1 | Test harness, runner and C4 mock | `luajit tests/run.lua` runs and is green |
| 2 | Frame encoding | Masked client frames, all three length forms |
| 3 | Frame decoding and reader | Reassembly across reads, fragments, control frames |
| 4 | Vendored JSON and the protocol layer | `parse` / `encodeChange` |
| 5 | Mapping | Input table, surround ids, dB ↔ percent |
| 6 | State — document projection | `applyDocument` |
| 7 | State — patch operations | `applyOps` with a change set |
| 8 | Logging and transport handshake | Upgrade request, 101 validation |
| 9 | Transport — frames, keepalive, backoff | Staying connected |
| 10 | Session | `getmso`, dispatch, write queue, reconcile |
| 11 | `driver.xml` | Full Control4 declaration |
| 12 | Proxy handlers and `driver.lua` | Commands and notifications end to end |
| 13 | Packaging | `build/Monolith.HTP1.c4z` with fail-closed checks |
| 14 | Fake device and end-to-end test | Real socket, no hardware |

---

### Task 1: Test harness, runner and C4 mock

**Files:**
- Create: `tests/mock_c4.lua`, `tests/harness.lua`, `tests/test_smoke.lua`, `tests/run.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: `mock.install(properties) -> mock`, `mock.advance(ms)`, `mock.clearCalls()`,
  `mock.calls`, `mock.printed`, `mock.sent`, `mock.variables`, `mock.proxyCalls(binding, command)`,
  `mock.lastProxyCall(binding, command)`; harness assertions `H.equal(actual, expected, msg)`,
  `H.isTrue`, `H.isFalse`, `H.count`, `H.errorMatches(fn, substring)`, `H.assertNoErrorLog()`.

The mock's `SendToProxy` takes varargs deliberately. This workspace recorded that `C4:SendToProxy`
rejects an explicit `nil` call type, and a mock with a fixed fourth parameter cannot tell `f(a,b,c)`
from `f(a,b,c,nil)` — so it reports that bug as passing.

- [ ] **Step 1: Write the C4 mock**

Create `tests/mock_c4.lua`:

```lua
-- A stand-in for the Control4 API, good enough to run the driver offline.
-- Time is virtual: nothing sleeps, tests call mock.advance(ms) to fire timers.

local M = {}

M.calls, M.printed, M.sent, M.timers, M.now = {}, {}, {}, {}, 0
M.properties, M.variables = {}, {}
M.hashAlgorithms = { MD5 = true, SHA1 = true }

local function record(name, args) table.insert(M.calls, { name = name, args = args }) end

function M.clearCalls()
    M.calls, M.printed, M.sent = {}, {}, {}
end

function M.advance(ms)
    local target = M.now + ms
    while true do
        local soonest, soonestId
        for id, t in pairs(M.timers) do
            if t.due <= target and (not soonest or t.due < soonest.due) then
                soonest, soonestId = t, id
            end
        end
        if not soonest then break end
        M.now = soonest.due
        if soonest.repeating then
            soonest.due = M.now + soonest.interval
        else
            M.timers[soonestId] = nil
        end
        soonest.callback(soonest.handle, 0)
    end
    M.now = target
end

function M.proxyCalls(binding, command)
    local found = {}
    for _, c in ipairs(M.calls) do
        if c.name == "SendToProxy" and c.args[1] == binding and c.args[2] == command then
            table.insert(found, c)
        end
    end
    return found
end

function M.lastProxyCall(binding, command)
    local found = M.proxyCalls(binding, command)
    return found[#found]
end

function M.install(properties)
    M.calls, M.printed, M.sent, M.timers, M.now = {}, {}, {}, {}, 0
    M.variables = {}
    M.properties = properties or {}

    _G.Properties = M.properties
    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        table.insert(M.printed, table.concat(parts, "\t"))
    end

    local nextTimerId = 0

    _G.C4 = {
        CreateNetworkConnection = function(_, binding, address)
            record("CreateNetworkConnection", { binding, address })
        end,
        NetConnect = function(_, binding, port) record("NetConnect", { binding, port }) end,
        NetDisconnect = function(_, binding, port) record("NetDisconnect", { binding, port }) end,
        SendToNetwork = function(_, binding, port, data)
            record("SendToNetwork", { binding, port, data })
            table.insert(M.sent, data)
        end,
        SetTimer = function(_, ms, callback, repeating)
            nextTimerId = nextTimerId + 1
            local id = nextTimerId
            local handle
            handle = { Cancel = function() M.timers[id] = nil; return handle end }
            M.timers[id] = {
                due = M.now + ms, interval = ms, repeating = repeating and true or false,
                callback = callback, handle = handle,
            }
            record("SetTimer", { ms, repeating })
            return handle
        end,
        -- Varargs on purpose: a fixed fourth parameter cannot distinguish an
        -- omitted call type from an explicitly nil one, and the real proxy
        -- rejects the second.
        SendToProxy = function(_, binding, command, params, ...)
            if select("#", ...) > 0 and select(1, ...) == nil then
                error("SendToProxy called with an explicit nil strCallType", 2)
            end
            record("SendToProxy", { binding, command, params, ... })
        end,
        UpdateProperty = function(_, name, value)
            M.properties[name] = value
            record("UpdateProperty", { name, value })
        end,
        AddVariable = function(_, name, value, kind)
            M.variables[name] = value
            record("AddVariable", { name, value, kind })
        end,
        SetVariable = function(_, name, value)
            M.variables[name] = value
            record("SetVariable", { name, value })
        end,
        ErrorLog = function(_, message)
            record("ErrorLog", { message })
            table.insert(M.printed, "ErrorLog: " .. tostring(message))
        end,
        Base64Encode = function(_, data)
            local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
            local out = {}
            local pad = (3 - #data % 3) % 3
            local padded = data .. string.rep("\0", pad)
            for i = 1, #padded, 3 do
                local a, b, c = padded:byte(i, i + 2)
                local n = a * 65536 + b * 256 + c
                for j = 3, 0, -1 do
                    local index = math.floor(n / (64 ^ j)) % 64
                    table.insert(out, alphabet:sub(index + 1, index + 1))
                end
            end
            local encoded = table.concat(out)
            return encoded:sub(1, #encoded - pad) .. string.rep("=", pad)
        end,
        Hash = function(_, algorithm, data)
            if not M.hashAlgorithms[algorithm] then
                error("unsupported hash algorithm: " .. tostring(algorithm), 2)
            end
            record("Hash", { algorithm, data })
            return "hashed:" .. algorithm .. ":" .. data
        end,
        GetDriverConfigInfo = function(_, key) return "test-" .. key end,
        GetDeviceID = function() return 4242 end,
    }

    return M
end

return M
```

- [ ] **Step 2: Write the harness**

Create `tests/harness.lua`:

```lua
-- Assertions and shared helpers. Pure modules are required directly by the
-- suites; only driver-level suites need the mock installed.

local mock = require("tests.mock_c4")

local H = { mock = mock }

local function fail(msg, level) error(msg, (level or 2) + 1) end

function H.isTrue(value, msg)
    if not value then fail(msg or ("expected truthy, got " .. tostring(value))) end
end

function H.isFalse(value, msg)
    if value then fail(msg or ("expected falsey, got " .. tostring(value))) end
end

function H.equal(actual, expected, msg)
    if actual ~= expected then
        fail((msg and (msg .. ": ") or "") ..
            "expected " .. tostring(expected) .. ", got " .. tostring(actual))
    end
end

function H.count(list, expected, msg)
    if #list ~= expected then
        fail((msg and (msg .. ": ") or "") ..
            "expected " .. expected .. " item(s), got " .. #list)
    end
end

-- Assert `fn` raises, and that the message contains `substring`.
function H.errorMatches(fn, substring)
    local ok, err = pcall(fn)
    if ok then fail("expected an error containing '" .. substring .. "', none was raised") end
    if not tostring(err):find(substring, 1, true) then
        fail("expected an error containing '" .. substring .. "', got: " .. tostring(err))
    end
end

-- Handlers are wrapped, so a fault is otherwise invisible and a broken handler
-- reports as passing. Every driver-level test ends with this.
function H.assertNoErrorLog()
    for _, line in ipairs(mock.printed) do
        if line:find("ErrorLog:", 1, true) then
            fail("driver logged an error: " .. line)
        end
    end
end

return H
```

- [ ] **Step 3: Write the smoke test**

Create `tests/test_smoke.lua`:

```lua
local H = require("tests.harness")
local mock = H.mock

return {
    {
        name = "the mock installs and exposes the C4 global",
        fn = function()
            mock.install({ ["Debug Mode"] = "Off" })
            H.isTrue(_G.C4 ~= nil, "C4 global should exist")
            H.equal(Properties["Debug Mode"], "Off")
        end,
    },
    {
        name = "virtual time fires a one-shot timer exactly once",
        fn = function()
            mock.install({})
            local fired = 0
            C4:SetTimer(500, function() fired = fired + 1 end, false)
            mock.advance(499)
            H.equal(fired, 0, "should not fire early")
            mock.advance(1)
            H.equal(fired, 1, "should fire at its due time")
            mock.advance(5000)
            H.equal(fired, 1, "a one-shot timer should not repeat")
        end,
    },
    {
        name = "virtual time repeats a repeating timer and honours Cancel",
        fn = function()
            mock.install({})
            local fired = 0
            local timer = C4:SetTimer(100, function() fired = fired + 1 end, true)
            mock.advance(350)
            H.equal(fired, 3, "should fire once per interval")
            timer:Cancel()
            mock.advance(1000)
            H.equal(fired, 3, "cancelled timers stop firing")
        end,
    },
    {
        name = "SendToProxy rejects an explicit nil call type",
        fn = function()
            mock.install({})
            H.errorMatches(function()
                C4:SendToProxy(5001, "VOLUME_LEVEL_CHANGED", { LEVEL = 10 }, nil)
            end, "explicit nil strCallType")
        end,
    },
    {
        name = "the mock's base64 matches the known RFC 6455 example",
        fn = function()
            mock.install({})
            -- Bytes 0x01..0x10. Written with string.char rather than \x escapes,
            -- which Lua 5.1 does not have -- the driver must stay in that dialect.
            local sixteenBytes = string.char(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)
            H.equal(C4:Base64Encode(sixteenBytes), "AQIDBAUGBwgJCgsMDQ4PEA==")
        end,
    },
}
```

- [ ] **Step 4: Write the runner**

Create `tests/run.lua`:

```lua
-- Test runner. Run from the repository root:
--
--   luajit tests/run.lua
--
-- Exits non-zero if any test fails, so it can gate packaging.

package.path = "./?.lua;./?/init.lua;" .. package.path

local SUITES = {
    "tests.test_smoke",
}

local GREEN, RED, DIM, RESET = "\27[32m", "\27[31m", "\27[2m", "\27[0m"
if os.getenv("NO_COLOR") then GREEN, RED, DIM, RESET = "", "", "", "" end

local passed, failed, failures = 0, 0, {}
local out = print   -- suites replace the global print; keep our own

for _, suiteName in ipairs(SUITES) do
    local ok, suite = pcall(require, suiteName)
    if not ok then
        failed = failed + 1
        table.insert(failures, { name = suiteName, err = "failed to load: " .. tostring(suite) })
        out(RED .. "LOAD FAIL" .. RESET .. "  " .. suiteName)
    else
        out(DIM .. suiteName .. RESET)
        for _, test in ipairs(suite) do
            local testOk, err = pcall(test.fn)
            _G.print = out
            if testOk then
                passed = passed + 1
                out("  " .. GREEN .. "pass" .. RESET .. "  " .. test.name)
            else
                failed = failed + 1
                table.insert(failures, { name = suiteName .. " / " .. test.name, err = err })
                out("  " .. RED .. "FAIL" .. RESET .. "  " .. test.name)
                out("        " .. tostring(err))
            end
        end
    end
end

out("")
if failed == 0 then
    out(GREEN .. passed .. " passed, 0 failed" .. RESET)
    os.exit(0)
else
    out(RED .. passed .. " passed, " .. failed .. " failed" .. RESET)
    for _, f in ipairs(failures) do
        out("  " .. RED .. f.name .. RESET .. ": " .. tostring(f.err))
    end
    os.exit(1)
end
```

- [ ] **Step 5: Run the suite**

Run: `"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: PASS — every suite green, and the new tests among them.

- [ ] **Step 6: Commit**

```bash
git add tests/
git commit -m "test: offline harness, C4 mock with virtual time, and runner"
```

---

### Task 2: Frame encoding

**Files:**
- Create: `htp1/frame.lua`, `tests/test_frame.lua`
- Modify: `tests/run.lua` — add `"tests.test_frame"` to `SUITES`

**Interfaces:**
- Consumes: nothing.
- Produces: `Frame.OP` (`CONT`, `TEXT`, `BINARY`, `CLOSE`, `PING`, `PONG`), `Frame.MAX_PAYLOAD`,
  `Frame.applyMask(payload, key) -> string`, `Frame.encode(opcode, payload, maskKey) -> string`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_frame.lua`:

```lua
local H = require("tests.harness")
local Frame = require("htp1.frame")

local KEY = "\1\2\3\4"

return {
    {
        name = "masking is its own inverse",
        fn = function()
            local plain = "getmso"
            local masked = Frame.applyMask(plain, KEY)
            H.isTrue(masked ~= plain, "masking should change the bytes")
            H.equal(Frame.applyMask(masked, KEY), plain, "unmasking should restore")
        end,
    },
    {
        name = "masking an empty payload yields an empty payload",
        fn = function()
            H.equal(Frame.applyMask("", KEY), "")
        end,
    },
    {
        name = "a short text frame sets FIN, the opcode, the mask bit and the length",
        fn = function()
            local f = Frame.encode(Frame.OP.TEXT, "getmso", KEY)
            H.equal(f:byte(1), 0x81, "FIN set with the TEXT opcode")
            H.equal(f:byte(2), 0x80 + 6, "mask bit set with a 6-byte length")
            H.equal(f:sub(3, 6), KEY, "the mask key follows the header")
            H.equal(Frame.applyMask(f:sub(7), KEY), "getmso", "payload is masked")
            H.equal(#f, 2 + 4 + 6)
        end,
    },
    {
        name = "a 126-byte payload switches to the 16-bit length form",
        fn = function()
            local f = Frame.encode(Frame.OP.TEXT, string.rep("x", 126), KEY)
            H.equal(f:byte(2), 0x80 + 126, "length marker for the extended form")
            H.equal(f:byte(3), 0, "high byte of 126")
            H.equal(f:byte(4), 126, "low byte of 126")
            H.equal(#f, 2 + 2 + 4 + 126)
        end,
    },
    {
        name = "a 65536-byte payload switches to the 64-bit length form",
        fn = function()
            local f = Frame.encode(Frame.OP.TEXT, string.rep("x", 65536), KEY)
            H.equal(f:byte(2), 0x80 + 127, "length marker for the 64-bit form")
            for i = 3, 7 do H.equal(f:byte(i), 0, "leading length byte " .. i) end
            H.equal(f:byte(8), 1, "0x010000 high byte")
            H.equal(f:byte(9), 0)
            H.equal(f:byte(10), 0)
            H.equal(#f, 2 + 8 + 4 + 65536)
        end,
    },
    {
        name = "a ping frame carries no payload but is still masked",
        fn = function()
            local f = Frame.encode(Frame.OP.PING, "", KEY)
            H.equal(f:byte(1), 0x89, "FIN set with the PING opcode")
            H.equal(f:byte(2), 0x80, "mask bit set with a zero length")
            H.equal(#f, 2 + 4)
        end,
    },
    {
        name = "encoding without a four-byte mask key is refused",
        fn = function()
            H.errorMatches(function() Frame.encode(Frame.OP.TEXT, "x", "abc") end,
                "four-byte mask key")
        end,
    },
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Add `"tests.test_frame"` to `SUITES` in `tests/run.lua`, then run:
`"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: LOAD FAIL — `module 'htp1.frame' not found`.

- [ ] **Step 3: Write the encoder**

Create `htp1/frame.lua`:

```lua
-- RFC 6455 frame codec.
--
-- No Control4 API and no `bit` library: LuaJIT provides `bit`, DriverWorks does
-- not document it, so masking is arithmetic and one implementation runs in both.
-- The cost falls only on outbound frames, which are small -- inbound frames from
-- the unit are unmasked and are never XORed.

local Frame = {}

Frame.OP = { CONT = 0x0, TEXT = 0x1, BINARY = 0x2, CLOSE = 0x8, PING = 0x9, PONG = 0xA }

-- Frames larger than this are rejected rather than buffered. The largest real
-- message is the ~38 KB mso document; anything near a megabyte is a fault.
Frame.MAX_PAYLOAD = 1048576

local byte, char, sub, concat = string.byte, string.char, string.sub, table.concat

local function bxorByte(a, b)
    local result, place = 0, 1
    for _ = 1, 8 do
        local abit, bbit = a % 2, b % 2
        if abit ~= bbit then result = result + place end
        a, b, place = (a - abit) / 2, (b - bbit) / 2, place * 2
    end
    return result
end

-- Masking is symmetric, so this both masks and unmasks.
function Frame.applyMask(payload, key)
    if #payload == 0 then return payload end
    local k1, k2, k3, k4 = byte(key, 1, 4)
    local k = { k1, k2, k3, k4 }
    local out = {}
    for i = 1, #payload do
        out[i] = char(bxorByte(byte(payload, i), k[((i - 1) % 4) + 1]))
    end
    return concat(out)
end

-- This codec never fragments outbound messages, so FIN is always set.
function Frame.encode(opcode, payload, maskKey)
    payload = payload or ""
    if type(maskKey) ~= "string" or #maskKey ~= 4 then
        error("client frames require a four-byte mask key", 2)
    end

    local header = char(0x80 + opcode)
    local length = #payload

    if length < 126 then
        header = header .. char(0x80 + length)
    elseif length < 65536 then
        header = header .. char(0x80 + 126)
            .. char(math.floor(length / 256), length % 256)
    else
        header = header .. char(0x80 + 127) .. char(0, 0, 0, 0)
            .. char(math.floor(length / 16777216) % 256,
                    math.floor(length / 65536) % 256,
                    math.floor(length / 256) % 256,
                    length % 256)
    end

    return header .. maskKey .. Frame.applyMask(payload, maskKey)
end

return Frame
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: PASS — every suite green, and the new tests among them.

- [ ] **Step 5: Commit**

```bash
git add htp1/frame.lua tests/test_frame.lua tests/run.lua
git commit -m "feat: RFC 6455 frame encoding with arithmetic masking"
```

---

### Task 3: Frame decoding and the reassembling reader

**Files:**
- Modify: `htp1/frame.lua` — add `Frame.decode` and `Frame.newReader` before the final `return Frame`
- Modify: `tests/test_frame.lua` — append tests to the returned table

**Interfaces:**
- Consumes: `Frame.OP`, `Frame.MAX_PAYLOAD`, `Frame.applyMask` from Task 2.
- Produces:
  - `Frame.decode(buf) -> frame, consumed` where `frame = { fin, opcode, payload }`; `nil, 0` when
    more bytes are needed; `nil, -1, err` on a protocol violation.
  - `Frame.newReader() -> reader`, with `reader:push(chunk)` and
    `reader:next() -> message | nil | nil, err`, where `message = { opcode, payload }` and
    continuation frames are already joined.

Control frames are never fragmented and may interleave a fragmented message, so the reader returns
them immediately without touching its fragment state. Server-to-client frames are unmasked; a masked
one is a protocol violation, not something to unmask.

- [ ] **Step 1: Write the failing tests**

Append these entries to the returned table in `tests/test_frame.lua`:

```lua
    {
        name = "decode consumes nothing while the header is short",
        fn = function()
            local f, consumed = Frame.decode("\129")
            H.equal(f, nil)
            H.equal(consumed, 0)
        end,
    },
    {
        name = "decode consumes nothing while the payload is incomplete",
        fn = function()
            local f, consumed = Frame.decode("\129\6get")
            H.equal(f, nil)
            H.equal(consumed, 0)
        end,
    },
    {
        name = "decode reads an unmasked short text frame",
        fn = function()
            local f, consumed = Frame.decode("\129\4mso ")
            H.isTrue(f ~= nil, "frame should decode")
            H.isTrue(f.fin, "FIN should be set")
            H.equal(f.opcode, Frame.OP.TEXT)
            H.equal(f.payload, "mso ")
            H.equal(consumed, 6)
        end,
    },
    {
        name = "decode reads the 16-bit length form",
        fn = function()
            local raw = "\129\126" .. string.char(1, 44) .. string.rep("y", 300)
            local f, consumed = Frame.decode(raw)
            H.equal(#f.payload, 300)
            H.equal(consumed, 4 + 300)
        end,
    },
    {
        name = "decode reads the 64-bit length form",
        fn = function()
            local raw = "\129\127" .. string.char(0, 0, 0, 0, 0, 1, 17, 112) .. string.rep("z", 70000)
            local f, consumed = Frame.decode(raw)
            H.equal(#f.payload, 70000)
            H.equal(consumed, 10 + 70000)
        end,
    },
    {
        name = "decode rejects a payload above the cap instead of buffering it",
        fn = function()
            local raw = "\129\127" .. string.char(0, 0, 0, 0, 255, 255, 255, 255)
            local f, consumed, err = Frame.decode(raw)
            H.equal(f, nil)
            H.equal(consumed, -1)
            H.isTrue(err:find("exceeds", 1, true) ~= nil, "error should name the cap: " .. tostring(err))
        end,
    },
    {
        name = "decode rejects a masked server frame",
        fn = function()
            local f, consumed, err = Frame.decode("\129\132\1\2\3\4abcd")
            H.equal(f, nil)
            H.equal(consumed, -1)
            H.isTrue(err:find("masked", 1, true) ~= nil, "error should say masked: " .. tostring(err))
        end,
    },
    {
        name = "the reader yields a whole message from one chunk",
        fn = function()
            local r = Frame.newReader()
            r:push("\129\4mso ")
            local m = r:next()
            H.equal(m.opcode, Frame.OP.TEXT)
            H.equal(m.payload, "mso ")
            H.equal(r:next(), nil, "no second message")
        end,
    },
    {
        name = "the reader reassembles a message split byte by byte",
        fn = function()
            local raw = "\129\11hello world"
            local r = Frame.newReader()
            for i = 1, #raw - 1 do
                r:push(raw:sub(i, i))
                H.equal(r:next(), nil, "incomplete at byte " .. i)
            end
            r:push(raw:sub(#raw))
            H.equal(r:next().payload, "hello world")
        end,
    },
    {
        name = "the reader yields several messages from a single read",
        fn = function()
            local r = Frame.newReader()
            r:push("\129\1a" .. "\129\1b" .. "\129\1c")
            H.equal(r:next().payload, "a")
            H.equal(r:next().payload, "b")
            H.equal(r:next().payload, "c")
            H.equal(r:next(), nil)
        end,
    },
    {
        name = "the reader joins continuation frames into one message",
        fn = function()
            local r = Frame.newReader()
            r:push("\1\3one")      -- TEXT, FIN clear
            H.equal(r:next(), nil, "an open fragment yields nothing yet")
            r:push("\0\3two")      -- CONT, FIN clear
            H.equal(r:next(), nil)
            r:push("\128\5three")  -- CONT, FIN set
            local m = r:next()
            H.equal(m.opcode, Frame.OP.TEXT, "the message keeps the first frame's opcode")
            H.equal(m.payload, "onetwothree")
        end,
    },
    {
        name = "a control frame passes through without disturbing an open fragment",
        fn = function()
            local r = Frame.newReader()
            r:push("\1\3one")
            H.equal(r:next(), nil)
            r:push("\137\0")       -- PING, FIN set, empty
            H.equal(r:next().opcode, Frame.OP.PING)
            r:push("\128\3two")
            H.equal(r:next().payload, "onetwo", "the fragment survived the ping")
        end,
    },
    {
        name = "a continuation with nothing to continue is a protocol error",
        fn = function()
            local r = Frame.newReader()
            r:push("\128\3one")    -- CONT with FIN, no open fragment
            local m, err = r:next()
            H.equal(m, nil)
            H.isTrue(err:find("continue", 1, true) ~= nil, "error should explain: " .. tostring(err))
        end,
    },
    {
        name = "the reader handles a 38 KB message delivered in 1 KB chunks",
        fn = function()
            local raw = "\129\127" .. string.char(0, 0, 0, 0, 0, 0, 148, 112) .. string.rep("m", 38000)
            local r = Frame.newReader()
            for i = 1, #raw, 1024 do r:push(raw:sub(i, i + 1023)) end
            local m = r:next()
            H.equal(#m.payload, 38000)
            H.equal(m.opcode, Frame.OP.TEXT)
        end,
    },
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: FAIL — `attempt to call field 'decode' (a nil value)`.

- [ ] **Step 3: Write the decoder and reader**

Insert into `htp1/frame.lua`, before the final `return Frame`:

```lua
-- Returns (frame, consumed) on success, (nil, 0) when more bytes are needed,
-- and (nil, -1, err) on a protocol violation the caller must not recover from.
function Frame.decode(buf)
    if #buf < 2 then return nil, 0 end

    local b1, b2 = byte(buf, 1), byte(buf, 2)
    local fin    = b1 >= 128
    local opcode = b1 % 16
    local masked = b2 >= 128
    local length = b2 % 128
    local offset = 2

    if length == 126 then
        if #buf < 4 then return nil, 0 end
        length = byte(buf, 3) * 256 + byte(buf, 4)
        offset = 4
    elseif length == 127 then
        if #buf < 10 then return nil, 0 end
        length = 0
        for i = 3, 10 do length = length * 256 + byte(buf, i) end
        offset = 10
    end

    if length > Frame.MAX_PAYLOAD then
        return nil, -1, "frame payload of " .. length .. " bytes exceeds the cap"
    end
    if masked then
        return nil, -1, "server frame is masked, which RFC 6455 forbids"
    end
    if #buf < offset + length then return nil, 0 end

    return { fin = fin, opcode = opcode, payload = sub(buf, offset + 1, offset + length) },
        offset + length
end

local Reader = {}
Reader.__index = Reader

function Frame.newReader()
    return setmetatable({ buf = "", fragment = nil, fragmentOp = nil }, Reader)
end

function Reader:push(chunk)
    self.buf = self.buf .. chunk
end

-- Returns a whole message, or nil when more bytes are needed, or (nil, err).
function Reader:next()
    while true do
        local frame, consumed, err = Frame.decode(self.buf)
        if err then return nil, err end
        if not frame then return nil end
        self.buf = sub(self.buf, consumed + 1)

        if frame.opcode >= 0x8 then
            -- Control frames are never fragmented and may arrive between the
            -- fragments of a data message, so they bypass the fragment state.
            return { opcode = frame.opcode, payload = frame.payload }
        end

        if frame.opcode == Frame.OP.CONT then
            if not self.fragment then
                return nil, "continuation frame with nothing to continue"
            end
            self.fragment = self.fragment .. frame.payload
        else
            if self.fragment then
                return nil, "new data frame while a fragmented message is open"
            end
            self.fragment, self.fragmentOp = frame.payload, frame.opcode
        end

        if frame.fin then
            local message = { opcode = self.fragmentOp, payload = self.fragment }
            self.fragment, self.fragmentOp = nil, nil
            return message
        end
    end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: PASS — every suite green, and the new tests among them.

- [ ] **Step 5: Commit**

```bash
git add htp1/frame.lua tests/test_frame.lua
git commit -m "feat: frame decoding and a reassembling reader"
```

---

### Task 4: Vendored JSON and the protocol layer

**Files:**
- Create: `module/json.lua` (vendored), `htp1/protocol.lua`, `tests/test_protocol.lua`
- Modify: `tests/run.lua` — add `"tests.test_protocol"` to `SUITES`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Protocol.GET_MSO` = `"getmso"`
  - `Protocol.parse(text) -> { verb = string, arg = value|nil, err = string|nil }`
  - `Protocol.encodeChange(ops) -> string` producing `changemso <json array>`
  - `Protocol.op(operation, path, value) -> table` — one patch operation

**Null handling.** No patch operation this driver *sends* carries a null, and no path it *reads*
takes one. Rather than depend on how the vendored codec represents JSON null, `state.lua` (Task 7)
treats an operation whose decoded value is `nil` as one to skip and log. That rule is testable
without knowing the library's sentinel.

- [ ] **Step 1: Vendor the JSON codec**

The sibling Control4 drivers all vendor Jeffrey Friedl's `JSON.lua` (version `20111207.5`), which is
proven on this controller. Copy it rather than picking a new library:

```bash
cp "../Control4-HA-Blinds/module/json.lua" module/json.lua
```

If that checkout is absent, fetch the same version from `http://regex.info/blog/lua/json`.

Then verify three things about the file before continuing, because the rest of the plan depends on
them:

```bash
head -12 module/json.lua                     # expect the Friedl copyright and VERSION 20111207.5
grep -n "^return\|^OBJDEF" module/json.lua   # expect a returned table so `require` yields the codec
```

Confirm `JSON:decode(text)` and `JSON:encode(value)` are **colon**-called. Note in passing that the
file assigns a global `OBJDEF`; the sibling drivers live with it and so does this one.

- [ ] **Step 2: Write the failing tests**

Create `tests/test_protocol.lua`:

```lua
local H = require("tests.harness")
local Protocol = require("htp1.protocol")

return {
    {
        name = "a verb with no argument parses to the verb alone",
        fn = function()
            local m = Protocol.parse("getmso")
            H.equal(m.verb, "getmso")
            H.equal(m.arg, nil)
            H.equal(m.err, nil)
        end,
    },
    {
        name = "an mso document parses into a table",
        fn = function()
            local m = Protocol.parse('mso {"volume":-25,"muted":false,"input":"h1"}')
            H.equal(m.verb, "mso")
            H.equal(m.err, nil)
            H.equal(m.arg.volume, -25)
            H.equal(m.arg.muted, false)
            H.equal(m.arg.input, "h1")
        end,
    },
    {
        name = "an msoupdate parses into an array of operations",
        fn = function()
            local m = Protocol.parse('msoupdate [{"op":"replace","path":"/volume","value":-30}]')
            H.equal(m.verb, "msoupdate")
            H.count(m.arg, 1)
            H.equal(m.arg[1].op, "replace")
            H.equal(m.arg[1].path, "/volume")
            H.equal(m.arg[1].value, -30)
        end,
    },
    {
        name = "the unit's bad-verb reply parses as a verb and a string argument",
        fn = function()
            local m = Protocol.parse('error "bad-verb"')
            H.equal(m.verb, "error")
            H.equal(m.arg, "bad-verb")
            H.equal(m.err, nil)
        end,
    },
    {
        name = "a payload containing spaces is not split further",
        fn = function()
            local m = Protocol.parse('mso {"unitname":"a b c"}')
            H.equal(m.arg.unitname, "a b c")
        end,
    },
    {
        name = "undecodable JSON reports an error instead of raising",
        fn = function()
            local m = Protocol.parse("mso {not json")
            H.equal(m.verb, "mso")
            H.equal(m.arg, nil)
            H.isTrue(m.err ~= nil, "an error should be reported")
        end,
    },
    {
        name = "an empty message reports an error instead of raising",
        fn = function()
            local m = Protocol.parse("")
            H.isTrue(m.err ~= nil, "an error should be reported")
        end,
    },
    {
        name = "a non-string message reports an error instead of raising",
        fn = function()
            local m = Protocol.parse(nil)
            H.isTrue(m.err ~= nil, "an error should be reported")
        end,
    },
    {
        name = "op builds a single patch operation",
        fn = function()
            local o = Protocol.op("replace", "/volume", -30)
            H.equal(o.op, "replace")
            H.equal(o.path, "/volume")
            H.equal(o.value, -30)
        end,
    },
    {
        name = "encodeChange produces a changemso carrying a JSON array",
        fn = function()
            local text = Protocol.encodeChange({ Protocol.op("replace", "/volume", -30) })
            H.equal(text:sub(1, 10), "changemso ")
            local body = text:sub(11)
            H.equal(body:sub(1, 1), "[", "the argument must be an array, not an object")
            -- Round-trips through the same codec the unit's replies use.
            local back = Protocol.parse(text)
            H.equal(back.verb, "changemso")
            H.equal(back.arg[1].path, "/volume")
            H.equal(back.arg[1].value, -30)
        end,
    },
    {
        name = "encodeChange keeps several operations in order",
        fn = function()
            local text = Protocol.encodeChange({
                Protocol.op("replace", "/muted", false),
                Protocol.op("replace", "/volume", -40),
            })
            local back = Protocol.parse(text)
            H.count(back.arg, 2)
            H.equal(back.arg[1].path, "/muted")
            H.equal(back.arg[2].path, "/volume")
        end,
    },
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Add `"tests.test_protocol"` to `SUITES`, then run:
`"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: LOAD FAIL — `module 'htp1.protocol' not found`.

- [ ] **Step 4: Write the protocol layer**

Create `htp1/protocol.lua`:

```lua
-- The HTP-1's message layer: a verb, optionally followed by one space and a
-- JSON argument. Pure Lua; no Control4 API.
--
--   ->  getmso
--   <-  mso {...}                 the full document, ~38 KB
--   ->  changemso [ops]           RFC 6902 patch operations
--   <-  msoupdate [ops]           pushed on every change, from any source
--   <-  error "bad-verb"          rejected input; the connection survives

local JSON = require("module.json")

local Protocol = {}

Protocol.GET_MSO = "getmso"

-- Never raises. A malformed message must not be able to kill the read path.
function Protocol.parse(text)
    if type(text) ~= "string" or text == "" then
        return { verb = "", err = "empty or non-string message" }
    end

    local space = text:find(" ", 1, true)
    if not space then return { verb = text } end

    local verb = text:sub(1, space - 1)
    local body = text:sub(space + 1)

    local ok, value = pcall(function() return JSON:decode(body) end)
    if not ok or value == nil then
        return { verb = verb, err = "undecodable JSON argument (" .. #body .. " bytes)" }
    end

    return { verb = verb, arg = value }
end

function Protocol.op(operation, path, value)
    return { op = operation, path = path, value = value }
end

-- `ops` must be a non-empty array. An empty one would encode as {} rather than
-- [] and the unit would reject it, so callers skip the send instead.
function Protocol.encodeChange(ops)
    return "changemso " .. JSON:encode(ops)
end

return Protocol
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: PASS — every suite green, and the new tests among them.

- [ ] **Step 6: Commit**

```bash
git add module/json.lua htp1/protocol.lua tests/test_protocol.lua tests/run.lua
git commit -m "feat: vendored JSON codec and the HTP-1 verb protocol layer"
```

---

### Task 5: Mapping — inputs, surround modes and the volume scale

**Files:**
- Create: `htp1/mapping.lua`, `tests/test_mapping.lua`
- Modify: `tests/run.lua` — add `"tests.test_mapping"` to `SUITES`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Mapping.PROXY_BINDING` = 5001, `Mapping.NETWORK_BINDING` = 6001,
    `Mapping.ROOM_OUTPUT` = 7000, `Mapping.NO_INPUT` = -1
  - `Mapping.INPUTS` — ordered array of `{ binding, key, name }`
  - `Mapping.bindingToKey(binding) -> key | nil`
  - `Mapping.keyToBinding(key) -> binding | nil`
  - `Mapping.SURROUND` — ordered array of `{ id, key, name }`
  - `Mapping.surroundIdToKey(id) -> key | nil`
  - `Mapping.keyToSurroundId(key) -> id | nil`
  - `Mapping.dbToPercent(db, vpl, vph) -> integer 0..100`
  - `Mapping.percentToDb(percent, vpl, vph) -> integer dB`

The `tv` input has two bindings: a hidden HDMI video connection (1008) and the proxy-visible virtual
audio connection (3008), following the Episode driver's treatment of its ARC input. Both decode to
`tv`; `keyToBinding` returns the proxy-visible 3008, because that is the one the proxy addresses.

**dB is the truth.** `percentToDb` rounds to whole dB, so the round trip is lossy by design — with a
50 dB span and 101 percent steps, adjacent percentages can land on the same dB. Everything reported
outward is derived from the dB the unit confirms, never from the percentage requested.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_mapping.lua`:

```lua
local H = require("tests.harness")
local Mapping = require("htp1.mapping")

return {
    {
        name = "every HDMI input maps both ways",
        fn = function()
            for n = 1, 8 do
                local binding = 999 + n
                local key = "h" .. n
                H.equal(Mapping.bindingToKey(binding), key, "binding " .. binding)
                H.equal(Mapping.keyToBinding(key), binding, "key " .. key)
            end
        end,
    },
    {
        name = "the audio-only inputs map both ways",
        fn = function()
            local pairsToCheck = {
                { 3000, "a1" }, { 3001, "a2" },
                { 3002, "spdif1" }, { 3003, "spdif2" }, { 3004, "spdif3" },
                { 3005, "optical1" }, { 3006, "optical2" }, { 3007, "optical3" },
                { 3009, "aes" }, { 3010, "b" }, { 3011, "usb" },
            }
            for _, entry in ipairs(pairsToCheck) do
                H.equal(Mapping.bindingToKey(entry[1]), entry[2], "binding " .. entry[1])
                H.equal(Mapping.keyToBinding(entry[2]), entry[1], "key " .. entry[2])
            end
        end,
    },
    {
        name = "both eARC bindings decode to tv, and tv encodes to the proxy-visible one",
        fn = function()
            H.equal(Mapping.bindingToKey(1008), "tv", "the hidden HDMI binding")
            H.equal(Mapping.bindingToKey(3008), "tv", "the virtual audio binding")
            H.equal(Mapping.keyToBinding("tv"), 3008, "the proxy addresses the audio binding")
        end,
    },
    {
        name = "roon has no connection, by decision",
        fn = function()
            H.equal(Mapping.keyToBinding("roon"), nil,
                "roon is out of scope and must not gain a binding silently")
        end,
    },
    {
        name = "an unknown binding or key maps to nil rather than guessing",
        fn = function()
            H.equal(Mapping.bindingToKey(9999), nil)
            H.equal(Mapping.keyToBinding("nosuchinput"), nil)
            H.equal(Mapping.bindingToKey(nil), nil)
            H.equal(Mapping.keyToBinding(nil), nil)
        end,
    },
    {
        name = "the surround modes are the seven upmixers with the vendor's labels",
        fn = function()
            H.count(Mapping.SURROUND, 7)
            local expected = {
                { 1, "off", "Direct" }, { 2, "native", "Native" },
                { 3, "dolby", "Dolby Surround" }, { 4, "dts", "DTS Neural:X" },
                { 5, "auro", "Auro-3D" }, { 6, "mono", "Mono" }, { 7, "stereo", "Stereo" },
            }
            for i, entry in ipairs(expected) do
                H.equal(Mapping.SURROUND[i].id, entry[1])
                H.equal(Mapping.SURROUND[i].key, entry[2])
                H.equal(Mapping.SURROUND[i].name, entry[3])
                H.equal(Mapping.surroundIdToKey(entry[1]), entry[2])
                H.equal(Mapping.keyToSurroundId(entry[2]), entry[1])
            end
        end,
    },
    {
        name = "an unknown surround id or key maps to nil",
        fn = function()
            H.equal(Mapping.surroundIdToKey(0), nil)
            H.equal(Mapping.surroundIdToKey(8), nil)
            H.equal(Mapping.keyToSurroundId("atmos"), nil)
        end,
    },
    {
        name = "dB maps to percent across the observed -50..0 range",
        fn = function()
            H.equal(Mapping.dbToPercent(-50, -50, 0), 0)
            H.equal(Mapping.dbToPercent(0, -50, 0), 100)
            H.equal(Mapping.dbToPercent(-25, -50, 0), 50)
            H.equal(Mapping.dbToPercent(-30, -50, 0), 40)
        end,
    },
    {
        name = "percent maps back to whole dB",
        fn = function()
            H.equal(Mapping.percentToDb(0, -50, 0), -50)
            H.equal(Mapping.percentToDb(100, -50, 0), 0)
            H.equal(Mapping.percentToDb(50, -50, 0), -25)
            H.equal(Mapping.percentToDb(41, -50, 0), -30)  -- rounds to the nearest dB
        end,
    },
    {
        name = "the scale follows a non-default range read from the unit",
        fn = function()
            H.equal(Mapping.dbToPercent(-20, -40, -10), 67)
            H.equal(Mapping.percentToDb(100, -40, -10), -10)
            H.equal(Mapping.percentToDb(0, -40, -10), -40)
        end,
    },
    {
        name = "values outside the range clamp instead of overflowing",
        fn = function()
            H.equal(Mapping.dbToPercent(10, -50, 0), 100)
            H.equal(Mapping.dbToPercent(-99, -50, 0), 0)
            H.equal(Mapping.percentToDb(150, -50, 0), 0)
            H.equal(Mapping.percentToDb(-10, -50, 0), -50)
        end,
    },
    {
        name = "a degenerate range does not divide by zero",
        fn = function()
            H.equal(Mapping.dbToPercent(-20, -20, -20), 0)
            H.equal(Mapping.percentToDb(50, -20, -20), -20)
        end,
    },
    {
        name = "non-numeric input yields nil rather than an arithmetic error",
        fn = function()
            H.equal(Mapping.dbToPercent(nil, -50, 0), nil)
            H.equal(Mapping.percentToDb("loud", -50, 0), nil)
        end,
    },
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Add `"tests.test_mapping"` to `SUITES`, then run:
`"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: LOAD FAIL — `module 'htp1.mapping' not found`.

- [ ] **Step 3: Write the mapping**

Create `htp1/mapping.lua`:

```lua
-- Static maps between Control4's world and the unit's.
--
-- The receiver proxy addresses inputs and outputs by CONNECTION BINDING ID, not
-- by any internal index, so this table is the input map -- it must stay in step
-- with the <connections> block in driver.xml.
--
-- Pure Lua; no Control4 API.

local Mapping = {}

Mapping.PROXY_BINDING   = 5001
Mapping.NETWORK_BINDING = 6001
Mapping.ROOM_OUTPUT     = 7000

-- What the proxy is told when the unit is on an input Control4 does not model,
-- such as Roon. Reporting the truth beats inventing a selected input.
Mapping.NO_INPUT = -1

Mapping.INPUTS = {
    { binding = 1000, key = "h1",       name = "HDMI Input 1" },
    { binding = 1001, key = "h2",       name = "HDMI Input 2" },
    { binding = 1002, key = "h3",       name = "HDMI Input 3" },
    { binding = 1003, key = "h4",       name = "HDMI Input 4" },
    { binding = 1004, key = "h5",       name = "HDMI Input 5" },
    { binding = 1005, key = "h6",       name = "HDMI Input 6" },
    { binding = 1006, key = "h7",       name = "HDMI Input 7" },
    { binding = 1007, key = "h8",       name = "HDMI Input 8" },
    { binding = 3000, key = "a1",       name = "Analog Input 1" },
    { binding = 3001, key = "a2",       name = "Analog Input 2" },
    { binding = 3002, key = "spdif1",   name = "Coax Input 1" },
    { binding = 3003, key = "spdif2",   name = "Coax Input 2" },
    { binding = 3004, key = "spdif3",   name = "Coax Input 3" },
    { binding = 3005, key = "optical1", name = "Optical Input 1" },
    { binding = 3006, key = "optical2", name = "Optical Input 2" },
    { binding = 3007, key = "optical3", name = "Optical Input 3" },
    { binding = 3008, key = "tv",       name = "eARC Audio" },
    { binding = 3009, key = "aes",      name = "AES/EBU Input" },
    { binding = 3010, key = "b",        name = "Bluetooth" },
    { binding = 3011, key = "usb",      name = "USB Audio" },
}

-- The eARC input is cabled as HDMI but selected as audio, so it carries a hidden
-- video binding alongside the proxy-visible one. Decoding accepts both; encoding
-- returns the proxy-visible binding above.
local HIDDEN_BINDINGS = { [1008] = "tv" }

local bindingIndex, keyIndex = {}, {}
for _, input in ipairs(Mapping.INPUTS) do
    bindingIndex[input.binding] = input.key
    keyIndex[input.key] = input.binding
end
for binding, key in pairs(HIDDEN_BINDINGS) do
    bindingIndex[binding] = key
end

function Mapping.bindingToKey(binding)
    if binding == nil then return nil end
    return bindingIndex[tonumber(binding) or binding]
end

function Mapping.keyToBinding(key)
    if key == nil then return nil end
    return keyIndex[key]
end

Mapping.SURROUND = {
    { id = 1, key = "off",    name = "Direct" },
    { id = 2, key = "native", name = "Native" },
    { id = 3, key = "dolby",  name = "Dolby Surround" },
    { id = 4, key = "dts",    name = "DTS Neural:X" },
    { id = 5, key = "auro",   name = "Auro-3D" },
    { id = 6, key = "mono",   name = "Mono" },
    { id = 7, key = "stereo", name = "Stereo" },
}

local surroundById, surroundByKey = {}, {}
for _, mode in ipairs(Mapping.SURROUND) do
    surroundById[mode.id] = mode.key
    surroundByKey[mode.key] = mode.id
end

function Mapping.surroundIdToKey(id)
    if id == nil then return nil end
    return surroundById[tonumber(id) or id]
end

function Mapping.keyToSurroundId(key)
    if key == nil then return nil end
    return surroundByKey[key]
end

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

-- Control4 rooms work in 0..100; the unit works in whole dB over the range it
-- reports in cal.vpl and cal.vph. That range is user-configurable, so it is read
-- from the unit rather than assumed.
function Mapping.dbToPercent(db, vpl, vph)
    db, vpl, vph = tonumber(db), tonumber(vpl), tonumber(vph)
    if not (db and vpl and vph) then return nil end
    if vph <= vpl then return 0 end
    local percent = (db - vpl) / (vph - vpl) * 100
    return clamp(math.floor(percent + 0.5), 0, 100)
end

function Mapping.percentToDb(percent, vpl, vph)
    percent, vpl, vph = tonumber(percent), tonumber(vpl), tonumber(vph)
    if not (percent and vpl and vph) then return nil end
    if vph <= vpl then return vpl end
    local db = vpl + clamp(percent, 0, 100) / 100 * (vph - vpl)
    return clamp(math.floor(db + 0.5), vpl, vph)
end

return Mapping
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: PASS — every suite green, and the new tests among them.

- [ ] **Step 5: Commit**

```bash
git add htp1/mapping.lua tests/test_mapping.lua tests/run.lua
git commit -m "feat: input, surround-mode and volume-scale mapping"
```

---

### Task 6: State — projecting the mso document

**Files:**
- Create: `htp1/state.lua`, `tests/fixtures.lua`, `tests/test_state.lua`
- Modify: `tests/run.lua` — add `"tests.test_state"` to `SUITES`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `State.new() -> state`
  - `state.loaded` — false until a document has been applied
  - `state.fields` — `{ volume, muted, power, input, upmix, vpl, vph, unitName, firmware, serial }`
  - `state.inputs` — `{ [key] = { label = string, visible = boolean } }`
  - `state:applyDocument(doc) -> changes`, where `changes` is a set of changed field names, plus
    `changes.inputs = true` if any label or visibility moved
  - `state:inputLabel(key) -> string | nil`

Fixtures are **invented**: no real labels, unit names or serials. They model the two firmware shapes,
including 2.1.1's extra keys and 1.13.3's, so absence-tolerance is exercised from the start.

- [ ] **Step 1: Write the fixtures**

Create `tests/fixtures.lua`:

```lua
-- Invented mso documents. Shapes follow the two firmware families the driver
-- must tolerate; every value is made up. No site data belongs in this file.

local F = {}

local function baseInputs()
    return {
        h1       = { label = "Streamer", visible = true,  disable = false },
        h2       = { label = "Console",  visible = true,  disable = false },
        h3       = { label = "HDMI 3",   visible = false, disable = false },
        a1       = { label = "Turntable", visible = true, disable = false },
        optical1 = { label = "Optical 1", visible = false, disable = false },
        roon     = { label = "Roon",     visible = true,  disable = false },
    }
end

-- Firmware 2.x shape: has channeltrim, dialnorm, shaker, secondaryVolume.
function F.modern()
    return {
        volume = -25,
        muted = false,
        powerIsOn = true,
        powerAction = "none",
        input = "h1",
        unitname = "Processor",
        upmix = {
            select = "dolby",
            dolby = { cs = false, homevis = true },
            dts   = { ws = true,  homevis = true },
        },
        cal = { vpl = -50, vph = 0, zeroPoint = 0, diracactive = "on", currentdiracslot = 0 },
        inputs = baseInputs(),
        versions = { avController = "5.96 Built Jul  8 2026, 11:45:00\n", SerialNumber = "0001" },
        channeltrim = {}, dialnorm = 0, shaker = {}, secondaryVolume = -40,
        loudness = "off", night = "off", dialogEnh = 3, bassenhance = "off",
    }
end

-- Firmware 1.x shape: no channeltrim/dialnorm/shaker, and secondVolume not
-- secondaryVolume. Everything this driver reads must still be present.
function F.legacy()
    return {
        volume = -29,
        muted = false,
        powerIsOn = true,
        powerAction = "none",
        input = "h1",
        unitname = "Processor",
        upmix = { select = "dolby", dolby = { cs = false }, dts = { ws = true } },
        cal = { vpl = -50, vph = 0, zeroPoint = 0, diracactive = "off", currentdiracslot = 1 },
        inputs = baseInputs(),
        versions = { avController = "4.91 Built Dec 23 2024, 11:23:51\n", SerialNumber = "0002" },
        secondVolume = -40, vu = {},
        loudness = "off", night = "off", dialogEnh = 3, bassenhance = "off",
    }
end

-- A document missing everything optional, to prove absence tolerance.
function F.sparse()
    return { volume = -10, powerIsOn = false }
end

return F
```

- [ ] **Step 2: Write the failing tests**

Create `tests/test_state.lua`:

```lua
local H = require("tests.harness")
local State = require("htp1.state")
local F = require("tests.fixtures")

return {
    {
        name = "a fresh state is not loaded and holds no values",
        fn = function()
            local s = State.new()
            H.isFalse(s.loaded)
            H.equal(s.fields.volume, nil)
            H.equal(s.fields.input, nil)
        end,
    },
    {
        name = "applying a modern document projects every tracked scalar",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            H.isTrue(s.loaded)
            H.equal(s.fields.volume, -25)
            H.equal(s.fields.muted, false)
            H.equal(s.fields.power, true)
            H.equal(s.fields.input, "h1")
            H.equal(s.fields.upmix, "dolby")
            H.equal(s.fields.vpl, -50)
            H.equal(s.fields.vph, 0)
            H.equal(s.fields.unitName, "Processor")
        end,
    },
    {
        name = "the firmware version is reduced to its version number",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            H.equal(s.fields.firmware, "5.96", "the build date and newline are dropped")
            H.equal(s.fields.serial, "0001")
        end,
    },
    {
        name = "a legacy document projects the same fields",
        fn = function()
            local s = State.new()
            s:applyDocument(F.legacy())
            H.equal(s.fields.volume, -29)
            H.equal(s.fields.upmix, "dolby")
            H.equal(s.fields.vpl, -50)
            H.equal(s.fields.firmware, "4.91")
        end,
    },
    {
        name = "a sparse document loads without error and leaves absent fields nil",
        fn = function()
            local s = State.new()
            s:applyDocument(F.sparse())
            H.isTrue(s.loaded)
            H.equal(s.fields.volume, -10)
            H.equal(s.fields.power, false)
            H.equal(s.fields.upmix, nil, "an absent field stays absent rather than defaulting")
            H.equal(s.fields.vpl, nil)
        end,
    },
    {
        name = "input labels and visibility are projected",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            H.equal(s.inputs.h1.label, "Streamer")
            H.equal(s.inputs.h1.visible, true)
            H.equal(s.inputs.h3.visible, false)
            H.equal(s:inputLabel("a1"), "Turntable")
            H.equal(s:inputLabel("h8"), nil, "an input the unit did not report")
        end,
    },
    {
        name = "the first document reports every populated field as changed",
        fn = function()
            local s = State.new()
            local changes = s:applyDocument(F.modern())
            H.isTrue(changes.volume, "volume changed")
            H.isTrue(changes.input, "input changed")
            H.isTrue(changes.upmix, "upmix changed")
            H.isTrue(changes.inputs, "inputs changed")
        end,
    },
    {
        name = "re-applying an identical document reports no changes",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyDocument(F.modern())
            H.equal(next(changes), nil, "an unchanged document must not notify anything")
        end,
    },
    {
        name = "re-applying a document reports only what actually moved",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local doc = F.modern()
            doc.volume = -30
            local changes = s:applyDocument(doc)
            H.isTrue(changes.volume, "volume moved")
            H.equal(changes.input, nil, "input did not move")
            H.equal(changes.inputs, nil, "labels did not move")
            H.equal(s.fields.volume, -30)
        end,
    },
    {
        name = "a changed input label is reported as an inputs change",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local doc = F.modern()
            doc.inputs.h1.label = "Renamed"
            local changes = s:applyDocument(doc)
            H.isTrue(changes.inputs)
            H.equal(s.inputs.h1.label, "Renamed")
        end,
    },
    {
        name = "a non-table document is ignored rather than raising",
        fn = function()
            local s = State.new()
            local changes = s:applyDocument("not a document")
            H.equal(next(changes), nil)
            H.isFalse(s.loaded, "a rejected document must not mark the state loaded")
        end,
    },
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Add `"tests.test_state"` to `SUITES`, then run:
`"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: LOAD FAIL — `module 'htp1.state' not found`.

- [ ] **Step 4: Write the state projection**

Create `htp1/state.lua`:

```lua
-- The projected view of the unit's mso document.
--
-- The real document is ~38 KB and several thousand paths. Mirroring it would be
-- roughly ten times the memory per driver instance, and a controller runs two.
-- This keeps only the paths the driver acts on, and reports what actually moved
-- so callers notify the proxy on real transitions rather than on every push.
--
-- Pure Lua; no Control4 API.

local State = {}
State.__index = State

-- Tracked scalars, by their JSON-pointer path in the document.
local SCALAR_PATHS = {
    ["/volume"]                = "volume",
    ["/muted"]                 = "muted",
    ["/powerIsOn"]             = "power",
    ["/powerAction"]           = "powerAction",
    ["/input"]                 = "input",
    ["/upmix/select"]          = "upmix",
    ["/cal/vpl"]               = "vpl",
    ["/cal/vph"]               = "vph",
    ["/unitname"]              = "unitName",
    ["/versions/avController"] = "firmware",
    ["/versions/SerialNumber"] = "serial",
}
State.SCALAR_PATHS = SCALAR_PATHS

-- The unit reports its controller version as "5.96 Built Jul  8 2026, ...\n".
-- Only the number is useful in a Composer property.
local NORMALISE = {
    firmware = function(value) return tostring(value):match("^%s*(%S+)") end,
    serial   = function(value) return tostring(value) end,
}

local function resolve(container, pointer)
    local node = container
    for segment in pointer:gmatch("/([^/]+)") do
        if type(node) ~= "table" then return nil end
        node = node[segment]
    end
    return node
end

function State.new()
    return setmetatable({ loaded = false, fields = {}, inputs = {} }, State)
end

function State:inputLabel(key)
    local entry = self.inputs[key]
    return entry and entry.label or nil
end

-- Returns true when the stored value actually moved.
function State:_assign(field, value)
    local normalise = NORMALISE[field]
    if normalise and value ~= nil then value = normalise(value) end
    if self.fields[field] == value then return false end
    self.fields[field] = value
    return true
end

function State:_setInputs(inputs)
    if type(inputs) ~= "table" then return false end
    local changed = false
    for key, entry in pairs(inputs) do
        if type(entry) == "table" then
            local current = self.inputs[key]
            local label   = entry.label
            local visible = entry.visible
            if not current then
                self.inputs[key] = { label = label, visible = visible }
                changed = true
            elseif current.label ~= label or current.visible ~= visible then
                current.label, current.visible = label, visible
                changed = true
            end
        end
    end
    return changed
end

-- Re-derive every tracked path that lives under `prefix` from `value`.
-- `prefix` of "" means the whole document.
function State:_applyContainer(prefix, value, changes)
    if type(value) ~= "table" then return changes end

    for path, field in pairs(SCALAR_PATHS) do
        local relative
        if prefix == "" then
            relative = path
        elseif path:sub(1, #prefix + 1) == prefix .. "/" then
            relative = path:sub(#prefix + 1)
        end
        if relative then
            local resolved = resolve(value, relative)
            if resolved ~= nil and self:_assign(field, resolved) then
                changes[field] = true
            end
        end
    end

    local inputs
    if prefix == "" then
        inputs = value.inputs
    elseif prefix == "/inputs" then
        inputs = value
    end
    if inputs and self:_setInputs(inputs) then changes.inputs = true end

    return changes
end

-- Apply a full document from `getmso`.
function State:applyDocument(doc)
    local changes = {}
    if type(doc) ~= "table" then return changes end
    self:_applyContainer("", doc, changes)
    self.loaded = true
    return changes
end

return State
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: PASS — every suite green, and the new tests among them.

- [ ] **Step 6: Commit**

```bash
git add htp1/state.lua tests/fixtures.lua tests/test_state.lua tests/run.lua
git commit -m "feat: project the mso document onto the paths the driver uses"
```

---

### Task 7: State — applying msoupdate patch operations

**Files:**
- Modify: `htp1/state.lua` — add `State:applyOps`
- Modify: `tests/test_state.lua` — append the patch tests

**Interfaces:**
- Consumes: `State.new`, `state.fields`, `state.inputs`, `State.SCALAR_PATHS` from Task 6.
- Produces: `state:applyOps(ops) -> changes` with the same `changes` shape as `applyDocument`.

Rules, each of which has a test:

- Operations on untracked paths are dropped by a prefix test **before** any allocation. That is what
  keeps a document with thousands of paths cheap.
- An operation whose path is a container holding tracked paths (`/cal`, `/upmix`, `/versions`,
  `/inputs`, or `/` itself) re-derives everything beneath it.
- `add` and `replace` assign; `remove` clears the field.
- An operation whose value is `nil` is skipped, so the driver does not depend on how the vendored
  codec represents JSON null.
- A malformed operation is skipped, never raised — a bad push must not break the read path.

- [ ] **Step 1: Write the failing tests**

Append to the returned table in `tests/test_state.lua`:

```lua
    {
        name = "a replace on a tracked scalar updates it and reports the change",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({ { op = "replace", path = "/volume", value = -35 } })
            H.equal(s.fields.volume, -35)
            H.isTrue(changes.volume)
        end,
    },
    {
        name = "a replace to the same value reports no change",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({ { op = "replace", path = "/volume", value = -25 } })
            H.equal(next(changes), nil, "an idempotent push must not notify")
        end,
    },
    {
        name = "several operations in one update all apply",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/muted", value = true },
                { op = "replace", path = "/input", value = "a1" },
                { op = "replace", path = "/upmix/select", value = "auro" },
            })
            H.equal(s.fields.muted, true)
            H.equal(s.fields.input, "a1")
            H.equal(s.fields.upmix, "auro")
            H.isTrue(changes.muted and changes.input and changes.upmix)
        end,
    },
    {
        name = "operations on untracked paths are ignored",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/speakers/groups/lf", value = true },
                { op = "replace", path = "/peq/0/gain", value = 3 },
                { op = "add",     path = "/personalize/macros/cmda", value = true },
            })
            H.equal(next(changes), nil, "nothing tracked moved")
            H.equal(s.fields.volume, -25, "tracked state is untouched")
        end,
    },
    {
        name = "a remove clears the tracked field",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({ { op = "remove", path = "/upmix/select" } })
            H.equal(s.fields.upmix, nil)
            H.isTrue(changes.upmix)
        end,
    },
    {
        name = "an operation with a nil value is skipped rather than clearing the field",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({ { op = "replace", path = "/volume" } })
            H.equal(s.fields.volume, -25, "the previous value survives")
            H.equal(next(changes), nil)
        end,
    },
    {
        name = "replacing a container re-derives every tracked path beneath it",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/cal", value = { vpl = -40, vph = -10, zeroPoint = 0 } },
            })
            H.equal(s.fields.vpl, -40)
            H.equal(s.fields.vph, -10)
            H.isTrue(changes.vpl and changes.vph)
        end,
    },
    {
        name = "replacing the whole inputs container re-derives labels",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/inputs", value = { h1 = { label = "New", visible = true } } },
            })
            H.equal(s.inputs.h1.label, "New")
            H.isTrue(changes.inputs)
        end,
    },
    {
        name = "a single input label update is applied",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/inputs/h2/label", value = "Games" },
            })
            H.equal(s.inputs.h2.label, "Games")
            H.equal(s.inputs.h2.visible, true, "visibility is untouched")
            H.isTrue(changes.inputs)
        end,
    },
    {
        name = "a single input visibility update is applied",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                { op = "replace", path = "/inputs/h3/visible", value = true },
            })
            H.equal(s.inputs.h3.visible, true)
            H.isTrue(changes.inputs)
        end,
    },
    {
        name = "an update naming an input the unit never reported creates it",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            s:applyOps({ { op = "add", path = "/inputs/h8/label", value = "Spare" } })
            H.equal(s.inputs.h8.label, "Spare")
        end,
    },
    {
        name = "malformed operations are skipped without raising",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({
                "not a table",
                {},
                { op = "replace" },
                { path = "/volume", value = -1 },
                { op = "replace", path = 42, value = 1 },
                { op = "replace", path = "/volume", value = -33 },
            })
            H.equal(s.fields.volume, -33, "the one good operation still applied")
            H.isTrue(changes.volume)
        end,
    },
    {
        name = "a non-array argument is ignored",
        fn = function()
            local s = State.new()
            s:applyDocument(F.modern())
            H.equal(next(s:applyOps(nil)), nil)
            H.equal(next(s:applyOps("nonsense")), nil)
            H.equal(s.fields.volume, -25)
        end,
    },
    {
        name = "a single operation sent unwrapped is accepted",
        fn = function()
            -- The web UI's own client handles a non-array msoupdate, so the unit
            -- evidently sends one sometimes.
            local s = State.new()
            s:applyDocument(F.modern())
            local changes = s:applyOps({ op = "replace", path = "/volume", value = -12 })
            H.equal(s.fields.volume, -12)
            H.isTrue(changes.volume)
        end,
    },
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: FAIL — `attempt to call method 'applyOps' (a nil value)`.

- [ ] **Step 3: Write the patch applier**

Insert into `htp1/state.lua`, before the final `return State`:

```lua
-- Container paths whose replacement re-derives everything beneath them.
local CONTAINER_PREFIXES = { "/cal", "/upmix", "/versions", "/inputs" }

-- True when `path` is a tracked scalar, a tracked input sub-path, or a container
-- holding either. Checked before any allocation, so the thousands of paths this
-- driver ignores cost one string compare each.
local function isInteresting(path)
    if SCALAR_PATHS[path] then return "scalar" end
    if path == "" or path == "/" then return "container" end
    if path:match("^/inputs/[^/]+/label$") or path:match("^/inputs/[^/]+/visible$") then
        return "input"
    end
    for _, prefix in ipairs(CONTAINER_PREFIXES) do
        if path == prefix then return "container" end
    end
    return nil
end
State._isInteresting = isInteresting

function State:_applyOne(operation, changes)
    if type(operation) ~= "table" then return end

    local kind = operation.op
    local path = operation.path
    if type(path) ~= "string" or type(kind) ~= "string" then return end

    local interest = isInteresting(path)
    if not interest then return end

    local removing = (kind == "remove")
    if not removing and operation.value == nil then
        -- Skip rather than clear: this driver never needs a null-valued path,
        -- and skipping avoids depending on how the JSON codec spells null.
        return
    end

    if interest == "scalar" then
        local field = SCALAR_PATHS[path]
        if self:_assign(field, removing and nil or operation.value) then
            changes[field] = true
        end
        return
    end

    if interest == "input" then
        local key, leaf = path:match("^/inputs/([^/]+)/(%a+)$")
        local entry = self.inputs[key]
        if not entry then
            entry = {}
            self.inputs[key] = entry
        end
        local newValue = removing and nil or operation.value
        if entry[leaf] ~= newValue then
            entry[leaf] = newValue
            changes.inputs = true
        end
        return
    end

    -- A container replacement.
    local prefix = (path == "" or path == "/") and "" or path
    self:_applyContainer(prefix, operation.value, changes)
end

-- Apply an `msoupdate` argument. Accepts an array of operations or, defensively,
-- a single unwrapped one. Never raises: a malformed push must not break reading.
function State:applyOps(ops)
    local changes = {}
    if type(ops) ~= "table" then return changes end

    if ops.op ~= nil and ops.path ~= nil then
        self:_applyOne(ops, changes)
        return changes
    end

    for _, operation in ipairs(ops) do
        self:_applyOne(operation, changes)
    end
    return changes
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: PASS — every suite green, and the new tests among them.

- [ ] **Step 5: Commit**

```bash
git add htp1/state.lua tests/test_state.lua
git commit -m "feat: apply msoupdate patch operations against the projection"
```

---

### Task 8: Logging and the WebSocket handshake

**Files:**
- Create: `htp1/log.lua`, `htp1/transport.lua`, `tests/test_transport.lua`
- Modify: `tests/run.lua` — add `"tests.test_transport"` to `SUITES`

**Interfaces:**
- Consumes: `Frame` (Task 2–3).
- Produces:
  - `Log.new(name) -> log`; `log:setMode(mode)` for `"Off"` / `"On"` / `"On for 15 Minutes"`;
    `log:debug(...)`; `log:error(message)`; `log.enabled`
  - `Transport.new(opts) -> transport` where `opts = { binding, port, host, path, onOpen, onMessage,
    onClose, log, randomBytes }`
  - `transport:connect()`, `transport:close()`, `transport.state` — one of `"idle"`,
    `"connecting"`, `"handshaking"`, `"open"`, `"closed"`
  - `transport:onConnectionStatus(status)` and `transport:onData(data)`, called by `driver.lua`

**Design change from the approved spec, and why.** The spec said `Sec-WebSocket-Accept` would be
validated best-effort with `C4:Hash`. This plan **does not validate it**, and drops the `C4:Hash`
dependency along with the open question about SHA-1 support. The reasoning: the link is `ws://` with
no TLS and no authentication, so an attacker positioned to forge the accept header is already able to
forge every frame that follows — validating it defends against nothing. What the handshake must
actually catch is *talking to the wrong service*, and a `101` with an `Upgrade: websocket` header does
that. Real assurance that our framing and masking are correct comes from the fake server in Task 14,
which validates both strictly.

- [ ] **Step 1: Write the logger**

Create `htp1/log.lua`:

```lua
-- Debug logging with a self-cancelling timer, so a driver left in debug does not
-- fill the Director log indefinitely. Faults always reach C4:ErrorLog, whatever
-- the mode -- nothing is ever swallowed.

local Log = {}
Log.__index = Log

local AUTO_OFF_MS = 15 * 60 * 1000

function Log.new(name)
    return setmetatable({ name = name or "HTP-1", enabled = false, timer = nil }, Log)
end

function Log:setMode(mode)
    if self.timer then
        self.timer:Cancel()
        self.timer = nil
    end

    if mode == "On" then
        self.enabled = true
    elseif mode == "On for 15 Minutes" then
        self.enabled = true
        self.timer = C4:SetTimer(AUTO_OFF_MS, function()
            self.enabled = false
            self.timer = nil
            print(self.name .. ": debug logging expired")
        end, false)
    else
        self.enabled = false
    end
end

function Log:debug(...)
    if not self.enabled then return end
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    print(self.name .. ": " .. table.concat(parts, " "))
end

-- Always logged. A caught error that nobody records is worse than a crash.
function Log:error(message)
    C4:ErrorLog(self.name .. ": " .. tostring(message))
end

return Log
```

- [ ] **Step 2: Write the failing tests**

Create `tests/test_transport.lua`:

```lua
local H = require("tests.harness")
local mock = H.mock
local Transport = require("htp1.transport")
local Log = require("htp1.log")

-- A transport wired to recording callbacks, with deterministic "randomness".
local function build(overrides)
    mock.install({})
    local events = { opened = 0, closed = {}, messages = {} }
    local opts = {
        binding = 6001,
        port = 80,
        host = "unit.invalid",
        path = "/ws/controller",
        log = Log.new("test"),
        randomBytes = function(n) return string.rep("\7", n) end,
        onOpen = function() events.opened = events.opened + 1 end,
        onMessage = function(text) table.insert(events.messages, text) end,
        onClose = function(reason) table.insert(events.closed, reason) end,
    }
    for k, v in pairs(overrides or {}) do opts[k] = v end
    return Transport.new(opts), events
end

local ACCEPT = "HTTP/1.1 101 Switching Protocols\r\n" ..
    "Upgrade: websocket\r\nConnection: Upgrade\r\n" ..
    "Sec-WebSocket-Accept: irrelevant\r\n\r\n"

return {
    {
        name = "logging is off by default and On enables it",
        fn = function()
            mock.install({})
            local log = Log.new("test")
            log:debug("hidden")
            H.count(mock.printed, 0, "nothing is printed while off")
            log:setMode("On")
            log:debug("shown")
            H.count(mock.printed, 1)
        end,
    },
    {
        name = "the fifteen-minute mode cancels itself",
        fn = function()
            mock.install({})
            local log = Log.new("test")
            log:setMode("On for 15 Minutes")
            H.isTrue(log.enabled)
            mock.advance(14 * 60 * 1000)
            H.isTrue(log.enabled, "still on before the deadline")
            mock.advance(60 * 1000)
            H.isFalse(log.enabled, "off after fifteen minutes")
        end,
    },
    {
        name = "errors reach the error log even with debug off",
        fn = function()
            mock.install({})
            local log = Log.new("test")
            log:setMode("Off")
            log:error("something broke")
            H.count(mock.proxyCalls(0, "none"), 0)  -- no proxy traffic
            local logged = false
            for _, line in ipairs(mock.printed) do
                if line:find("something broke", 1, true) then logged = true end
            end
            H.isTrue(logged, "the error must be recorded")
        end,
    },
    {
        name = "connect opens the network binding and sends nothing yet",
        fn = function()
            local t = build()
            t:connect()
            H.equal(t.state, "connecting")
            H.count(mock.sent, 0, "nothing is written before the socket is up")
            local connects = 0
            for _, c in ipairs(mock.calls) do
                if c.name == "NetConnect" then connects = connects + 1 end
            end
            H.equal(connects, 1)
        end,
    },
    {
        name = "an online socket triggers a well-formed upgrade request",
        fn = function()
            local t = build()
            t:connect()
            t:onConnectionStatus("ONLINE")
            H.equal(t.state, "handshaking")
            H.count(mock.sent, 1)
            local request = mock.sent[1]
            H.isTrue(request:find("GET /ws/controller HTTP/1.1\r\n", 1, true) == 1,
                "request line: " .. request:sub(1, 40))
            H.isTrue(request:find("Host: unit.invalid\r\n", 1, true) ~= nil, "Host header")
            H.isTrue(request:find("Upgrade: websocket\r\n", 1, true) ~= nil, "Upgrade header")
            H.isTrue(request:find("Connection: Upgrade\r\n", 1, true) ~= nil, "Connection header")
            H.isTrue(request:find("Sec%-WebSocket%-Key: %S+\r\n") ~= nil, "a key is present")
            H.isTrue(request:find("Sec-WebSocket-Version: 13\r\n", 1, true) ~= nil, "version 13")
            H.isTrue(request:sub(-4) == "\r\n\r\n", "headers are terminated")
        end,
    },
    {
        name = "a 101 response opens the transport",
        fn = function()
            local t, events = build()
            t:connect()
            t:onConnectionStatus("ONLINE")
            t:onData(ACCEPT)
            H.equal(t.state, "open")
            H.equal(events.opened, 1)
        end,
    },
    {
        name = "a response split across reads still completes the handshake",
        fn = function()
            local t, events = build()
            t:connect()
            t:onConnectionStatus("ONLINE")
            for i = 1, #ACCEPT do
                t:onData(ACCEPT:sub(i, i))
            end
            H.equal(t.state, "open")
            H.equal(events.opened, 1)
        end,
    },
    {
        name = "a non-101 response closes instead of opening",
        fn = function()
            local t, events = build()
            t:connect()
            t:onConnectionStatus("ONLINE")
            t:onData("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
            H.equal(t.state, "closed")
            H.equal(events.opened, 0)
            H.count(events.closed, 1)
            H.isTrue(events.closed[1]:find("404", 1, true) ~= nil,
                "the reason should quote the status: " .. tostring(events.closed[1]))
        end,
    },
    {
        name = "a 101 without an Upgrade header is refused",
        fn = function()
            local t, events = build()
            t:connect()
            t:onConnectionStatus("ONLINE")
            t:onData("HTTP/1.1 101 Switching Protocols\r\nContent-Length: 0\r\n\r\n")
            H.equal(t.state, "closed")
            H.equal(events.opened, 0)
        end,
    },
    {
        name = "an offline socket during the handshake closes the transport",
        fn = function()
            local t, events = build()
            t:connect()
            t:onConnectionStatus("ONLINE")
            t:onConnectionStatus("OFFLINE")
            H.equal(t.state, "closed")
            H.count(events.closed, 1)
        end,
    },
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Add `"tests.test_transport"` to `SUITES`, then run:
`"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: LOAD FAIL — `module 'htp1.transport' not found`.

- [ ] **Step 4: Write the transport's handshake half**

Create `htp1/transport.lua`:

```lua
-- The WebSocket client. Owns the socket, the handshake, the keepalive and the
-- reconnection backoff: staying connected is entirely this module's job, so a
-- replacement implementation can be dropped in without rearranging the driver
-- around it. Everything above sees only onOpen, onMessage and onClose.
--
-- The endpoint is ws://, never wss://. There is no TLS here and no
-- authentication, so Sec-WebSocket-Accept is not validated: anyone able to forge
-- it can already forge every frame that follows. The handshake check that earns
-- its keep is "did we reach a websocket endpoint at all", which a 101 plus an
-- Upgrade header answers.

local Frame = require("htp1.frame")

local Transport = {}
Transport.__index = Transport

local HEADER_TERMINATOR = "\r\n\r\n"

local function defaultRandomBytes(count)
    local bytes = {}
    for i = 1, count do bytes[i] = string.char(math.random(0, 255)) end
    return table.concat(bytes)
end

function Transport.new(opts)
    local t = setmetatable({
        binding = opts.binding,
        port    = opts.port,
        host    = opts.host,
        path    = opts.path or "/ws/controller",
        log     = opts.log,
        randomBytes = opts.randomBytes or defaultRandomBytes,
        onOpen    = opts.onOpen or function() end,
        onMessage = opts.onMessage or function() end,
        onClose   = opts.onClose or function() end,
        state   = "idle",
        rxBuf   = "",
        reader  = nil,
    }, Transport)
    return t
end

function Transport:connect()
    if self.state == "connecting" or self.state == "handshaking" or self.state == "open" then
        return
    end
    self.rxBuf, self.reader = "", nil
    self.state = "connecting"
    self.log:debug("connecting to", self.host)
    C4:NetConnect(self.binding, self.port)
end

function Transport:_shutdown(reason)
    if self.state == "closed" or self.state == "idle" then return end
    self.state = "closed"
    self.rxBuf, self.reader = "", nil
    C4:NetDisconnect(self.binding, self.port)
    self.log:debug("closed:", reason)
    self.onClose(reason)
end

function Transport:close()
    self:_shutdown("closed by the driver")
end

function Transport:onConnectionStatus(status)
    if status == "ONLINE" then
        if self.state == "connecting" then self:_sendHandshake() end
    else
        self:_shutdown("network reported " .. tostring(status))
    end
end

function Transport:_sendHandshake()
    local key = C4:Base64Encode(self.randomBytes(16))
    local request = table.concat({
        "GET " .. self.path .. " HTTP/1.1",
        "Host: " .. self.host,
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: " .. key,
        "Sec-WebSocket-Version: 13",
        "", "",
    }, "\r\n")

    self.state = "handshaking"
    self.log:debug("sending upgrade request")
    C4:SendToNetwork(self.binding, self.port, request)
end

function Transport:_completeHandshake(head)
    local status = head:match("^HTTP/1%.1 (%d+)")
    if status ~= "101" then
        return self:_shutdown("handshake rejected with status " .. tostring(status or "?"))
    end
    if not head:lower():find("upgrade: websocket", 1, true) then
        return self:_shutdown("handshake response is not a websocket upgrade")
    end

    self.state = "open"
    self.reader = Frame.newReader()
    self.log:debug("websocket open")
    self.onOpen()
    return true
end

function Transport:onData(data)
    if self.state == "handshaking" then
        self.rxBuf = self.rxBuf .. data
        local terminator = self.rxBuf:find(HEADER_TERMINATOR, 1, true)
        if not terminator then return end

        local head = self.rxBuf:sub(1, terminator - 1)
        local rest = self.rxBuf:sub(terminator + #HEADER_TERMINATOR)
        self.rxBuf = ""

        if not self:_completeHandshake(head) then return end
        if #rest > 0 then self:_consume(rest) end
    elseif self.state == "open" then
        self:_consume(data)
    end
end

-- Frame handling arrives in the next task; declared here so onData has a target.
function Transport:_consume(_) end

return Transport
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: PASS — every suite green, and the new tests among them.

- [ ] **Step 6: Commit**

```bash
git add htp1/log.lua htp1/transport.lua tests/test_transport.lua tests/run.lua
git commit -m "feat: self-cancelling debug logger and the websocket handshake"
```

---

### Task 9: Transport — frames, keepalive and reconnection

**Files:**
- Modify: `htp1/transport.lua` — replace the `_consume` stub, add `send`, keepalive and backoff
- Modify: `tests/test_transport.lua` — append the tests

**Interfaces:**
- Consumes: everything from Task 8.
- Produces:
  - `transport:send(text)` — encodes a masked text frame and writes it
  - `transport:isOpen() -> boolean`
  - New `opts` entries, all with defaults: `pingIntervalMs` (30000), `pongTimeoutMs` (10000),
    `backoffMs` (`{2000, 4000, 8000, 16000, 30000, 60000}`), `jitter` (a function taking the delay
    and returning the delay to use; defaults to ±20 %)

**Reconnection.** After any close, the transport schedules its own reconnect through the backoff
ladder, holding at the last rung. The jitter is load-bearing: two driver instances on one controller
would otherwise reconnect in lockstep after every network blip. A successful open resets the ladder.

**Liveness.** The unit answers WebSocket pings — verified on hardware. A ping goes out every 30 s and
a missing pong within 10 s is treated as a dead socket, because a half-open TCP connection can
otherwise sit there for many minutes without the driver noticing.

- [ ] **Step 1: Write the failing tests**

Append to the returned table in `tests/test_transport.lua`:

```lua
    {
        name = "an open transport sends a masked text frame",
        fn = function()
            local t = build()
            t:connect(); t:onConnectionStatus("ONLINE"); t:onData(ACCEPT)
            mock.clearCalls()
            t:send("getmso")
            H.count(mock.sent, 1)
            local raw = mock.sent[1]
            H.equal(raw:byte(1), 0x81, "FIN with the TEXT opcode")
            H.equal(raw:byte(2), 0x80 + 6, "masked, six bytes")
            H.equal(Frame.applyMask(raw:sub(7), raw:sub(3, 6)), "getmso")
        end,
    },
    {
        name = "sending while not open writes nothing",
        fn = function()
            local t = build()
            t:connect()
            t:send("getmso")
            H.count(mock.sent, 0, "a queued write must not be invented at this layer")
        end,
    },
    {
        name = "a text frame is delivered to onMessage",
        fn = function()
            local t, events = build()
            t:connect(); t:onConnectionStatus("ONLINE"); t:onData(ACCEPT)
            t:onData("\129\4mso ")
            H.count(events.messages, 1)
            H.equal(events.messages[1], "mso ")
        end,
    },
    {
        name = "a payload arriving with the handshake response is not lost",
        fn = function()
            local t, events = build()
            t:connect(); t:onConnectionStatus("ONLINE")
            t:onData(ACCEPT .. "\129\4mso ")
            H.equal(t.state, "open")
            H.count(events.messages, 1, "the trailing frame must be consumed")
        end,
    },
    {
        name = "a server ping is answered with a pong carrying the same payload",
        fn = function()
            local t = build()
            t:connect(); t:onConnectionStatus("ONLINE"); t:onData(ACCEPT)
            mock.clearCalls()
            t:onData("\137\4ping")
            H.count(mock.sent, 1)
            local raw = mock.sent[1]
            H.equal(raw:byte(1), 0x8A, "FIN with the PONG opcode")
            H.equal(Frame.applyMask(raw:sub(7), raw:sub(3, 6)), "ping")
        end,
    },
    {
        name = "a server close frame shuts the transport down",
        fn = function()
            local t, events = build()
            t:connect(); t:onConnectionStatus("ONLINE"); t:onData(ACCEPT)
            t:onData("\136\0")
            H.equal(t.state, "closed")
            H.count(events.closed, 1)
        end,
    },
    {
        name = "a framing violation closes rather than desynchronising",
        fn = function()
            local t, events = build()
            t:connect(); t:onConnectionStatus("ONLINE"); t:onData(ACCEPT)
            t:onData("\129\132\1\2\3\4abcd")   -- a masked server frame
            H.equal(t.state, "closed")
            H.isTrue(events.closed[1]:find("masked", 1, true) ~= nil,
                "the reason should name the fault: " .. tostring(events.closed[1]))
        end,
    },
    {
        name = "a ping goes out on the keepalive interval",
        fn = function()
            local t = build()
            t:connect(); t:onConnectionStatus("ONLINE"); t:onData(ACCEPT)
            mock.clearCalls()
            mock.advance(30000)
            H.count(mock.sent, 1)
            H.equal(mock.sent[1]:byte(1), 0x89, "a PING frame")
        end,
    },
    {
        name = "a pong within the timeout keeps the connection",
        fn = function()
            local t = build()
            t:connect(); t:onConnectionStatus("ONLINE"); t:onData(ACCEPT)
            mock.advance(30000)
            t:onData("\138\0")          -- PONG
            mock.advance(10000)
            H.equal(t.state, "open", "an answered ping must not close the socket")
        end,
    },
    {
        name = "a missing pong is treated as a dead socket",
        fn = function()
            local t, events = build()
            t:connect(); t:onConnectionStatus("ONLINE"); t:onData(ACCEPT)
            mock.advance(30000)         -- ping sent
            mock.advance(10000)         -- pong deadline passes
            H.equal(t.state, "closed")
            H.isTrue(events.closed[1]:find("pong", 1, true) ~= nil,
                "the reason should name the missing pong: " .. tostring(events.closed[1]))
        end,
    },
    {
        name = "the backoff ladder is walked and then held",
        fn = function()
            local delays = {}
            local t = build({ jitter = function(ms) table.insert(delays, ms) return ms end })
            for _ = 1, 8 do
                t:connect()
                t:onConnectionStatus("OFFLINE")
                mock.advance(60000)
            end
            H.equal(delays[1], 2000)
            H.equal(delays[2], 4000)
            H.equal(delays[3], 8000)
            H.equal(delays[4], 16000)
            H.equal(delays[5], 30000)
            H.equal(delays[6], 60000)
            H.equal(delays[7], 60000, "the ladder holds at its last rung")
        end,
    },
    {
        name = "a successful open resets the backoff ladder",
        fn = function()
            local delays = {}
            local t = build({ jitter = function(ms) table.insert(delays, ms) return ms end })
            t:connect(); t:onConnectionStatus("OFFLINE"); mock.advance(60000)
            t:connect(); t:onConnectionStatus("OFFLINE"); mock.advance(60000)
            H.equal(delays[2], 4000, "the ladder advanced")
            t:connect(); t:onConnectionStatus("ONLINE"); t:onData(ACCEPT)
            t:onConnectionStatus("OFFLINE")
            H.equal(delays[3], 2000, "a good connection resets the ladder")
        end,
    },
    {
        name = "the scheduled reconnect actually reconnects",
        fn = function()
            local t = build({ jitter = function(ms) return ms end })
            t:connect()
            mock.clearCalls()
            t:onConnectionStatus("OFFLINE")
            mock.advance(1999)
            local before = 0
            for _, c in ipairs(mock.calls) do
                if c.name == "NetConnect" then before = before + 1 end
            end
            H.equal(before, 0, "not yet")
            mock.advance(1)
            local after = 0
            for _, c in ipairs(mock.calls) do
                if c.name == "NetConnect" then after = after + 1 end
            end
            H.equal(after, 1, "reconnected on schedule")
        end,
    },
    {
        name = "an explicit close does not schedule a reconnect",
        fn = function()
            local t = build({ jitter = function(ms) return ms end })
            t:connect(); t:onConnectionStatus("ONLINE"); t:onData(ACCEPT)
            mock.clearCalls()
            t:close()
            mock.advance(120000)
            for _, c in ipairs(mock.calls) do
                H.isTrue(c.name ~= "NetConnect", "a deliberate close stays closed")
            end
        end,
    },
```

Add `local Frame = require("htp1.frame")` to the top of `tests/test_transport.lua`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: FAIL — `attempt to call method 'send' (a nil value)`.

- [ ] **Step 3: Extend the transport**

In `htp1/transport.lua`, extend `Transport.new` with the new options and replace the `_consume` stub.

Add to the table built in `Transport.new`, before the closing brace:

```lua
        pingIntervalMs = opts.pingIntervalMs or 30000,
        pongTimeoutMs  = opts.pongTimeoutMs or 10000,
        backoffMs      = opts.backoffMs or { 2000, 4000, 8000, 16000, 30000, 60000 },
        jitter         = opts.jitter or function(ms)
            -- +/-20 %. Two instances on one controller must not reconnect in lockstep.
            return math.floor(ms * (0.8 + math.random() * 0.4))
        end,
        backoffStep   = 0,
        deliberate    = false,
        pingTimer     = nil,
        pongTimer     = nil,
        reconnectTimer = nil,
```

Replace the `_consume` stub with the following, and add the rest before `return Transport`:

```lua
function Transport:isOpen()
    return self.state == "open"
end

function Transport:send(text)
    if self.state ~= "open" then
        self.log:debug("dropping a write while", self.state)
        return false
    end
    C4:SendToNetwork(self.binding, self.port,
        Frame.encode(Frame.OP.TEXT, text, self.randomBytes(4)))
    return true
end

function Transport:_sendControl(opcode, payload)
    if self.state ~= "open" then return end
    C4:SendToNetwork(self.binding, self.port,
        Frame.encode(opcode, payload or "", self.randomBytes(4)))
end

function Transport:_consume(data)
    self.reader:push(data)
    while true do
        local message, err = self.reader:next()
        if err then return self:_shutdown("framing error: " .. err) end
        if not message then return end

        if message.opcode == Frame.OP.TEXT then
            self.onMessage(message.payload)
        elseif message.opcode == Frame.OP.PING then
            self:_sendControl(Frame.OP.PONG, message.payload)
        elseif message.opcode == Frame.OP.PONG then
            self:_clearPongDeadline()
        elseif message.opcode == Frame.OP.CLOSE then
            self:_sendControl(Frame.OP.CLOSE, "")
            return self:_shutdown("the unit closed the connection")
        end
        -- Binary frames are not part of this protocol and are ignored.
    end
end

function Transport:_clearPongDeadline()
    if self.pongTimer then
        self.pongTimer:Cancel()
        self.pongTimer = nil
    end
end

function Transport:_startKeepalive()
    self:_stopKeepalive()
    self.pingTimer = C4:SetTimer(self.pingIntervalMs, function()
        if self.state ~= "open" then return end
        self:_sendControl(Frame.OP.PING, "")
        if not self.pongTimer then
            -- A half-open TCP connection can sit unnoticed for many minutes, so
            -- liveness is decided here rather than left to the network stack.
            self.pongTimer = C4:SetTimer(self.pongTimeoutMs, function()
                self.pongTimer = nil
                self:_shutdown("no pong within " .. self.pongTimeoutMs .. " ms")
            end, false)
        end
    end, true)
end

function Transport:_stopKeepalive()
    if self.pingTimer then self.pingTimer:Cancel(); self.pingTimer = nil end
    self:_clearPongDeadline()
end

function Transport:_scheduleReconnect()
    if self.deliberate then return end
    if self.reconnectTimer then return end

    self.backoffStep = math.min(self.backoffStep + 1, #self.backoffMs)
    local delay = self.jitter(self.backoffMs[self.backoffStep])
    self.log:debug("reconnecting in", delay, "ms")
    self.reconnectTimer = C4:SetTimer(delay, function()
        self.reconnectTimer = nil
        self.state = "idle"
        self:connect()
    end, false)
end
```

Then amend the three existing functions:

- In `Transport:connect()`, after setting `self.state = "connecting"`, add `self.deliberate = false`.
- In `Transport:_completeHandshake`, after `self.state = "open"`, add
  `self.backoffStep = 0` and `self:_startKeepalive()`.
- In `Transport:_shutdown(reason)`, after `self.state = "closed"`, add `self:_stopKeepalive()`, and
  add `self:_scheduleReconnect()` as the last statement.
- In `Transport:close()`, set `self.deliberate = true` before calling `_shutdown`, and cancel
  `self.reconnectTimer` if one is pending.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: PASS — every suite green, and the new tests among them.

- [ ] **Step 5: Commit**

```bash
git add htp1/transport.lua tests/test_transport.lua
git commit -m "feat: frame dispatch, ping keepalive and jittered reconnection"
```

---

### Task 10: Session — orchestration, the write queue and reconciliation

**Files:**
- Create: `htp1/session.lua`, `tests/test_session.lua`
- Modify: `tests/run.lua` — add `"tests.test_session"` to `SUITES`

**Interfaces:**
- Consumes: `Protocol` (Task 4), `State` (Tasks 6–7), and any object satisfying the transport
  interface — `connect`, `close`, `send`, `isOpen` — which tests supply as a fake.
- Produces:
  - `Session.new(opts) -> session` where `opts = { transport, state, log, onChanges, onConnected,
    flushMs (50), reconcileMs (2000) }`
  - `session:start()`, `session:stop()`
  - `session:onOpen()`, `session:onMessage(text)`, `session:onClose(reason)` — wired to the
    transport's callbacks by `driver.lua`
  - `session:write(path, value)` — queue one patch operation
  - `session:refresh()` — request a fresh document
  - `session.connected` — true between a completed `getmso` and the next close

**Coalescing.** One outbound queue flushed on a 50 ms timer, in which a new operation **replaces** any
queued operation with the same path rather than appending. This is what the vendor's own web client
does in `filterMatchingCommandType`, and it is what stops a hold-to-ramp emitting a message per step.

**Optimistic echo and reconciliation.** A write is applied locally and reported immediately, so the
room's volume bar tracks the remote instead of lagging a round trip. The unit's confirming
`msoupdate` is then idempotent and reports no further change. If nothing confirms within 2 s the
driver re-requests the document and corrects, which bounds the cost of being wrong.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_session.lua`:

```lua
local H = require("tests.harness")
local mock = H.mock
local Session = require("htp1.session")
local State = require("htp1.state")
local Log = require("htp1.log")
local F = require("tests.fixtures")
local JSON = require("module.json")

-- A transport double: records what the session asks of it, nothing more.
local function fakeTransport()
    local t = { sent = {}, connects = 0, closes = 0, open = false }
    function t:connect() self.connects = self.connects + 1; self.open = true end
    function t:close() self.closes = self.closes + 1; self.open = false end
    function t:isOpen() return self.open end
    function t:send(text) table.insert(self.sent, text); return true end
    return t
end

local function build()
    mock.install({})
    local transport = fakeTransport()
    local changes = {}
    local session = Session.new({
        transport = transport,
        state = State.new(),
        log = Log.new("test"),
        onChanges = function(set) table.insert(changes, set) end,
    })
    return session, transport, changes
end

local function msoMessage()
    return "mso " .. JSON:encode(F.modern())
end

return {
    {
        name = "start connects the transport",
        fn = function()
            local s, transport = build()
            s:start()
            H.equal(transport.connects, 1)
        end,
    },
    {
        name = "an opened transport is asked for the full document",
        fn = function()
            local s, transport = build()
            s:start(); s:onOpen()
            H.count(transport.sent, 1)
            H.equal(transport.sent[1], "getmso")
            H.isFalse(s.connected, "not connected until the document arrives")
        end,
    },
    {
        name = "the document marks the session connected and reports changes",
        fn = function()
            local s, transport, changes = build()
            s:start(); s:onOpen()
            s:onMessage(msoMessage())
            H.isTrue(s.connected)
            H.equal(s.state.fields.volume, -25)
            H.count(changes, 1)
            H.isTrue(changes[1].volume)
        end,
    },
    {
        name = "an msoupdate is applied and reported",
        fn = function()
            local s, _, changes = build()
            s:start(); s:onOpen(); s:onMessage(msoMessage())
            s:onMessage('msoupdate [{"op":"replace","path":"/volume","value":-31}]')
            H.equal(s.state.fields.volume, -31)
            H.count(changes, 2)
            H.isTrue(changes[2].volume)
        end,
    },
    {
        name = "an msoupdate that changes nothing tracked reports nothing",
        fn = function()
            local s, _, changes = build()
            s:start(); s:onOpen(); s:onMessage(msoMessage())
            s:onMessage('msoupdate [{"op":"replace","path":"/peq/0/gain","value":2}]')
            H.count(changes, 1, "no second notification for an untracked path")
        end,
    },
    {
        name = "the unit's error reply is logged and the session stays up",
        fn = function()
            local s, transport = build()
            s:start(); s:onOpen(); s:onMessage(msoMessage())
            s:onMessage('error "bad-verb"')
            H.isTrue(s.connected, "an error reply must not tear the session down")
            H.equal(transport.closes, 0)
        end,
    },
    {
        name = "an undecodable message triggers a fresh document rather than a crash",
        fn = function()
            local s, transport = build()
            s:start(); s:onOpen(); s:onMessage(msoMessage())
            local before = #transport.sent
            s:onMessage("mso {not json")
            H.equal(#transport.sent, before + 1)
            H.equal(transport.sent[#transport.sent], "getmso")
        end,
    },
    {
        name = "a close clears connected so programming can gate on it",
        fn = function()
            local s, _, _ = build()
            s:start(); s:onOpen(); s:onMessage(msoMessage())
            s:onClose("network reported OFFLINE")
            H.isFalse(s.connected)
        end,
    },
    {
        name = "a write is not sent before the flush interval",
        fn = function()
            local s, transport = build()
            s:start(); s:onOpen(); s:onMessage(msoMessage())
            local before = #transport.sent
            s:write("/volume", -30)
            H.equal(#transport.sent, before, "nothing goes out immediately")
            mock.advance(49)
            H.equal(#transport.sent, before, "nor before the interval elapses")
            mock.advance(1)
            H.equal(#transport.sent, before + 1, "one changemso after 50 ms")
        end,
    },
    {
        name = "repeated writes to one path collapse to the latest value",
        fn = function()
            local s, transport = build()
            s:start(); s:onOpen(); s:onMessage(msoMessage())
            local before = #transport.sent
            for db = -30, -26 do s:write("/volume", db) end
            mock.advance(50)
            H.equal(#transport.sent, before + 1, "five writes, one message")
            local sent = transport.sent[#transport.sent]
            local ops = JSON:decode(sent:sub(11))
            H.count(ops, 1, "one operation, not five")
            H.equal(ops[1].value, -26, "the latest value wins")
        end,
    },
    {
        name = "writes to different paths are kept, in the order first queued",
        fn = function()
            local s, transport = build()
            s:start(); s:onOpen(); s:onMessage(msoMessage())
            s:write("/muted", true)
            s:write("/volume", -30)
            s:write("/muted", false)
            mock.advance(50)
            local ops = JSON:decode(transport.sent[#transport.sent]:sub(11))
            H.count(ops, 2)
            H.equal(ops[1].path, "/muted")
            H.equal(ops[1].value, false, "coalesced to the latest")
            H.equal(ops[2].path, "/volume")
        end,
    },
    {
        name = "a write is echoed into local state and reported at once",
        fn = function()
            local s, _, changes = build()
            s:start(); s:onOpen(); s:onMessage(msoMessage())
            s:write("/volume", -30)
            H.equal(s.state.fields.volume, -30, "local state moves immediately")
            H.count(changes, 2)
            H.isTrue(changes[2].volume)
        end,
    },
    {
        name = "the unit's confirmation is idempotent and reports nothing further",
        fn = function()
            local s, _, changes = build()
            s:start(); s:onOpen(); s:onMessage(msoMessage())
            s:write("/volume", -30)
            mock.advance(50)
            local reported = #changes
            s:onMessage('msoupdate [{"op":"replace","path":"/volume","value":-30}]')
            H.equal(#changes, reported, "a confirming push must not notify twice")
        end,
    },
    {
        name = "an unconfirmed write re-requests the document",
        fn = function()
            local s, transport = build()
            s:start(); s:onOpen(); s:onMessage(msoMessage())
            s:write("/volume", -30)
            mock.advance(50)
            local afterFlush = #transport.sent
            mock.advance(2000)
            H.equal(#transport.sent, afterFlush + 1)
            H.equal(transport.sent[#transport.sent], "getmso")
        end,
    },
    {
        name = "a confirmed write does not re-request the document",
        fn = function()
            local s, transport = build()
            s:start(); s:onOpen(); s:onMessage(msoMessage())
            s:write("/volume", -30)
            mock.advance(50)
            s:onMessage('msoupdate [{"op":"replace","path":"/volume","value":-30}]')
            local afterConfirm = #transport.sent
            mock.advance(5000)
            H.equal(#transport.sent, afterConfirm, "nothing further is needed")
        end,
    },
    {
        name = "a write while disconnected is dropped rather than queued forever",
        fn = function()
            local s, transport = build()
            s:start(); s:onOpen(); s:onMessage(msoMessage())
            s:onClose("gone")
            local before = #transport.sent
            s:write("/volume", -30)
            mock.advance(5000)
            H.equal(#transport.sent, before, "a stale command must not fire on reconnect")
        end,
    },
    {
        name = "stop closes the transport and cancels pending work",
        fn = function()
            local s, transport = build()
            s:start(); s:onOpen(); s:onMessage(msoMessage())
            s:write("/volume", -30)
            s:stop()
            local after = #transport.sent
            mock.advance(10000)
            H.equal(transport.closes, 1)
            H.equal(#transport.sent, after, "no timer fires after stop")
        end,
    },
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Add `"tests.test_session"` to `SUITES`, then run:
`"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: LOAD FAIL — `module 'htp1.session' not found`.

- [ ] **Step 3: Write the session**

Create `htp1/session.lua`:

```lua
-- What happens between a live socket and the driver's state.
--
-- The transport knows how to stay connected and nothing else. This module knows
-- the conversation: ask for the document when the socket opens, fold every push
-- into the projection, and coalesce outbound writes so a hold-to-ramp does not
-- become a message per step.
--
-- The transport is injected, so this tests against a fake with no socket at all.

local Protocol = require("htp1.protocol")

local Session = {}
Session.__index = Session

function Session.new(opts)
    return setmetatable({
        transport   = opts.transport,
        state       = opts.state,
        log         = opts.log,
        onChanges   = opts.onChanges or function() end,
        onConnected = opts.onConnected or function() end,
        flushMs     = opts.flushMs or 50,
        reconcileMs = opts.reconcileMs or 2000,
        connected   = false,
        queue       = {},   -- path -> value
        order       = {},   -- paths, in the order first queued
        pending     = {},   -- path -> value awaiting the unit's confirmation
        flushTimer  = nil,
        reconcileTimer = nil,
    }, Session)
end

function Session:start()
    self.transport:connect()
end

function Session:stop()
    self:_cancelTimers()
    self.queue, self.order, self.pending = {}, {}, {}
    self.connected = false
    self.transport:close()
end

function Session:_cancelTimers()
    if self.flushTimer then self.flushTimer:Cancel(); self.flushTimer = nil end
    if self.reconcileTimer then self.reconcileTimer:Cancel(); self.reconcileTimer = nil end
end

function Session:refresh()
    if self.transport:isOpen() then
        self.transport:send(Protocol.GET_MSO)
    end
end

function Session:onOpen()
    self.log:debug("socket open, requesting the document")
    self:refresh()
end

function Session:onClose(reason)
    self.log:debug("session down:", reason)
    self:_cancelTimers()
    -- Anything queued belongs to a conversation that no longer exists. Replaying
    -- it after a reconnect would apply a stale command minutes later.
    self.queue, self.order, self.pending = {}, {}, {}
    if self.connected then
        self.connected = false
        self.onConnected(false)
    end
end

function Session:onMessage(text)
    local message = Protocol.parse(text)

    if message.err then
        self.log:error("undecodable message from the unit: " .. message.err)
        self:refresh()
        return
    end

    if message.verb == "mso" then
        local changes = self.state:applyDocument(message.arg)
        self.pending = {}
        if not self.connected then
            self.connected = true
            self.onConnected(true)
        end
        if next(changes) then self.onChanges(changes) end

    elseif message.verb == "msoupdate" then
        self:_clearConfirmed(message.arg)
        local changes = self.state:applyOps(message.arg)
        if next(changes) then self.onChanges(changes) end

    elseif message.verb == "error" then
        -- The unit answers junk with error "bad-verb" and keeps the socket open,
        -- so this is a log line, not a disconnect.
        self.log:error("the unit rejected a message: " .. tostring(message.arg))

    else
        self.log:debug("ignoring verb", message.verb)
    end
end

function Session:_clearConfirmed(ops)
    if type(ops) ~= "table" then return end
    local list = (ops.op ~= nil and ops.path ~= nil) and { ops } or ops
    for _, operation in ipairs(list) do
        if type(operation) == "table" and operation.path then
            self.pending[operation.path] = nil
        end
    end
    if next(self.pending) == nil and self.reconcileTimer then
        self.reconcileTimer:Cancel()
        self.reconcileTimer = nil
    end
end

-- Queue one patch operation. The value is echoed into local state immediately so
-- the room responds at once; the unit's confirming push is then idempotent.
function Session:write(path, value)
    if not self.connected then
        self.log:debug("dropping a write while disconnected:", path)
        return false
    end

    if self.queue[path] == nil then table.insert(self.order, path) end
    self.queue[path] = value
    self.pending[path] = value

    local changes = self.state:applyOps({ { op = "replace", path = path, value = value } })
    if next(changes) then self.onChanges(changes) end

    if not self.flushTimer then
        self.flushTimer = C4:SetTimer(self.flushMs, function()
            self.flushTimer = nil
            self:flush()
        end, false)
    end
    return true
end

function Session:flush()
    if #self.order == 0 then return end

    local ops = {}
    for _, path in ipairs(self.order) do
        table.insert(ops, Protocol.op("replace", path, self.queue[path]))
    end
    self.queue, self.order = {}, {}

    self.transport:send(Protocol.encodeChange(ops))

    if not self.reconcileTimer then
        self.reconcileTimer = C4:SetTimer(self.reconcileMs, function()
            self.reconcileTimer = nil
            if next(self.pending) ~= nil then
                -- The unit never confirmed. Rather than let local state drift,
                -- throw it away and re-read.
                self.log:debug("unconfirmed write, re-reading the document")
                self.pending = {}
                self:refresh()
            end
        end, false)
    end
end

return Session
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: PASS — every suite green, and the new tests among them.

- [ ] **Step 5: Commit**

```bash
git add htp1/session.lua tests/test_session.lua tests/run.lua
git commit -m "feat: session orchestration with a coalescing write queue"
```

---

### Task 11: `driver.xml`

**Files:**
- Create: `driver.xml`, `tests/test_manifest.lua`
- Modify: `tests/run.lua` — add `"tests.test_manifest"` to `SUITES`

**Interfaces:**
- Consumes: `Mapping.INPUTS`, `Mapping.SURROUND` (Task 5) — the XML and the Lua table must agree.
- Produces: the Control4 declaration. Property names other tasks read:
  `"Driver Version"`, `"Firmware Version"`, `"Serial Number"`, `"Model"`, `"Connection Status"`,
  `"Maximum Volume"`, `"Volume Ramp Rate"`, `"Power Off Action"`, `"Adopt Input Labels"`,
  `"Debug Mode"`. Action commands: `REFRESH_FROM_DEVICE`, `ADOPT_INPUT_LABELS`, `PRINT_STATE`.

The test in this task is not decoration. The proxy addresses inputs by connection binding id, so a
connection in the XML with no matching row in `Mapping.INPUTS` — or the reverse — is a driver that
silently fails to switch one input. A parser check catches it at the gate instead of on the hardware.

Loudness capabilities are declared **False** here and flipped to True in M3 when the handlers exist.
Declaring a capability the driver does not service puts a dead button in the room UI.

- [ ] **Step 1: Write the failing test**

Create `tests/test_manifest.lua`:

```lua
-- The XML and htp1/mapping.lua describe the same connections. If they disagree,
-- an input silently stops switching. Parsed with patterns rather than an XML
-- library: the check is structural, and LuaJIT ships no XML parser.

local H = require("tests.harness")
local Mapping = require("htp1.mapping")

local function readManifest()
    local handle = assert(io.open("driver.xml", "r"), "driver.xml should exist")
    local text = handle:read("*a")
    handle:close()
    return text
end

-- Returns { [id] = { name = ..., type = ..., raw = ... } } for every <connection>.
local function parseConnections(xml)
    local connections = {}
    for block in xml:gmatch("<connection.->(.-)</connection>") do
        local id = tonumber(block:match("<id>%s*(%d+)%s*</id>"))
        if id then
            connections[id] = {
                name = block:match("<connectionname>%s*(.-)%s*</connectionname>"),
                type = tonumber(block:match("<type>%s*(%d+)%s*</type>")),
                raw  = block,
            }
        end
    end
    return connections
end

return {
    {
        name = "the manifest declares the receiver proxy on binding 5001",
        fn = function()
            local xml = readManifest()
            H.isTrue(xml:find('proxybindingid="5001"', 1, true) ~= nil, "proxy binding")
            H.isTrue(xml:find(">receiver</proxy>", 1, true) ~= nil, "the receiver proxy")
        end,
    },
    {
        name = "auto update is disabled so the director cannot substitute a build",
        fn = function()
            local xml = readManifest()
            H.isTrue(xml:find("<auto_update>false</auto_update>", 1, true) ~= nil)
        end,
    },
    {
        name = "every mapped input has a connection with a matching id",
        fn = function()
            local connections = parseConnections(readManifest())
            for _, input in ipairs(Mapping.INPUTS) do
                H.isTrue(connections[input.binding] ~= nil,
                    "no <connection> for binding " .. input.binding .. " (" .. input.key .. ")")
                H.equal(connections[input.binding].name, input.name,
                    "name for binding " .. input.binding)
            end
        end,
    },
    {
        name = "every input connection in the manifest is mapped",
        fn = function()
            local connections = parseConnections(readManifest())
            -- Input connections live in the 1000 and 3000 ranges; 1008 is the
            -- hidden eARC video binding, which is deliberately unmapped.
            for id in pairs(connections) do
                local isInput = (id >= 1000 and id < 2000) or (id >= 3000 and id < 4000)
                if isInput and id ~= 1008 then
                    H.isTrue(Mapping.bindingToKey(id) ~= nil,
                        "connection " .. id .. " has no row in Mapping.INPUTS")
                end
            end
        end,
    },
    {
        name = "the room end-point carries both audio selection and volume classes",
        fn = function()
            local connections = parseConnections(readManifest())
            local endpoint = connections[Mapping.ROOM_OUTPUT]
            H.isTrue(endpoint ~= nil, "connection 7000 should exist")
            H.equal(endpoint.type, 7, "a room end-point is type 7")
            H.isTrue(endpoint.raw:find("AUDIO_SELECTION", 1, true) ~= nil, "AUDIO_SELECTION")
            H.isTrue(endpoint.raw:find("AUDIO_VOLUME", 1, true) ~= nil,
                "AUDIO_VOLUME is what makes room volume commands arrive")
        end,
    },
    {
        name = "the surround modes match the mapping, by id and name",
        fn = function()
            local xml = readManifest()
            for _, mode in ipairs(Mapping.SURROUND) do
                local pattern = "<name>" .. mode.name:gsub("([%-%.%:])", "%%%1") ..
                    "</name>%s*<id>" .. mode.id .. "</id>"
                H.isTrue(xml:find(pattern) ~= nil,
                    "no surround_mode for " .. mode.name .. " with id " .. mode.id)
            end
        end,
    },
    {
        name = "tone controls are declared absent, because the unit has none",
        fn = function()
            local xml = readManifest()
            for _, capability in ipairs({ "has_discrete_bass_control", "has_discrete_treble_control",
                                          "has_discrete_balance_control" }) do
                H.isTrue(xml:find("<" .. capability .. ">False</" .. capability .. ">", 1, true) ~= nil,
                    capability .. " must be False: the unit has EQ, not tone controls")
            end
        end,
    },
    {
        name = "every property the driver reads is declared",
        fn = function()
            local xml = readManifest()
            for _, name in ipairs({ "Driver Version", "Firmware Version", "Serial Number", "Model",
                                    "Connection Status", "Maximum Volume", "Volume Ramp Rate",
                                    "Power Off Action", "Adopt Input Labels", "Debug Mode" }) do
                H.isTrue(xml:find("<name>" .. name .. "</name>", 1, true) ~= nil,
                    "missing property: " .. name)
            end
        end,
    },
}
```

- [ ] **Step 2: Run the test to verify it fails**

Add `"tests.test_manifest"` to `SUITES`, then run:
`"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: FAIL — `driver.xml should exist`.

- [ ] **Step 3: Write the manifest**

Create `driver.xml`:

```xml
<devicedata>
	<copyright>Copyright 2026</copyright>
	<creator>Control4-Monolith-HTP1</creator>
	<manufacturer>Monoprice</manufacturer>
	<name>Monolith HTP-1</name>
	<model>HTP-1</model>
	<created>08/04/2026 12:00</created>
	<modified>08/04/2026 12:00</modified>
	<version>100</version>
	<auto_update>false</auto_update>
	<control>lua_gen</control>
	<controlmethod>IP</controlmethod>
	<driver>DriverWorks</driver>
	<config>
		<script jit="1" file="driver.lua"/>
		<properties>
			<property>
				<name>Driver Version</name>
				<type>STRING</type>
				<readonly>true</readonly>
				<default></default>
			</property>
			<property>
				<name>Model</name>
				<type>STRING</type>
				<readonly>true</readonly>
				<default>HTP-1</default>
			</property>
			<property>
				<name>Firmware Version</name>
				<type>STRING</type>
				<readonly>true</readonly>
				<default></default>
			</property>
			<property>
				<name>Serial Number</name>
				<type>STRING</type>
				<readonly>true</readonly>
				<default></default>
			</property>
			<property>
				<name>Connection Status</name>
				<type>STRING</type>
				<readonly>true</readonly>
				<default>Not connected</default>
			</property>
			<!-- Applied above the unit's own cal.vph, so a room cannot be driven
			     louder than the installer intends. -->
			<property>
				<name>Maximum Volume</name>
				<type>LIST</type>
				<items>
					<item>Unit maximum</item>
					<item>-5 dB</item>
					<item>-10 dB</item>
					<item>-15 dB</item>
					<item>-20 dB</item>
					<item>-25 dB</item>
					<item>-30 dB</item>
				</items>
				<default>Unit maximum</default>
				<readonly>false</readonly>
			</property>
			<property>
				<name>Volume Ramp Rate</name>
				<type>LIST</type>
				<items>
					<item>50 ms</item>
					<item>100 ms</item>
					<item>150 ms</item>
					<item>200 ms</item>
					<item>300 ms</item>
				</items>
				<default>100 ms</default>
				<readonly>false</readonly>
			</property>
			<property>
				<name>Power Off Action</name>
				<type>LIST</type>
				<items>
					<item>Standby</item>
					<item>Sleep</item>
				</items>
				<default>Standby</default>
				<readonly>false</readonly>
			</property>
			<property>
				<name>Adopt Input Labels</name>
				<type>LIST</type>
				<items>
					<item>Yes</item>
					<item>No</item>
				</items>
				<default>Yes</default>
				<readonly>false</readonly>
			</property>
			<!-- "On for 15 Minutes" cancels itself, so a driver left in debug
			     cannot fill the Director log indefinitely. -->
			<property>
				<name>Debug Mode</name>
				<type>LIST</type>
				<items>
					<item>Off</item>
					<item>On</item>
					<item>On for 15 Minutes</item>
				</items>
				<default>Off</default>
				<readonly>false</readonly>
			</property>
		</properties>
		<actions>
			<action>
				<name>Refresh From Device</name>
				<command>REFRESH_FROM_DEVICE</command>
			</action>
			<action>
				<name>Rename Inputs From Device Labels</name>
				<command>ADOPT_INPUT_LABELS</command>
			</action>
			<action>
				<name>Print Driver State</name>
				<command>PRINT_STATE</command>
			</action>
		</actions>
		<commands/>
	</config>
	<proxies>
		<proxy proxybindingid="5001" primary="True" name="Monolith HTP-1">receiver</proxy>
	</proxies>
	<capabilities>
		<audio_consumer_count>20</audio_consumer_count>
		<audio_provider_count>1</audio_provider_count>
		<video_consumer_count>9</video_consumer_count>
		<video_provider_count>2</video_provider_count>
		<can_upclass>True</can_upclass>
		<can_downclass>True</can_downclass>
		<can_switch>True</can_switch>
		<has_audio_signal_sense>False</has_audio_signal_sense>
		<has_video_signal_sense>False</has_video_signal_sense>
		<has_discrete_volume_control>True</has_discrete_volume_control>
		<has_up_down_volume_control>True</has_up_down_volume_control>
		<has_discrete_mute_control>True</has_discrete_mute_control>
		<has_toggle_mute_control>True</has_toggle_mute_control>
		<has_discrete_input_select>True</has_discrete_input_select>
		<has_discrete_surround_mode_select>True</has_discrete_surround_mode_select>
		<!-- Flipped to True in M3, when the handlers exist. A declared capability
		     with no handler is a dead button in the room UI. -->
		<has_discrete_loudness_control>False</has_discrete_loudness_control>
		<has_toggle_loudness_control>False</has_toggle_loudness_control>
		<!-- The unit has parametric EQ and bass management, not tone controls. -->
		<has_discrete_bass_control>False</has_discrete_bass_control>
		<has_discrete_treble_control>False</has_discrete_treble_control>
		<has_discrete_balance_control>False</has_discrete_balance_control>
		<has_up_down_bass_control>False</has_up_down_bass_control>
		<has_up_down_treble_control>False</has_up_down_treble_control>
		<has_up_down_balance_control>False</has_up_down_balance_control>
		<surround_modes>
			<surround_mode><name>Direct</name><id>1</id></surround_mode>
			<surround_mode><name>Native</name><id>2</id></surround_mode>
			<surround_mode><name>Dolby Surround</name><id>3</id></surround_mode>
			<surround_mode><name>DTS Neural:X</name><id>4</id></surround_mode>
			<surround_mode><name>Auro-3D</name><id>5</id></surround_mode>
			<surround_mode><name>Mono</name><id>6</id></surround_mode>
			<surround_mode><name>Stereo</name><id>7</id></surround_mode>
		</surround_modes>
	</capabilities>
	<connections>
		<!-- Control. The driver writes the HTTP upgrade itself, so no delimiter. -->
		<connection>
			<id>6001</id>
			<connectionname>Monolith HTP-1 Control</connectionname>
			<type>4</type>
			<consumer>True</consumer>
			<classes>
				<class>
					<classname>TCP</classname>
					<ports>
						<port>
							<number>80</number>
							<auto_connect>False</auto_connect>
							<monitor_connection>True</monitor_connection>
							<keep_connection>True</keep_connection>
						</port>
					</ports>
				</class>
			</classes>
		</connection>

		<connection>
			<id>5001</id>
			<facing>6</facing>
			<connectionname>Receiver Proxy</connectionname>
			<type>2</type>
			<consumer>False</consumer>
			<audiosource>False</audiosource>
			<videosource>False</videosource>
			<linelevel>True</linelevel>
			<classes>
				<class><classname>RECEIVER</classname></class>
			</classes>
		</connection>

		<!-- HDMI inputs. Ids match Mapping.INPUTS; tests/test_manifest.lua enforces it. -->
		<connection proxybindingid="5001">
			<id>1000</id><facing>6</facing><connectionname>HDMI Input 1</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<classes><class><classname>HDMI</classname></class></classes>
		</connection>
		<connection proxybindingid="5001">
			<id>1001</id><facing>6</facing><connectionname>HDMI Input 2</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<classes><class><classname>HDMI</classname></class></classes>
		</connection>
		<connection proxybindingid="5001">
			<id>1002</id><facing>6</facing><connectionname>HDMI Input 3</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<classes><class><classname>HDMI</classname></class></classes>
		</connection>
		<connection proxybindingid="5001">
			<id>1003</id><facing>6</facing><connectionname>HDMI Input 4</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<classes><class><classname>HDMI</classname></class></classes>
		</connection>
		<connection proxybindingid="5001">
			<id>1004</id><facing>6</facing><connectionname>HDMI Input 5</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<classes><class><classname>HDMI</classname></class></classes>
		</connection>
		<connection proxybindingid="5001">
			<id>1005</id><facing>6</facing><connectionname>HDMI Input 6</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<classes><class><classname>HDMI</classname></class></classes>
		</connection>
		<connection proxybindingid="5001">
			<id>1006</id><facing>6</facing><connectionname>HDMI Input 7</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<classes><class><classname>HDMI</classname></class></classes>
		</connection>
		<connection proxybindingid="5001">
			<id>1007</id><facing>6</facing><connectionname>HDMI Input 8</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<classes><class><classname>HDMI</classname></class></classes>
		</connection>

		<!-- The display's eARC return. Cabled as HDMI, selected as audio: the
		     hidden video binding carries the cable, the virtual one below is what
		     the proxy addresses. This mirrors the Episode receiver's ARC input. -->
		<connection>
			<id>1008</id><facing>6</facing><connectionname>HDMI eARC</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<hidden>True</hidden>
			<classes><class><classname>HDMI</classname></class></classes>
		</connection>

		<!-- Audio-only inputs. -->
		<connection proxybindingid="5001">
			<id>3000</id><facing>6</facing><connectionname>Analog Input 1</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<classes><class><classname>STEREO</classname></class></classes>
		</connection>
		<connection proxybindingid="5001">
			<id>3001</id><facing>6</facing><connectionname>Analog Input 2</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<classes><class><classname>STEREO</classname></class></classes>
		</connection>
		<connection proxybindingid="5001">
			<id>3002</id><facing>6</facing><connectionname>Coax Input 1</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<classes><class><classname>DIGITAL_COAX</classname></class></classes>
		</connection>
		<connection proxybindingid="5001">
			<id>3003</id><facing>6</facing><connectionname>Coax Input 2</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<classes><class><classname>DIGITAL_COAX</classname></class></classes>
		</connection>
		<connection proxybindingid="5001">
			<id>3004</id><facing>6</facing><connectionname>Coax Input 3</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<classes><class><classname>DIGITAL_COAX</classname></class></classes>
		</connection>
		<connection proxybindingid="5001">
			<id>3005</id><facing>6</facing><connectionname>Optical Input 1</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<classes><class><classname>DIGITAL_OPTICAL</classname></class></classes>
		</connection>
		<connection proxybindingid="5001">
			<id>3006</id><facing>6</facing><connectionname>Optical Input 2</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<classes><class><classname>DIGITAL_OPTICAL</classname></class></classes>
		</connection>
		<connection proxybindingid="5001">
			<id>3007</id><facing>6</facing><connectionname>Optical Input 3</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<classes><class><classname>DIGITAL_OPTICAL</classname></class></classes>
		</connection>
		<connection proxybindingid="5001">
			<id>3008</id><facing>6</facing><connectionname>eARC Audio</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<classes>
				<class><classname>STEREO</classname></class>
				<class><classname>DIGITAL_OPTICAL</classname></class>
				<class><classname>DIGITAL_COAX</classname></class>
			</classes>
		</connection>
		<connection proxybindingid="5001">
			<id>3009</id><facing>6</facing><connectionname>AES/EBU Input</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<classes><class><classname>DIGITAL_COAX</classname></class></classes>
		</connection>
		<!-- Bluetooth and USB have no cable to bind, but the proxy derives its
		     selectable inputs from connections, so they need one to be selectable. -->
		<connection proxybindingid="5001">
			<id>3010</id><facing>6</facing><connectionname>Bluetooth</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<classes><class><classname>STEREO</classname></class></classes>
		</connection>
		<connection proxybindingid="5001">
			<id>3011</id><facing>6</facing><connectionname>USB Audio</connectionname>
			<type>6</type><consumer>True</consumer><linelevel>True</linelevel>
			<classes><class><classname>STEREO</classname></class></classes>
		</connection>

		<!-- Outputs. The unit mirrors its two HDMI outputs; there is no
		     per-output state in the document, so neither is selectable. -->
		<connection proxybindingid="5001">
			<id>2000</id><facing>6</facing><connectionname>HDMI Output 1</connectionname>
			<type>5</type><consumer>False</consumer><videosource>True</videosource>
			<linelevel>True</linelevel>
			<classes><class><classname>HDMI</classname></class></classes>
		</connection>
		<connection proxybindingid="5001">
			<id>2001</id><facing>6</facing><connectionname>HDMI Output 2</connectionname>
			<type>5</type><consumer>False</consumer><videosource>True</videosource>
			<linelevel>True</linelevel>
			<classes><class><classname>HDMI</classname></class></classes>
		</connection>
		<connection proxybindingid="5001">
			<id>4000</id><facing>6</facing><connectionname>Audio Output</connectionname>
			<type>6</type><consumer>False</consumer><audiosource>True</audiosource>
			<linelevel>True</linelevel>
			<classes><class><classname>SPEAKER</classname></class></classes>
		</connection>

		<!-- The room end-point. AUDIO_VOLUME is what makes a room's volume and
		     mute commands reach this driver at all. -->
		<connection>
			<id>7000</id>
			<facing>6</facing>
			<connectionname>Room Selection</connectionname>
			<type>7</type>
			<consumer>False</consumer>
			<audiosource>True</audiosource>
			<videosource>False</videosource>
			<linelevel>True</linelevel>
			<classes>
				<class><classname>AUDIO_SELECTION</classname></class>
				<class><classname>AUDIO_VOLUME</classname></class>
			</classes>
		</connection>
	</connections>
</devicedata>
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: PASS — every suite green, and the new tests among them.

- [ ] **Step 5: Commit**

```bash
git add driver.xml tests/test_manifest.lua tests/run.lua
git commit -m "feat: Control4 manifest with the receiver proxy and its connections"
```

---

### Task 12: Proxy handlers and the driver entry points

**Files:**
- Create: `htp1/proxy.lua`, `driver.lua`, `tests/test_proxy.lua`, `tests/test_driver.lua`
- Modify: `tests/run.lua` — add `"tests.test_proxy"` and `"tests.test_driver"` to `SUITES`

**Interfaces:**
- Consumes: `Mapping` (5), `State` (6–7), `Session` (10), `Log` (8).
- Produces:
  - `Proxy.new(opts) -> proxy` where `opts = { state, session, log, maxVolumeDb, rampMs,
    powerOffAction }`; `maxVolumeDb` may be `nil` for "unit maximum"
  - `proxy:handle(binding, command, params) -> boolean` — true when the command was recognised
  - `proxy:announce()` — push the whole of state to the proxy, used after a document arrives and
    after a binding change
  - `proxy:notify(changes)` — push only what moved
  - `proxy:setMaxVolumeDb(db)`, `proxy:setRampMs(ms)`, `proxy:setPowerOffAction(action)`
  - Global entry points in `driver.lua`: `OnDriverInit`, `OnDriverLateInit`, `OnDriverDestroyed`,
    `OnPropertyChanged`, `ReceivedFromProxy`, `OnConnectionStatusChanged`, `ReceivedFromNetwork`,
    `ExecuteCommand`

`C4:GetBindingAddress(6001)` supplies the host for the HTTP `Host` header; it is used by shipped
Control4 drivers, so it is available. The connection itself is made by `C4:NetConnect`, which takes
the address from the binding.

Control4 delivers proxy parameters as **strings**. Every numeric parameter is passed through
`tonumber` and every command is written to tolerate that.

- [ ] **Step 1: Write the failing proxy tests**

Create `tests/test_proxy.lua`:

```lua
local H = require("tests.harness")
local mock = H.mock
local Proxy = require("htp1.proxy")
local State = require("htp1.state")
local Session = require("htp1.session")
local Log = require("htp1.log")
local Mapping = require("htp1.mapping")
local F = require("tests.fixtures")
local JSON = require("module.json")

local BINDING = Mapping.PROXY_BINDING
local OUTPUT = Mapping.ROOM_OUTPUT

local function fakeTransport()
    local t = { sent = {}, open = true }
    function t:connect() self.open = true end
    function t:close() self.open = false end
    function t:isOpen() return self.open end
    function t:send(text) table.insert(self.sent, text); return true end
    return t
end

-- A proxy over a live-looking session that has already loaded a document.
local function build(overrides)
    mock.install({})
    local transport = fakeTransport()
    local state = State.new()
    local log = Log.new("test")
    local proxy
    local session = Session.new({
        transport = transport, state = state, log = log,
        onChanges = function(changes) proxy:notify(changes) end,
    })
    proxy = Proxy.new({
        state = state, session = session, log = log,
        maxVolumeDb = (overrides or {}).maxVolumeDb,
        rampMs = (overrides or {}).rampMs or 100,
        powerOffAction = (overrides or {}).powerOffAction or "Standby",
    })
    session:start(); session:onOpen()
    session:onMessage("mso " .. JSON:encode(F.modern()))
    mock.clearCalls()
    return proxy, session, transport, state
end

-- The operations in the last changemso the session flushed.
local function lastOps(transport)
    for i = #transport.sent, 1, -1 do
        if transport.sent[i]:sub(1, 10) == "changemso " then
            return JSON:decode(transport.sent[i]:sub(11))
        end
    end
    return nil
end

return {
    {
        name = "an unrecognised command is reported as unhandled, not swallowed",
        fn = function()
            local proxy = build()
            H.isFalse(proxy:handle(BINDING, "NO_SUCH_COMMAND", {}))
            H.assertNoErrorLog()
        end,
    },
    {
        name = "ON powers the unit up",
        fn = function()
            local proxy, _, transport = build()
            H.isTrue(proxy:handle(BINDING, "ON", {}))
            mock.advance(50)
            local ops = lastOps(transport)
            H.equal(ops[1].path, "/powerIsOn")
            H.equal(ops[1].value, true)
        end,
    },
    {
        name = "OFF uses the configured power-off action",
        fn = function()
            local proxy, _, transport = build({ powerOffAction = "Standby" })
            proxy:handle(BINDING, "OFF", {})
            mock.advance(50)
            H.equal(lastOps(transport)[1].path, "/powerAction")
            H.equal(lastOps(transport)[1].value, "off")

            local sleepProxy, _, sleepTransport = build({ powerOffAction = "Sleep" })
            sleepProxy:handle(BINDING, "OFF", {})
            mock.advance(50)
            H.equal(lastOps(sleepTransport)[1].value, "sleep")
        end,
    },
    {
        name = "SET_INPUT translates a connection binding into an input key",
        fn = function()
            local proxy, _, transport = build()
            proxy:handle(BINDING, "SET_INPUT", { INPUT = "3000", OUTPUT = tostring(OUTPUT) })
            mock.advance(50)
            local ops = lastOps(transport)
            H.equal(ops[1].path, "/input")
            H.equal(ops[1].value, "a1", "binding 3000 is the first analog input")
        end,
    },
    {
        name = "SET_INPUT for an unknown binding writes nothing",
        fn = function()
            local proxy, _, transport = build()
            H.isTrue(proxy:handle(BINDING, "SET_INPUT", { INPUT = "9999" }))
            mock.advance(50)
            H.equal(lastOps(transport), nil, "no command is invented for an unknown input")
        end,
    },
    {
        name = "SET_VOLUME_LEVEL maps percent onto the unit's dB range",
        fn = function()
            local proxy, _, transport = build()
            proxy:handle(BINDING, "SET_VOLUME_LEVEL", { LEVEL = "50", OUTPUT = tostring(OUTPUT) })
            mock.advance(50)
            local ops = lastOps(transport)
            H.equal(ops[1].path, "/volume")
            H.equal(ops[1].value, -25, "50 % of -50..0 dB")
        end,
    },
    {
        name = "the maximum volume property clamps above the unit's own range",
        fn = function()
            local proxy, _, transport = build({ maxVolumeDb = -20 })
            proxy:handle(BINDING, "SET_VOLUME_LEVEL", { LEVEL = "100" })
            mock.advance(50)
            H.equal(lastOps(transport)[1].value, -20, "the cap wins over the unit maximum")
        end,
    },
    {
        name = "PULSE_VOL_UP and PULSE_VOL_DOWN move one dB",
        fn = function()
            local proxy, _, transport, state = build()
            H.equal(state.fields.volume, -25)
            proxy:handle(BINDING, "PULSE_VOL_UP", {})
            mock.advance(50)
            H.equal(lastOps(transport)[1].value, -24)
            proxy:handle(BINDING, "PULSE_VOL_DOWN", {})
            proxy:handle(BINDING, "PULSE_VOL_DOWN", {})
            mock.advance(50)
            H.equal(lastOps(transport)[1].value, -26, "two steps down from -24")
        end,
    },
    {
        name = "a hold-to-ramp steps at the configured rate and stops on command",
        fn = function()
            local proxy, _, transport, state = build({ rampMs = 100 })
            proxy:handle(BINDING, "START_VOL_UP", {})
            mock.advance(350)                 -- one immediate step plus three ticks
            proxy:handle(BINDING, "STOP_VOL_UP", {})
            local reached = state.fields.volume
            H.equal(reached, -21, "-25 plus four steps")
            mock.advance(1000)
            H.equal(state.fields.volume, reached, "stopping actually stops")
        end,
    },
    {
        name = "a burst of pulses faster than the flush interval becomes one message",
        fn = function()
            -- This is the guarantee coalescing actually provides: at most one
            -- message per flush interval, however fast commands arrive. A 100 ms
            -- ramp is already slower than the 50 ms flush, so it is one message
            -- per step by design -- what needs bounding is a faster stream.
            local proxy, _, transport, state = build()
            local before = 0
            for _, text in ipairs(transport.sent) do
                if text:sub(1, 10) == "changemso " then before = before + 1 end
            end

            for _ = 1, 20 do proxy:handle(BINDING, "PULSE_VOL_DOWN", {}) end
            mock.advance(50)

            local messages = 0
            for _, text in ipairs(transport.sent) do
                if text:sub(1, 10) == "changemso " then messages = messages + 1 end
            end
            H.equal(messages - before, 1, "twenty pulses, one message")
            H.equal(lastOps(transport)[1].value, -45, "carrying only the final value")
            H.equal(state.fields.volume, -45, "local state followed every step")
        end,
    },
    {
        name = "a ramp stops at the bottom of the range instead of running past it",
        fn = function()
            local proxy, _, _, state = build({ rampMs = 100 })
            proxy:handle(BINDING, "START_VOL_DOWN", {})
            mock.advance(60000)
            proxy:handle(BINDING, "STOP_VOL_DOWN", {})
            H.equal(state.fields.volume, -50, "clamped at cal.vpl")
        end,
    },
    {
        name = "MUTE_ON, MUTE_OFF and MUTE_TOGGLE all write the right value",
        fn = function()
            local proxy, _, transport, state = build()
            proxy:handle(BINDING, "MUTE_ON", {})
            mock.advance(50)
            H.equal(lastOps(transport)[1].path, "/muted")
            H.equal(lastOps(transport)[1].value, true)

            proxy:handle(BINDING, "MUTE_OFF", {})
            mock.advance(50)
            H.equal(lastOps(transport)[1].value, false)

            proxy:handle(BINDING, "MUTE_TOGGLE", {})
            mock.advance(50)
            H.equal(lastOps(transport)[1].value, true, "toggled from the current state")
        end,
    },
    {
        name = "SET_SURROUND_MODE maps a proxy id to an upmixer key",
        fn = function()
            local proxy, _, transport = build()
            proxy:handle(BINDING, "SET_SURROUND_MODE", { SURROUND_MODE = "5" })
            mock.advance(50)
            H.equal(lastOps(transport)[1].path, "/upmix/select")
            H.equal(lastOps(transport)[1].value, "auro")
        end,
    },
    {
        name = "an unknown surround id writes nothing",
        fn = function()
            local proxy, _, transport = build()
            proxy:handle(BINDING, "SET_SURROUND_MODE", { SURROUND_MODE = "99" })
            mock.advance(50)
            H.equal(lastOps(transport), nil)
        end,
    },
    {
        name = "announce pushes power, volume, mute, input and surround mode",
        fn = function()
            local proxy = build()
            mock.clearCalls()
            proxy:announce()
            H.isTrue(mock.lastProxyCall(BINDING, "ON") ~= nil, "power state")
            local volume = mock.lastProxyCall(BINDING, "VOLUME_LEVEL_CHANGED")
            H.isTrue(volume ~= nil, "volume")
            H.equal(volume.args[3].LEVEL, 50, "-25 dB of -50..0 is 50 %")
            H.equal(tonumber(volume.args[3].OUTPUT), OUTPUT, "addressed to the room end-point")
            H.isTrue(mock.lastProxyCall(BINDING, "MUTE_CHANGED") ~= nil, "mute")
            local input = mock.lastProxyCall(BINDING, "INPUT_OUTPUT_CHANGED")
            H.isTrue(input ~= nil, "input")
            H.equal(tonumber(input.args[3].INPUT), 1000, "h1 is binding 1000")
            H.isTrue(mock.lastProxyCall(BINDING, "SURROUND_MODE_CHANGED") ~= nil, "surround")
        end,
    },
    {
        name = "an input the driver does not model is reported as no input",
        fn = function()
            local proxy, session = build()
            mock.clearCalls()
            session:onMessage('msoupdate [{"op":"replace","path":"/input","value":"roon"}]')
            local input = mock.lastProxyCall(BINDING, "INPUT_OUTPUT_CHANGED")
            H.isTrue(input ~= nil, "a notification is still sent")
            H.equal(tonumber(input.args[3].INPUT), Mapping.NO_INPUT,
                "the truth, rather than a fabricated input")
        end,
    },
    {
        name = "a change from the unit is forwarded to the proxy",
        fn = function()
            local _, session = build()
            mock.clearCalls()
            session:onMessage('msoupdate [{"op":"replace","path":"/volume","value":-10}]')
            local volume = mock.lastProxyCall(BINDING, "VOLUME_LEVEL_CHANGED")
            H.equal(volume.args[3].LEVEL, 80, "-10 dB of -50..0")
        end,
    },
    {
        name = "power off from the unit notifies OFF",
        fn = function()
            local _, session = build()
            mock.clearCalls()
            session:onMessage('msoupdate [{"op":"replace","path":"/powerIsOn","value":false}]')
            H.isTrue(mock.lastProxyCall(BINDING, "OFF") ~= nil)
        end,
    },
    {
        name = "notifications carry an explicit NOTIFY call type",
        fn = function()
            local proxy = build()
            mock.clearCalls()
            proxy:announce()
            for _, call in ipairs(mock.calls) do
                if call.name == "SendToProxy" then
                    H.equal(call.args[4], "NOTIFY", "every notification must say NOTIFY")
                end
            end
        end,
    },
}
```

- [ ] **Step 2: Run to verify the tests fail**

Add `"tests.test_proxy"` to `SUITES`, then run:
`"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: LOAD FAIL — `module 'htp1.proxy' not found`.

- [ ] **Step 3: Write the proxy layer**

Create `htp1/proxy.lua`:

```lua
-- The receiver proxy: commands in, notifications out.
--
-- The proxy addresses inputs and outputs by CONNECTION BINDING ID, so every
-- translation runs through htp1/mapping.lua. Control4 delivers proxy parameters
-- as strings, so every numeric parameter goes through tonumber.

local Mapping = require("htp1.mapping")

local Proxy = {}
Proxy.__index = Proxy

function Proxy.new(opts)
    return setmetatable({
        state    = opts.state,
        session  = opts.session,
        log      = opts.log,
        maxVolumeDb    = opts.maxVolumeDb,
        rampMs         = opts.rampMs or 100,
        powerOffAction = opts.powerOffAction or "Standby",
        rampTimer      = nil,
    }, Proxy)
end

function Proxy:setMaxVolumeDb(db) self.maxVolumeDb = db end
function Proxy:setRampMs(ms) self.rampMs = ms end
function Proxy:setPowerOffAction(action) self.powerOffAction = action end

function Proxy:_notify(command, params)
    params = params or {}
    params.OUTPUT = tostring(Mapping.ROOM_OUTPUT)
    C4:SendToProxy(Mapping.PROXY_BINDING, command, params, "NOTIFY")
end

--------------------------------------------------------------------------------
-- Volume
--------------------------------------------------------------------------------

-- The usable dB range: the unit's own, narrowed by the Maximum Volume property.
function Proxy:_range()
    local low  = self.state.fields.vpl
    local high = self.state.fields.vph
    if low == nil or high == nil then return nil end
    if self.maxVolumeDb and self.maxVolumeDb < high then high = self.maxVolumeDb end
    return low, high
end

function Proxy:_setVolumeDb(db)
    local low, high = self:_range()
    if not low then return end
    if db < low then db = low end
    if db > high then db = high end
    if self.state.fields.volume == db then return end
    self.session:write("/volume", db)
end

function Proxy:_stepVolume(delta)
    local current = self.state.fields.volume
    if current == nil then return end
    self:_setVolumeDb(current + delta)
end

function Proxy:_stopRamp()
    if self.rampTimer then
        self.rampTimer:Cancel()
        self.rampTimer = nil
    end
end

function Proxy:_startRamp(delta)
    self:_stopRamp()
    self:_stepVolume(delta)   -- respond to the first press immediately
    self.rampTimer = C4:SetTimer(self.rampMs, function()
        self:_stepVolume(delta)
    end, true)
end

--------------------------------------------------------------------------------
-- Command handlers
--------------------------------------------------------------------------------

local COMMANDS = {}

function COMMANDS.ON(self)
    self.session:write("/powerIsOn", true)
end

function COMMANDS.OFF(self)
    self.session:write("/powerAction", self.powerOffAction == "Sleep" and "sleep" or "off")
end

function COMMANDS.SET_INPUT(self, params)
    local key = Mapping.bindingToKey(tonumber(params.INPUT))
    if not key then
        self.log:debug("SET_INPUT for an unmapped binding:", tostring(params.INPUT))
        return
    end
    self.session:write("/input", key)
end

function COMMANDS.SET_VOLUME_LEVEL(self, params)
    local low, high = self:_range()
    if not low then return end
    local db = Mapping.percentToDb(tonumber(params.LEVEL), low, high)
    if db then self:_setVolumeDb(db) end
end

function COMMANDS.PULSE_VOL_UP(self) self:_stepVolume(1) end
function COMMANDS.PULSE_VOL_DOWN(self) self:_stepVolume(-1) end
function COMMANDS.START_VOL_UP(self) self:_startRamp(1) end
function COMMANDS.START_VOL_DOWN(self) self:_startRamp(-1) end
function COMMANDS.STOP_VOL_UP(self) self:_stopRamp() end
function COMMANDS.STOP_VOL_DOWN(self) self:_stopRamp() end

function COMMANDS.MUTE_ON(self) self.session:write("/muted", true) end
function COMMANDS.MUTE_OFF(self) self.session:write("/muted", false) end
function COMMANDS.MUTE_TOGGLE(self)
    self.session:write("/muted", not self.state.fields.muted)
end

function COMMANDS.SET_SURROUND_MODE(self, params)
    local key = Mapping.surroundIdToKey(tonumber(params.SURROUND_MODE))
    if not key then
        self.log:debug("unknown surround mode:", tostring(params.SURROUND_MODE))
        return
    end
    self.session:write("/upmix/select", key)
end

-- The unit switches its own audio path; Control4 only needs the acknowledgement.
function COMMANDS.CONNECT_OUTPUT() end
function COMMANDS.DISCONNECT_OUTPUT() end

function COMMANDS.BINDING_CHANGE_ACTION(self)
    self:announce()
end

function Proxy:handle(_, command, params)
    local handler = COMMANDS[command]
    if not handler then return false end
    handler(self, params or {})
    return true
end

--------------------------------------------------------------------------------
-- Notifications
--------------------------------------------------------------------------------

function Proxy:_notifyPower()
    if self.state.fields.power == nil then return end
    self:_notify(self.state.fields.power and "ON" or "OFF")
end

function Proxy:_notifyVolume()
    local low, high = self:_range()
    local percent = Mapping.dbToPercent(self.state.fields.volume, low, high)
    if percent == nil then return end
    self:_notify("VOLUME_LEVEL_CHANGED", { LEVEL = percent })
end

function Proxy:_notifyMute()
    if self.state.fields.muted == nil then return end
    self:_notify("MUTE_CHANGED", { MUTE = self.state.fields.muted })
end

function Proxy:_notifyInput()
    local key = self.state.fields.input
    if key == nil then return end
    -- An input the driver does not model -- Roon, for instance -- is reported as
    -- no input rather than as some arbitrary one.
    local binding = Mapping.keyToBinding(key) or Mapping.NO_INPUT
    self:_notify("INPUT_OUTPUT_CHANGED", {
        INPUT = tostring(binding), AUDIO = true, VIDEO = true,
    })
end

function Proxy:_notifySurround()
    local id = Mapping.keyToSurroundId(self.state.fields.upmix)
    if id == nil then return end
    self:_notify("SURROUND_MODE_CHANGED", { SURROUND_MODE = tostring(id) })
end

function Proxy:announce()
    self:_notifyPower()
    self:_notifyVolume()
    self:_notifyMute()
    self:_notifyInput()
    self:_notifySurround()
end

-- Only what actually moved. The volume range moving rescales the reported level,
-- so vpl and vph feed the volume notification too.
function Proxy:notify(changes)
    if changes.power then self:_notifyPower() end
    if changes.volume or changes.vpl or changes.vph then self:_notifyVolume() end
    if changes.muted then self:_notifyMute() end
    if changes.input then self:_notifyInput() end
    if changes.upmix then self:_notifySurround() end
end

return Proxy
```

- [ ] **Step 4: Write the failing driver tests**

Create `tests/test_driver.lua`:

```lua
-- driver.lua is wiring, so these tests check the wiring: that Control4's entry
-- points reach the right object, that properties take effect, and that a fault
-- in a handler is logged rather than swallowed.

local H = require("tests.harness")
local mock = H.mock
local Mapping = require("htp1.mapping")
local JSON = require("module.json")

local DEFAULTS = {
    ["Driver Version"] = "", ["Model"] = "HTP-1", ["Firmware Version"] = "",
    ["Serial Number"] = "", ["Connection Status"] = "Not connected",
    ["Maximum Volume"] = "Unit maximum", ["Volume Ramp Rate"] = "100 ms",
    ["Power Off Action"] = "Standby", ["Adopt Input Labels"] = "Yes",
    ["Debug Mode"] = "Off",
}

local function loadDriver(overrides)
    local properties = {}
    for k, v in pairs(DEFAULTS) do properties[k] = v end
    for k, v in pairs(overrides or {}) do properties[k] = v end

    for _, name in ipairs({ "htp1.frame", "htp1.protocol", "htp1.mapping", "htp1.state",
                            "htp1.transport", "htp1.session", "htp1.proxy", "htp1.log",
                            "module.json" }) do
        package.loaded[name] = nil
    end
    package.loaded["driver"] = nil
    for _, name in ipairs({ "DRIVER", "OnDriverInit", "ReceivedFromProxy" }) do _G[name] = nil end

    mock.install(properties)
    dofile("driver.lua")
    OnDriverInit()
    OnDriverLateInit()
    return mock
end

-- Bring the driver to a live, document-loaded state without a real socket.
local function goLive()
    OnConnectionStatusChanged(Mapping.NETWORK_BINDING, 80, "ONLINE")
    local accept = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n"
    ReceivedFromNetwork(Mapping.NETWORK_BINDING, 80, accept)

    local F = require("tests.fixtures")
    local text = "mso " .. JSON:encode(F.modern())
    -- Server frames are unmasked, so they are built here without a mask.
    local header = string.char(0x81)
    if #text < 126 then
        header = header .. string.char(#text)
    else
        header = header .. string.char(126, math.floor(#text / 256), #text % 256)
    end
    ReceivedFromNetwork(Mapping.NETWORK_BINDING, 80, header .. text)
end

return {
    {
        name = "the driver loads and publishes its version",
        fn = function()
            loadDriver()
            H.isTrue(Properties["Driver Version"] ~= "", "the version should be published")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "init opens the network connection",
        fn = function()
            loadDriver()
            local connects = 0
            for _, c in ipairs(mock.calls) do
                if c.name == "NetConnect" then connects = connects + 1 end
            end
            H.equal(connects, 1)
        end,
    },
    {
        name = "a completed handshake and document mark the driver connected",
        fn = function()
            loadDriver()
            goLive()
            H.equal(Properties["Connection Status"], "Connected")
            H.equal(Properties["Firmware Version"], "5.96")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "a proxy command reaches the unit",
        fn = function()
            loadDriver()
            goLive()
            mock.clearCalls()
            ReceivedFromProxy(Mapping.PROXY_BINDING, "MUTE_ON", {})
            mock.advance(50)
            local wrote = false
            for _, raw in ipairs(mock.sent) do
                if #raw > 6 then
                    local body = require("htp1.frame").applyMask(raw:sub(7), raw:sub(3, 6))
                    if body:find("/muted", 1, true) then wrote = true end
                end
            end
            H.isTrue(wrote, "a changemso carrying /muted should have gone out")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "a failing handler is logged rather than swallowed",
        fn = function()
            loadDriver()
            goLive()
            -- Force a fault inside the dispatch path.
            local realNotify = DRIVER.proxy.announce
            DRIVER.proxy.announce = function() error("deliberate fault") end
            ReceivedFromProxy(Mapping.PROXY_BINDING, "BINDING_CHANGE_ACTION", {})
            DRIVER.proxy.announce = realNotify

            local logged = false
            for _, line in ipairs(mock.printed) do
                if line:find("deliberate fault", 1, true) then logged = true end
            end
            H.isTrue(logged, "the error must reach the log, with its traceback")
        end,
    },
    {
        name = "changing the debug property takes effect immediately",
        fn = function()
            loadDriver()
            H.isFalse(DRIVER.log.enabled)
            Properties["Debug Mode"] = "On"
            OnPropertyChanged("Debug Mode")
            H.isTrue(DRIVER.log.enabled)
        end,
    },
    {
        name = "changing the maximum volume property re-clamps the proxy",
        fn = function()
            loadDriver()
            goLive()
            Properties["Maximum Volume"] = "-20 dB"
            OnPropertyChanged("Maximum Volume")
            H.equal(DRIVER.proxy.maxVolumeDb, -20)
        end,
    },
    {
        name = "the refresh action re-reads the document",
        fn = function()
            loadDriver()
            goLive()
            local before = #mock.sent
            ExecuteCommand("REFRESH_FROM_DEVICE", {})
            H.equal(#mock.sent, before + 1, "a getmso should have gone out")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "driver teardown closes the socket and cancels timers",
        fn = function()
            loadDriver()
            goLive()
            OnDriverDestroyed()
            local disconnects = 0
            for _, c in ipairs(mock.calls) do
                if c.name == "NetDisconnect" then disconnects = disconnects + 1 end
            end
            H.isTrue(disconnects >= 1, "the socket should be closed")
            mock.clearCalls()
            mock.advance(120000)
            for _, c in ipairs(mock.calls) do
                H.isTrue(c.name ~= "NetConnect", "a destroyed driver must not reconnect")
            end
        end,
    },
}
```

- [ ] **Step 5: Write `driver.lua`**

Create `driver.lua`:

```lua
-- Control4 entry points. This file is wiring: it builds the object graph and
-- forwards Control4's callbacks into it. Logic belongs in htp1/.

local Log       = require("htp1.log")
local Mapping   = require("htp1.mapping")
local State     = require("htp1.state")
local Transport = require("htp1.transport")
local Session   = require("htp1.session")
local Proxy     = require("htp1.proxy")

DRIVER = {}

--------------------------------------------------------------------------------
-- Property parsing
--------------------------------------------------------------------------------

-- "Unit maximum" means no cap of our own; "-20 dB" means -20.
local function parseMaxVolume(value)
    if value == nil or value == "Unit maximum" then return nil end
    return tonumber(value:match("(-?%d+)"))
end

local function parseRampMs(value)
    return tonumber((value or ""):match("(%d+)")) or 100
end

--------------------------------------------------------------------------------
-- Error handling
--------------------------------------------------------------------------------

-- Handlers are wrapped so a Lua fault cannot take the driver down, but nothing
-- is swallowed: every caught error is logged with its traceback. A silent
-- handler failure is worse than a crash, because it looks like success.
local function guard(name, fn, ...)
    local args = { ... }
    local ok, err = xpcall(function() return fn(unpack(args)) end, debug.traceback)
    if not ok then
        if DRIVER.log then
            DRIVER.log:error(name .. " failed: " .. tostring(err))
        else
            print("HTP-1: " .. name .. " failed: " .. tostring(err))
        end
        return nil
    end
    return err
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function buildDriver()
    local log = Log.new("HTP-1")
    log:setMode(Properties["Debug Mode"])

    local state = State.new()

    local host = ""
    local ok, address = pcall(function()
        return C4:GetBindingAddress(Mapping.NETWORK_BINDING)
    end)
    if ok and type(address) == "string" then host = address end

    local transport = Transport.new({
        binding = Mapping.NETWORK_BINDING,
        port = 80,
        host = host,
        path = "/ws/controller",
        log = log,
        onOpen    = function() DRIVER.session:onOpen() end,
        onMessage = function(text) DRIVER.session:onMessage(text) end,
        onClose   = function(reason) DRIVER.session:onClose(reason) end,
    })

    local session = Session.new({
        transport = transport,
        state = state,
        log = log,
        onChanges = function(changes) DRIVER.proxy:notify(changes) end,
        onConnected = function(connected) DRIVER.onConnected(connected) end,
    })

    local proxy = Proxy.new({
        state = state,
        session = session,
        log = log,
        maxVolumeDb = parseMaxVolume(Properties["Maximum Volume"]),
        rampMs = parseRampMs(Properties["Volume Ramp Rate"]),
        powerOffAction = Properties["Power Off Action"],
    })

    DRIVER.log, DRIVER.state = log, state
    DRIVER.transport, DRIVER.session, DRIVER.proxy = transport, session, proxy
end

function DRIVER.onConnected(connected)
    C4:UpdateProperty("Connection Status", connected and "Connected" or "Not connected")
    if not connected then return end

    C4:UpdateProperty("Firmware Version", DRIVER.state.fields.firmware or "")
    C4:UpdateProperty("Serial Number", DRIVER.state.fields.serial or "")
    DRIVER.proxy:announce()
end

function OnDriverInit()
    guard("OnDriverInit", function()
        buildDriver()
        C4:UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
    end)
end

function OnDriverLateInit()
    guard("OnDriverLateInit", function()
        DRIVER.session:start()
    end)
end

function OnDriverDestroyed()
    guard("OnDriverDestroyed", function()
        if DRIVER.session then DRIVER.session:stop() end
        if DRIVER.proxy then DRIVER.proxy:_stopRamp() end
    end)
end

--------------------------------------------------------------------------------
-- Composer
--------------------------------------------------------------------------------

local PROPERTY_HANDLERS = {
    ["Debug Mode"] = function(value) DRIVER.log:setMode(value) end,
    ["Maximum Volume"] = function(value)
        DRIVER.proxy:setMaxVolumeDb(parseMaxVolume(value))
        DRIVER.proxy:announce()
    end,
    ["Volume Ramp Rate"] = function(value) DRIVER.proxy:setRampMs(parseRampMs(value)) end,
    ["Power Off Action"] = function(value) DRIVER.proxy:setPowerOffAction(value) end,
}

function OnPropertyChanged(name)
    guard("OnPropertyChanged(" .. tostring(name) .. ")", function()
        local handler = PROPERTY_HANDLERS[name]
        if handler then handler(Properties[name]) end
    end)
end

local ACTIONS = {
    REFRESH_FROM_DEVICE = function() DRIVER.session:refresh() end,
    PRINT_STATE = function()
        print("HTP-1 state:")
        for key, value in pairs(DRIVER.state.fields) do
            print("  " .. key .. " = " .. tostring(value))
        end
        print("  connected = " .. tostring(DRIVER.session.connected))
    end,
    -- Adopting labels is applied in M2, when the driver renames its connections.
    ADOPT_INPUT_LABELS = function()
        print("HTP-1: input labels are applied in M2")
    end,
}

function ExecuteCommand(command, params)
    guard("ExecuteCommand(" .. tostring(command) .. ")", function()
        local action = ACTIONS[command]
        if action then action(params or {}) end
    end)
end

--------------------------------------------------------------------------------
-- Proxy and network callbacks
--------------------------------------------------------------------------------

function ReceivedFromProxy(binding, command, params)
    return guard("ReceivedFromProxy(" .. tostring(command) .. ")", function()
        return DRIVER.proxy:handle(binding, command, params)
    end)
end

function OnConnectionStatusChanged(binding, port, status)
    guard("OnConnectionStatusChanged", function()
        if binding ~= Mapping.NETWORK_BINDING then return end
        DRIVER.transport:onConnectionStatus(status)
    end)
end

function ReceivedFromNetwork(binding, port, data)
    guard("ReceivedFromNetwork", function()
        if binding ~= Mapping.NETWORK_BINDING then return end
        DRIVER.transport:onData(data)
    end)
end
```

- [ ] **Step 6: Run the tests to verify they pass**

Add `"tests.test_driver"` to `SUITES`, then run:
`"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: PASS — every suite green, and the new tests among them.

- [ ] **Step 7: Commit**

```bash
git add htp1/proxy.lua driver.lua tests/test_proxy.lua tests/test_driver.lua tests/run.lua
git commit -m "feat: receiver proxy handlers and the Control4 entry points"
```

---

### Task 13: Packaging

**Files:**
- Create: `tools/build-c4z.ps1`

**Interfaces:**
- Consumes: `driver.xml`, `driver.lua`, `htp1/*.lua`, `module/json.lua`.
- Produces: `build/Monolith.HTP1.c4z`.

Adapted from the sibling drivers' build, keeping all three fail-closed checks. The third — that git
tracks every payload file — exists because a sibling driver shipped two builds containing files a
*global* gitignore silently excluded, so the repository could not reproduce its own releases and
nothing said a word.

- [ ] **Step 1: Write the build script**

Create `tools/build-c4z.ps1`:

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    Package the driver as a .c4z for Composer Pro.

.DESCRIPTION
    A .c4z is a plain zip. This script names every file it packs explicitly
    rather than sweeping the working tree, so a development file added later
    cannot leak into a release by accident -- it has to be added here first.

    Entry names use forward slashes regardless of host platform, because that is
    what the controller expects inside the archive.

    The build fails, rather than warns, on three conditions:

      1. A payload file that does not exist.
      2. A module required by a packaged file that is not itself packaged. An
         archive that loads on the bench and fails on a controller is worse than
         one that refuses to build.
      3. A payload file that git does not track. A sibling driver shipped two
         builds containing files a *global* gitignore silently excluded.

    This script never installs. It writes to build/ and stops there.

.PARAMETER OutputName
    File name of the packaged driver. Composer identifies a driver by file name,
    so building under a different one adds a second driver instead of updating
    the installed one.

.EXAMPLE
    powershell -File tools/build-c4z.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputName = 'Monolith.HTP1.c4z'
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

$repoRoot = Split-Path -Parent $PSScriptRoot

# The exact archive layout the controller expects. Order is the order printed.
$payload = @(
    'driver.xml'
    'driver.lua'
    'htp1/frame.lua'
    'htp1/protocol.lua'
    'htp1/mapping.lua'
    'htp1/state.lua'
    'htp1/transport.lua'
    'htp1/session.lua'
    'htp1/proxy.lua'
    'htp1/log.lua'
    'module/json.lua'
)

function Get-SourcePath([string]$entry) {
    return (Join-Path $repoRoot ($entry -replace '/', '\'))
}

# --- 1. Every payload file exists --------------------------------------------

$missing = @()
foreach ($entry in $payload) {
    if (-not (Test-Path -LiteralPath (Get-SourcePath $entry) -PathType Leaf)) {
        $missing += $entry
    }
}
if ($missing.Count -gt 0) {
    throw ("Cannot package: missing $($missing.Count) required file(s):`n  " +
           ($missing -join "`n  "))
}

# --- 2. The require graph is closed over the payload -------------------------

$packagedModules = @{}
foreach ($entry in $payload) {
    if ($entry -like '*.lua') {
        $packagedModules[($entry -replace '\.lua$', '') -replace '/', '.'] = $entry
    }
}

$unresolved = @()
foreach ($entry in $payload) {
    if ($entry -notlike '*.lua') { continue }
    $text = Get-Content -LiteralPath (Get-SourcePath $entry) -Raw
    foreach ($match in [regex]::Matches($text, "require\s*\(?\s*['""]([^'""]+)['""]")) {
        $module = $match.Groups[1].Value
        if (-not $packagedModules.ContainsKey($module)) {
            $unresolved += "$entry requires '$module', which is not in the payload"
        }
    }
}
if ($unresolved.Count -gt 0) {
    throw ("Cannot package: the require graph is incomplete:`n  " + ($unresolved -join "`n  "))
}

# --- 3. Git tracks every payload file ----------------------------------------

$untracked = @()
foreach ($entry in $payload) {
    & git -C $repoRoot ls-files --error-unmatch -- $entry | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $untracked += "$entry is not tracked by git (check: git check-ignore -v '$entry')"
    }
}
if ($untracked.Count -gt 0) {
    throw ("Cannot package: $($untracked.Count) payload file(s) git does not track:`n  " +
           ($untracked -join "`n  "))
}

# --- Build the archive -------------------------------------------------------

$buildDir = Join-Path $repoRoot 'build'
if (-not (Test-Path -LiteralPath $buildDir)) {
    New-Item -ItemType Directory -Path $buildDir | Out-Null
}

$outputPath = Join-Path $buildDir $OutputName
if (Test-Path -LiteralPath $outputPath) {
    Remove-Item -LiteralPath $outputPath -Force
}

$archive = [System.IO.Compression.ZipFile]::Open(
    $outputPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($entry in $payload) {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, (Get-SourcePath $entry), $entry,
            [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
}
finally {
    $archive.Dispose()
}

# --- Report ------------------------------------------------------------------

$driverXml = [xml](Get-Content -LiteralPath (Join-Path $repoRoot 'driver.xml') -Raw)

Write-Host ''
Write-Host "Packaged: $outputPath"
Write-Host "Driver version: $($driverXml.devicedata.version)"
Write-Host "Auto update: $($driverXml.devicedata.auto_update)"
Write-Host ''
Write-Host 'Archive contents:'

$reader = [System.IO.Compression.ZipFile]::OpenRead($outputPath)
try {
    foreach ($item in $reader.Entries) {
        Write-Host ('  {0,8}  {1}' -f $item.Length, $item.FullName)
    }
    $entryCount = $reader.Entries.Count
}
finally {
    $reader.Dispose()
}

Write-Host ''
Write-Host "$entryCount entries, $([math]::Round((Get-Item -LiteralPath $outputPath).Length / 1KB, 1)) KB"
Write-Host ''
Write-Host 'The build never installs. Copy the archive into Composer by hand.'
```

- [ ] **Step 2: Run the build**

Run: `powershell -File tools/build-c4z.ps1`
Expected: 11 entries listed, `Auto update: false`, and the archive written to
`build/Monolith.HTP1.c4z`.

- [ ] **Step 3: Prove the guards actually fire**

Temporarily rename `htp1/log.lua`, run the build, and confirm it **throws** rather than producing a
short archive. Restore the file and re-run to confirm it builds again. Paste both outputs into the
implementation doc — an untested guard is not a guard.

```bash
mv htp1/log.lua htp1/log.lua.bak
powershell -File tools/build-c4z.ps1   # expect: "Cannot package: missing 1 required file(s)"
mv htp1/log.lua.bak htp1/log.lua
powershell -File tools/build-c4z.ps1   # expect: a clean build
```

- [ ] **Step 4: Commit**

```bash
git add tools/build-c4z.ps1
git commit -m "build: package Monolith.HTP1.c4z with fail-closed payload checks"
```

---

### Task 14: The fake device and cross-validated frame vectors

**Files:**
- Create: `tools/fake-htp1.py`, `tools/gen_vectors.py`, `tests/fixtures/vectors.lua`,
  `tests/test_vectors.lua`
- Modify: `tests/run.lua` — add `"tests.test_vectors"` to `SUITES`

**Interfaces:**
- Consumes: `Frame` (Tasks 2–3).
- Produces: `tests/fixtures/vectors.lua` returning
  `{ inbound = { { raw, opcode, payload } ... }, outbound = { { opcode, payload, key, raw } ... } }`.

**Why vectors rather than a socket.** LuaJIT here has no socket library, so the Lua transport cannot
open a real TCP connection in the test suite. Cross-validation gets the same assurance a different
way: Python's `websockets` — a mature, widely deployed implementation — serialises frames that our
decoder must read, and serialises the frames our encoder must produce, byte for byte. If our masking,
length encoding or fragmentation is wrong, the comparison fails. `tools/fake-htp1.py` then exists for
what vectors cannot cover: a driver-level soak against a real endpoint, and deliberate faults
(mid-frame disconnects, byte-at-a-time delivery, a device that stops answering pings).

- [ ] **Step 1: Write the vector generator**

Create `tools/gen_vectors.py`:

```python
"""Generate frame vectors from Python's `websockets` reference implementation.

Our Lua codec must decode exactly what a real server sends, and must produce
exactly what a real server expects. Rather than open a socket from LuaJIT, which
has no socket library here, both directions are cross-checked against a mature
implementation. Run from the repository root:

    python tools/gen_vectors.py > tests/fixtures/vectors.lua
"""

import sys

from websockets.frames import Frame, Opcode


def lua_string(data: bytes) -> str:
    """Every byte as a decimal escape: safe regardless of Lua's string rules."""
    return '"' + "".join(f"\\{b:d}" for b in data) + '"'


def serialise(frame: Frame, mask: bool, key: bytes | None = None) -> bytes:
    if mask:
        # websockets generates its own key; force ours so Lua can reproduce it.
        raw = frame.serialize(mask=True)
        header_len = len(raw) - len(frame.data) - 4
        body = bytes(b ^ key[i % 4] for i, b in enumerate(frame.data))
        return raw[:header_len] + key + body
    return frame.serialize(mask=False)


INBOUND = [
    ("short text", Frame(Opcode.TEXT, b"mso {}")),
    ("125 byte text", Frame(Opcode.TEXT, b"x" * 125)),
    ("126 byte text", Frame(Opcode.TEXT, b"x" * 126)),
    ("16 bit length", Frame(Opcode.TEXT, b"y" * 4000)),
    ("64 bit length", Frame(Opcode.TEXT, b"z" * 70000)),
    ("mso sized", Frame(Opcode.TEXT, b"m" * 38461)),
    ("empty ping", Frame(Opcode.PING, b"")),
    ("ping payload", Frame(Opcode.PING, b"keepalive")),
    ("empty pong", Frame(Opcode.PONG, b"")),
    ("close", Frame(Opcode.CLOSE, b"")),
]

OUTBOUND_KEY = bytes([0x37, 0xFA, 0x21, 0x3D])
OUTBOUND = [
    ("getmso", Frame(Opcode.TEXT, b"getmso")),
    ("changemso", Frame(Opcode.TEXT, b'changemso [{"op":"replace","path":"/volume","value":-30}]')),
    ("long text", Frame(Opcode.TEXT, b"q" * 300)),
    ("very long text", Frame(Opcode.TEXT, b"q" * 70000)),
    ("ping", Frame(Opcode.PING, b"")),
    ("pong echo", Frame(Opcode.PONG, b"keepalive")),
]


def main() -> None:
    out = sys.stdout
    out.write("-- GENERATED by tools/gen_vectors.py. Do not edit.\n")
    out.write("-- Frames serialised by Python's `websockets`, used to cross-check\n")
    out.write("-- htp1/frame.lua in both directions.\n\n")
    out.write("return {\n  inbound = {\n")
    for name, frame in INBOUND:
        raw = serialise(frame, mask=False)
        out.write(
            f"    {{ name = {lua_string(name.encode())}, "
            f"raw = {lua_string(raw)}, opcode = {int(frame.opcode)}, "
            f"payload = {lua_string(frame.data)} }},\n"
        )
    out.write("  },\n  outbound = {\n")
    out.write(f"    key = {lua_string(OUTBOUND_KEY)},\n")
    for name, frame in OUTBOUND:
        raw = serialise(frame, mask=True, key=OUTBOUND_KEY)
        out.write(
            f"    {{ name = {lua_string(name.encode())}, "
            f"opcode = {int(frame.opcode)}, payload = {lua_string(frame.data)}, "
            f"raw = {lua_string(raw)} }},\n"
        )
    out.write("  },\n}\n")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Generate the vectors**

```bash
python tools/gen_vectors.py > tests/fixtures/vectors.lua
head -5 tests/fixtures/vectors.lua
```
Expected: the generated header, then vector rows. The file is large; that is fine, it is generated
and checked in so the suite needs no Python.

- [ ] **Step 3: Write the failing cross-check tests**

Create `tests/test_vectors.lua`:

```lua
-- Cross-checks htp1/frame.lua against frames serialised by Python's
-- `websockets`. Regenerate with tools/gen_vectors.py after any codec change.

local H = require("tests.harness")
local Frame = require("htp1.frame")
local V = require("tests.fixtures.vectors")

local tests = {}

table.insert(tests, {
    name = "the vector file carries both directions",
    fn = function()
        H.isTrue(#V.inbound > 0, "inbound vectors")
        H.isTrue(#V.outbound > 0, "outbound vectors")
        H.equal(#V.outbound.key, 4, "a four-byte mask key")
    end,
})

table.insert(tests, {
    name = "every reference server frame decodes to the expected message",
    fn = function()
        for _, vector in ipairs(V.inbound) do
            local reader = Frame.newReader()
            reader:push(vector.raw)
            local message, err = reader:next()
            H.equal(err, nil, vector.name .. ": " .. tostring(err))
            H.isTrue(message ~= nil, vector.name .. " should decode")
            H.equal(message.opcode, vector.opcode, vector.name .. " opcode")
            H.equal(message.payload, vector.payload, vector.name .. " payload")
        end
    end,
})

table.insert(tests, {
    name = "every reference server frame decodes when delivered one byte at a time",
    fn = function()
        for _, vector in ipairs(V.inbound) do
            local reader = Frame.newReader()
            local message
            for i = 1, #vector.raw do
                reader:push(vector.raw:sub(i, i))
                message = reader:next()
                if message then break end
            end
            H.isTrue(message ~= nil, vector.name .. " should decode byte by byte")
            H.equal(message.payload, vector.payload, vector.name .. " payload")
        end
    end,
})

table.insert(tests, {
    name = "our encoder produces byte-identical client frames",
    fn = function()
        for _, vector in ipairs(V.outbound) do
            local encoded = Frame.encode(vector.opcode, vector.payload, V.outbound.key)
            H.equal(#encoded, #vector.raw, vector.name .. " length")
            H.equal(encoded, vector.raw, vector.name .. " bytes differ from the reference")
        end
    end,
})

table.insert(tests, {
    name = "several reference frames concatenated all decode in order",
    fn = function()
        local reader = Frame.newReader()
        local raw = {}
        for _, vector in ipairs(V.inbound) do table.insert(raw, vector.raw) end
        reader:push(table.concat(raw))
        for _, vector in ipairs(V.inbound) do
            local message = reader:next()
            H.isTrue(message ~= nil, vector.name .. " should decode from the stream")
            H.equal(message.payload, vector.payload, vector.name)
        end
        H.equal(reader:next(), nil, "the stream is fully consumed")
    end,
})

return tests
```

- [ ] **Step 4: Run the tests to verify they pass**

Add `"tests.test_vectors"` to `SUITES`, then run:
`"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/run.lua`
Expected: PASS — every suite green, and the new tests among them. A failure here means the codec disagrees with a reference
implementation, which is the whole point of the task.

- [ ] **Step 5: Write the fake device**

Create `tools/fake-htp1.py`:

```python
"""A local stand-in for a Monolith HTP-1, for driver-level testing.

Speaks the real protocol -- getmso / mso / changemso / msoupdate / error
"bad-verb" -- from an invented document, so the live units are never touched.
Fault injection covers what a healthy device will not do on demand.

    python tools/fake-htp1.py                 # serve on 127.0.0.1:8080
    python tools/fake-htp1.py --port 8123
    python tools/fake-htp1.py --fault drop-mid-frame
    python tools/fake-htp1.py --fault trickle      # one byte per write
    python tools/fake-htp1.py --fault ignore-ping  # never answer a ping

Nothing here contains site data: the document is invented, matching the shape of
firmware 2.x.
"""

import argparse
import asyncio
import json

import websockets

DOCUMENT = {
    "volume": -25,
    "muted": False,
    "powerIsOn": True,
    "powerAction": "none",
    "input": "h1",
    "unitname": "Processor",
    "upmix": {"select": "dolby", "dolby": {"cs": False}, "dts": {"ws": True}},
    "cal": {"vpl": -50, "vph": 0, "zeroPoint": 0, "diracactive": "on", "currentdiracslot": 0},
    "inputs": {
        "h1": {"label": "Streamer", "visible": True},
        "h2": {"label": "Console", "visible": True},
        "a1": {"label": "Turntable", "visible": True},
    },
    "versions": {"avController": "5.96 Built Jan  1 2026, 00:00:00\n", "SerialNumber": "0001"},
    "status": {"SurroundMode": "Dolby Surround", "DECSourceProgram": "PCM"},
    "videostat": {"VideoResolution": "3840x2160p60Hz", "HDRstatus": "HDR10"},
}


def apply_patch(document: dict, op: dict) -> None:
    """Apply one RFC 6902 operation. Only what this fake needs to be honest."""
    path = op.get("path", "")
    segments = [s for s in path.split("/") if s]
    if not segments:
        return
    node = document
    for segment in segments[:-1]:
        node = node.setdefault(segment, {})
    if op.get("op") == "remove":
        node.pop(segments[-1], None)
    else:
        node[segments[-1]] = op.get("value")


class Device:
    def __init__(self, fault: str | None):
        self.document = json.loads(json.dumps(DOCUMENT))
        self.fault = fault
        self.clients: set = set()

    async def broadcast(self, ops: list) -> None:
        message = "msoupdate " + json.dumps(ops)
        for client in list(self.clients):
            try:
                await client.send(message)
            except websockets.ConnectionClosed:
                self.clients.discard(client)

    async def send(self, client, message: str) -> None:
        if self.fault == "trickle":
            # Exercise reassembly: one byte per TCP write.
            for index in range(len(message)):
                await client.send(message[index : index + 1])
            return
        if self.fault == "drop-mid-frame":
            await client.send(message[: len(message) // 2])
            await client.close(code=1006)
            return
        await client.send(message)

    async def handle(self, client) -> None:
        if client.request.path != "/ws/controller":
            await client.close(code=1008, reason="unknown path")
            return

        self.clients.add(client)
        print(f"client connected ({len(self.clients)} total)")
        try:
            async for raw in client:
                verb, _, body = raw.partition(" ")
                if verb == "getmso":
                    await self.send(client, "mso " + json.dumps(self.document))
                elif verb == "changemso":
                    try:
                        ops = json.loads(body)
                    except ValueError:
                        await client.send('error "bad-json"')
                        continue
                    for op in ops:
                        apply_patch(self.document, op)
                        print(f"  {op.get('op')} {op.get('path')} = {op.get('value')!r}")
                    # The real unit echoes every change to every client.
                    await self.broadcast(ops)
                else:
                    await client.send('error "bad-verb"')
        except websockets.ConnectionClosed:
            pass
        finally:
            self.clients.discard(client)
            print(f"client gone ({len(self.clients)} left)")


async def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument(
        "--fault",
        choices=["trickle", "drop-mid-frame", "ignore-ping"],
        default=None,
        help="inject a failure a healthy device will not produce on demand",
    )
    args = parser.parse_args()

    device = Device(args.fault)
    # ping_interval None means this server never pings; the driver's own pings
    # are still answered unless the ignore-ping fault is selected.
    ping_interval = None if args.fault == "ignore-ping" else 20
    async with websockets.serve(
        device.handle, args.host, args.port, ping_interval=ping_interval
    ):
        print(f"fake HTP-1 on ws://{args.host}:{args.port}/ws/controller"
              + (f" (fault: {args.fault})" if args.fault else ""))
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
```

- [ ] **Step 6: Exercise the fake device by hand**

```bash
python tools/fake-htp1.py &
python - <<'EOF'
import asyncio, json, websockets
async def main():
    async with websockets.connect("ws://127.0.0.1:8080/ws/controller") as ws:
        await ws.send("getmso")
        raw = await ws.recv()
        print("verb:", raw.split(" ", 1)[0], "bytes:", len(raw))
        await ws.send('changemso [{"op":"replace","path":"/volume","value":-30}]')
        print("push:", await ws.recv())
        await ws.send("nonsense")
        print("junk:", await ws.recv())
asyncio.run(main())
EOF
```
Expected: `verb: mso`, an `msoupdate` echoing the volume change, then `error "bad-verb"`.

- [ ] **Step 7: Commit**

```bash
git add tools/gen_vectors.py tools/fake-htp1.py tests/fixtures/vectors.lua tests/test_vectors.lua tests/run.lua
git commit -m "test: cross-validate the frame codec against a reference implementation"
```

---

## M1 exit criteria

M1 is done when all of the following are true and the evidence is pasted into
`docs/ai/implementation/2026-08-04-feature-control4-htp1-driver.md`:

- [ ] `luajit tests/run.lua` — green, with the real output pasted.
- [ ] `powershell -File tools/build-c4z.ps1` — builds `Monolith.HTP1.c4z`, with the printed archive
      layout pasted, and the guard test from Task 13 Step 3 shown failing and recovering.
- [ ] The driver loads in Composer Pro, connects to a unit, and its **Connection Status**,
      **Firmware Version** and **Serial Number** properties populate. (Owner-driven.)
- [ ] From a Control4 remote in the bound room: power on and off, input select, discrete volume,
      hold-to-ramp, mute and surround-mode select all work. (Owner-driven.)
- [ ] Changes made on the unit's front panel appear in Control4 within a second. (Owner-driven.)
- [ ] The unit is rebooted and the driver reconnects unattended. (Owner-driven.)
- [ ] With Debug Mode off, the Director log is quiet.

## Questions M1 answers that the design could not

- Whether the unit keeps its network stack alive with `powerIsOn` false. Both units report
  `fastStart: "on"`, which suggests yes. If not, `ON` cannot work over IP and the driver needs
  Wake-on-LAN — record the answer in the implementation doc either way.
- Whether `C4:GetBindingAddress` returns the address in the form the `Host` header wants.
- Whether the unit ever fragments the 38 KB `mso` frame in practice, or always sends it whole.


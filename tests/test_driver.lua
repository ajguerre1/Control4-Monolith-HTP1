-- driver.lua is wiring, so these tests check the wiring: that Control4's entry
-- points reach the right object, that properties take effect, and that a fault
-- in a handler is logged rather than swallowed.

local H = require("tests.harness")
local mock = H.mock
local Mapping = require("htp1.mapping")
local JSON = require("module.json")
local Frame = require("htp1.frame")

local DEFAULTS = {
    ["Driver Version"] = "", ["Model"] = "HTP-1",
    ["System Software Version"] = "", ["AV Controller Version"] = "",
    ["Serial Number"] = "", ["Connection Status"] = "Not connected",
    ["Maximum Volume"] = "Unit maximum", ["Volume Ramp Rate"] = "100 ms",
    ["Power Off Action"] = "Standby",
    ["Debug Mode"] = "Off",
    -- What Composer has before the driver has read anything from the unit:
    -- each DYNAMIC_LIST's declared <default> in driver.xml. Dirac Filter has
    -- none, so it starts empty; Macro defaults to its own sentinel, so an
    -- install that has never seen the unit reads the same as one whose chosen
    -- macro was deleted. tests/test_manifest.lua pins both against driver.xml.
    ["Dirac Filter"] = "", ["Macro"] = "(none)",
}

local function loadDriver(overrides, bindingAddress)
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
    if bindingAddress ~= nil then mock.bindingAddress = bindingAddress end
    dofile("driver.lua")
    OnDriverInit()
    OnDriverLateInit()
    return mock
end

-- Wraps `text` in an unmasked server text frame and delivers it as if it had
-- arrived on the socket. Server frames are unmasked, so no mask is applied.
local function sendFrame(text)
    local header = string.char(0x81)
    if #text < 126 then
        header = header .. string.char(#text)
    else
        header = header .. string.char(126, math.floor(#text / 256), #text % 256)
    end
    ReceivedFromNetwork(Mapping.NETWORK_BINDING, 80, header .. text)
end

-- Bring the driver to a live state without a real socket, loaded with `doc`
-- (F.modern() if omitted).
local function goLiveWith(doc)
    OnConnectionStatusChanged(Mapping.NETWORK_BINDING, 80, "ONLINE")
    local accept = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n"
    ReceivedFromNetwork(Mapping.NETWORK_BINDING, 80, accept)
    sendFrame("mso " .. JSON:encode(doc))
end

local function goLive()
    local F = require("tests.fixtures")
    goLiveWith(F.modern())
end

-- Push a single msoupdate operation as if the unit sent it.
local function pushUpdate(path, value)
    sendFrame("msoupdate " .. JSON:encode({ { op = "replace", path = path, value = value } }))
end

local VARIABLE_NAMES = {
    "CONNECTED", "UNIT_POWER", "INPUT_ID", "INPUT_LABEL", "VOLUME_DB", "VOLUME_PERCENT",
    "MUTED", "SURROUND_MODE", "INPUT_FORMAT", "INPUT_PROGRAM", "INPUT_SAMPLE_RATE",
    "OUTPUT_FORMAT", "OUTPUT_SAMPLE_RATE", "VIDEO_RESOLUTION", "VIDEO_COLORSPACE",
    "VIDEO_HDR", "DIRAC_STATE",
    "LOUDNESS", "NIGHT_MODE", "DIALOG_ENHANCE", "BASS_ENHANCE", "DIRAC_SLOT", "LIP_SYNC_MS",
}

local function callsNamed(name)
    local found = {}
    for _, c in ipairs(mock.calls) do
        if c.name == name then table.insert(found, c) end
    end
    return found
end

-- True when the driver printed a line containing `text`. Debug logging is off
-- by default, so a test asserting a refusal was explained loads the driver with
-- Debug Mode on.
local function loggedContaining(text)
    for _, line in ipairs(mock.printed) do
        if line:find(text, 1, true) then return true end
    end
    return false
end

-- The most recent C4:UpdatePropertyList for ONE property, or nil. Filtered by
-- property name deliberately: the driver populates more than one DYNAMIC_LIST,
-- so "the last UpdatePropertyList call" is not necessarily the list under test.
local function lastPropertyList(name)
    for i = #mock.calls, 1, -1 do
        local c = mock.calls[i]
        if c.name == "UpdatePropertyList" and c.args[1] == name then return c end
    end
    return nil
end

-- Decodes one masked client frame (the driver always sends masked, unfragmented
-- text frames). Handles all three RFC 6455 length encodings, unlike a fixed
-- 6-byte-header assumption, because a two-path changemso (lip sync) is long
-- enough to need the 16-bit extended length form.
local function decodeFrame(raw)
    local secondByte = raw:byte(2)
    local masked = secondByte >= 128
    local len = secondByte % 128
    local offset = 3
    if len == 126 then
        len = raw:byte(3) * 256 + raw:byte(4)
        offset = 5
    elseif len == 127 then
        error("64-bit frame length not expected in these tests")
    end
    local maskKey
    if masked then
        maskKey = raw:sub(offset, offset + 3)
        offset = offset + 4
    end
    local payload = raw:sub(offset, offset + len - 1)
    if masked then payload = Frame.applyMask(payload, maskKey) end
    return payload
end

-- How many changemso messages the driver sent since the last mock.clearCalls().
-- A macro touching several paths must be ONE message, not one per path.
local function changeMsoCount()
    local count = 0
    for _, raw in ipairs(mock.sent) do
        if #raw > 2 then
            local ok, body = pcall(decodeFrame, raw)
            if ok and body:sub(1, 10) == "changemso " then count = count + 1 end
        end
    end
    return count
end

-- The operations in the most recent changemso the driver actually sent, or
-- nil if none was sent since the last mock.clearCalls().
local function lastWrittenOps()
    for i = #mock.sent, 1, -1 do
        local raw = mock.sent[i]
        if #raw > 2 then
            local ok, body = pcall(decodeFrame, raw)
            if ok and body:sub(1, 10) == "changemso " then
                return JSON:decode(body:sub(11))
            end
        end
    end
    return nil
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
            H.equal(Properties["System Software Version"], "V2.1.1",
                "the release an owner would recognise")
            H.equal(Properties["AV Controller Version"], "5.96")
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
        name = "a variable that could not be created is never written to afterwards",
        fn = function()
            -- Without the created-set the driver would SetVariable a name that
            -- does not exist, silently, on every change for its whole life.
            loadDriver()
            local realAdd = C4.AddVariable
            C4.AddVariable = function(self, name, value, kind, readOnly)
                if name == "VIDEO_HDR" then error("Director refused") end
                return realAdd(self, name, value, kind, readOnly)
            end
            OnDriverInit()
            C4.AddVariable = realAdd

            H.isTrue(DRIVER.varCreated.VOLUME_DB, "the others are still created")
            H.equal(DRIVER.varCreated.VIDEO_HDR, nil, "the failed one is not marked created")

            mock.clearCalls()
            goLive()
            for _, c in ipairs(callsNamed("SetVariable")) do
                H.isTrue(c.args[1] ~= "VIDEO_HDR",
                    "a variable that was never created must never be written")
            end
        end,
    },
    {
        name = "a fault in the variable layer cannot starve the proxy notification",
        fn = function()
            -- The proxy notification is what M1 depends on for volume, mute and
            -- input feedback in Navigator, and it is proven on hardware. The
            -- variables and events are newer; a fault in them must not take it
            -- down with them.
            loadDriver()
            goLive()
            local realNotify = DRIVER.proxy.notify
            local notified = 0
            DRIVER.proxy.notify = function(self, changes)
                notified = notified + 1
                return realNotify(self, changes)
            end
            local realSet = C4.SetVariable
            C4.SetVariable = function() error("deliberate fault in the variable layer") end

            pushUpdate("/volume", -33)

            C4.SetVariable = realSet
            DRIVER.proxy.notify = realNotify
            H.equal(notified, 1, "the proxy was still notified despite the fault")

            local logged = false
            for _, line in ipairs(mock.printed) do
                if line:find("deliberate fault in the variable layer", 1, true) then logged = true end
            end
            H.isTrue(logged, "and the fault was logged rather than swallowed")
        end,
    },
    {
        name = "every action declared in driver.xml runs when Composer invokes it",
        fn = function()
            -- Composer sends the literal "LUA_ACTION" with the declared command
            -- in tParams.ACTION -- NOT the command as the command. Dispatching
            -- on the command matched nothing and returned in silence, so every
            -- action did nothing and said nothing, through two releases and a
            -- field install. The tests missed it because they invoked the
            -- actions the way the code expected rather than the way Composer
            -- does. This test reads the manifest so a new action cannot be
            -- added without being exercised the real way.
            local handle = assert(io.open("driver.xml", "r"))
            local xml = handle:read("*a")
            handle:close()

            local commands = {}
            for block in xml:gmatch("<action>(.-)</action>") do
                local command = block:match("<command>%s*(.-)%s*</command>")
                if command then table.insert(commands, command) end
            end
            H.isTrue(#commands >= 3, "expected the declared actions, found " .. #commands)

            loadDriver()
            goLive()
            for _, command in ipairs(commands) do
                mock.clearCalls()
                ExecuteCommand("LUA_ACTION", { ACTION = command })
                for _, line in ipairs(mock.printed) do
                    H.isTrue(line:find("no handler for action", 1, true) == nil,
                        command .. " has no handler: " .. line)
                end
                H.assertNoErrorLog()
            end
        end,
    },
    {
        name = "an unrecognised action says so instead of failing silently",
        fn = function()
            loadDriver()
            mock.clearCalls()
            ExecuteCommand("LUA_ACTION", { ACTION = "NO_SUCH_ACTION" })
            local complained = false
            for _, line in ipairs(mock.printed) do
                if line:find("no handler for action", 1, true) then complained = true end
            end
            H.isTrue(complained, "silence is how the dispatch bug hid for two releases")
        end,
    },
    {
        name = "the refresh action re-reads the document",
        fn = function()
            loadDriver()
            goLive()
            local before = #mock.sent
            ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_FROM_DEVICE" })
            H.equal(#mock.sent, before + 1, "a getmso should have gone out")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "Print Input Labels reports one line per input the unit sent -- mapped inputs in " ..
               "Mapping.INPUTS order, then unmapped ones (Roon) sorted by key",
        fn = function()
            loadDriver()
            goLive()   -- F.modern()'s inputs: h1, h2, h3, a1, optical1 (mapped), roon (not)
            mock.clearCalls()
            ExecuteCommand("LUA_ACTION", { ACTION = "PRINT_INPUT_LABELS" })

            local lines = mock.printed
            H.count(lines, 7, "a header line plus one line per reported input")
            H.equal(lines[1], "HTP-1 input labels:")

            -- Mapping.INPUTS declares h1, h2, h3 ... a1 ... optical1 ... in that
            -- order; only the ones the unit actually reported should appear, in
            -- that same relative order.
            local mappedOrder = { "h1", "h2", "h3", "a1", "optical1" }
            for i, key in ipairs(mappedOrder) do
                local line = lines[i + 1]
                H.isTrue(line:find("key=" .. key, 1, true) ~= nil,
                    "line " .. (i + 1) .. " should report " .. key)
                H.isTrue(line:find("connection ", 1, true) ~= nil,
                    key .. " is mapped and should carry a Control4 connection")
            end
            H.isTrue(lines[2]:find("label=Streamer", 1, true) ~= nil)
            H.isTrue(lines[2]:find("visible=true", 1, true) ~= nil)
            H.isTrue(lines[4]:find("visible=false", 1, true) ~= nil,
                "h3 is reported not visible in the fixture")

            local roonLine = lines[7]
            H.isTrue(roonLine:find("key=roon", 1, true) ~= nil,
                "Roon has no Control4 connection but should still be printed")
            H.isTrue(roonLine:find("label=Roon", 1, true) ~= nil)
            H.isTrue(roonLine:find("no Control4 connection", 1, true) ~= nil,
                "an installer should be told plainly that Roon cannot be selected from Control4")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "Print Input Labels prints in the same order on two consecutive runs",
        fn = function()
            loadDriver()
            goLive()

            mock.clearCalls()
            ExecuteCommand("LUA_ACTION", { ACTION = "PRINT_INPUT_LABELS" })
            local first = {}
            for i, line in ipairs(mock.printed) do first[i] = line end

            mock.clearCalls()
            ExecuteCommand("LUA_ACTION", { ACTION = "PRINT_INPUT_LABELS" })
            local second = mock.printed

            H.count(second, #first, "the second run should print the same number of lines")
            for i, line in ipairs(first) do
                H.equal(second[i], line, "line " .. i .. " should match across runs")
            end
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
    {
        name = "adding the driver before its IP is set does not attempt to connect to nothing",
        fn = function()
            -- The normal Composer order: add the driver, THEN set the IP. A
            -- caching read at buildDriver() time would leave the transport
            -- dialing an empty host for the driver's entire life.
            loadDriver(nil, "")
            local connects = 0
            for _, c in ipairs(mock.calls) do
                if c.name == "NetConnect" then connects = connects + 1 end
            end
            H.equal(connects, 0, "no address yet, so no connection should be attempted")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "OnBindingChanged on the network binding retries once an address is set",
        fn = function()
            loadDriver(nil, "")
            mock.bindingAddress = "unit.invalid"
            OnBindingChanged(Mapping.NETWORK_BINDING, "NETWORK", true)
            local connects = 0
            for _, c in ipairs(mock.calls) do
                if c.name == "NetConnect" then connects = connects + 1 end
            end
            H.equal(connects, 1, "the newly bound address should trigger a connect attempt")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "OnBindingChanged for an unrelated binding is ignored",
        fn = function()
            loadDriver(nil, "")
            OnBindingChanged(Mapping.PROXY_BINDING, "PROXY", true)
            local connects = 0
            for _, c in ipairs(mock.calls) do
                if c.name == "NetConnect" then connects = connects + 1 end
            end
            H.equal(connects, 0, "the proxy binding has nothing to do with the network socket")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "the driver seeds math.random from the device id so instances decorrelate",
        fn = function()
            -- Without this, every driver instance shares Lua's default,
            -- deterministic seed and two HTP-1s on one controller would
            -- reconnect in lockstep -- exactly what the jitter exists to break.
            local recordedSeed
            local realRandomseed = math.randomseed
            math.randomseed = function(seed) recordedSeed = seed; realRandomseed(seed) end
            loadDriver()
            math.randomseed = realRandomseed
            H.equal(recordedSeed, 4242, "seeded from the mock's GetDeviceID")
        end,
    },

    --------------------------------------------------------------------------
    -- Variables
    --------------------------------------------------------------------------
    {
        name = "every one of the twenty-three variables exists after init, created as STRING",
        fn = function()
            loadDriver()
            local created = {}
            for _, c in ipairs(callsNamed("AddVariable")) do created[c.args[1]] = c.args[3] end
            local expected = {}
            for _, name in ipairs(VARIABLE_NAMES) do
                expected[name] = true
                H.isTrue(mock.variables[name] ~= nil, name .. " should have been created")
                H.equal(created[name], "STRING", name .. " should be created as a STRING")
                -- An external write would desynchronise the driver's cache: it
                -- would still hold the driver's last value, so nothing would be
                -- rewritten until the computed value moved, and the variable
                -- could read wrong indefinitely.
                H.equal(mock.variableReadOnly[name], true, name .. " should be read-only")
            end
            H.equal(#VARIABLE_NAMES, 23, "the brief calls for twenty-three variables")

            -- The reverse direction: an eighteenth variable added to driver.lua
            -- would otherwise ship with nothing asserting it exists at all.
            for name in pairs(mock.variables) do
                H.isTrue(expected[name],
                    name .. " was created but is not in the expected list")
            end

            -- POWER_STATE is a variable the receiver proxy owns on this same
            -- device. Creating one of our own would put two writers on one name.
            H.equal(mock.variables.POWER_STATE, nil,
                "POWER_STATE belongs to the proxy; ours is UNIT_POWER")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "a document populates the variables with correct values, including the computed volume percent",
        fn = function()
            loadDriver()
            goLive()
            -- vpl -50, vph 0, volume -25: (-25 - -50) / (0 - -50) * 100 = 50.
            local expected = {
                CONNECTED = "true",
                UNIT_POWER = "On",
                INPUT_ID = "h1",
                INPUT_LABEL = "Streamer",
                VOLUME_DB = "-25",
                VOLUME_PERCENT = "50",
                MUTED = "false",
                SURROUND_MODE = "Native Dolby ATMOS",
                INPUT_FORMAT = "Dolby MAT/PCM",
                INPUT_PROGRAM = "Object Audio",
                INPUT_SAMPLE_RATE = "48 kHz",
                OUTPUT_FORMAT = "5.1.2",
                OUTPUT_SAMPLE_RATE = "48 kHz",
                VIDEO_RESOLUTION = "3840x2160p60Hz",
                VIDEO_COLORSPACE = "BT2020",
                VIDEO_HDR = "HDR10",
                DIRAC_STATE = "on",
                LOUDNESS = "off",
                NIGHT_MODE = "off",
                DIALOG_ENHANCE = "3",
                BASS_ENHANCE = "off",
                DIRAC_SLOT = "0",
                LIP_SYNC_MS = "20",
            }
            for name, value in pairs(expected) do
                H.equal(mock.variables[name], value, name)
            end
            H.assertNoErrorLog()
        end,
    },
    {
        name = "INPUT_LABEL falls back to the Control4 connection name when the unit reports " ..
               "none, and to empty when neither exists",
        fn = function()
            loadDriver()
            local F = require("tests.fixtures")

            -- "b" is Mapping.INPUTS' Bluetooth key; F.modern()'s own inputs
            -- table has no entry for it at all, so the unit has no label to
            -- offer and the Control4 connection name should be used instead.
            local doc = F.modern()
            doc.input = "b"
            goLiveWith(doc)
            H.equal(mock.variables.INPUT_ID, "b")
            H.equal(mock.variables.INPUT_LABEL, "Bluetooth",
                "no label from the unit, so the Control4 connection name is used")

            -- An input key neither the unit's own inputs table nor
            -- Mapping.INPUTS knows about (an unmodeled source, invented here).
            mock.clearCalls()
            pushUpdate("/input", "xyz")
            H.equal(mock.variables.INPUT_ID, "xyz")
            H.equal(mock.variables.INPUT_LABEL, "",
                "neither the unit nor Mapping.INPUTS knows this key")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "an msoupdate on a single status field updates exactly that variable and no others",
        fn = function()
            loadDriver()
            goLive()
            mock.clearCalls()
            pushUpdate("/status/DECSampleRate", "96 kHz")
            local writes = callsNamed("SetVariable")
            H.count(writes, 1, "only the sample-rate variable should have moved")
            H.equal(writes[1].args[1], "INPUT_SAMPLE_RATE")
            H.equal(writes[1].args[2], "96 kHz")
            H.equal(mock.variables.INPUT_SAMPLE_RATE, "96 kHz")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "a targeted push on one processing field updates only that variable",
        fn = function()
            loadDriver()
            goLive()
            mock.clearCalls()
            pushUpdate("/dialogEnh", 5)
            local writes = callsNamed("SetVariable")
            H.count(writes, 1, "only DIALOG_ENHANCE should have moved")
            H.equal(writes[1].args[1], "DIALOG_ENHANCE")
            H.equal(writes[1].args[2], "5")
            H.equal(mock.variables.DIALOG_ENHANCE, "5")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "a /cal container replace re-derives DIRAC_SLOT and LIP_SYNC_MS and nothing else",
        fn = function()
            loadDriver()
            goLive()
            mock.clearCalls()
            sendFrame("msoupdate " .. JSON:encode({
                { op = "replace", path = "/cal", value = {
                    vpl = -50, vph = 0, zeroPoint = 0, diracactive = "on",
                    currentdiracslot = 4, lipsync = 90,
                } },
            }))
            H.equal(mock.variables.DIRAC_SLOT, "4")
            H.equal(mock.variables.LIP_SYNC_MS, "90")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "a redundant push writes no variables and fires no events",
        fn = function()
            loadDriver()
            goLive()
            mock.clearCalls()
            -- The exact value the unit already reported: state.lua drops this
            -- before onChanges is even called, so nothing downstream should run.
            pushUpdate("/status/DECSampleRate", "48 kHz")
            H.count(callsNamed("SetVariable"), 0)
            H.count(callsNamed("FireEvent"), 0)
            H.assertNoErrorLog()
        end,
    },
    {
        name = "a nil field yields an empty string, never the literal text 'nil'",
        fn = function()
            loadDriver()
            local F = require("tests.fixtures")
            goLiveWith(F.sparse())   -- { volume = -10, powerIsOn = false }, everything else absent

            for _, name in ipairs(VARIABLE_NAMES) do
                local value = mock.variables[name]
                H.equal(type(value), "string", name .. " must always be a string")
                H.isFalse(value == "nil", name .. " must never be the literal text 'nil'")
            end

            H.equal(mock.variables.SURROUND_MODE, "")
            H.equal(mock.variables.INPUT_FORMAT, "")
            H.equal(mock.variables.INPUT_PROGRAM, "")
            H.equal(mock.variables.INPUT_SAMPLE_RATE, "")
            H.equal(mock.variables.OUTPUT_FORMAT, "")
            H.equal(mock.variables.OUTPUT_SAMPLE_RATE, "")
            H.equal(mock.variables.VIDEO_RESOLUTION, "")
            H.equal(mock.variables.VIDEO_COLORSPACE, "")
            H.equal(mock.variables.VIDEO_HDR, "")
            H.equal(mock.variables.DIRAC_STATE, "")
            H.equal(mock.variables.LOUDNESS, "", "loudness is absent from F.sparse()")
            H.equal(mock.variables.NIGHT_MODE, "")
            H.equal(mock.variables.DIALOG_ENHANCE, "")
            H.equal(mock.variables.BASS_ENHANCE, "")
            H.equal(mock.variables.DIRAC_SLOT, "")
            H.equal(mock.variables.LIP_SYNC_MS, "")
            H.equal(mock.variables.INPUT_ID, "", "input is absent from F.sparse()")
            H.equal(mock.variables.INPUT_LABEL, "", "no input selected, so no label to show")
            H.equal(mock.variables.VOLUME_PERCENT, "", "vpl/vph are absent, so no percent can be computed")
            -- The contrast that matters: powerIsOn is genuinely false in this
            -- fixture and reads "Off", while muted is simply absent and reads
            -- empty. Reporting an absent field as "false" would be a
            -- determinate answer to a question nothing has answered yet.
            H.equal(mock.variables.UNIT_POWER, "Off", "F.sparse() reports powerIsOn = false")
            H.equal(mock.variables.MUTED, "", "muted is absent, so unknown rather than false")
            H.assertNoErrorLog()
        end,
    },

    --------------------------------------------------------------------------
    -- Events
    --------------------------------------------------------------------------
    {
        name = "the Connected event fires exactly once when the session comes up",
        fn = function()
            loadDriver()
            mock.clearCalls()
            goLive()
            local fired = callsNamed("FireEvent")
            local count = 0
            for _, c in ipairs(fired) do
                if c.args[1] == "Connected" then count = count + 1 end
            end
            H.equal(count, 1)
            H.assertNoErrorLog()
        end,
    },
    {
        name = "the Disconnected event fires exactly once when the connection drops",
        fn = function()
            loadDriver()
            goLive()
            mock.clearCalls()
            OnConnectionStatusChanged(Mapping.NETWORK_BINDING, 80, "OFFLINE")
            local fired = callsNamed("FireEvent")
            H.count(fired, 1)
            H.equal(fired[1].args[1], "Disconnected")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "the first document does not fire Powered On, Input Changed or Surround Mode " ..
               "Changed -- Connected already covers discovering the starting state",
        fn = function()
            loadDriver()
            mock.clearCalls()
            goLive()
            local names = {}
            for _, c in ipairs(callsNamed("FireEvent")) do names[c.args[1]] = true end
            H.isTrue(names["Connected"], "Connected should fire")
            H.isFalse(names["Powered On"] or false,
                "the initial power reading is discovery, not a transition")
            H.isFalse(names["Input Changed"] or false)
            H.isFalse(names["Surround Mode Changed"] or false)
        end,
    },
    {
        name = "Powered Off fires once on a true -> false transition, and Powered On on the way back",
        fn = function()
            loadDriver()
            goLive()   -- power starts true

            mock.clearCalls()
            pushUpdate("/powerIsOn", false)
            local firedOff = callsNamed("FireEvent")
            H.count(firedOff, 1)
            H.equal(firedOff[1].args[1], "Powered Off")
            H.equal(mock.variables.UNIT_POWER, "Off")

            mock.clearCalls()
            pushUpdate("/powerIsOn", true)
            local firedOn = callsNamed("FireEvent")
            H.count(firedOn, 1)
            H.equal(firedOn[1].args[1], "Powered On")
            H.equal(mock.variables.UNIT_POWER, "On")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "Input Changed fires exactly once when the selected input changes",
        fn = function()
            loadDriver()
            goLive()
            mock.clearCalls()
            pushUpdate("/input", "h2")
            local fired = callsNamed("FireEvent")
            H.count(fired, 1)
            H.equal(fired[1].args[1], "Input Changed")
            H.equal(mock.variables.INPUT_ID, "h2")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "Surround Mode Changed fires exactly once when the unit's surround mode text changes",
        fn = function()
            loadDriver()
            goLive()
            mock.clearCalls()
            pushUpdate("/status/SurroundMode", "Dolby Surround")
            local fired = callsNamed("FireEvent")
            H.count(fired, 1)
            H.equal(fired[1].args[1], "Surround Mode Changed")
            H.equal(mock.variables.SURROUND_MODE, "Dolby Surround")
            H.assertNoErrorLog()
        end,
    },

    --------------------------------------------------------------------------
    -- Programming commands
    --------------------------------------------------------------------------
    {
        name = "a command invoked with no parameter at all writes nothing",
        fn = function()
            -- Control4 should always supply a declared param, but a command
            -- invoked from a hand-written program or a malformed call must not
            -- reach the unit with a nil mode.
            loadDriver()
            goLive()
            for _, command in ipairs({ "Set Dirac Processing", "Set Night Mode",
                                        "Set Bass Enhance", "Run Macro" }) do
                mock.clearCalls()
                ExecuteCommand(command, {})
                mock.advance(50)
                for _, raw in ipairs(mock.sent) do
                    H.isTrue(raw:find("changemso", 1, true) == nil,
                        command .. " with no parameter must not write")
                end
                -- A name this driver does not have would also "not write", and
                -- would pass this test while covering nothing at all.
                for _, line in ipairs(mock.printed) do
                    H.isTrue(line:find("no handler for action", 1, true) == nil,
                        command .. " is not a command this driver has: " .. line)
                end
                -- INSIDE the loop: mock.clearCalls() above wipes mock.printed
                -- every iteration, so an assertion after the loop can only ever
                -- see the last command -- and a missing guard on any of the
                -- others would slip through, which is exactly what happened.
                H.assertNoErrorLog()
            end
        end,
    },
    {
        name = "every command declared in driver.xml has a handler",
        fn = function()
            -- Mirrors the actions-coverage test above, but for <commands>: a
            -- programming command arrives as ExecuteCommand("<declared name>",
            -- tParams) directly -- the exact declared name, spaces and all --
            -- never wrapped in LUA_ACTION the way an Actions-tab entry is.
            local handle = assert(io.open("driver.xml", "r"))
            local xml = handle:read("*a")
            handle:close()

            -- Scoped to the <commands> block on purpose. An unscoped search for
            -- <command> also matches the <command>TOKEN</command> inside every
            -- <action>; that only fails to break this test because an action's
            -- command element has no nested <name>, which is coincidence, not
            -- construction.
            local commandsBlock = xml:match("<commands>(.-)</commands>") or ""
            local names = {}
            for block in commandsBlock:gmatch("<command>(.-)</command>") do
                local name = block:match("<name>%s*(.-)%s*</name>")
                if name then table.insert(names, name) end
            end
            H.isTrue(#names >= 6, "expected the declared commands, found " .. #names)

            loadDriver()
            goLive()
            for _, name in ipairs(names) do
                mock.clearCalls()
                ExecuteCommand(name, {})
                for _, line in ipairs(mock.printed) do
                    H.isTrue(line:find("no handler for action", 1, true) == nil,
                        name .. " has no handler: " .. line)
                end
                H.assertNoErrorLog()
            end
        end,
    },
    {
        name = "Set Dirac Processing writes /cal/diracactive with the chosen mode",
        fn = function()
            loadDriver()
            goLive()
            mock.clearCalls()
            ExecuteCommand("Set Dirac Processing", { Mode = "Bypass" })
            mock.advance(50)
            local ops = lastWrittenOps()
            H.equal(ops[1].path, "/cal/diracactive")
            H.equal(ops[1].value, "bypass")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "Set Night Mode writes /night with the chosen mode",
        fn = function()
            loadDriver()
            goLive()
            mock.clearCalls()
            ExecuteCommand("Set Night Mode", { Mode = "Auto" })
            mock.advance(50)
            local ops = lastWrittenOps()
            H.equal(ops[1].path, "/night")
            H.equal(ops[1].value, "auto")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "Set Dialog Enhance writes /dialogEnh as a number, from a string parameter",
        fn = function()
            loadDriver()
            goLive()
            mock.clearCalls()
            -- Control4 delivers every programming-command parameter as a
            -- string, "5" not 5 -- this is the real shape.
            ExecuteCommand("Set Dialog Enhance", { Level = "5" })
            mock.advance(50)
            local ops = lastWrittenOps()
            H.equal(ops[1].path, "/dialogEnh")
            H.equal(ops[1].value, 5)
            H.assertNoErrorLog()
        end,
    },
    {
        name = "Set Bass Enhance writes /bassenhance with the chosen mode",
        fn = function()
            loadDriver()
            goLive()
            mock.clearCalls()
            ExecuteCommand("Set Bass Enhance", { Mode = "On" })
            mock.advance(50)
            local ops = lastWrittenOps()
            H.equal(ops[1].path, "/bassenhance")
            H.equal(ops[1].value, "on")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "Toggle Bass Enhance flips from whatever the unit currently reports",
        fn = function()
            loadDriver()
            goLive()   -- F.modern() reports bassenhance = "off"
            mock.clearCalls()
            ExecuteCommand("Toggle Bass Enhance", {})
            mock.advance(50)
            local ops = lastWrittenOps()
            H.equal(ops[1].path, "/bassenhance")
            H.equal(ops[1].value, "on", "toggled from off")

            ExecuteCommand("Toggle Bass Enhance", {})
            mock.advance(50)
            H.equal(lastWrittenOps()[1].value, "off", "toggled back from on")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "Set Lip Sync Delay writes both the calibration path and the current input's own delay",
        fn = function()
            loadDriver()
            goLive()   -- F.modern()'s selected input is h1
            mock.clearCalls()
            ExecuteCommand("Set Lip Sync Delay", { Delay = "90" })
            mock.advance(50)
            local ops = lastWrittenOps()
            H.isTrue(ops ~= nil and #ops >= 2,
                "expected both writes in one flush, got " .. tostring(ops and #ops))

            local byPath = {}
            for _, op in ipairs(ops) do byPath[op.path] = op.value end
            H.equal(byPath["/cal/lipsync"], 90)
            H.equal(byPath["/inputs/h1/delay"], 90)
            H.assertNoErrorLog()
        end,
    },
    {
        name = "Set Lip Sync Delay writes only /cal/lipsync when no input is known",
        fn = function()
            loadDriver()
            local F = require("tests.fixtures")
            goLiveWith(F.sparse())   -- { volume = -10, powerIsOn = false }: no input at all
            H.equal(DRIVER.state.fields.input, nil, "the fixture reports no input")
            mock.clearCalls()
            ExecuteCommand("Set Lip Sync Delay", { Delay = "50" })
            mock.advance(50)
            local ops = lastWrittenOps()
            H.count(ops, 1, "only the calibration path should be written, not a nil-keyed input path")
            H.equal(ops[1].path, "/cal/lipsync")
            H.equal(ops[1].value, 50)
            H.assertNoErrorLog()
        end,
    },
    {
        name = "Set Dirac Slot writes /cal/currentdiracslot as a number, from a string parameter",
        fn = function()
            loadDriver()
            goLive()   -- F.modern() starts on wire slot 0
            mock.clearCalls()
            ExecuteCommand("Set Dirac Slot", { Slot = "4" })
            mock.advance(50)
            local ops = lastWrittenOps()
            H.equal(ops[1].path, "/cal/currentdiracslot")
            H.equal(ops[1].value, 4)
            H.assertNoErrorLog()
        end,
    },
    {
        name = "an out-of-range or unrecognised command parameter is refused: a log line, no write",
        fn = function()
            loadDriver({ ["Debug Mode"] = "On" })
            goLive()

            local cases = {
                { "Set Dirac Processing", { Mode = "Loud" } },
                { "Set Night Mode",     { Mode = "Maximum" } },
                { "Set Dialog Enhance", { Level = "7" } },
                { "Set Dialog Enhance", { Level = "-1" } },
                { "Set Dialog Enhance", { Level = "not a number" } },
                { "Set Bass Enhance",   { Mode = "Maybe" } },
                { "Set Lip Sync Delay", { Delay = "341" } },
                { "Set Lip Sync Delay", { Delay = "-1" } },
                { "Set Lip Sync Delay", { Delay = "not a number" } },
                { "Set Dirac Slot",     { Slot = "6" } },
                { "Set Dirac Slot",     { Slot = "-1" } },
                { "Set Dirac Slot",     { Slot = "not a number" } },
            }
            for _, case in ipairs(cases) do
                local name, params = case[1], case[2]
                mock.clearCalls()
                ExecuteCommand(name, params)
                mock.advance(50)
                H.equal(lastWrittenOps(), nil, name .. " should not have written anything")

                local logged = false
                for _, line in ipairs(mock.printed) do
                    if line:find("HTP-1:", 1, true) then logged = true end
                end
                H.isTrue(logged, name .. " should have logged the rejection")
                H.assertNoErrorLog()
            end
        end,
    },

    --------------------------------------------------------------------------
    -- Dirac Filter picker
    --------------------------------------------------------------------------
    {
        name = "the Dirac Filter list is populated from the unit's own slot names, in wire " ..
               "order, with the current slot selected",
        fn = function()
            loadDriver()
            goLive()   -- F.modern(): Calibrated/Flat/""/Movie/Music/Custom, slot 0 selected
            local last = lastPropertyList("Dirac Filter")
            H.isTrue(last ~= nil, "the property should have been populated on the first document")
            H.equal(last.args[2],
                "0 - Calibrated,1 - Flat,2 - Slot 2,3 - Movie,4 - Music,5 - Custom",
                "wire order, comma-separated, the unnamed slot falling back to its own number")
            H.equal(last.args[3], "0 - Calibrated", "wire slot 0 is the unit's current selection")
            H.equal(Properties["Dirac Filter"], "0 - Calibrated")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "a slot the unit left unnamed still appears in the list, and can be the selection",
        fn = function()
            loadDriver()
            local F = require("tests.fixtures")
            -- F.legacy(): wire slot 1 has no `name` key at all; currentdiracslot = 1.
            goLiveWith(F.legacy())
            local last = lastPropertyList("Dirac Filter")
            H.equal(last.args[2],
                "0 - Slot 1,1 - Slot 1,2 - Flat,3 - Movie,4 - Music,5 - Custom",
                "wire slot 0's real invented name happens to read 'Slot 1' too; wire slot 1 is " ..
                "the unnamed fallback -- the leading index keeps the two apart")
            H.equal(last.args[3], "1 - Slot 1", "the unit's current slot has no name either")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "a renamed Dirac slot keeps the selection on the same slot, not on the same text",
        fn = function()
            -- The Dirac picker's counterpart to the Macro sentinel, and the
            -- reason it needs no sentinel of its own: this selection is not a
            -- stored choice but a mirror of /cal/currentdiracslot, so it is
            -- keyed on the SLOT INDEX. Renaming the selected slot moves its
            -- label and nothing else. The six slots are fixed and cannot be
            -- deleted, so "the selection vanished" has no analogue here.
            loadDriver()
            goLive()   -- wire slot 0, "Calibrated", is current
            mock.clearCalls()
            pushUpdate("/cal/slots", {
                { name = "Reference" }, { name = "Flat" }, { name = "" },
                { name = "Movie" }, { name = "Music" }, { name = "Custom" },
            })
            local last = lastPropertyList("Dirac Filter")
            H.isTrue(last ~= nil, "the rename should reach Composer")
            H.equal(last.args[3], "0 - Reference",
                "still wire slot 0 -- the selection follows the slot, not the old label")
            H.equal(lastWrittenOps(), nil, "and a rename must never turn into a write")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "an out-of-range current slot selects nothing rather than another filter",
        fn = function()
            -- If the unit ever reports a slot this driver has no row for, the
            -- honest answer is no selection. Falling back to slot 0 would show
            -- a filter that is not the one running.
            loadDriver()
            goLive()
            mock.clearCalls()
            pushUpdate("/cal/currentdiracslot", 9)
            local last = lastPropertyList("Dirac Filter")
            H.isTrue(last ~= nil, "the property is still repopulated")
            H.equal(last.args[3], "",
                "nothing selected, NOT '0 - Calibrated'")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "selecting a Dirac Filter entry writes the matching integer slot",
        fn = function()
            loadDriver()
            goLive()
            mock.clearCalls()
            Properties["Dirac Filter"] = "3 - Movie"
            OnPropertyChanged("Dirac Filter")
            mock.advance(50)
            local ops = lastWrittenOps()
            H.equal(ops[1].path, "/cal/currentdiracslot")
            H.equal(ops[1].value, 3)
            H.assertNoErrorLog()
        end,
    },
    {
        name = "selecting the entry for wire index 2 writes 2, not 1 or 3",
        fn = function()
            loadDriver()
            goLive()
            mock.clearCalls()
            Properties["Dirac Filter"] = "2 - Slot 2"
            OnPropertyChanged("Dirac Filter")
            mock.advance(50)
            local ops = lastWrittenOps()
            H.equal(ops[1].path, "/cal/currentdiracslot")
            H.equal(ops[1].value, 2, "wire index 2 must write 2, not an off-by-one neighbour")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "selecting the entry already selected writes nothing",
        fn = function()
            -- The direct case of the feedback-loop guard: choosing the slot the
            -- unit already reports is indistinguishable from Composer replaying
            -- the driver's own selection back, so both must be silent.
            loadDriver()
            goLive()   -- F.modern() starts on wire slot 0
            mock.clearCalls()
            Properties["Dirac Filter"] = "0 - Calibrated"
            OnPropertyChanged("Dirac Filter")
            mock.advance(50)
            H.equal(lastWrittenOps(), nil, "already the unit's current slot; nothing to write")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "a push from the unit updates the Dirac Filter property and writes nothing back",
        fn = function()
            -- The loop this guards against: the driver writes the slot, the
            -- unit echoes it back as a push, the push repopulates the property
            -- via UpdatePropertyList, and Composer may report that repopulation
            -- as its own property change. None of that may turn into a second
            -- write.
            loadDriver()
            goLive()   -- F.modern() starts on wire slot 0
            mock.clearCalls()
            pushUpdate("/cal/currentdiracslot", 3)
            H.equal(Properties["Dirac Filter"], "3 - Movie",
                "the property should reflect the unit's own push")

            -- Composer replaying the driver's own UpdatePropertyList call.
            OnPropertyChanged("Dirac Filter")
            mock.advance(50)
            H.equal(lastWrittenOps(), nil, "nothing should be written back to the unit")
            H.assertNoErrorLog()
        end,
    },

    --------------------------------------------------------------------------
    -- Macros
    --------------------------------------------------------------------------
    -- F.modern()'s stored macros, in slot order:
    --   cmda        "Movie Night"  /volume -22, /dialogEnh 5
    --   cmdb        "Listening"    /volume -40 then /volume -30
    --   cmdc        "Late Night"   nothing stored
    --   cmdd        unnamed        one good operation among three that are not
    --   preset1     "Preset 1"     /upmix/select auro
    --   cmdcustom1  unnamed        /muted true
    {
        name = "the Macro list carries the names the unit gave its stored macros",
        fn = function()
            loadDriver()
            goLive()
            local last = lastPropertyList("Macro")
            H.isTrue(last ~= nil, "the property should be populated from the first document")
            H.equal(last.args[2], "(none),Movie Night,Listening,cmdd,Preset 1,cmdcustom1",
                "in slot order, with the slot key standing in where the owner named nothing")
            H.equal(last.args[3], "(none)",
                "nothing had been selected before, so nothing is selected now -- the driver " ..
                "must not decide on the installer's behalf which macro their action runs")
            H.equal(Properties["Macro"], "(none)")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "a slot the unit named but left empty is not offered",
        fn = function()
            -- Selecting it could only do nothing, which is worse than not
            -- offering it: it looks like a control.
            loadDriver()
            goLive()
            local items = lastPropertyList("Macro").args[2]
            H.equal(items:find("Late Night", 1, true), nil,
                "cmdc is named but stores no operations: " .. items)
            H.equal(DRIVER.state.macros.cmdc.name, "Late Night",
                "the name is still tracked, just not offered")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "the Macro property is left alone when the unit reports no macros at all",
        fn = function()
            -- Nothing to say: the unit never mentioned macros, so there is no
            -- change to report and no repopulation. driver.xml already defaults
            -- the property to "(none)", so what Composer shows is still right.
            loadDriver()
            local F = require("tests.fixtures")
            goLiveWith(F.legacy())   -- no /svronly block at all
            H.equal(lastPropertyList("Macro"), nil,
                "no macros reported and none had, so there is nothing to repopulate")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "deleting the last macro leaves the list holding only (none)",
        fn = function()
            -- The one case that must not leave a stale list standing: every
            -- macro is gone, so every entry Composer still shows would run
            -- something the unit no longer has.
            loadDriver()
            goLive()
            Properties["Macro"] = "Movie Night"
            local F = require("tests.fixtures")
            local doc = F.modern()
            doc.svronly = { macroNames = {} }

            mock.clearCalls()
            sendFrame("mso " .. JSON:encode(doc))
            local last = lastPropertyList("Macro")
            H.isTrue(last ~= nil, "the picker must be emptied, not left stale")
            H.equal(last.args[2], "(none)", "the sentinel is the whole list")
            H.equal(last.args[3], "(none)")

            mock.clearCalls()
            ExecuteCommand("LUA_ACTION", { ACTION = "RUN_SELECTED_MACRO" })
            mock.advance(50)
            H.equal(changeMsoCount(), 0, "and there is nothing left to run")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "a macro the owner named (none) is listed under its slot key, not as the sentinel",
        fn = function()
            -- The collision case, and the reason it must not be left to resolve
            -- by luck: an entry whose text equals the sentinel is a row the
            -- picker cannot tell from "nothing selected". Listed under its slot
            -- key it stays visible, selectable and runnable.
            loadDriver()
            local F = require("tests.fixtures")
            local doc = F.modern()
            doc.svronly.macroNames.preset1 = "(none)"
            goLiveWith(doc)

            local last = lastPropertyList("Macro")
            H.equal(last.args[2], "(none),Movie Night,Listening,cmdd,preset1,cmdcustom1",
                "one sentinel only -- preset1 appears under its key, not as a second '(none)'")

            -- And it stays runnable, by the text shown and by its slot key --
            -- both being "preset1" here, which is the point of the fallback.
            mock.clearCalls()
            ExecuteCommand("Run Macro", { Macro = "preset1" })
            mock.advance(50)
            local ops = lastWrittenOps()
            H.count(ops, 1, "the macro must still be reachable")
            H.equal(ops[1].path, "/upmix/select")

            -- But the sentinel itself never resolves, even though this unit has
            -- a macro whose REAL name is "(none)" -- Run Macro matches raw
            -- names as well as displayed text, so without its guard this
            -- request would run preset1.
            mock.clearCalls()
            ExecuteCommand("Run Macro", { Macro = "(none)" })
            mock.advance(50)
            H.equal(changeMsoCount(), 0, "'(none)' means nothing, never a macro named that")
            H.equal(lastWrittenOps(), nil)

            -- Same through the action, which reads the property.
            mock.clearCalls()
            Properties["Macro"] = "(none)"
            ExecuteCommand("LUA_ACTION", { ACTION = "RUN_SELECTED_MACRO" })
            mock.advance(50)
            H.equal(changeMsoCount(), 0)
            H.assertNoErrorLog()
        end,
    },
    {
        name = "deleting the selected macro cannot start running one the owner named (none)",
        fn = function()
            -- The exact failure the sentinel exists to prevent, with the one
            -- name that could defeat it. Without the resolver guards this ran
            -- preset1's operations after cmda was deleted.
            loadDriver()
            local F = require("tests.fixtures")
            local doc = F.modern()
            doc.svronly.macroNames.preset1 = "(none)"
            goLiveWith(doc)
            Properties["Macro"] = "Movie Night"       -- cmda
            OnPropertyChanged("Macro")

            local gone = F.modern()
            gone.svronly.macroNames.preset1 = "(none)"
            gone.svronly.cmda = nil
            gone.svronly.macroNames.cmda = nil
            mock.clearCalls()
            sendFrame("mso " .. JSON:encode(gone))
            H.equal(lastPropertyList("Macro").args[3], "(none)")

            mock.clearCalls()
            ExecuteCommand("LUA_ACTION", { ACTION = "RUN_SELECTED_MACRO" })
            mock.advance(50)
            H.equal(changeMsoCount(), 0,
                "deleting a macro must not start running a DIFFERENT one named (none)")
            H.equal(lastWrittenOps(), nil)
            H.assertNoErrorLog()
        end,
    },
    {
        name = "renaming the selected macro on the unit keeps it selected",
        fn = function()
            -- The selection is the installer's choice of MACRO, not of a string.
            -- Dropping it on a rename would leave their Run Selected Macro
            -- programming doing nothing, with nothing to say why.
            loadDriver()
            goLive()
            Properties["Macro"] = "Movie Night"       -- cmda
            OnPropertyChanged("Macro")

            mock.clearCalls()
            pushUpdate("/svronly/macroNames/cmda", "Film Night")
            local last = lastPropertyList("Macro")
            H.equal(last.args[2], "(none),Film Night,Listening,cmdd,Preset 1,cmdcustom1")
            H.equal(last.args[3], "Film Night", "still cmda, under its new name")

            mock.clearCalls()
            ExecuteCommand("LUA_ACTION", { ACTION = "RUN_SELECTED_MACRO" })
            mock.advance(50)
            local ops = lastWrittenOps()
            H.count(ops, 2, "and the action still runs cmda")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "Run Selected Macro replays the stored operations as one changemso",
        fn = function()
            loadDriver()
            goLive()
            Properties["Macro"] = "Movie Night"   -- the installer picking cmda
            mock.clearCalls()
            ExecuteCommand("LUA_ACTION", { ACTION = "RUN_SELECTED_MACRO" })
            mock.advance(50)

            H.equal(changeMsoCount(), 1, "one message, not one per operation")
            local ops = lastWrittenOps()
            H.count(ops, 2, "a macro touching two paths must send both")
            local byPath = {}
            for _, op in ipairs(ops) do byPath[op.path] = op.value end
            H.equal(byPath["/volume"], -22)
            H.equal(byPath["/dialogEnh"], 5)
            H.assertNoErrorLog()
        end,
    },
    {
        name = "Run Selected Macro runs whatever the property currently shows",
        fn = function()
            loadDriver()
            goLive()
            mock.clearCalls()
            Properties["Macro"] = "cmdcustom1"   -- the installer picking another entry
            ExecuteCommand("LUA_ACTION", { ACTION = "RUN_SELECTED_MACRO" })
            mock.advance(50)
            local ops = lastWrittenOps()
            H.count(ops, 1)
            H.equal(ops[1].path, "/muted")
            H.equal(ops[1].value, true)
            H.assertNoErrorLog()
        end,
    },
    {
        name = "Run Selected Macro runs the entry that was picked, not a slot that shares its text",
        fn = function()
            -- The action never sees a slot key: Composer hands it the DISPLAY
            -- TEXT of the entry the installer chose, and for that text is
            -- authoritative by construction. Preferring a slot-key match runs a
            -- different macro whenever an owner has named one after a slot key
            -- -- which they are entitled to do.
            loadDriver()
            goLive()
            pushUpdate("/svronly/macroNames/cmda", "cmdcustom1")
            Properties["Macro"] = "cmdcustom1"

            mock.clearCalls()
            ExecuteCommand("LUA_ACTION", { ACTION = "RUN_SELECTED_MACRO" })
            mock.advance(50)
            local ops = lastWrittenOps()
            H.count(ops, 2, "cmda is the first entry reading 'cmdcustom1', and what was picked")
            local byPath = {}
            for _, op in ipairs(ops) do byPath[op.path] = op.value end
            H.equal(byPath["/volume"], -22)
            H.equal(byPath["/dialogEnh"], 5)
            H.equal(byPath["/muted"], nil, "the cmdcustom1 SLOT must not have run instead")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "Run Macro still resolves a slot key ahead of a macro named after one",
        fn = function()
            -- The command's flexibility is deliberate and stays: a programmer
            -- typing 'cmdcustom1' means the slot, which is the unambiguous
            -- request, and is what survives the macro being renamed.
            loadDriver()
            goLive()
            pushUpdate("/svronly/macroNames/cmda", "cmdcustom1")

            mock.clearCalls()
            ExecuteCommand("Run Macro", { Macro = "cmdcustom1" })
            mock.advance(50)
            local ops = lastWrittenOps()
            H.count(ops, 1, "the slot key wins where the two could collide")
            H.equal(ops[1].path, "/muted")
            H.equal(ops[1].value, true)
            H.assertNoErrorLog()
        end,
    },
    {
        name = "a macro touching one path twice sends only the later value",
        fn = function()
            loadDriver()
            goLive()
            mock.clearCalls()
            ExecuteCommand("Run Macro", { Macro = "Listening" })   -- cmdb
            mock.advance(50)
            local ops = lastWrittenOps()
            H.count(ops, 1, "coalesced by path; sending both would be a write the second undoes")
            H.equal(ops[1].path, "/volume")
            H.equal(ops[1].value, -30, "the later of the two stored values")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "Run Macro accepts either the macro's name or its slot key",
        fn = function()
            loadDriver()
            goLive()
            for _, request in ipairs({ "Movie Night", "cmda" }) do
                mock.clearCalls()
                ExecuteCommand("Run Macro", { Macro = request })
                mock.advance(50)
                local ops = lastWrittenOps()
                H.count(ops, 2, "'" .. request .. "' should have run cmda")
                local byPath = {}
                for _, op in ipairs(ops) do byPath[op.path] = op.value end
                H.equal(byPath["/volume"], -22, "'" .. request .. "'")
                H.equal(byPath["/dialogEnh"], 5, "'" .. request .. "'")
            end
            H.assertNoErrorLog()
        end,
    },
    {
        name = "an entry that is not an operation is skipped rather than forwarded",
        fn = function()
            -- cmdd stores a bare string, an entry with no op, an entry with no
            -- path, and a remove with no value -- alongside one real operation.
            loadDriver()
            goLive()
            mock.clearCalls()
            ExecuteCommand("Run Macro", { Macro = "cmdd" })
            mock.advance(50)
            local ops = lastWrittenOps()
            H.count(ops, 1, "only the one well-formed operation may reach the unit")
            H.equal(ops[1].path, "/night")
            H.equal(ops[1].value, "auto")
            -- NOT H.assertNoErrorLog(): skipping four of five stored entries is
            -- now reported at the always-written level on purpose, because the
            -- macro did not run in full. Asserting the report is strictly more
            -- than asserting silence was -- silence here was the defect.
            H.isTrue(loggedContaining("ran 1 of 5 stored entries"),
                "the four skipped entries must be reported, not passed over quietly")
            -- But the report must be the ONLY thing reported. Swapping silence
            -- for one expected line would otherwise stop catching a second,
            -- unrelated error raised on the same path.
            local errors = 0
            for _, line in ipairs(mock.printed) do
                if line:find("ErrorLog:", 1, true) then errors = errors + 1 end
            end
            H.equal(errors, 1, "the skip report is the only error this run may log")
        end,
    },
    {
        name = "a stored guard or add is not sent; only the replace reaches the unit",
        fn = function()
            -- Only `replace` survives ingest, because only `replace` is what the
            -- write path sends. A stored `test` is a guard the unit evaluates --
            -- replaying it as a replace would MUTE the room -- and an `add`
            -- would arrive as a replace on a member the unit does not have,
            -- which it rejects wholesale.
            loadDriver()
            goLive()
            sendFrame("msoupdate " .. JSON:encode({
                { op = "replace", path = "/svronly/preset2", value = {
                    { op = "test",    path = "/muted",        value = true },
                    { op = "add",     path = "/upmix/select", value = "auro" },
                    { op = "replace", path = "/night",        value = "auto" },
                } },
            }))
            mock.clearCalls()
            ExecuteCommand("Run Macro", { Macro = "preset2" })
            mock.advance(50)
            local ops = lastWrittenOps()
            H.count(ops, 1, "only the replace may reach the unit")
            H.equal(ops[1].path, "/night")
            H.equal(ops[1].value, "auto")
        end,
    },
    {
        name = "a slot storing only non-replace entries is not offered and runs nothing",
        fn = function()
            loadDriver()
            goLive()
            mock.clearCalls()
            sendFrame("msoupdate " .. JSON:encode({
                { op = "replace", path = "/svronly/preset3", value = {
                    { op = "test", path = "/muted", value = true },
                } },
            }))
            H.equal(lastPropertyList("Macro"), nil,
                "a slot with nothing replayable never enters the picker")

            mock.clearCalls()
            ExecuteCommand("Run Macro", { Macro = "preset3" })
            mock.advance(50)
            H.equal(changeMsoCount(), 0, "a guard must never be executed as a setting")
            H.equal(lastWrittenOps(), nil)
            H.isTrue(loggedContaining("ran 0 of 1 stored entries"),
                "and a macro that did nothing at all must not look like one that ran")
        end,
    },
    {
        name = "a macro that could not run in full says so with Debug Mode off",
        fn = function()
            -- Off is the SHIPPING DEFAULT, and a macro that under-runs is
            -- exactly the case that must not be hidden behind a debug switch:
            -- the owner pressed one button and got part of what they saved.
            loadDriver()
            H.equal(Properties["Debug Mode"], "Off")
            goLive()
            mock.clearCalls()
            ExecuteCommand("Run Macro", { Macro = "cmdd" })
            mock.advance(50)

            local ops = lastWrittenOps()
            H.count(ops, 1, "the one replayable operation still runs")
            H.isTrue(loggedContaining("ran 1 of 5 stored entries"),
                "the installer is told how much of the macro did not run")
            H.isTrue(loggedContaining("ErrorLog:"),
                "reported at the one level this logger always writes")
        end,
    },
    {
        name = "an empty macro sends nothing and says why",
        fn = function()
            -- An empty changemso would encode as {} rather than [] and the unit
            -- rejects it, so there is nothing safe to send.
            loadDriver({ ["Debug Mode"] = "On" })
            goLive()
            mock.clearCalls()
            ExecuteCommand("Run Macro", { Macro = "Late Night" })   -- cmdc, named but empty
            mock.advance(50)
            H.equal(changeMsoCount(), 0, "nothing at all should have been sent")
            H.equal(lastWrittenOps(), nil)
            H.isTrue(loggedContaining("has no stored operations"),
                "the refusal should be explained, not silent")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "a macro name that matches nothing sends nothing and says why",
        fn = function()
            loadDriver({ ["Debug Mode"] = "On" })
            goLive()
            mock.clearCalls()
            ExecuteCommand("Run Macro", { Macro = "Nothing By That Name" })
            mock.advance(50)
            H.equal(changeMsoCount(), 0, "an unknown name should have sent nothing")
            H.isTrue(loggedContaining("no macro named"), "and should have been explained")

            -- An empty request and the "(none)" entry are a DIFFERENT case from
            -- a name that matched nothing: nothing was asked for, rather than
            -- something being asked for and missing. Saying "no macro named"
            -- there would send an installer looking for a macro they never
            -- named, so the two are worded apart.
            for _, request in ipairs({ "", "(none)" }) do
                mock.clearCalls()
                ExecuteCommand("Run Macro", { Macro = request })
                mock.advance(50)
                H.equal(changeMsoCount(), 0, "'" .. request .. "' should have sent nothing")
                H.isTrue(loggedContaining("no macro was given"),
                    "'" .. request .. "' is a command parameter, not a selection")
            end

            -- The action reads the property instead, so its wording differs.
            -- "" as well as the sentinel: an install that upgrades from an
            -- earlier version carries Composer's stored empty value across.
            for _, selection in ipairs({ "(none)", "" }) do
                mock.clearCalls()
                Properties["Macro"] = selection
                ExecuteCommand("LUA_ACTION", { ACTION = "RUN_SELECTED_MACRO" })
                mock.advance(50)
                H.equal(changeMsoCount(), 0, "'" .. selection .. "' should have sent nothing")
                H.isTrue(loggedContaining("no macro is selected"),
                    "'" .. selection .. "' should have said nothing was selected")
            end
            H.assertNoErrorLog()
        end,
    },
    {
        name = "selecting a macro in Composer selects it and does not run it",
        fn = function()
            -- The reason this list needs no feedback-loop guard of its own: a
            -- selection, whether the installer's or Composer echoing the
            -- driver's own UpdatePropertyList back, never reaches the unit.
            loadDriver()
            goLive()
            mock.clearCalls()
            Properties["Macro"] = "Preset 1"
            OnPropertyChanged("Macro")
            mock.advance(50)
            H.equal(lastWrittenOps(), nil, "running one is the action's job, not the property's")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "a macro renamed on the unit repopulates the list and keeps the selection",
        fn = function()
            loadDriver()
            goLive()
            Properties["Macro"] = "Preset 1"   -- the installer's own choice
            mock.clearCalls()
            pushUpdate("/svronly/macroNames/cmdb", "Evening")
            mock.advance(50)

            local last = lastPropertyList("Macro")
            H.isTrue(last ~= nil, "the unit's rename should reach Composer")
            H.equal(last.args[2], "(none),Movie Night,Evening,cmdd,Preset 1,cmdcustom1")
            H.equal(last.args[3], "Preset 1",
                "the installer's selection survives a repopulation")
            H.equal(lastWrittenOps(), nil, "a push must never turn into a write")
            H.assertNoErrorLog()
        end,
    },
    {
        name = "a macro deleted on the unit leaves the list and stops running",
        fn = function()
            -- A re-read is a complete document, so a slot it no longer carries
            -- is a slot the owner deleted. Leaving it runnable would put the
            -- owner's old operations on the wire long after they removed them.
            loadDriver()
            goLive()
            Properties["Macro"] = "Movie Night"   -- the installer's own choice, cmda
            local F = require("tests.fixtures")
            local doc = F.modern()
            doc.svronly.cmda = nil
            doc.svronly.macroNames.cmda = nil

            mock.clearCalls()
            sendFrame("mso " .. JSON:encode(doc))
            local last = lastPropertyList("Macro")
            H.isTrue(last ~= nil, "the picker has to lose the entry")
            H.equal(last.args[2], "(none),Listening,cmdd,Preset 1,cmdcustom1")
            H.equal(last.args[3], "(none)",
                "the selection must fall to nothing, NEVER to whichever macro now happens " ..
                "to be first -- an action that quietly starts running a different macro is " ..
                "worse than one that runs nothing")

            mock.clearCalls()
            ExecuteCommand("Run Macro", { Macro = "Movie Night" })
            mock.advance(50)
            H.equal(changeMsoCount(), 0, "a deleted macro must not still reach the unit")
            H.equal(lastWrittenOps(), nil)
            H.assertNoErrorLog()
        end,
    },
    {
        name = "a macro stored on the unit after connecting appears in the list",
        fn = function()
            loadDriver()
            goLive()
            mock.clearCalls()
            sendFrame("msoupdate " .. JSON:encode({
                { op = "replace", path = "/svronly/cmdc",
                  value = { { op = "replace", path = "/loudness", value = "on" } } },
            }))
            local last = lastPropertyList("Macro")
            H.isTrue(last ~= nil, "gaining operations puts a named slot into the list")
            H.equal(last.args[2],
                "(none),Movie Night,Listening,Late Night,cmdd,Preset 1,cmdcustom1")

            mock.clearCalls()
            ExecuteCommand("Run Macro", { Macro = "Late Night" })
            mock.advance(50)
            local ops = lastWrittenOps()
            H.count(ops, 1, "and it runs what the unit now stores there")
            H.equal(ops[1].path, "/loudness")
            H.equal(ops[1].value, "on")
            H.assertNoErrorLog()
        end,
    },
}

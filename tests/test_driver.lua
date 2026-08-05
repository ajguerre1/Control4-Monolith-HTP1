-- driver.lua is wiring, so these tests check the wiring: that Control4's entry
-- points reach the right object, that properties take effect, and that a fault
-- in a handler is logged rather than swallowed.

local H = require("tests.harness")
local mock = H.mock
local Mapping = require("htp1.mapping")
local JSON = require("module.json")

local DEFAULTS = {
    ["Driver Version"] = "", ["Model"] = "HTP-1",
    ["System Software Version"] = "", ["AV Controller Version"] = "",
    ["Serial Number"] = "", ["Connection Status"] = "Not connected",
    ["Maximum Volume"] = "Unit maximum", ["Volume Ramp Rate"] = "100 ms",
    ["Power Off Action"] = "Standby",
    ["Debug Mode"] = "Off",
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
}

local function callsNamed(name)
    local found = {}
    for _, c in ipairs(mock.calls) do
        if c.name == name then table.insert(found, c) end
    end
    return found
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
        name = "Print Input Labels reports one line per input the unit sent -- mapped inputs in " ..
               "Mapping.INPUTS order, then unmapped ones (Roon) sorted by key",
        fn = function()
            loadDriver()
            goLive()   -- F.modern()'s inputs: h1, h2, h3, a1, optical1 (mapped), roon (not)
            mock.clearCalls()
            ExecuteCommand("PRINT_INPUT_LABELS", {})

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
            ExecuteCommand("PRINT_INPUT_LABELS", {})
            local first = {}
            for i, line in ipairs(mock.printed) do first[i] = line end

            mock.clearCalls()
            ExecuteCommand("PRINT_INPUT_LABELS", {})
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
        name = "every one of the seventeen variables exists after init, created as STRING",
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
            H.equal(#VARIABLE_NAMES, 17, "the brief calls for seventeen variables")

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
}

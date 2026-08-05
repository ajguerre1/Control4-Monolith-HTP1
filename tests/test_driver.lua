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
    ["Power Off Action"] = "Standby", ["Adopt Input Labels"] = "Yes",
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
}

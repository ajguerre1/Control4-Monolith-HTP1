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
            -- 80 %, not 50 %: the fixture already sits at -25 dB, which is what
            -- 50 % of -50..0 maps to, so that level would exercise the
            -- already-there path instead of the mapping this test is named for.
            local proxy, _, transport = build()
            proxy:handle(BINDING, "SET_VOLUME_LEVEL", { LEVEL = "80", OUTPUT = tostring(OUTPUT) })
            mock.advance(50)
            local ops = lastOps(transport)
            H.equal(ops[1].path, "/volume")
            H.equal(ops[1].value, -10, "80 % of -50..0 dB")
        end,
    },
    {
        name = "setting the level the unit already holds notifies but does not write",
        fn = function()
            local proxy, _, transport, state = build()
            H.equal(state.fields.volume, -25)
            mock.clearCalls()
            proxy:handle(BINDING, "SET_VOLUME_LEVEL", { LEVEL = "50" })
            mock.advance(50)
            H.equal(lastOps(transport), nil, "no command for a value already held")
            H.isTrue(mock.lastProxyCall(BINDING, "VOLUME_LEVEL_CHANGED") ~= nil,
                "the room is still told the truth, since percent maps to dB lossily")
        end,
    },
    {
        name = "a ramp held at the end of the range stops notifying too",
        fn = function()
            local proxy, _, _, state = build({ rampMs = 100 })
            proxy:handle(BINDING, "START_VOL_DOWN", {})
            mock.advance(10000)
            proxy:handle(BINDING, "STOP_VOL_DOWN", {})
            H.equal(state.fields.volume, -50)

            mock.clearCalls()
            proxy:handle(BINDING, "START_VOL_DOWN", {})
            mock.advance(10000)
            proxy:handle(BINDING, "STOP_VOL_DOWN", {})
            H.count(mock.proxyCalls(BINDING, "VOLUME_LEVEL_CHANGED"), 0,
                "restating an unchanged level tells the room nothing it does not know")
        end,
    },
    {
        name = "announce restates the level even when nothing moved",
        fn = function()
            local proxy = build()
            proxy:announce()
            mock.clearCalls()
            proxy:announce()
            H.isTrue(mock.lastProxyCall(BINDING, "VOLUME_LEVEL_CHANGED") ~= nil,
                "an announce follows a connect or binding change, where the room's "
                .. "idea of the level cannot be assumed")
        end,
    },
    {
        name = "a ramp held at the end of the range stops writing",
        fn = function()
            -- Without the already-there guard this rewrites the same dB for as
            -- long as the button is held -- exactly the noise the design forbids.
            local proxy, _, transport, state = build({ rampMs = 100 })
            proxy:handle(BINDING, "START_VOL_DOWN", {})
            mock.advance(10000)
            proxy:handle(BINDING, "STOP_VOL_DOWN", {})
            mock.advance(50)
            H.equal(state.fields.volume, -50, "clamped at the bottom")

            local before = #transport.sent
            proxy:handle(BINDING, "START_VOL_DOWN", {})
            mock.advance(10000)
            proxy:handle(BINDING, "STOP_VOL_DOWN", {})
            mock.advance(50)
            H.equal(#transport.sent, before, "a ramp against the stop sends nothing at all")
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
            H.equal(volume.args[3].LEVEL, "50", "-25 dB of -50..0 is 50 %, sent as a string")
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
            H.equal(volume.args[3].LEVEL, "80", "-10 dB of -50..0, sent as a string")
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
        name = "every notification parameter is stringified, not just OUTPUT",
        fn = function()
            -- Director serialises tParams for the proxy, and the real proxy is
            -- not as forgiving of a raw boolean or number as this test mock is.
            -- _notify used to tostring() only OUTPUT; MUTE, AUDIO, VIDEO and
            -- LEVEL went out as a boolean, booleans and a number respectively.
            local proxy = build()
            mock.clearCalls()
            proxy:announce()

            local mute = mock.lastProxyCall(BINDING, "MUTE_CHANGED")
            H.equal(type(mute.args[3].MUTE), "string", "MUTE must be a string, not a boolean")
            H.equal(mute.args[3].MUTE, "false")

            local input = mock.lastProxyCall(BINDING, "INPUT_OUTPUT_CHANGED")
            H.equal(type(input.args[3].AUDIO), "string", "AUDIO must be a string, not a boolean")
            H.equal(input.args[3].AUDIO, "true")
            H.equal(type(input.args[3].VIDEO), "string", "VIDEO must be a string, not a boolean")

            local volume = mock.lastProxyCall(BINDING, "VOLUME_LEVEL_CHANGED")
            H.equal(type(volume.args[3].LEVEL), "string", "LEVEL must be a string, not a number")
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

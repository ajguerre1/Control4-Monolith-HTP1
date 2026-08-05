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

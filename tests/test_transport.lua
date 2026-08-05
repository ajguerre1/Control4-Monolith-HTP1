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

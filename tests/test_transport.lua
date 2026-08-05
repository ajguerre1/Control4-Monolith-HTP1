local H = require("tests.harness")
local mock = H.mock
local Transport = require("htp1.transport")
local Log = require("htp1.log")
local Frame = require("htp1.frame")

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
        name = "a handshake response that never terminates is cut off, not buffered",
        fn = function()
            local t, events = build()
            t:connect()
            t:onConnectionStatus("ONLINE")
            for _ = 1, 10 do t:onData(string.rep("x", 1024)) end
            H.equal(t.state, "closed", "an endless response must not grow the buffer forever")
            H.isTrue(events.closed[1]:find("exceeded", 1, true) ~= nil,
                "the reason should name the cap: " .. tostring(events.closed[1]))
        end,
    },
    {
        name = "a header that merely contains the upgrade text is not accepted",
        fn = function()
            local t, events = build()
            t:connect()
            t:onConnectionStatus("ONLINE")
            t:onData("HTTP/1.1 101 Switching Protocols\r\n" ..
                "X-Original-Upgrade: websocket\r\nUpgrade: websocketZZZ\r\n\r\n")
            H.equal(t.state, "closed", "neither line is a real Upgrade: websocket header")
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
}

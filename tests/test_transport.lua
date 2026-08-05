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
            -- Each rung leaves the auto-reconnect sitting unanswered in
            -- "connecting" for up to 60000 ms, which the connect watchdog
            -- (15000 ms default) would otherwise also trip on -- a real effect,
            -- but not what this test is isolating. A generous override keeps
            -- the ladder itself under test; the watchdog has its own tests.
            local delays = {}
            local t = build({
                jitter = function(ms) table.insert(delays, ms) return ms end,
                connectTimeoutMs = 10000000,
            })
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
            -- See the ladder test above for why the watchdog is pushed out of
            -- range here too.
            local delays = {}
            local t = build({
                jitter = function(ms) table.insert(delays, ms) return ms end,
                connectTimeoutMs = 10000000,
            })
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
    {
        name = "a close cancels a reconnect that was already armed",
        fn = function()
            -- The close-from-open case above can never exercise the
            -- cancellation, because no timer is pending there. Only a close
            -- that follows an unexpected drop does.
            local t = build({ jitter = function(ms) return ms end })
            t:connect()
            t:onConnectionStatus("OFFLINE")     -- arms the reconnect
            mock.clearCalls()
            t:close()
            mock.advance(120000)
            for _, c in ipairs(mock.calls) do
                H.isTrue(c.name ~= "NetConnect",
                    "an armed reconnect must not survive a deliberate close")
            end
        end,
    },
    {
        name = "reconnection resumes after a deliberate close and a fresh connect",
        fn = function()
            -- Pins that connect() clears the deliberate flag. Without it the
            -- driver would never reconnect again after one manual close -- a
            -- silent permanent failure, the worst outcome for this driver.
            local t = build({ jitter = function(ms) return ms end })
            t:connect(); t:onConnectionStatus("ONLINE"); t:onData(ACCEPT)
            t:close()
            t:connect(); t:onConnectionStatus("ONLINE"); t:onData(ACCEPT)
            H.equal(t.state, "open", "the fresh connect should have opened")
            mock.clearCalls()
            t:onConnectionStatus("OFFLINE")     -- an unexpected drop this time
            mock.advance(2000)
            local reconnects = 0
            for _, c in ipairs(mock.calls) do
                if c.name == "NetConnect" then reconnects = reconnects + 1 end
            end
            H.equal(reconnects, 1, "an unexpected drop after a manual close must still recover")
        end,
    },
    {
        name = "a manual connect cancels a pending reconnect rather than racing it",
        fn = function()
            local t = build({ jitter = function(ms) return ms end })
            t:connect()
            t:onConnectionStatus("OFFLINE")     -- arms a 2000 ms reconnect
            mock.clearCalls()
            t:connect()                          -- manual attempt gets in first
            t:onConnectionStatus("ONLINE"); t:onData(ACCEPT)
            H.equal(t.state, "open")
            -- Past the 2000 ms the stale timer was armed for, but short of the
            -- 30 s keepalive ping, whose pong nothing answers in this test.
            mock.advance(5000)
            H.equal(t.state, "open", "a stale timer must not stomp a live connection")
            local reconnects = 0
            for _, c in ipairs(mock.calls) do
                if c.name == "NetConnect" then reconnects = reconnects + 1 end
            end
            H.equal(reconnects, 1, "exactly one connect attempt, not two")
        end,
    },
    {
        name = "a reconnect armed from inside onClose is not doubled",
        fn = function()
            -- _shutdown hands control to onClose before scheduling. A driver
            -- that reconnects from that callback must not also get a timer.
            local reconnecting
            local t = build({
                jitter = function(ms) return ms end,
                onClose = function() if reconnecting then reconnecting() end end,
            })
            reconnecting = function() t:connect() end
            t:connect()
            mock.clearCalls()
            t:onConnectionStatus("OFFLINE")
            H.equal(t.state, "connecting", "onClose reconnected immediately")
            -- Short of the connect watchdog (15000 ms default): this test is
            -- about the old backoff-timer path only. The watchdog's own retry
            -- behaviour, over a longer horizon, has its own tests below.
            mock.advance(5000)
            local reconnects = 0
            for _, c in ipairs(mock.calls) do
                if c.name == "NetConnect" then reconnects = reconnects + 1 end
            end
            H.equal(reconnects, 1, "no dangling backoff timer on top of the manual attempt")
        end,
    },
    {
        name = "the connect watchdog trips if online never arrives",
        fn = function()
            local t, events = build()
            t:connect()
            H.equal(t.state, "connecting")
            mock.advance(14999)
            H.equal(t.state, "connecting", "not yet")
            mock.advance(1)
            H.equal(t.state, "closed", "a socket that never confirms ONLINE must not wedge forever")
            H.isTrue(events.closed[1]:find("timed out", 1, true) ~= nil,
                "the reason should name the timeout: " .. tostring(events.closed[1]))
        end,
    },
    {
        name = "the connect watchdog also covers a stalled handshake",
        fn = function()
            -- The exact scenario from the field: TCP accepts and Director
            -- reports ONLINE, but the unit's /ws/controller route is not live
            -- yet, so the 101 never arrives.
            local t, events = build()
            t:connect()
            t:onConnectionStatus("ONLINE")
            H.equal(t.state, "handshaking")
            mock.advance(15000)
            H.equal(t.state, "closed")
            H.isTrue(events.closed[1]:find("timed out after 15000 ms", 1, true) ~= nil,
                tostring(events.closed[1]))
        end,
    },
    {
        name = "a clean open cancels the watchdog so it cannot fire on a healthy connection",
        fn = function()
            local t, events = build()
            t:connect()
            t:onConnectionStatus("ONLINE")
            t:onData(ACCEPT)
            H.equal(t.state, "open")
            mock.advance(20000)
            H.equal(t.state, "open", "the watchdog must not fire after a clean open")
            H.count(events.closed, 0)
        end,
    },
    {
        name = "connectTimeoutMs is configurable",
        fn = function()
            local t, events = build({ connectTimeoutMs = 5000 })
            t:connect()
            mock.advance(4999)
            H.equal(t.state, "connecting")
            mock.advance(1)
            H.equal(t.state, "closed")
            H.isTrue(events.closed[1]:find("5000", 1, true) ~= nil,
                "the reason should quote the configured timeout: " .. tostring(events.closed[1]))
        end,
    },
    {
        name = "a watchdog trip still recovers through the normal backoff ladder",
        fn = function()
            local t = build({ jitter = function(ms) return ms end })
            t:connect()
            t:onConnectionStatus("ONLINE")
            mock.clearCalls()
            mock.advance(15000)   -- watchdog trips, first backoff rung armed
            local connects = 0
            for _, c in ipairs(mock.calls) do
                if c.name == "NetConnect" then connects = connects + 1 end
            end
            H.equal(connects, 0, "not yet -- the backoff delay has not elapsed")
            mock.advance(2000)
            connects = 0
            for _, c in ipairs(mock.calls) do
                if c.name == "NetConnect" then connects = connects + 1 end
            end
            H.equal(connects, 1, "the standard ladder recovers from a watchdog trip")
        end,
    },
    {
        name = "closing before the watchdog fires does not leave it armed for the next attempt",
        fn = function()
            -- Proves the watchdog cannot leak across reconnects: if _shutdown
            -- failed to cancel it, this stale timer would fire mid-way through
            -- the second, successful connection and kill it wrongly.
            local t, events = build()
            t:connect()
            t:onConnectionStatus("ONLINE")   -- handshaking, watchdog armed
            t:close()                         -- legitimately produces one close event
            t:connect()
            t:onConnectionStatus("ONLINE")
            t:onData(ACCEPT)
            H.equal(t.state, "open")
            local closedBefore = #events.closed
            mock.advance(20000)   -- past the first attempt's 15000 ms deadline
            H.equal(t.state, "open", "a leaked watchdog from the earlier attempt must not fire")
            H.count(events.closed, closedBefore)
        end,
    },
    {
        name = "a hostProvider is re-read on every connect rather than cached at construction",
        fn = function()
            local host = ""
            local t = build({ hostProvider = function() return host end })
            t:connect()
            H.equal(t.state, "closed", "no address configured yet")
            H.count(mock.sent, 0)

            host = "unit.invalid"
            mock.clearCalls()
            t:connect()
            H.equal(t.state, "connecting", "the freshly read address is used")
            local connects = 0
            for _, c in ipairs(mock.calls) do
                if c.name == "NetConnect" then connects = connects + 1 end
            end
            H.equal(connects, 1)
        end,
    },
    {
        name = "connecting with no host attempts nothing but still schedules a retry",
        fn = function()
            local host = ""
            local t = build({
                hostProvider = function() return host end,
                jitter = function(ms) return ms end,
            })
            t:connect()
            H.equal(t.state, "closed")
            H.count(mock.sent, 0)
            local connects = 0
            for _, c in ipairs(mock.calls) do
                if c.name == "NetConnect" then connects = connects + 1 end
            end
            H.equal(connects, 0, "no attempt without an address")

            mock.clearCalls()
            host = "unit.invalid"
            mock.advance(2000)   -- the first backoff rung
            connects = 0
            for _, c in ipairs(mock.calls) do
                if c.name == "NetConnect" then connects = connects + 1 end
            end
            H.equal(connects, 1, "a later address should be picked up by the scheduled retry")
        end,
    },
    {
        name = "the default random byte source never emits a NUL",
        fn = function()
            -- With the pre-fix math.random(0, 255), a 16-byte handshake key had
            -- about a 6 % chance per call of an embedded NUL. Over 5000 bytes the
            -- old range would almost certainly produce at least one; this range
            -- (1..255) cannot produce one at all.
            mock.install({})
            local t = Transport.new({
                binding = 6001, port = 80, host = "unit.invalid",
                path = "/ws/controller", log = Log.new("test"),
            })
            local bytes = t.randomBytes(5000)
            H.equal(#bytes, 5000)
            for i = 1, #bytes do
                H.isTrue(bytes:byte(i) ~= 0,
                    "byte " .. i .. " was NUL: Base64Encode could truncate the key")
            end
        end,
    },
}

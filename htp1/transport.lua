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

-- Generous for a real 101 response, which runs to a few hundred bytes.
local MAX_HANDSHAKE_BYTES = 8192

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
        pingIntervalMs = opts.pingIntervalMs or 30000,
        pongTimeoutMs  = opts.pongTimeoutMs or 10000,
        backoffMs      = opts.backoffMs or { 2000, 4000, 8000, 16000, 30000, 60000 },
        jitter         = opts.jitter or function(ms)
            -- +/-20 %. Two instances on one controller must not reconnect in
            -- lockstep after every network blip.
            return math.floor(ms * (0.8 + math.random() * 0.4))
        end,
        backoffStep    = 0,
        deliberate     = false,
        pingTimer      = nil,
        pongTimer      = nil,
        reconnectTimer = nil,
    }, Transport)
    return t
end

function Transport:connect()
    if self.state == "connecting" or self.state == "handshaking" or self.state == "open" then
        return
    end
    -- A reconnect may already be armed. Leaving it running lets the timer race
    -- this attempt: its callback forces the state back to idle and reconnects
    -- on top of a connection that may by then be live.
    if self.reconnectTimer then
        self.reconnectTimer:Cancel()
        self.reconnectTimer = nil
    end
    self.rxBuf, self.reader = "", nil
    self.deliberate = false
    self.state = "connecting"
    self.log:debug("connecting to", self.host)
    C4:NetConnect(self.binding, self.port)
end

function Transport:_shutdown(reason)
    if self.state == "closed" or self.state == "idle" then return end
    self.state = "closed"
    self.rxBuf, self.reader = "", nil
    self:_stopKeepalive()
    C4:NetDisconnect(self.binding, self.port)
    self.log:debug("closed:", reason)
    self.onClose(reason)
    self:_scheduleReconnect()
end

function Transport:close()
    self.deliberate = true
    if self.reconnectTimer then
        self.reconnectTimer:Cancel()
        self.reconnectTimer = nil
    end
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

-- Exact header match. A plain substring search over the whole block would also
-- accept "X-Original-Upgrade: websocket" or "Upgrade: websocketZZZ", so it could
-- not actually tell us we reached a websocket endpoint -- which is the one thing
-- this handshake check exists to establish.
local function hasHeader(head, name, value)
    for line in (head .. "\r\n"):gmatch("(.-)\r\n") do
        local key, val = line:match("^([^:]+):%s*(.-)%s*$")
        if key and key:lower() == name and val:lower() == value then
            return true
        end
    end
    return false
end

function Transport:_completeHandshake(head)
    local status = head:match("^HTTP/1%.1 (%d+)")
    if status ~= "101" then
        return self:_shutdown("handshake rejected with status " .. tostring(status or "?"))
    end
    if not hasHeader(head, "upgrade", "websocket") then
        return self:_shutdown("handshake response is not a websocket upgrade")
    end

    self.state = "open"
    self.reader = Frame.newReader()
    self.backoffStep = 0
    self:_startKeepalive()
    self.log:debug("websocket open")
    self.onOpen()
    return true
end

function Transport:onData(data)
    if self.state == "handshaking" then
        self.rxBuf = self.rxBuf .. data
        -- A peer that never sends the terminator would otherwise grow this
        -- buffer without bound, on a controller shared with every other driver
        -- in the project. Real response headers are a few hundred bytes.
        if #self.rxBuf > MAX_HANDSHAKE_BYTES then
            return self:_shutdown("handshake response exceeded "
                .. MAX_HANDSHAKE_BYTES .. " bytes without completing")
        end
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
    -- _shutdown hands control to the driver's onClose before reaching here. If
    -- that callback reconnected, arming a timer now would leave one dangling
    -- over a live connection.
    if self.state ~= "closed" then return end

    self.backoffStep = math.min(self.backoffStep + 1, #self.backoffMs)
    -- A caller-supplied jitter is not trusted to stay positive; the timer API
    -- rejects a non-positive interval.
    local delay = math.max(1, tonumber(self.jitter(self.backoffMs[self.backoffStep])) or 1)
    self.log:debug("reconnecting in", delay, "ms")
    self.reconnectTimer = C4:SetTimer(delay, function()
        self.reconnectTimer = nil
        -- Anything other than closed means a connect happened while this was
        -- armed, so there is nothing to resume.
        if self.state ~= "closed" then return end
        self.state = "idle"
        self:connect()
    end, false)
end

return Transport

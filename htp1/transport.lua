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

-- Frame handling arrives in the next task; declared here so onData has a target.
function Transport:_consume(_) end

return Transport

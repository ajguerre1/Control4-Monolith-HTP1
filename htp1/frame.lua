-- RFC 6455 frame codec.
--
-- No Control4 API and no `bit` library: LuaJIT provides `bit`, DriverWorks does
-- not document it, so masking is arithmetic and one implementation runs in both.
-- The cost falls only on outbound frames, which are small -- inbound frames from
-- the unit are unmasked and are never XORed.

local Frame = {}

Frame.OP = { CONT = 0x0, TEXT = 0x1, BINARY = 0x2, CLOSE = 0x8, PING = 0x9, PONG = 0xA }

-- Frames larger than this are rejected rather than buffered. The largest real
-- message is the ~38 KB mso document; anything near a megabyte is a fault.
Frame.MAX_PAYLOAD = 1048576

local byte, char, sub, concat = string.byte, string.char, string.sub, table.concat

local function bxorByte(a, b)
    local result, place = 0, 1
    for _ = 1, 8 do
        local abit, bbit = a % 2, b % 2
        if abit ~= bbit then result = result + place end
        a, b, place = (a - abit) / 2, (b - bbit) / 2, place * 2
    end
    return result
end

-- Masking is symmetric, so this both masks and unmasks.
function Frame.applyMask(payload, key)
    if #payload == 0 then return payload end
    local k1, k2, k3, k4 = byte(key, 1, 4)
    local k = { k1, k2, k3, k4 }
    local out = {}
    for i = 1, #payload do
        out[i] = char(bxorByte(byte(payload, i), k[((i - 1) % 4) + 1]))
    end
    return concat(out)
end

-- This codec never fragments outbound messages, so FIN is always set.
function Frame.encode(opcode, payload, maskKey)
    payload = payload or ""
    if type(maskKey) ~= "string" or #maskKey ~= 4 then
        error("client frames require a four-byte mask key", 2)
    end

    local header = char(0x80 + opcode)
    local length = #payload

    if length < 126 then
        header = header .. char(0x80 + length)
    elseif length < 65536 then
        header = header .. char(0x80 + 126)
            .. char(math.floor(length / 256), length % 256)
    else
        header = header .. char(0x80 + 127) .. char(0, 0, 0, 0)
            .. char(math.floor(length / 16777216) % 256,
                    math.floor(length / 65536) % 256,
                    math.floor(length / 256) % 256,
                    length % 256)
    end

    return header .. maskKey .. Frame.applyMask(payload, maskKey)
end

-- Returns (frame, consumed) on success, (nil, 0) when more bytes are needed,
-- and (nil, -1, err) on a protocol violation the caller must not recover from.
function Frame.decode(buf)
    if #buf < 2 then return nil, 0 end

    local b1, b2 = byte(buf, 1), byte(buf, 2)
    local fin    = b1 >= 128
    local opcode = b1 % 16
    local masked = b2 >= 128
    local length = b2 % 128
    local offset = 2

    if length == 126 then
        if #buf < 4 then return nil, 0 end
        length = byte(buf, 3) * 256 + byte(buf, 4)
        offset = 4
    elseif length == 127 then
        if #buf < 10 then return nil, 0 end
        length = 0
        for i = 3, 10 do length = length * 256 + byte(buf, i) end
        offset = 10
    end

    if length > Frame.MAX_PAYLOAD then
        return nil, -1, "frame payload of " .. length .. " bytes exceeds the cap"
    end
    if masked then
        return nil, -1, "server frame is masked, which RFC 6455 forbids"
    end
    if #buf < offset + length then return nil, 0 end

    return { fin = fin, opcode = opcode, payload = sub(buf, offset + 1, offset + length) },
        offset + length
end

local Reader = {}
Reader.__index = Reader

function Frame.newReader()
    return setmetatable({ buf = "", fragment = nil, fragmentOp = nil }, Reader)
end

function Reader:push(chunk)
    self.buf = self.buf .. chunk
end

-- Returns a whole message, or nil when more bytes are needed, or (nil, err).
function Reader:next()
    while true do
        local frame, consumed, err = Frame.decode(self.buf)
        if err then return nil, err end
        if not frame then return nil end
        self.buf = sub(self.buf, consumed + 1)

        if frame.opcode >= 0x8 then
            -- Control frames are never fragmented and may arrive between the
            -- fragments of a data message, so they bypass the fragment state.
            return { opcode = frame.opcode, payload = frame.payload }
        end

        if frame.opcode == Frame.OP.CONT then
            if not self.fragment then
                return nil, "continuation frame with nothing to continue"
            end
            self.fragment = self.fragment .. frame.payload
        else
            if self.fragment then
                return nil, "new data frame while a fragmented message is open"
            end
            self.fragment, self.fragmentOp = frame.payload, frame.opcode
        end

        if frame.fin then
            local message = { opcode = self.fragmentOp, payload = self.fragment }
            self.fragment, self.fragmentOp = nil, nil
            return message
        end
    end
end

return Frame

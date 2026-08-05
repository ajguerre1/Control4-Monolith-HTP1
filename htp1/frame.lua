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

return Frame

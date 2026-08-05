local H = require("tests.harness")
local Frame = require("htp1.frame")

local KEY = "\1\2\3\4"

return {
    {
        name = "masking is its own inverse",
        fn = function()
            local plain = "getmso"
            local masked = Frame.applyMask(plain, KEY)
            H.isTrue(masked ~= plain, "masking should change the bytes")
            H.equal(Frame.applyMask(masked, KEY), plain, "unmasking should restore")
        end,
    },
    {
        name = "masking an empty payload yields an empty payload",
        fn = function()
            H.equal(Frame.applyMask("", KEY), "")
        end,
    },
    {
        name = "a masked frame matches the worked example in RFC 6455 section 5.7",
        fn = function()
            -- The RFC publishes this exact frame for the text "Hello" masked with
            -- key 0x37 0xfa 0x21 0x3d. It is an external oracle: the round-trip
            -- tests above cannot catch an off-by-one in the key cycling, because
            -- XOR is self-inverse under any consistent scheme. This can -- note
            -- that the fifth payload byte must wrap back to the first key byte.
            local key = string.char(0x37, 0xFA, 0x21, 0x3D)
            local expected = string.char(0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D,
                                         0x7F, 0x9F, 0x4D, 0x51, 0x58)
            H.equal(Frame.encode(Frame.OP.TEXT, "Hello", key), expected,
                "encoded frame differs from the RFC's published bytes")
        end,
    },
    {
        name = "a short text frame sets FIN, the opcode, the mask bit and the length",
        fn = function()
            local f = Frame.encode(Frame.OP.TEXT, "getmso", KEY)
            H.equal(f:byte(1), 0x81, "FIN set with the TEXT opcode")
            H.equal(f:byte(2), 0x80 + 6, "mask bit set with a 6-byte length")
            H.equal(f:sub(3, 6), KEY, "the mask key follows the header")
            H.equal(Frame.applyMask(f:sub(7), KEY), "getmso", "payload is masked")
            H.equal(#f, 2 + 4 + 6)
        end,
    },
    {
        name = "a 126-byte payload switches to the 16-bit length form",
        fn = function()
            local f = Frame.encode(Frame.OP.TEXT, string.rep("x", 126), KEY)
            H.equal(f:byte(2), 0x80 + 126, "length marker for the extended form")
            H.equal(f:byte(3), 0, "high byte of 126")
            H.equal(f:byte(4), 126, "low byte of 126")
            H.equal(#f, 2 + 2 + 4 + 126)
        end,
    },
    {
        name = "a 65536-byte payload switches to the 64-bit length form",
        fn = function()
            local f = Frame.encode(Frame.OP.TEXT, string.rep("x", 65536), KEY)
            H.equal(f:byte(2), 0x80 + 127, "length marker for the 64-bit form")
            for i = 3, 7 do H.equal(f:byte(i), 0, "leading length byte " .. i) end
            H.equal(f:byte(8), 1, "0x010000 high byte")
            H.equal(f:byte(9), 0)
            H.equal(f:byte(10), 0)
            H.equal(#f, 2 + 8 + 4 + 65536)
        end,
    },
    {
        name = "a ping frame carries no payload but is still masked",
        fn = function()
            local f = Frame.encode(Frame.OP.PING, "", KEY)
            H.equal(f:byte(1), 0x89, "FIN set with the PING opcode")
            H.equal(f:byte(2), 0x80, "mask bit set with a zero length")
            H.equal(#f, 2 + 4)
        end,
    },
    {
        name = "encoding without a four-byte mask key is refused",
        fn = function()
            H.errorMatches(function() Frame.encode(Frame.OP.TEXT, "x", "abc") end,
                "four-byte mask key")
        end,
    },
    {
        name = "decode consumes nothing while the header is short",
        fn = function()
            local f, consumed = Frame.decode("\129")
            H.equal(f, nil)
            H.equal(consumed, 0)
        end,
    },
    {
        name = "decode consumes nothing while the payload is incomplete",
        fn = function()
            local f, consumed = Frame.decode("\129\6get")
            H.equal(f, nil)
            H.equal(consumed, 0)
        end,
    },
    {
        name = "decode reads an unmasked short text frame",
        fn = function()
            local f, consumed = Frame.decode("\129\4mso ")
            H.isTrue(f ~= nil, "frame should decode")
            H.isTrue(f.fin, "FIN should be set")
            H.equal(f.opcode, Frame.OP.TEXT)
            H.equal(f.payload, "mso ")
            H.equal(consumed, 6)
        end,
    },
    {
        name = "decode reads the 16-bit length form",
        fn = function()
            local raw = "\129\126" .. string.char(1, 44) .. string.rep("y", 300)
            local f, consumed = Frame.decode(raw)
            H.equal(#f.payload, 300)
            H.equal(consumed, 4 + 300)
        end,
    },
    {
        name = "decode reads the 64-bit length form",
        fn = function()
            local raw = "\129\127" .. string.char(0, 0, 0, 0, 0, 1, 17, 112) .. string.rep("z", 70000)
            local f, consumed = Frame.decode(raw)
            H.equal(#f.payload, 70000)
            H.equal(consumed, 10 + 70000)
        end,
    },
    {
        name = "decode rejects a payload above the cap instead of buffering it",
        fn = function()
            local raw = "\129\127" .. string.char(0, 0, 0, 0, 255, 255, 255, 255)
            local f, consumed, err = Frame.decode(raw)
            H.equal(f, nil)
            H.equal(consumed, -1)
            H.isTrue(err:find("exceeds", 1, true) ~= nil, "error should name the cap: " .. tostring(err))
        end,
    },
    {
        name = "decode rejects a masked server frame",
        fn = function()
            local f, consumed, err = Frame.decode("\129\132\1\2\3\4abcd")
            H.equal(f, nil)
            H.equal(consumed, -1)
            H.isTrue(err:find("masked", 1, true) ~= nil, "error should say masked: " .. tostring(err))
        end,
    },
    {
        name = "the reader yields a whole message from one chunk",
        fn = function()
            local r = Frame.newReader()
            r:push("\129\4mso ")
            local m = r:next()
            H.equal(m.opcode, Frame.OP.TEXT)
            H.equal(m.payload, "mso ")
            H.equal(r:next(), nil, "no second message")
        end,
    },
    {
        name = "the reader reassembles a message split byte by byte",
        fn = function()
            local raw = "\129\11hello world"
            local r = Frame.newReader()
            for i = 1, #raw - 1 do
                r:push(raw:sub(i, i))
                H.equal(r:next(), nil, "incomplete at byte " .. i)
            end
            r:push(raw:sub(#raw))
            H.equal(r:next().payload, "hello world")
        end,
    },
    {
        name = "the reader yields several messages from a single read",
        fn = function()
            local r = Frame.newReader()
            r:push("\129\1a" .. "\129\1b" .. "\129\1c")
            H.equal(r:next().payload, "a")
            H.equal(r:next().payload, "b")
            H.equal(r:next().payload, "c")
            H.equal(r:next(), nil)
        end,
    },
    {
        name = "the reader joins continuation frames into one message",
        fn = function()
            local r = Frame.newReader()
            r:push("\1\3one")      -- TEXT, FIN clear
            H.equal(r:next(), nil, "an open fragment yields nothing yet")
            r:push("\0\3two")      -- CONT, FIN clear
            H.equal(r:next(), nil)
            r:push("\128\5three")  -- CONT, FIN set
            local m = r:next()
            H.equal(m.opcode, Frame.OP.TEXT, "the message keeps the first frame's opcode")
            H.equal(m.payload, "onetwothree")
        end,
    },
    {
        name = "a control frame passes through without disturbing an open fragment",
        fn = function()
            local r = Frame.newReader()
            r:push("\1\3one")
            H.equal(r:next(), nil)
            r:push("\137\0")       -- PING, FIN set, empty
            H.equal(r:next().opcode, Frame.OP.PING)
            r:push("\128\3two")
            H.equal(r:next().payload, "onetwo", "the fragment survived the ping")
        end,
    },
    {
        name = "a continuation with nothing to continue is a protocol error",
        fn = function()
            local r = Frame.newReader()
            r:push("\128\3one")    -- CONT with FIN, no open fragment
            local m, err = r:next()
            H.equal(m, nil)
            H.isTrue(err:find("continue", 1, true) ~= nil, "error should explain: " .. tostring(err))
        end,
    },
    {
        name = "the reader handles a 38 KB message delivered in 1 KB chunks",
        fn = function()
            local raw = "\129\127" .. string.char(0, 0, 0, 0, 0, 0, 148, 112) .. string.rep("m", 38000)
            local r = Frame.newReader()
            for i = 1, #raw, 1024 do r:push(raw:sub(i, i + 1023)) end
            local m = r:next()
            H.equal(#m.payload, 38000)
            H.equal(m.opcode, Frame.OP.TEXT)
        end,
    },
    {
        name = "a fragmented message is capped in total, not only per frame",
        fn = function()
            local saved = Frame.MAX_PAYLOAD
            Frame.MAX_PAYLOAD = 10
            local r = Frame.newReader()
            r:push("\1\6aaaaaa")            -- TEXT, FIN clear, 6 bytes
            r:next()
            r:push("\0\6bbbbbb")            -- CONT, FIN clear, 6 more: 12 > 10
            local message, err = r:next()
            Frame.MAX_PAYLOAD = saved       -- restore before asserting
            H.equal(message, nil)
            H.isTrue(err ~= nil and err:find("cap", 1, true) ~= nil,
                "error should name the cap: " .. tostring(err))
        end,
    },
    {
        name = "a reader that has errored stays errored",
        fn = function()
            local r = Frame.newReader()
            r:push("\128\3one")             -- CONT with FIN, nothing open
            local _, first = r:next()
            H.isTrue(first ~= nil, "the violation should be reported")
            r:push("\129\1a")               -- a perfectly valid frame afterwards
            local message, again = r:next()
            H.equal(message, nil, "a corrupt stream must not silently resume")
            H.equal(again, first, "the same error should keep being reported")
        end,
    },
    {
        name = "a truncated 16-bit length header consumes nothing",
        fn = function()
            local r = Frame.newReader()
            r:push("\129\126\1")            -- marker 126, only 1 of 2 length bytes
            H.equal(r:next(), nil)
            r:push(string.char(44) .. string.rep("y", 300))
            H.equal(#r:next().payload, 300, "the frame completes once the rest arrives")
        end,
    },
    {
        name = "a truncated 64-bit length header consumes nothing",
        fn = function()
            local r = Frame.newReader()
            r:push("\129\127" .. string.char(0, 0, 0, 0, 0, 0, 1))  -- 7 of 8 bytes
            H.equal(r:next(), nil)
            r:push(string.char(44) .. string.rep("z", 300))
            H.equal(#r:next().payload, 300, "the frame completes once the rest arrives")
        end,
    },
}

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
}

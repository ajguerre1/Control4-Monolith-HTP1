-- Cross-checks htp1/frame.lua against frames serialised by Python's
-- `websockets`. Regenerate with tools/gen_vectors.py after any codec change.

local H = require("tests.harness")
local Frame = require("htp1.frame")
local V = require("tests.fixtures.vectors")

local tests = {}

table.insert(tests, {
    name = "the vector file carries both directions",
    fn = function()
        H.isTrue(#V.inbound > 0, "inbound vectors")
        H.isTrue(#V.outbound > 0, "outbound vectors")
        H.equal(#V.outbound.key, 4, "a four-byte mask key")
    end,
})

table.insert(tests, {
    name = "every reference server frame decodes to the expected message",
    fn = function()
        for _, vector in ipairs(V.inbound) do
            local reader = Frame.newReader()
            reader:push(vector.raw)
            local message, err = reader:next()
            H.equal(err, nil, vector.name .. ": " .. tostring(err))
            H.isTrue(message ~= nil, vector.name .. " should decode")
            H.equal(message.opcode, vector.opcode, vector.name .. " opcode")
            H.equal(message.payload, vector.payload, vector.name .. " payload")
        end
    end,
})

table.insert(tests, {
    name = "every reference server frame decodes when delivered one byte at a time",
    fn = function()
        for _, vector in ipairs(V.inbound) do
            local reader = Frame.newReader()
            local message
            for i = 1, #vector.raw do
                reader:push(vector.raw:sub(i, i))
                message = reader:next()
                if message then break end
            end
            H.isTrue(message ~= nil, vector.name .. " should decode byte by byte")
            H.equal(message.payload, vector.payload, vector.name .. " payload")
        end
    end,
})

table.insert(tests, {
    name = "our encoder produces byte-identical client frames",
    fn = function()
        for _, vector in ipairs(V.outbound) do
            local encoded = Frame.encode(vector.opcode, vector.payload, V.outbound.key)
            H.equal(#encoded, #vector.raw, vector.name .. " length")
            H.equal(encoded, vector.raw, vector.name .. " bytes differ from the reference")
        end
    end,
})

table.insert(tests, {
    name = "several reference frames concatenated all decode in order",
    fn = function()
        local reader = Frame.newReader()
        local raw = {}
        for _, vector in ipairs(V.inbound) do table.insert(raw, vector.raw) end
        reader:push(table.concat(raw))
        for _, vector in ipairs(V.inbound) do
            local message = reader:next()
            H.isTrue(message ~= nil, vector.name .. " should decode from the stream")
            H.equal(message.payload, vector.payload, vector.name)
        end
        H.equal(reader:next(), nil, "the stream is fully consumed")
    end,
})

return tests

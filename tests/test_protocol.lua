local H = require("tests.harness")
local Protocol = require("htp1.protocol")

return {
    {
        name = "a verb with no argument parses to the verb alone",
        fn = function()
            local m = Protocol.parse("getmso")
            H.equal(m.verb, "getmso")
            H.equal(m.arg, nil)
            H.equal(m.err, nil)
        end,
    },
    {
        name = "an mso document parses into a table",
        fn = function()
            local m = Protocol.parse('mso {"volume":-25,"muted":false,"input":"h1"}')
            H.equal(m.verb, "mso")
            H.equal(m.err, nil)
            H.equal(m.arg.volume, -25)
            H.equal(m.arg.muted, false)
            H.equal(m.arg.input, "h1")
        end,
    },
    {
        name = "an msoupdate parses into an array of operations",
        fn = function()
            local m = Protocol.parse('msoupdate [{"op":"replace","path":"/volume","value":-30}]')
            H.equal(m.verb, "msoupdate")
            H.count(m.arg, 1)
            H.equal(m.arg[1].op, "replace")
            H.equal(m.arg[1].path, "/volume")
            H.equal(m.arg[1].value, -30)
        end,
    },
    {
        name = "the unit's bad-verb reply parses as a verb and a string argument",
        fn = function()
            local m = Protocol.parse('error "bad-verb"')
            H.equal(m.verb, "error")
            H.equal(m.arg, "bad-verb")
            H.equal(m.err, nil)
        end,
    },
    {
        name = "a payload containing spaces is not split further",
        fn = function()
            local m = Protocol.parse('mso {"unitname":"a b c"}')
            H.equal(m.arg.unitname, "a b c")
        end,
    },
    {
        name = "undecodable JSON reports an error instead of raising",
        fn = function()
            local m = Protocol.parse("mso {not json")
            H.equal(m.verb, "mso")
            H.equal(m.arg, nil)
            H.isTrue(m.err ~= nil, "an error should be reported")
        end,
    },
    {
        name = "an empty message reports an error instead of raising",
        fn = function()
            local m = Protocol.parse("")
            H.isTrue(m.err ~= nil, "an error should be reported")
        end,
    },
    {
        name = "a non-string message reports an error instead of raising",
        fn = function()
            local m = Protocol.parse(nil)
            H.isTrue(m.err ~= nil, "an error should be reported")
        end,
    },
    {
        name = "op builds a single patch operation",
        fn = function()
            local o = Protocol.op("replace", "/volume", -30)
            H.equal(o.op, "replace")
            H.equal(o.path, "/volume")
            H.equal(o.value, -30)
        end,
    },
    {
        name = "encodeChange produces a changemso carrying a JSON array",
        fn = function()
            local text = Protocol.encodeChange({ Protocol.op("replace", "/volume", -30) })
            H.equal(text:sub(1, 10), "changemso ")
            local body = text:sub(11)
            H.equal(body:sub(1, 1), "[", "the argument must be an array, not an object")
            -- Round-trips through the same codec the unit's replies use.
            local back = Protocol.parse(text)
            H.equal(back.verb, "changemso")
            H.equal(back.arg[1].path, "/volume")
            H.equal(back.arg[1].value, -30)
        end,
    },
    {
        name = "encodeChange keeps several operations in order",
        fn = function()
            local text = Protocol.encodeChange({
                Protocol.op("replace", "/muted", false),
                Protocol.op("replace", "/volume", -40),
            })
            local back = Protocol.parse(text)
            H.count(back.arg, 2)
            H.equal(back.arg[1].path, "/muted")
            H.equal(back.arg[2].path, "/volume")
        end,
    },
}

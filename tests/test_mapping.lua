local H = require("tests.harness")
local Mapping = require("htp1.mapping")

return {
    {
        name = "every HDMI input maps both ways",
        fn = function()
            for n = 1, 8 do
                local binding = 999 + n
                local key = "h" .. n
                H.equal(Mapping.bindingToKey(binding), key, "binding " .. binding)
                H.equal(Mapping.keyToBinding(key), binding, "key " .. key)
            end
        end,
    },
    {
        name = "the audio-only inputs map both ways",
        fn = function()
            local pairsToCheck = {
                { 3000, "a1" }, { 3001, "a2" },
                { 3002, "spdif1" }, { 3003, "spdif2" }, { 3004, "spdif3" },
                { 3005, "optical1" }, { 3006, "optical2" }, { 3007, "optical3" },
                { 3009, "aes" }, { 3010, "b" }, { 3011, "usb" },
            }
            for _, entry in ipairs(pairsToCheck) do
                H.equal(Mapping.bindingToKey(entry[1]), entry[2], "binding " .. entry[1])
                H.equal(Mapping.keyToBinding(entry[2]), entry[1], "key " .. entry[2])
            end
        end,
    },
    {
        name = "both eARC bindings decode to tv, and tv encodes to the proxy-visible one",
        fn = function()
            H.equal(Mapping.bindingToKey(1008), "tv", "the hidden HDMI binding")
            H.equal(Mapping.bindingToKey(3008), "tv", "the virtual audio binding")
            H.equal(Mapping.keyToBinding("tv"), 3008, "the proxy addresses the audio binding")
        end,
    },
    {
        name = "roon has no connection, by decision",
        fn = function()
            H.equal(Mapping.keyToBinding("roon"), nil,
                "roon is out of scope and must not gain a binding silently")
        end,
    },
    {
        name = "an unknown binding or key maps to nil rather than guessing",
        fn = function()
            H.equal(Mapping.bindingToKey(9999), nil)
            H.equal(Mapping.keyToBinding("nosuchinput"), nil)
            H.equal(Mapping.bindingToKey(nil), nil)
            H.equal(Mapping.keyToBinding(nil), nil)
        end,
    },
    {
        name = "the surround modes are the seven upmixers with the vendor's labels",
        fn = function()
            H.count(Mapping.SURROUND, 7)
            local expected = {
                { 1, "off", "Direct" }, { 2, "native", "Native" },
                { 3, "dolby", "Dolby Surround" }, { 4, "dts", "DTS Neural:X" },
                { 5, "auro", "Auro-3D" }, { 6, "mono", "Mono" }, { 7, "stereo", "Stereo" },
            }
            for i, entry in ipairs(expected) do
                H.equal(Mapping.SURROUND[i].id, entry[1])
                H.equal(Mapping.SURROUND[i].key, entry[2])
                H.equal(Mapping.SURROUND[i].name, entry[3])
                H.equal(Mapping.surroundIdToKey(entry[1]), entry[2])
                H.equal(Mapping.keyToSurroundId(entry[2]), entry[1])
            end
        end,
    },
    {
        name = "an unknown surround id or key maps to nil",
        fn = function()
            H.equal(Mapping.surroundIdToKey(0), nil)
            H.equal(Mapping.surroundIdToKey(8), nil)
            H.equal(Mapping.keyToSurroundId("atmos"), nil)
        end,
    },
    {
        name = "dB maps to percent across the observed -50..0 range",
        fn = function()
            H.equal(Mapping.dbToPercent(-50, -50, 0), 0)
            H.equal(Mapping.dbToPercent(0, -50, 0), 100)
            H.equal(Mapping.dbToPercent(-25, -50, 0), 50)
            H.equal(Mapping.dbToPercent(-30, -50, 0), 40)
        end,
    },
    {
        name = "percent maps back to whole dB",
        fn = function()
            H.equal(Mapping.percentToDb(0, -50, 0), -50)
            H.equal(Mapping.percentToDb(100, -50, 0), 0)
            H.equal(Mapping.percentToDb(50, -50, 0), -25)
            H.equal(Mapping.percentToDb(41, -50, 0), -30)  -- rounds to the nearest dB
        end,
    },
    {
        name = "the scale follows a non-default range read from the unit",
        fn = function()
            H.equal(Mapping.dbToPercent(-20, -40, -10), 67)
            H.equal(Mapping.percentToDb(100, -40, -10), -10)
            H.equal(Mapping.percentToDb(0, -40, -10), -40)
        end,
    },
    {
        name = "values outside the range clamp instead of overflowing",
        fn = function()
            H.equal(Mapping.dbToPercent(10, -50, 0), 100)
            H.equal(Mapping.dbToPercent(-99, -50, 0), 0)
            H.equal(Mapping.percentToDb(150, -50, 0), 0)
            H.equal(Mapping.percentToDb(-10, -50, 0), -50)
        end,
    },
    {
        name = "a degenerate range does not divide by zero",
        fn = function()
            H.equal(Mapping.dbToPercent(-20, -20, -20), 0)
            H.equal(Mapping.percentToDb(50, -20, -20), -20)
        end,
    },
    {
        name = "non-numeric input yields nil rather than an arithmetic error",
        fn = function()
            H.equal(Mapping.dbToPercent(nil, -50, 0), nil)
            H.equal(Mapping.percentToDb("loud", -50, 0), nil)
        end,
    },
}

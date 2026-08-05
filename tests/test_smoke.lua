local H = require("tests.harness")
local mock = H.mock

return {
    {
        name = "the mock installs and exposes the C4 global",
        fn = function()
            mock.install({ ["Debug Mode"] = "Off" })
            H.isTrue(_G.C4 ~= nil, "C4 global should exist")
            H.equal(Properties["Debug Mode"], "Off")
        end,
    },
    {
        name = "virtual time fires a one-shot timer exactly once",
        fn = function()
            mock.install({})
            local fired = 0
            C4:SetTimer(500, function() fired = fired + 1 end, false)
            mock.advance(499)
            H.equal(fired, 0, "should not fire early")
            mock.advance(1)
            H.equal(fired, 1, "should fire at its due time")
            mock.advance(5000)
            H.equal(fired, 1, "a one-shot timer should not repeat")
        end,
    },
    {
        name = "virtual time repeats a repeating timer and honours Cancel",
        fn = function()
            mock.install({})
            local fired = 0
            local timer = C4:SetTimer(100, function() fired = fired + 1 end, true)
            mock.advance(350)
            H.equal(fired, 3, "should fire once per interval")
            timer:Cancel()
            mock.advance(1000)
            H.equal(fired, 3, "cancelled timers stop firing")
        end,
    },
    {
        name = "a non-positive timer interval is refused rather than hanging the suite",
        fn = function()
            mock.install({})
            H.errorMatches(function() C4:SetTimer(0, function() end, true) end,
                "positive interval")
            H.errorMatches(function() C4:SetTimer(-5, function() end, false) end,
                "positive interval")
        end,
    },
    {
        name = "SendToProxy rejects an explicit nil call type",
        fn = function()
            mock.install({})
            H.errorMatches(function()
                C4:SendToProxy(5001, "VOLUME_LEVEL_CHANGED", { LEVEL = 10 }, nil)
            end, "explicit nil strCallType")
        end,
    },
    {
        name = "the mock's base64 matches the known RFC 6455 example",
        fn = function()
            mock.install({})
            -- Bytes 0x01..0x10. Written with string.char rather than \x escapes,
            -- which Lua 5.1 does not have -- the driver must stay in that dialect.
            local sixteenBytes = string.char(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)
            H.equal(C4:Base64Encode(sixteenBytes), "AQIDBAUGBwgJCgsMDQ4PEA==")
        end,
    },
}

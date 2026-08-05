-- Invented mso documents. Shapes follow the two firmware families the driver
-- must tolerate; every value is made up. No site data belongs in this file.

local F = {}

local function baseInputs()
    return {
        h1       = { label = "Streamer", visible = true,  disable = false },
        h2       = { label = "Console",  visible = true,  disable = false },
        h3       = { label = "HDMI 3",   visible = false, disable = false },
        a1       = { label = "Turntable", visible = true, disable = false },
        optical1 = { label = "Optical 1", visible = false, disable = false },
        roon     = { label = "Roon",     visible = true,  disable = false },
    }
end

-- The unit's decoder internals -- sample rate enums, delay values, activity
-- bitmasks, format codes -- that this driver deliberately does not track.
-- Only present here to prove a `/status/raw/...` push is ignored.
local function statusRaw()
    return {
        decoderSampleRateEnum = 2,
        delayValues = { 0, 0, 12, 0 },
        activityMask = 0,
        formatCode = 17,
    }
end

-- The unit's stored macros. Every slot holds an array of JSON-patch operations
-- and the names live apart, in a map keyed by the same slot names.
--
-- MACRO NAMES ARE SITE DATA on a real unit -- whatever the owner typed. Every
-- name here is invented and deliberately neutral. The slots cover the cases the
-- picker and the replay have to get right:
--
--   cmda        two operations on two different paths -- both must be sent
--   cmdb        two operations on ONE path -- only the later value may be sent
--   cmdc        named but empty -- must not appear in the list at all
--   cmdd        one good operation among entries that are not operations
--   cmdcustom1  operations but no name -- falls back to the slot key
--
-- preset2..4 and cmdcustom2..16 are simply absent, as they are on a unit whose
-- owner never used them.
local function macros()
    return {
        macroNames = {
            cmda = "Movie Night",
            cmdb = "Listening",
            cmdc = "Late Night",
            preset1 = "Preset 1",
        },
        -- Every value here differs from what the fixture's own document
        -- reports, so a test asserting an operation was sent cannot pass by
        -- accident on a value that was already in place.
        cmda = {
            { op = "replace", path = "/volume", value = -22 },
            { op = "replace", path = "/dialogEnh", value = 5 },
        },
        cmdb = {
            { op = "replace", path = "/volume", value = -40 },
            { op = "replace", path = "/volume", value = -30 },
        },
        cmdc = {},
        cmdd = {
            "not an operation at all",
            { path = "/night", value = "on" },              -- no op
            { op = "replace", value = "on" },                -- no path
            { op = "replace", path = "/night", value = "auto" },
            { op = "remove", path = "/loudness" },           -- nothing to replay
        },
        preset1 = {
            { op = "replace", path = "/upmix/select", value = "auro" },
        },
        cmdcustom1 = {
            { op = "replace", path = "/muted", value = true },
        },
        -- /svronly holds more than macros on a real unit; this proves an
        -- unknown key there is ignored rather than mistaken for a slot.
        lastUsedPage = "settings",
    }
end

-- Firmware 2.x shape: has channeltrim, dialnorm, shaker, secondaryVolume.
function F.modern()
    return {
        volume = -25,
        muted = false,
        powerIsOn = true,
        powerAction = "none",
        input = "h1",
        unitname = "Processor",
        upmix = {
            select = "dolby",
            dolby = { cs = false, homevis = true },
            dts   = { ws = true,  homevis = true },
        },
        cal = {
            vpl = -50, vph = 0, zeroPoint = 0, diracactive = "on", currentdiracslot = 0,
            lipsync = 20,
            -- Six fixed filter slots. Names are site data on a real unit --
            -- every name here is invented, and one is left empty on purpose to
            -- prove an unnamed slot still gets a row rather than being dropped.
            slots = {
                { name = "Calibrated" },
                { name = "Flat" },
                { name = "" },
                { name = "Movie" },
                { name = "Music" },
                { name = "Custom" },
            },
        },
        inputs = baseInputs(),
        svronly = macros(),
        -- swVer is the release the unit calls itself; avController is an internal
        -- component on its own numbering. Both are reported, and they never match.
        versions = { avController = "5.96 Built Jul  8 2026, 11:45:00\n", swVer = "V2.1.1",
                     SerialNumber = "0001" },
        channeltrim = {}, dialnorm = 0, shaker = {}, secondaryVolume = -40,
        loudness = "off", night = "off", dialogEnh = 3, bassenhance = "off",
        status = {
            SurroundMode = "Native Dolby ATMOS",
            DECSourceProgram = "Dolby MAT/PCM",
            DECProgramFormat = "Object Audio",
            DECSampleRate = "48 kHz",
            ENCListeningFormat = "5.1.2",
            ENCSampleRate = "48 kHz",
            DiracState = "on",
            raw = statusRaw(),
        },
        videostat = {
            VideoResolution = "3840x2160p60Hz",
            VideoColorSpace = "BT2020",
            HDRstatus = "HDR10",
        },
    }
end

-- Firmware 1.x shape: no channeltrim/dialnorm/shaker, and secondVolume not
-- secondaryVolume. Everything this driver reads must still be present.
--
-- Also the fixture that proves absence tolerance for the video fields: this
-- unit reports `status` but, on this firmware, no `videostat` block at all.
-- It carries no `svronly` block either, so it doubles as the "a document that
-- says nothing about macros leaves the macro picker alone" case.
function F.legacy()
    return {
        volume = -29,
        muted = false,
        powerIsOn = true,
        powerAction = "none",
        input = "h1",
        unitname = "Processor",
        upmix = { select = "dolby", dolby = { cs = false }, dts = { ws = true } },
        cal = {
            vpl = -50, vph = 0, zeroPoint = 0, diracactive = "off", currentdiracslot = 1,
            lipsync = 0,
            -- Same invented-name rule as the modern fixture; here the unnamed
            -- slot omits the `name` key entirely, to prove absence and an empty
            -- string are both tolerated.
            slots = {
                { name = "Slot 1" },
                {},
                { name = "Flat" },
                { name = "Movie" },
                { name = "Music" },
                { name = "Custom" },
            },
        },
        inputs = baseInputs(),
        versions = { avController = "4.91 Built Dec 23 2024, 11:23:51\n", swVer = "V1.13.3",
                     SerialNumber = "0002" },
        secondVolume = -40, vu = {},
        loudness = "off", night = "off", dialogEnh = 3, bassenhance = "off",
        status = {
            SurroundMode = "Dolby Surround",
            DECSourceProgram = "PCM",
            DECProgramFormat = "2.0.0",
            DECSampleRate = "48 kHz",
            ENCListeningFormat = "5.2.2t",
            ENCSampleRate = "48 kHz",
            DiracState = "off",
            raw = statusRaw(),
        },
    }
end

-- A document missing everything optional, to prove absence tolerance.
function F.sparse()
    return { volume = -10, powerIsOn = false }
end

return F

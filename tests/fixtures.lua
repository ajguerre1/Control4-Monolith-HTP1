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
        cal = { vpl = -50, vph = 0, zeroPoint = 0, diracactive = "on", currentdiracslot = 0 },
        inputs = baseInputs(),
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
function F.legacy()
    return {
        volume = -29,
        muted = false,
        powerIsOn = true,
        powerAction = "none",
        input = "h1",
        unitname = "Processor",
        upmix = { select = "dolby", dolby = { cs = false }, dts = { ws = true } },
        cal = { vpl = -50, vph = 0, zeroPoint = 0, diracactive = "off", currentdiracslot = 1 },
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

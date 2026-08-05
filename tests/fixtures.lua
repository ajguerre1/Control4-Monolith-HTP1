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
    }
end

-- Firmware 1.x shape: no channeltrim/dialnorm/shaker, and secondVolume not
-- secondaryVolume. Everything this driver reads must still be present.
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
    }
end

-- A document missing everything optional, to prove absence tolerance.
function F.sparse()
    return { volume = -10, powerIsOn = false }
end

return F

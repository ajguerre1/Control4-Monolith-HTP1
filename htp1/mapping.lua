-- Static maps between Control4's world and the unit's.
--
-- The receiver proxy addresses inputs and outputs by CONNECTION BINDING ID, not
-- by any internal index, so this table is the input map -- it must stay in step
-- with the <connections> block in driver.xml.
--
-- Pure Lua; no Control4 API.

local Mapping = {}

Mapping.PROXY_BINDING   = 5001
Mapping.NETWORK_BINDING = 6001
Mapping.ROOM_OUTPUT     = 7000

-- What the proxy is told when the unit is on an input Control4 does not model,
-- such as Roon. Reporting the truth beats inventing a selected input.
Mapping.NO_INPUT = -1

Mapping.INPUTS = {
    { binding = 1000, key = "h1",       name = "HDMI Input 1" },
    { binding = 1001, key = "h2",       name = "HDMI Input 2" },
    { binding = 1002, key = "h3",       name = "HDMI Input 3" },
    { binding = 1003, key = "h4",       name = "HDMI Input 4" },
    { binding = 1004, key = "h5",       name = "HDMI Input 5" },
    { binding = 1005, key = "h6",       name = "HDMI Input 6" },
    { binding = 1006, key = "h7",       name = "HDMI Input 7" },
    { binding = 1007, key = "h8",       name = "HDMI Input 8" },
    { binding = 3000, key = "a1",       name = "Analog Input 1" },
    { binding = 3001, key = "a2",       name = "Analog Input 2" },
    { binding = 3002, key = "spdif1",   name = "Coax Input 1" },
    { binding = 3003, key = "spdif2",   name = "Coax Input 2" },
    { binding = 3004, key = "spdif3",   name = "Coax Input 3" },
    { binding = 3005, key = "optical1", name = "Optical Input 1" },
    { binding = 3006, key = "optical2", name = "Optical Input 2" },
    { binding = 3007, key = "optical3", name = "Optical Input 3" },
    { binding = 3008, key = "tv",       name = "eARC Audio" },
    { binding = 3009, key = "aes",      name = "AES/EBU Input" },
    { binding = 3010, key = "b",        name = "Bluetooth" },
    { binding = 3011, key = "usb",      name = "USB Audio" },
}

-- The eARC input is cabled as HDMI but selected as audio, so it carries a hidden
-- video binding alongside the proxy-visible one. Decoding accepts both; encoding
-- returns the proxy-visible binding above.
local HIDDEN_BINDINGS = { [1008] = "tv" }

local bindingIndex, keyIndex = {}, {}
for _, input in ipairs(Mapping.INPUTS) do
    bindingIndex[input.binding] = input.key
    keyIndex[input.key] = input.binding
end
for binding, key in pairs(HIDDEN_BINDINGS) do
    bindingIndex[binding] = key
end

function Mapping.bindingToKey(binding)
    if binding == nil then return nil end
    return bindingIndex[tonumber(binding) or binding]
end

function Mapping.keyToBinding(key)
    if key == nil then return nil end
    return keyIndex[key]
end

Mapping.SURROUND = {
    { id = 1, key = "off",    name = "Direct" },
    { id = 2, key = "native", name = "Native" },
    { id = 3, key = "dolby",  name = "Dolby Surround" },
    { id = 4, key = "dts",    name = "DTS Neural:X" },
    { id = 5, key = "auro",   name = "Auro-3D" },
    { id = 6, key = "mono",   name = "Mono" },
    { id = 7, key = "stereo", name = "Stereo" },
}

local surroundById, surroundByKey = {}, {}
for _, mode in ipairs(Mapping.SURROUND) do
    surroundById[mode.id] = mode.key
    surroundByKey[mode.key] = mode.id
end

function Mapping.surroundIdToKey(id)
    if id == nil then return nil end
    return surroundById[tonumber(id) or id]
end

function Mapping.keyToSurroundId(key)
    if key == nil then return nil end
    return surroundByKey[key]
end

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

-- Round half away from zero, so a tie such as -29.5 rounds to -30, not -29.
-- math.floor(x + 0.5) alone would round every tie up, which is wrong once x
-- can be negative -- and dB values here usually are.
local function round(x)
    if x >= 0 then
        return math.floor(x + 0.5)
    end
    return -math.floor(-x + 0.5)
end

-- Control4 rooms work in 0..100; the unit works in whole dB over the range it
-- reports in cal.vpl and cal.vph. That range is user-configurable, so it is read
-- from the unit rather than assumed.
function Mapping.dbToPercent(db, vpl, vph)
    db, vpl, vph = tonumber(db), tonumber(vpl), tonumber(vph)
    if not (db and vpl and vph) then return nil end
    if vph <= vpl then return 0 end
    local percent = (db - vpl) / (vph - vpl) * 100
    return clamp(round(percent), 0, 100)
end

function Mapping.percentToDb(percent, vpl, vph)
    percent, vpl, vph = tonumber(percent), tonumber(vpl), tonumber(vph)
    if not (percent and vpl and vph) then return nil end
    if vph <= vpl then return vpl end
    local db = vpl + clamp(percent, 0, 100) / 100 * (vph - vpl)
    return clamp(round(db), vpl, vph)
end

return Mapping

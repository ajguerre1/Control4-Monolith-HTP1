-- The HTP-1's message layer: a verb, optionally followed by one space and a
-- JSON argument. Pure Lua; no Control4 API.
--
--   ->  getmso
--   <-  mso {...}                 the full document, ~38 KB
--   ->  changemso [ops]           RFC 6902 patch operations
--   <-  msoupdate [ops]           pushed on every change, from any source
--   <-  error "bad-verb"          rejected input; the connection survives

local JSON = require("module.json")

-- Friedl's codec reports a decode failure by printing, and one of those prints
-- is a bare print() that no documented hook can reach. Driver output lands in
-- Composer's Lua window, this driver's logging is off by default, and malformed
-- input arrives from the network -- so a faulty peer could otherwise drive
-- unbounded output that the installer never asked for. Silence the codec for
-- the duration of the decode, and only for that.
local function decodeQuietly(body)
    local realPrint = print
    print = function() end
    local ok, value = pcall(function() return JSON:decode(body) end)
    print = realPrint
    return ok, value
end

local Protocol = {}

Protocol.GET_MSO = "getmso"

-- Never raises. A malformed message must not be able to kill the read path.
function Protocol.parse(text)
    if type(text) ~= "string" or text == "" then
        return { verb = "", err = "empty or non-string message" }
    end

    local space = text:find(" ", 1, true)
    if not space then return { verb = text } end

    local verb = text:sub(1, space - 1)
    local body = text:sub(space + 1)

    local ok, value = decodeQuietly(body)
    if not ok then
        return { verb = verb, err = "undecodable JSON argument (" .. #body .. " bytes)" }
    end
    if value == nil then
        -- Valid JSON that decoded to null. No path this driver reads takes a
        -- null, so it is still an error -- but not a decoding failure.
        return { verb = verb, err = "JSON argument decoded to null" }
    end

    return { verb = verb, arg = value }
end

function Protocol.op(operation, path, value)
    return { op = operation, path = path, value = value }
end

-- `ops` must be a non-empty array. An empty one would encode as {} rather than
-- [] and the unit would reject it, so callers skip the send instead.
function Protocol.encodeChange(ops)
    return "changemso " .. JSON:encode(ops)
end

return Protocol

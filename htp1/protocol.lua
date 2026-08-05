-- The HTP-1's message layer: a verb, optionally followed by one space and a
-- JSON argument. Pure Lua; no Control4 API.
--
--   ->  getmso
--   <-  mso {...}                 the full document, ~38 KB
--   ->  changemso [ops]           RFC 6902 patch operations
--   <-  msoupdate [ops]           pushed on every change, from any source
--   <-  error "bad-verb"          rejected input; the connection survives

local JSON = require("module.json")

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

    local ok, value = pcall(function() return JSON:decode(body) end)
    if not ok or value == nil then
        return { verb = verb, err = "undecodable JSON argument (" .. #body .. " bytes)" }
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

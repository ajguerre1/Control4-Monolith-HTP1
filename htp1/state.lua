-- The projected view of the unit's mso document.
--
-- The real document is ~38 KB and several thousand paths. Mirroring it would be
-- roughly ten times the memory per driver instance, and a controller runs two.
-- This keeps only the paths the driver acts on, and reports what actually moved
-- so callers notify the proxy on real transitions rather than on every push.
--
-- Pure Lua; no Control4 API.

local State = {}
State.__index = State

-- Tracked scalars, by their JSON-pointer path in the document.
local SCALAR_PATHS = {
    ["/volume"]                = "volume",
    ["/muted"]                 = "muted",
    ["/powerIsOn"]             = "power",
    ["/powerAction"]           = "powerAction",
    ["/input"]                 = "input",
    ["/upmix/select"]          = "upmix",
    ["/cal/vpl"]               = "vpl",
    ["/cal/vph"]               = "vph",
    ["/unitname"]              = "unitName",
    ["/versions/avController"] = "firmware",
    ["/versions/SerialNumber"] = "serial",
}
State.SCALAR_PATHS = SCALAR_PATHS

-- The unit reports its controller version as "5.96 Built Jul  8 2026, ...\n".
-- Only the number is useful in a Composer property.
local NORMALISE = {
    firmware = function(value) return tostring(value):match("^%s*(%S+)") end,
    serial   = function(value) return tostring(value) end,
}

local function resolve(container, pointer)
    local node = container
    for segment in pointer:gmatch("/([^/]+)") do
        if type(node) ~= "table" then return nil end
        node = node[segment]
    end
    return node
end

function State.new()
    return setmetatable({ loaded = false, fields = {}, inputs = {} }, State)
end

function State:inputLabel(key)
    local entry = self.inputs[key]
    return entry and entry.label or nil
end

-- Returns true when the stored value actually moved.
function State:_assign(field, value)
    local normalise = NORMALISE[field]
    if normalise and value ~= nil then value = normalise(value) end
    if self.fields[field] == value then return false end
    self.fields[field] = value
    return true
end

function State:_setInputs(inputs)
    if type(inputs) ~= "table" then return false end
    local changed = false
    for key, entry in pairs(inputs) do
        if type(entry) == "table" then
            local current = self.inputs[key]
            local label   = entry.label
            local visible = entry.visible
            if not current then
                self.inputs[key] = { label = label, visible = visible }
                changed = true
            elseif current.label ~= label or current.visible ~= visible then
                current.label, current.visible = label, visible
                changed = true
            end
        end
    end
    return changed
end

-- Re-derive every tracked path that lives under `prefix` from `value`.
-- `prefix` of "" means the whole document.
function State:_applyContainer(prefix, value, changes)
    if type(value) ~= "table" then return changes end

    for path, field in pairs(SCALAR_PATHS) do
        local relative
        if prefix == "" then
            relative = path
        elseif path:sub(1, #prefix + 1) == prefix .. "/" then
            relative = path:sub(#prefix + 1)
        end
        if relative then
            local resolved = resolve(value, relative)
            if resolved ~= nil and self:_assign(field, resolved) then
                changes[field] = true
            end
        end
    end

    local inputs
    if prefix == "" then
        inputs = value.inputs
    elseif prefix == "/inputs" then
        inputs = value
    end
    if inputs and self:_setInputs(inputs) then changes.inputs = true end

    return changes
end

-- Apply a full document from `getmso`.
function State:applyDocument(doc)
    local changes = {}
    if type(doc) ~= "table" then return changes end
    self:_applyContainer("", doc, changes)
    self.loaded = true
    return changes
end

return State

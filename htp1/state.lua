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
    ["/versions/avController"] = "avControllerVersion",
    ["/versions/swVer"]        = "systemVersion",
    ["/versions/SerialNumber"] = "serial",
}
State.SCALAR_PATHS = SCALAR_PATHS

-- Two different versions, and the distinction matters to an installer.
--
-- `swVer` is the system software release, which is what the unit calls itself
-- everywhere a human looks -- "V2.1.1", "V1.13.3" -- and what release notes and
-- support conversations are about.
--
-- `avController` is an internal component version on its own numbering ("5.96",
-- "4.91"), reported as "5.96 Built Jul  8 2026, 11:45:00\n". Showing that under
-- a label like "Firmware Version" is actively misleading: it looks like a
-- version the owner should recognise, and it is not one.
local NORMALISE = {
    avControllerVersion = function(value) return tostring(value):match("^%s*(%S+)") end,
    systemVersion       = function(value) return tostring(value):match("^%s*(.-)%s*$") end,
    serial              = function(value) return tostring(value) end,
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

-- A field absent from a pushed entry is UNSPECIFIED, not cleared.
--
-- This loop already treats a container replace as a per-key merge: inputs the
-- push does not mention are left alone. Clearing a field that a mentioned entry
-- happens to omit would contradict that at the level below, and a partial
-- `/inputs` replace would silently wipe a label the installer had set -- with a
-- change notification indistinguishable from a genuine rename.
function State:_setInputs(inputs)
    if type(inputs) ~= "table" then return false end
    local changed = false
    for key, entry in pairs(inputs) do
        if type(entry) == "table" then
            local current = self.inputs[key]
            if not current then
                current = {}
                self.inputs[key] = current
            end
            if entry.label ~= nil and current.label ~= entry.label then
                current.label = entry.label
                changed = true
            end
            if entry.visible ~= nil and current.visible ~= entry.visible then
                current.visible = entry.visible
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

-- Container paths whose replacement re-derives everything beneath them.
local CONTAINER_PREFIXES = { "/cal", "/upmix", "/versions", "/inputs" }

-- True when `path` is a tracked scalar, a tracked input sub-path, or a container
-- holding either. Checked before any allocation, so the thousands of paths this
-- driver ignores cost a hash lookup, at most two anchored matches and a few
-- equality tests -- no allocation, so a busy device stays cheap.
local function isInteresting(path)
    if SCALAR_PATHS[path] then return "scalar" end
    if path == "" or path == "/" then return "container" end
    if path:match("^/inputs/[^/]+/label$") or path:match("^/inputs/[^/]+/visible$") then
        return "input"
    end
    for _, prefix in ipairs(CONTAINER_PREFIXES) do
        if path == prefix then return "container" end
    end
    return nil
end
State._isInteresting = isInteresting

function State:_applyOne(operation, changes)
    if type(operation) ~= "table" then return end

    local kind = operation.op
    local path = operation.path
    if type(path) ~= "string" or type(kind) ~= "string" then return end

    local interest = isInteresting(path)
    if not interest then return end

    local removing = (kind == "remove")
    if not removing and operation.value == nil then
        -- Skip rather than clear: this driver never needs a null-valued path,
        -- and skipping avoids depending on how the JSON codec spells null.
        return
    end

    if interest == "scalar" then
        local field = SCALAR_PATHS[path]
        if self:_assign(field, removing and nil or operation.value) then
            changes[field] = true
        end
        return
    end

    if interest == "input" then
        local key, leaf = path:match("^/inputs/([^/]+)/(%a+)$")
        local entry = self.inputs[key]
        if not entry then
            entry = {}
            self.inputs[key] = entry
        end
        local newValue = removing and nil or operation.value
        if entry[leaf] ~= newValue then
            entry[leaf] = newValue
            changes.inputs = true
        end
        return
    end

    -- A container replacement.
    local prefix = (path == "" or path == "/") and "" or path
    self:_applyContainer(prefix, operation.value, changes)
end

-- Apply an `msoupdate` argument. Accepts an array of operations or, defensively,
-- a single unwrapped one. Never raises: a malformed push must not break reading.
function State:applyOps(ops)
    local changes = {}
    if type(ops) ~= "table" then return changes end

    if ops.op ~= nil and ops.path ~= nil then
        self:_applyOne(ops, changes)
        return changes
    end

    for _, operation in ipairs(ops) do
        self:_applyOne(operation, changes)
    end
    return changes
end

return State

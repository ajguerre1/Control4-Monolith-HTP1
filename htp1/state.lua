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
    ["/volume"]                     = "volume",
    ["/muted"]                      = "muted",
    ["/powerIsOn"]                  = "power",
    ["/powerAction"]                = "powerAction",
    ["/input"]                      = "input",
    ["/upmix/select"]               = "upmix",
    ["/loudness"]                   = "loudness",
    ["/night"]                      = "night",
    ["/dialogEnh"]                  = "dialogEnhance",
    ["/bassenhance"]                = "bassEnhance",
    ["/cal/vpl"]                    = "vpl",
    ["/cal/vph"]                    = "vph",
    ["/cal/currentdiracslot"]       = "diracSlot",
    ["/cal/lipsync"]                = "lipSync",
    ["/unitname"]                   = "unitName",
    ["/versions/avController"]      = "avControllerVersion",
    ["/versions/swVer"]             = "systemVersion",
    ["/versions/SerialNumber"]      = "serial",
    ["/status/SurroundMode"]        = "surroundMode",
    ["/status/DECSourceProgram"]    = "decSourceProgram",
    ["/status/DECProgramFormat"]    = "decProgramFormat",
    ["/status/DECSampleRate"]       = "decSampleRate",
    ["/status/ENCListeningFormat"]  = "encListeningFormat",
    ["/status/ENCSampleRate"]       = "encSampleRate",
    ["/status/DiracState"]          = "diracState",
    ["/videostat/VideoResolution"]  = "videoResolution",
    ["/videostat/VideoColorSpace"]  = "videoColorSpace",
    ["/videostat/HDRstatus"]        = "videoHdr",
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

-- The unit stores macros in these fixed slots and no others: four command
-- buttons, four presets, sixteen custom entries. Each slot lives at
-- /svronly/<slot> and holds an ARRAY OF JSON-PATCH OPERATIONS -- there is no
-- "run macro" verb on this unit, so running one means replaying what is stored
-- here. The human-readable names live apart, in a map at /svronly/macroNames
-- keyed by these same slot names.
--
-- Declared as an array, not derived from pairs(), because this is also the
-- order Composer's macro picker shows: pairs() order is undefined in Lua, so a
-- list built from it would reshuffle between driver loads.
local MACRO_SLOTS = { "cmda", "cmdb", "cmdc", "cmdd",
                      "preset1", "preset2", "preset3", "preset4" }
for i = 1, 16 do table.insert(MACRO_SLOTS, "cmdcustom" .. i) end
State.MACRO_SLOTS = MACRO_SLOTS

-- Keys outside this set are ignored wherever macros are read. /svronly is the
-- unit's own scratch container and holds more than macros, so an unknown key
-- there is not a macro; and a key with no row here has no defined position in
-- the picker above.
local MACRO_SLOT_SET = {}
for _, slot in ipairs(MACRO_SLOTS) do MACRO_SLOT_SET[slot] = true end

local function resolve(container, pointer)
    local node = container
    for segment in pointer:gmatch("/([^/]+)") do
        if type(node) ~= "table" then return nil end
        node = node[segment]
    end
    return node
end

function State.new()
    return setmetatable({
        loaded = false, fields = {}, inputs = {}, diracSlots = {}, macros = {},
    }, State)
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

-- Six fixed Dirac filter slots, each with a name the owner may have set on the
-- unit -- site data the driver only ever passes through, never invents. Kept as
-- an array in the order the unit reports them: `cal.slots` is a 0-indexed array
-- on the wire and `/cal/currentdiracslot` is a 0-based index into it, so Lua's
-- 1-based array preserves that correspondence (slot 0 lands at diracSlots[1]).
--
-- A slot with an empty or absent name still gets an entry. Dropping it would
-- misalign the array against `currentdiracslot`, and the M3-T3 slot picker
-- needs a row to fall back to "Slot N" for, not a hole.
function State:_setDiracSlots(slots)
    if type(slots) ~= "table" then return false end
    local changed = false
    for i, entry in ipairs(slots) do
        local name = (type(entry) == "table") and entry.name or nil
        local current = self.diracSlots[i]
        if not current then
            current = {}
            self.diracSlots[i] = current
        end
        if current.name ~= name then
            current.name = name
            changed = true
        end
    end
    return changed
end

-- A stored entry counts as an operation only when it carries what replaying it
-- needs: the kind `replace`, a path to apply it to, and a value to apply.
-- Anything else in the array -- a bare string, a half-written entry, or an entry
-- of any other kind -- is dropped here rather than forwarded to the unit,
-- because a driver that blindly relays whatever it finds in a stored blob is one
-- malformed macro away from sending nonsense to a live processor.
--
-- EXACTLY ONE KIND IS REPLAYABLE, and the filter has to say so, because the
-- write path does not carry the stored kind through: htp1/session.lua encodes
-- every queued write as `replace`. So a stored `test` -- a guard meaning "only
-- proceed if this path already holds this value" -- would go out as a replace
-- and be EXECUTED, muting a room the owner only meant to check. A stored `add`
-- would go out as a replace on a member that does not exist, which this unit
-- rejects wholesale, so one `add` would silently fail the entire macro. Writing
-- the other kinds properly means a write path that can send them, which is a
-- wire shape this project has not verified; until then, not sending is the only
-- honest option, and runMacro reports what it skipped.
--
-- Filtering on INGEST rather than at replay time is deliberate: it makes "this
-- slot has operations" mean "this slot has operations this driver can replay",
-- which is the question the picker asks when deciding whether to list a slot at
-- all. The count of what was dropped is returned alongside, so replaying a macro
-- can say how much of it did not run.
local function replayableOps(list)
    local ops, dropped = {}, 0
    if type(list) ~= "table" then return ops, dropped end
    for _, entry in ipairs(list) do
        if type(entry) == "table" and entry.op == "replace"
            and type(entry.path) == "string" and entry.value ~= nil then
            table.insert(ops, { op = entry.op, path = entry.path, value = entry.value })
        else
            dropped = dropped + 1
        end
    end
    return ops, dropped
end

function State:_macroEntry(slot)
    local entry = self.macros[slot]
    if not entry then
        entry = { ops = {}, dropped = 0 }
        self.macros[slot] = entry
    end
    return entry
end

-- Returns true when what a MACRO PICKER would show has changed -- which is to
-- say, when the slot gained or lost its operations. The picker lists names, not
-- operations, so an owner editing a macro that stays non-empty stores its new
-- operations without asking anything to redraw.
--
-- `entry.dropped` rides along and deliberately does NOT count as a change: how
-- much of a macro this driver cannot replay is something the owner is told when
-- they run it, not a reason to repaint a list.
function State:_setMacroOps(slot, list)
    local entry = self:_macroEntry(slot)
    local had = #entry.ops > 0
    entry.ops, entry.dropped = replayableOps(list)
    return had ~= (#entry.ops > 0)
end

-- Names are SITE DATA: whatever the owner typed on the unit. The driver passes
-- them through and never invents one.
function State:_setMacroNames(names)
    if type(names) ~= "table" then return false end
    local changed = false
    for slot, name in pairs(names) do
        if MACRO_SLOT_SET[slot] and type(name) == "string" then
            local entry = self:_macroEntry(slot)
            if entry.name ~= name then
                entry.name = name
                changed = true
            end
        end
    end
    return changed
end

-- `complete` says whether `svronly` is the container as carried by a WHOLE
-- document, which is the one case where absence means deleted.
--
-- In a targeted /svronly push a slot the container does not mention is left
-- alone, not emptied -- the same "absent is UNSPECIFIED, not cleared" rule
-- _setInputs follows above, because a partial push would otherwise wipe every
-- macro it happened not to carry.
--
-- A getmso reply is not partial. It is the unit's full state, so a slot it does
-- not mention is a slot the owner deleted, and keeping it would leave a deleted
-- macro listed in Composer and still runnable -- putting the owner's removed
-- operations on the wire. The slot is dropped outright rather than emptied so
-- that self.macros keeps holding only what the unit actually has.
function State:_setMacros(svronly, complete)
    if type(svronly) ~= "table" then return false end
    local names = svronly.macroNames
    local changed = self:_setMacroNames(names)
    for _, slot in ipairs(MACRO_SLOTS) do
        if svronly[slot] ~= nil then
            if self:_setMacroOps(slot, svronly[slot]) then changed = true end
        elseif complete and self.macros[slot]
            and not (type(names) == "table" and names[slot] ~= nil) then
            -- Mentioned by neither an operations array nor a name: gone.
            local had = #self.macros[slot].ops > 0
            self.macros[slot] = nil
            if had then changed = true end
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

    local slots
    if prefix == "" then
        slots = value.cal and value.cal.slots
    elseif prefix == "/cal" then
        slots = value.slots
    elseif prefix == "/cal/slots" then
        -- Accepting a replace of the array on its own is permissive INBOUND
        -- parsing, which is a different risk class from guessing an outbound
        -- call shape: if the unit never pushes at this granularity the branch
        -- simply never runs, and if it does, the slot names stay live instead
        -- of going stale until the next full document.
        slots = value
    end
    if slots and self:_setDiracSlots(slots) then changes.diracSlots = true end

    -- The whole document is a census and a targeted push is a fragment, and the
    -- macro container is the one place that distinction changes the outcome:
    -- only a complete document can say a slot no longer exists.
    local svronly, complete
    if prefix == "" then
        svronly, complete = value.svronly, true
    elseif prefix == "/svronly" then
        svronly, complete = value, false
    end
    if svronly and self:_setMacros(svronly, complete) then changes.macros = true end

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
--
-- `/status` also holds a `raw` sub-table of decoder internals (sample rate
-- enums, delay values, activity bitmasks, format codes) that this driver does
-- not read. It is deliberately absent from SCALAR_PATHS, so it is untouched by
-- a wholesale `/status` replace (only the named leaves above get re-derived)
-- and `isInteresting` never matches a path under `/status/raw/...` -- neither
-- path equals "/status" exactly, so a targeted push there is dropped before
-- any allocation. Tracking it wildcard-style would undo the entire reason
-- this driver projects rather than mirrors the ~38 KB document.
--
-- `/svronly` is the unit's own scratch container. It holds the macro slots and
-- their names, and other things this driver does not read; a wholesale replace
-- of it re-derives the macros and ignores the rest.
local CONTAINER_PREFIXES = { "/cal", "/cal/slots", "/upmix", "/versions", "/inputs",
                             "/status", "/videostat", "/svronly" }

-- True when `path` is a tracked scalar, a tracked input sub-path, a macro slot
-- or name, or a container holding any of them. Checked before any allocation,
-- so the thousands of paths this driver ignores cost a few hash lookups, at
-- most three anchored matches and a handful of equality tests -- no allocation,
-- so a busy device stays cheap.
local function isInteresting(path)
    if SCALAR_PATHS[path] then return "scalar" end
    if path == "" or path == "/" then return "container" end
    if path:match("^/inputs/[^/]+/label$") or path:match("^/inputs/[^/]+/visible$") then
        return "input"
    end
    -- Gated on one anchored find so the thousands of paths that are not macros
    -- pay a single test and, unlike a :sub() prefix compare, do not allocate a
    -- throwaway string apiece to do it -- which is the promise two lines up.
    if path:find("^/svronly/") then
        local rest = path:sub(10)
        if rest == "macroNames" then return "macroNames" end
        local named = rest:match("^macroNames/([^/]+)$")
        if named then return MACRO_SLOT_SET[named] and "macroName" or nil end
        return MACRO_SLOT_SET[rest] and "macroOps" or nil
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

    -- The three macro granularities the unit's own client patches at: one
    -- slot's operations, the whole name map, one name. Accepting all three is
    -- permissive INBOUND parsing, the same call made for /cal/slots above --
    -- and here it is what keeps a macro renamed or rewritten on the unit from
    -- going stale in Composer until the next reconnect, since this driver never
    -- polls for a fresh document.
    if interest == "macroOps" then
        if self:_setMacroOps(path:sub(10), removing and {} or operation.value) then
            changes.macros = true
        end
        return
    end

    if interest == "macroNames" then
        if self:_setMacroNames(operation.value) then changes.macros = true end
        return
    end

    if interest == "macroName" then
        local slot = path:match("([^/]+)$")
        local newName = removing and nil or operation.value
        if newName ~= nil and type(newName) ~= "string" then return end
        local entry = self:_macroEntry(slot)
        if entry.name ~= newName then
            entry.name = newName
            changes.macros = true
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

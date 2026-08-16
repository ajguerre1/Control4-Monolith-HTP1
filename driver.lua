-- Control4 entry points. This file is wiring: it builds the object graph and
-- forwards Control4's callbacks into it. Logic belongs in htp1/.

local Log       = require("htp1.log")
local Mapping   = require("htp1.mapping")
local State     = require("htp1.state")
local Transport = require("htp1.transport")
local Session   = require("htp1.session")
local Proxy     = require("htp1.proxy")

DRIVER = {}

--------------------------------------------------------------------------------
-- Property parsing
--------------------------------------------------------------------------------

-- "Unit maximum" means no cap of our own; "-20 dB" means -20.
local function parseMaxVolume(value)
    if value == nil or value == "Unit maximum" then return nil end
    return tonumber(value:match("(-?%d+)"))
end

local function parseRampMs(value)
    return tonumber((value or ""):match("(%d+)")) or 100
end

--------------------------------------------------------------------------------
-- Variables and events
--------------------------------------------------------------------------------

-- Every variable Composer sees, and how to compute it from live state. ONE
-- table drives both creation (AddVariable, at init) and every update
-- (SetVariable, from every change) -- a variable defined here but missing
-- from either call site is not a failure mode this shape allows.
--
-- Every function returns a string, never nil: a nil field must read as an
-- empty string, never the literal text "nil".
--
-- UNKNOWN IS EMPTY, and that distinction is the point. Before the first
-- document arrives -- and after a driver reload while the unit is still being
-- read -- these fields are genuinely unknown, not false. Reporting "Off" or
-- "false" there would be a determinate answer to a question nobody can answer
-- yet, and a program acting on it would act on a value the driver invented.
-- CONNECTED is the one variable that is always determinate, because whether
-- the driver has a live session is something it always knows.
local function boolText(value)
    if value == nil then return "" end
    return value and "true" or "false"
end

local function text(value)
    if value == nil then return "" end
    return tostring(value)
end

-- The unit's own label beats nothing; the Control4 connection name beats an
-- empty field. Task M2-T3 (input labels) reads Mapping.INPUTS for the same
-- reason -- extend this lookup rather than forking it.
-- An input the unit named but never described. A targeted /inputs/<key>/label
-- push for a key absent from the last document creates an entry with a label
-- and no visibility, and printing the literal "nil" there would read as a value.
local function visibleText(value)
    if value == nil then return "unknown" end
    return tostring(value)
end

local function inputLabelText(state)
    local key = state.fields.input
    if key == nil then return "" end
    local label = state:inputLabel(key)
    if label ~= nil then return label end
    for _, input in ipairs(Mapping.INPUTS) do
        if input.key == key then return input.name end
    end
    return ""
end

local VARIABLES = {
    -- Always determinate: the driver always knows whether it has a session.
    CONNECTED          = function(_, connected) return connected and "true" or "false" end,
    -- UNIT_POWER, not POWER_STATE. The receiver proxy owns a variable called
    -- POWER_STATE on this same device, and it is the one proxy variable with no
    -- output index -- a bare name we would be writing over. The driver also
    -- drives the proxy's copy, sending ON/OFF on every power change, so both
    -- would write one name in different encodings and whichever wrote last
    -- would win. Programming that read it would work until it silently didn't.
    UNIT_POWER         = function(state)
        if state.fields.power == nil then return "" end
        return state.fields.power and "On" or "Off"
    end,
    INPUT_ID           = function(state) return text(state.fields.input) end,
    INPUT_LABEL        = function(state) return inputLabelText(state) end,
    VOLUME_DB          = function(state) return text(state.fields.volume) end,
    VOLUME_PERCENT     = function(state)
        return text(Mapping.dbToPercent(state.fields.volume, state.fields.vpl, state.fields.vph))
    end,
    MUTED              = function(state) return boolText(state.fields.muted) end,
    -- The unit's own text, richer than the Control4 surround id: it reads
    -- "Native Dolby ATMOS" where the proxy only knows "Dolby Surround".
    SURROUND_MODE      = function(state) return text(state.fields.surroundMode) end,
    INPUT_FORMAT       = function(state) return text(state.fields.decSourceProgram) end,
    INPUT_PROGRAM      = function(state) return text(state.fields.decProgramFormat) end,
    INPUT_SAMPLE_RATE  = function(state) return text(state.fields.decSampleRate) end,
    OUTPUT_FORMAT      = function(state) return text(state.fields.encListeningFormat) end,
    OUTPUT_SAMPLE_RATE = function(state) return text(state.fields.encSampleRate) end,
    VIDEO_RESOLUTION   = function(state) return text(state.fields.videoResolution) end,
    VIDEO_COLORSPACE   = function(state) return text(state.fields.videoColorSpace) end,
    VIDEO_HDR          = function(state) return text(state.fields.videoHdr) end,
    DIRAC_STATE        = function(state) return text(state.fields.diracState) end,
    -- Control for all six arrives in later M3 tasks; these are read-only
    -- projections of what the unit already pushes, same as DIRAC_STATE above.
    LOUDNESS           = function(state) return text(state.fields.loudness) end,
    NIGHT_MODE         = function(state) return text(state.fields.night) end,
    DIALOG_ENHANCE     = function(state) return text(state.fields.dialogEnhance) end,
    BASS_ENHANCE       = function(state) return text(state.fields.bassEnhance) end,
    DIRAC_SLOT         = function(state) return text(state.fields.diracSlot) end,
    LIP_SYNC_MS        = function(state) return text(state.fields.lipSync) end,
}

-- Names as fired by C4:FireEvent. tests/test_manifest.lua asserts this list
-- and driver.xml's <events> block name the same six events, in both
-- directions, so a declared-but-never-fired (or fired-but-undeclared) event
-- cannot slip in unnoticed.
local EVENTS = {
    CONNECTED             = "Connected",
    DISCONNECTED          = "Disconnected",
    POWERED_ON            = "Powered On",
    POWERED_OFF           = "Powered Off",
    INPUT_CHANGED         = "Input Changed",
    SURROUND_MODE_CHANGED = "Surround Mode Changed",
}
DRIVER.EVENTS = EVENTS -- for tests; the code below always uses the local.

-- Names only, for the documentation check in tests/test_manifest.lua. Exposing
-- the VARIABLES table itself would let a test assert the driver against itself;
-- the names are what the documentation has to keep up with.
DRIVER.VARIABLE_NAMES = {}
for name in pairs(VARIABLES) do table.insert(DRIVER.VARIABLE_NAMES, name) end
table.sort(DRIVER.VARIABLE_NAMES)

local function initVariables()
    DRIVER.varCache, DRIVER.varCreated = {}, {}
    local connected = DRIVER.session and DRIVER.session.connected or false
    for name, fn in pairs(VARIABLES) do
        local value = fn(DRIVER.state, connected)
        -- Read-only, and isolated. Read-only because an external write would
        -- desynchronise varCache: the cache would still hold our last value, so
        -- we would not rewrite until the computed value moved, and the variable
        -- could read wrong indefinitely.
        --
        -- Isolated because this loop runs under pairs(), whose order is
        -- unspecified: one failure without a pcall would abort it partway and
        -- leave an arbitrary, reload-varying subset of the created variables,
        -- while varCache claimed all of them existed. It would also skip the
        -- Driver Version update below, so a successful install would still
        -- report the old version in Composer.
        local ok, err = pcall(function()
            C4:AddVariable(name, value, "STRING", true)
        end)
        if ok then
            DRIVER.varCreated[name] = true
            DRIVER.varCache[name] = value
        else
            -- Not created, so never updated. Without this the driver would
            -- write to a name that does not exist, silently, on every change
            -- for the life of the driver.
            DRIVER.log:error("could not create variable " .. name .. ": " .. tostring(err))
        end
    end
end

-- Writes only what actually moved since the last write: Director sees every
-- SetVariable, and this driver's stated budget for noise is zero redundant
-- ones. Recomputing the full table each time -- rather than mapping a changed
-- field to the one variable it affects -- is what lets this stay a single
-- source of truth: several variables (VOLUME_PERCENT, INPUT_LABEL) depend on
-- more than one field, and a hand-maintained field-to-variable map is exactly
-- the kind of second list that could drift from the first.
local function updateVariables(connected)
    for name, fn in pairs(VARIABLES) do
        local value = fn(DRIVER.state, connected)
        if DRIVER.varCreated[name] and DRIVER.varCache[name] ~= value then
            DRIVER.varCache[name] = value
            C4:SetVariable(name, value)
        end
    end
end

-- Power, input and surround mode only count as a transition when the PRIOR
-- value was itself known. The first document turns a nil into a real value
-- for all three, and that is discovery, not a transition -- the Connected
-- event above already reports it, so re-announcing it here as e.g. "Powered
-- On" would be a second, redundant signal for the same moment.
local function fireStateEvents(changes)
    local fields = DRIVER.state.fields

    if changes.power then
        local now = fields.power
        if DRIVER.prevPower == false and now == true then
            C4:FireEvent(EVENTS.POWERED_ON)
        elseif DRIVER.prevPower == true and now == false then
            C4:FireEvent(EVENTS.POWERED_OFF)
        end
        DRIVER.prevPower = now
    end

    if changes.input then
        local now = fields.input
        if DRIVER.prevInput ~= nil and now ~= DRIVER.prevInput then
            C4:FireEvent(EVENTS.INPUT_CHANGED)
        end
        DRIVER.prevInput = now
    end

    if changes.surroundMode then
        local now = fields.surroundMode
        if DRIVER.prevSurroundMode ~= nil and now ~= DRIVER.prevSurroundMode then
            C4:FireEvent(EVENTS.SURROUND_MODE_CHANGED)
        end
        DRIVER.prevSurroundMode = now
    end
end

--------------------------------------------------------------------------------
-- Dirac Filter picker
--------------------------------------------------------------------------------

-- One label per slot, in the order C4:UpdatePropertyList wants: a comma-
-- separated string, not a table. Labelled by the WIRE index (0-based) rather
-- than diracSlots' 1-based Lua position, so the number an installer sees here
-- is the same number DIRAC_SLOT reports and /cal/currentdiracslot uses -- no
-- translation for anyone comparing the two.
local function diracFilterEntry(wireIndex, name)
    if name ~= nil and name ~= "" then
        return wireIndex .. " - " .. name
    end
    return wireIndex .. " - Slot " .. wireIndex
end

-- Returns the full comma-separated item list and the text of the entry
-- matching state.fields.diracSlot (nil if the current slot is unknown or out
-- of range).
local function diracFilterItems()
    local items, selectedText = {}, nil
    local selectedSlot = DRIVER.state.fields.diracSlot
    for i, entry in ipairs(DRIVER.state.diracSlots) do
        local wireIndex = i - 1
        local text = diracFilterEntry(wireIndex, entry.name)
        table.insert(items, text)
        if selectedSlot == wireIndex then selectedText = text end
    end
    return items, selectedText
end

-- Repopulates the whole list rather than editing one entry: UpdatePropertyList
-- always wants the complete set, so "a name changed" and "the selection
-- changed" are the same call. Called from onChanges below whenever
-- changes.diracSlots or changes.diracSlot fires -- which includes the first
-- document, since both start out empty/nil.
-- The unit's Fast Start setting, shown as a read-only property.
--
-- Reported only, never set: whether the unit wakes quickly is a unit setting,
-- and a room control has no business changing it. Shown because it is the
-- difference between an ON command taking a moment and taking the better part
-- of a minute.
--
-- Empty until the unit has been read, like every other unknown in this driver:
-- "Off" would be a determinate answer to a question nobody can answer yet.
local function updateFastStartProperty()
    local value = DRIVER.state.fields.fastStart
    if value == nil then
        C4:UpdateProperty("Fast Start", "")
        return
    end
    C4:UpdateProperty("Fast Start", value == "on" and "On" or "Off")
end

local function updateDiracFilterProperty()
    local items, selectedText = diracFilterItems()
    if #items == 0 then return end -- nothing reported yet; leave the property alone
    C4:UpdatePropertyList("Dirac Filter", table.concat(items, ","), selectedText or "")
end

--------------------------------------------------------------------------------
-- Macros
--------------------------------------------------------------------------------

-- The unit stores macros in fixed slots and this driver only ever REPLAYS them.
-- There is no "run macro" verb on the wire: a macro is an array of JSON-patch
-- operations the owner saved on the unit, and running one means sending those
-- operations back as a changemso -- exactly what the unit's own web client
-- does. Nothing here can create, edit, rename or delete a macro; the unit's own
-- UI owns all of that.

-- A real, always-present first entry that deliberately does nothing.
--
-- It exists because the driver cannot stop Composer falling back to the first
-- item when the selected one is gone -- so the fix is to make the first item
-- HARMLESS rather than to argue with the platform. A macro deleted on the unit
-- must not promote a different macro into its place: an action that quietly
-- starts running something else is worse than one that runs nothing, because
-- nothing about the room announces which macro just fired.
local MACRO_NONE = "(none)"

-- What one slot reads as in Composer's list: the unit's own name for it,
-- falling back to the slot key when the owner never named it.
--
-- Commas are replaced because C4:UpdatePropertyList takes the whole list as one
-- COMMA-SEPARATED STRING -- a macro whose name contains a comma would otherwise
-- arrive in Composer as two entries, neither of them selectable. The
-- substitution is display-only: runMacro still accepts the unit's real name,
-- commas and all.
--
-- A macro the owner named literally "(none)" also falls back to its slot key,
-- for the same reason as the comma: an entry whose text collides with the
-- sentinel would be a row the picker cannot tell from "nothing selected", so it
-- would list twice and be unselectable. Under its slot key it stays reachable.
local function macroEntryText(slot, name)
    if name == nil or name == "" or name == MACRO_NONE then return slot end
    return (name:gsub(",", " "))
end

-- Forward declaration: updateMacroProperty below needs to resolve the text
-- Composer persisted across a driver reload, and the resolver needs
-- macroEntryText above. Declared here rather than reordering the file, so the
-- two picker sections stay next to each other.
local resolveMacroByListedText

-- Only slots that actually hold operations. A slot the owner named but left
-- empty is deliberately absent: it would look like a control and do nothing.
local function macroItems()
    local items = {}
    for _, slot in ipairs(State.MACRO_SLOTS) do
        local entry = DRIVER.state.macros[slot]
        if entry and #entry.ops > 0 then
            table.insert(items, macroEntryText(slot, entry.name))
        end
    end
    return items
end

-- Repopulates the whole list, like the Dirac picker above.
--
-- THE SELECTION IS KEPT BY SLOT, NOT BY THE TEXT SHOWN -- the same thing the
-- Dirac picker gets right by construction, since its selection is an index. A
-- macro renamed on the unit is still the macro the installer chose, so their
-- Run Selected Macro programming must keep working across a rename; matching on
-- display text would quietly drop the selection the moment the owner edited a
-- name, and the installer would find their action doing nothing with no clue
-- why. DRIVER.macroSlot is what makes that possible -- see OnPropertyChanged.
--
-- Where the chosen slot is GONE, the selection falls to MACRO_NONE and never to
-- another macro: see that constant for why the sentinel is an entry rather than
-- an empty string.
--
-- Populates even when the unit stores no macros at all, unlike the Dirac picker
-- which leaves its property alone. The two differ because their empty states
-- differ: Dirac's six slots always exist, so "nothing reported yet" only ever
-- means the driver has not heard, and blanking a live picker on a momentary
-- gap would be a lie. A unit with no macros, by contrast, genuinely has none,
-- and a list of MACRO_NONE alone says exactly that.
--
-- No feedback loop to guard against here, unlike the Dirac picker: selecting a
-- macro selects it and nothing more. Running one is an explicit action, so
-- Composer echoing this call back as a property change cannot reach the unit.
local function updateMacroProperty()
    local items = macroItems()

    -- Nothing remembered means a fresh driver load: DRIVER.macroSlot is gone
    -- but Composer still holds the text it persisted, so recover the slot from
    -- that. This is the one moment text matching is right -- nothing can have
    -- been renamed while the driver was not running to see it.
    local slot = DRIVER.macroSlot
    if slot == nil then slot = resolveMacroByListedText(Properties["Macro"]) end

    local entry = slot and DRIVER.state.macros[slot]
    local kept = (entry and #entry.ops > 0) and macroEntryText(slot, entry.name) or nil
    DRIVER.macroSlot = kept and slot or nil

    table.insert(items, 1, MACRO_NONE)
    C4:UpdatePropertyList("Macro", table.concat(items, ","), kept or MACRO_NONE)
end

-- For the Run Macro COMMAND, where a programmer typed the request: accepts the
-- unit's own name for a macro, the text shown in the list, or the slot key. A
-- name is the likely case; a slot key is the unambiguous one, so it wins where
-- the two could collide -- an owner may name a macro "cmdcustom1", and someone
-- typing that string into programming means the slot. Two macros sharing one
-- name resolve to the earlier slot -- arbitrary, but deterministic.
local function resolveMacroSlot(request)
    if type(request) ~= "string" or request == "" then return nil end
    if request == MACRO_NONE then return nil end
    local byKey, byName, byText
    for _, slot in ipairs(State.MACRO_SLOTS) do
        local entry = DRIVER.state.macros[slot]
        if entry then
            if not byKey and slot == request then byKey = slot end
            if not byName and entry.name == request then byName = slot end
            if not byText and macroEntryText(slot, entry.name) == request then byText = slot end
        end
    end
    return byKey or byName or byText
end

-- For the Run Selected Macro ACTION, which has something different in hand: not
-- a typed request but the DISPLAY TEXT of an entry this driver itself put in
-- the list. For that, text is authoritative by construction -- it is the only
-- thing Composer can hand back -- so matching anything else can only pick a
-- different macro than the one shown. Same slot order and same first-match rule
-- as macroItems(): the FIRST slot whose display text matches wins. Where two
-- slots render the same text -- two macros the owner gave one name, or a macro
-- named exactly another slot's key -- both rows therefore resolve to the
-- earlier slot, and the later row is unreachable. Composer hands back text and
-- nothing else, so there is nothing here to tell the two rows apart.
function resolveMacroByListedText(text)   -- forward-declared local, above
    if type(text) ~= "string" or text == "" then return nil end
    -- Belt and braces, and deliberately kept as such: macroEntryText can no
    -- longer return the sentinel for any slot, so the loop below would return
    -- nil here anyway and no test can distinguish this line's presence. It
    -- stays because it states the rule locally -- the sentinel is not a macro
    -- -- rather than leaving it to hold only as long as a function three
    -- sections away keeps its collision fallback. The command's counterpart in
    -- resolveMacroSlot IS load-bearing: that one also matches raw names.
    if text == MACRO_NONE then return nil end
    for _, slot in ipairs(State.MACRO_SLOTS) do
        local entry = DRIVER.state.macros[slot]
        if entry and #entry.ops > 0 and macroEntryText(slot, entry.name) == text then
            return slot
        end
    end
    return nil
end

-- REPLAYS THE OWNER'S OWN STORED INTENT, and that is worth saying out loud:
-- this is the one place the driver sends paths it did not choose. A macro can
-- touch anything the unit's own web client can, and second-guessing which of
-- those paths are allowed would break the owner's own macro for no benefit --
-- the unit remains the authority on what it will accept. What the driver will
-- not do is forward an entry it cannot replay -- htp1/state.lua keeps only
-- `replace` on the way in, because that is the only kind this write path can
-- send -- or send an empty changemso, which this codec would encode as {}
-- rather than [] and the unit would reject outright. Skipping is not silent:
-- how many entries a slot lost is counted at ingest and reported below.
--
-- Session:write is the right tool, and no batch call is needed: writes queue by
-- path and flush together 50 ms later, so every path a macro touches goes out
-- in ONE changemso, and a macro touching one path twice sends only the later
-- value -- sending both would be a write the second immediately overwrites.
local function runMacro(request, label, resolve)
    local slot = (resolve or resolveMacroSlot)(request)
    if not slot then
        -- "Nothing was asked for" is a different report from "what you asked
        -- for is not there", and the wording has to suit the caller: the action
        -- has a SELECTION, the command has a typed parameter. Telling a
        -- programmer that "no macro is selected" would send them looking at a
        -- property they were not using.
        if request == nil or request == "" or request == MACRO_NONE then
            if resolve == resolveMacroByListedText then
                DRIVER.log:debug(label .. ": no macro is selected, so nothing was run")
            else
                DRIVER.log:debug(label .. ": no macro was given, so nothing was run")
            end
        else
            DRIVER.log:debug(label .. ": no macro named", tostring(request))
        end
        return
    end
    local entry = DRIVER.state.macros[slot]
    local ops, dropped = entry.ops, entry.dropped or 0

    -- DELIBERATELY NOT behind Debug Mode, unlike every other line in here. The
    -- shipping default is Off, and a macro that ran in part is precisely what an
    -- owner cannot notice on their own: one button, and some of what they saved.
    -- `error` is this logger's only always-written level, so it is the one an
    -- installer actually sees -- no new level invented for one message. The slot
    -- key is a fixed name of the unit's own; the macro's NAME is site data and
    -- stays out of a log that leaves this machine.
    if dropped > 0 then
        DRIVER.log:error(label .. ": macro " .. slot .. " ran " .. #ops .. " of " ..
            (#ops + dropped) .. " stored entries -- the rest are entries this driver " ..
            "cannot replay. Only `replace` operations are sent: the write path sends " ..
            "values, so it cannot express a delete.")
    end

    if #ops == 0 then
        DRIVER.log:debug(label .. ": macro", slot, "has no stored operations to replay")
        return
    end
    DRIVER.log:debug(label .. ": replaying", #ops, "stored operation(s) from", slot)
    for _, op in ipairs(ops) do
        DRIVER.session:write(op.path, op.value)
    end
end

--------------------------------------------------------------------------------
-- Error handling
--------------------------------------------------------------------------------

-- Handlers are wrapped so a Lua fault cannot take the driver down, but nothing
-- is swallowed: every caught error is logged with its traceback. A silent
-- handler failure is worse than a crash, because it looks like success.
local function guard(name, fn, ...)
    local args = { ... }
    local ok, err = xpcall(function() return fn(unpack(args)) end, debug.traceback)
    if not ok then
        if DRIVER.log then
            DRIVER.log:error(name .. " failed: " .. tostring(err))
        else
            print("HTP-1: " .. name .. " failed: " .. tostring(err))
        end
        return nil
    end
    return err
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

-- The normal Composer order is: add the driver, THEN set its IP. Reading this
-- once at construction would leave self.host == "" for the driver's entire
-- life if the first connect attempt lands before the address is set, so the
-- transport calls this again on every connect() instead of trusting a cached
-- value.
local function readHost()
    local ok, address = pcall(function()
        return C4:GetBindingAddress(Mapping.NETWORK_BINDING)
    end)
    if ok and type(address) == "string" then return address end
    return ""
end

local function buildDriver()
    -- Two HTP-1 instances on one controller share Lua's default, deterministic
    -- seed unless something breaks the tie: without this, both instances draw
    -- the identical jitter sequence and reconnect in lockstep after a shared
    -- network blip -- precisely what the jitter in transport.lua exists to
    -- prevent. Must run before the transport (and its jitter closure) exists.
    -- Guarded like the binding-address read: this is the first statement of the
    -- constructor, so a nil or non-numeric return would kill the whole object
    -- graph and leave every later entry point erroring on a nil DRIVER.
    pcall(function() math.randomseed(C4:GetDeviceID()) end)

    local log = Log.new("HTP-1")
    log:setMode(Properties["Debug Mode"])

    local state = State.new()

    local transport = Transport.new({
        binding = Mapping.NETWORK_BINDING,
        port = 80,
        hostProvider = readHost,
        path = "/ws/controller",
        log = log,
        onOpen    = function() DRIVER.session:onOpen() end,
        onMessage = function(text) DRIVER.session:onMessage(text) end,
        onClose   = function(reason) DRIVER.session:onClose(reason) end,
    })

    local session = Session.new({
        transport = transport,
        state = state,
        log = log,
        onChanges = function(changes) DRIVER.onChanges(changes) end,
        onConnected = function(connected) DRIVER.onConnected(connected) end,
    })

    local proxy = Proxy.new({
        state = state,
        session = session,
        log = log,
        maxVolumeDb = parseMaxVolume(Properties["Maximum Volume"]),
        rampMs = parseRampMs(Properties["Volume Ramp Rate"]),
        powerOffAction = Properties["Power Off Action"],
    })

    DRIVER.log, DRIVER.state = log, state
    DRIVER.transport, DRIVER.session, DRIVER.proxy = transport, session, proxy
    DRIVER.prevPower, DRIVER.prevInput, DRIVER.prevSurroundMode = nil, nil, nil
    initVariables()
end

-- Connected/Disconnected fire from here, not from the change set: the session
-- already guarantees onConnected only runs on a genuine transport transition
-- (see htp1/session.lua), so no further "did this really change" check
-- belongs here.
function DRIVER.onConnected(connected)
    C4:UpdateProperty("Connection Status", connected and "Connected" or "Not connected")
    updateVariables(connected)
    C4:FireEvent(connected and EVENTS.CONNECTED or EVENTS.DISCONNECTED)
    if not connected then return end

    -- RE-ANCHOR THE MACRO SELECTION AGAINST THE DOCUMENT WE JUST READ.
    --
    -- DRIVER.macroSlot remembers WHICH SLOT the installer chose, so a rename on
    -- the unit does not lose their selection. But a slot is only a reliable
    -- handle while the driver is watching every msoupdate. Across an outage the
    -- owner can delete the chosen macro and record a different one into the
    -- same slot, and the remembered slot would then hand the selection -- and
    -- Run Selected Macro -- to a macro they never picked.
    --
    -- Here, and only here, the persisted TEXT is the better handle: this runs
    -- after applyDocument and before onChanges (see htp1/session.lua), so
    -- state.macros already holds the fresh document while Properties["Macro"]
    -- still holds the pre-outage choice -- exactly the two things to compare.
    -- If the name is still there it re-anchors; if it is not, the selection
    -- falls to the sentinel rather than to a stranger.
    --
    -- Clearing to nil instead would NOT work, and the difference is subtle: a
    -- reconnect that changed nothing reports no macro changes, so
    -- updateMacroProperty never runs to re-resolve it. The nil would sit until
    -- the next rename -- the one moment the stored text and the fresh state are
    -- guaranteed to disagree -- and the selection would be dropped then.
    --
    -- Only on a genuine transport transition: session.lua calls onConnected
    -- when it was not connected, so a Refresh From Device on a driver that
    -- never went away does not re-anchor, and should not. That driver saw
    -- every push, and its slot is the trustworthy handle.
    DRIVER.macroSlot = resolveMacroByListedText(Properties["Macro"])

    C4:UpdateProperty("System Software Version", DRIVER.state.fields.systemVersion or "")
    C4:UpdateProperty("AV Controller Version", DRIVER.state.fields.avControllerVersion or "")
    C4:UpdateProperty("Serial Number", DRIVER.state.fields.serial or "")
    updateFastStartProperty()
    DRIVER.proxy:announce()
end

function DRIVER.onChanges(changes)
    -- The proxy first, and deliberately. This is the call M1 depends on for
    -- volume, mute and input feedback in Navigator, and it is already proven on
    -- hardware. The variables and events are new: a fault in them must not be
    -- able to starve the thing that already works, so they run after and behind
    -- their own guard.
    DRIVER.proxy:notify(changes)

    guard("variables", function()
        updateVariables(DRIVER.session.connected)
        fireStateEvents(changes)
    end)

    -- Its own guard, behind the same reasoning as the variables block above: a
    -- fault repopulating the Composer property must not be able to take the
    -- proxy or the variables down with it.
    guard("dirac filter property", function()
        if changes.diracSlots or changes.diracSlot then
            updateDiracFilterProperty()
        end
    end)

    -- Its own guard again, and not folded into the block above: two independent
    -- lists, and a fault repopulating one must not be able to stop the other.
    guard("macro property", function()
        if changes.macros then updateMacroProperty() end
        if changes.fastStart then updateFastStartProperty() end
    end)
end

function OnDriverInit()
    guard("OnDriverInit", function()
        buildDriver()
        C4:UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
    end)
end

function OnDriverLateInit()
    guard("OnDriverLateInit", function()
        DRIVER.session:start()
    end)
end

function OnDriverDestroyed()
    guard("OnDriverDestroyed", function()
        if DRIVER.session then DRIVER.session:stop() end
        if DRIVER.proxy then DRIVER.proxy:stop() end
    end)
end

--------------------------------------------------------------------------------
-- Composer
--------------------------------------------------------------------------------

local PROPERTY_HANDLERS = {
    ["Debug Mode"] = function(value) DRIVER.log:setMode(value) end,
    ["Maximum Volume"] = function(value)
        DRIVER.proxy:setMaxVolumeDb(parseMaxVolume(value))
        DRIVER.proxy:announce()
    end,
    ["Volume Ramp Rate"] = function(value) DRIVER.proxy:setRampMs(parseRampMs(value)) end,
    ["Power Off Action"] = function(value) DRIVER.proxy:setPowerOffAction(value) end,
    -- Composer delivers the selected entry's full text, "<wire index> - <name>",
    -- not a bare number -- parse the LEADING DIGITS with a pattern, not a single
    -- character: a one-character parse silently breaks from slot 10 up, and
    -- while this unit only has six slots today, that bug is not worth carrying
    -- into whichever driver copies this shape next.
    ["Dirac Filter"] = function(value)
        local slot = tonumber((value or ""):match("^(%d+)"))
        if not slot then
            DRIVER.log:debug("Dirac Filter: could not parse a slot index from", tostring(value))
            return
        end
        if DRIVER.state.fields.diracSlot == slot then
            -- GUARDS THE FEEDBACK LOOP. This handler cannot tell an installer's
            -- own selection apart from Composer echoing back the driver's own
            -- updateDiracFilterProperty() call (the unit's push repopulating
            -- the list is exactly that call) -- both arrive here the same way.
            -- What distinguishes a real request is that it asks for a slot
            -- other than the one the unit already reports. Same shape as the
            -- volume "already there" guard in htp1/proxy.lua's _setVolumeDb.
            return
        end
        DRIVER.session:write("/cal/currentdiracslot", slot)
    end,
    -- Records WHICH SLOT the installer picked, and writes nothing. Selecting a
    -- macro must never reach the unit -- running one is the action's job -- so
    -- this handler exists purely so a later repopulation can keep the selection
    -- on the same macro after the owner renames it on the unit. Composer
    -- echoing the driver's own UpdatePropertyList back through here resolves to
    -- the same slot, which is why the echo is harmless and needs no guard.
    ["Macro"] = function(value)
        DRIVER.macroSlot = resolveMacroByListedText(value)
    end,
}

function OnPropertyChanged(name)
    guard("OnPropertyChanged(" .. tostring(name) .. ")", function()
        local handler = PROPERTY_HANDLERS[name]
        if handler then handler(Properties[name]) end
    end)
end

local ACTIONS = {
    REFRESH_FROM_DEVICE = function() DRIVER.session:refresh() end,
    -- Runs whatever the Macro property currently shows. Reading the property
    -- here rather than caching a selection keeps one source of truth: Composer
    -- owns what the installer chose. Resolved BY THAT TEXT, because the text is
    -- all this action has and all Composer can give it.
    RUN_SELECTED_MACRO = function()
        runMacro(Properties["Macro"], "Run Selected Macro", resolveMacroByListedText)
    end,
    PRINT_STATE = function()
        print("HTP-1 state:")
        for key, value in pairs(DRIVER.state.fields) do
            print("  " .. key .. " = " .. tostring(value))
        end
        print("  connected = " .. tostring(DRIVER.session.connected))
    end,
    -- The driver cannot rename Control4's connections -- there is no DriverWorks
    -- call for it (see the requirements doc for the evidence) -- so it reports
    -- the unit's labels instead of promising to apply them. Mapped inputs print
    -- in Mapping.INPUTS' declared order; inputs the unit reported that this
    -- driver does not model (Roon has no Control4 connection) print after,
    -- sorted by key. Either half of pairs(DRIVER.state.inputs) is
    -- iteration-order-unstable in Lua, so both halves are put into a stable
    -- order explicitly rather than left to pairs().
    PRINT_INPUT_LABELS = function()
        print("HTP-1 input labels:")
        local inputs = DRIVER.state.inputs
        local seen = {}

        for _, mapped in ipairs(Mapping.INPUTS) do
            local entry = inputs[mapped.key]
            if entry then
                seen[mapped.key] = true
                print(string.format(
                    "  connection %d (%s): key=%s label=%s visible=%s",
                    mapped.binding, mapped.name, mapped.key,
                    tostring(entry.label or ""), visibleText(entry.visible)))
            end
        end

        local unmappedKeys = {}
        for key in pairs(inputs) do
            if not seen[key] then table.insert(unmappedKeys, key) end
        end
        table.sort(unmappedKeys)

        for _, key in ipairs(unmappedKeys) do
            local entry = inputs[key]
            print(string.format(
                "  no Control4 connection: key=%s label=%s visible=%s",
                key, tostring(entry.label or ""), visibleText(entry.visible)))
        end
    end,
}

--------------------------------------------------------------------------------
-- Programming commands
--------------------------------------------------------------------------------

-- Declared in <commands>. Unlike the Actions tab, Composer delivers one of
-- these with the command's own declared name as `command` -- never
-- "LUA_ACTION" -- and parameters keyed by each <param><name>. Every
-- parameter arrives as a string, so every numeric one goes through tonumber,
-- and every LIST one is checked against its declared domain: the unit is the
-- ultimate authority on a value, but nonsense earns a log line here rather
-- than a write.
local DIRAC_MODES = { Off = "off", On = "on", Bypass = "bypass" }
local NIGHT_MODES = { Off = "off", Auto = "auto", On = "on" }
local ONOFF_MODES = { Off = "off", On = "on" }

local PROGRAMMING_COMMANDS = {}

-- Named "Set Dirac Processing" rather than "Set Dirac" because "Set Dirac Slot"
-- exists too: one turns Dirac on, off or into bypass, the other picks which
-- calibrated filter it runs. A name that is a strict prefix of another names
-- nothing in a programming dropdown -- and both commands are new in this
-- release, so this is the last moment the rename costs an installed program
-- nothing.
PROGRAMMING_COMMANDS["Set Dirac Processing"] = function(params)
    local value = DIRAC_MODES[params.Mode]
    if not value then
        DRIVER.log:debug("Set Dirac Processing: unrecognised Mode", tostring(params.Mode))
        return
    end
    DRIVER.session:write("/cal/diracactive", value)
end

PROGRAMMING_COMMANDS["Set Night Mode"] = function(params)
    local value = NIGHT_MODES[params.Mode]
    if not value then
        DRIVER.log:debug("Set Night Mode: unrecognised Mode", tostring(params.Mode))
        return
    end
    DRIVER.session:write("/night", value)
end

PROGRAMMING_COMMANDS["Set Dialog Enhance"] = function(params)
    local level = tonumber(params.Level)
    if not level or level < 0 or level > 6 then
        DRIVER.log:debug("Set Dialog Enhance: Level out of range 0-6:", tostring(params.Level))
        return
    end
    DRIVER.session:write("/dialogEnh", level)
end

PROGRAMMING_COMMANDS["Set Bass Enhance"] = function(params)
    local value = ONOFF_MODES[params.Mode]
    if not value then
        DRIVER.log:debug("Set Bass Enhance: unrecognised Mode", tostring(params.Mode))
        return
    end
    DRIVER.session:write("/bassenhance", value)
end

PROGRAMMING_COMMANDS["Toggle Bass Enhance"] = function()
    local next = (DRIVER.state.fields.bassEnhance == "on") and "off" or "on"
    DRIVER.session:write("/bassenhance", next)
end

PROGRAMMING_COMMANDS["Set Lip Sync Delay"] = function(params)
    local delay = tonumber(params.Delay)
    if not delay or delay < 0 or delay > 340 then
        DRIVER.log:debug("Set Lip Sync Delay: Delay out of range 0-340:", tostring(params.Delay))
        return
    end
    DRIVER.session:write("/cal/lipsync", delay)
    -- The vendor's own web client writes the calibration value and the
    -- currently selected input's own delay together; writing only the first
    -- would leave the driver disagreeing with the unit's own display for that
    -- input. Skipped when no input is known yet, rather than building a path
    -- with a nil key.
    local input = DRIVER.state.fields.input
    if input ~= nil then
        DRIVER.session:write("/inputs/" .. input .. "/delay", delay)
    end
end

-- For programming that wants a slot by number. No already-there guard here,
-- unlike the "Dirac Filter" property handler above: a programming command is
-- always an explicit ask, never Composer echoing the driver's own write back,
-- so it writes unconditionally -- the same convention every other command in
-- this table already follows.
PROGRAMMING_COMMANDS["Set Dirac Slot"] = function(params)
    local slot = tonumber(params.Slot)
    if not slot or slot < 0 or slot > 5 then
        DRIVER.log:debug("Set Dirac Slot: Slot out of range 0-5:", tostring(params.Slot))
        return
    end
    DRIVER.session:write("/cal/currentdiracslot", slot)
end

-- A STRING parameter, not a LIST: the macros a unit holds are its own, and a
-- fixed list declared in driver.xml could only be wrong. The name the owner
-- gave the macro is the likely thing to type; the slot key (cmda, preset1,
-- cmdcustom3) is accepted too, for programming that wants to name a macro
-- without depending on what it is currently called.
PROGRAMMING_COMMANDS["Run Macro"] = function(params)
    runMacro(params.Macro, "Run Macro")
end

-- Names only, for the manifest test's coverage check -- same pattern as
-- DRIVER.VARIABLE_NAMES above.
DRIVER.PROGRAMMING_COMMAND_NAMES = {}
for name in pairs(PROGRAMMING_COMMANDS) do
    table.insert(DRIVER.PROGRAMMING_COMMAND_NAMES, name)
end
table.sort(DRIVER.PROGRAMMING_COMMAND_NAMES)

-- Composer's Actions tab does NOT send an action's <command> as the command.
-- It sends the literal "LUA_ACTION", with the declared name in tParams.ACTION.
-- Dispatching on the command alone matched nothing and returned in silence, so
-- every action in this driver did nothing at all and said nothing about it.
--
-- A programming command declared in <commands> arrives the other way: the
-- command IS the declared name, spaces and all, never wrapped in LUA_ACTION.
-- Both forms are tried here, plus a space-stripped variant of the name as a
-- defensive fallback some shipped drivers also rely on -- it costs one more
-- table lookup.
function ExecuteCommand(command, params)
    guard("ExecuteCommand(" .. tostring(command) .. ")", function()
        params = params or {}

        local name = command
        if command == "LUA_ACTION" then name = params.ACTION end

        local handler = ACTIONS[name] or PROGRAMMING_COMMANDS[name]
        if not handler and type(name) == "string" then
            local stripped = name:gsub(" ", "")
            handler = ACTIONS[stripped] or PROGRAMMING_COMMANDS[stripped]
        end

        if handler then
            handler(params)
            return
        end

        -- Never silent again. An unrecognised action is a wiring bug, and this
        -- one hid behind a no-op through two releases and a field install.
        print("HTP-1: no handler for action " .. tostring(name) ..
            " (command " .. tostring(command) .. ")")
    end)
end

--------------------------------------------------------------------------------
-- Proxy and network callbacks
--------------------------------------------------------------------------------

function ReceivedFromProxy(binding, command, params)
    return guard("ReceivedFromProxy(" .. tostring(command) .. ")", function()
        return DRIVER.proxy:handle(binding, command, params)
    end)
end

function OnConnectionStatusChanged(binding, port, status)
    guard("OnConnectionStatusChanged", function()
        if binding ~= Mapping.NETWORK_BINDING then return end
        DRIVER.transport:onConnectionStatus(status)
    end)
end

-- Fires when a binding's target changes in Composer -- in particular, when the
-- network binding's IP is set for the first time after the driver was added
-- with none. connect() already no-ops while a connection attempt is live, so
-- this only matters while the transport is genuinely idle or waiting on a
-- still-empty address.
-- The installer has just given us an address, so drop back to the first rung:
-- an unconfigured driver will have ratcheted the ladder to its 60 s cap, and
-- making someone wait a minute after they finally typed the IP is the wrong
-- first impression.
local function onNetworkBindingChanged(idBinding)
    if idBinding ~= Mapping.NETWORK_BINDING then return end
    DRIVER.transport:resetBackoff()
    DRIVER.transport:connect()
end

function OnBindingChanged(idBinding, class, bIsBound)
    guard("OnBindingChanged", function() onNetworkBindingChanged(idBinding) end)
end

-- DriverWorks signals a network binding through its own callback rather than
-- the control/AV one above. Which of the two fires is not settled without
-- hardware, so both are defined and both are idempotent.
function OnNetworkBindingChanged(idBinding, bIsBound)
    guard("OnNetworkBindingChanged", function() onNetworkBindingChanged(idBinding) end)
end

function ReceivedFromNetwork(binding, port, data)
    guard("ReceivedFromNetwork", function()
        if binding ~= Mapping.NETWORK_BINDING then return end
        DRIVER.transport:onData(data)
    end)
end

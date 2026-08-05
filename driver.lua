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
        -- leave an arbitrary, reload-varying subset of the seventeen created,
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

    C4:UpdateProperty("System Software Version", DRIVER.state.fields.systemVersion or "")
    C4:UpdateProperty("AV Controller Version", DRIVER.state.fields.avControllerVersion or "")
    C4:UpdateProperty("Serial Number", DRIVER.state.fields.serial or "")
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
}

function OnPropertyChanged(name)
    guard("OnPropertyChanged(" .. tostring(name) .. ")", function()
        local handler = PROPERTY_HANDLERS[name]
        if handler then handler(Properties[name]) end
    end)
end

local ACTIONS = {
    REFRESH_FROM_DEVICE = function() DRIVER.session:refresh() end,
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

-- Composer's Actions tab does NOT send an action's <command> as the command.
-- It sends the literal "LUA_ACTION", with the declared name in tParams.ACTION.
-- Dispatching on the command alone matched nothing and returned in silence, so
-- every action in this driver did nothing at all and said nothing about it.
--
-- The direct form is still accepted: it costs one lookup and is how a
-- programming command would arrive if this driver ever declares one.
function ExecuteCommand(command, params)
    guard("ExecuteCommand(" .. tostring(command) .. ")", function()
        params = params or {}

        local name = command
        if command == "LUA_ACTION" then name = params.ACTION end

        local action = ACTIONS[name]
        if action then
            action(params)
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

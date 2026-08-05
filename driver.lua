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
local function boolText(value) return value and "true" or "false" end

local function text(value)
    if value == nil then return "" end
    return tostring(value)
end

-- The unit's own label beats nothing; the Control4 connection name beats an
-- empty field. Task M2-T3 (input labels) reads Mapping.INPUTS for the same
-- reason -- extend this lookup rather than forking it.
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
    CONNECTED          = function(_, connected) return boolText(connected) end,
    POWER_STATE        = function(state) return state.fields.power and "On" or "Off" end,
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
    DRIVER.varCache = {}
    local connected = DRIVER.session and DRIVER.session.connected or false
    for name, fn in pairs(VARIABLES) do
        local value = fn(DRIVER.state, connected)
        DRIVER.varCache[name] = value
        C4:AddVariable(name, value, "STRING")
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
        if DRIVER.varCache[name] ~= value then
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
    updateVariables(DRIVER.session.connected)
    fireStateEvents(changes)
    DRIVER.proxy:notify(changes)
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
    -- Adopting labels is applied in M2, when the driver renames its connections.
    ADOPT_INPUT_LABELS = function()
        print("HTP-1: input labels are applied in M2")
    end,
}

function ExecuteCommand(command, params)
    guard("ExecuteCommand(" .. tostring(command) .. ")", function()
        local action = ACTIONS[command]
        if action then action(params or {}) end
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

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
    math.randomseed(C4:GetDeviceID())

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
        onChanges = function(changes) DRIVER.proxy:notify(changes) end,
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
end

function DRIVER.onConnected(connected)
    C4:UpdateProperty("Connection Status", connected and "Connected" or "Not connected")
    if not connected then return end

    C4:UpdateProperty("Firmware Version", DRIVER.state.fields.firmware or "")
    C4:UpdateProperty("Serial Number", DRIVER.state.fields.serial or "")
    DRIVER.proxy:announce()
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
function OnBindingChanged(idBinding, class, bIsBound)
    guard("OnBindingChanged", function()
        if idBinding ~= Mapping.NETWORK_BINDING then return end
        DRIVER.transport:connect()
    end)
end

function ReceivedFromNetwork(binding, port, data)
    guard("ReceivedFromNetwork", function()
        if binding ~= Mapping.NETWORK_BINDING then return end
        DRIVER.transport:onData(data)
    end)
end

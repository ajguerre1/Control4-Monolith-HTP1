-- The receiver proxy: commands in, notifications out.
--
-- The proxy addresses inputs and outputs by CONNECTION BINDING ID, so every
-- translation runs through htp1/mapping.lua. Control4 delivers proxy parameters
-- as strings, so every numeric parameter goes through tonumber.

local Mapping = require("htp1.mapping")

local Proxy = {}
Proxy.__index = Proxy

function Proxy.new(opts)
    return setmetatable({
        state    = opts.state,
        session  = opts.session,
        log      = opts.log,
        maxVolumeDb    = opts.maxVolumeDb,
        rampMs         = opts.rampMs or 100,
        powerOffAction = opts.powerOffAction or "Standby",
        rampTimer      = nil,
    }, Proxy)
end

function Proxy:setMaxVolumeDb(db) self.maxVolumeDb = db end
function Proxy:setRampMs(ms) self.rampMs = ms end
function Proxy:setPowerOffAction(action) self.powerOffAction = action end

function Proxy:_notify(command, params)
    params = params or {}
    params.OUTPUT = tostring(Mapping.ROOM_OUTPUT)
    C4:SendToProxy(Mapping.PROXY_BINDING, command, params, "NOTIFY")
end

--------------------------------------------------------------------------------
-- Volume
--------------------------------------------------------------------------------

-- The usable dB range: the unit's own, narrowed by the Maximum Volume property.
function Proxy:_range()
    local low  = self.state.fields.vpl
    local high = self.state.fields.vph
    if low == nil or high == nil then return nil end
    if self.maxVolumeDb and self.maxVolumeDb < high then high = self.maxVolumeDb end
    return low, high
end

-- Always writes, even when db already equals the stored value: the unit is the
-- source of truth for the write's confirmation, and a caller-side "no real
-- change" skip here also has to be right for every future caller, not just the
-- ones known today.
function Proxy:_setVolumeDb(db)
    local low, high = self:_range()
    if not low then return end
    if db < low then db = low end
    if db > high then db = high end

    if self.state.fields.volume == db then
        -- Already there, so writing again would be noise: a ramp held against
        -- either end of the range would otherwise rewrite the same value for as
        -- long as the button is down.
        --
        -- Still re-notify, because percent maps onto dB lossily. The room may
        -- believe a percentage that does not round to this dB, and dB is the
        -- truth -- without this the room's bar could sit one step off with
        -- nothing to correct it.
        self:_notifyVolume()
        return
    end

    self.session:write("/volume", db)
end

function Proxy:_stepVolume(delta)
    local current = self.state.fields.volume
    if current == nil then return end
    self:_setVolumeDb(current + delta)
end

function Proxy:_stopRamp()
    if self.rampTimer then
        self.rampTimer:Cancel()
        self.rampTimer = nil
    end
end

function Proxy:_startRamp(delta)
    self:_stopRamp()
    self:_stepVolume(delta)   -- respond to the first press immediately
    self.rampTimer = C4:SetTimer(self.rampMs, function()
        self:_stepVolume(delta)
    end, true)
end

--------------------------------------------------------------------------------
-- Command handlers
--------------------------------------------------------------------------------

local COMMANDS = {}

function COMMANDS.ON(self)
    self.session:write("/powerIsOn", true)
end

function COMMANDS.OFF(self)
    self.session:write("/powerAction", self.powerOffAction == "Sleep" and "sleep" or "off")
end

function COMMANDS.SET_INPUT(self, params)
    local key = Mapping.bindingToKey(tonumber(params.INPUT))
    if not key then
        self.log:debug("SET_INPUT for an unmapped binding:", tostring(params.INPUT))
        return
    end
    self.session:write("/input", key)
end

function COMMANDS.SET_VOLUME_LEVEL(self, params)
    local low, high = self:_range()
    if not low then return end
    local db = Mapping.percentToDb(tonumber(params.LEVEL), low, high)
    if db then self:_setVolumeDb(db) end
end

function COMMANDS.PULSE_VOL_UP(self) self:_stepVolume(1) end
function COMMANDS.PULSE_VOL_DOWN(self) self:_stepVolume(-1) end
function COMMANDS.START_VOL_UP(self) self:_startRamp(1) end
function COMMANDS.START_VOL_DOWN(self) self:_startRamp(-1) end
function COMMANDS.STOP_VOL_UP(self) self:_stopRamp() end
function COMMANDS.STOP_VOL_DOWN(self) self:_stopRamp() end

function COMMANDS.MUTE_ON(self) self.session:write("/muted", true) end
function COMMANDS.MUTE_OFF(self) self.session:write("/muted", false) end
function COMMANDS.MUTE_TOGGLE(self)
    self.session:write("/muted", not self.state.fields.muted)
end

function COMMANDS.SET_SURROUND_MODE(self, params)
    local key = Mapping.surroundIdToKey(tonumber(params.SURROUND_MODE))
    if not key then
        self.log:debug("unknown surround mode:", tostring(params.SURROUND_MODE))
        return
    end
    self.session:write("/upmix/select", key)
end

-- The unit switches its own audio path; Control4 only needs the acknowledgement.
function COMMANDS.CONNECT_OUTPUT() end
function COMMANDS.DISCONNECT_OUTPUT() end

function COMMANDS.BINDING_CHANGE_ACTION(self)
    self:announce()
end

function Proxy:handle(_, command, params)
    local handler = COMMANDS[command]
    if not handler then return false end
    handler(self, params or {})
    return true
end

--------------------------------------------------------------------------------
-- Notifications
--------------------------------------------------------------------------------

function Proxy:_notifyPower()
    if self.state.fields.power == nil then return end
    self:_notify(self.state.fields.power and "ON" or "OFF")
end

function Proxy:_notifyVolume()
    local low, high = self:_range()
    local percent = Mapping.dbToPercent(self.state.fields.volume, low, high)
    if percent == nil then return end
    self:_notify("VOLUME_LEVEL_CHANGED", { LEVEL = percent })
end

function Proxy:_notifyMute()
    if self.state.fields.muted == nil then return end
    self:_notify("MUTE_CHANGED", { MUTE = self.state.fields.muted })
end

function Proxy:_notifyInput()
    local key = self.state.fields.input
    if key == nil then return end
    -- An input the driver does not model -- Roon, for instance -- is reported as
    -- no input rather than as some arbitrary one.
    local binding = Mapping.keyToBinding(key) or Mapping.NO_INPUT
    self:_notify("INPUT_OUTPUT_CHANGED", {
        INPUT = tostring(binding), AUDIO = true, VIDEO = true,
    })
end

function Proxy:_notifySurround()
    local id = Mapping.keyToSurroundId(self.state.fields.upmix)
    if id == nil then return end
    self:_notify("SURROUND_MODE_CHANGED", { SURROUND_MODE = tostring(id) })
end

function Proxy:announce()
    self:_notifyPower()
    self:_notifyVolume()
    self:_notifyMute()
    self:_notifyInput()
    self:_notifySurround()
end

-- Only what actually moved. The volume range moving rescales the reported level,
-- so vpl and vph feed the volume notification too.
function Proxy:notify(changes)
    if changes.power then self:_notifyPower() end
    if changes.volume or changes.vpl or changes.vph then self:_notifyVolume() end
    if changes.muted then self:_notifyMute() end
    if changes.input then self:_notifyInput() end
    if changes.upmix then self:_notifySurround() end
end

return Proxy

-- Debug logging with a self-cancelling timer, so a driver left in debug does not
-- fill the Director log indefinitely. Faults always reach C4:ErrorLog, whatever
-- the mode -- nothing is ever swallowed.

local Log = {}
Log.__index = Log

local AUTO_OFF_MS = 15 * 60 * 1000

function Log.new(name)
    return setmetatable({ name = name or "HTP-1", enabled = false, timer = nil }, Log)
end

function Log:setMode(mode)
    if self.timer then
        self.timer:Cancel()
        self.timer = nil
    end

    if mode == "On" then
        self.enabled = true
    elseif mode == "On for 15 Minutes" then
        self.enabled = true
        self.timer = C4:SetTimer(AUTO_OFF_MS, function()
            self.enabled = false
            self.timer = nil
            print(self.name .. ": debug logging expired")
        end, false)
    else
        self.enabled = false
    end
end

function Log:debug(...)
    if not self.enabled then return end
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    print(self.name .. ": " .. table.concat(parts, " "))
end

-- Always logged. A caught error that nobody records is worse than a crash.
function Log:error(message)
    C4:ErrorLog(self.name .. ": " .. tostring(message))
end

return Log

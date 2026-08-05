-- A stand-in for the Control4 API, good enough to run the driver offline.
-- Time is virtual: nothing sleeps, tests call mock.advance(ms) to fire timers.

local M = {}

M.calls, M.printed, M.sent, M.timers, M.now = {}, {}, {}, {}, 0
M.properties, M.variables = {}, {}
M.variableReadOnly = {}
M.hashAlgorithms = { MD5 = true, SHA1 = true }
-- What C4:GetBindingAddress(6001) answers. Invented, reserved-for-testing
-- hostname (RFC 2606), never a real one. Tests that care about the "no
-- address yet" case override this before the driver reads it.
M.bindingAddress = "unit.invalid"

local function record(name, args) table.insert(M.calls, { name = name, args = args }) end

function M.clearCalls()
    M.calls, M.printed, M.sent = {}, {}, {}
end

function M.advance(ms)
    local target = M.now + ms
    while true do
        local soonest, soonestId
        for id, t in pairs(M.timers) do
            if t.due <= target and (not soonest or t.due < soonest.due) then
                soonest, soonestId = t, id
            end
        end
        if not soonest then break end
        M.now = soonest.due
        if soonest.repeating then
            soonest.due = M.now + soonest.interval
        else
            M.timers[soonestId] = nil
        end
        soonest.callback(soonest.handle, 0)
    end
    M.now = target
end

function M.proxyCalls(binding, command)
    local found = {}
    for _, c in ipairs(M.calls) do
        if c.name == "SendToProxy" and c.args[1] == binding and c.args[2] == command then
            table.insert(found, c)
        end
    end
    return found
end

function M.lastProxyCall(binding, command)
    local found = M.proxyCalls(binding, command)
    return found[#found]
end

function M.install(properties)
    M.calls, M.printed, M.sent, M.timers, M.now = {}, {}, {}, {}, 0
    M.variables, M.variableReadOnly = {}, {}
    M.properties = properties or {}
    M.bindingAddress = "unit.invalid"

    _G.Properties = M.properties
    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        table.insert(M.printed, table.concat(parts, "\t"))
    end

    local nextTimerId = 0

    _G.C4 = {
        CreateNetworkConnection = function(_, binding, address)
            record("CreateNetworkConnection", { binding, address })
        end,
        NetConnect = function(_, binding, port) record("NetConnect", { binding, port }) end,
        NetDisconnect = function(_, binding, port) record("NetDisconnect", { binding, port }) end,
        SendToNetwork = function(_, binding, port, data)
            record("SendToNetwork", { binding, port, data })
            table.insert(M.sent, data)
        end,
        SetTimer = function(_, ms, callback, repeating)
            -- A non-positive interval makes M.advance loop forever, which hangs
            -- the suite silently. Fail at the call site, where the culprit is named.
            if type(ms) ~= "number" or ms <= 0 then
                error("SetTimer requires a positive interval, got " .. tostring(ms), 2)
            end
            nextTimerId = nextTimerId + 1
            local id = nextTimerId
            local handle
            handle = { Cancel = function() M.timers[id] = nil; return handle end }
            M.timers[id] = {
                due = M.now + ms, interval = ms, repeating = repeating and true or false,
                callback = callback, handle = handle,
            }
            record("SetTimer", { ms, repeating })
            return handle
        end,
        -- Varargs on purpose: a fixed fourth parameter cannot distinguish an
        -- omitted call type from an explicitly nil one, and the real proxy
        -- rejects the second.
        SendToProxy = function(_, binding, command, params, ...)
            if select("#", ...) > 0 and select(1, ...) == nil then
                error("SendToProxy called with an explicit nil strCallType", 2)
            end
            record("SendToProxy", { binding, command, params, ... })
        end,
        UpdateProperty = function(_, name, value)
            M.properties[name] = value
            record("UpdateProperty", { name, value })
        end,
        AddVariable = function(_, name, value, kind, readOnly)
            M.variables[name] = value
            M.variableReadOnly[name] = readOnly
            record("AddVariable", { name, value, kind, readOnly })
        end,
        SetVariable = function(_, name, value)
            M.variables[name] = value
            record("SetVariable", { name, value })
        end,
        FireEvent = function(_, name)
            record("FireEvent", { name })
        end,
        ErrorLog = function(_, message)
            record("ErrorLog", { message })
            table.insert(M.printed, "ErrorLog: " .. tostring(message))
        end,
        Base64Encode = function(_, data)
            local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
            local out = {}
            local pad = (3 - #data % 3) % 3
            local padded = data .. string.rep("\0", pad)
            for i = 1, #padded, 3 do
                local a, b, c = padded:byte(i, i + 2)
                local n = a * 65536 + b * 256 + c
                for j = 3, 0, -1 do
                    local index = math.floor(n / (64 ^ j)) % 64
                    table.insert(out, alphabet:sub(index + 1, index + 1))
                end
            end
            local encoded = table.concat(out)
            return encoded:sub(1, #encoded - pad) .. string.rep("=", pad)
        end,
        Hash = function(_, algorithm, data)
            if not M.hashAlgorithms[algorithm] then
                error("unsupported hash algorithm: " .. tostring(algorithm), 2)
            end
            record("Hash", { algorithm, data })
            return "hashed:" .. algorithm .. ":" .. data
        end,
        GetDriverConfigInfo = function(_, key) return "test-" .. key end,
        GetDeviceID = function() return 4242 end,
        GetBindingAddress = function(_, binding) return M.bindingAddress end,
    }

    return M
end

return M

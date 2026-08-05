-- Assertions and shared helpers. Pure modules are required directly by the
-- suites; only driver-level suites need the mock installed.

local mock = require("tests.mock_c4")

local H = { mock = mock }

local function fail(msg, level) error(msg, (level or 2) + 1) end

function H.isTrue(value, msg)
    if not value then fail(msg or ("expected truthy, got " .. tostring(value))) end
end

function H.isFalse(value, msg)
    if value then fail(msg or ("expected falsey, got " .. tostring(value))) end
end

function H.equal(actual, expected, msg)
    if actual ~= expected then
        fail((msg and (msg .. ": ") or "") ..
            "expected " .. tostring(expected) .. ", got " .. tostring(actual))
    end
end

function H.count(list, expected, msg)
    if #list ~= expected then
        fail((msg and (msg .. ": ") or "") ..
            "expected " .. expected .. " item(s), got " .. #list)
    end
end

-- Assert `fn` raises, and that the message contains `substring`.
function H.errorMatches(fn, substring)
    local ok, err = pcall(fn)
    if ok then fail("expected an error containing '" .. substring .. "', none was raised") end
    if not tostring(err):find(substring, 1, true) then
        fail("expected an error containing '" .. substring .. "', got: " .. tostring(err))
    end
end

-- Handlers are wrapped, so a fault is otherwise invisible and a broken handler
-- reports as passing. Every driver-level test ends with this.
function H.assertNoErrorLog()
    for _, line in ipairs(mock.printed) do
        if line:find("ErrorLog:", 1, true) then
            fail("driver logged an error: " .. line)
        end
    end
end

return H

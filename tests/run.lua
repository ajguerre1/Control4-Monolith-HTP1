-- Test runner. Run from the repository root:
--
--   luajit tests/run.lua
--
-- Exits non-zero if any test fails, so it can gate packaging.

package.path = "./?.lua;./?/init.lua;" .. package.path

local SUITES = {
    "tests.test_smoke",
    "tests.test_frame",
}

local GREEN, RED, DIM, RESET = "\27[32m", "\27[31m", "\27[2m", "\27[0m"
if os.getenv("NO_COLOR") then GREEN, RED, DIM, RESET = "", "", "", "" end

local passed, failed, failures = 0, 0, {}
local out = print   -- suites replace the global print; keep our own

for _, suiteName in ipairs(SUITES) do
    local ok, suite = pcall(require, suiteName)
    if not ok then
        failed = failed + 1
        table.insert(failures, { name = suiteName, err = "failed to load: " .. tostring(suite) })
        out(RED .. "LOAD FAIL" .. RESET .. "  " .. suiteName)
    else
        out(DIM .. suiteName .. RESET)
        for _, test in ipairs(suite) do
            local testOk, err = pcall(test.fn)
            _G.print = out
            if testOk then
                passed = passed + 1
                out("  " .. GREEN .. "pass" .. RESET .. "  " .. test.name)
            else
                failed = failed + 1
                table.insert(failures, { name = suiteName .. " / " .. test.name, err = err })
                out("  " .. RED .. "FAIL" .. RESET .. "  " .. test.name)
                out("        " .. tostring(err))
            end
        end
    end
end

out("")
if failed == 0 then
    out(GREEN .. passed .. " passed, 0 failed" .. RESET)
    os.exit(0)
else
    out(RED .. passed .. " passed, " .. failed .. " failed" .. RESET)
    for _, f in ipairs(failures) do
        out("  " .. RED .. f.name .. RESET .. ": " .. tostring(f.err))
    end
    os.exit(1)
end

-- Foundry.Commands test runner (plain Lua 5.1, no external dependencies).
--
-- Run from the Foundry repo root or anywhere:
--   lua5.1 Foundry-1.0/Tests/run.lua
--
-- These tests are development-only: they are NOT listed in the shipped TOC.
-- They mock the handful of WoW globals the module uses, load the bootstrap +
-- module fresh per test, and assert behavior against the module's public
-- contract.

local realPrint = print  -- preserve the real print; tests mock _G.print

local scriptPath = (arg and arg[0]) or "Foundry-1.0/Tests/run.lua"
local testsDir = scriptPath:match("^(.*)[/\\][^/\\]+$") or "."
local foundryRoot = testsDir .. "/.."

local T = {}

-- Captured chat output; the mocked print appends one entry per line.
T.output = {}

-- Install fresh WoW-global mocks. tocVersion drives IS_DEV_BUILD:
--   "@project-version@" or nil -> dev build (loud raise)
--   a real version string      -> release build (print + refuse)
function T.installMocks(tocVersion)
    T.output = {}
    -- Clear any SLASH_* globals left by a prior test.
    local stale = {}
    for k in pairs(_G) do
        if type(k) == "string" and k:find("^SLASH_") then
            stale[#stale + 1] = k
        end
    end
    for _, k in ipairs(stale) do _G[k] = nil end

    _G.SlashCmdList = {}
    _G.C_AddOns = {
        GetAddOnMetadata = function(_, key)
            if key == "Version" then return tocVersion end
            return nil
        end,
    }
    _G.print = function(...)
        local n = select("#", ...)
        local parts = {}
        for i = 1, n do parts[i] = tostring((select(i, ...))) end
        T.output[#T.output + 1] = table.concat(parts, " ")
    end
    _G.Foundry_1_0 = nil
    _G.FOUNDRY_DEV_BUILD_OVERRIDE = nil
end

-- Load the bootstrap + Commands module fresh; returns the Foundry table.
function T.loadFoundry()
    local boot = assert(loadfile(foundryRoot .. "/Foundry.lua"))
    boot("Foundry-1.0")
    local cmds = assert(loadfile(foundryRoot .. "/Modules/Commands.lua"))
    cmds("Foundry-1.0")
    return _G.Foundry_1_0
end

-- Install dev-build mocks (default) and load; returns the Foundry table.
function T.fresh(tocVersion)
    T.installMocks(tocVersion == nil and "@project-version@" or tocVersion)
    return T.loadFoundry()
end

function T.eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %q, got %q",
            msg or "eq", tostring(expected), tostring(actual)), 2)
    end
end
function T.truthy(v, msg)
    if not v then error((msg or "truthy") .. ": got " .. tostring(v), 2) end
end
function T.falsy(v, msg)
    if v then error((msg or "falsy") .. ": got " .. tostring(v), 2) end
end
function T.raises(fn, msg, expect)
    local ok, err = pcall(fn)
    if ok then error((msg or "raises") .. ": expected an error, none raised", 2) end
    if expect and not tostring(err):find(expect, 1, true) then
        error((msg or "raises") .. ": error did not contain '" .. expect
            .. "' (got: " .. tostring(err) .. ")", 2)
    end
    return err
end
function T.outputContains(substr, msg)
    for _, line in ipairs(T.output) do
        if line:find(substr, 1, true) then return true end
    end
    error((msg or "outputContains") .. ": no output line contained '" .. tostring(substr)
        .. "' (output: " .. table.concat(T.output, " | ") .. ")", 2)
end

local tests = assert(loadfile(testsDir .. "/Commands/commands_spec.lua"))(T)

local passed, failed, failures = 0, 0, {}
for _, case in ipairs(tests) do
    local ok, err = pcall(case.fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = case.name .. "  ->  " .. tostring(err)
    end
end

realPrint(string.format("Foundry.Commands: %d passed, %d failed (%d total)",
    passed, failed, passed + failed))
for _, f in ipairs(failures) do
    realPrint("  FAIL: " .. f)
end
os.exit(failed == 0 and 0 or 1)

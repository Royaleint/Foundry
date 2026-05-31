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

    -- CreateFrame("Frame") stub (additive; Commands never calls CreateFrame).
    -- Returns a recorder frame whose event/script methods log calls so Events
    -- tests can assert what the controller drove on the native frame, and a
    -- T.Fire(frame, event, ...) helper synthesizes an OnEvent delivery by
    -- invoking the captured OnEvent script as onEvent(frame, event, ...).
    T.frames = {}
    _G.CreateFrame = function(kind)
        local frame = {}
        frame._kind = kind
        frame._shown = true
        -- Call logs: each native method appends a record so a test can count
        -- and inspect the exact args (including unit2 presence/order).
        frame.calls = {
            RegisterEvent = {},
            RegisterUnitEvent = {},
            UnregisterEvent = {},
            UnregisterAllEvents = {},
            SetScript = {},
            Hide = {},
            Show = {},
        }
        function frame:RegisterEvent(event)
            self.calls.RegisterEvent[#self.calls.RegisterEvent + 1] = { event }
        end
        function frame:RegisterUnitEvent(...)
            -- Capture the true passed-arg count via varargs: a fixed parameter
            -- list would make select("#") always report 3, hiding whether the
            -- controller forwarded unit2 or omitted it.
            local n = select("#", ...)
            local event, unit1, unit2 = ...
            self.calls.RegisterUnitEvent[#self.calls.RegisterUnitEvent + 1] =
                { event = event, unit1 = unit1, unit2 = unit2, n = n }
        end
        function frame:UnregisterEvent(event)
            self.calls.UnregisterEvent[#self.calls.UnregisterEvent + 1] = { event }
        end
        function frame:UnregisterAllEvents()
            self.calls.UnregisterAllEvents[#self.calls.UnregisterAllEvents + 1] = {}
        end
        function frame:SetScript(name, fn)
            self.calls.SetScript[#self.calls.SetScript + 1] = { name, fn }
            if name == "OnEvent" then self._onEvent = fn end
        end
        function frame:Hide()
            self._shown = false
            self.calls.Hide[#self.calls.Hide + 1] = {}
        end
        function frame:Show()
            self._shown = true
            self.calls.Show[#self.calls.Show + 1] = {}
        end
        function frame:IsShown()
            return self._shown
        end
        T.frames[#T.frames + 1] = frame
        return frame
    end
    _G.print = function(...)
        local n = select("#", ...)
        local parts = {}
        for i = 1, n do parts[i] = tostring((select(i, ...))) end
        T.output[#T.output + 1] = table.concat(parts, " ")
    end
    _G.Foundry_1_0 = nil
    _G.FOUNDRY_DEV_BUILD_OVERRIDE = nil
end

-- Synthesize a native OnEvent delivery: invoke the frame's captured OnEvent
-- script exactly as WoW would, onEvent(frame, event, ...). A no-op if the
-- frame has no OnEvent script (e.g. after Destroy detaches it).
function T.Fire(frame, event, ...)
    local onEvent = frame and frame._onEvent
    if onEvent then return onEvent(frame, event, ...) end
end

-- Load the bootstrap + the Commands and Events modules fresh; returns the
-- Foundry table. Loading Events is additive: Commands tests reference only
-- F.Commands and are unaffected by the extra module being present.
function T.loadFoundry()
    local boot = assert(loadfile(foundryRoot .. "/Foundry.lua"))
    boot("Foundry-1.0")
    local cmds = assert(loadfile(foundryRoot .. "/Modules/Commands.lua"))
    cmds("Foundry-1.0")
    local events = assert(loadfile(foundryRoot .. "/Modules/Events.lua"))
    events("Foundry-1.0")
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

-- Each suite: a label and the cases list its spec returns when called with T.
local suites = {
    { label = "Foundry.Commands", cases = assert(loadfile(testsDir .. "/Commands/commands_spec.lua"))(T) },
    { label = "Foundry.Events",   cases = assert(loadfile(testsDir .. "/Events/events_spec.lua"))(T) },
}

local anyFailed = false
for _, suite in ipairs(suites) do
    local passed, failed, failures = 0, 0, {}
    for _, case in ipairs(suite.cases) do
        local ok, err = pcall(case.fn)
        if ok then
            passed = passed + 1
        else
            failed = failed + 1
            failures[#failures + 1] = case.name .. "  ->  " .. tostring(err)
        end
    end
    realPrint(string.format("%s: %d passed, %d failed (%d total)",
        suite.label, passed, failed, passed + failed))
    for _, f in ipairs(failures) do
        realPrint("  FAIL: " .. f)
    end
    if failed > 0 then anyFailed = true end
end

os.exit(anyFailed and 1 or 0)

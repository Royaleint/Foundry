-- Foundry.Tooltip in-game self-test (DEV-ONLY — never ships).
--
-- Tooltip is a DISPATCH module: its load-bearing behavior — registering a
-- post-call with the real TooltipDataProcessor, the filter applying correctly,
-- and the handler being silenced by :Destroy() — cannot be fully verified by the
-- headless harness because:
--   • The real TooltipDataProcessor drives real tooltip events (item hover, etc).
--   • Whether a line added via the handler actually appears requires visual check.
--   • The in-place disable path (no unregister API) requires the real dispatch
--     loop to confirm the callback truly becomes a no-op after :Destroy().
--
-- TRIPLE-GATED OFF for players:
--   (1) NOT listed in the released TOC payload; .pkgmeta `ignore: Dev` strips Dev/.
--   (2) `if not F.IS_DEV_BUILD then return end` — refuses in a release build.
--   (3) Commands registered under a private /foundrytooltip slash.

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: TooltipSelfTest.lua requires the Foundry-1.0 bootstrap "
        .. "(Foundry.lua) to have loaded first; _G.Foundry_1_0 is missing.", 0)
end

if not F.IS_DEV_BUILD then return end

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------

local PREFIX = "|cff33ff99[Foundry.Tooltip]|r "

local function emit(msg)
    print(PREFIX .. tostring(msg))
end

local function newReport() return { ok = 0, fail = 0 } end
local function check(r, cond, label)
    if cond then
        r.ok   = r.ok   + 1
        emit("  ok:   " .. label)
    else
        r.fail = r.fail + 1
        emit("  FAIL: " .. label)
    end
end
local function summary(r, name)
    emit(name .. " — Summary: " .. r.ok .. " ok / " .. r.fail .. " FAIL")
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

-- The live test controller (nil until /foundrytooltip register).
local testController = nil

local function teardownAll()
    if testController and not testController._destroyed then
        testController:Destroy()
    end
    testController = nil
end

local function guardDev(cmdName)
    if not F.IS_DEV_BUILD then
        F:RaiseDevError(cmdName .. " is dev-build only")
        return false
    end
    return true
end

--------------------------------------------------------------------------------
-- /foundrytooltip register
--
-- Registers a post-call on Enum.TooltipDataType.Item. The handler stamps a
-- "[Foundry.Tooltip Test]" line onto every item tooltip so visual verification
-- is trivial: hover any item and confirm the line appears.
--
-- Gate-2 Q1: does AddTooltipPostCall succeed at slash-command time (runtime,
--   not OnInitialize)? PASS if no Lua error.
-- Gate-2 Q2: does the handler fire on item hover? PASS if the test line appears
--   in the tooltip.
--------------------------------------------------------------------------------

local function registerHandler()
    if not guardDev("Tooltip self-test register") then return end

    if not (F.Tooltip and F.Tooltip.New) then
        emit("register: Foundry.Tooltip module not loaded")
        return
    end

    if testController and not testController._destroyed then
        testController:Destroy()
        testController = nil
        emit("  (prior test controller destroyed before re-register)")
    end

    emit("register: calling F.Tooltip:New for Enum.TooltipDataType.Item...")

    local r = newReport()

    local ok, errMsg = pcall(function()
        testController = F.Tooltip:New({
            type    = Enum.TooltipDataType.Item,
            name    = "FoundryTooltipTest",
            handler = function(tooltip, _)
                F.Tooltip.AddSeparator(tooltip)
                F.Tooltip.AddLine(tooltip, "|cff33ff99[Foundry.Tooltip Test]|r — handler fired", 1, 1, 1)
            end,
        })
    end)

    check(r, ok, "F.Tooltip:New returned without error (Q1: runtime registration safe)")
    if not ok then
        emit("  error = " .. tostring(errMsg))
        summary(r, "register")
        return
    end

    check(r, testController ~= nil, "controller is non-nil")
    if testController then
        local h = testController:GetNativeHandles()
        check(r, type(h) == "table", "GetNativeHandles() returned a table")
        check(r, h.type == Enum.TooltipDataType.Item, "handle.type matches Item enum value")
        check(r, h.tooltipDataProcessor == TooltipDataProcessor, "handle has live TDP reference")
        emit("  handle.type = " .. tostring(h.type))
    end

    summary(r, "register")
    emit("  Handler live. Hover any item — a green test line should appear (Q2).")
    emit("  Use /foundrytooltip destroy to silence it, /foundrytooltip dup to test")
    emit("  duplicate refusal, or /foundrytooltip stop to tear down.")
end

--------------------------------------------------------------------------------
-- /foundrytooltip destroy
--
-- Three-step teardown verification:
--   1. :Destroy() — marks destroyed, frees key.
--   2. Second :Destroy() — idempotent, no error.
--   3. Hover an item after destroy — the test line must NOT appear (Q3: in-place
--      disable confirmed when no handler line shows in subsequent item tooltip).
--------------------------------------------------------------------------------

local function destroyHandler()
    if not guardDev("Tooltip self-test destroy") then return end

    if not testController or testController._destroyed then
        emit("destroy: no live test controller — run /foundrytooltip register first")
        return
    end

    emit("destroy: tearing down controller...")

    local r = newReport()

    testController:Destroy()
    check(r, testController._destroyed, ":Destroy() set _destroyed = true")

    local okDouble, errDouble = pcall(function() testController:Destroy() end)
    check(r, okDouble, "second :Destroy() is idempotent" ..
        (okDouble and "" or ": " .. tostring(errDouble)))

    local okHandles = pcall(function() testController:GetNativeHandles() end)
    check(r, not okHandles, ":GetNativeHandles() after Destroy raised (refused)")

    -- Key freed: re-registration with the same name must succeed.
    local reOk, reErr = pcall(function()
        local tmp = F.Tooltip:New({
            type    = Enum.TooltipDataType.Item,
            name    = "FoundryTooltipTest",
            handler = function() end,
        })
        if tmp then tmp:Destroy() end
    end)
    check(r, reOk, "name key freed — re-registration succeeded" ..
        (reOk and "" or ": " .. tostring(reErr)))

    testController = nil
    summary(r, "destroy")
    emit("  Controller torn down. Hover an item — the test line must NOT appear (Q3).")
end

--------------------------------------------------------------------------------
-- /foundrytooltip dup
--
-- Attempts a duplicate-name registration while a controller is live. Must refuse.
--------------------------------------------------------------------------------

local function dupHandler()
    if not guardDev("Tooltip self-test dup") then return end

    if not testController or testController._destroyed then
        emit("dup: no live test controller — run /foundrytooltip register first")
        return
    end

    emit("dup: attempting duplicate registration (name 'FoundryTooltipTest')...")

    local r = newReport()

    local dupController = nil
    local ok, err = pcall(function()
        dupController = F.Tooltip:New({
            type    = Enum.TooltipDataType.Item,
            name    = "FoundryTooltipTest",
            handler = function() end,
        })
    end)

    if not ok then
        r.ok = r.ok + 1
        emit("  ok:   duplicate registration raised (RaiseDevError) — PASS")
        emit("        error = " .. tostring(err))
    elseif dupController == nil then
        r.ok = r.ok + 1
        emit("  ok:   duplicate registration returned nil (refused) — PASS")
    else
        r.fail = r.fail + 1
        emit("  FAIL: duplicate registration returned a controller — refusal did NOT fire")
        dupController:Destroy()
    end

    -- Original controller must remain functional.
    check(r, testController and not testController._destroyed,
        "original controller still live after refused dup")
    emit("  Original controller still live: " .. tostring(not testController._destroyed))

    summary(r, "dup")
end

--------------------------------------------------------------------------------
-- /foundrytooltip stop
--------------------------------------------------------------------------------

local function stopHandler()
    if not guardDev("Tooltip self-test stop") then return end
    local had = testController and not testController._destroyed
    teardownAll()
    if had then
        emit("stop: live controller destroyed and state cleared.")
    else
        emit("stop: no live controller — state already clear.")
    end
end

--------------------------------------------------------------------------------
-- Command registration
--------------------------------------------------------------------------------

local devCommands = F.Commands and F.Commands:New({
    name           = "FoundryTooltipTest",
    slashes        = { "/foundrytooltip" },
    description    = "Foundry.Tooltip in-game self-test (dev-build only). "
        .. "Run /foundrytooltip register first, then hover an item.",
    defaultHandler = registerHandler,
})

if devCommands then
    devCommands:Register({
        name    = "register",
        help    = "Register a post-call on Enum.TooltipDataType.Item. "
            .. "Hover any item to see the test line (Q1: runtime safe, Q2: handler fires).",
        handler = registerHandler,
    })
    devCommands:Register({
        name    = "destroy",
        help    = "Destroy the controller. Verifies idempotency and key release. "
            .. "Hover an item after — test line must NOT appear (Q3: in-place disable).",
        handler = destroyHandler,
    })
    devCommands:Register({
        name    = "dup",
        help    = "Attempt a duplicate-name registration. Expects refusal. "
            .. "Original controller must remain live.",
        handler = dupHandler,
    })
    devCommands:Register({
        name    = "stop",
        help    = "Tear down any live test controller. Safe at any time.",
        handler = stopHandler,
    })
end

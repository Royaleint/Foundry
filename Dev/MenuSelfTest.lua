-- Foundry.Menu in-game self-test (DEV-ONLY — never ships).
--
-- Menu is a DISPATCH module: its load-bearing behavior — the generatorWrapper
-- lifecycle, :SetupDropdown installing a persistent generator on a DropdownButton,
-- and the in-place disable path via the _destroyed flag — cannot be fully verified
-- by the headless harness because:
--   • The real MenuUtil drives real WoW context menu frames (anchored near owner).
--   • Whether item types (checkbox, radio, submenu) render correctly requires visual
--     inspection in the live UI.
--   • The empty-generator DropdownButton teardown behavior (instant close vs. visible
--     empty frame) is pre-implementation-confirmable only at Gate 2.
--   • The in-place disable path (no public unregister API) requires the real
--     DropdownButton frame to confirm the closure truly becomes a no-op after :Destroy().
--
-- TRIPLE-GATED OFF for players:
--   (1) NOT listed in the released TOC payload; .pkgmeta `ignore: Dev` strips Dev/.
--   (2) `if not F.IS_DEV_BUILD then return end` — refuses in a release build.
--   (3) Commands registered under a private /foundrymenu slash.

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: MenuSelfTest.lua requires the Foundry-1.0 bootstrap "
        .. "(Foundry.lua) to have loaded first; _G.Foundry_1_0 is missing.", 0)
end

if not F.IS_DEV_BUILD then return end

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------

local PREFIX = "|cff33ff99[Foundry.Menu]|r "

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

local testController         = nil   -- context menu controller ("FoundryMenuTest")
local testDropdownController = nil   -- dropdown controller ("FoundryMenuDropdown")
local testDropdownButton     = nil   -- DropdownButton frame for Q10 / Q11(b)
local testAnchorFrame        = nil   -- plain frame used as CreateContextMenu owner

local cbState      = false  -- checkbox state for Q5
local radioValue   = 1      -- radio selection for Q6 (1 = A, 2 = B)
local dropOpenCount = 0     -- counts dropdown opens for Q10 re-fire verification

local function teardownAll()
    if testController and not testController._destroyed then
        testController:Destroy()
    end
    testController = nil
    if testDropdownController and not testDropdownController._destroyed then
        testDropdownController:Destroy()
    end
    testDropdownController = nil
    if testDropdownButton then
        testDropdownButton:Hide()
    end
end

local function guardDev(cmdName)
    if not F.IS_DEV_BUILD then
        F:RaiseDevError(cmdName .. " is dev-build only")
        return false
    end
    return true
end

--------------------------------------------------------------------------------
-- Frame helpers
--------------------------------------------------------------------------------

local function getAnchorFrame()
    if not testAnchorFrame then
        testAnchorFrame = CreateFrame("Frame", nil, UIParent)
        testAnchorFrame:SetSize(1, 1)
        testAnchorFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    return testAnchorFrame
end

-- Creates a real DropdownButton frame for Q10/Q11(b).
-- Template "WowStyle1DropdownTemplate" is required for the button to be visible and
-- clickable — confirmed from both committed consumers:
--   Homestead OptionsControls.lua:309  CreateFrame("DropdownButton", nil, frame, "WowStyle1DropdownTemplate")
--   Sift HistoryPanel.lua:1854         CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
-- Bare intrinsic (no template) does not render visibly on any flavor. pcall guards
-- against future clients where the template or intrinsic may be absent.
local function getDropdownButton()
    if not testDropdownButton then
        local ok, err = pcall(function()
            testDropdownButton = CreateFrame(
                "DropdownButton", "FoundryMenuTestDropdown", UIParent,
                "WowStyle1DropdownTemplate")
            testDropdownButton:SetPoint("CENTER", UIParent, "CENTER", 0, -100)
            testDropdownButton:Show()
        end)
        if not ok then
            emit("  WARNING: CreateFrame('DropdownButton', ..., 'WowStyle1DropdownTemplate') failed — "
                .. "Q10 and Q11(b) will be skipped on this client.")
            emit("           error = " .. tostring(err))
        end
    end
    return testDropdownButton
end

--------------------------------------------------------------------------------
-- /foundrymenu register
--
-- Creates two controllers:
--   1. "FoundryMenuTest" — context menu with all item types.
--   2. "FoundryMenuDropdown" — persistent dropdown installed on a DropdownButton.
--
-- Then opens the context menu immediately via :CreateContextMenu so Q2–Q9 can be
-- verified visually by interacting with the live menu.
--
-- Gate-2 questions exercised:
--   Q1:  F.Menu:New succeeds at runtime (no Lua error; non-nil controller).
--   Q2:  :CreateContextMenu opens a visible frame near the anchor.
--   Q3:  Clicking "Test Button" fires the callback (emits Q3 line) and closes menu.
--   Q4:  Clicking "Refresh Button" returns MenuResponse.Refresh — menu stays open.
--   Q5:  Clicking the checkbox fires the setter (emits Q5 line); state toggles.
--   Q6:  Clicking Radio B selects it; clicking Radio A re-selects; no close.
--   Q7:  Hovering "Submenu" opens a flyout with two child buttons.
--   Q8:  "Disabled Item" is greyed; clicking it must NOT emit a callback line.
--   Q9:  Hovering "Disabled Item" shows the configured tooltip.
--   Q10: DropdownButton opens menu; closing and re-opening shows incremented title.
--------------------------------------------------------------------------------

local function registerHandler()
    if not guardDev("Menu self-test register") then return end

    if not (F.Menu and F.Menu.New) then
        emit("register: Foundry.Menu module not loaded")
        return
    end

    -- Tear down any prior test state cleanly.
    if testController and not testController._destroyed then
        testController:Destroy()
        testController = nil
        emit("  (prior context menu controller destroyed before re-register)")
    end
    if testDropdownController and not testDropdownController._destroyed then
        testDropdownController:Destroy()
        testDropdownController = nil
        emit("  (prior dropdown controller destroyed before re-register)")
    end

    -- Reset interactive state.
    cbState       = false
    radioValue    = 1
    dropOpenCount = 0

    emit("register: calling F.Menu:New for context menu controller (Q1)...")

    local r = newReport()

    -- Q1: F.Menu:New succeeds at runtime.
    local ok, errMsg = pcall(function()
        testController = F.Menu:New({
            name    = "FoundryMenuTest",
            builder = function(owner, rootDescription)
                rootDescription:CreateTitle("Foundry.Menu Test")

                -- Q3: button fires callback and closes menu (default close behavior).
                rootDescription:CreateButton(
                    "Test Button (click me) [Q3]",
                    function()
                        emit("Q3: button callback fired — menu should close now.")
                    end
                )

                -- Q4: button returns MenuResponse.Refresh — menu stays open.
                rootDescription:CreateButton(
                    "Refresh Button (click to keep open) [Q4]",
                    function()
                        emit("Q4: returning MenuResponse.Refresh — menu must stay open.")
                        return MenuResponse.Refresh
                    end
                )

                -- Q5: checkbox renders correct state; setter fires on click.
                rootDescription:CreateCheckbox(
                    ("Checkbox (current state = %s) [Q5]"):format(tostring(cbState)),
                    function() return cbState end,
                    function(_, checked)
                        cbState = checked
                        emit(("Q5: checkbox setter fired — new state = %s"):format(
                            tostring(cbState)))
                    end
                )

                -- Q6: radio pair — only one selected at a time.
                rootDescription:CreateRadio(
                    "Radio A [Q6]",
                    function() return radioValue == 1 end,
                    function() radioValue = 1; emit("Q6: Radio A selected.") end
                )
                rootDescription:CreateRadio(
                    "Radio B [Q6]",
                    function() return radioValue == 2 end,
                    function() radioValue = 2; emit("Q6: Radio B selected.") end
                )

                -- Q7: CreateButton with no callback → flyout submenu.
                local sub = rootDescription:CreateButton("Submenu (hover me) [Q7]")
                sub:CreateButton("Sub-item Alpha [Q7]", function()
                    emit("Q7: sub-item Alpha clicked.")
                end)
                sub:CreateButton("Sub-item Beta [Q7]", function()
                    emit("Q7: sub-item Beta clicked.")
                end)

                rootDescription:CreateDivider()

                -- Q8 + Q9: disabled item — SetEnabled(false) and SetTooltip.
                local disabledBtn = rootDescription:CreateButton(
                    "Disabled Item (hover for tooltip) [Q8/Q9]",
                    function()
                        emit("Q8: FAIL — disabled item callback must NOT fire.")
                    end
                )
                disabledBtn:SetEnabled(false)
                disabledBtn:SetTooltip(function(tooltip, _)
                    GameTooltip_SetTitle(
                        tooltip,
                        "Q9: Tooltip on disabled item — PASS if you see this text."
                    )
                end)
            end,
        })
    end)

    check(r, ok, "F.Menu:New returned without error (Q1: runtime registration safe)")
    if not ok then
        emit("  error = " .. tostring(errMsg))
        summary(r, "register")
        return
    end

    check(r, testController ~= nil, "controller is non-nil (Q1)")
    if not testController then
        summary(r, "register")
        return
    end

    -- Q10: :SetupDropdown — register a separate persistent dropdown controller.
    emit("register: calling F.Menu:New for dropdown controller (Q10)...")
    local dropOk, dropErr = pcall(function()
        testDropdownController = F.Menu:New({
            name    = "FoundryMenuDropdown",
            builder = function(owner, rootDescription)
                dropOpenCount = dropOpenCount + 1
                rootDescription:CreateTitle(
                    ("Dropdown — open #%d (re-fire confirmed if >1) [Q10]"):format(
                        dropOpenCount))
                rootDescription:CreateButton("Close (click to dismiss)", function() end)
            end,
        })
    end)
    check(r, dropOk, "F.Menu:New for dropdown controller succeeded (Q10)"
        .. (dropOk and "" or ": " .. tostring(dropErr)))
    check(r, testDropdownController ~= nil, "dropdown controller is non-nil (Q10)")

    if testDropdownController then
        local dd = getDropdownButton()
        if dd then
            local ddOk, ddErr = pcall(function()
                testDropdownController:SetupDropdown(dd)
            end)
            check(r, ddOk, ":SetupDropdown installed on test DropdownButton (Q10)"
                .. (ddOk and "" or ": " .. tostring(ddErr)))
            if ddOk then
                emit("  Q10: DropdownButton placed at screen center (slightly below).")
                emit("  Q10: Click it — menu opens with 'open #1' title.")
                emit("  Q10: Close and click again — title must increment to 'open #2'.")
                emit("       Confirms generator re-fires on each open (persistent generator).")
            end
        end
    end

    -- Q2: open the context menu visually now.
    emit("register: opening context menu via :CreateContextMenu (Q2)...")
    local openOk, openErr = pcall(function()
        testController:CreateContextMenu(getAnchorFrame())
    end)
    check(r, openOk, ":CreateContextMenu returned without error (Q2)"
        .. (openOk and "" or ": " .. tostring(openErr)))

    summary(r, "register")

    if openOk then
        emit("")
        emit("  Q2:  A context menu should be visible near screen center with title")
        emit("       'Foundry.Menu Test'. PASS = frame is present and readable.")
        emit("  Q3:  Click 'Test Button' — callback must print a Q3 line; menu closes.")
        emit("       Use /foundrymenu open to reopen without resetting state.")
        emit("  Q4:  Click 'Refresh Button' — menu must stay open; second click still works.")
        emit("  Q5:  Click the Checkbox — setter must print Q5 line; reopen to see state change.")
        emit("  Q6:  Click 'Radio B' — selection moves to B. Click 'Radio A' — moves back.")
        emit("  Q7:  Hover 'Submenu' — flyout opens with Sub-item Alpha and Beta inside.")
        emit("  Q8:  Click 'Disabled Item' — must NOT print a callback line.")
        emit("  Q9:  Hover 'Disabled Item' — tooltip must appear with Q9 text.")
        emit("")
        emit("  When ready: /foundrymenu dup (Q13 + dup refusal), then /foundrymenu destroy")
    end
end

--------------------------------------------------------------------------------
-- /foundrymenu destroy
--
-- Tears down the context menu controller and verifies three destroy properties:
--   1. :Destroy() marks _destroyed = true.
--   2. Second :Destroy() is idempotent (no error).
--   3. liveKeys freed — re-registration with the same name succeeds.
--   4. :GetNativeHandles() after destroy refuses loud (RaiseDevError).
--
-- Then, after a 5-second delay:
--   Q11(a): direct :CreateContextMenu on the destroyed controller refuses loud.
--   Q11(b): DropdownButton remains on-screen — Rawb clicks it to observe graceful
--           teardown behavior (instant close vs. empty frame, no Lua error).
--
-- Q11(c) (:SetupDropdown on destroyed controller) runs via /foundrymenu setupdestroyed.
--------------------------------------------------------------------------------

local function destroyHandler()
    if not guardDev("Menu self-test destroy") then return end

    if not testController or testController._destroyed then
        emit("destroy: no live context menu controller — run /foundrymenu register first")
        return
    end

    emit("destroy: tearing down context menu controller and dropdown controller...")

    local r = newReport()

    -- 1. Destroy context menu controller.
    testController:Destroy()
    check(r, testController._destroyed, ":Destroy() set _destroyed = true (context menu controller)")

    -- Also destroy the dropdown controller so the DropdownButton's generatorWrapper is
    -- backed by a truly dead controller. This is the prerequisite for Q11(b): clicking
    -- the button must exercise the _destroyed-returns-early path, not a live open.
    if testDropdownController and not testDropdownController._destroyed then
        testDropdownController:Destroy()
        check(r, testDropdownController._destroyed,
            ":Destroy() set _destroyed = true (dropdown controller — Q11(b) prerequisite)")
    end

    -- 2. Idempotent second call.
    local okDouble, errDouble = pcall(function() testController:Destroy() end)
    check(r, okDouble, "second :Destroy() is idempotent"
        .. (okDouble and "" or ": " .. tostring(errDouble)))

    -- 3. Key freed — same name can be re-registered immediately.
    local reOk, reErr = pcall(function()
        local tmp = F.Menu:New({
            name    = "FoundryMenuTest",
            builder = function() end,
        })
        if tmp then tmp:Destroy() end
    end)
    check(r, reOk, "name key freed — re-registration of 'FoundryMenuTest' succeeded"
        .. (reOk and "" or ": " .. tostring(reErr)))

    -- 4. :GetNativeHandles() after destroy refuses loud.
    local okHandles = pcall(function() testController:GetNativeHandles() end)
    check(r, not okHandles, ":GetNativeHandles() after Destroy raised (refused loud)")

    summary(r, "destroy")
    emit("")
    emit("  Q11(a): Testing direct :CreateContextMenu in 5 seconds.")
    emit("          Do NOT click the dropdown button yet.")

    -- Q11(a) + Q11(b) — delayed so Rawb can read the summary before interaction.
    C_Timer.After(5, function()
        emit("")
        emit("destroy: Q11(a) — calling :CreateContextMenu on destroyed controller now...")
        local r11a = newReport()

        local refuseOk = pcall(function()
            testController:CreateContextMenu(getAnchorFrame())
        end)
        -- RaiseDevError raises in dev builds; not-raised means refusal path was silent.
        check(r11a, not refuseOk,
            "Q11(a): :CreateContextMenu on destroyed controller raised (refused loud)")
        check(r11a, testController._destroyed,
            "Q11(a): controller still marked _destroyed after refused call")
        emit("  Q11(a): No menu should have appeared. A dev error line must be visible.")
        summary(r11a, "Q11(a)")

        emit("")
        emit("  Q11(b): The test DropdownButton (screen center, slightly below) is still")
        emit("          installed with the destroyed controller's generatorWrapper.")
        if testDropdownButton and testDropdownButton:IsShown() then
            emit("  Q11(b): Click the test dropdown button now (5 seconds remaining).")
            emit("          Expect: graceful result — instant close OR empty frame visible.")
            emit("          PASS = no Lua error. Record actual behavior for plan update.")
            C_Timer.After(5, function()
                emit("  Q11(b): 5-second window elapsed. Check above for any Lua errors.")
                emit("          Run /foundrymenu setupdestroyed next to test Q11(c).")
            end)
        else
            emit("  Q11(b): DropdownButton not visible — skip Q11(b) interactive test.")
            emit("          (Run /foundrymenu register first to create the DropdownButton.)")
            emit("  Run /foundrymenu setupdestroyed to test Q11(c).")
        end
    end)
end

--------------------------------------------------------------------------------
-- /foundrymenu dup
--
-- Two checks in sequence:
--   Q13: :GetNativeHandles() returns correct keys; mutation of the returned table
--        does not corrupt a second call (fresh table per call contract).
--   dup: A second F.Menu:New with the same name ("FoundryMenuTest") is refused
--        while the first controller is live. The original controller remains
--        unaffected.
--
-- Run after /foundrymenu register (requires a live testController).
--------------------------------------------------------------------------------

local function dupHandler()
    if not guardDev("Menu self-test dup") then return end

    if not testController or testController._destroyed then
        emit("dup: no live test controller — run /foundrymenu register first")
        return
    end

    emit("dup: testing GetNativeHandles (Q13) and duplicate-name refusal...")

    local r = newReport()

    -- Q13: :GetNativeHandles returns correct keys.
    local handles  = nil
    local handlesOk, handlesErr = pcall(function()
        handles = testController:GetNativeHandles()
    end)
    check(r, handlesOk, "Q13: :GetNativeHandles() returned without error")

    if handlesOk and handles then
        check(r, type(handles) == "table",
            "Q13: GetNativeHandles returned a table")
        check(r, handles.menuUtil == _G.MenuUtil,
            "Q13: handles.menuUtil == _G.MenuUtil (hard gate — load-bearing)")
        if handles.menu ~= nil then
            check(r, true,
                "Q13: handles.menu is non-nil (_G.Menu present on this client; advisory)")
        else
            emit("  Q13: handles.menu is nil — _G.Menu absent on this client.")
            emit("       Advisory only; not a FAIL. Log for Gate 2 record.")
        end

        -- Mutation safety: mutating the first handle table must not corrupt a second call.
        handles.menuUtil = "MUTATED"
        local handles2   = testController:GetNativeHandles()
        check(r, handles2 ~= nil and handles2.menuUtil == _G.MenuUtil,
            "Q13: second :GetNativeHandles() unaffected by mutation of first table "
            .. "(fresh table per call)")
    else
        emit("  Q13: GetNativeHandles error: " .. tostring(handlesErr))
    end

    -- Duplicate-name refusal.
    emit("  dup: attempting duplicate registration (name 'FoundryMenuTest')...")
    local dupController = nil
    local dupOk, dupErr = pcall(function()
        dupController = F.Menu:New({
            name    = "FoundryMenuTest",
            builder = function() end,
        })
    end)

    if not dupOk then
        r.ok = r.ok + 1
        emit("  ok:   duplicate registration raised (RaiseDevError) — PASS")
        emit("        error = " .. tostring(dupErr))
    elseif dupController == nil then
        r.ok = r.ok + 1
        emit("  ok:   duplicate registration returned nil (refused) — PASS")
    else
        r.fail = r.fail + 1
        emit("  FAIL: duplicate registration returned a controller — refusal did NOT fire")
        dupController:Destroy()
    end

    check(r, testController and not testController._destroyed,
        "original controller still live after refused dup")

    summary(r, "dup")
end

--------------------------------------------------------------------------------
-- /foundrymenu setupdestroyed  (Q11(c))
--
-- Calls :SetupDropdown on a destroyed controller. Expects RaiseDevError refusal
-- (not the silent no-op that fires when Blizzard internally fires an already-
-- installed wrapper on a destroyed controller — those are different paths).
--
-- Uses testController if already destroyed (after /foundrymenu destroy), or creates
-- and immediately destroys a temporary controller when needed.
--------------------------------------------------------------------------------

local function setupDestroyedHandler()
    if not guardDev("Menu self-test setupdestroyed") then return end

    emit("setupdestroyed: Q11(c) — :SetupDropdown on a destroyed controller must refuse loud...")

    local r = newReport()

    -- Acquire a destroyed controller.
    local destroyed = nil
    if testController and testController._destroyed then
        destroyed = testController
        emit("  using already-destroyed testController (from /foundrymenu destroy)")
    elseif testDropdownController and testDropdownController._destroyed then
        destroyed = testDropdownController
        emit("  using already-destroyed testDropdownController")
    else
        -- Create and immediately destroy a temporary controller.
        local tmpOk, tmpErr = pcall(function()
            destroyed = F.Menu:New({
                name    = "FoundryMenuTempDestroyed",
                builder = function() end,
            })
            if destroyed then destroyed:Destroy() end
        end)
        if not tmpOk or not destroyed then
            emit("setupdestroyed: could not create a temporary controller: "
                .. tostring(tmpErr))
            return
        end
        emit("  created and immediately destroyed a temporary controller for this test")
    end

    check(r, destroyed._destroyed, "pre-condition: controller is marked _destroyed")

    local dd = getDropdownButton()
    if not dd then
        emit("  Q11(c): DropdownButton frame unavailable — cannot call :SetupDropdown.")
        emit("  Q11(c): SKIP — log as untested for this client.")
        summary(r, "setupdestroyed")
        return
    end

    local refuseOk = pcall(function()
        destroyed:SetupDropdown(dd)
    end)
    check(r, not refuseOk,
        "Q11(c): :SetupDropdown on destroyed controller raised (refused loud)")

    emit("  Q11(c): A dev error line ('Menu:SetupDropdown called on a destroyed controller')")
    emit("          must be visible above. No new generator should be installed on the button.")
    if refuseOk then
        emit("  Q11(c): NOTE — RaiseDevError did not raise in this build. Verify via dev error")
        emit("          output channel (chat, debug output) that the refusal message appeared.")
    end

    summary(r, "setupdestroyed")
end

--------------------------------------------------------------------------------
-- /foundrymenu response  (Q12)
--
-- Reads _G.MenuResponse directly from addon code and verifies:
--   • The table exists (global accessible from addon code, no taint block).
--   • MenuResponse.Refresh == 2 (confirmed by Sift production code; gate-2 verification
--     of the remaining three wiki-sourced values).
--
-- Calls DevTools_Dump(MenuResponse) when available to produce the full raw dump for
-- the Gate 2 record.
--------------------------------------------------------------------------------

local function responseHandler()
    if not guardDev("Menu self-test response") then return end

    emit("response: Q12 — reading _G.MenuResponse directly from addon code...")

    local r = newReport()

    local hasGlobal = type(_G.MenuResponse) == "table"
    check(r, hasGlobal,
        "Q12: _G.MenuResponse is a table (global accessible from addon code, no taint block)")

    if hasGlobal then
        local mr = _G.MenuResponse
        check(r, mr.Refresh == 2,
            ("Q12: MenuResponse.Refresh == 2 (got %s) — CONFIRMED by Sift production code"):format(
                tostring(mr.Refresh)))

        emit("")
        emit(("  Q12: MenuResponse.Open     = %s  (wiki: 1)"):format(tostring(mr.Open)))
        emit(("  Q12: MenuResponse.Refresh  = %s  (wiki: 2, production-confirmed)"):format(
            tostring(mr.Refresh)))
        emit(("  Q12: MenuResponse.Close    = %s  (wiki: 3)"):format(tostring(mr.Close)))
        emit(("  Q12: MenuResponse.CloseAll = %s  (wiki: 4)"):format(tostring(mr.CloseAll)))
        emit("")

        if _G.DevTools_Dump then
            emit("  Q12: DevTools_Dump output follows (raw Gate-2 record):")
            _G.DevTools_Dump(_G.MenuResponse)
        else
            emit("  Q12: DevTools_Dump not available on this client.")
            emit("       Use /run DevTools_Dump(MenuResponse) for the raw dump if needed.")
        end
    end

    summary(r, "response")
end

--------------------------------------------------------------------------------
-- /foundrymenu open
--
-- Re-opens the context menu without resetting state. Once Q3's or Q4's click closes
-- the menu, Rawb can reopen with /foundrymenu open to continue testing Q4–Q9 without
-- losing cbState / radioValue (a full /foundrymenu register resets both).
-- Also useful during Q11 delay windows when the original open was consumed.
--------------------------------------------------------------------------------

local function openHandler()
    if not guardDev("Menu self-test open") then return end

    if not testController or testController._destroyed then
        emit("open: no live context menu controller — run /foundrymenu register first")
        return
    end

    emit("open: reopening context menu via :CreateContextMenu...")
    local ok, err = pcall(function()
        testController:CreateContextMenu(getAnchorFrame())
    end)
    if ok then
        emit("  Menu opened. Continue interacting with Q3–Q9 items.")
    else
        emit("  FAIL: :CreateContextMenu raised: " .. tostring(err))
    end
end

--------------------------------------------------------------------------------
-- /foundrymenu stop
--------------------------------------------------------------------------------

local function stopHandler()
    if not guardDev("Menu self-test stop") then return end
    local had = (testController         and not testController._destroyed)
             or (testDropdownController and not testDropdownController._destroyed)
    teardownAll()
    if had then
        emit("stop: live controller(s) destroyed and state cleared.")
    else
        emit("stop: no live controllers — state already clear.")
    end
end

--------------------------------------------------------------------------------
-- Command registration
--------------------------------------------------------------------------------

local devCommands = F.Commands and F.Commands:New({
    name           = "FoundryMenuTest",
    slashes        = { "/foundrymenu" },
    description    = "Foundry.Menu in-game self-test (dev-build only). "
        .. "Run /foundrymenu register first, then follow the on-screen prompts. "
        .. "Covers Gate-2 Q1–Q13.",
    defaultHandler = registerHandler,
})

if devCommands then
    devCommands:Register({
        name    = "register",
        help    = "Create context menu + dropdown controllers and open the context menu. "
            .. "Q1 (New), Q2 (visible menu), Q3–Q9 (interact with menu items), "
            .. "Q10 (click the DropdownButton at screen center).",
        handler = registerHandler,
    })
    devCommands:Register({
        name    = "open",
        help    = "Reopen the context menu without resetting state (cbState, radioValue). "
            .. "Use after Q3 or Q4 closes the menu to continue testing Q5–Q9.",
        handler = openHandler,
    })
    devCommands:Register({
        name    = "destroy",
        help    = "Destroy both controllers. Verifies idempotency, key release, "
            .. "and GetNativeHandles refusal. After 5 seconds: Q11(a) direct-call refusal; "
            .. "Q11(b) dropdown click prompt (5-second interactive window).",
        handler = destroyHandler,
    })
    devCommands:Register({
        name    = "dup",
        help    = "Q13: GetNativeHandles keys + mutation safety. "
            .. "Duplicate-name refusal while original controller is live. "
            .. "Run after /foundrymenu register.",
        handler = dupHandler,
    })
    devCommands:Register({
        name    = "setupdestroyed",
        help    = "Q11(c): call :SetupDropdown on a destroyed controller. "
            .. "Expects RaiseDevError refusal (the loud path). "
            .. "Run after /foundrymenu destroy.",
        handler = setupDestroyedHandler,
    })
    devCommands:Register({
        name    = "response",
        help    = "Q12: read _G.MenuResponse from addon code. Verifies Refresh == 2 "
            .. "and dumps all four fields. Can run at any time — no controller required.",
        handler = responseHandler,
    })
    devCommands:Register({
        name    = "stop",
        help    = "Tear down any live test controllers and hide the DropdownButton. "
            .. "Safe at any time.",
        handler = stopHandler,
    })
end

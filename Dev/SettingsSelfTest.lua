-- Foundry.Settings in-game self-test (DEV-ONLY — never ships).
--
-- Settings is a REGISTRATION module: its load-bearing behavior — selecting the
-- correct Blizzard registration path, storing the category object, opening the
-- settings panel, enforcing duplicate-key refusal, and releasing cleanly on
-- Destroy — cannot be fully verified by the headless harness because:
--   • The real `Settings.RegisterCanvasLayoutCategory` returns a live Blizzard
--     category object whose `GetID()` returns a numeric id assigned by the client.
--   • `Settings.OpenToCategory` opens a real panel on a real display.
--   • Duplicate-key refusal in the module-level `liveKeys` registry is only
--     meaningful against a live controller, not a headless stub.
--   • Post-Destroy behavior requires the live `F:RaiseDevError` path (not the
--     headless stub that returns instead of erroring).
--
-- This instrument drives those behaviors in-game and prints labelled PASS/FAIL.
-- It also resolves Gate-2-deferrable open questions from the plan:
--   Q6 — is registration safe at runtime (slash-command time, not OnInitialize)?
--        The instrument registers at command time. PASS if no Lua error.
--   Q7 — does :Open() open the settings window, or only scroll?
--        /foundrysettings open with the Settings panel CLOSED. Inspect visually.
--   Q8 — does :Open() cause ADDON_ACTION_FORBIDDEN from an insecure handler?
--        /foundrysettings open from a button OnClick. Inspect error frame.
--
-- TRIPLE-GATED OFF for players:
--   (1) This file is NOT listed in Foundry-1.0.toc in the released payload.
--       .pkgmeta `ignore: Dev` strips the Dev/ tree from packaged addons. The
--       TOC Dev block is a local-only edit (same as ListSelfTest, DBSelfTest).
--   (2) `if not F.IS_DEV_BUILD then return end` at file scope — if the file were
--       force-loaded in a release build it refuses before touching any API.
--   (3) Commands are registered under a private F.Commands:New controller
--       (/foundrysettings — its OWN slash; Commands:New refuses duplicate slashes,
--       so sharing /foundrydev or any other Dev controller would silently drop
--       whichever file loaded second). No raw SLASH_* global is ever written.

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: SettingsSelfTest.lua requires the Foundry-1.0 bootstrap "
        .. "(Foundry.lua) to have loaded first; _G.Foundry_1_0 is missing.", 0)
end

-- Gate (2a): never even build the commands in a release build.
if not F.IS_DEV_BUILD then
    return
end

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------

local PREFIX = "|cff33ff99[Foundry.Settings]|r "

local function emit(msg)
    print(PREFIX .. tostring(msg))
end

-- Studio-standard check/summary helpers (SF-9).
local function newReport() return { ok = 0, fail = 0 } end
local function check(r, cond, label)
    if cond then
        r.ok = r.ok + 1
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
-- State (upvalues — survive across command invocations in the same session)
--------------------------------------------------------------------------------

-- The registered root controller (nil until /foundrysettings register).
local testController = nil

-- The registered subcategory controller (nil until /foundrysettings sub).
local subController  = nil

-- The stub panel frame for the root category (built lazily, reused across runs).
-- A simple unnamed Frame with GetObjectType — the minimum Settings:New requires.
local testPanel = nil

-- The stub panel frame for the subcategory (built lazily, reused across runs).
local subPanel  = nil

-- Build (lazily) the stub panel frames. Frames are created here rather than at
-- file scope: no WoW API is called at parse/load time, only inside handlers.
local function ensurePanel()
    if not testPanel then
        testPanel = CreateFrame("Frame", nil, UIParent)
        testPanel:SetSize(400, 400)
        -- A minimal visible label so the category is non-empty when viewed.
        local label = testPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("CENTER")
        label:SetText("Foundry.Settings self-test panel (dev)")
    end
end

local function ensureSubPanel()
    if not subPanel then
        subPanel = CreateFrame("Frame", nil, UIParent)
        subPanel:SetSize(400, 400)
        local label = subPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("CENTER")
        label:SetText("Foundry.Settings self-test subcategory panel (dev)")
    end
end

local function teardownAll()
    if subController and not subController._destroyed then
        subController:Destroy()
    end
    if testController and not testController._destroyed then
        testController:Destroy()
    end
    subController  = nil
    testController = nil
end

--------------------------------------------------------------------------------
-- Guard: dev-build double-check inside every handler (defense in depth)
--------------------------------------------------------------------------------

local function guardDev(cmdName)
    if not F.IS_DEV_BUILD then
        F:RaiseDevError(cmdName .. " is dev-build only")
        return false
    end
    return true
end

--------------------------------------------------------------------------------
-- /foundrysettings register
--
-- Registers a root test category ("Foundry Settings Test") with a simple stub
-- frame. Prints the category ID returned by :GetCategoryID() and the handles
-- returned by :GetNativeHandles(). Runs a PASS/FAIL report on the assertable
-- parts. Calling again while a controller is live tears it down and re-registers
-- (for reload-test convenience).
--
-- Gate-2-deferrable Q6 resolution: registration happens here at slash-command
-- time (runtime), not at file scope or OnInitialize. PASS if no Lua error — the
-- plan's Gate-0 "OnInitialize is safe" finding is conservative; runtime is equally
-- safe because the Blizzard registration surface is live from ADDON_LOADED onward.
--------------------------------------------------------------------------------

local function registerHandler()
    if not guardDev("Settings self-test register") then return end

    emit("register: building test category...")

    -- If a prior controller exists (from an earlier run), tear it down so the
    -- duplicate-key check does not fire on the re-registration.
    if testController and not testController._destroyed then
        testController:Destroy()
        testController = nil
        emit("  (prior test controller destroyed before re-register)")
    end
    if subController and not subController._destroyed then
        subController:Destroy()
        subController = nil
    end

    ensurePanel()

    -- Create the controller. Settings:New performs atomic validation, path
    -- selection, and registration. Name is explicit so a future re-run with a
    -- different title does not accumulate duplicate keys.
    testController = F.Settings and F.Settings:New({
        title = "Foundry Settings Test",
        frame = testPanel,
        name  = "FoundrySettingsTest",
    })

    if not testController then
        emit("  FAIL: Settings:New returned nil — module absent or validation refused")
        return
    end

    local r = newReport()

    -- :GetCategoryID() — the numeric ID Blizzard assigned to this category.
    -- Modern: a number (confirmed OQ#1 resolution: subcategory also returns a
    --   number from :GetID()). Legacy: nil.
    local catID = testController:GetCategoryID()
    if catID ~= nil then
        emit("  ok:   GetCategoryID() = " .. tostring(catID) .. "  (modern path)")
        r.ok = r.ok + 1
    else
        emit("  ok:   GetCategoryID() = nil  (legacy/interface-options path)")
        r.ok = r.ok + 1
    end

    -- :GetNativeHandles() — fresh table, live objects inside.
    local h = testController:GetNativeHandles()
    check(r, type(h) == "table", "GetNativeHandles() returned a table")
    if type(h) == "table" then
        emit("        mode       = " .. tostring(h.mode))
        emit("        categoryID = " .. tostring(h.categoryID))
        emit("        category   = " .. tostring(h.category))
        emit("        frame      = " .. tostring(h.frame))
        emit("        layout     = " .. tostring(h.layout))
    end

    -- Mutation isolation: mutating the returned table must not affect the
    -- controller's own stored references.
    local h2 = testController:GetNativeHandles()
    h2.frame = nil
    local h3 = testController:GetNativeHandles()
    check(r, h3.frame ~= nil,
        "GetNativeHandles() is mutation-safe (mutating returned table does not corrupt controller)")

    summary(r, "register")
    emit("  controller live. Use /foundrysettings open to open it, /foundrysettings sub")
    emit("  to register a subcategory, /foundrysettings dup to test duplicate refusal,")
    emit("  or /foundrysettings destroy to tear it down.")
end

--------------------------------------------------------------------------------
-- /foundrysettings open
--
-- Calls :Open() on the registered root controller.
--
-- Gate-2-deferrable Q7 resolution: with the Settings panel CLOSED before running
--   this command, PASS = the Settings window opens to the "Foundry Settings Test"
--   category. If it only scrolls (window was already open), close it first and
--   re-run.
-- Gate-2-deferrable Q8 resolution: run this command from a macro button (insecure
--   OnClick). PASS = no ADDON_ACTION_FORBIDDEN error appears. The plan's Gate-0
--   evidence (Blizzard's own XML calls OpenToCategory from OnClick) predicts PASS;
--   this confirms it.
--------------------------------------------------------------------------------

local function openHandler()
    if not guardDev("Settings self-test open") then return end

    if not testController or testController._destroyed then
        emit("open: no live test controller — run /foundrysettings register first")
        return
    end

    emit("open: calling :Open() — the Settings window should open to 'Foundry Settings Test'...")
    emit("  (Gate-2 Q7: did the window OPEN, not just scroll? Close it first if needed.)")
    emit("  (Gate-2 Q8: run from a macro/button — no ADDON_ACTION_FORBIDDEN = PASS.)")
    testController:Open()
    -- :Open() is void on success; errors surface through F:RaiseDevError or as
    -- Lua errors. If execution reaches here, the call did not raise. Whether the
    -- window opened is a visual/manual check only.
    emit("  :Open() returned without error. Inspect the screen.")
end

--------------------------------------------------------------------------------
-- /foundrysettings sub
--
-- Registers a subcategory ("Foundry Settings Sub") under the root test controller.
-- Prints the subcategory's category ID (resolves OQ#1 in-game: does the
-- subcategory object expose :GetID()? Gate-3 confirmed yes by Rawb's probe,
-- returning 35; this confirms the live value in the current session).
--------------------------------------------------------------------------------

local function subHandler()
    if not guardDev("Settings self-test sub") then return end

    if not testController or testController._destroyed then
        emit("sub: no live root controller — run /foundrysettings register first")
        return
    end

    -- Tear down a prior subcategory (from an earlier sub run).
    if subController and not subController._destroyed then
        subController:Destroy()
        subController = nil
        emit("  (prior subcategory controller destroyed before re-register)")
    end

    ensureSubPanel()

    emit("sub: registering subcategory under root controller...")
    subController = F.Settings and F.Settings:New({
        title  = "Foundry Settings Sub",
        frame  = subPanel,
        parent = testController,
        name   = "FoundrySettingsTestSub",
    })

    if not subController then
        emit("  FAIL: Settings:New (subcategory) returned nil")
        return
    end

    local r = newReport()

    -- OQ#1 in-game confirmation: does the subcategory object expose :GetID()?
    -- Gate-3 closed with "yes, returns a number (35 in Rawb's probe)".
    -- Record the live value from this session.
    local subCatID = subController:GetCategoryID()
    if type(subCatID) == "number" then
        emit("  ok:   subcategory GetCategoryID() = " .. tostring(subCatID)
            .. "  (OQ#1 CONFIRMED: subcategory :GetID() returns a number)")
        r.ok = r.ok + 1
    elseif subCatID == nil then
        emit("  ok:   subcategory GetCategoryID() = nil  (legacy path or OQ#1 not met on this client)")
        r.ok = r.ok + 1
    else
        emit("  FAIL: subcategory GetCategoryID() returned unexpected type: " .. type(subCatID))
        r.fail = r.fail + 1
    end

    local h = subController:GetNativeHandles()
    check(r, h ~= nil, "GetNativeHandles() returned a table")
    emit("  mode       = " .. tostring(h and h.mode))
    emit("  categoryID = " .. tostring(h and h.categoryID))
    summary(r, "sub")
    emit("  subcategory controller live. Open Settings to see it nested under the root.")
end

--------------------------------------------------------------------------------
-- /foundrysettings dup
--
-- Attempts to register a second controller using the same name as the live root
-- controller ("FoundrySettingsTest"). The duplicate-key check in Settings:New
-- must refuse it. In a dev build F:RaiseDevError errors (pcall catches it); the
-- live-key registry must remain intact with the original controller untouched.
--------------------------------------------------------------------------------

local function dupHandler()
    if not guardDev("Settings self-test dup") then return end

    if not testController or testController._destroyed then
        emit("dup: no live root controller — run /foundrysettings register first")
        return
    end

    emit("dup: attempting duplicate registration (same name 'FoundrySettingsTest')...")

    -- The duplicate attempt must raise through F:RaiseDevError in a dev build.
    -- pcall catches it so this handler can report the outcome and keep running.
    ensurePanel()  -- reuse the same panel frame; the name is the refusal key, not the frame
    local secondPanel = CreateFrame("Frame", nil, UIParent)
    secondPanel:SetSize(400, 400)

    local dupController = nil
    local ok, err = pcall(function()
        dupController = F.Settings and F.Settings:New({
            title = "Foundry Settings Test Dup",
            frame = secondPanel,
            name  = "FoundrySettingsTest",   -- same key as testController
        })
    end)

    if not ok then
        emit("  ok:   duplicate registration raised (RaiseDevError) — PASS")
        emit("        error = " .. tostring(err))
    elseif dupController == nil then
        -- RaiseDevError may return nil in some environments rather than raise.
        emit("  ok:   duplicate registration returned nil (refused without raise) — PASS")
    else
        emit("  FAIL: duplicate registration returned a controller — refusal did NOT fire")
    end

    -- The original controller must still be live and functional.
    local catID = testController:GetCategoryID()
    if not testController._destroyed and catID ~= nil then
        emit("  ok:   original controller is still live after the refused dup attempt")
    elseif not testController._destroyed then
        emit("  ok:   original controller is still live (legacy path: catID nil is expected)")
    else
        emit("  FAIL: original controller was destroyed by the dup attempt")
    end
end

--------------------------------------------------------------------------------
-- /foundrysettings destroy
--
-- Three-step teardown verification:
--   1. :Destroy() on the root controller — marks it destroyed, frees the key.
--   2. A second :Destroy() (idempotency) — must be a silent no-op (no error).
--   3. :Open() after Destroy — must raise through F:RaiseDevError (pcall catches).
--
-- After this command the upvalue `testController` is set to nil; subsequent
-- commands that need a controller will prompt re-registration.
--------------------------------------------------------------------------------

local function destroyHandler()
    if not guardDev("Settings self-test destroy") then return end

    if not testController or testController._destroyed then
        emit("destroy: no live test controller — run /foundrysettings register first")
        return
    end

    emit("destroy: tearing down root controller...")

    -- MF-7: tear down subController first so its liveKeys entry is freed.
    if subController and not subController._destroyed then
        subController:Destroy()
    end
    subController = nil

    local r = newReport()

    -- Step 1: first :Destroy().
    testController:Destroy()
    check(r, testController._destroyed, ":Destroy() marked controller destroyed")

    -- Step 2: second :Destroy() must be idempotent (no error, no double-free).
    local okDouble, errDouble = pcall(function() testController:Destroy() end)
    check(r, okDouble, "second :Destroy() is idempotent (no error)" ..
        (okDouble and "" or ": " .. tostring(errDouble)))

    -- Step 3: :Open() on a destroyed controller must refuse via F:RaiseDevError.
    local okOpen, errOpen = pcall(function() testController:Open() end)
    check(r, not okOpen, ":Open() after Destroy raised (refused)")
    if not okOpen then
        emit("        error = " .. tostring(errOpen))
    end

    -- Bonus: GetCategoryID and GetNativeHandles should also refuse.
    local okGetID = pcall(function() testController:GetCategoryID() end)
    check(r, not okGetID, ":GetCategoryID() after Destroy raised")

    local okHandles = pcall(function() testController:GetNativeHandles() end)
    check(r, not okHandles, ":GetNativeHandles() after Destroy raised")

    -- Step 4 (SF-8): verify the name key was freed — re-registration must succeed.
    ensurePanel()
    local reRegOk, reRegErr = pcall(function()
        local reController = F.Settings and F.Settings:New({
            title = "Foundry Settings Test Reregister",
            frame = testPanel,
            name  = "FoundrySettingsTest",
        })
        if reController then reController:Destroy() end
    end)
    check(r, reRegOk, "name key freed by :Destroy() — re-registration succeeded" ..
        (reRegOk and "" or ": " .. tostring(reRegErr)))

    testController = nil

    summary(r, "destroy")
    emit("  Controllers cleared. Run /foundrysettings register to rebuild.")
end

--------------------------------------------------------------------------------
-- /foundrysettings stop
--
-- Cleans up any live test controllers and reports state cleared. Safe to call
-- at any time — cleans up even partially-constructed state.
--------------------------------------------------------------------------------

local function stopHandler()
    if not guardDev("Settings self-test stop") then return end

    local hadRoot = testController and not testController._destroyed
    local hadSub  = subController  and not subController._destroyed

    teardownAll()

    if hadRoot or hadSub then
        emit("stop: live controllers destroyed and state cleared.")
    else
        emit("stop: no live controllers — state already clear.")
    end
end

--------------------------------------------------------------------------------
-- Command registration (gates 2b + 2c)
-- /foundrysettings is this instrument's OWN slash; it cannot share any other
-- Dev controller because Commands:New refuses duplicate slashes and the second
-- registrant would silently lose its commands.
-- Gate (2b): every handler also early-returns through guardDev() — defense in
-- depth behind the file-level IS_DEV_BUILD return and the TOC exclusion.
--------------------------------------------------------------------------------

local devCommands = F.Commands and F.Commands:New({
    name        = "FoundrySettingsTest",
    slashes     = { "/foundrysettings" },
    description = "Foundry.Settings in-game self-test (dev-build only). "
        .. "Run /foundrysettings register first, then use subcommands.",
    defaultHandler = registerHandler,
})

if devCommands then
    devCommands:Register({
        name    = "register",
        help    = "Register a root test category ('Foundry Settings Test') and print the category ID. "
            .. "Tears down any prior test controller first.",
        handler = registerHandler,
    })
    devCommands:Register({
        name    = "open",
        help    = "Call :Open() on the registered controller. Settings panel should open to the test category. "
            .. "Q7: close the Settings window first. Q8: run from a macro button.",
        handler = openHandler,
    })
    devCommands:Register({
        name    = "sub",
        help    = "Register a subcategory ('Foundry Settings Sub') under the root. "
            .. "Prints subcategory category ID (OQ#1 in-game confirmation).",
        handler = subHandler,
    })
    devCommands:Register({
        name    = "dup",
        help    = "Attempt a duplicate registration (same name). Expects RaiseDevError. "
            .. "Original controller must remain live. PASS if refused.",
        handler = dupHandler,
    })
    devCommands:Register({
        name    = "destroy",
        help    = "Destroy the root controller. Verifies idempotency and that all methods "
            .. "refuse post-Destroy. Clears state.",
        handler = destroyHandler,
    })
    devCommands:Register({
        name    = "stop",
        help    = "Tear down all live test controllers and clear state. Safe at any time.",
        handler = stopHandler,
    })
end

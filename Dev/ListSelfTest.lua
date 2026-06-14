-- Foundry.List in-game self-test (DEV-ONLY — never ships).
--
-- List is a VISUAL module: its load-bearing behaviors — virtualized render,
-- frame recycling on scroll, in-place repaint, the variable-height calculator
-- path, replace-while-scrolled, and the empty state — are unobservable by the
-- headless harness (no real ScrollBox, no frames, no scroll). For a visual module
-- the visible/scrollable artifact IS the primary Gate-2 evidence, so this command
-- builds a REAL list on screen and exercises EVERY v1 API path, then prints a
-- labelled PASS/FAIL report for the parts that are assertable in code.
--
-- v1 surface is the FOUR-method controller only — SetData, ForEachFrame,
-- GetNativeHandles, Destroy. This instrument deliberately uses NOTHING outside it:
-- no native selection, no Insert/Remove/Refresh, no multi-template factory /
-- SetElementFactory, no emptyText. (Each cut surface is reachable raw via
-- :GetNativeHandles if a consumer ever needs it; spec Q4–Q7.)
--
-- TRIPLE-GATED OFF for players:
--   (1) This file is NOT listed in Foundry-1.0.toc, and .pkgmeta `ignore: Dev`
--       strips the whole Dev/ tree from the packaged addon, so a released build
--       never contains it (the primary gate — exactly like Tests/).
--   (2) Both registration AND every command handler early-return through
--       F:RaiseDevError when not F.IS_DEV_BUILD, so even if the file were force-
--       loaded it refuses in a release build.
--   (3) The commands are registered through a private F.Commands:New controller
--       (/foundrylist — its OWN controller and slash, mirroring DBSelfTest's
--       /foundrydb: Commands:New refuses duplicate slashes, so a separate Dev file
--       CANNOT share Lifecycle's /foundrydev controller — whichever loaded second
--       would silently lose its registration). No raw SLASH_* global is written.

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: ListSelfTest.lua requires the Foundry-1.0 bootstrap "
        .. "(Foundry.lua) to have loaded first; _G.Foundry_1_0 is missing.", 0)
end

-- Gate (2a): never even build the commands in a release build.
if not F.IS_DEV_BUILD then
    return
end

--------------------------------------------------------------------------------
-- Report plumbing (the LifecycleSelfTest / DBSelfTest template)
--------------------------------------------------------------------------------

-- Each run accumulates a fresh report; a check() appends a labelled line and
-- tracks pass/fail counts so the run can print a final summary. Failing checks
-- are prefixed "FAIL:" and the run CONTINUES, so the developer sees the full
-- picture in one pass rather than aborting at the first failure.
local function newReport(out)
    return {
        out = out,
        passed = 0,
        failed = 0,
    }
end

local function check(report, ok, label)
    if ok then
        report.passed = report.passed + 1
        report.out("  ok:   " .. label)
    else
        report.failed = report.failed + 1
        report.out("  FAIL: " .. label)
    end
    return ok
end

local function emit(line)
    print(line)
end

--------------------------------------------------------------------------------
-- Demo data
--------------------------------------------------------------------------------

-- ~200 synthetic rows so virtualization is visible: only a screenful of frames is
-- ever realized for 200 rows, and scrolling recycles them. Fresh tables each call
-- (List holds rows by reference; independent tables keep repeated runs honest).
local FIXED_ROW_COUNT = 200

local function makeFixedRows()
    local rows = {}
    for i = 1, FIXED_ROW_COUNT do
        rows[i] = { id = i, label = "Row " .. i }
    end
    return rows
end

-- A second row set whose tables carry a per-row height, to drive the
-- extentCalculator (variable-height) path. The heights cycle so the visual
-- result is obviously non-uniform.
local function makeVariableRows()
    local rows = {}
    local heights = { 20, 28, 36, 44 }
    for i = 1, 80 do
        rows[i] = { id = i, label = "Var row " .. i, rowHeight = heights[(i % #heights) + 1] }
    end
    return rows
end

-- An alternate fixed set used by the "replace" path so the swap is visibly a
-- different list (different labels), not the same rows re-laid-out.
local function makeReplacementRows()
    local rows = {}
    for i = 1, 50 do
        rows[i] = { id = i, label = "Replaced " .. i }
    end
    return rows
end

--------------------------------------------------------------------------------
-- The visible demo frame (built lazily, reused across runs)
--------------------------------------------------------------------------------

-- The host frame and its current List controller live in upvalues so re-running
-- /foundrylist rebuilds on the SAME parent without leaking frames. CreateFrame is
-- never called at file scope (it runs inside ensureHost, reached only from a
-- handler) per api-conventions.
local host
local demoList
local listParent
local selectedId  -- the consumer-owned selection key (NO native selection in v1)

-- Repaint one row's highlight to reflect the current selection. Called from the
-- initializer (so freshly-realized/recycled rows paint correctly) AND from the
-- click handler via ForEachFrame (so the visible rows repaint in place with no
-- provider rebuild). This is the both-consumers selection style. The highlight is
-- a plain child texture (works on any frame type — a bare "Button" has no backdrop
-- mixin), shown/hidden rather than recreated so recycled rows reuse it.
local function paintRow(frame, elementData)
    if frame._st_hl then
        frame._st_hl:SetShown(elementData ~= nil and elementData.id == selectedId)
    end
end

-- Build (once) the host frame, its control buttons, and a status line. The List
-- itself is created in spawnDemo so a run after Destroy rebuilds it cleanly.
local function ensureHost()
    if host then return end

    host = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    host:SetSize(320, 460)
    host:SetPoint("CENTER")
    host:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    host:SetMovable(true)
    host:EnableMouse(true)
    host:RegisterForDrag("LeftButton")
    host:SetScript("OnDragStart", host.StartMoving)
    host:SetScript("OnDragStop", host.StopMovingOrSizing)

    local title = host:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -10)
    title:SetText("Foundry.List self-test (dev)")

    -- The List fills a region with room reserved for a control row at the bottom.
    listParent = CreateFrame("Frame", nil, host)
    listParent:SetPoint("TOPLEFT", 12, -32)
    listParent:SetPoint("BOTTOMRIGHT", -16, 44)

    -- A small bank of buttons drives every v1 path by hand (a visual demo reads
    -- better with on-frame controls than typed subcommands; the subcommands also
    -- exist for completeness).
    local function makeButton(text, anchorX, onClick)
        local b = CreateFrame("Button", nil, host, "UIPanelButtonTemplate")
        b:SetSize(72, 22)
        b:SetPoint("BOTTOMLEFT", anchorX, 12)
        b:SetText(text)
        b:SetScript("OnClick", onClick)
        return b
    end

    makeButton("Replace", 12, function() F._ListSelfTest_replace() end)
    makeButton("Variable", 88, function() F._ListSelfTest_variable() end)
    makeButton("Empty", 164, function() F._ListSelfTest_empty() end)
    makeButton("Destroy", 240, function() F._ListSelfTest_destroy() end)

    host:Hide()
end

-- (Re)build a fixed-height demo list on the host frame. Returns the controller (or
-- nil on failure). Tears down any prior controller first so frames are not leaked.
local function spawnFixedDemo()
    ensureHost()
    if demoList and not demoList._destroyed then
        demoList:Destroy()
    end
    selectedId = nil

    demoList = F.List:New({
        name = "FoundryListSelfTest",
        parent = listParent,
        elementType = "Button",
        extent = 24,
        managedScrollBarVisibility = true,
        initializer = function(frame, elementData)
            -- Build the row's text + highlight texture lazily, so a recycled frame
            -- keeps the children it already has (no per-acquire allocation).
            if not frame._st_built then
                frame._st_hl = frame:CreateTexture(nil, "BACKGROUND")
                frame._st_hl:SetAllPoints()
                frame._st_hl:SetColorTexture(0.2, 0.5, 0.9, 0.5)
                frame._st_hl:Hide()
                frame._st_text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                frame._st_text:SetPoint("LEFT", 6, 0)
                frame._st_built = true
            end
            frame._st_text:SetText(elementData.label)
            frame:SetScript("OnClick", function()
                selectedId = elementData.id
                emit("Foundry.List self-test: selected " .. tostring(elementData.label))
                -- In-place repaint via ForEachFrame: touch only the realized rows,
                -- no provider rebuild, no scroll jump. (NOT native selection.)
                demoList:ForEachFrame(paintRow)
            end)
            paintRow(frame, elementData)
        end,
        -- Symmetric resetter: tear down what the initializer wired so a recycled
        -- frame carries no stale state/handler into its next data row.
        resetter = function(frame)
            frame:SetScript("OnClick", nil)
            if frame._st_text then frame._st_text:SetText("") end
            if frame._st_hl then frame._st_hl:Hide() end
        end,
    })
    return demoList
end

--------------------------------------------------------------------------------
-- The main run: build the visible list and assert the code-checkable parts.
--------------------------------------------------------------------------------

local function runSpawn(out)
    local report = newReport(out)
    out("Foundry.List self-test: spawn 200-row demo list (visible artifact)")

    local List = F.List
    if not List then
        out("  FAIL: F.List module is not present")
        report.failed = report.failed + 1
        return report
    end

    local list = spawnFixedDemo()
    if not check(report, list ~= nil, "List:New returned a controller") then
        out(string.format("Summary: %d ok, %d FAIL (aborted: no controller)",
            report.passed, report.failed))
        return report
    end

    host:Show()

    -- The native composition is reachable and live.
    local h = list:GetNativeHandles()
    check(report, type(h) == "table", "GetNativeHandles returned a table")
    check(report, h ~= nil and h.scrollBox ~= nil, "native scrollBox present")
    check(report, h ~= nil and h.scrollBar ~= nil, "native scrollBar present")
    check(report, h ~= nil and h.view ~= nil, "native view present")
    check(report, h ~= nil and h.dataProvider ~= nil,
        "native dataProvider present (empty provider seeded at :New)")

    -- Load the rows. After SetData the provider reports the full size even though
    -- only a screenful of frames is realized — that gap IS the virtualization.
    list:SetData(makeFixedRows())
    local h2 = list:GetNativeHandles()
    check(report, h2 ~= nil and h2.dataProvider ~= nil
        and h2.dataProvider:GetSize() == FIXED_ROW_COUNT,
        "SetData loaded all " .. FIXED_ROW_COUNT .. " rows into the provider")

    -- ForEachFrame visits only the REALIZED rows (a screenful), never all 200 —
    -- the in-place-repaint contract. The count is layout-dependent, so assert the
    -- weaker, robust invariants: it visits at least one and far fewer than total.
    local realized = 0
    list:ForEachFrame(function() realized = realized + 1 end)
    check(report, realized > 0, "ForEachFrame visited at least one realized row")
    check(report, realized < FIXED_ROW_COUNT,
        "ForEachFrame visited only the realized screenful (" .. realized
            .. " < " .. FIXED_ROW_COUNT .. "), proving virtualization")

    -- A truthy return stops iteration early.
    local visited = 0
    list:ForEachFrame(function() visited = visited + 1; return true end)
    check(report, visited == 1, "ForEachFrame stops on the first truthy return")

    out("  (manual Gate-2: scroll top<->bottom — rows recycle, no stale text/state;")
    out("   click a row — its highlight repaints in place; use the on-frame buttons")
    out("   for Replace / Variable / Empty / Destroy.)")
    out(string.format("Summary: %d ok, %d FAIL", report.passed, report.failed))
    return report
end

--------------------------------------------------------------------------------
-- SetData drives: replace (incl. replace-while-scrolled), variable-height, empty.
--------------------------------------------------------------------------------

local function runReplace(out)
    local report = newReport(out)
    out("Foundry.List self-test: SetData replace (drive while scrolled to test rebuild)")

    if not (demoList and not demoList._destroyed) then
        out("  FAIL: no live demo list — run /foundrylist first")
        report.failed = report.failed + 1
        return report
    end

    -- The visual point: if the developer scrolled mid-list before clicking
    -- Replace, the list rebuilds cleanly and scrolls back to top (SetData builds a
    -- fresh provider — full replace, not an in-place recycle). The assertable part
    -- is that the new size took.
    demoList:SetData(makeReplacementRows())
    selectedId = nil
    local h = demoList:GetNativeHandles()
    check(report, h ~= nil and h.dataProvider ~= nil and h.dataProvider:GetSize() == 50,
        "replace-while-scrolled: provider rebuilt to the new row set (50)")
    out("  (manual Gate-2: the list rebuilt cleanly and jumped to the top, no artifact.)")
    out(string.format("Summary: %d ok, %d FAIL", report.passed, report.failed))
    return report
end

local function runVariable(out)
    local report = newReport(out)
    out("Foundry.List self-test: extentCalculator (variable row height) demo")

    if not (demoList and not demoList._destroyed) then
        out("  FAIL: no live demo list — run /foundrylist first")
        report.failed = report.failed + 1
        return report
    end

    -- The calculator path is a DIFFERENT list (extent and extentCalculator are
    -- mutually exclusive, so it cannot be retro-fitted onto the fixed-extent demo).
    -- Replace the demo list with a calculator-driven one on the same parent.
    demoList:Destroy()
    selectedId = nil
    demoList = F.List:New({
        name = "FoundryListSelfTestVariable",
        parent = listParent,
        elementType = "Button",
        extentCalculator = function(_, elementData)
            return elementData.rowHeight or 24
        end,
        managedScrollBarVisibility = true,
        initializer = function(frame, elementData)
            if not frame._st_built then
                frame._st_text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                frame._st_text:SetPoint("LEFT", 6, 0)
                frame._st_built = true
            end
            frame._st_text:SetText(elementData.label .. " (h=" .. elementData.rowHeight .. ")")
        end,
        resetter = function(frame)
            if frame._st_text then frame._st_text:SetText("") end
        end,
    })

    if not check(report, demoList ~= nil, "extentCalculator List:New returned a controller") then
        out(string.format("Summary: %d ok, %d FAIL", report.passed, report.failed))
        return report
    end

    demoList:SetData(makeVariableRows())
    local h = demoList:GetNativeHandles()
    check(report, h ~= nil and h.dataProvider ~= nil and h.dataProvider:GetSize() == 80,
        "variable-height list loaded its rows (80)")
    out("  (manual Gate-2: rows render at visibly different heights, no gaps/overlap.)")
    out(string.format("Summary: %d ok, %d FAIL", report.passed, report.failed))
    return report
end

local function runEmpty(out)
    local report = newReport(out)
    out("Foundry.List self-test: empty state (SetData({}) renders an empty list, no text)")

    if not (demoList and not demoList._destroyed) then
        out("  FAIL: no live demo list — run /foundrylist first")
        report.failed = report.failed + 1
        return report
    end

    demoList:SetData({})
    selectedId = nil
    local h = demoList:GetNativeHandles()
    check(report, h ~= nil and h.dataProvider ~= nil and h.dataProvider:GetSize() == 0,
        "empty SetData: provider holds zero rows")
    local realized = 0
    demoList:ForEachFrame(function() realized = realized + 1 end)
    check(report, realized == 0, "empty SetData: no rows realized")
    out("  (manual Gate-2: the list area is empty — List renders NO placeholder text"
        .. " — no emptyText in v1.)")
    out(string.format("Summary: %d ok, %d FAIL", report.passed, report.failed))
    return report
end

--------------------------------------------------------------------------------
-- Destroy drive: tear down, then prove every v1 method refuses post-Destroy.
--------------------------------------------------------------------------------

local function runDestroy(out)
    local report = newReport(out)
    out("Foundry.List self-test: Destroy, then every method refuses post-Destroy")

    if not (demoList and not demoList._destroyed) then
        out("  FAIL: no live demo list to destroy — run /foundrylist first")
        report.failed = report.failed + 1
        return report
    end

    local dead = demoList
    dead:Destroy()
    check(report, dead._destroyed == true, "Destroy marked the controller destroyed")

    -- Each method raises through F:RaiseDevError in a dev build, so pcall each and
    -- assert it refused. The run continues regardless.
    local okSetData = pcall(function() dead:SetData({}) end)
    check(report, not okSetData, "SetData refuses after Destroy")
    local okForEach = pcall(function() dead:ForEachFrame(function() end) end)
    check(report, not okForEach, "ForEachFrame refuses after Destroy")
    local okHandles = pcall(function() dead:GetNativeHandles() end)
    check(report, not okHandles, "GetNativeHandles refuses after Destroy")
    local okDestroy = pcall(function() dead:Destroy() end)
    check(report, not okDestroy, "a second Destroy refuses after Destroy")

    demoList = nil
    if host then host:Hide() end
    out("  (manual Gate-2: the list disappeared from the host frame, no Lua error.)")
    out("  Re-run /foundrylist to rebuild a fresh demo list on the same frame.")
    out(string.format("Summary: %d ok, %d FAIL", report.passed, report.failed))
    return report
end

--------------------------------------------------------------------------------
-- Button bridges (the on-frame controls call through F-namespaced shims so the
-- buttons created in ensureHost have a stable target; dev-only).
--------------------------------------------------------------------------------

function F._ListSelfTest_replace() runReplace(emit) end
function F._ListSelfTest_variable() runVariable(emit) end
function F._ListSelfTest_empty() runEmpty(emit) end
function F._ListSelfTest_destroy() runDestroy(emit) end

--------------------------------------------------------------------------------
-- Command registration (gate 2b + 2c)
--------------------------------------------------------------------------------

-- Gate (2b): every handler ALSO early-returns through RaiseDevError if somehow
-- reached in a release build — defense in depth behind the file-level return and
-- the TOC/.pkgmeta exclusion.
local function guardDev(name)
    if not F.IS_DEV_BUILD then
        F:RaiseDevError(name .. " is dev-build only")
        return false
    end
    return true
end

local function spawnHandler()
    if not guardDev("List self-test") then return end
    runSpawn(emit)
end

local function replaceHandler()
    if not guardDev("List self-test") then return end
    runReplace(emit)
end

local function variableHandler()
    if not guardDev("List self-test") then return end
    runVariable(emit)
end

local function emptyHandler()
    if not guardDev("List self-test") then return end
    runEmpty(emit)
end

local function destroyHandler()
    if not guardDev("List self-test") then return end
    runDestroy(emit)
end

-- Gate (2c): register through a private F.Commands controller, so no raw SLASH_*
-- global is written. /foundrylist is List's OWN dev surface — it CANNOT share
-- /foundrydev (Lifecycle's): Commands:New refuses duplicate slashes, and in a
-- combined dev session the second registrant would silently lose its command.
-- This mirrors DBSelfTest's own /foundrydb split. Bare /foundrylist spawns the
-- demo (its defaultHandler); subcommands drive the SetData/Destroy paths.
local devCommands = F.Commands and F.Commands:New({
    name = "FoundryList",
    slashes = { "/foundrylist" },
    description = "Foundry.List developer self-test (dev-build only). "
        .. "Bare command spawns the demo list.",
    defaultHandler = spawnHandler,
})

if devCommands then
    devCommands:Register({
        name = "spawn",
        help = "(Re)build the 200-row demo list and run the spawn assertions.",
        handler = spawnHandler,
    })
    devCommands:Register({
        name = "replace",
        help = "SetData a different row set (scroll first to test replace-while-scrolled).",
        handler = replaceHandler,
    })
    devCommands:Register({
        name = "variable",
        help = "Swap in an extentCalculator (variable-height) demo list.",
        handler = variableHandler,
    })
    devCommands:Register({
        name = "empty",
        help = "SetData({}) — show the empty state (List renders no text).",
        handler = emptyHandler,
    })
    devCommands:Register({
        name = "destroy",
        help = "Destroy the demo list, then prove every method refuses post-Destroy.",
        handler = destroyHandler,
    })
end

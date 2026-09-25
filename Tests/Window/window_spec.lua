-- Foundry.Window behavior tests. Loaded by Tests/run.lua, which passes the
-- harness table T. Returns a list of { name, fn } cases covering the v1
-- public contract: atomic :Attach validation (with ordering), the
-- SetMovable -> SetUserPlaced(false) -> SetClampedToScreen invariant at
-- Attach, the drag-stop SetUserPlaced(false) -> save invariant, restore
-- (empty/valid/garbage geometry), the OnDragStop save guard (reparenting and
-- a non-UIParent-relative anchor), :Reset, the release axis, and version pins.
--
-- Stub design: makeFrame() builds a stub frame via the shared CreateFrame
-- mock (Tests/run.lua), parented to UIParent by default. frame._seq is the
-- ordered cross-method call log the stub appends SetMovable/SetClampedToScreen/
-- RegisterForDrag/EnableMouse/StartMoving/StopMovingOrSizing/SetUserPlaced to;
-- it is what proves call ORDER, which a per-method call count cannot.

local T = ...

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

--------------------------------------------------------------------------------
-- Per-test surface helpers
--------------------------------------------------------------------------------

-- A stub frame via the shared CreateFrame mock. Parented to UIParent unless a
-- different parent is supplied (used to exercise the parent-check refusal).
local function makeFrame(parent)
    return _G.CreateFrame("Frame", nil, parent or _G.UIParent)
end

-- A fresh default literal per call: {"CENTER", "CENTER", 0, 0}. Window:Attach
-- never mutates the caller's table, so reuse would be safe too, but a fresh
-- table per test keeps each case self-contained.
local function makeDefault()
    return { "CENTER", "CENTER", 0, 0 }
end

-- Builds win/handle/geometry/default and calls Attach, returning everything
-- the caller might want to inspect. Every field is overridable.
local function attach(F, over)
    over = over or {}
    local win = over.win or makeFrame(over.parent)
    local handle = over.handle or win
    local geometry = over.geometry or {}
    local default = over.default or makeDefault()
    local ret = F.Window:Attach(win, { handle = handle, geometry = geometry, default = default })
    return ret, win, handle, geometry, default
end

-- Asserts a refused Attach touched nothing on win: no movement/persistence
-- method fired (frame._seq), and no script or anchor call was made. `before`
-- names each bucket's expected pre-existing count, for a test that seeds win
-- with its own calls (a pre-set drag script, or a prior successful Attach)
-- before the refused call under test.
local function assertUntouched(win, before)
    before = before or {}
    T.eq(#win._seq, before.seq or 0, "no movement/persistence methods called")
    T.eq(#win.calls.SetScript, before.scripts or 0, "no SetScript calls")
    T.eq(#win.calls.SetPoint, before.points or 0, "no SetPoint calls")
    T.eq(#win.calls.ClearAllPoints, before.clears or 0, "no ClearAllPoints calls")
end

--------------------------------------------------------------------------------
-- Version pins
--------------------------------------------------------------------------------

test("version pins: Window.API_VERSION == 1", function()
    local F = T.fresh()
    T.eq(F.Window.API_VERSION, 1, "Window per-module API_VERSION == 1")
    T.eq(F:RequireModule("Window", 1), F.Window, "RequireModule min=1 returns the module")
    T.raises(function() F:RequireModule("Window", 99) end, "RequireModule too-high", "version")
end)

test("library API_VERSION does not advance when Window is loaded", function()
    local F = T.fresh()
    T.eq(F.API_VERSION, 6, "library API_VERSION unchanged after Window load")
end)

--------------------------------------------------------------------------------
-- Attach validation: win must be a frame
--------------------------------------------------------------------------------

test("Attach: non-table win refused", function()
    local F = T.fresh()
    T.raises(function() F.Window:Attach("nope", {}) end, "non-table win", "win must be a frame")
end)

test("Attach: table win missing required methods refused", function()
    local F = T.fresh()
    T.raises(function() F.Window:Attach({}, {}) end, "bare-table win", "win must be a frame")
end)

--------------------------------------------------------------------------------
-- Attach validation: win must be parented to UIParent
--------------------------------------------------------------------------------

test("Attach: win not parented to UIParent refused", function()
    local F = T.fresh()
    local win = makeFrame({})
    T.raises(function() F.Window:Attach(win, { handle = win, geometry = {}, default = makeDefault() }) end,
        "wrong parent", "win must be parented directly to UIParent")
    assertUntouched(win)
end)

test("Attach: parent check surfaces before config-table check", function()
    local F = T.fresh()
    local win = makeFrame({})
    T.raises(function() F.Window:Attach(win, "nope") end,
        "parent-before-config", "win must be parented directly to UIParent")
    assertUntouched(win)
end)

--------------------------------------------------------------------------------
-- Attach validation: already attached
--------------------------------------------------------------------------------

test("Attach: second Attach on the same frame refused", function()
    local F = T.fresh()
    local ret1, win = attach(F)
    T.truthy(ret1, "first attach succeeds")
    local baseline = {
        seq = #win._seq, scripts = #win.calls.SetScript,
        points = #win.calls.SetPoint, clears = #win.calls.ClearAllPoints,
    }
    T.raises(function() F.Window:Attach(win, { handle = makeFrame(), geometry = {}, default = makeDefault() }) end,
        "double attach", "already attached; Foundry.Window does not re-attach")
    assertUntouched(win, baseline)
end)

test("Attach: already-attached check surfaces before config-table check", function()
    local F = T.fresh()
    local _, win = attach(F)
    local baseline = {
        seq = #win._seq, scripts = #win.calls.SetScript,
        points = #win.calls.SetPoint, clears = #win.calls.ClearAllPoints,
    }
    T.raises(function() F.Window:Attach(win, "not a table") end,
        "already-attached before config", "already attached; Foundry.Window does not re-attach")
    assertUntouched(win, baseline)
end)

--------------------------------------------------------------------------------
-- Attach validation: registry atomicity (a refused Attach must not poison the
-- registry -- a later correct Attach on the same frame must still succeed)
--------------------------------------------------------------------------------

test("Attach: a refused Attach (bad default) does not block a later correct Attach on the same frame", function()
    local F = T.fresh()
    local win = makeFrame()
    T.raises(function() F.Window:Attach(win, { handle = win, geometry = {}, default = { "BOGUS", "CENTER", 0, 0 } }) end,
        "bad default refused", "config.default must be")
    local ret = F.Window:Attach(win, { handle = win, geometry = {}, default = makeDefault() })
    T.eq(ret, win, "a correct Attach after a refused one succeeds")
end)

test("Attach: a refused Attach (bad geometry) does not block a later correct Attach on the same frame", function()
    local F = T.fresh()
    local win = makeFrame()
    T.raises(function() F.Window:Attach(win, { handle = win, geometry = "bad", default = makeDefault() }) end,
        "bad geometry refused", "config.geometry must be a table")
    local ret = F.Window:Attach(win, { handle = win, geometry = {}, default = makeDefault() })
    T.eq(ret, win, "a correct Attach after a refused one succeeds")
end)

--------------------------------------------------------------------------------
-- Attach validation: config must be a table
--------------------------------------------------------------------------------

test("Attach: non-table config refused", function()
    local F = T.fresh()
    local win = makeFrame()
    T.raises(function() F.Window:Attach(win, "nope") end, "non-table config", "config must be a table")
    assertUntouched(win)
end)

--------------------------------------------------------------------------------
-- Attach validation: config.handle
--------------------------------------------------------------------------------

test("Attach: missing handle refused", function()
    local F = T.fresh()
    local win = makeFrame()
    T.raises(function() F.Window:Attach(win, { geometry = {}, default = makeDefault() }) end,
        "missing handle", "config.handle must be a frame")
    assertUntouched(win)
end)

test("Attach: handle lacking RegisterForDrag refused", function()
    local F = T.fresh()
    local win = makeFrame()
    T.raises(function() F.Window:Attach(win, { handle = {}, geometry = {}, default = makeDefault() }) end,
        "bare-table handle", "config.handle must be a frame")
    assertUntouched(win)
end)

test("Attach: handle already has OnDragStart refused", function()
    local F = T.fresh()
    local win = makeFrame()
    win:SetScript("OnDragStart", function() end)
    T.raises(function() F.Window:Attach(win, { handle = win, geometry = {}, default = makeDefault() }) end,
        "existing OnDragStart", "handle already has drag scripts; Foundry.Window owns OnDragStart/OnDragStop")
    assertUntouched(win, { scripts = 1 })
end)

test("Attach: handle already has OnDragStop refused", function()
    local F = T.fresh()
    local win = makeFrame()
    win:SetScript("OnDragStop", function() end)
    T.raises(function() F.Window:Attach(win, { handle = win, geometry = {}, default = makeDefault() }) end,
        "existing OnDragStop", "handle already has drag scripts; Foundry.Window owns OnDragStart/OnDragStop")
    assertUntouched(win, { scripts = 1 })
end)

--------------------------------------------------------------------------------
-- Attach validation: config.geometry
--------------------------------------------------------------------------------

test("Attach: non-table geometry refused", function()
    local F = T.fresh()
    local win = makeFrame()
    T.raises(function() F.Window:Attach(win, { handle = win, geometry = "nope", default = makeDefault() }) end,
        "non-table geometry", "config.geometry must be a table")
    assertUntouched(win)
end)

test("Attach: handle check surfaces before geometry check", function()
    local F = T.fresh()
    local win = makeFrame()
    T.raises(function() F.Window:Attach(win, { handle = {}, geometry = "bad", default = makeDefault() }) end,
        "handle-before-geometry", "config.handle must be a frame")
    assertUntouched(win)
end)

--------------------------------------------------------------------------------
-- Attach validation: config.default
--------------------------------------------------------------------------------

test("Attach: missing default refused", function()
    local F = T.fresh()
    local win = makeFrame()
    T.raises(function() F.Window:Attach(win, { handle = win, geometry = {} }) end,
        "missing default", "config.default must be")
    assertUntouched(win)
end)

test("Attach: default with unwhitelisted point name refused", function()
    local F = T.fresh()
    local win = makeFrame()
    T.raises(function() F.Window:Attach(win, { handle = win, geometry = {}, default = { "BOGUS", "CENTER", 0, 0 } }) end,
        "bad point name", "config.default must be")
    assertUntouched(win)
end)

test("Attach: default with unwhitelisted relPoint refused", function()
    local F = T.fresh()
    local win = makeFrame()
    T.raises(function() F.Window:Attach(win, { handle = win, geometry = {}, default = { "CENTER", "BOGUS", 0, 0 } }) end,
        "bad relPoint name", "config.default must be")
    assertUntouched(win)
end)

test("Attach: default with a non-number offset refused", function()
    local F = T.fresh()
    local win = makeFrame()
    T.raises(function() F.Window:Attach(win, { handle = win, geometry = {}, default = { "CENTER", "CENTER", "0", 0 } }) end,
        "string offset", "config.default must be")
    assertUntouched(win)
end)

test("Attach: default with a NaN offset refused", function()
    local F = T.fresh()
    local win = makeFrame()
    local nan = 0 / 0
    T.raises(function() F.Window:Attach(win, { handle = win, geometry = {}, default = { "CENTER", "CENTER", nan, 0 } }) end,
        "NaN offset", "config.default must be")
    assertUntouched(win)
end)

test("Attach: default with a +inf offset refused", function()
    local F = T.fresh()
    local win = makeFrame()
    T.raises(function() F.Window:Attach(win, { handle = win, geometry = {}, default = { "CENTER", "CENTER", math.huge, 0 } }) end,
        "+inf offset", "config.default must be")
    assertUntouched(win)
end)

test("Attach: default with a -inf offset refused", function()
    local F = T.fresh()
    local win = makeFrame()
    T.raises(function() F.Window:Attach(win, { handle = win, geometry = {}, default = { "CENTER", "CENTER", -math.huge, 0 } }) end,
        "-inf offset", "config.default must be")
    assertUntouched(win)
end)

test("Attach: geometry check surfaces before default check", function()
    local F = T.fresh()
    local win = makeFrame()
    T.raises(function() F.Window:Attach(win, { handle = win, geometry = "bad", default = "also bad" }) end,
        "geometry-before-default", "config.geometry must be a table")
    assertUntouched(win)
end)

--------------------------------------------------------------------------------
-- Attach effects
--------------------------------------------------------------------------------

test("Attach effects: SetMovable(true), SetUserPlaced(false), SetClampedToScreen(true) in order", function()
    local F = T.fresh()
    local _, win = attach(F)
    T.eq(win.calls.SetMovable[1][1], true, "SetMovable(true) recorded")
    T.eq(win.calls.SetClampedToScreen[1][1], true, "SetClampedToScreen(true) recorded")
    T.eq(win._seq[1][1], "SetMovable", "seq[1] is SetMovable")
    T.eq(win._seq[1][2], true, "seq[1] arg is true")
    T.eq(win._seq[2][1], "SetUserPlaced", "seq[2] is SetUserPlaced, immediately after SetMovable")
    T.eq(win._seq[2][2], false, "seq[2] arg is false")
    T.eq(win._seq[3][1], "SetClampedToScreen", "seq[3] is SetClampedToScreen")
end)

test("Attach effects: returns win", function()
    local F = T.fresh()
    local ret, win = attach(F)
    T.eq(ret, win, "Attach returns win on success")
end)

test("Attach effects: handle gets EnableMouse(true), RegisterForDrag(LeftButton), two SetScript calls", function()
    local F = T.fresh()
    local _, win = attach(F)
    T.eq(win.calls.EnableMouse[1][1], true, "EnableMouse(true)")
    T.eq(win.calls.RegisterForDrag[1][1], "LeftButton", "RegisterForDrag(LeftButton)")
    T.eq(#win.calls.SetScript, 2, "two SetScript calls")
    local names = {}
    for _, c in ipairs(win.calls.SetScript) do names[c[1]] = true end
    T.truthy(names.OnDragStart, "OnDragStart installed")
    T.truthy(names.OnDragStop, "OnDragStop installed")
end)

test("Attach effects: handle may be a different frame than win", function()
    local F = T.fresh()
    local handle = makeFrame()
    local ret, win = attach(F, { handle = handle })
    T.eq(ret, win, "returns win")
    T.eq(#handle.calls.EnableMouse, 1, "handle got EnableMouse")
    T.eq(#win.calls.EnableMouse, 0, "win itself did not")
    T.eq(win.calls.SetMovable[1][1], true, "win still got SetMovable")
end)

--------------------------------------------------------------------------------
-- Restore
--------------------------------------------------------------------------------

test("Restore: empty geometry applies the default", function()
    local F = T.fresh()
    local _, win = attach(F, { geometry = {}, default = { "CENTER", "CENTER", 0, 0 } })
    local p = win._points
    T.eq(p.point, "CENTER", "point = default")
    T.eq(p.relativeTo, _G.UIParent, "relativeTo = UIParent")
    T.eq(p.relPoint, "CENTER", "relPoint = default")
    T.eq(p.x, 0, "x = default")
    T.eq(p.y, 0, "y = default")
end)

test("Restore: valid geometry applies the saved record", function()
    local F = T.fresh()
    -- point and relPoint are deliberately different anchors here (not the usual
    -- CENTER/CENTER or TOPLEFT/TOPLEFT test fixture) so a swap between them in
    -- apply() shows up as a failure instead of passing unnoticed.
    local geometry = { point = "TOPLEFT", relPoint = "BOTTOMRIGHT", x = 16, y = -104 }
    local _, win = attach(F, { geometry = geometry, default = { "CENTER", "CENTER", 0, 0 } })
    local p = win._points
    T.eq(p.point, "TOPLEFT", "point = record")
    T.eq(p.relPoint, "BOTTOMRIGHT", "relPoint = record")
    T.eq(p.x, 16, "x = record")
    T.eq(p.y, -104, "y = record")
end)

local garbageCases = {
    { name = "unwhitelisted point name", geometry = { point = "BOGUS", relPoint = "CENTER", x = 0, y = 0 } },
    { name = "string offset",            geometry = { point = "CENTER", relPoint = "CENTER", x = "0", y = 0 } },
    { name = "missing key",              geometry = { point = "CENTER", relPoint = "CENTER", x = 0 } },
    { name = "NaN offset",               geometry = { point = "CENTER", relPoint = "CENTER", x = 0 / 0, y = 0 } },
    { name = "+inf offset",              geometry = { point = "CENTER", relPoint = "CENTER", x = math.huge, y = 0 } },
    { name = "-inf offset",              geometry = { point = "CENTER", relPoint = "CENTER", x = -math.huge, y = 0 } },
}

for _, case in ipairs(garbageCases) do
    test("Restore: garbage geometry (" .. case.name .. ") clears the four keys and applies the default", function()
        local F = T.fresh()
        local geometry = case.geometry
        geometry.extra = "keep me"
        local _, win = attach(F, { geometry = geometry, default = { "CENTER", "CENTER", 0, 0 } })
        T.eq(geometry.point, nil, "point cleared")
        T.eq(geometry.relPoint, nil, "relPoint cleared")
        T.eq(geometry.x, nil, "x cleared")
        T.eq(geometry.y, nil, "y cleared")
        T.eq(geometry.extra, "keep me", "other keys in the table untouched")
        local p = win._points
        T.eq(p.point, "CENTER", "default applied")
        T.eq(p.relPoint, "CENTER", "default relPoint applied")
    end)
end

test("Restore: garbage geometry in a dev build does not raise (Attach itself succeeds)", function()
    local F = T.fresh()
    local ret = attach(F, { geometry = { point = "BOGUS", relPoint = "CENTER", x = 0, y = 0 } })
    T.truthy(ret, "Attach succeeds despite a garbage saved record; garbage is data, not a programmer error")
end)

test("Restore: garbage geometry in a release build prints nothing", function()
    local F = T.fresh("1.0.0")
    attach(F, { geometry = { point = "BOGUS", relPoint = "CENTER", x = 0, y = 0 } })
    T.eq(#T.output, 0, "release build prints nothing for a garbage-record restore")
end)

--------------------------------------------------------------------------------
-- OnDragStop save guard: reparenting / a non-UIParent-relative anchor
--------------------------------------------------------------------------------

test("OnDragStop save guard: frame reparented after Attach refuses the write", function()
    local F = T.fresh()
    local geometry = { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 }
    local _, win = attach(F, { geometry = geometry })
    local before = { point = geometry.point, relPoint = geometry.relPoint, x = geometry.x, y = geometry.y }

    win._parent = {} -- simulate a caller reparenting win after Attach

    local seqBefore = #win._seq
    local pointsBefore, clearsBefore = #win.calls.SetPoint, #win.calls.ClearAllPoints
    T.raises(function() win._scripts.OnDragStop() end, "reparented drag stop",
        "Window: attached frame's parent or anchor is no longer UIParent-relative; geometry not saved")

    T.eq(geometry.point, before.point, "point unchanged")
    T.eq(geometry.relPoint, before.relPoint, "relPoint unchanged")
    T.eq(geometry.x, before.x, "x unchanged")
    T.eq(geometry.y, before.y, "y unchanged")
    T.eq(#win._seq, seqBefore + 2, "the drag itself still ran (StopMovingOrSizing, SetUserPlaced); only the save was refused")
    T.eq(win._seq[seqBefore + 1][1], "StopMovingOrSizing", "StopMovingOrSizing still ran")
    T.eq(win._seq[seqBefore + 2][1], "SetUserPlaced", "SetUserPlaced still ran")
    T.eq(win._seq[seqBefore + 2][2], false, "SetUserPlaced(false)")
    T.eq(#win.calls.SetPoint, pointsBefore, "no SetPoint on the refusal path")
    T.eq(#win.calls.ClearAllPoints, clearsBefore, "no ClearAllPoints on the refusal path")
end)

test("OnDragStop save guard: non-UIParent relativeTo refuses the write", function()
    local F = T.fresh()
    local geometry = { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 }
    local _, win = attach(F, { geometry = geometry })
    local before = { point = geometry.point, relPoint = geometry.relPoint, x = geometry.x, y = geometry.y }

    win._points.relativeTo = {} -- simulate GetPoint(1) returning a non-UIParent relativeTo

    local pointsBefore, clearsBefore = #win.calls.SetPoint, #win.calls.ClearAllPoints
    T.raises(function() win._scripts.OnDragStop() end, "non-UIParent-relativeTo drag stop",
        "Window: attached frame's parent or anchor is no longer UIParent-relative; geometry not saved")

    T.eq(geometry.point, before.point, "point unchanged")
    T.eq(geometry.relPoint, before.relPoint, "relPoint unchanged")
    T.eq(geometry.x, before.x, "x unchanged")
    T.eq(geometry.y, before.y, "y unchanged")
    T.eq(#win.calls.SetPoint, pointsBefore, "no SetPoint on the refusal path")
    T.eq(#win.calls.ClearAllPoints, clearsBefore, "no ClearAllPoints on the refusal path")
end)

test("OnDragStop save guard: a nil relativeTo is accepted and the save proceeds", function()
    local F = T.fresh()
    local geometry = { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 }
    local _, win = attach(F, { geometry = geometry })

    -- The save contract treats a nil relativeTo as UIParent-relative, not as a
    -- refusal cause (whether any client's GetPoint actually returns nil here is
    -- a Gate 2 question, not this test's concern).
    win._points.relativeTo = nil
    win._points.x = 42

    win._scripts.OnDragStop()

    T.eq(geometry.point, "CENTER", "save proceeded despite a nil relativeTo")
    T.eq(geometry.x, 42, "geometry updated with the post-drag value")
end)

test("OnDragStop save guard: release build prints instead of raising, and still skips the write", function()
    local F = T.fresh("1.0.0")
    local geometry = { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 }
    local _, win = attach(F, { geometry = geometry })
    win._parent = {}
    win._scripts.OnDragStop()
    T.eq(geometry.x, 0, "geometry unchanged")
    T.outputContains("geometry not saved", "release build printed the diagnostic instead of raising")
end)

test("OnDragStop save guard: release build prints for the non-UIParent-relativeTo cause too", function()
    local F = T.fresh("1.0.0")
    local geometry = { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 }
    local _, win = attach(F, { geometry = geometry })
    win._points.relativeTo = {}
    win._scripts.OnDragStop()
    T.eq(geometry.x, 0, "geometry unchanged")
    T.outputContains("geometry not saved", "release build printed the diagnostic instead of raising")
end)

--------------------------------------------------------------------------------
-- Drag: OnDragStart moves; OnDragStop writes geometry only after
-- SetUserPlaced(false) (the two-part invariant's second half)
--------------------------------------------------------------------------------

test("Drag: OnDragStart records StartMoving; OnDragStop writes geometry only after SetUserPlaced(false)", function()
    local F = T.fresh()
    local geometry = { point = "TOPLEFT", relPoint = "TOPLEFT", x = 16, y = -104 }
    local geometryIdentity = geometry
    local preDrag = { point = geometry.point, relPoint = geometry.relPoint, x = geometry.x, y = geometry.y }
    local _, win = attach(F, { geometry = geometry, default = { "CENTER", "CENTER", 0, 0 } })

    -- The test itself (not a Tests/run.lua stub feature) wraps win.SetUserPlaced
    -- to snapshot geometry at the moment SetUserPlaced(false) runs, BEFORE
    -- saveGeometry writes it -- proving the write happens after, not before.
    -- A frame._points snapshot inside SetUserPlaced could not prove this:
    -- StopMovingOrSizing has already moved _points to the post-drag position
    -- by the time SetUserPlaced runs, regardless of write order.
    local snapshotAtSetUserPlaced
    local realSetUserPlaced = win.SetUserPlaced
    win.SetUserPlaced = function(self, ...)
        snapshotAtSetUserPlaced = { point = geometry.point, relPoint = geometry.relPoint, x = geometry.x, y = geometry.y }
        return realSetUserPlaced(self, ...)
    end

    T.eq(#win.calls.StartMoving, 0, "not moved before drag")
    win._scripts.OnDragStart()
    T.eq(#win.calls.StartMoving, 1, "StartMoving recorded on drag start")

    -- Model the engine having repositioned win during the drag (the mock's
    -- StopMovingOrSizing does not move _points on its own).
    -- point and relPoint are deliberately different anchors (not the TOPLEFT/
    -- TOPLEFT the pre-drag geometry uses) so a swap between them in
    -- saveGeometry's write shows up as a failure instead of passing unnoticed.
    win:SetPoint("TOPLEFT", _G.UIParent, "BOTTOMRIGHT", 200, -300)

    win._scripts.OnDragStop()

    T.eq(snapshotAtSetUserPlaced.point, preDrag.point, "geometry not yet written when SetUserPlaced(false) ran")
    T.eq(snapshotAtSetUserPlaced.x, preDrag.x, "geometry.x not yet written when SetUserPlaced(false) ran")

    T.eq(geometry.point, "TOPLEFT", "geometry now holds the post-drag point")
    T.eq(geometry.relPoint, "BOTTOMRIGHT", "geometry now holds the post-drag relPoint")
    T.eq(geometry.x, 200, "geometry now holds the post-drag x")
    T.eq(geometry.y, -300, "geometry now holds the post-drag y")
    T.truthy(geometry == geometryIdentity, "same table identity (no allocation)")

    local last, secondLast = win._seq[#win._seq], win._seq[#win._seq - 1]
    T.eq(secondLast[1], "StopMovingOrSizing", "StopMovingOrSizing before SetUserPlaced")
    T.eq(last[1], "SetUserPlaced", "SetUserPlaced immediately after StopMovingOrSizing")
    T.eq(last[2], false, "SetUserPlaced(false)")
end)

--------------------------------------------------------------------------------
-- Reset
--------------------------------------------------------------------------------

test("Reset: unattached frame refused", function()
    local F = T.fresh()
    local win = makeFrame()
    T.raises(function() F.Window:Reset(win) end, "reset unattached", "Window:Reset: frame is not attached")
end)

test("Reset: attached frame clears the four geometry keys and re-applies the default", function()
    local F = T.fresh()
    local geometry = { point = "TOPLEFT", relPoint = "TOPLEFT", x = 16, y = -104 }
    -- point and relPoint are deliberately different anchors so a swap between
    -- them in the registry's stored copy of default shows up as a failure.
    local _, win = attach(F, { geometry = geometry, default = { "TOPLEFT", "BOTTOMRIGHT", 0, 0 } })
    F.Window:Reset(win)
    T.eq(geometry.point, nil, "point cleared")
    T.eq(geometry.relPoint, nil, "relPoint cleared")
    T.eq(geometry.x, nil, "x cleared")
    T.eq(geometry.y, nil, "y cleared")
    local p = win._points
    T.eq(p.point, "TOPLEFT", "default point applied")
    T.eq(p.relPoint, "BOTTOMRIGHT", "default relPoint applied")
    T.eq(p.x, 0, "default x applied")
    T.eq(p.y, 0, "default y applied")
end)

test("Reset: second Reset on the same frame is fine", function()
    local F = T.fresh()
    local _, win = attach(F)
    F.Window:Reset(win)
    local ok, err = pcall(function() F.Window:Reset(win) end)
    T.truthy(ok, "second Reset does not error (got: " .. tostring(err) .. ")")
end)

test("Reset applies the default captured at Attach time, not a later mutation of the caller's table", function()
    local F = T.fresh()
    local default = { "CENTER", "CENTER", 0, 0 }
    local _, win = attach(F, { default = default })
    default[1] = "TOPLEFT"
    default[3] = 999
    F.Window:Reset(win)
    local p = win._points
    T.eq(p.point, "CENTER", "Reset uses the Attach-time copy, not the caller's mutated table")
    T.eq(p.x, 0, "same for x")
end)

--------------------------------------------------------------------------------
-- Release axis
--------------------------------------------------------------------------------

test("release build: bad config prints and returns nil, does not raise", function()
    local F = T.fresh("1.0.0")
    local win = makeFrame()
    local ret = F.Window:Attach(win, "nope")
    T.eq(ret, nil, "release Attach returns nil on bad config")
    T.outputContains("Window:Attach: config must be a table", "release printed the diagnostic")
end)

--------------------------------------------------------------------------------
-- Module hygiene
--------------------------------------------------------------------------------

test("Attach never calls CreateFrame", function()
    local F = T.fresh()
    local win = makeFrame()
    local before = #T.frames
    F.Window:Attach(win, { handle = win, geometry = {}, default = makeDefault() })
    T.eq(#T.frames, before, "Attach creates no frames")
end)

return tests

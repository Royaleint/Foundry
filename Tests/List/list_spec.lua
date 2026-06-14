-- Foundry.List behavior tests. Loaded by Tests/run.lua, which passes the harness
-- table T. Returns a list of { name, fn } cases covering the v1 public contract:
-- atomic :New validation, the five-object composition order against the recording
-- ScrollBox stub, SetData / ForEachFrame / GetNativeHandles / Destroy, the
-- re-entrancy guard, the flavor gate, the dev/release axis, and the version pins.
--
-- The harness CreateScrollBoxListLinearView / CreateDataProvider / ScrollUtil
-- stubs replicate the real call REQUIREMENTS (factory-before-provider trap;
-- scrollbar-must-be-an-EventFrame), so a List that wired them out of order would
-- fail here rather than silently pass.

local T = ...

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

-- A minimal valid config. parent is a plain table (List only passes it to
-- CreateFrame, which the stub does not dereference), so validation tests can
-- assert #T.frames == 0 without a real parent frame inflating the count.
local function valid(over)
    local cfg = {
        name        = "TestList",
        parent      = {},
        elementType = "Button",
        extent      = 20,
        initializer = function() end,
    }
    if over then
        for k, v in pairs(over) do cfg[k] = v end
    end
    return cfg
end

--------------------------------------------------------------------------------
-- 1. Construction + method surface
--------------------------------------------------------------------------------

test("New returns a controller exposing exactly the four v1 methods", function()
    local F = T.fresh()
    local c = F.List:New(valid())
    T.truthy(c, "controller created")
    for _, m in ipairs({ "SetData", "ForEachFrame", "GetNativeHandles", "Destroy" }) do
        T.eq(type(c[m]), "function", "method " .. m)
    end
    -- Cut surfaces must NOT be present in v1.
    for _, m in ipairs({ "Insert", "Remove", "Refresh", "Select", "GetSelected", "ScrollToData" }) do
        T.eq(c[m], nil, "cut surface absent: " .. m)
    end
end)

--------------------------------------------------------------------------------
-- 2-16. Atomic :New validation (dev build raises; a rejected call builds nothing)
--------------------------------------------------------------------------------

test("New: non-table config refused, builds nothing", function()
    local F = T.fresh()
    T.raises(function() F.List:New("nope") end, "non-table config", "config must be a table")
    T.eq(#T.frames, 0, "no frame created on a rejected :New")
end)

test("New: missing/empty name refused", function()
    local F = T.fresh()
    T.raises(function() F.List:New(valid({ name = "" })) end, "empty name", "config.name must be a non-empty string")
    T.raises(function() F.List:New(valid({ name = 5 })) end, "non-string name", "config.name must be a non-empty string")
    T.eq(#T.frames, 0, "no frame created")
end)

test("New: missing parent refused", function()
    local F = T.fresh()
    local cfg = valid(); cfg.parent = nil
    T.raises(function() F.List:New(cfg) end, "no parent", "config.parent must be a frame")
end)

test("New: neither template nor elementType refused", function()
    local F = T.fresh()
    local cfg = valid()
    cfg.elementType = nil
    T.raises(function() F.List:New(cfg) end, "neither", "requires exactly one of template or elementType")
end)

test("New: both template and elementType refused (mutually exclusive)", function()
    local F = T.fresh()
    T.raises(function() F.List:New(valid({ template = "X" })) end, "both",
        "config.template and config.elementType are mutually exclusive")
end)

test("New: template not a string refused", function()
    local F = T.fresh()
    local cfg = valid()
    cfg.elementType = nil
    cfg.template = 7
    T.raises(function() F.List:New(cfg) end, "template type", "config.template must be a string")
end)

test("New: elementType not a string refused", function()
    local F = T.fresh()
    T.raises(function() F.List:New(valid({ elementType = 7 })) end, "elementType type",
        "config.elementType must be a string")
end)

test("New: missing/non-function initializer refused", function()
    local F = T.fresh()
    local cfg = valid(); cfg.initializer = nil
    T.raises(function() F.List:New(cfg) end, "no initializer",
        "config.initializer must be a function")
    T.raises(function() F.List:New(valid({ initializer = 5 })) end, "non-fn initializer",
        "config.initializer must be a function")
end)

test("New: resetter not a function refused", function()
    local F = T.fresh()
    T.raises(function() F.List:New(valid({ resetter = 5 })) end, "resetter type",
        "config.resetter must be a function")
end)

test("New: elementType row with no extent or calculator refused", function()
    local F = T.fresh()
    local cfg = valid()
    cfg.extent = nil
    T.raises(function() F.List:New(cfg) end, "no extent",
        "elementType rows require config.extent")
end)

test("New: extent and extentCalculator both set refused", function()
    local F = T.fresh()
    T.raises(function() F.List:New(valid({ extentCalculator = function() return 10 end })) end,
        "both extent forms", "config.extent and config.extentCalculator are mutually exclusive")
end)

test("New: non-positive / non-number extent refused", function()
    local F = T.fresh()
    T.raises(function() F.List:New(valid({ extent = 0 })) end, "zero extent", "config.extent must be a number > 0")
    T.raises(function() F.List:New(valid({ extent = -3 })) end, "negative extent", "config.extent must be a number > 0")
    T.raises(function() F.List:New(valid({ extent = "x" })) end, "string extent", "config.extent must be a number > 0")
end)

test("New: extentCalculator not a function refused", function()
    local F = T.fresh()
    local cfg = valid()
    cfg.extent = nil
    cfg.extentCalculator = 5
    T.raises(function() F.List:New(cfg) end, "calc type", "config.extentCalculator must be a function")
end)

test("New: spacing not a number refused", function()
    local F = T.fresh()
    T.raises(function() F.List:New(valid({ spacing = "wide" })) end, "spacing type", "config.spacing must be a number")
end)

test("New: validation is ordered (type error before precondition)", function()
    local F = T.fresh()
    -- name is bad (type) AND parent is missing: the name type error must surface first.
    local cfg = valid({ name = 5 })
    cfg.parent = nil
    T.raises(function() F.List:New(cfg) end, "ordered", "config.name must be a non-empty string")
end)

--------------------------------------------------------------------------------
-- 17-23. Composition order against the recording stub
--------------------------------------------------------------------------------

test("New: builds the ScrollBox frame and a MinimalScrollBar EventFrame", function()
    local F = T.fresh()
    local c = F.List:New(valid())
    T.truthy(c, "controller created")
    T.eq(#T.frames, 2, "exactly two frames: ScrollBox + ScrollBar")
    T.eq(T.frames[1]._template, "WowScrollBoxList", "frame 1 is the ScrollBox list")
    T.eq(T.frames[2]._kind, "EventFrame", "frame 2 (the scrollbar) is an EventFrame")
    T.eq(T.frames[2]._template, "MinimalScrollBar", "frame 2 is the MinimalScrollBar")
end)

test("New: InitScrollBoxListWithScrollBar wired box+bar+view", function()
    local F = T.fresh()
    F.List:New(valid())
    local box = T.frames[1]
    T.truthy(box._inited, "box was Init'd")
    T.eq(box._bar._kind, "EventFrame", "box wired to the EventFrame scrollbar")
    T.truthy(box._view, "box wired to a view")
end)

test("New: initializer set before the provider seed (factory-before-provider)", function()
    local F = T.fresh()
    local c = F.List:New(valid())
    local box = T.frames[1]
    -- A valid :New proves the order held: the view's SetDataProvider would have
    -- errored if the initializer/factory were not set first. Confirm both ran.
    T.eq(#box._view.calls.SetElementInitializer, 1, "initializer set exactly once")
    T.eq(#box._view.calls.SetDataProvider, 1, "provider seeded exactly once")
end)

test("New: seeds an empty provider so SetData is valid immediately", function()
    local F = T.fresh()
    local c = F.List:New(valid())
    local h = c:GetNativeHandles()
    T.truthy(h.dataProvider, "a provider is present after :New")
    T.eq(h.dataProvider:GetSize(), 0, "seeded provider is empty")
end)

test("New: extent path sets the element extent, not a calculator", function()
    local F = T.fresh()
    local c = F.List:New(valid({ extent = 26 }))
    local view = c:GetNativeHandles().view
    T.eq(view._extent, 26, "extent wired")
    T.eq(view._calc, nil, "no calculator wired")
end)

test("New: extentCalculator path sets a calculator, not a fixed extent", function()
    local F = T.fresh()
    local cfg = valid()
    cfg.extent = nil
    cfg.extentCalculator = function() return 18 end
    local c = F.List:New(cfg)
    local view = c:GetNativeHandles().view
    T.eq(type(view._calc), "function", "calculator wired")
    T.eq(view._extent, nil, "no fixed extent wired")
end)

test("New: single-initializer path only (selection never wired)", function()
    local F = T.fresh()
    F.List:New(valid())
    T.eq(_G.ScrollUtil._selectionCalls, 0, "List wires no native selection behavior")
end)

test("New: a supplied resetter is wired to the view; none leaves it unset", function()
    local F = T.fresh()
    local fn = function() end
    local c = F.List:New(valid({ resetter = fn }))
    local view = c:GetNativeHandles().view
    T.eq(view._resetter, fn, "resetter wired to the view")
    T.eq(#view.calls.SetElementResetter, 1, "SetElementResetter called exactly once")
    -- The default valid() has no resetter, so the view must be left untouched.
    local F2 = T.fresh()
    local c2 = F2.List:New(valid())
    local view2 = c2:GetNativeHandles().view
    T.eq(view2._resetter, nil, "no resetter wired when config omits it")
    T.eq(#view2.calls.SetElementResetter, 0, "SetElementResetter never called without a resetter")
end)

--------------------------------------------------------------------------------
-- 24-27. Data plumbing + re-entrancy
--------------------------------------------------------------------------------

test("SetData replaces the row set with a fresh provider of K tables", function()
    local F = T.fresh()
    local c = F.List:New(valid())
    c:SetData({ { id = 1 }, { id = 2 }, { id = 3 } })
    T.eq(c:GetNativeHandles().dataProvider:GetSize(), 3, "provider holds 3 rows")
    c:SetData({ { id = 1 } })
    T.eq(c:GetNativeHandles().dataProvider:GetSize(), 1, "replaced, not appended")
end)

test("SetData refuses a non-table argument", function()
    local F = T.fresh()
    local c = F.List:New(valid())
    T.raises(function() c:SetData("nope") end, "non-table arg",
        "data must be an array of tables")
end)

test("SetData refuses non-table rows", function()
    local F = T.fresh()
    local c = F.List:New(valid())
    T.raises(function() c:SetData({ { id = 1 }, "x" }) end, "non-table row",
        "data must be an array of tables")
end)

test("SetData refuses being called from inside an initializer (re-entrancy)", function()
    local F = T.fresh()
    local c
    local refused = false
    local cfg = valid()
    cfg.initializer = function()
        local ok, err = pcall(function() c:SetData({ { id = 9 } }) end)
        refused = (not ok) and tostring(err):find("cannot mutate data from inside an initializer", 1, true) ~= nil
    end
    c = F.List:New(cfg)
    -- Invoke the wrapped initializer exactly as Blizzard would after layout.
    local view = c:GetNativeHandles().view
    view._initializer({}, { id = 1 })
    T.truthy(refused, "SetData refused from inside the initializer")
    -- The re-entrancy flag is cleared afterward, so a normal SetData still works.
    c:SetData({ { id = 1 }, { id = 2 } })
    T.eq(c:GetNativeHandles().dataProvider:GetSize(), 2, "SetData works again after the initializer")
end)

test("an erroring initializer still clears _inInitializer (SetData not bricked)", function()
    local F = T.fresh()
    local cfg = valid()
    cfg.initializer = function() error("boom") end
    local c = F.List:New(cfg)
    -- The wrapped initializer must re-raise the consumer error (List.lua clears the
    -- flag, then re-raises). Drive it exactly as Blizzard would after layout.
    local view = c:GetNativeHandles().view
    T.raises(function() view._initializer({}, {}) end, "init error propagates", "boom")
    -- Despite the error, _inInitializer was cleared, so SetData is not permanently
    -- bricked: a subsequent call must succeed.
    c:SetData({ { id = 1 } })
    T.eq(c:GetNativeHandles().dataProvider:GetSize(), 1, "SetData works after an initializer error")
end)

--------------------------------------------------------------------------------
-- 28-31. Escape hatch, ForEachFrame, teardown
--------------------------------------------------------------------------------

test("GetNativeHandles returns the four live objects, no selection key, fresh table", function()
    local F = T.fresh()
    local c = F.List:New(valid())
    local h = c:GetNativeHandles()
    T.truthy(h.scrollBox, "scrollBox handle")
    T.truthy(h.scrollBar, "scrollBar handle")
    T.truthy(h.view, "view handle")
    T.truthy(h.dataProvider, "dataProvider handle")
    T.eq(h.selection, nil, "no selection key in v1")
    local h2 = c:GetNativeHandles()
    T.truthy(h ~= h2, "a fresh wrapper table each call")
    T.eq(h.scrollBox, h2.scrollBox, "but the same live objects")
end)

test("ForEachFrame forwards to the ScrollBox and stops on a truthy return", function()
    local F = T.fresh()
    local c = F.List:New(valid())
    local box = c:GetNativeHandles().scrollBox
    box._realizedFrames = { { _elementData = { id = 1 } }, { _elementData = { id = 2 } } }
    local seen = {}
    c:ForEachFrame(function(_, data) seen[#seen + 1] = data.id end)
    T.eq(#seen, 2, "iterated both realized frames")
    T.eq(#box.calls.ForEachFrame, 1, "forwarded to the box exactly once")
    -- truthy return stops iteration
    local count = 0
    local stopped = c:ForEachFrame(function() count = count + 1; return "stop" end)
    T.eq(count, 1, "stopped after the first frame")
    T.eq(stopped, "stop", "returns the stopping value")
end)

test("Destroy releases the provider, hides the frames, and refuses afterwards", function()
    local F = T.fresh()
    local c = F.List:New(valid())
    local box, bar, view = T.frames[1], T.frames[2], T.frames[1]._view
    c:Destroy()
    T.eq(view._dataProvider, nil, "provider released")
    T.falsy(box:IsShown(), "ScrollBox hidden")
    T.falsy(bar:IsShown(), "ScrollBar hidden")
    -- Double-Destroy refuses, and every method refuses post-Destroy.
    T.raises(function() c:Destroy() end, "double-destroy", "List:Destroy called on a destroyed controller")
    T.raises(function() c:SetData({}) end, "post-destroy SetData", "List:SetData called on a destroyed controller")
    T.raises(function() c:ForEachFrame(function() end) end, "post-destroy ForEachFrame",
        "List:ForEachFrame called on a destroyed controller")
    T.raises(function() c:GetNativeHandles() end, "post-destroy handles",
        "List:GetNativeHandles called on a destroyed controller")
end)

--------------------------------------------------------------------------------
-- 32-35. Flavor gate, dev/release axis, version pins, managed visibility
--------------------------------------------------------------------------------

test("New: flavor gate refuses when the ScrollBox system is absent", function()
    local F = T.fresh()
    _G.ScrollUtil = nil
    T.raises(function() F.List:New(valid()) end, "no scrollbox system",
        "lacks the modern scrolling-list system")
    T.eq(#T.frames, 0, "no frame created when the system is unavailable")
end)

test("release build: a validation error prints and refuses (returns nil), never raises", function()
    local F = T.fresh("1.0.0")
    local c = F.List:New("nope")
    T.eq(c, nil, "release :New returns nil on bad config")
    T.outputContains("config must be a table", "release printed the diagnostic")
end)

test("version pins: List.API_VERSION == 1 and F.API_VERSION == 5", function()
    local F = T.fresh()
    T.eq(F.List.API_VERSION, 1, "List per-module marker == 1")
    T.eq(F.API_VERSION, 5, "library API_VERSION bumped 4 -> 5 with List")
end)

test("New: managedScrollBarVisibility opt-in is accepted", function()
    local F = T.fresh()
    local c = F.List:New(valid({ managedScrollBarVisibility = true }))
    T.truthy(c, "controller created with managed visibility")
end)

return tests

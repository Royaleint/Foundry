-- Foundry.Settings behavior tests. Loaded by Tests/run.lua, which passes the
-- harness table T. Returns a list of { name, fn } cases covering the v1 public
-- contract: registration path selection (modern / legacy / neither / both-present
-- modern-wins), atomic :New validation, :Open, :GetCategoryID, :GetNativeHandles,
-- :Destroy, subcategory support, duplicate-key refusal, and version pins.
--
-- Stub design (hostile-pass #1): one surface per simulated flavor. Modern and
-- legacy never coexist in the same test. installModern/installLegacy/installNeither
-- helpers write exactly the right globals so T.fresh() sees a single flavor.
-- Category stubs record calls with precision (not friendly mocks): return shapes,
-- argument order, and call counts are all assertable.

local T = ...

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

--------------------------------------------------------------------------------
-- Per-test flavor helpers
-- These write (or clear) the flavor globals AFTER T.fresh() has reset them to
-- nil via installMocks. Call one of these inside each test body after T.fresh().
--------------------------------------------------------------------------------

-- Modern flavor: _G.Settings table with all three required functions present.
-- RegisterCanvasLayoutCategory returns TWO values: (category, layout).
-- category:GetID() → 35. A distinct subcategoryCategory with GetID() → 36.
-- registerAddOnCategoryCalls, registerRootCalls, registerSubCalls, openCalls
-- are the test-visible call logs.
local function installModern()
    local state = {
        registerRootCalls  = {},
        registerSubCalls   = {},
        registerAddOnCalls = {},
        openCalls          = {},
    }

    local rootCategory = {
        _id = 35,
        GetID = function(self) return self._id end,
    }

    local subCategory = {
        _id = 36,
        GetID = function(self) return self._id end,
    }

    -- The module calls all of these via DOT notation (_G.Settings.Fn(...)), never
    -- colon notation. Stubs must therefore be plain functions, NOT methods.
    -- Using `function(self, ...)` would shift all args by one and silently corrupt
    -- the frame/title/categoryID values the module passes.
    _G.Settings = {
        _state         = state,
        _rootCategory  = rootCategory,
        _subCategory   = subCategory,

        RegisterCanvasLayoutCategory = function(frame, title)
            state.registerRootCalls[#state.registerRootCalls + 1] =
                { frame = frame, title = title }
            -- Two values: category, layout. Only category is used by Settings:New.
            local layout = { _isLayout = true }
            return rootCategory, layout
        end,

        RegisterCanvasLayoutSubcategory = function(parentCategory, frame, title)
            state.registerSubCalls[#state.registerSubCalls + 1] =
                { parentCategory = parentCategory, frame = frame, title = title }
            local layout = { _isLayout = true }
            return subCategory, layout
        end,

        RegisterAddOnCategory = function(category)
            state.registerAddOnCalls[#state.registerAddOnCalls + 1] =
                { category = category }
        end,

        OpenToCategory = function(categoryID)
            state.openCalls[#state.openCalls + 1] = { categoryID = categoryID }
        end,
    }

    -- Legacy surface MUST be absent for single-surface fidelity.
    _G.InterfaceOptions_AddCategory = nil
    _G.InterfaceOptionsFrame         = nil

    return state, rootCategory, subCategory
end

-- Legacy flavor: InterfaceOptions_AddCategory present; Settings absent.
local function installLegacy()
    local state = {
        addCategoryCalls = {},
        openCalls        = {},
    }

    _G.Settings = nil
    _G.InterfaceOptions_AddCategory = function(frame)
        state.addCategoryCalls[#state.addCategoryCalls + 1] = { frame = frame }
    end
    _G.InterfaceOptionsFrame = {
        _state = state,
        OpenToCategory = function(self, frame)
            state.openCalls[#state.openCalls + 1] = { frame = frame }
        end,
    }

    return state
end

-- Neither flavor: both surfaces nil.
local function installNeither()
    _G.Settings                      = nil
    _G.InterfaceOptions_AddCategory  = nil
    _G.InterfaceOptionsFrame         = nil
end

-- A minimal valid consumer frame: a table that satisfies the frame validation
-- (must have GetObjectType). Settings:New never calls CreateFrame — the consumer
-- supplies the frame. T.frames stays 0 for all Settings tests.
local function makeFrame()
    return {
        GetObjectType = function() return "Frame" end,
        _isFrame = true,
    }
end

-- A minimal valid config. Individual tests override fields via 'over'.
local function valid(over)
    local cfg = {
        title = "TestAddon",
        frame = makeFrame(),
    }
    if over then
        for k, v in pairs(over) do cfg[k] = v end
    end
    return cfg
end

--------------------------------------------------------------------------------
-- Version pins
--------------------------------------------------------------------------------

test("version pins: Settings.API_VERSION == 1 and F.API_VERSION == 6", function()
    local F = T.fresh()
    installModern()
    T.eq(F.Settings.API_VERSION, 1, "Settings per-module API_VERSION == 1")
    T.eq(F.API_VERSION, 6, "library API_VERSION == 6 (the v1.0.6 bump covers Settings + RegisterBucket)")
    T.eq(F:RequireModule("Settings", 1), F.Settings, "RequireModule min=1 returns the module")
    T.raises(function() F:RequireModule("Settings", 99) end,
        "RequireModule too-high", "version")
end)

--------------------------------------------------------------------------------
-- Construction + method surface
--------------------------------------------------------------------------------

test("New returns a controller exposing exactly the four v1 methods", function()
    local F = T.fresh()
    installModern()
    local c = F.Settings:New(valid())
    T.truthy(c, "controller created")
    for _, m in ipairs({ "Open", "GetCategoryID", "GetNativeHandles", "Destroy" }) do
        T.eq(type(c[m]), "function", "method " .. m .. " present")
    end
end)

test("New does not create any WoW frames (consumer owns the frame)", function()
    local F = T.fresh()
    installModern()
    F.Settings:New(valid())
    T.eq(#T.frames, 0, "Settings:New never calls CreateFrame")
end)

--------------------------------------------------------------------------------
-- Registration path selection
--------------------------------------------------------------------------------

test("Modern present: RegisterCanvasLayoutCategory + RegisterAddOnCategory called; mode=settings", function()
    local F = T.fresh()
    local state = installModern()
    local frame = makeFrame()
    local c = F.Settings:New({ title = "Homestead", frame = frame })
    T.truthy(c, "controller created")
    T.eq(#state.registerRootCalls,  1, "RegisterCanvasLayoutCategory called once")
    T.eq(#state.registerAddOnCalls, 1, "RegisterAddOnCategory called once")
    T.eq(#state.registerSubCalls,   0, "RegisterCanvasLayoutSubcategory not called")
    -- RegisterCanvasLayoutCategory received the frame and title.
    T.eq(state.registerRootCalls[1].frame, frame,       "frame forwarded")
    T.eq(state.registerRootCalls[1].title, "Homestead", "title forwarded")
    -- RegisterAddOnCategory received the category object (not the layout).
    local h = c:GetNativeHandles()
    T.eq(state.registerAddOnCalls[1].category, h.category, "AddOnCategory got the category")
    T.eq(h.mode, "settings", "mode is 'settings'")
end)

test("Legacy present, modern absent: InterfaceOptions_AddCategory called; mode=interface-options", function()
    local F = T.fresh()
    local state = installLegacy()
    local frame = makeFrame()
    local c = F.Settings:New({ title = "Homestead", frame = frame })
    T.truthy(c, "controller created via legacy path")
    T.eq(#state.addCategoryCalls, 1, "InterfaceOptions_AddCategory called once")
    T.eq(state.addCategoryCalls[1].frame, frame, "frame forwarded to legacy")
    local h = c:GetNativeHandles()
    T.eq(h.mode, "interface-options", "mode is 'interface-options'")
end)

test("Neither present: RaiseDevError raised, no registration occurs", function()
    local F = T.fresh()
    installNeither()
    T.raises(function() F.Settings:New(valid()) end,
        "neither present", "no supported options-registration API")
end)

test("Both stubs present (impossible on real client): modern wins", function()
    -- On a real client, modern and legacy never coexist. This test guards against
    -- a future regression where the path selection order is inverted. We install
    -- both surfaces: modern must win.
    local F = T.fresh()
    local state, rootCategory = installModern()
    -- Now inject the legacy surface too — this violates the single-surface rule
    -- intentionally to test the precedence logic only.
    local legacyCalls = {}
    _G.InterfaceOptions_AddCategory = function(frame)
        legacyCalls[#legacyCalls + 1] = frame
    end
    local c = F.Settings:New(valid())
    T.truthy(c, "controller created")
    T.eq(#state.registerRootCalls, 1, "modern RegisterCanvasLayoutCategory was called")
    T.eq(#legacyCalls, 0, "legacy InterfaceOptions_AddCategory was NOT called")
    T.eq(c:GetNativeHandles().mode, "settings", "mode is 'settings' (modern wins)")
end)

test("Partial Settings table (missing RegisterAddOnCategory): legacy path taken", function()
    -- hasModernSettings() requires ALL three: _G.Settings table + RegisterCanvasLayoutCategory
    -- + RegisterAddOnCategory. A partial stub (only RegisterCanvasLayoutCategory present)
    -- must NOT take the modern path.
    local F = T.fresh()
    local state = installLegacy()  -- sets up InterfaceOptions_AddCategory
    -- Inject a partial modern stub that has RegisterCanvasLayoutCategory but NOT
    -- RegisterAddOnCategory. hasModernSettings() must return false.
    _G.Settings = { RegisterCanvasLayoutCategory = function() end }
    local c = F.Settings:New(valid())
    T.truthy(c, "controller created via legacy path")
    T.eq(c:GetNativeHandles().mode, "interface-options",
        "partial modern stub: legacy path taken, not partial-modern")
end)

--------------------------------------------------------------------------------
-- Atomic :New validation (a rejected :New registers nothing)
--------------------------------------------------------------------------------

test("New: non-table config refused, nothing registered", function()
    local F = T.fresh()
    local state = installModern()
    T.raises(function() F.Settings:New("nope") end,
        "non-table config", "config must be a table")
    T.eq(#state.registerRootCalls,  0, "no registration on bad config")
    T.eq(#state.registerAddOnCalls, 0, "no AddOnCategory on bad config")
end)

test("New: nil title refused", function()
    local F = T.fresh()
    local state = installModern()
    local cfg = valid(); cfg.title = nil
    T.raises(function() F.Settings:New(cfg) end,
        "nil title", "config.title must be a non-empty string")
    T.eq(#state.registerRootCalls, 0, "no registration on nil title")
end)

test("New: empty string title refused", function()
    local F = T.fresh()
    local state = installModern()
    T.raises(function() F.Settings:New(valid({ title = "" })) end,
        "empty title", "config.title must be a non-empty string")
    T.eq(#state.registerRootCalls, 0, "no registration on empty title")
end)

test("New: non-string title refused", function()
    local F = T.fresh()
    installModern()
    T.raises(function() F.Settings:New(valid({ title = 7 })) end,
        "numeric title", "config.title must be a non-empty string")
end)

test("New: frame absent refused", function()
    local F = T.fresh()
    local state = installModern()
    local cfg = valid(); cfg.frame = nil
    T.raises(function() F.Settings:New(cfg) end,
        "nil frame", "config.frame must be a WoW frame")
    T.eq(#state.registerRootCalls, 0, "no registration on nil frame")
end)

test("New: plain table without GetObjectType refused (not a WoW frame)", function()
    local F = T.fresh()
    local state = installModern()
    T.raises(function() F.Settings:New(valid({ frame = {} })) end,
        "plain table frame", "config.frame must be a WoW frame")
    T.eq(#state.registerRootCalls, 0, "no registration on non-frame")
end)

test("New: non-table frame refused", function()
    local F = T.fresh()
    installModern()
    T.raises(function() F.Settings:New(valid({ frame = "notaframe" })) end,
        "string frame", "config.frame must be a WoW frame")
end)

test("New: destroyed parent refused", function()
    local F = T.fresh()
    installModern()
    local parent = F.Settings:New(valid({ title = "Parent" }))
    T.truthy(parent, "parent controller created")
    parent:Destroy()
    local state2, _, _ = installModern() -- re-install to get fresh state
    T.raises(function()
        F.Settings:New(valid({ title = "Child", parent = parent }))
    end, "destroyed parent", "config.parent must be a live Foundry.Settings controller")
    T.eq(#state2.registerRootCalls, 0, "no registration when parent is destroyed")
end)

test("New: non-controller parent table refused", function()
    local F = T.fresh()
    installModern()
    T.raises(function()
        F.Settings:New(valid({ parent = { _isSettingsController = false } }))
    end, "non-controller parent", "config.parent must be a live Foundry.Settings controller")
end)

test("New: plain table parent with no _isSettingsController refused", function()
    local F = T.fresh()
    installModern()
    T.raises(function()
        F.Settings:New(valid({ parent = {} }))
    end, "plain table parent", "config.parent must be a live Foundry.Settings controller")
end)

test("New: empty string name refused when explicitly supplied", function()
    local F = T.fresh()
    installModern()
    T.raises(function() F.Settings:New(valid({ name = "" })) end,
        "empty name", "config.name must be a non-empty string when supplied")
end)

test("New: non-string name refused when explicitly supplied", function()
    local F = T.fresh()
    installModern()
    T.raises(function() F.Settings:New(valid({ name = 42 })) end,
        "numeric name", "config.name must be a non-empty string when supplied")
end)

test("validation is ordered: title checked before frame", function()
    -- title is bad (empty) AND frame is bad (nil): title error must surface first.
    -- IMPORTANT: valid({title="", frame=nil}) silently skips the frame=nil override
    -- because pairs() does not iterate nil values. Set frame=nil explicitly after build.
    local F = T.fresh()
    installModern()
    local cfg = valid({ title = "" })
    cfg.frame = nil  -- explicit nil so the override actually takes effect
    T.raises(function() F.Settings:New(cfg) end, "title-before-frame", "config.title must be a non-empty string")
end)

test("validation is ordered: frame checked before parent", function()
    -- frame is bad (nil) AND parent is bad (plain table): frame error must surface first.
    -- IMPORTANT: pairs() skips nil values, so { frame = nil } in the override table is
    -- ignored by the valid() helper. Set frame to nil explicitly after building cfg.
    local F = T.fresh()
    installModern()
    local cfg = valid({ parent = {} })
    cfg.frame = nil  -- set nil explicitly so it overrides the makeFrame() default
    T.raises(function() F.Settings:New(cfg) end, "frame-before-parent", "config.frame must be a WoW frame")
end)

--------------------------------------------------------------------------------
-- Duplicate-key refusal and liveKeys isolation
--------------------------------------------------------------------------------

test("duplicate name: second :New with same key refused", function()
    -- Both :New calls must be inside one T.fresh() so liveKeys is shared.
    local F = T.fresh()
    installModern()
    local c1 = F.Settings:New(valid({ title = "Addon" }))
    T.truthy(c1, "first registration succeeds")
    T.raises(function() F.Settings:New(valid({ title = "Addon" })) end,
        "duplicate key", "a live controller already owns the name")
end)

test("duplicate name defaults to title, explicit name= overrides", function()
    local F = T.fresh()
    installModern()
    -- With explicit name="Key", title="Different" does not conflict with name="Key".
    local c1 = F.Settings:New(valid({ title = "Addon",     name = "SharedKey" }))
    T.truthy(c1, "first with explicit name")
    -- Same explicit name → refused.
    T.raises(function()
        F.Settings:New(valid({ title = "Addon2", name = "SharedKey" }))
    end, "explicit name duplicate", "a live controller already owns the name")
end)

test("duplicate key freed on :Destroy; third :New with same name succeeds", function()
    local F = T.fresh()
    installModern()
    local c1 = F.Settings:New(valid({ title = "Addon" }))
    T.truthy(c1, "first registration")
    c1:Destroy()
    -- After destroy, the key is free — re-registration must succeed.
    local c2 = F.Settings:New(valid({ title = "Addon" }))
    T.truthy(c2, "re-registration after :Destroy succeeds")
end)

--------------------------------------------------------------------------------
-- Two-value return: both category and layout stored (SF-4)
--------------------------------------------------------------------------------

test("RegisterCanvasLayoutCategory returns two values; category and layout both stored", function()
    local F = T.fresh()
    installModern()
    local c = F.Settings:New(valid())
    local h = c:GetNativeHandles()
    -- The category object is stored and exposed.
    T.truthy(h.category, "category is present in handles")
    T.eq(h.categoryID, 35, "categoryID comes from category:GetID()")
    -- Layout is now stored and exposed (SF-4). The stub returns {_isLayout=true}.
    T.truthy(h.layout, "layout second return value IS stored on controller (SF-4)")
    T.truthy(h.layout._isLayout, "layout object has expected marker from stub")
    -- Keys: frame, category, categoryID, mode, layout
    T.eq(h.mode, "settings", "mode key present")
    T.truthy(h.frame, "frame key present")
end)

--------------------------------------------------------------------------------
-- :Open()
--------------------------------------------------------------------------------

test(":Open modern: calls Settings.OpenToCategory with category:GetID() (number)", function()
    local F = T.fresh()
    local state = installModern()
    local c = F.Settings:New(valid())
    c:Open()
    T.eq(#state.openCalls, 1, "OpenToCategory called once")
    T.eq(state.openCalls[1].categoryID, 35, "categoryID is 35 (from category:GetID())")
    T.eq(type(state.openCalls[1].categoryID), "number", "categoryID is a number")
end)

test(":Open legacy: calls InterfaceOptionsFrame:OpenToCategory TWICE with frame", function()
    local F = T.fresh()
    local state = installLegacy()
    local frame = makeFrame()
    local c = F.Settings:New({ title = "Addon", frame = frame })
    c:Open()
    T.eq(#state.openCalls, 2, "OpenToCategory called exactly twice (absorb first-call quirk)")
    T.eq(state.openCalls[1].frame, frame, "first call passes the frame")
    T.eq(state.openCalls[2].frame, frame, "second call passes the same frame")
end)

test(":Open neither: returns false, 'unsupported-open' (defensive dead code path)", function()
    -- A live controller always has a valid mode because :New refuses when neither
    -- surface is present. Test via white-box: force _mode = nil on a modern controller.
    local F = T.fresh()
    installModern()
    local c = F.Settings:New(valid())
    c._mode = nil  -- Force the unreachable branch; this is intentional white-box coverage.
    local ret1, ret2 = c:Open()
    T.eq(ret1, false,              "returns false when mode is unrecognized")
    T.eq(ret2, "unsupported-open", "returns 'unsupported-open' error token")
end)

test(":Open on destroyed controller raises", function()
    local F = T.fresh()
    installModern()
    local c = F.Settings:New(valid())
    c:Destroy()
    T.raises(function() c:Open() end,
        "open after destroy", "Settings:Open called on a destroyed controller")
end)

--------------------------------------------------------------------------------
-- :GetCategoryID()
--------------------------------------------------------------------------------

test(":GetCategoryID modern: returns the numeric category ID", function()
    local F = T.fresh()
    installModern()
    local c = F.Settings:New(valid())
    local id = c:GetCategoryID()
    T.eq(id, 35, "GetCategoryID returns 35")
    T.eq(type(id), "number", "return is a number")
end)

test(":GetCategoryID legacy: returns nil (no numeric ID on legacy surface)", function()
    local F = T.fresh()
    installLegacy()
    local c = F.Settings:New(valid())
    local id = c:GetCategoryID()
    T.eq(id, nil, "GetCategoryID returns nil for legacy controller")
end)

test(":GetCategoryID on destroyed controller raises", function()
    local F = T.fresh()
    installModern()
    local c = F.Settings:New(valid())
    c:Destroy()
    T.raises(function() c:GetCategoryID() end,
        "getCategoryID after destroy", "Settings:GetCategoryID called on a destroyed controller")
end)

--------------------------------------------------------------------------------
-- :GetNativeHandles()
--------------------------------------------------------------------------------

test(":GetNativeHandles returns correct keys for modern controller", function()
    local F = T.fresh()
    local _, rootCategory = installModern()
    local frame = makeFrame()
    local c = F.Settings:New({ title = "Addon", frame = frame })
    local h = c:GetNativeHandles()
    T.eq(h.frame,      frame,        "frame key is the consumer frame")
    T.eq(h.category,   rootCategory, "category key is the registered category")
    T.eq(h.categoryID, 35,           "categoryID is from category:GetID()")
    T.eq(h.mode,       "settings",   "mode is 'settings'")
    T.truthy(h.layout,               "layout is present on modern path (SF-4)")
end)

test(":GetNativeHandles returns correct keys for legacy controller", function()
    local F = T.fresh()
    installLegacy()
    local frame = makeFrame()
    local c = F.Settings:New({ title = "Addon", frame = frame })
    local h = c:GetNativeHandles()
    T.eq(h.frame,      frame,               "frame key is the consumer frame")
    T.eq(h.category,   nil,                 "category is nil for legacy")
    T.eq(h.categoryID, nil,                 "categoryID is nil for legacy")
    T.eq(h.mode,       "interface-options", "mode is 'interface-options'")
    T.eq(h.layout,     nil,                 "layout is nil on legacy path (no layout anchor)")
end)

test(":GetNativeHandles returns a fresh table each call; mutating it does not affect :Open", function()
    local F = T.fresh()
    local state = installModern()
    local c = F.Settings:New(valid())
    local h1 = c:GetNativeHandles()
    local h2 = c:GetNativeHandles()
    T.truthy(h1 ~= h2, "fresh wrapper table per call")
    -- Mutation safety: clobber categoryID in the returned table, then assert that
    -- :Open still uses the controller's internally-stored category:GetID() result.
    h1.categoryID = 999
    c:Open()
    T.eq(state.openCalls[1].categoryID, 35, "Open used controller's own category:GetID(), not the mutated handle")
end)

test(":GetNativeHandles on destroyed controller raises", function()
    local F = T.fresh()
    installModern()
    local c = F.Settings:New(valid())
    c:Destroy()
    T.raises(function() c:GetNativeHandles() end,
        "getNativeHandles after destroy", "Settings:GetNativeHandles called on a destroyed controller")
end)

--------------------------------------------------------------------------------
-- :Destroy()
--------------------------------------------------------------------------------

test(":Destroy marks controller destroyed and frees the duplicate-refusal key", function()
    local F = T.fresh()
    installModern()
    local c = F.Settings:New(valid({ title = "Addon" }))
    T.truthy(c, "controller created")
    T.falsy(c._destroyed, "not destroyed before :Destroy")
    c:Destroy()
    T.truthy(c._destroyed, "_destroyed set to true")
    -- Key freed: a new registration with the same name must succeed.
    local c2 = F.Settings:New(valid({ title = "Addon" }))
    T.truthy(c2, "re-registration after :Destroy succeeds")
end)

test(":Destroy releases internal category, frame, and name references", function()
    local F = T.fresh()
    installModern()
    local c = F.Settings:New(valid())
    c:Destroy()
    T.eq(c._category, nil, "_category released")
    T.eq(c._frame,    nil, "_frame released")
    T.eq(c._name,     nil, "_name released (NB-1)")
end)

test(":Destroy is idempotent (second :Destroy is a silent no-op, does not raise)", function()
    local F = T.fresh()
    installModern()
    local c = F.Settings:New(valid())
    c:Destroy()
    -- Second Destroy must NOT raise. The module comment says "idempotent", which
    -- diverges from List's second-Destroy-raises behavior.
    local ok, err = pcall(function() c:Destroy() end)
    T.truthy(ok, "second :Destroy is a no-op, not an error (got: " .. tostring(err) .. ")")
end)

test("After :Destroy, all methods except :Destroy raise via RaiseDevError", function()
    local F = T.fresh()
    installModern()
    local c = F.Settings:New(valid())
    c:Destroy()
    T.raises(function() c:Open() end,
        "Open after destroy", "Settings:Open called on a destroyed controller")
    T.raises(function() c:GetCategoryID() end,
        "GetCategoryID after destroy", "Settings:GetCategoryID called on a destroyed controller")
    T.raises(function() c:GetNativeHandles() end,
        "GetNativeHandles after destroy", "Settings:GetNativeHandles called on a destroyed controller")
end)

--------------------------------------------------------------------------------
-- Subcategory (parent field)
--------------------------------------------------------------------------------

test("Modern subcategory: RegisterCanvasLayoutSubcategory called; RegisterAddOnCategory NOT called for child", function()
    local F = T.fresh()
    local state, rootCategory, subCategory = installModern()

    -- Create parent.
    local parentFrame = makeFrame()
    local parent = F.Settings:New({ title = "ParentAddon", frame = parentFrame })
    T.truthy(parent, "parent controller created")

    -- Reset call counts to isolate child registration.
    local addOnCallsBeforeChild = #state.registerAddOnCalls

    -- Create child.
    local childFrame = makeFrame()
    local child = F.Settings:New({
        title  = "ChildPanel",
        frame  = childFrame,
        parent = parent,
    })
    T.truthy(child, "child controller created")

    -- RegisterCanvasLayoutSubcategory must be called with (parentCategory, childFrame, title).
    T.eq(#state.registerSubCalls, 1, "RegisterCanvasLayoutSubcategory called once")
    T.eq(state.registerSubCalls[1].parentCategory, rootCategory, "parentCategory forwarded")
    T.eq(state.registerSubCalls[1].frame,          childFrame,  "child frame forwarded")
    T.eq(state.registerSubCalls[1].title,          "ChildPanel","child title forwarded")

    -- RegisterAddOnCategory must NOT be called again for the child.
    T.eq(#state.registerAddOnCalls, addOnCallsBeforeChild,
        "RegisterAddOnCategory NOT called for subcategory child")

    -- Child handles reflect sub-category object.
    local h = child:GetNativeHandles()
    T.eq(h.category,   subCategory, "child category is the subcategory object")
    T.eq(h.categoryID, 36,          "child categoryID is 36 (child's own GetID())")
    T.eq(h.mode,       "settings",  "child mode is 'settings'")
end)

test("Modern child :Open calls OpenToCategory with the child's own category ID (not parent's)", function()
    local F = T.fresh()
    local state = installModern()

    local parent = F.Settings:New({ title = "ParentAddon", frame = makeFrame() })
    local child  = F.Settings:New({ title = "ChildPanel",  frame = makeFrame(), parent = parent })

    child:Open()
    -- Only the child :Open call is in the log (parent was never opened).
    T.eq(#state.openCalls, 1, "exactly one OpenToCategory call")
    T.eq(state.openCalls[1].categoryID, 36, "child :Open used child categoryID (36), not parent (35)")
end)

test("Legacy subcategory: child registered as sibling (InterfaceOptions_AddCategory called for child frame)", function()
    local F = T.fresh()
    local state = installLegacy()

    -- Parent.
    local parentFrame = makeFrame()
    local parent = F.Settings:New({ title = "Parent", frame = parentFrame })
    local parentCallCount = #state.addCategoryCalls

    -- Child: legacy has no nesting. Child registered as a sibling.
    local childFrame = makeFrame()
    local child = F.Settings:New({ title = "Child", frame = childFrame, parent = parent })
    T.truthy(child, "child controller created on legacy path")
    T.eq(#state.addCategoryCalls, parentCallCount + 1,
        "InterfaceOptions_AddCategory called once more for child")
    T.eq(state.addCategoryCalls[parentCallCount + 1].frame, childFrame,
        "child frame passed to InterfaceOptions_AddCategory")
    T.eq(child:GetNativeHandles().mode, "interface-options", "child mode is 'interface-options'")
end)

test("name= defaults to title when not supplied", function()
    -- Prove that a second :New with the same title (but no explicit name=) is refused,
    -- because the default key is the title. A correct default means liveKeys["TestAddon"] = true
    -- after the first :New, blocking the second.
    local F = T.fresh()
    installModern()
    local c1 = F.Settings:New(valid())   -- title="TestAddon", name defaults to "TestAddon"
    T.truthy(c1, "first :New succeeds")
    T.raises(function() F.Settings:New(valid()) end,
        "same title = same key", "a live controller already owns the name")
end)

--------------------------------------------------------------------------------
-- Release-axis behavior (dev/release refusal form)
--------------------------------------------------------------------------------

test("release build: a validation error prints and returns nil, does not raise", function()
    local F = T.fresh("1.0.0")
    installModern()
    local c = F.Settings:New(valid({ title = "" }))
    T.eq(c, nil, "release :New returns nil on bad config")
    T.outputContains("config.title must be a non-empty string", "release printed the diagnostic")
end)

return tests

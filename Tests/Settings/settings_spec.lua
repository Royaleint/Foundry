-- Foundry.Settings behavior tests. Loaded by Tests/run.lua, which passes the
-- harness table T. Returns a list of { name, fn } cases covering the v1 public
-- contract: registration path selection (modern / absent, including a legacy-only
-- surface), atomic :New validation, :Open, :GetCategoryID, :GetNativeHandles,
-- :Destroy, subcategory support, duplicate-key refusal, and version pins.
--
-- Stub design (hostile-pass #1): one surface per simulated flavor.
-- installModern/installLegacyOnly/installNeither helpers write exactly the right
-- globals so T.fresh() sees a single flavor.
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

-- Legacy-only flavor: InterfaceOptions_AddCategory present; Settings absent.
-- Foundry must refuse here and never call the legacy function.
local function installLegacyOnly()
    local state = {
        addCategoryCalls = {},
    }

    _G.Settings = nil
    _G.InterfaceOptions_AddCategory = function(frame)
        state.addCategoryCalls[#state.addCategoryCalls + 1] = { frame = frame }
    end

    return state
end

-- Neither flavor: both surfaces nil.
local function installNeither()
    _G.Settings                      = nil
    _G.InterfaceOptions_AddCategory  = nil
    _G.InterfaceOptionsFrame         = nil
end

-- A minimal valid consumer frame: a table that satisfies the frame validation
-- (must have GetObjectType). Settings:New never calls CreateFrame, the consumer
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

-- Launcher flavor: installModern() plus the vertical-layout functions and the
-- global CreateSettingsButtonInitializer. Every Blizzard settings call, canvas
-- ones included, appends its name to state.log in call order. Setting
-- state.throwOn[fnName] makes that function error after it is logged.
-- The vertical category is a distinct object from the canvas root category
-- (same GetID 35), so tests can tell which one a call received.
local function installLauncher()
    local state, rootCategory = installModern()
    state.log                  = {}
    state.throwOn              = {}
    state.verticalCalls        = {}
    state.initializerCalls     = {}
    state.registerInitializerCalls = {}

    local verticalCategory = {
        _id = 35,
        GetID = function(self) return self._id end,
    }

    local function logged(fnName, fn)
        return function(...)
            state.log[#state.log + 1] = fnName
            if state.throwOn[fnName] then
                error("stub throw: " .. fnName, 0)
            end
            return fn(...)
        end
    end

    local S = _G.Settings
    for _, fnName in ipairs({
        "RegisterCanvasLayoutCategory", "RegisterCanvasLayoutSubcategory", "RegisterAddOnCategory",
    }) do
        S[fnName] = logged(fnName, S[fnName])
    end

    S.RegisterVerticalLayoutCategory = logged("RegisterVerticalLayoutCategory", function(title)
        state.verticalCalls[#state.verticalCalls + 1] = { title = title }
        return verticalCategory, { _isVerticalLayout = true }
    end)

    S.RegisterInitializer = logged("RegisterInitializer", function(category, initializer)
        state.registerInitializerCalls[#state.registerInitializerCalls + 1] =
            { category = category, initializer = initializer }
    end)

    -- Blizzard asserts addSearchTags ~= nil on every client.
    _G.CreateSettingsButtonInitializer = logged("CreateSettingsButtonInitializer", function(...)
        local name, buttonText, buttonClick, tooltip, addSearchTags = ...
        assert(addSearchTags ~= nil, "addSearchTags must not be nil")
        local initializer = { _isInitializer = true }
        state.initializerCalls[#state.initializerCalls + 1] = {
            name          = name,
            buttonText    = buttonText,
            buttonClick   = buttonClick,
            tooltip       = tooltip,
            addSearchTags = addSearchTags,
            argCount      = select("#", ...),
            initializer   = initializer,
        }
        return initializer
    end)

    return state, verticalCategory, rootCategory
end

-- A launch function that records each call and its argument count.
local function makeLaunch()
    local rec = { calls = 0, argCounts = {} }
    rec.fn = function(...)
        rec.calls = rec.calls + 1
        rec.argCounts[#rec.argCounts + 1] = select("#", ...)
    end
    return rec
end

-- A minimal valid launcher config. Tests override fields via 'over'.
local function validLauncher(over)
    local cfg = {
        title      = "TestAddon",
        buttonText = "Open TestAddon",
        launch     = function() end,
    }
    if over then
        for k, v in pairs(over) do cfg[k] = v end
    end
    return cfg
end

-- Simulates the player clicking the registered button: Blizzard's OnClick
-- passes (button, mouseButton, down).
local function click(state, index)
    state.initializerCalls[index or 1].buttonClick({}, "LeftButton", false)
end

local LAUNCHER_CALLS = {
    "RegisterVerticalLayoutCategory",
    "CreateSettingsButtonInitializer",
    "RegisterInitializer",
    "RegisterAddOnCategory",
}

local function assertLog(log, expected, msg)
    T.eq(#log, #expected, msg .. ": call count")
    for i, fnName in ipairs(expected) do
        T.eq(log[i], fnName, msg .. ": call " .. i)
    end
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

test("Neither present: RaiseDevError raised, no registration occurs", function()
    local F = T.fresh()
    installNeither()
    T.raises(function() F.Settings:New(valid()) end,
        "neither present", "Settings API")
end)

test("Legacy-only client: New refuses and never calls InterfaceOptions_AddCategory", function()
    local F = T.fresh()
    local state = installLegacyOnly()
    T.raises(function() F.Settings:New(valid()) end,
        "legacy only", "Settings API")
    T.eq(#state.addCategoryCalls, 0, "InterfaceOptions_AddCategory was not called")

    -- A refusal must not hold the name: once the Settings API is present, the
    -- same title registers normally.
    local modern = installModern()
    local c = F.Settings:New(valid())
    T.truthy(c, "same name registers after the refusal")
    T.eq(#modern.registerRootCalls, 1, "exactly one root registration")
end)

test("Partial Settings table (missing RegisterAddOnCategory): refused, nothing registered", function()
    local F = T.fresh()
    local state = installLegacyOnly()
    local registerCalls = 0
    _G.Settings = { RegisterCanvasLayoutCategory = function() registerCalls = registerCalls + 1 end }
    T.raises(function() F.Settings:New(valid()) end,
        "partial modern", "Settings API")
    T.eq(registerCalls, 0, "RegisterCanvasLayoutCategory was not called")
    T.eq(#state.addCategoryCalls, 0, "InterfaceOptions_AddCategory was not called")
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

test("duplicate key freed on :Destroy; a same-name :New succeeds again", function()
    local F = T.fresh()
    installModern()
    -- Same frame across the cycle: re-registration re-binds the cached
    -- category rather than registering a duplicate.
    local frame = makeFrame()
    local c1 = F.Settings:New(valid({ title = "Addon", frame = frame }))
    T.truthy(c1, "first registration")
    c1:Destroy()
    -- After destroy, the key is free, re-registration must succeed.
    local c2 = F.Settings:New(valid({ title = "Addon", frame = frame }))
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
    -- Same frame across the cycle: the freed key re-binds the cached
    -- category rather than registering a duplicate.
    local frame = makeFrame()
    local c = F.Settings:New(valid({ title = "Addon", frame = frame }))
    T.truthy(c, "controller created")
    T.falsy(c._destroyed, "not destroyed before :Destroy")
    c:Destroy()
    T.truthy(c._destroyed, "_destroyed set to true")
    -- Key freed: a new registration with the same name must succeed.
    local c2 = F.Settings:New(valid({ title = "Addon", frame = frame }))
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

--------------------------------------------------------------------------------
-- Registered-category re-bind: New/Destroy cycles must not register
-- a duplicate options-panel category.
--------------------------------------------------------------------------------

test("New/Destroy/New with matching inputs re-binds; no duplicate registration", function()
    local F = T.fresh()
    local state = installModern()
    local frame = makeFrame()
    local a = F.Settings:New({ title = "MyAddon", frame = frame })
    T.eq(#state.registerRootCalls, 1, "first New registers")
    a:Destroy()
    local b = F.Settings:New({ title = "MyAddon", frame = frame })
    T.eq(#state.registerRootCalls, 1, "re-New registers NOTHING (re-bound)")
    T.eq(#state.registerAddOnCalls, 1, "RegisterAddOnCategory not repeated")
    -- The re-bound controller is fully functional against the cached category.
    T.eq(b:GetCategoryID(), 35, "re-bound controller resolves the category ID")
    b:Open()
    T.eq(#state.openCalls, 1, "Open drives the cached category")
    T.eq(state.openCalls[1].categoryID, 35, "opened at the cached category's ID")
end)

test("re-New with a DIFFERENT frame is refused (category is stuck)", function()
    local F = T.fresh()
    local state = installModern()
    local a = F.Settings:New({ title = "MyAddon", frame = makeFrame() })
    a:Destroy()
    T.raises(function()
        F.Settings:New({ title = "MyAddon", frame = makeFrame() })
    end, "different frame refused", "must reuse the same registration inputs")
    T.eq(#state.registerRootCalls, 1, "no second registration attempted")
end)

test("subcategory re-bind requires the same parent category and registers nothing", function()
    local F = T.fresh()
    local state = installModern()
    local parentFrame, childFrame = makeFrame(), makeFrame()
    local parent = F.Settings:New({ title = "Parent", frame = parentFrame })
    local child = F.Settings:New({ title = "Child", frame = childFrame, parent = parent })
    T.eq(#state.registerSubCalls, 1, "child registered once")
    child:Destroy()
    local child2 = F.Settings:New({ title = "Child", frame = childFrame, parent = parent })
    T.eq(#state.registerSubCalls, 1, "child re-bind registers nothing")
    T.eq(child2:GetCategoryID(), 36, "re-bound child resolves its category")
end)

test("cycling the PARENT does not break a child re-bind (category identity survives)", function()
    local F = T.fresh()
    local state = installModern()
    local parentFrame, childFrame = makeFrame(), makeFrame()
    local parent = F.Settings:New({ title = "Parent", frame = parentFrame })
    local child = F.Settings:New({ title = "Child", frame = childFrame, parent = parent })
    child:Destroy()
    parent:Destroy()
    -- The re-bound parent carries the SAME cached category object, so the
    -- child's parent-identity comparison still matches.
    local parent2 = F.Settings:New({ title = "Parent", frame = parentFrame })
    local child2 = F.Settings:New({ title = "Child", frame = childFrame, parent = parent2 })
    T.eq(#state.registerRootCalls, 1, "parent never re-registered")
    T.eq(#state.registerSubCalls, 1, "child never re-registered")
    T.eq(child2:GetCategoryID(), 36, "child re-bound through the cycled parent")
end)

--------------------------------------------------------------------------------
-- Launcher mode: a vertical-layout category holding one button
--------------------------------------------------------------------------------

local M1 = "Settings:New: supply exactly one of config.frame or config.launch"
local M2 = "Settings:New: config.frame must be a WoW frame (table with GetObjectType), or supply config.launch instead"
local M3 = "Settings:New: config.frame must be a WoW frame (table with GetObjectType)"
local M4 = "Settings:New: config.buttonText is only used with config.launch"
local M5 = "Settings:New: config.launch must be a function"
local M6 = "Settings:New: config.buttonText must be a non-empty string when config.launch is used"
local M7 = "Settings:New: config.parent is not supported with config.launch"
local M8 = "Settings:New: Blizzard's Settings API for launcher categories (Settings.RegisterVerticalLayoutCategory, "
    .. "Settings.RegisterInitializer, Settings.RegisterAddOnCategory and CreateSettingsButtonInitializer) "
    .. "is not available on this client"
local M10 = "Settings: the launcher button for 'TestAddon' was clicked after its controller was destroyed; "
    .. "call :New again with the same title and buttonText to restore it"

test("launcher: four Blizzard calls in order, RegisterAddOnCategory last; no canvas calls, no frames", function()
    local F = T.fresh()
    local state, verticalCategory = installLauncher()
    local c = F.Settings:New(validLauncher())
    T.truthy(c, "controller created")
    assertLog(state.log, LAUNCHER_CALLS, "launcher registration")
    T.eq(#state.registerRootCalls, 0, "RegisterCanvasLayoutCategory not called")
    T.eq(#state.registerSubCalls, 0, "RegisterCanvasLayoutSubcategory not called")
    T.eq(state.verticalCalls[1].title, "TestAddon", "vertical category takes the title")
    T.eq(state.registerInitializerCalls[1].category, verticalCategory, "RegisterInitializer got the category")
    T.eq(state.registerInitializerCalls[1].initializer, state.initializerCalls[1].initializer,
        "RegisterInitializer got the created initializer")
    T.eq(state.registerAddOnCalls[1].category, verticalCategory, "RegisterAddOnCategory got the category")
    T.eq(#T.frames, 0, "launcher :New never calls CreateFrame")
end)

test("launcher: button initializer receives title, buttonText, nil tooltip, search tags on, and a wrapper", function()
    local F = T.fresh()
    local state = installLauncher()
    local launch = function() end
    F.Settings:New(validLauncher({ title = "MyAddon", buttonText = "Open MyAddon", launch = launch }))
    local call = state.initializerCalls[1]
    T.eq(call.argCount,      5,              "exactly five arguments passed")
    T.eq(call.name,          "MyAddon",      "name is the title")
    T.eq(call.buttonText,    "Open MyAddon", "buttonText forwarded")
    T.eq(call.tooltip,       nil,            "tooltip is nil")
    T.eq(call.addSearchTags, true,           "addSearchTags is true")
    T.eq(type(call.buttonClick), "function", "click handler is a function")
    T.truthy(call.buttonClick ~= launch,     "click handler is a wrapper, not the consumer's launch")
end)

test("launcher click: calls launch once with no arguments; after :Destroy dev raises; re-New dispatches to the new launch", function()
    local F = T.fresh()
    local state = installLauncher()
    local first = makeLaunch()
    local c = F.Settings:New(validLauncher({ launch = first.fn }))
    click(state)
    T.eq(first.calls, 1, "launch called once")
    T.eq(first.argCounts[1], 0, "launch received no arguments")

    c:Destroy()
    T.raises(function() click(state) end, "click after destroy", M10)
    T.eq(first.calls, 1, "launch not called after :Destroy")

    local second = makeLaunch()
    local c2 = F.Settings:New(validLauncher({ launch = second.fn }))
    T.truthy(c2, "re-New with a different launch re-binds")
    click(state)
    T.eq(second.calls, 1, "new launch runs")
    T.eq(second.argCounts[1], 0, "new launch received no arguments")
    T.eq(first.calls, 1, "old launch does not run")
end)

test("launcher click after :Destroy in a release build is silent", function()
    local F = T.fresh("1.0.0")
    local state = installLauncher()
    local rec = makeLaunch()
    local c = F.Settings:New(validLauncher({ launch = rec.fn }))
    c:Destroy()
    click(state)
    T.eq(#T.output, 0, "no output line")
    T.eq(rec.calls, 0, "launch not called")
end)

test("launcher refusals: each raises its message, makes no Blizzard calls, and leaves the name free", function()
    local cases = {
        { "frame and launch",           function() return validLauncher({ frame = makeFrame() }) end, M1 },
        { "invalid frame and launch",   function() return validLauncher({ frame = {} }) end,          M1 },
        { "neither frame nor launch",   function() return { title = "TestAddon" } end,                M2 },
        { "invalid frame alone",        function() return valid({ frame = {} }) end,                  M3 },
        { "frame with empty buttonText", function() return valid({ buttonText = "" }) end,            M4 },
        { "frame with buttonText",      function() return valid({ buttonText = "Open" }) end,         M4 },
        { "launch = false",             function() return validLauncher({ launch = false }) end,      M5 },
        { "launch is a string",         function() return validLauncher({ launch = "open" }) end,     M5 },
        { "buttonText nil", function()
            local cfg = validLauncher(); cfg.buttonText = nil; return cfg
        end, M6 },
        { "buttonText empty",           function() return validLauncher({ buttonText = "" }) end,     M6 },
        { "buttonText not a string",    function() return validLauncher({ buttonText = 5 }) end,      M6 },
        { "launch with parent table",   function() return validLauncher({ parent = {} }) end,         M7 },
    }
    for _, case in ipairs(cases) do
        local label, build, message = case[1], case[2], case[3]
        local F = T.fresh()
        local state = installLauncher()
        T.raises(function() F.Settings:New(build()) end, label, message)
        T.eq(#state.log, 0, label .. ": no Blizzard calls")
        local after = installLauncher()
        T.truthy(F.Settings:New(validLauncher()), label .. ": the name is still free")
        assertLog(after.log, LAUNCHER_CALLS, label .. ": later :New registers fresh")
    end

    -- A live canvas parent is refused as well, with no further calls.
    local F = T.fresh()
    local state = installLauncher()
    local parent = F.Settings:New(valid({ title = "Parent" }))
    local before = #state.log
    T.raises(function()
        F.Settings:New(validLauncher({ parent = parent }))
    end, "launch with live parent", M7)
    T.eq(#state.log, before, "launch with live parent: no Blizzard calls")
end)

test("launcher refusals: a missing launcher API function refuses with no calls; the name stays free", function()
    local removals = {
        { "RegisterVerticalLayoutCategory", function() _G.Settings.RegisterVerticalLayoutCategory = nil end },
        { "RegisterInitializer",            function() _G.Settings.RegisterInitializer = nil end },
        { "RegisterAddOnCategory",          function() _G.Settings.RegisterAddOnCategory = nil end },
        { "CreateSettingsButtonInitializer", function() _G.CreateSettingsButtonInitializer = nil end },
    }
    for _, removal in ipairs(removals) do
        local label, remove = removal[1], removal[2]
        local F = T.fresh()
        local state = installLauncher()
        remove()
        T.raises(function() F.Settings:New(validLauncher()) end, "missing " .. label, M8)
        T.eq(#state.log, 0, "missing " .. label .. ": no Blizzard calls")
        local after = installLauncher()
        T.truthy(F.Settings:New(validLauncher()), "missing " .. label .. ": the name is still free")
        assertLog(after.log, LAUNCHER_CALLS, "missing " .. label .. ": later :New registers fresh")
    end
end)

test("launcher validation order: title, then mode, then fields, then parent", function()
    local F = T.fresh()
    installLauncher()
    T.raises(function() F.Settings:New({ title = "" }) end,
        "title before mode", "config.title must be a non-empty string")
    T.raises(function() F.Settings:New(validLauncher({ frame = "notaframe" })) end,
        "exactly-one before frame type", M1)
    local cfg = validLauncher({ launch = false }); cfg.buttonText = nil
    T.raises(function() F.Settings:New(cfg) end, "launch type before buttonText", M5)
    T.raises(function()
        F.Settings:New(validLauncher({ buttonText = "", parent = {} }))
    end, "fields before parent", M6)
    T.raises(function()
        F.Settings:New(validLauncher({ parent = {}, name = "" }))
    end, "parent before name", M7)
    -- M3 text is unchanged for an invalid frame without a launch.
    T.raises(function() F.Settings:New(valid({ frame = {} })) end, "invalid frame", M3)
end)

test("launcher :Open opens the category, never launch; :GetCategoryID returns its ID", function()
    local F = T.fresh()
    local state = installLauncher()
    local rec = makeLaunch()
    local c = F.Settings:New(validLauncher({ launch = rec.fn }))
    c:Open()
    T.eq(#state.openCalls, 1, "OpenToCategory called once")
    T.eq(state.openCalls[1].categoryID, 35, "opened at the category's ID")
    T.eq(rec.calls, 0, ":Open does not call launch")
    T.eq(c:GetCategoryID(), 35, "GetCategoryID returns 35")
end)

test("launcher :GetNativeHandles shape; canvas gains kind; a matching re-New reuses the cached objects", function()
    local F = T.fresh()
    local state, verticalCategory = installLauncher()
    local c = F.Settings:New(validLauncher())
    local h = c:GetNativeHandles()
    T.eq(h.frame,       nil,              "frame is nil for a launcher")
    T.eq(h.category,    verticalCategory, "category is the vertical category")
    T.eq(h.categoryID,  35,               "categoryID from category:GetID()")
    T.eq(h.mode,        "settings",       "mode is 'settings'")
    T.truthy(h.layout and h.layout._isVerticalLayout, "layout is the vertical layout")
    T.eq(h.initializer, state.initializerCalls[1].initializer, "initializer is the button initializer")
    T.eq(h.kind,        "launcher",       "kind is 'launcher'")

    local canvas = F.Settings:New(valid({ title = "CanvasAddon" }))
    local ch = canvas:GetNativeHandles()
    T.eq(ch.kind,        "canvas", "canvas kind is 'canvas'")
    T.eq(ch.initializer, nil,      "canvas has no initializer")

    c:Destroy()
    T.eq(c._launch,      nil, "_launch released")
    T.eq(c._initializer, nil, "_initializer released")
    local before = #state.log
    local c2 = F.Settings:New(validLauncher())
    local h2 = c2:GetNativeHandles()
    T.eq(#state.log, before, "re-New makes no Blizzard calls")
    T.eq(h2.initializer, h.initializer, "same initializer object")
    T.eq(h2.category,    h.category,    "same category object")
    T.eq(h2.layout,      h.layout,      "same layout object")
    T.eq(h2.kind,        "launcher",    "kind is 'launcher'")
end)

test("launcher re-bind: the API check applies to fresh registrations only", function()
    local F = T.fresh()
    local state = installLauncher()
    local c = F.Settings:New(validLauncher())
    c:Destroy()
    _G.CreateSettingsButtonInitializer = nil
    _G.Settings.RegisterVerticalLayoutCategory = nil
    local before = #state.log
    T.truthy(F.Settings:New(validLauncher()), "matching re-New succeeds without the launcher API")
    T.eq(#state.log, before, "no Blizzard calls")
end)

test("launcher re-bind: mismatches refuse with a token and make no calls", function()
    local F = T.fresh()
    local state = installLauncher()
    local frame = makeFrame()

    local c = F.Settings:New(validLauncher())
    c:Destroy()
    local before = #state.log
    T.raises(function()
        F.Settings:New(validLauncher({ buttonText = "Open Something Else" }))
    end, "different buttonText", "with a different buttonText")
    T.raises(function()
        F.Settings:New(validLauncher({ title = "Other Title", name = "TestAddon" }))
    end, "different title", "with a different title")
    T.raises(function()
        F.Settings:New(valid({ title = "TestAddon", frame = frame }))
    end, "launcher to canvas", "with a different kind")
    T.eq(#state.log, before, "launcher-side refusals: no Blizzard calls")

    local canvas = F.Settings:New(valid({ title = "CanvasAddon", frame = frame }))
    canvas:Destroy()
    before = #state.log
    T.raises(function()
        F.Settings:New(validLauncher({ title = "CanvasAddon" }))
    end, "canvas to launcher", "with a different kind")
    T.eq(#state.log, before, "canvas-side refusal: no Blizzard calls")
end)

test("launcher as parent: a canvas child registers under the launcher's category", function()
    local F = T.fresh()
    local state, verticalCategory = installLauncher()
    local parent = F.Settings:New(validLauncher({ title = "ParentAddon" }))
    local addOnBefore = #state.registerAddOnCalls
    local childFrame = makeFrame()
    local child = F.Settings:New({ title = "ChildPanel", frame = childFrame, parent = parent })
    T.truthy(child, "child controller created")
    T.eq(#state.registerSubCalls, 1, "RegisterCanvasLayoutSubcategory called once")
    T.eq(state.registerSubCalls[1].parentCategory, verticalCategory, "child registered under the launcher's category")
    T.eq(state.registerSubCalls[1].frame, childFrame, "child frame forwarded")
    T.eq(#state.registerAddOnCalls, addOnBefore, "RegisterAddOnCategory not called again")
end)

test("live-key duplicate refusal applies across canvas and launcher", function()
    local F = T.fresh()
    local state = installLauncher()
    F.Settings:New(validLauncher({ title = "Addon" }))
    local before = #state.log
    T.raises(function() F.Settings:New(valid({ title = "Addon" })) end,
        "canvas over live launcher", "a live controller already owns the name")

    F.Settings:New(valid({ title = "Other" }))
    T.raises(function() F.Settings:New(validLauncher({ title = "Other" })) end,
        "launcher over live canvas", "a live controller already owns the name")
    T.eq(#state.log, before + 2, "only the canvas registration's two calls were made")
end)

test("release build: a launcher refusal prints and returns nil", function()
    local F = T.fresh("1.0.0")
    local state = installLauncher()
    local c = F.Settings:New(validLauncher({ launch = false }))
    T.eq(c, nil, "release :New returns nil")
    T.outputContains(M5, "release printed the diagnostic")
    T.eq(#state.log, 0, "no Blizzard calls")
end)

test("launcher: a throw in a registration step propagates and holds no name or cache entry", function()
    for step = 2, 4 do
        local fnName = LAUNCHER_CALLS[step]
        local F = T.fresh()
        local state = installLauncher()
        state.throwOn[fnName] = true
        T.raises(function() F.Settings:New(validLauncher()) end,
            "throw at " .. fnName, "stub throw: " .. fnName)
        T.eq(#state.log, step, fnName .. ": registration stopped at the throwing call")
        T.eq(state.log[step], fnName, fnName .. ": the throwing call is last")

        state.throwOn[fnName] = nil
        state.log = {}
        T.truthy(F.Settings:New(validLauncher()), fnName .. ": the name is still free")
        assertLog(state.log, LAUNCHER_CALLS, fnName .. ": retry registers from the first call")
    end
end)

return tests

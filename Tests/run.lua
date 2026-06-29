-- Foundry.Commands test runner (plain Lua 5.1, no external dependencies).
--
-- Run from the Foundry repo root or anywhere:
--   lua5.1 Tests/run.lua
--
-- These tests are development-only: they are NOT listed in the shipped TOC.
-- They mock the handful of WoW globals the module uses, load the bootstrap +
-- module fresh per test, and assert behavior against the module's public
-- contract.

local realPrint = print  -- preserve the real print; tests mock _G.print

local scriptPath = (arg and arg[0]) or "Tests/run.lua"
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

    -- Clear Settings flavor globals so each test starts with no surface installed.
    -- Settings tests install exactly one surface (modern OR legacy OR neither) via
    -- their per-test helper after T.fresh(). Without this reset a surface set by
    -- a previous test would leak through to the next test's :New call.
    _G.Settings                     = nil
    _G.InterfaceOptions_AddCategory = nil
    _G.InterfaceOptionsFrame        = nil
    _G.TooltipDataProcessor = nil

    _G.SlashCmdList = {}

    -- Player/realm identity for Foundry.DB (spec §3.4: charKey = "Name - Realm").
    -- T-controllable per test via T.identity. The DEFAULT is a multi-word realm
    -- with internal spaces ("Test Realm") so a charKey separator/space bug cannot
    -- hide -- a wrong separator or a stripped space changes the key and orphans a
    -- bucket. A test sets T.identity = { name = ..., realm = ... } before :New to
    -- exercise the nil / "" / "Unknown" refuse-before-mutation paths, or to match a
    -- fixture's bucket key. UnitName("player") returns (name, serverName-or-nil) on
    -- the real client; the realm comes from GetRealmName(), so the mock returns
    -- (name, nil) from UnitName and the realm from GetRealmName -- the real shape
    -- AceDB and DB both consume (acedb-semantics.md §1).
    T.identity = { name = "Tester", realm = "Test Realm" }
    _G.UnitName = function(unit)
        if unit == "player" then return T.identity.name, nil end
        return T.identity.name, nil
    end
    _G.GetRealmName = function()
        return T.identity.realm
    end

    -- Test SavedVariables globals are cleared so no state leaks across cases. DB
    -- resolves/creates _G[sv]; a residual table from a prior test would mask a
    -- fresh-save path. The set covers every sv name the DB specs construct.
    for _, name in ipairs({
        "HomesteadDB", "BawrSpamDB", "TestDB", "TestDB2", "SyntheticDB",
        "DB_A", "DB_B", "FxHomestead", "FxBawrSpam",
    }) do
        _G[name] = nil
    end

    -- Lifecycle's addon-loaded catch-up probes C_AddOns.IsAddOnLoaded(addonName).
    -- T.loadedAddons is the per-test set of names the mock reports on; empty by
    -- default, so the normal (not-yet-loaded) path runs and a test opts a name in
    -- explicitly to exercise catch-up.
    T.loadedAddons = {}
    _G.C_AddOns = {
        GetAddOnMetadata = function(_, key)
            if key == "Version" then return tocVersion end
            return nil
        end,
        -- The REAL C_AddOns.IsAddOnLoaded returns TWO booleans: loadedOrLoading,
        -- loaded. The catch-up's "finished loading" gate keys on the SECOND value,
        -- so the mock must return both faithfully (a single-boolean mock would mask
        -- a catch-up that fires mid-load). T.loadedAddons[name] models three states:
        --   true       -> fully loaded   -> (true,  true)
        --   "loading"  -> still loading  -> (true,  false)
        --   nil/false  -> not loaded     -> (false, false)
        IsAddOnLoaded = function(name)
            local state = T.loadedAddons[name]
            if state == true then return true, true end
            if state == "loading" then return true, false end
            return false, false
        end,
    }

    -- CreateFrame stub (additive; Commands never calls CreateFrame).
    -- Returns a recorder frame whose event/script methods log calls so Events
    -- tests can assert what the controller drove on the native frame, and a
    -- T.Fire(frame, event, ...) helper synthesizes an OnEvent delivery by
    -- invoking the captured OnEvent script as onEvent(frame, event, ...).
    --
    -- The signature captures (kind, name, parent, template) so Foundry.List tests
    -- can find the WowScrollBoxList frame and the MinimalScrollBar EventFrame by
    -- (kind, template). Frames built from the WowScrollBoxList template gain the
    -- ScrollBox-list methods (SetDataProvider / ForEachFrame / RemoveDataProvider /
    -- GetDataProvider), wired to a view by ScrollUtil.InitScrollBoxListWithScrollBar.
    -- The existing event-frame buckets and OnEvent plumbing are unchanged, so the
    -- Commands/Events/Lifecycle/DB suites are unaffected.
    T.frames = {}
    _G.CreateFrame = function(kind, name, parent, template)
        local frame = {}
        frame._kind = kind
        frame._name = name
        frame._parent = parent
        frame._template = template
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
            SetPoint = {},
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
        frame._scripts = {}
        function frame:SetScript(name, fn)
            self.calls.SetScript[#self.calls.SetScript + 1] = { name, fn }
            self._scripts[name] = fn
            if name == "OnEvent" then self._onEvent = fn end
        end
        -- Lifecycle:_TestFire fetches the live OnEvent via GetScript to drive the
        -- real dispatcher path without touching registration; mirror the real frame.
        function frame:GetScript(name)
            return self._scripts[name]
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
        -- Layout recorders (List anchors its ScrollBox/ScrollBar). No-op math; the
        -- recorder only logs that the call happened with its args.
        function frame:SetPoint(...)
            self.calls.SetPoint[#self.calls.SetPoint + 1] = { ... }
        end
        function frame:ClearAllPoints() end

        -- WowScrollBoxList frames carry the ScrollBox-list surface List drives.
        -- SetDataProvider delegates to the view (so the factory-before-provider
        -- trap fires through the view) and records the box-level scroll-to-begin.
        if template == "WowScrollBoxList" then
            frame._realizedFrames = {}
            frame.calls.SetDataProvider = {}
            frame.calls.RemoveDataProvider = {}
            frame.calls.ForEachFrame = {}
            function frame:SetDataProvider(provider, retainScrollPosition)
                if not self._view then
                    error("ScrollBox:SetDataProvider: a view is required before assigning the data provider.")
                end
                self._view:SetDataProvider(provider)
                if not retainScrollPosition then self._scrolledToBegin = true end
                self.calls.SetDataProvider[#self.calls.SetDataProvider + 1] =
                    { provider = provider, retain = retainScrollPosition }
            end
            function frame:GetDataProvider()
                return self._view and self._view:GetDataProvider()
            end
            function frame:RemoveDataProvider()
                if self._view then self._view._dataProvider = nil end
                self.calls.RemoveDataProvider[#self.calls.RemoveDataProvider + 1] = {}
            end
            function frame:ForEachFrame(fn)
                self.calls.ForEachFrame[#self.calls.ForEachFrame + 1] = {}
                for _, rf in ipairs(self._realizedFrames) do
                    local stop = fn(rf, rf._elementData)
                    if stop then return stop end
                end
            end
        end
        T.frames[#T.frames + 1] = frame
        return frame
    end

    -- The modern ScrollBox view, data provider, and ScrollUtil wiring that
    -- Foundry.List composes. Recorder objects that replicate the real call
    -- REQUIREMENTS (not just accept calls): SetDataProvider errors if no element
    -- factory was set first (factory-before-provider trap), and
    -- InitScrollBoxListWithScrollBar errors if the scrollbar is not an EventFrame.
    T.views = {}
    _G.CreateScrollBoxListLinearView = function(top, bottom, left, right, spacing)
        local view = {
            _spacing = spacing,
            _elementFactory = false,
            calls = {
                SetElementExtent = {},
                SetElementExtentCalculator = {},
                SetElementInitializer = {},
                SetElementResetter = {},
                SetDataProvider = {},
            },
        }
        function view:SetElementExtent(n)
            self._extent = n
            self.calls.SetElementExtent[#self.calls.SetElementExtent + 1] = { n }
        end
        function view:SetElementExtentCalculator(fn)
            self._calc = fn
            self.calls.SetElementExtentCalculator[#self.calls.SetElementExtentCalculator + 1] = { fn }
        end
        function view:SetElementInitializer(typeOrTemplate, fn)
            self._elementFactory = true
            self._initType = typeOrTemplate
            self._initializer = fn
            self.calls.SetElementInitializer[#self.calls.SetElementInitializer + 1] = { typeOrTemplate }
        end
        function view:SetElementResetter(fn)
            self._resetter = fn
            self.calls.SetElementResetter[#self.calls.SetElementResetter + 1] = { fn }
        end
        function view:SetDataProvider(provider)
            if not self._elementFactory then
                error("SetDataProvider() elementFactory was nil. Call SetElementFactory() before setting the data provider.")
            end
            self._dataProvider = provider
            self.calls.SetDataProvider[#self.calls.SetDataProvider + 1] = { provider }
        end
        function view:GetDataProvider()
            return self._dataProvider
        end
        T.views[#T.views + 1] = view
        return view
    end

    _G.CreateDataProvider = function(tbl)
        local provider = { _rows = tbl or {} }
        function provider:GetSize()
            return #self._rows
        end
        return provider
    end

    _G.ScrollUtil = {
        _selectionCalls = 0,
        InitScrollBoxListWithScrollBar = function(scrollBox, scrollBar, view)
            if not (scrollBar and scrollBar._kind == "EventFrame") then
                error("InitScrollBoxListWithScrollBar: scrollBar must be an EventFrame (got "
                    .. tostring(scrollBar and scrollBar._kind) .. ")")
            end
            scrollBox._view = view
            scrollBox._bar = scrollBar
            scrollBox._inited = true
        end,
        AddManagedScrollBarVisibilityBehavior = function(scrollBox, scrollBar)
            return { _box = scrollBox, _bar = scrollBar, _managed = true }
        end,
        -- v1 List must NEVER wire native selection; the spec cuts it. The stub
        -- counts calls so a test can assert List makes none.
        AddSelectionBehavior = function()
            _G.ScrollUtil._selectionCalls = _G.ScrollUtil._selectionCalls + 1
            return {}
        end,
    }
    -- C_Timer stub (additive; only Foundry.Events' RegisterBucket uses it, and
    -- no module touches C_Timer at load, so the other suites stay green). The
    -- bucket schedules its flush via C_Timer.NewTimer (a CANCELABLE handle) so
    -- Cancel()/Destroy() can kill a pending flush. The stub mirrors that handle:
    -- NewTimer(interval, cb) records the timer in T.timers and returns a handle
    -- with :Cancel() (sets _cancelled) and :IsCancelled(). Nothing fires on its
    -- own -- a test drives expiry deterministically via T.FireTimer(handle),
    -- which invokes cb exactly once and only if the handle was never cancelled
    -- (one-shot, like the real C_Timer.NewTimer firing).
    T.timers = {}
    _G.C_Timer = {
        NewTimer = function(interval, callback)
            local handle = {
                _interval = interval,
                _callback = callback,
                _cancelled = false,
                _fired = false,
            }
            function handle:Cancel()
                self._cancelled = true
            end
            function handle:IsCancelled()
                return self._cancelled
            end
            T.timers[#T.timers + 1] = handle
            return handle
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

-- Synthesize a native OnEvent delivery: invoke the frame's captured OnEvent
-- script exactly as WoW would, onEvent(frame, event, ...). A no-op if the
-- frame has no OnEvent script (e.g. after Destroy detaches it).
function T.Fire(frame, event, ...)
    local onEvent = frame and frame._onEvent
    if onEvent then return onEvent(frame, event, ...) end
end

-- Synthesize a C_Timer expiry: invoke the handle's recorded callback exactly
-- once, and only if the handle was never cancelled (the real one-shot timer
-- never fires after Cancel()). A no-op for a cancelled or already-fired handle,
-- so a test can assert a rescheduled/torn-down timer never reaches its handler.
function T.FireTimer(handle)
    if not handle or handle._cancelled or handle._fired then return end
    handle._fired = true
    return handle._callback()
end

-- The Tests/ directory path, exposed so specs can build fixture paths
-- (e.g. T.loadFixture(T.testsDir .. "/DB/fixtures/empty.lua")).
T.testsDir = testsDir

-- The Foundry repo root, exposed so the FND-007 injection specs can loadfile a
-- SINGLE module file (Foundry.lua or Modules/DB.lua) against a hand-injected
-- _G.Foundry_1_0 / hand-stubbed F.Lifecycle -- the graft scenarios the normal
-- T.loadFoundry() path cannot reproduce (it pre-registers DB and loads a real,
-- seam-bearing Lifecycle). Dev-test-only; the shipped TOC never loads run.lua.
T.foundryRoot = foundryRoot

-- Load one module file (relpath from the repo root, e.g. "Modules/DB.lua")
-- against the current _G.Foundry_1_0, exactly as the TOC would. Convenience for
-- the injection specs; pairs with installMocks (which resets _G.Foundry_1_0).
function T.loadModule(relpath)
    return assert(loadfile(foundryRoot .. "/" .. relpath))("Foundry-1.0")
end

-- Load a SavedVariables-format fixture — a bare `NAME = { ... }` global
-- assignment, exactly the on-disk WTF shape — into a fresh sandbox env and
-- return that env (so the caller reads env.NAME). Path-parameterized on
-- purpose: specs load the committed fixtures under Tests/DB/fixtures/, and
-- the Gate-2 real-save-file proofs pass an absolute path to a live WTF file
-- through this very same loader, so both modes exercise identical code.
-- The sandbox env is fresh and empty per call: fixtures are pure data and
-- never see (or pollute) the test mocks or real globals.
function T.loadFixture(path)
    local chunk = assert(loadfile(path))
    local env = {}
    setfenv(chunk, env)
    chunk()
    return env
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
    local lifecycle = assert(loadfile(foundryRoot .. "/Modules/Lifecycle.lua"))
    lifecycle("Foundry-1.0")
    local db = assert(loadfile(foundryRoot .. "/Modules/DB.lua"))
    db("Foundry-1.0")
    local list = assert(loadfile(foundryRoot .. "/Modules/List.lua"))
    list("Foundry-1.0")
    local settings = assert(loadfile(foundryRoot .. "/Modules/Settings.lua"))
    settings("Foundry-1.0")
    local tooltip = assert(loadfile(foundryRoot .. "/Modules/Tooltip.lua"))
    tooltip("Foundry-1.0")
    local menu = assert(loadfile(foundryRoot .. "/Modules/Menu.lua"))
    menu("Foundry-1.0")
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
    { label = "Foundry.Commands",  cases = assert(loadfile(testsDir .. "/Commands/commands_spec.lua"))(T) },
    { label = "Foundry.Events",    cases = assert(loadfile(testsDir .. "/Events/events_spec.lua"))(T) },
    { label = "Foundry.Lifecycle", cases = assert(loadfile(testsDir .. "/Lifecycle/lifecycle_spec.lua"))(T) },
    { label = "Foundry.Bootstrap", cases = assert(loadfile(testsDir .. "/Bootstrap/bootstrap_spec.lua"))(T) },
    { label = "Foundry.DB",        cases = assert(loadfile(testsDir .. "/DB/db_spec.lua"))(T) },
    { label = "Foundry.DB.parity", cases = assert(loadfile(testsDir .. "/DB/acedb_parity.lua"))(T) },
    { label = "Foundry.List",      cases = assert(loadfile(testsDir .. "/List/list_spec.lua"))(T) },
    { label = "Foundry.Settings",  cases = assert(loadfile(testsDir .. "/Settings/settings_spec.lua"))(T) },
    { label = "Foundry.Tooltip",   cases = assert(loadfile(testsDir .. "/Tooltip/tooltip_spec.lua"))(T) },
    { label = "Foundry.Menu",      cases = assert(loadfile(testsDir .. "/Menu/menu_spec.lua"))(T) },
    { label = "Foundry.Packaging", cases = assert(loadfile(testsDir .. "/Packaging/packaging_spec.lua"))(T) },
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

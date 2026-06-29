-- Foundry.Menu behavior tests. Loaded by Tests/run.lua, which passes the
-- harness table T. Returns a list of { name, fn } cases covering the v1 public
-- contract: feature detection, atomic :New validation, builder dispatch,
-- vararg forwarding (both the MenuUtil forward AND the wrapper→builder forward),
-- :SetupDropdown, :Destroy disable-in-place, :GetNativeHandles, duplicate-key
-- refusal, anonymous counter, and version pins.
--
-- Stub design:
--   freshMenu([tocVersion])   — calls T.fresh(), clears menu globals (MenuUtil /
--                               Menu / MenuResponse), returns F. Menu.lua is
--                               loaded by T.loadFoundry() so freshMenu() does
--                               not need to load it manually.
--   installMenuUtil()         — installs _G.MenuUtil + _G.Menu + _G.MenuResponse;
--                               returns spy state { createCalls, lastWrapper }.
--                               state.createCalls[n] = { owner, wrapper, extra }
--                               where extra = { ... } captures the varargs passed
--                               to MenuUtil.CreateContextMenu after the wrapper.
--   makeDropdownButton()      — fake DropdownButton; SetupMenu spy records { wrapper }.
--   makeElementDescription()  — fake elementDescription with SetEnabled / SetTooltip
--                               spies and CreateButton / CreateRadio Create* spies.
--   makeRootDescription()     — alias for makeElementDescription (unified table).
--   valid([over])             — minimal valid config { builder = fn }; fields
--                               overrideable via over.

local T = ...

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

--------------------------------------------------------------------------------
-- Per-test surface helpers
--------------------------------------------------------------------------------

-- Load Foundry fresh (Menu.lua is included by T.loadFoundry); clear the three
-- menu globals that T.installMocks does not reset so no state leaks between tests.
local function freshMenu(tocVersion)
    local F = T.fresh(tocVersion)
    -- T.installMocks does not clear these; wipe them so each test starts neutral.
    _G.MenuUtil     = nil
    _G.Menu         = nil
    _G.MenuResponse = nil
    return F
end

-- Install the full MenuUtil / Menu / MenuResponse stubs.
-- Returns spy state:
--   state.createCalls  — array of { owner, wrapper, extra } per call.
--                         extra = { ... } captures the varargs passed to
--                         CreateContextMenu AFTER the wrapper (the Foundry side
--                         of vararg forwarding).
--   state.lastWrapper  — the most recent wrapper fn passed in.
local function installMenuUtil()
    local state = { createCalls = {}, lastWrapper = nil }
    _G.MenuUtil = {
        CreateContextMenu = function(owner, wrapper, ...)
            state.lastWrapper = wrapper
            state.createCalls[#state.createCalls + 1] = {
                owner   = owner,
                wrapper = wrapper,
                extra   = { ... },
            }
        end,
    }
    _G.Menu        = {}
    _G.MenuResponse = { Open = 1, Refresh = 2, Close = 3, CloseAll = 4 }
    return state
end

-- Fake DropdownButton: SetupMenu spy records { wrapper } per call.
local function makeDropdownButton()
    local btn = { _setupCalls = {} }
    function btn:SetupMenu(wrapper)
        self._setupCalls[#self._setupCalls + 1] = { wrapper = wrapper }
    end
    return btn
end

-- Fake elementDescription with SetEnabled / SetTooltip spies and Create* spies.
-- CreateButton returns a child elementDescription that itself has Create* methods
-- (submenu depth required by test 29).
local function makeElementDescription()
    local ed = {
        _setEnabledCalls   = {},
        _setTooltipCalls   = {},
        _createButtonCalls = {},
        _createRadioCalls  = {},
    }
    function ed:SetEnabled(v)
        self._setEnabledCalls[#self._setEnabledCalls + 1] = v
    end
    function ed:SetTooltip(fn)
        self._setTooltipCalls[#self._setTooltipCalls + 1] = fn
    end
    -- CreateButton: returns a child elementDescription (itself with Create*).
    function ed:CreateButton(text, fn)
        local child = makeElementDescription()
        self._createButtonCalls[#self._createButtonCalls + 1] = {
            text = text, fn = fn, result = child,
        }
        return child
    end
    -- CreateRadio: records call and returns a child elementDescription.
    function ed:CreateRadio(text, isChecked, setChecked, value)
        local child = makeElementDescription()
        self._createRadioCalls[#self._createRadioCalls + 1] = {
            text = text, result = child,
        }
        return child
    end
    return ed
end

-- Convenience alias: a rootDescription is an elementDescription.
local function makeRootDescription()
    return makeElementDescription()
end

-- Minimal valid config. Tests override fields via 'over'.
local function valid(over)
    local cfg = { builder = function() end }
    if over then
        for k, v in pairs(over) do cfg[k] = v end
    end
    return cfg
end

--------------------------------------------------------------------------------
-- 1. API_VERSION
--------------------------------------------------------------------------------

test("API_VERSION == 1", function()
    local F = freshMenu()
    T.eq(F.Menu.API_VERSION, 1, "Menu.API_VERSION == 1")
end)

--------------------------------------------------------------------------------
-- 2. Module surface
--------------------------------------------------------------------------------

test("module surface: F.Menu exists and New is a function", function()
    local F = freshMenu()
    T.truthy(F.Menu, "F.Menu is non-nil")
    T.eq(type(F.Menu.New), "function", "F.Menu.New is a function")
end)

--------------------------------------------------------------------------------
-- 3-4. Feature detection
--------------------------------------------------------------------------------

test("New: raises when MenuUtil is absent (_G.MenuUtil = nil)", function()
    local F = freshMenu()
    -- MenuUtil is nil (freshMenu cleared it); builder+name are valid so the only
    -- failure path is the feature-detect check (#5 in validation order).
    T.raises(function() F.Menu:New(valid()) end,
        "no MenuUtil", "MenuUtil is not available")
end)

test("New: raises when MenuUtil exists but CreateContextMenu is missing", function()
    local F = freshMenu()
    _G.MenuUtil = {}  -- table present but no CreateContextMenu function
    T.raises(function() F.Menu:New(valid()) end,
        "partial MenuUtil", "MenuUtil is not available")
end)

--------------------------------------------------------------------------------
-- 5-9. Validation ordering
--------------------------------------------------------------------------------

test("validation: config not a table raises", function()
    local F = freshMenu()
    installMenuUtil()
    T.raises(function() F.Menu:New("not a table") end,
        "non-table config", "config must be a table")
end)

test("validation: builder nil raises before name is checked", function()
    local F = freshMenu()
    installMenuUtil()
    T.raises(function() F.Menu:New({ builder = nil }) end,
        "nil builder", "config.builder must be a function")
end)

test("validation ordering: builder error fires before name error", function()
    local F = freshMenu()
    installMenuUtil()
    -- Both builder and name are invalid; builder is check #2, name is check #3.
    T.raises(function() F.Menu:New({ builder = nil, name = "" }) end,
        "builder-before-name", "config.builder must be a function")
end)

test("validation: empty string name raises", function()
    local F = freshMenu()
    installMenuUtil()
    T.raises(function() F.Menu:New(valid({ name = "" })) end,
        "empty name", "config.name must be a non-empty string when supplied")
end)

test("validation: non-string non-nil name raises", function()
    local F = freshMenu()
    installMenuUtil()
    T.raises(function() F.Menu:New(valid({ name = 42 })) end,
        "numeric name", "config.name must be a non-empty string when supplied")
end)

--------------------------------------------------------------------------------
-- 10. Atomicity: failed :New does not pollute liveKeys
--------------------------------------------------------------------------------

test("atomicity: failed :New({name='X', builder=nil}) does not block re-registration", function()
    local F = freshMenu()
    installMenuUtil()
    -- First call: builder nil → fails at check #2, before liveKeys is written.
    T.raises(function() F.Menu:New({ name = "X", builder = nil }) end,
        "first call fails")
    -- Second call: same name, valid builder → must succeed.
    local c = F.Menu:New({ name = "X", builder = function() end })
    T.truthy(c, "re-registration with same name succeeds after atomically-failed :New")
end)

--------------------------------------------------------------------------------
-- 11. Valid :New succeeds
--------------------------------------------------------------------------------

test("valid :New returns a non-nil controller", function()
    local F = freshMenu()
    installMenuUtil()
    local c = F.Menu:New(valid())
    T.truthy(c, "controller is non-nil")
end)

--------------------------------------------------------------------------------
-- 12. Anonymous counter
--------------------------------------------------------------------------------

test("anon counter: two :New calls with no name succeed and return distinct controllers", function()
    local F = freshMenu()
    installMenuUtil()
    local c1 = F.Menu:New({ builder = function() end })
    local c2 = F.Menu:New({ builder = function() end })
    T.truthy(c1, "first anon controller non-nil")
    T.truthy(c2, "second anon controller non-nil")
    T.truthy(c1 ~= c2, "anon controllers are distinct table references")
end)

--------------------------------------------------------------------------------
-- 13. Duplicate name refusal
--------------------------------------------------------------------------------

test("duplicate explicit name refused on second :New", function()
    local F = freshMenu()
    installMenuUtil()
    local c1 = F.Menu:New(valid({ name = "MyMenu" }))
    T.truthy(c1, "first registration succeeds")
    T.raises(function() F.Menu:New(valid({ name = "MyMenu" })) end,
        "duplicate name", "a live controller already owns the name")
end)

--------------------------------------------------------------------------------
-- 14. :CreateContextMenu calls MenuUtil.CreateContextMenu with correct args
--------------------------------------------------------------------------------

test(":CreateContextMenu calls MenuUtil.CreateContextMenu(owner, wrapper)", function()
    local F = freshMenu()
    local state = installMenuUtil()
    local owner = {}
    local c = F.Menu:New(valid())
    c:CreateContextMenu(owner)
    T.eq(#state.createCalls, 1, "MenuUtil.CreateContextMenu called once")
    T.eq(state.createCalls[1].owner, owner, "owner arg matches")
    T.eq(type(state.createCalls[1].wrapper), "function", "wrapper is a function")
end)

--------------------------------------------------------------------------------
-- 15. Builder receives (owner, rootDescription) in that order
--------------------------------------------------------------------------------

test(":CreateContextMenu builder receives (owner, rootDescription) in order", function()
    local F = freshMenu()
    local state = installMenuUtil()
    local owner   = { _isOwner = true }
    local rootDesc = makeRootDescription()
    local gotOwner, gotRoot
    local c = F.Menu:New({
        builder = function(o, r) gotOwner = o; gotRoot = r end,
    })
    c:CreateContextMenu(owner)
    -- Simulate Blizzard firing the captured generatorWrapper.
    state.lastWrapper(owner, rootDesc)
    T.eq(gotOwner, owner,    "builder arg1 == owner")
    T.eq(gotRoot,  rootDesc, "builder arg2 == rootDescription")
end)

--------------------------------------------------------------------------------
-- 16. Vararg forwarding: Foundry→MenuUtil AND wrapper→builder
--------------------------------------------------------------------------------

test(":CreateContextMenu forwards extras to MenuUtil AND builder", function()
    local F = freshMenu()
    local state = installMenuUtil()
    local owner    = {}
    local rootDesc = makeRootDescription()
    local received = {}
    local c = F.Menu:New({
        builder = function(...) received = { ... } end,
    })
    -- Call with extras — Foundry must forward them to MenuUtil.CreateContextMenu.
    c:CreateContextMenu(owner, "extra1", 42)
    -- Assert the Foundry→MenuUtil forward (the impl's `...` pass-through).
    local extra = state.createCalls[1].extra
    T.eq(#extra,    2,        "MenuUtil received 2 extra args")
    T.eq(extra[1],  "extra1", "MenuUtil extra[1] == 'extra1'")
    T.eq(extra[2],  42,       "MenuUtil extra[2] == 42")
    -- Simulate Blizzard firing the wrapper with the forwarded extras.
    state.lastWrapper(owner, rootDesc, "extra1", 42)
    -- Assert the wrapper→builder forward.
    T.eq(#received,   4,        "builder received 4 args total")
    T.eq(received[1], owner,    "builder arg1 == owner")
    T.eq(received[2], rootDesc, "builder arg2 == rootDescription")
    T.eq(received[3], "extra1", "builder arg3 == 'extra1'")
    T.eq(received[4], 42,       "builder arg4 == 42")
end)

--------------------------------------------------------------------------------
-- 17. Zero extra args: no nil injection, Foundry side and builder side
--------------------------------------------------------------------------------

test(":CreateContextMenu with no extras: no nil injection on either side", function()
    local F = freshMenu()
    local state = installMenuUtil()
    local owner, rootDesc = {}, makeRootDescription()
    local argCount
    local c = F.Menu:New({
        builder = function(...) argCount = select("#", ...) end,
    })
    -- No extras passed — Foundry must not inject nils into the MenuUtil call.
    c:CreateContextMenu(owner)
    T.eq(#state.createCalls[1].extra, 0, "MenuUtil received 0 extras (no nil injection)")
    -- Simulate Blizzard firing the wrapper with no extras.
    state.lastWrapper(owner, rootDesc)
    T.eq(argCount, 2, "builder received exactly 2 args (no nil injection)")
end)

--------------------------------------------------------------------------------
-- 18. :SetupDropdown calls button:SetupMenu(wrapper)
--------------------------------------------------------------------------------

test(":SetupDropdown calls button:SetupMenu with the wrapper function", function()
    local F = freshMenu()
    installMenuUtil()
    local btn = makeDropdownButton()
    local c   = F.Menu:New(valid())
    c:SetupDropdown(btn)
    T.eq(#btn._setupCalls, 1, "SetupMenu called once")
    T.eq(type(btn._setupCalls[1].wrapper), "function", "wrapper passed to SetupMenu")
end)

--------------------------------------------------------------------------------
-- 19-21. Destroyed controller behavior
--------------------------------------------------------------------------------

test("destroyed controller: :CreateContextMenu raises", function()
    local F = freshMenu()
    installMenuUtil()
    local c = F.Menu:New(valid())
    c:Destroy()
    T.raises(function() c:CreateContextMenu({}) end,
        "CreateContextMenu after destroy",
        "Menu:CreateContextMenu called on a destroyed controller")
end)

test("destroyed controller: :SetupDropdown raises", function()
    local F = freshMenu()
    installMenuUtil()
    local c   = F.Menu:New(valid())
    local btn = makeDropdownButton()
    c:Destroy()
    T.raises(function() c:SetupDropdown(btn) end,
        "SetupDropdown after destroy",
        "Menu:SetupDropdown called on a destroyed controller")
end)

test("destroyed controller: Blizzard firing already-installed wrapper is a no-op", function()
    local F = freshMenu()
    local state = installMenuUtil()
    local owner, rootDesc = {}, makeRootDescription()
    local fired = 0
    local c = F.Menu:New({
        builder = function() fired = fired + 1 end,
    })
    -- Capture the wrapper through a real CreateContextMenu call, then destroy.
    c:CreateContextMenu(owner)
    local wrapper = state.lastWrapper
    c:Destroy()
    -- Simulate Blizzard firing the stale wrapper (the _destroyed check silences it).
    wrapper(owner, rootDesc)
    T.eq(fired, 0, "builder not called after destroy (wrapper is a no-op)")
end)

--------------------------------------------------------------------------------
-- 22. :Destroy idempotent
--------------------------------------------------------------------------------

test(":Destroy is idempotent: second call is a silent no-op", function()
    local F = freshMenu()
    installMenuUtil()
    local c = F.Menu:New(valid())
    c:Destroy()
    local ok, err = pcall(function() c:Destroy() end)
    T.truthy(ok, "second :Destroy does not raise (got: " .. tostring(err) .. ")")
end)

--------------------------------------------------------------------------------
-- 23. liveKeys freed on :Destroy
--------------------------------------------------------------------------------

test(":Destroy frees the live key; same name can be re-registered", function()
    local F = freshMenu()
    installMenuUtil()
    local c1 = F.Menu:New(valid({ name = "Shared" }))
    T.truthy(c1, "first registration")
    c1:Destroy()
    local c2 = F.Menu:New(valid({ name = "Shared" }))
    T.truthy(c2, "re-registration after :Destroy succeeds")
end)

--------------------------------------------------------------------------------
-- 24-27. :GetNativeHandles
--------------------------------------------------------------------------------

test(":GetNativeHandles returns a non-nil table", function()
    local F = freshMenu()
    installMenuUtil()
    local c = F.Menu:New(valid())
    local h = c:GetNativeHandles()
    T.truthy(h, "GetNativeHandles returns non-nil")
    T.eq(type(h), "table", "GetNativeHandles returns a table")
end)

test(":GetNativeHandles h.menuUtil == _G.MenuUtil", function()
    local F = freshMenu()
    installMenuUtil()
    local c = F.Menu:New(valid())
    local h = c:GetNativeHandles()
    T.eq(h.menuUtil, _G.MenuUtil, "h.menuUtil is _G.MenuUtil")
end)

test(":GetNativeHandles returns a fresh table per call; mutation does not corrupt", function()
    local F = freshMenu()
    installMenuUtil()
    local c  = F.Menu:New(valid())
    local h1 = c:GetNativeHandles()
    local h2 = c:GetNativeHandles()
    T.truthy(h1 ~= h2, "distinct table per call")
    -- Mutate h1; h2 must be unaffected.
    local saved = h2.menuUtil
    h1.menuUtil = nil
    T.eq(h2.menuUtil, saved, "mutating h1 does not affect h2")
end)

test(":GetNativeHandles on destroyed controller raises", function()
    local F = freshMenu()
    installMenuUtil()
    local c = F.Menu:New(valid())
    c:Destroy()
    T.raises(function() c:GetNativeHandles() end,
        "GetNativeHandles after destroy",
        "Menu:GetNativeHandles called on a destroyed controller")
end)

--------------------------------------------------------------------------------
-- 28. elementDescription stub self-check
--------------------------------------------------------------------------------

test("stub: elementDescription SetEnabled and SetTooltip spies work correctly", function()
    local ed = makeElementDescription()
    ed:SetEnabled(true)
    local fn = function() end
    ed:SetTooltip(fn)
    T.eq(ed._setEnabledCalls[1], true, "SetEnabled recorded boolean arg")
    T.eq(ed._setTooltipCalls[1], fn,   "SetTooltip recorded function arg")
end)

--------------------------------------------------------------------------------
-- 29. Submenu stub self-check
--------------------------------------------------------------------------------

test("stub: rootDescription CreateButton returns child with own Create* methods", function()
    local rd    = makeRootDescription()
    local child = rd:CreateButton("MyButton", nil)
    T.truthy(child, "CreateButton returned non-nil child")
    T.eq(#rd._createButtonCalls, 1, "CreateButton recorded on root")
    T.eq(type(child.CreateRadio), "function", "child has CreateRadio method")
    child:CreateRadio("MyRadio", function() end, function() end, 1)
    T.eq(#child._createRadioCalls, 1, "CreateRadio recorded on child")
end)

--------------------------------------------------------------------------------
-- 30. Create-once call-many: builder fires on every open, no state leakage
--------------------------------------------------------------------------------

test("create-once call-many: builder fires each time :CreateContextMenu is called", function()
    local F = freshMenu()
    local state = installMenuUtil()
    local owner, rootDesc = {}, makeRootDescription()
    local fired = 0
    local c = F.Menu:New({ builder = function() fired = fired + 1 end })
    -- First open.
    c:CreateContextMenu(owner)
    state.lastWrapper(owner, rootDesc)
    -- Second open.
    c:CreateContextMenu(owner)
    state.lastWrapper(owner, rootDesc)
    T.eq(fired,              2, "builder fired twice")
    T.eq(#state.createCalls, 2, "CreateContextMenu called twice")
end)

--------------------------------------------------------------------------------
-- 31-32. Release-build axis
--------------------------------------------------------------------------------

test("release build: validation error returns nil, does not raise", function()
    local F = freshMenu("1.0.0")
    installMenuUtil()
    local c = F.Menu:New("not a table")
    T.eq(c, nil, "release :New returns nil on bad config")
    T.outputContains("config must be a table", "release printed the diagnostic")
end)

test("release build: feature-detect failure returns nil, does not raise", function()
    local F = freshMenu("1.0.0")
    -- MenuUtil is nil (freshMenu cleared it).
    local c = F.Menu:New(valid())
    T.eq(c, nil, "release :New returns nil when MenuUtil absent")
    T.outputContains("MenuUtil is not available", "release printed the diagnostic")
end)

return tests

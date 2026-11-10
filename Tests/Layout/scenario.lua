-- The scenario shared by the reachability and handover specs: uses every
-- module once, the way a session would, and returns what a test or the client
-- would hold on to. Not a suite of its own.

local T, surfaces = ...

local S = {}

local function makeCanvasFrame()
    return { GetObjectType = function() return "Frame" end }
end

-- Uses every module once and returns what a test or the client would hold.
--   s.inst     the instances built
--   s.holders  the tables the client or the tests keep (walk roots)
--   s.calls    the label of every scenario callback, in the order it ran
function S.run(F)
    local s = { inst = {}, holders = {}, launched = 0, callbacks = {}, calls = {} }

    -- Every callback the scenario hands to the library is a function of its
    -- own, made here and recorded. Two sites sharing one function value would
    -- let the walker count a captured callback as reachable through the other
    -- site's field.
    local function cb(label, body)
        local fn = function(...)
            s.calls[#s.calls + 1] = label
            if body then return body(...) end
            return label
        end
        s.callbacks[#s.callbacks + 1] = { fn = fn, label = label }
        return fn
    end

    -- DB: two stores, one destroyed.
    T.loadedAddons["ScenarioAddon"] = true
    local db1 = F.DB:New({
        name = "ScenarioAddon", sv = "TestDB", defaultProfile = true,
        defaults = { profile = { a = 1 }, global = { g = 1 } },
        schema = { version = 1, key = "global.schemaStamp", migrate = cb("db migrate") },
    })
    local _ = db1.profile
    _ = db1.global
    local db2 = F.DB:New({
        name = "ScenarioAddon", sv = "TestDB2", defaultProfile = true,
        defaults = { global = { x = 1 } },
    })
    _ = db2.global
    db2:Destroy()
    db1:OnSavedVariablesTooLarge(cb("db size warning"))
    s.inst.db = db1

    -- Events: a once handler and a bucket with a pending timer.
    local ev = F.Events:New("ScenarioAddon")
    s.onceCalls = 0
    ev:RegisterOnce("SCENARIO_ONCE", cb("events once", function() s.onceCalls = s.onceCalls + 1 end))
    ev:Register("SCENARIO_PLAIN", cb("events plain"))
    s.inst.bucket = ev:RegisterBucket({ events = "SCENARIO_BUCKET", interval = 5, handler = cb("events bucket") })
    T.Fire(ev._frame, "SCENARIO_BUCKET")
    s.inst.events = ev

    -- Commands, with the restriction notice.
    _G.Enum = {
        AddOnRestrictionType = { Combat = 0, Encounter = 1, ChallengeMode = 2, PvPMatch = 3, Map = 4, Chat = 5 },
        AddOnRestrictionState = { Inactive = 0, Activating = 1, Active = 2 },
    }
    _G.C_RestrictedActions = { IsAddOnRestrictionActive = function() return false end }
    _G.C_EventUtils = { IsEventValid = function() return true end }
    local cmd = F.Commands:New({ name = "Scenario", slashes = { "/scn" }, restrictionNotice = true })
    s.slashRan = 0
    cmd:Register({ name = "go", handler = cb("command go", function() s.slashRan = s.slashRan + 1 end) })
    s.inst.commands = cmd
    -- A second controller guarded by the built-in guard, taken by value.
    s.inst.guarded = F.Commands:New({ name = "ScenarioGuarded", slashes = { "/scg" }, guard = F.Commands.Guards.NotRestricted })

    -- Settings: a canvas page and a launcher; the launcher is destroyed,
    -- created again over the cached page, and clicked.
    local panel = surfaces.installSettingsLauncher()
    s.inst.settingsCanvas = F.Settings:New({ title = "ScenarioCanvas", frame = makeCanvasFrame() })
    local function launcherConfig()
        return { title = "ScenarioLauncher", buttonText = "Open", launch = cb("settings launch", function() s.launched = s.launched + 1 end) }
    end
    local launcher = F.Settings:New(launcherConfig())
    panel.clicks[1]({}, "LeftButton", false)
    launcher:Destroy()
    s.inst.settings = F.Settings:New(launcherConfig())
    panel.clicks[1]({}, "LeftButton", false)
    s.holders[#s.holders + 1] = panel.clicks
    s.panel = panel

    -- Tooltip: two types, and a second handler on the first.
    local processor = surfaces.installTooltipProcessor()
    s.inst.tooltip = F.Tooltip:New({ type = 1, handler = cb("tooltip first") })
    F.Tooltip:New({ type = 1, handler = cb("tooltip second"), name = "second" })
    F.Tooltip:New({ type = 2, handler = cb("tooltip other type") })
    s.holders[#s.holders + 1] = processor.postCalls
    s.processor = processor

    -- Menu: an unnamed controller, installed on a dropdown and opened.
    local menuUtil = surfaces.installMenuUtil()
    local menu = F.Menu:New({ builder = cb("menu builder") })
    local button = surfaces.makeDropdownButton()
    menu:SetupDropdown(button)
    menu:CreateContextMenu({})
    s.inst.menu = menu
    s.holders[#s.holders + 1] = button.setups
    s.holders[#s.holders + 1] = menuUtil.createCalls
    s.button, s.menuUtil = button, menuUtil

    -- Window: one attached frame.
    local win = _G.CreateFrame("Frame", nil, _G.UIParent)
    F.Window:Attach(win, { handle = win, geometry = {}, default = { "CENTER", "CENTER", 0, 0 } })
    s.inst.windowFrame = win

    -- List: a calculator and an initializer, each its own function so neither
    -- is reached through another module's copy of the same value.
    local list = F.List:New({
        name = "ScenarioList", parent = {}, elementType = "Button",
        extentCalculator = cb("list calculator", function() return 20 end), initializer = cb("list initializer"),
    })
    s.inst.list = list
    s.holders[#s.holders + 1] = list:GetNativeHandles().view

    -- Lifecycle: all four hooks and an identity hold that is released, then a
    -- second hold taken and left pending.
    T.SetRegional(true)   -- a region-wide-names client whose surname lags
    local lcA = F.Lifecycle:New(nil, "ScenarioA")
    lcA:OnAddonLoaded(cb("lifecycle A addon loaded"))
    lcA:OnLogin(cb("lifecycle A login"))
    lcA:OnLogout(cb("lifecycle A logout"))
    lcA:OnUnloading(cb("lifecycle A unloading"))
    local dispatcher = surfaces.dispatcherFrame()
    T.Fire(dispatcher, "ADDON_LOADED", "ScenarioA")
    T.Fire(dispatcher, "PLAYER_LOGIN")
    T.Fire(dispatcher, "PLAYER_ENTERING_WORLD")
    T.RunAfters()
    s.releasedBy = F.Lifecycle._identityResolvedBy
    T.identity = { name = "Unknown", realm = T.identity.realm }
    local lcB = F.Lifecycle:New(nil, "ScenarioB")
    lcB:OnAddonLoaded(cb("lifecycle B addon loaded"))
    T.Fire(dispatcher, "ADDON_LOADED", "ScenarioB")
    s.inst.lifecycleReleased = lcA
    s.inst.lifecycle = lcB

    -- Things a test or the client holds on to.
    s.holders[#s.holders + 1] = T.frames
    s.holders[#s.holders + 1] = _G.SlashCmdList
    s.holders[#s.holders + 1] = T.afters
    s.holders[#s.holders + 1] = T.timers
    return s
end

return S

-- A newer copy of the whole library taking over an older one in place, checked
-- over a full session rather than one unit at a time:
--   * after a takeover every table of the library keeps its identity, no older
--     function is reachable outside the slots that keep one by design, and the
--     strict reachability walk finds nothing out of reach;
--   * a session over a takeover does exactly what the same session does over
--     the current files alone;
--   * chains of takeovers (layout-1 copy, then build 2, then build 3), with a
--     unit held back by combat or left out of a trimmed copy;
--   * a takeover loaded from inside a running hook or handler;
--   * every reference from one module to another names a function both copies
--     keep under that name;
--   * the loader behind the takeover run of the whole suite.
-- Every copy is loaded here with T.loadCopy, T.loadOldCopy or T.loadBuild, so
-- the current files alone are never themselves a takeover in takeover mode.

local T = ...

local surfaces = assert(loadfile(T.testsDir .. "/Layout/surfaces.lua"))(T)
local slots = assert(loadfile(T.testsDir .. "/Layout/slots.lua"))(T)
local W = assert(loadfile(T.testsDir .. "/Layout/walker.lua"))(T)
local SN = assert(loadfile(T.testsDir .. "/Layout/snapshot.lua"))(T)

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local DEV = "@project-version@"
local MODULES = { "Commands", "Events", "Lifecycle", "DB", "List", "Settings", "Tooltip", "Menu", "Window" }
local MODULE_OF_FILE = {
    ["Foundry.lua"] = "core",
    ["Modules/Commands.lua"] = "Commands", ["Modules/Events.lua"] = "Events",
    ["Modules/Lifecycle.lua"] = "Lifecycle", ["Modules/DB.lua"] = "DB", ["Modules/List.lua"] = "List",
    ["Modules/Settings.lua"] = "Settings", ["Modules/Tooltip.lua"] = "Tooltip", ["Modules/Menu.lua"] = "Menu",
    ["Modules/Window.lua"] = "Window",
}

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

local function loadCurrent(files)
    return T.loadCopy({ root = T.foundryRoot, files = files or T.FOUNDRY_FILES })
end

local function filesWithout(unit)
    local files = {}
    for _, rel in ipairs(T.FOUNDRY_FILES) do
        if MODULE_OF_FILE[rel] ~= unit then files[#files + 1] = rel end
    end
    return files
end

local function unitTable(F, unit)
    if unit == "core" then return F end
    return F[unit]
end

-- The build each unit serves, by unit; nil for the layout-1 copy.
local function builds(F)
    local out = { core = rawget(F, "_build") }
    for _, name in ipairs(MODULES) do out[name] = rawget(F[name], "_build") end
    return out
end

local function expectBuilds(F, expected, who)
    local got = builds(F)
    for _, unit in ipairs({ "core", unpack(MODULES) }) do
        T.eq(got[unit], expected[unit], who .. unit .. " serves build")
    end
end

local function allAt(build, except)
    local out = { core = build }
    for _, name in ipairs(MODULES) do out[name] = build end
    for unit, value in pairs(except or {}) do out[unit] = value ~= false and value or nil end
    return out
end

local function sourceOf(fn)
    local info = debug.getinfo(fn, "S")
    if info.what == "C" then return nil end
    return (info.source:gsub("\\", "/"))
end

local function unitOfSource(source)
    local rel = source:match("(Modules/[^/]+%.lua)$") or source:match("(Foundry%.lua)$")
    return rel and MODULE_OF_FILE[rel]
end

-- A predicate for the functions a newer copy at `build` replaced: those of the
-- layout-1 copy and of any lower build, limited to the units in `units` (all
-- units when nil), the ones that took over.
local function olderThan(build, units)
    return function(fn)
        if type(fn) ~= "function" then return false end
        local source = sourceOf(fn)
        if not source then return false end
        local older = source:find("/OldCopies/layout1/", 1, true) ~= nil
        local n = tonumber(source:match("/build%-(%d+)/"))
        if n ~= nil and n < build then older = true end
        if not older then return false end
        return units == nil or units[unitOfSource(source)] == true
    end
end

local function isLayout1(fn)
    local source = type(fn) == "function" and sourceOf(fn)
    return source and source:find("/OldCopies/layout1/", 1, true) ~= nil or false
end

local function unitSet(list)
    local set = {}
    for _, unit in ipairs(list) do set[unit] = true end
    return set
end

--------------------------------------------------------------------------------
-- A session up to login, and the rest of it
--------------------------------------------------------------------------------

local function makeCanvasFrame()
    return { GetObjectType = function() return "Frame" end }
end

-- Uses every module the way a session does before login, so that a newer copy
-- may still take over afterwards. Shaped like the handover scenario, without
-- any login event: an identity hold is left pending instead.
local function prepare(F)
    local s = { inst = {}, holders = {}, launched = 0, calls = {} }
    local function cb(label, body)
        return function(...)
            s.calls[#s.calls + 1] = label
            if body then return body(...) end
            return label
        end
    end
    s.cb = cb

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

    -- A leading bucket: its pending flush fires once and does not re-arm.
    local ev = F.Events:New("ScenarioAddon")
    ev:RegisterOnce("SCENARIO_ONCE", cb("events once"))
    ev:Register("SCENARIO_PLAIN", cb("events plain"))
    s.inst.bucket = ev:RegisterBucket({ events = "SCENARIO_BUCKET", interval = 5, handler = cb("events bucket") })
    T.Fire(ev._frame, "SCENARIO_BUCKET")
    s.inst.events = ev

    _G.Enum = {
        AddOnRestrictionType = { Combat = 0, Encounter = 1, ChallengeMode = 2, PvPMatch = 3, Map = 4, Chat = 5 },
        AddOnRestrictionState = { Inactive = 0, Activating = 1, Active = 2 },
    }
    _G.C_RestrictedActions = { IsAddOnRestrictionActive = function() return false end }
    _G.C_EventUtils = { IsEventValid = function() return true end }
    local cmd = F.Commands:New({ name = "Scenario", slashes = { "/scn" }, restrictionNotice = true })
    cmd:Register({ name = "go", handler = cb("command go") })
    s.inst.commands = cmd
    s.inst.guarded = F.Commands:New({ name = "ScenarioGuarded", slashes = { "/scg" }, guard = F.Commands.Guards.NotRestricted })

    local panel = surfaces.installSettingsLauncher()
    s.inst.settingsCanvas = F.Settings:New({ title = "ScenarioCanvas", frame = makeCanvasFrame() })
    local function launcherConfig()
        return { title = "ScenarioLauncher", buttonText = "Open", launch = cb("settings launch") }
    end
    local launcher = F.Settings:New(launcherConfig())
    panel.clicks[1]({}, "LeftButton", false)
    launcher:Destroy()
    s.inst.settings = F.Settings:New(launcherConfig())
    s.panel = panel

    local processor = surfaces.installTooltipProcessor()
    s.inst.tooltip = F.Tooltip:New({ type = 1, handler = cb("tooltip first") })
    F.Tooltip:New({ type = 1, handler = cb("tooltip second"), name = "second" })
    F.Tooltip:New({ type = 2, handler = cb("tooltip other type") })
    s.processor = processor

    local menuUtil = surfaces.installMenuUtil()
    local menu = F.Menu:New({ builder = cb("menu builder") })
    local button = surfaces.makeDropdownButton()
    menu:SetupDropdown(button)
    menu:CreateContextMenu({})
    s.inst.menu = menu
    s.button, s.menuUtil = button, menuUtil

    local win = _G.CreateFrame("Frame", nil, _G.UIParent)
    s.windowGeometry = {}
    F.Window:Attach(win, { handle = win, geometry = s.windowGeometry, default = { "CENTER", "CENTER", 0, 0 } })
    s.inst.windowFrame = win

    local list = F.List:New({
        name = "ScenarioList", parent = {}, elementType = "Button",
        extentCalculator = cb("list calculator", function() return 20 end), initializer = cb("list initializer"),
    })
    s.inst.list = list

    -- Lifecycle: one controller with all four hooks, its addon loaded; a
    -- second held until the player's name is known.
    local lcA = F.Lifecycle:New(nil, "ScenarioA")
    lcA:OnAddonLoaded(cb("lifecycle A addon loaded"))
    lcA:OnLogin(cb("lifecycle A login"))
    lcA:OnLogout(cb("lifecycle A logout"))
    lcA:OnUnloading(cb("lifecycle A unloading"))
    T.Fire(F.Lifecycle._state.dispatcher, "ADDON_LOADED", "ScenarioA")
    T.identity.name = nil
    T.loadedAddons["ScenarioB"] = true
    local lcB = F.Lifecycle:New(nil, "ScenarioB")
    lcB:OnAddonLoaded(cb("lifecycle B addon loaded"))
    s.inst.lifecycleA, s.inst.lifecycleB = lcA, lcB

    s.holders = {
        panel.clicks, processor.postCalls, button.setups, menuUtil.createCalls,
        list:GetNativeHandles().view, T.frames, _G.SlashCmdList, T.afters, T.timers,
    }
    return s
end

-- A table as text, keys sorted, so two runs compare line for line.
local function describe(value)
    if type(value) == "string" then return string.format("%q", value) end
    if type(value) ~= "table" then return tostring(value) end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return describe(a) < describe(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = "[" .. describe(k) .. "]=" .. describe(value[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- What each mock frame was asked to register, in order, without the script
-- functions themselves (those differ between copies by design).
local function frameRegistrations()
    local lines = {}
    for i, frame in ipairs(T.frames) do
        local parts = { tostring(frame._kind) }
        for _, method in ipairs({ "RegisterEvent", "RegisterUnitEvent", "UnregisterEvent", "UnregisterAllEvents" }) do
            parts[#parts + 1] = method .. describe(frame.calls[method])
        end
        local scripts = {}
        for _, call in ipairs(frame.calls.SetScript) do scripts[#scripts + 1] = call[1] .. "=" .. type(call[2]) end
        parts[#parts + 1] = "SetScript" .. table.concat(scripts, ",")
        lines[#lines + 1] = "frame " .. i .. " " .. table.concat(parts, " ")
    end
    return lines
end

-- The rest of the session: login, every instance driven once, objects made
-- now used too, then logout. Returns what happened, as lines.
local function exercise(F, s)
    local firstCall, firstOutput = #s.calls + 1, #T.output + 1
    local dispatcher = F.Lifecycle._state.dispatcher
    T.identity.name = "Tester"
    T.Fire(dispatcher, "UNIT_NAME_UPDATE", "player")
    T.Fire(dispatcher, "PLAYER_LOGIN")
    T.Fire(dispatcher, "PLAYER_ENTERING_WORLD")
    T.RunAfters()

    local ev = s.inst.events
    T.Fire(ev._frame, "SCENARIO_ONCE")
    T.Fire(ev._frame, "SCENARIO_ONCE")
    T.Fire(ev._frame, "SCENARIO_PLAIN")
    T.Fire(ev._frame, "SCENARIO_BUCKET")
    T.now = 10
    for _, handle in ipairs(slots.pendingTimers()) do T.FireTimer(handle) end
    _G.SlashCmdList.SCENARIO("go")
    _G.SlashCmdList.SCENARIOGUARDED("")
    T.Fire(s.inst.commands._restrictionEvents._frame, "ADDON_RESTRICTION_STATE_CHANGED",
        _G.Enum.AddOnRestrictionType.Combat, _G.Enum.AddOnRestrictionState.Activating)
    for _, entry in ipairs(s.processor.postCalls) do entry.fn(surfaces.makeTooltip(), {}) end
    s.menuUtil.createCalls[1].generator({}, surfaces.makeRootDescription())
    s.button.setups[1]({}, surfaces.makeRootDescription())
    local view = s.inst.list:GetNativeHandles().view
    view._calc(1, {})
    view._initializer({}, {})
    local win = s.inst.windowFrame
    win._scripts.OnDragStart(win)
    win:SetPoint("TOPLEFT", _G.UIParent, "TOPLEFT", 12, -34)
    win._scripts.OnDragStop(win)
    s.panel.clicks[#s.panel.clicks]({}, "LeftButton", false)
    local ok, sizeErr = pcall(T.Fire, F.DB._state.sizeWarningEvents._frame, "SAVED_VARIABLES_TOO_LARGE", "ScenarioAddon")
    T.falsy(ok, "the size warning raises in a dev build")

    -- Made after the takeover, by whichever copy serves now.
    local later = F.Events:New("ScenarioLater")
    later:Register("SCENARIO_LATER", s.cb("later events plain"))
    T.Fire(later._frame, "SCENARIO_LATER")
    local laterCmd = F.Commands:New({ name = "ScenarioLater", slashes = { "/scl" } })
    laterCmd:Register({ name = "go", handler = s.cb("later command go") })
    _G.SlashCmdList.SCENARIOLATER("go")
    s.inst.db.profile.a = 7
    s.inst.db.char.c = 3
    T.Fire(dispatcher, "PLAYER_LOGOUT")

    local lines = { "raised " .. surfaces.normalise(sizeErr) }
    for i = firstCall, #s.calls do lines[#lines + 1] = "call " .. s.calls[i] end
    for i = firstOutput, #T.output do lines[#lines + 1] = "print " .. T.output[i] end
    lines[#lines + 1] = "geometry " .. describe(s.windowGeometry)
    lines[#lines + 1] = "saved TestDB " .. describe(_G.TestDB)
    lines[#lines + 1] = "saved TestDB2 " .. describe(_G.TestDB2)
    for _, line in ipairs(frameRegistrations()) do lines[#lines + 1] = line end
    return lines
end

local function countOf(lines, line)
    local n = 0
    for _, l in ipairs(lines) do if l == line then n = n + 1 end end
    return n
end

--------------------------------------------------------------------------------
-- The invariants after a takeover
--------------------------------------------------------------------------------

-- Tables the library replaces by design during a session (as in the handover
-- spec): they may differ from the ones a fresh load made.
local REPLACED_BY_DESIGN = {
    ["Lifecycle._state.identityHeld"] = "replaced on every release",
    ["Lifecycle._state.dispatcher"] = "set once, on first use",
    ["DB._state.sizeWarningEvents"] = "set once, on first use",
}

-- path -> table, for the library table, each module table, their _state and
-- _impl tables, and every table value in those.
local function layoutTables(F)
    local out = {}
    local function part(label, t)
        out[label] = t
        for k, v in pairs(t) do
            if type(v) == "table" then out[label .. "." .. tostring(k)] = v end
        end
    end
    out["the library table"] = F
    part("the library table._state", F._state)
    for name, M in pairs(F._state.modules) do
        part(name, M)
        part(name .. "._state", M._state)
        part(name .. "._impl", M._impl)
    end
    return out
end

local function identityChanges(before, after, allowed)
    local paths, changed = {}, {}
    for path in pairs(before) do paths[path] = true end
    for path in pairs(after) do paths[path] = true end
    for path in pairs(paths) do
        if not rawequal(before[path], after[path]) and not (allowed and allowed[path]) then
            changed[#changed + 1] = path
        end
    end
    table.sort(changed)
    return changed
end

local function strictWalk(F, s)
    return W.walk({
        F = F, roots = s.holders,
        constants = W.isConstant, functions = W.isAllowedFunction, skipKeys = W.SKIP_KEYS,
    })
end

-- Everything wrong with a library a newer copy has just taken over, as lines:
-- a layout table replaced since `before`, an older function outside the slots
-- recorded before the takeover, an entry the strict walk finds out of reach.
local function problemsAfterTakeover(F, s, before, records, isOlder)
    local problems = {}
    for _, path in ipairs(identityChanges(before, layoutTables(F))) do
        problems[#problems + 1] = "table replaced: " .. path
    end
    for _, line in ipairs(slots.oldFunctionsOutsideSlots(F, s, isOlder, nil, { takeover = records })) do
        problems[#problems + 1] = "older function " .. line
    end
    local walked = strictWalk(F, s)
    for _, key in ipairs(walked.order) do
        problems[#problems + 1] = "out of reach: " .. key .. " (" .. walked.trapped[key].why .. ")"
    end
    return problems
end

local function expectNoProblems(problems, who)
    T.eq(#problems, 0, who .. "problems after the takeover:\n    " .. table.concat(problems, "\n    "))
end

-- Every kind of slot the allowance names, other than the identity poll, which
-- is never pending before login.
local SLOT_KINDS = {
    "an events controller's frame script", "a pending bucket timer", "the /foundry command",
    "the Lifecycle dispatcher's script", "the DB logout entry", "a slash entry",
    "a list row initializer", "a list row extent", "a tooltip post-call", "a settings launcher click",
    "a menu generator", "a window drag script",
}

-- The layout-1 copy with the session up to login. Returns the library, the
-- scenario, its layout tables from the fresh load and from just now, and the
-- slots recorded for the takeover to come.
local function preparedOverLayout1()
    T.installMocks(DEV)
    local F = T.loadOldCopy("layout1")
    local fresh = layoutTables(F)
    local s = prepare(F)
    return F, s, fresh, layoutTables(F), slots.takeoverSlots(F, s)
end

test("before a takeover the scenario fills every kind of slot the allowance names, and the walk finds older functions", function()
    local F, s, _, _, records = preparedOverLayout1()
    local kinds = {}
    for _, record in ipairs(records) do
        kinds[record.what] = true
        T.truthy(isLayout1(record.value), record.what .. " holds a layout-1 function")
    end
    for _, kind in ipairs(SLOT_KINDS) do T.truthy(kinds[kind], "a slot of kind '" .. kind .. "' was recorded") end
    T.truthy(#slots.oldFunctionsOutsideSlots(F, s, isLayout1, nil, { takeover = {} }) > 50,
        "with no slots allowed, the walk reports the layout-1 copy's functions")
end)

test("a whole newer copy over the layout-1 copy keeps every library table, leaves older functions only in the recorded slots, and leaves nothing out of reach", function()
    local F, s, fresh, before, records = preparedOverLayout1()
    loadCurrent()
    expectBuilds(F, allAt(T.libraryBuild()), "")
    expectNoProblems(problemsAfterTakeover(F, s, before, records, olderThan(math.huge)), "")
    exercise(F, s)
    local changed = identityChanges(fresh, layoutTables(F), REPLACED_BY_DESIGN)
    T.eq(#changed, 0, "tables replaced over the session, other than by design: " .. table.concat(changed, ", "))
    local walked = strictWalk(F, s)
    T.eq(#walked.order, 0, "out of reach after the session: " .. table.concat(walked.order, ", "))
end)

test("every relay left in a slot by the layout-1 copy calls the newer implementation function once", function()
    local F, s, _, _, records = preparedOverLayout1()
    loadCurrent()
    local dispatcher = F.Lifecycle._state.dispatcher
    local calls = {
        ["the Lifecycle dispatcher's script"] = function(fn) fn(dispatcher, "ADDON_LOADED", "Nothing") end,
        ["the DB logout entry"] = function(fn) fn() end,
        ["a slash entry"] = function(fn) fn("") end,
        ["a list row initializer"] = function(fn) fn({}, {}) end,
        ["a list row extent"] = function(fn) T.eq(fn(1, {}), 20, "the extent") end,
        ["a tooltip post-call"] = function(fn) fn(surfaces.makeTooltip(), {}) end,
        ["a settings launcher click"] = function(fn) fn({}, "LeftButton", false) end,
        ["a menu generator"] = function(fn) fn({}, surfaces.makeRootDescription()) end,
        ["a window drag script"] = function(fn) fn(s.inst.windowFrame) end,
    }
    local relays = 0
    for _, record in ipairs(records) do
        if record.unit then
            relays = relays + 1
            local who = record.what .. " (" .. record.target .. "): "
            local holder = F[record.unit]._impl
            local path = {}
            for key in record.target:gmatch("[^%.]+") do path[#path + 1] = key end
            for i = 1, #path - 1 do holder = holder[path[i]] end
            local target = path[#path]
            T.falsy(olderThan(math.huge)(holder[target]), who .. "the target is the newer copy's")
            local call = assert(calls[record.what], "a call for " .. record.what)
            T.eq(slots.countCalls(holder, target, function() call(record.value) end), 1, who .. "calls")
        end
    end
    T.truthy(relays >= 10, "relays were called: " .. relays)
end)

test("the takeover allowance reports an older function placed on a frame made after the takeover, or in a field that is no slot", function()
    local placements = {
        { "an events controller made after the takeover", function(F, older)
            local c = F.Events:New("MadeAfter")
            c._frame._scripts.OnEvent = older
        end },
        { "a window attached after the takeover", function(F, older)
            local win = _G.CreateFrame("Frame", nil, _G.UIParent)
            F.Window:Attach(win, { handle = win, geometry = {}, default = { "CENTER", "CENTER", 0, 0 } })
            win._scripts.OnDragStop = older
        end },
        { "a slash entry registered after the takeover", function(F, older)
            F.Commands:New({ name = "MadeAfter", slashes = { "/mda" } })
            _G.SlashCmdList.MADEAFTER = older
        end },
        { "a bucket timer started after the takeover", function(F, older)
            local c = F.Events:New("MadeAfterBucket")
            c:RegisterBucket({ events = "MADE_AFTER", interval = 5, handler = function() end })
            T.Fire(c._frame, "MADE_AFTER")
            local pending = slots.pendingTimers()
            pending[#pending]._callback = older
        end },
        { "a field of a module's state", function(F, older) F.Menu._state.stray = older end },
    }
    for _, placement in ipairs(placements) do
        local F, s, _, before, records = preparedOverLayout1()
        loadCurrent()
        local older = s.inst.events._frame._scripts.OnEvent
        T.truthy(isLayout1(older), placement[1] .. ": the planted function is the layout-1 copy's")
        placement[2](F, older)
        local problems = problemsAfterTakeover(F, s, before, records, olderThan(math.huge))
        T.truthy(#problems > 0, placement[1] .. ": the planted function is reported")
    end
end)

--------------------------------------------------------------------------------
-- Session equivalence
--------------------------------------------------------------------------------

-- The scripted session over the current files alone, or over a takeover of the
-- layout-1 copy made between the part before login and the rest.
local function session(overTakeover)
    T.installMocks(DEV)
    local F
    if overTakeover then
        F = T.loadOldCopy("layout1")
    else
        F = loadCurrent()
    end
    local s = prepare(F)
    if overTakeover then
        loadCurrent()
        expectBuilds(F, allAt(T.libraryBuild()), "the takeover: ")
    end
    return exercise(F, s)
end

test("a session with a takeover before login does exactly what the same session does over the current files alone", function()
    local alone = session(false)
    local over = session(true)
    for i = 1, math.max(#alone, #over) do
        T.eq(over[i], alone[i], "line " .. i)
    end
    for _, label in ipairs({
        "events once", "events plain", "events bucket", "command go", "tooltip first", "tooltip second",
        "tooltip other type", "menu builder", "list calculator", "list initializer", "settings launch",
        "db size warning", "lifecycle B addon loaded", "lifecycle A login", "lifecycle A logout",
        "later events plain", "later command go",
    }) do
        T.truthy(countOf(over, "call " .. label) > 0, "'" .. label .. "' ran in the session")
    end
    T.eq(countOf(over, "call events once"), 1, "the once handler ran once")
    T.eq(countOf(over, "call events bucket"), 1, "the bucket handler ran once")
    T.truthy(#over > 20, "the session produced its lines")
end)

--------------------------------------------------------------------------------
-- Chains
--------------------------------------------------------------------------------

-- Objects made by the copy serving after the first takeover, so the second
-- takeover has some of its own to carry: an anonymous menu, a tooltip type, a
-- settings page, an events bucket.
local function prepareMore(F, s)
    s.inst.menu2 = F.Menu:New({ builder = s.cb("second menu builder") })
    s.inst.menu2:CreateContextMenu({})
    F.Tooltip:New({ type = 3, handler = s.cb("tooltip third type") })
    F.Settings:New({ title = "ScenarioSecondCanvas", frame = makeCanvasFrame() })
    local ev = F.Events:New("ScenarioMore")
    ev:RegisterBucket({ events = "SCENARIO_MORE", interval = 5, handler = s.cb("second bucket") })
    T.Fire(ev._frame, "SCENARIO_MORE")
end

test("a chain of takeovers, layout-1 copy then build 2 then build 3, holds the invariants after each and keeps the first takeover's tables and counters", function()
    local F, s, fresh, before, records = preparedOverLayout1()
    T.loadBuild({ build = 2 })
    expectBuilds(F, allAt(2), "after build 2: ")
    expectNoProblems(problemsAfterTakeover(F, s, before, records, olderThan(2)), "after build 2: ")

    prepareMore(F, s)
    local menuState, tooltipState, settingsState = F.Menu._state, F.Tooltip._state, F.Settings._state
    local anon, dispatchers, categories = menuState.anonCounter, tooltipState.dispatchers, settingsState.registeredCategories
    local dispatcherTypes, categoryNames = describe(dispatchers), {}
    for name in pairs(categories) do categoryNames[#categoryNames + 1] = name end
    table.sort(categoryNames)
    T.truthy(anon >= 2, "the anonymous menu counter counted both menus")
    T.truthy(dispatchers[3] ~= nil, "build 2 made a dispatcher for a new type")

    local beforeC, recordsC = layoutTables(F), slots.takeoverSlots(F, s)
    T.loadBuild({ build = 3 })
    expectBuilds(F, allAt(3), "after build 3: ")
    expectNoProblems(problemsAfterTakeover(F, s, beforeC, recordsC, olderThan(3)), "after build 3: ")
    T.eq(menuState.anonCounter, anon, "the anonymous menu counter is kept")
    T.truthy(rawequal(tooltipState.dispatchers, dispatchers), "the tooltip dispatchers table is kept")
    T.eq(describe(dispatchers), dispatcherTypes, "and holds the same dispatchers")
    T.truthy(rawequal(settingsState.registeredCategories, categories), "the registered categories table is kept")
    local after = {}
    for name in pairs(categories) do after[#after + 1] = name end
    table.sort(after)
    T.eq(table.concat(after, ","), table.concat(categoryNames, ","), "and holds the same categories")
    local menu3 = F.Menu:New({ builder = function() end })
    T.eq(menuState.anonCounter, anon + 1, "the next anonymous menu continues the count")
    T.truthy(menu3 ~= nil, "a menu is made after the second takeover")

    local lines = exercise(F, s)
    for _, label in ipairs({ "second bucket", "tooltip third type", "events bucket", "lifecycle A logout" }) do
        T.truthy(countOf(lines, "call " .. label) > 0, "'" .. label .. "' ran after the second takeover")
    end
    local changed = identityChanges(fresh, layoutTables(F), REPLACED_BY_DESIGN)
    T.eq(#changed, 0, "tables replaced over the chain, other than by design: " .. table.concat(changed, ", "))
end)

test("after build 2 has taken over, a copy at build 2 or build 1 changes nothing but the record of copies", function()
    for _, build in ipairs({ 2, 1 }) do
        local F, s = preparedOverLayout1()
        T.loadBuild({ build = 2 })
        prepareMore(F, s)
        local before = SN.take(F)
        T.loadBuild({ build = build })
        local changes = SN.diff(before, SN.take(F), { copies = 1 })
        T.eq(#changes, 0, "build " .. build .. ": changes:\n    " .. table.concat(changes, "\n    "))
        expectBuilds(F, allAt(2), "build " .. build .. ": ")
        T.eq(F._state.copies[#F._state.copies].outcome, "not used", "build " .. build .. ": the core records it as not used")
    end
end)

test("a chain where combat starts before build 2's DB file leaves DB and the later modules on the layout-1 copy, and build 3 then takes DB from it and the rest from build 2", function()
    local F, s, _, before, records = preparedOverLayout1()
    local early = { "Foundry.lua", "Modules/Commands.lua", "Modules/Events.lua", "Modules/Lifecycle.lua" }
    local late = { "Modules/DB.lua", "Modules/List.lua", "Modules/Settings.lua", "Modules/Tooltip.lua",
        "Modules/Menu.lua", "Modules/Window.lua" }
    T.loadBuild({ build = 2, files = early })
    T.inCombat = true
    T.loadBuild({ build = 2, files = late })
    T.inCombat = false
    expectBuilds(F, allAt(2, { DB = false, List = false, Settings = false, Tooltip = false, Menu = false, Window = false }),
        "after build 2: ")
    T.truthy(isLayout1(F.DB._impl.onLogout), "DB is still the layout-1 copy's")
    expectNoProblems(problemsAfterTakeover(F, s, before, records,
        olderThan(2, unitSet({ "core", "Commands", "Events", "Lifecycle" }))), "after build 2: ")

    local beforeC, recordsC = layoutTables(F), slots.takeoverSlots(F, s)
    T.loadBuild({ build = 3 })
    expectBuilds(F, allAt(3), "after build 3: ")
    expectNoProblems(problemsAfterTakeover(F, s, beforeC, recordsC, olderThan(3)), "after build 3: ")
    local lines = exercise(F, s)
    T.truthy(countOf(lines, "call db size warning") == 1, "the size warning reaches the consumer once")
    T.eq(_G.TestDB.profiles.Default.a, 7, "the changed profile value is saved")
    T.eq(_G.TestDB.global.g, nil, "the default-equal global value is stripped")
end)

test("a chain where build 2 is trimmed without Window leaves Window on the layout-1 copy, and build 3 then takes it over", function()
    local F, s, _, before, records = preparedOverLayout1()
    T.loadBuild({ build = 2, files = filesWithout("Window") })
    expectBuilds(F, allAt(2, { Window = false }), "after build 2: ")
    local tookOver = unitSet({ "core", "Commands", "Events", "Lifecycle", "DB", "List", "Settings", "Tooltip", "Menu" })
    expectNoProblems(problemsAfterTakeover(F, s, before, records, olderThan(2, tookOver)), "after build 2: ")

    local beforeC, recordsC = layoutTables(F), slots.takeoverSlots(F, s)
    T.loadBuild({ build = 3 })
    expectBuilds(F, allAt(3), "after build 3: ")
    expectNoProblems(problemsAfterTakeover(F, s, beforeC, recordsC, olderThan(3)), "after build 3: ")
    local lines = exercise(F, s)
    T.truthy(lines ~= nil and s.windowGeometry.point == "TOPLEFT", "the window made by the layout-1 copy saves its position")
end)

--------------------------------------------------------------------------------
-- A takeover loaded from inside a running hook or handler
--------------------------------------------------------------------------------

-- Each case builds on the layout-1 copy before login, then starts something
-- whose callback loads the current files. run returns how often that callback
-- ran; next performs the following dispatch and returns how often the newer
-- implementation function was called by it.
local NESTED = {
    {
        name = "an addon-loaded hook",
        setup = function(F, nested)
            local lc = F.Lifecycle:New(nil, "NestedAddon")
            local runs = 0
            lc:OnAddonLoaded(function() runs = runs + 1; nested() end)
            local nextRuns = 0
            F.Lifecycle:New(nil, "NestedNext"):OnAddonLoaded(function() nextRuns = nextRuns + 1 end)
            local dispatcher = F.Lifecycle._state.dispatcher
            return {
                run = function()
                    T.Fire(dispatcher, "ADDON_LOADED", "NestedAddon")
                    T.Fire(dispatcher, "ADDON_LOADED", "NestedAddon")
                    return runs
                end,
                next = function()
                    local n = slots.countCalls(F.Lifecycle._impl, "onEvent", function()
                        T.Fire(dispatcher, "ADDON_LOADED", "NestedNext")
                    end)
                    T.eq(nextRuns, 1, "the next hook ran once")
                    return n, F.Lifecycle._impl.onEvent
                end,
            }
        end,
    },
    {
        name = "an events handler",
        setup = function(F, nested)
            local ev = F.Events:New("Nested")
            local runs = 0
            ev:Register("NESTED_LOAD", function() runs = runs + 1; nested() end)
            local nextRuns = 0
            ev:RegisterOnce("NESTED_NEXT", function() nextRuns = nextRuns + 1 end)
            return {
                run = function()
                    T.Fire(ev._frame, "NESTED_LOAD")
                    return runs
                end,
                next = function()
                    local handler = ev._handlers.NESTED_NEXT
                    T.Fire(ev._frame, "NESTED_NEXT")
                    T.Fire(ev._frame, "NESTED_NEXT")
                    T.eq(nextRuns, 1, "the next once handler ran once")
                    return 1, handler
                end,
            }
        end,
    },
    {
        name = "a slash subcommand",
        setup = function(F, nested)
            local cmd = F.Commands:New({ name = "Nested", slashes = { "/nst" } })
            local runs, nextRuns = 0, 0
            cmd:Register({ name = "load", handler = function() runs = runs + 1; nested() end })
            cmd:Register({ name = "next", handler = function() nextRuns = nextRuns + 1 end })
            return {
                run = function()
                    _G.SlashCmdList.NESTED("load")
                    return runs
                end,
                next = function()
                    local n = slots.countCalls(F.Commands._impl.Controller, "Dispatch", function()
                        _G.SlashCmdList.NESTED("next")
                    end)
                    T.eq(nextRuns, 1, "the next subcommand ran once")
                    return n, F.Commands._impl.Controller.Dispatch
                end,
            }
        end,
    },
    {
        name = "a saved-data migration",
        setup = function(F, nested)
            T.loadedAddons["NestedDB"] = true
            _G.TestDB = { global = { version = 1 } }
            local runs, db = 0, nil
            return {
                run = function()
                    db = F.DB:New({
                        name = "NestedDB", sv = "TestDB", defaultProfile = true,
                        defaults = { global = { d = 1 } },
                        schema = { version = 2, key = "global.version", migrate = function()
                            runs = runs + 1
                            nested()
                        end },
                    })
                    T.eq(db.global.version, 2, "the db made around the takeover is stamped")
                    T.eq(db.global.d, 1, "and has its defaults")
                    return runs
                end,
                next = function()
                    local n = slots.countCalls(F.DB, "New", function()
                        local db2 = F.DB:New({ name = "NestedDB", sv = "TestDB2", defaultProfile = true })
                        T.truthy(db2 ~= nil, "the next db is made")
                    end)
                    return n, F.DB.New
                end,
            }
        end,
    },
}

for _, case in ipairs(NESTED) do
    test("a takeover loaded from inside " .. case.name .. " before login runs it once, lets it finish, and the next dispatch runs the newer code", function()
        T.installMocks(DEV)
        local F = T.loadOldCopy("layout1")
        local loads = 0
        local steps = case.setup(F, function()
            loads = loads + 1
            loadCurrent()
        end)
        local ok, runs = pcall(steps.run)
        T.truthy(ok, "the in-flight dispatch finishes without error: " .. tostring(runs))
        T.eq(runs, 1, "it ran once")
        T.eq(loads, 1, "the newer copy loaded once")
        expectBuilds(F, allAt(T.libraryBuild()), "")
        local calls, fn = steps.next()
        T.eq(calls, 1, "the next dispatch calls the newer code once")
        T.falsy(isLayout1(fn), "the code the next dispatch runs is the newer copy's")
        T.eq(#T.output, 0, "nothing is printed")
    end)
end

--------------------------------------------------------------------------------
-- References from one module to another
--------------------------------------------------------------------------------

-- Every name one module reaches on another, which both an older and a newer
-- copy must keep: the core methods, module functions, and the methods and the
-- handler table of an events controller another module holds.
--   kind "core"       a method on the library table
--   kind "module"     a function on another module's table
--   kind "controller" a member of an events controller, with its type
local FROZEN_CROSS_UNIT = {
    { kind = "core", name = "RaiseDevError" },
    { kind = "core", name = "HasModule" },
    { kind = "core", name = "RegisterModule" },
    { kind = "module", unit = "Events", name = "New" },
    { kind = "module", unit = "Lifecycle", name = "_PlayerIdentity" },
    { kind = "module", unit = "Lifecycle", name = "_RegisterPostLogout" },
    { kind = "controller", name = "Register", type = "function" },
    { kind = "controller", name = "Destroy", type = "function" },
    { kind = "controller", name = "_handlers", type = "table" },
}

-- Source lines without comments.
local function codeLines(rel)
    local handle = assert(io.open(T.foundryRoot .. "/" .. rel, "rb"))
    local text = handle:read("*a")
    handle:close()
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = (line:gsub("\r$", ""):gsub("%-%-.*$", ""))
    end
    return lines
end

-- Every cross-unit reference in the module files, as "kind:unit:name" -> the
-- first file:line it was seen at. Receivers of events controllers are found
-- from the files: the target of each `= F.Events:New(` and any field that
-- target is stored into; aliases are the locals given `F.<Other>`.
local function crossUnitReferences()
    local refs, receivers = {}, {}
    local function add(key, where) refs[key] = refs[key] or where end
    for _, rel in ipairs(T.FOUNDRY_FILES) do
        local own = MODULE_OF_FILE[rel]
        if own ~= "core" then
            local lines = codeLines(rel)
            local aliases = {}
            for _, line in ipairs(lines) do
                local names, values = line:match("^%s*local%s+([%w_,%s]+)=%s*(F%.%u[%w_]*[%w_%.,%sF]*)$")
                if names then
                    local nameList, valueList = {}, {}
                    for n in names:gmatch("[%a_][%w_]*") do nameList[#nameList + 1] = n end
                    for v in values:gmatch("F%.(%u[%w_]*)") do valueList[#valueList + 1] = v end
                    for i, n in ipairs(nameList) do
                        if valueList[i] and valueList[i] ~= own then aliases[n] = valueList[i] end
                    end
                end
                local target = line:match("([%w_%.]+)%s*=%s*F%.Events:New%(")
                if target and own ~= "Events" then
                    receivers[(target:match("([%w_]+)$"))] = rel
                end
            end
            for _, line in ipairs(lines) do
                for field, source in line:gmatch("[%w_]+%.([%w_]+)%s*=%s*([%w_]+)%s*$") do
                    if receivers[source] then receivers[field] = rel end
                end
            end
            for i, line in ipairs(lines) do
                local where, padded = rel .. ":" .. i, " " .. line
                for other, name in padded:gmatch("[^%w_%.]F%.(%u[%w_]*)[%.:]([%a_][%w_]*)") do
                    if other ~= own then add("module:" .. other .. ":" .. name, where) end
                end
                for alias, other in pairs(aliases) do
                    for name in padded:gmatch("[^%w_%.]" .. alias .. "[%.:]([%a_][%w_]*)") do
                        add("module:" .. other .. ":" .. name, where)
                    end
                end
                for name in padded:gmatch("[^%w_%.]F:([%a_][%w_]*)%(") do add("core::" .. name, where) end
            end
        end
    end
    -- Members used on a receiver, in the files that hold one.
    local used = {}
    for _, rel in ipairs(T.FOUNDRY_FILES) do
        if MODULE_OF_FILE[rel] ~= "core" and MODULE_OF_FILE[rel] ~= "Events" then
            for i, line in ipairs(codeLines(rel)) do
                for receiver in pairs(receivers) do
                    for name in (" " .. line):gmatch("[^%w_]" .. receiver .. "[%.:]([%a_][%w_]*)") do
                        add("controller::" .. name, rel .. ":" .. i)
                        used[receiver] = true
                    end
                end
            end
        end
    end
    return refs, receivers, used
end

local function frozenKey(entry)
    return entry.kind .. ":" .. (entry.unit or "") .. ":" .. entry.name
end

test("every reference from one module to another names a frozen function", function()
    local refs, receivers, used = crossUnitReferences()
    local frozen = {}
    for _, entry in ipairs(FROZEN_CROSS_UNIT) do frozen[frozenKey(entry)] = true end
    local missing = {}
    for key, where in pairs(refs) do
        if not frozen[key] then missing[#missing + 1] = key .. " at " .. where end
    end
    table.sort(missing)
    T.eq(#missing, 0, "references to names not in the frozen list:\n    " .. table.concat(missing, "\n    "))
    for _, receiver in ipairs({ "sizeWarningEvents", "eventController", "_restrictionEvents" }) do
        T.truthy(receivers[receiver], "the scan found the events controller held as '" .. receiver .. "'")
        T.truthy(used[receiver], "the scan found a member used on '" .. receiver .. "'")
    end
    for _, key in ipairs({ "module:Lifecycle:_PlayerIdentity", "module:Events:New", "core::RaiseDevError",
        "controller::Register", "controller::_handlers" }) do
        T.truthy(refs[key], "the scan found " .. key)
    end
end)

test("every frozen cross-module name exists in the layout-1 copy and in the current code", function()
    local copies = {
        { "the layout-1 copy", function() return T.loadOldCopy("layout1") end },
        { "the current code", loadCurrent },
    }
    for _, copy in ipairs(copies) do
        T.installMocks(DEV)
        local F = copy[2]()
        local controller = F.Events:New("FrozenNames")
        for _, entry in ipairs(FROZEN_CROSS_UNIT) do
            local who = copy[1] .. ": " .. frozenKey(entry)
            if entry.kind == "core" then
                T.eq(type(F[entry.name]), "function", who)
            elseif entry.kind == "module" then
                T.eq(type(unitTable(F, entry.unit)[entry.name]), "function", who)
            else
                T.eq(type(controller[entry.name]), entry.type, who)
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- The loader behind the takeover run of the suite
--------------------------------------------------------------------------------

-- Runs fn with the loader in takeover mode (and not rehearsing), counting into
-- a fresh tally; restores the run's own mode and tally. Returns the tally.
local function inTakeoverMode(fn)
    local mode, rehearse, counts = T.TAKEOVER, T.REHEARSE, T.loadCounts
    T.TAKEOVER, T.REHEARSE, T.loadCounts = true, false, { takeovers = 0, plain = 0 }
    local ok, err = pcall(fn)
    local tally = T.loadCounts
    T.TAKEOVER, T.REHEARSE, T.loadCounts = mode, rehearse, counts
    if not ok then error(err, 0) end
    return tally
end

local function anyLayout1Code(F)
    if isLayout1(F.RegisterModule) then return "the core" end
    for _, name in ipairs(MODULES) do
        for _, value in pairs(F[name]._impl) do
            if isLayout1(value) then return name end
        end
    end
    return nil
end

test("in takeover mode the loader takes over the layout-1 copy when nothing serves and the player is neither logged in nor in combat", function()
    local F
    local tally = inTakeoverMode(function()
        T.installMocks(DEV)
        F = T.loadFoundry()
    end)
    T.eq(tally.takeovers, 1, "takeovers counted")
    T.eq(tally.plain, 0, "plain loads counted")
    expectBuilds(F, allAt(T.libraryBuild()), "")
    T.eq(anyLayout1Code(F), nil, "a unit serving layout-1 code")
    T.truthy(isLayout1(_G.SlashCmdList.FOUNDRY), "the /foundry command is the layout-1 copy's")
    local tookOver = 0
    for _, entry in ipairs(F._state.copies) do
        if entry.outcome == "took over" then tookOver = tookOver + 1 end
    end
    T.eq(tookOver, 1, "the core records one took over entry")
end)

test("in takeover mode the loader makes a plain load when a library already serves, the player is logged in, or in combat", function()
    local cases = {
        { "a library already serving", function() loadCurrent() end },
        { "logged in", function() T.loggedIn = true end },
        { "in combat", function() T.inCombat = true end },
    }
    for _, case in ipairs(cases) do
        local F
        local tally = inTakeoverMode(function()
            T.installMocks(DEV)
            case[2]()
            F = T.loadFoundry()
        end)
        T.eq(tally.takeovers, 0, case[1] .. ": takeovers counted")
        T.eq(tally.plain, 1, case[1] .. ": plain loads counted")
        T.eq(anyLayout1Code(F), nil, case[1] .. ": a unit serving layout-1 code")
        T.falsy(isLayout1(_G.SlashCmdList.FOUNDRY), case[1] .. ": the /foundry command is the layout-1 copy's")
    end
end)

test("in takeover mode a suite fails when it makes no takeover and is not exempt, or is exempt and makes one", function()
    local exempt = next(T.TAKEOVER_EXEMPT)
    T.truthy(exempt ~= nil, "some suite is exempt")
    for label, reason in pairs(T.TAKEOVER_EXEMPT) do
        T.truthy(type(reason) == "string" and reason ~= "", label .. " gives a reason")
    end
    T.truthy(T.takeoverVerdict("Foundry.NotExempt", { takeovers = 0, plain = 3 }) ~= nil,
        "a suite with no takeover that is not exempt fails")
    T.eq(T.takeoverVerdict("Foundry.NotExempt", { takeovers = 2, plain = 0 }), nil,
        "a suite that takes over passes")
    T.truthy(T.takeoverVerdict(exempt, { takeovers = 1, plain = 0 }) ~= nil,
        "an exempt suite that takes over fails")
    T.eq(T.takeoverVerdict(exempt, { takeovers = 0, plain = 0 }), nil, "an exempt suite with no takeover passes")
end)

return tests

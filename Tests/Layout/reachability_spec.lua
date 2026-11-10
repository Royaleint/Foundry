-- Reachability: nothing a library function relies on is kept where only that
-- function can reach it.
--
-- The scenario below uses every module once, the way a session would: hooks
-- and an identity hold, two DB stores, a pending event bucket, a slash
-- command, canvas and launcher settings pages, tooltip handlers, a menu, an
-- attached window and a list. The walker (walker.lua) then follows every
-- table and every library function's upvalues from the library table and from
-- everything the client or the tests hold on to, and lists each upvalue that
-- is out of reach.
--
-- The list of such upvalues that exist today is committed below (EXPECTED)
-- and compared exactly. Each change that moves a module's state onto its own
-- tables deletes that module's entries, and only those; when the list is
-- empty nothing is out of reach. The same expected list controls two other
-- checks, so that they cannot be left half done:
--   * a module's callback relays are checked once the module has no entries
--   * the extra instance fields a module adds are required once it has none
-- Run with FOUNDRY_STRICT_REACHABILITY=1 to compare against an empty list;
-- FOUNDRY_REACHABILITY_REPORT=1 prints what the walker found, with locations.

local T = ...

local report = print   -- the real print: the mocks replace _G.print per test
local surfaces = assert(loadfile(T.testsDir .. "/Layout/surfaces.lua"))(T)
local walker = assert(loadfile(T.testsDir .. "/Layout/walker.lua"))(T)

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

--------------------------------------------------------------------------------
-- what is allowed to stay a local
--------------------------------------------------------------------------------

-- Values that are never written after the file loads, by file and name.
local CONSTANTS = {
    ["Modules/Commands.lua"] = { restrictionTypes = true },
    ["Modules/DB.lua"] = {
        SECTION_GLOBAL = true, SECTION_PROFILE = true, SECTION_CHAR = true,
        DENY_LIST = true, RESERVED = true, REFERENCE_TAIL = true,
    },
    ["Modules/Settings.lua"] = { LAUNCHER_ADD_SEARCH_TAGS = true },
    ["Modules/Window.lua"] = { VALID_ANCHOR_POINTS = true, NOT_UIPARENT_RELATIVE = true },
}

-- The client's timer and clock functions, captured fresh by each bucket.
local FUNCTIONS = {
    ["Modules/Events.lua"] = { newTimer = true, getTime = true },
}

local function isConstant(file, name)
    return CONSTANTS[file] ~= nil and CONSTANTS[file][name] == true
end

local function isAllowedFunction(file, name)
    return FUNCTIONS[file] ~= nil and FUNCTIONS[file][name] == true
end

-- The mock frames and views log every call under these keys; the logs hold
-- copies of functions that are not otherwise reachable.
local SKIP_KEYS = { calls = true, _seq = true }

--------------------------------------------------------------------------------
-- the expected list
--------------------------------------------------------------------------------

-- Upvalues that are out of reach today, by file. Delete a module's entries in
-- the change that moves its state; the comparison is exact in both directions.
local EXPECTED = {
}

-- Shared with the layout checks, which start applying to a file once its entries are gone.
T.expectedTrapped = EXPECTED

-- The module name a file belongs to.
local function moduleOf(file)
    return (file:match("^Modules/(.-)%.lua$")) or "Foundry"
end

local function fileOfModule(name)
    return name == "Foundry" and "Foundry.lua" or ("Modules/" .. name .. ".lua")
end

-- A module is moved once it has no entries left.
local function isMoved(moduleName)
    local list = EXPECTED[fileOfModule(moduleName)]
    return list == nil or #list == 0
end

local STRICT = os.getenv("FOUNDRY_STRICT_REACHABILITY") ~= nil
local ACTIVE_EXPECTED = STRICT and {} or EXPECTED

--------------------------------------------------------------------------------
-- the scenario
--------------------------------------------------------------------------------

local function makeCanvasFrame()
    return { GetObjectType = function() return "Frame" end }
end

-- Uses every module once and returns what a test or the client would hold.
local function runScenario(F)
    local s = { inst = {}, holders = {}, launched = 0, callbacks = {} }

    -- Every callback the scenario hands to the library is a function of its
    -- own, made here and recorded. Two sites sharing one function value would
    -- let the walker count a captured callback as reachable through the other
    -- site's field.
    local function cb(label, body)
        local fn = function(...)
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

    -- Tooltip: two types, and a second handler on the first.
    local processor = surfaces.installTooltipProcessor()
    s.inst.tooltip = F.Tooltip:New({ type = 1, handler = cb("tooltip first") })
    F.Tooltip:New({ type = 1, handler = cb("tooltip second"), name = "second" })
    F.Tooltip:New({ type = 2, handler = cb("tooltip other type") })
    s.holders[#s.holders + 1] = processor.postCalls

    -- Menu: an unnamed controller, installed on a dropdown and opened.
    local menuUtil = surfaces.installMenuUtil()
    local menu = F.Menu:New({ builder = cb("menu builder") })
    local button = surfaces.makeDropdownButton()
    menu:SetupDropdown(button)
    menu:CreateContextMenu({})
    s.inst.menu = menu
    s.holders[#s.holders + 1] = button.setups
    s.holders[#s.holders + 1] = menuUtil.createCalls

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

local function walkScenario(F, s)
    return walker.walk({
        F = F,
        roots = s.holders,
        constants = isConstant,
        functions = isAllowedFunction,
        skipKeys = SKIP_KEYS,
    })
end

local function currentScenario()
    local F = surfaces.load("current")
    local s = runScenario(F)
    return F, s, walkScenario(F, s)
end

local function describe(byFile)
    local files = {}
    for file in pairs(byFile) do files[#files + 1] = file end
    table.sort(files)
    local out = {}
    for _, file in ipairs(files) do
        out[#out + 1] = file .. ": " .. table.concat(byFile[file], ", ")
    end
    return table.concat(out, "\n")
end

--------------------------------------------------------------------------------
-- the scenario really ran
--------------------------------------------------------------------------------

test("no two callbacks in the scenario are the same function", function()
    local _, s = currentScenario()
    T.truthy(#s.callbacks >= 18, "the scenario registered its callbacks through the helper")
    local seen = {}
    for _, record in ipairs(s.callbacks) do
        T.truthy(seen[record.fn] == nil,
            record.label .. " is the same function as " .. tostring(seen[record.fn]))
        seen[record.fn] = record.label
    end
end)

test("the scenario uses every module and the walker sees functions from each file", function()
    local F, s, result = currentScenario()
    T.eq(s.launched, 2, "the launcher click ran the consumer before and after destroy and re-create")
    T.eq(s.releasedBy, "POLL", "the first identity hold was released by the poll")
    T.truthy(s.inst.lifecycle._identityHeld, "a second hold is pending")
    T.truthy(#T.afters > 0, "the second hold has a poll timer pending")
    T.truthy(#T.timers > 0 and not T.timers[#T.timers]._cancelled, "the bucket has a pending timer")
    local seen = {}
    for _, record in ipairs(result.functions) do seen[record.file] = true end
    for _, file in ipairs({ "Foundry.lua", "Modules/Commands.lua", "Modules/Events.lua", "Modules/Lifecycle.lua",
        "Modules/DB.lua", "Modules/List.lua", "Modules/Settings.lua", "Modules/Tooltip.lua", "Modules/Menu.lua",
        "Modules/Window.lua" }) do
        T.truthy(seen[file], "the walk reached a function from " .. file)
    end
    T.truthy(F.Commands and F.Window, "the modules are present")
end)

--------------------------------------------------------------------------------
-- the walker checks itself
--------------------------------------------------------------------------------

local MUTANT = [[
local F = _G.Foundry_1_0
local M = { API_VERSION = 1 }
local hiddenTable = {}
local hiddenFlag = false
local hiddenCount = 0
function M.touch() hiddenTable.n = 1; hiddenFlag = true; hiddenCount = hiddenCount + 1 end
function M.onlyLayout() return M, F end
function M.capture(fn) M.held = function() return fn() end end
F:RegisterModule("Mutant", M)
]]

local function loadMutant(source)
    local F = T.fresh()
    assert(loadstring(source, "@Mutant/Modules/Mutant.lua"))("Foundry-1.0")
    return F
end

test("walker self-check: a closure that captures a hidden table, flag, counter or consumer function is flagged", function()
    local F = loadMutant(MUTANT)
    local consumer = function() end
    F.Mutant.capture(consumer)
    local result = walker.walk({ F = F, skipKeys = SKIP_KEYS })
    local byFile = walker.trappedByFile(result)
    local names = table.concat(byFile["Modules/Mutant.lua"] or {}, ",")
    T.eq(names, "fn,hiddenCount,hiddenFlag,hiddenTable", "mutant upvalues flagged")
    T.eq(result.trapped["Modules/Mutant.lua:hiddenTable"].why, "table", "reason for the table")
    T.eq(result.trapped["Modules/Mutant.lua:hiddenFlag"].why, "boolean", "reason for the flag")
    T.eq(result.trapped["Modules/Mutant.lua:fn"].why, "function", "reason for the consumer function")
    T.falsy(result.trapped["Modules/Mutant.lua:M"], "the module table itself is reachable")
    T.falsy(result.trapped["Modules/Mutant.lua:F"], "F itself is allowed")
end)

test("walker self-check: exposing the table on the module table, or listing a constant, clears the flag", function()
    local exposed = MUTANT:gsub("function M.touch", "M.exposed = hiddenTable\nfunction M.touch", 1)
    local F = loadMutant(exposed)
    local result = walker.walk({ F = F, skipKeys = SKIP_KEYS })
    T.falsy(result.trapped["Modules/Mutant.lua:hiddenTable"], "a table reachable from F is in reach")
    T.truthy(result.trapped["Modules/Mutant.lua:hiddenFlag"], "the flag is still flagged")
    local allowed = walker.walk({
        F = F, skipKeys = SKIP_KEYS,
        constants = function(file, name) return file == "Modules/Mutant.lua" and name == "hiddenFlag" end,
    })
    T.falsy(allowed.trapped["Modules/Mutant.lua:hiddenFlag"], "a listed constant is allowed")
end)

test("walker self-check: a table reachable only through an upvalue is not in the layout set", function()
    local F = loadMutant(MUTANT)
    local result = walker.walk({ F = F, skipKeys = SKIP_KEYS })
    local hiddenTable
    for _, record in ipairs(result.functions) do
        for _, up in ipairs(record.upvalues) do
            if up.name == "hiddenTable" then hiddenTable = up.value end
        end
    end
    T.truthy(hiddenTable, "the walk found the closure")
    T.truthy(result.seenTables[hiddenTable], "the walk followed the upvalue")
    T.falsy(result.layoutTables[hiddenTable], "but the layout set did not")
end)

test("walker self-check: _G and the test harness are outside the layout set and never walked", function()
    local _, _, result = currentScenario()
    T.falsy(result.layoutTables[_G], "_G is not layout-reachable")
    T.falsy(result.layoutTables[T], "the test harness is not layout-reachable")
    T.falsy(result.seenTables[_G], "_G is not walked")
    T.falsy(result.seenTables[T], "the test harness is not walked")
    T.falsy(result.layoutTables[_G.SlashCmdList], "mock holders are not layout-reachable")
    T.falsy(result.layoutTables[T.afters], "timers waiting in the mock are not layout-reachable")
end)

test("walker self-check: the mock call logs are skipped, and nothing else is", function()
    local _, _, result = currentScenario()
    local frame = T.frames[1]
    T.truthy(result.seenTables[frame], "the frame is walked")
    T.truthy(result.seenTables[frame._scripts], "its script table is walked")
    T.falsy(result.seenTables[frame.calls], "its call log is skipped")
    T.falsy(result.seenTables[frame._seq], "its ordered call log is skipped")
end)

test("walker self-check: pinned release copies are not treated as library code", function()
    T.installMocks("@project-version@")
    local old = T.loadOldCopy("v1.0.114")
    local result = walker.walk({ F = old, skipKeys = SKIP_KEYS })
    T.eq(#result.functions, 0, "no function in a pinned copy is checked")
    T.eq(next(result.trapped), nil, "nothing is flagged in a pinned copy")
end)

--------------------------------------------------------------------------------
-- every piece of library state is reachable from the library table
--------------------------------------------------------------------------------

test("every piece of library state is reachable from the library table", function()
    local _, _, result = currentScenario()
    local found = walker.trappedByFile(result)
    if os.getenv("FOUNDRY_REACHABILITY_REPORT") then
        report("reachability: out of reach\n" .. describe(found))
        for _, key in ipairs(result.order) do
            local e = result.trapped[key]
            report(string.format("  %s (%s) at %s", key, e.why, table.concat(e.sites, " ")))
        end
    end
    local problems = {}
    local files = {}
    for file in pairs(found) do files[file] = true end
    for file in pairs(ACTIVE_EXPECTED) do files[file] = true end
    local sorted = {}
    for file in pairs(files) do sorted[#sorted + 1] = file end
    table.sort(sorted)
    for _, file in ipairs(sorted) do
        local have, want = {}, {}
        for _, name in ipairs(found[file] or {}) do have[name] = true end
        for _, name in ipairs(ACTIVE_EXPECTED[file] or {}) do want[name] = true end
        for name in pairs(have) do
            if not want[name] then problems[#problems + 1] = "out of reach but not expected: " .. file .. ": " .. name end
        end
        for name in pairs(want) do
            if not have[name] then problems[#problems + 1] = "expected out of reach but now reachable: " .. file .. ": " .. name end
        end
    end
    table.sort(problems)
    if #problems > 0 then
        error("reachability differs from the expected list:\n  " .. table.concat(problems, "\n  "), 0)
    end
end)

test("the expected list names only upvalues that sort and de-duplicate", function()
    for file, names in pairs(EXPECTED) do
        for i = 2, #names do
            T.truthy(names[i - 1] < names[i], file .. ": names are sorted and unique at " .. names[i])
        end
    end
end)

--------------------------------------------------------------------------------
-- callback relays
--------------------------------------------------------------------------------

-- A relay is the small function a client or a consumer holds on to; its body
-- only forwards to the module's current implementation. Each site is found by
-- its body text, which must occur exactly once in its file. Sites are listed
-- here and checked as soon as their module has no expected entries left, so a
-- module cannot finish its move without its relay being in place.
--   others     how many upvalues besides the module table the relay may hold
--              (an instance or a record, never anything else)
--   moduleToo  whether the module table is among its upvalues
local SITES = {
    { id = "poll timer", module = "Lifecycle", body = "return Lifecycle._impl.pollTick()", others = 0 },
    { id = "logout strip entry", module = "DB", body = "return DB._impl.onLogout()", others = 0 },
    -- The slash handler keeps its original body: one method call on the
    -- controller it was made for, resolved through the swappable method table.
    { id = "slash command", module = "Commands", body = "c:Dispatch(msg)", others = 1, moduleToo = false },
    { id = "tooltip post-call", module = "Tooltip", body = "return Tooltip._impl.dispatch(list, tooltip, data)", others = 1 },
    { id = "settings launcher click", module = "Settings", body = "return Settings._impl.launcherClick(record)", others = 1 },
    { id = "menu generator", module = "Menu", body = "return Menu._impl.generate(c, owner, rootDescription, ...)", others = 1 },
    { id = "list row initializer", module = "List", body = "return List._impl.initRow(c, frame, elementData)", others = 1 },
    { id = "list row extent", module = "List", body = "return List._impl.extent(c, index, elementData)", others = 1 },
}

local function readLines(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
    return lines
end

local function countPlain(text, needle)
    local count, from = 0, 1
    while true do
        local i, j = text:find(needle, from, true)
        if not i then return count end
        count, from = count + 1, j + 1
    end
end

-- The 1-based line the single occurrence of `needle` starts on.
local function lineOfPlain(text, needle)
    local i = text:find(needle, 1, true)
    local line = 1
    for _ in text:sub(1, i - 1):gmatch("\n") do line = line + 1 end
    return line
end

-- Checks one relay site against a source text and the walked function
-- records of its file. Returns a list of problems.
local function checkSite(site, text, records, moduleTable)
    local problems = {}
    local function bad(msg) problems[#problems + 1] = site.id .. ": " .. msg end

    local occurrences = countPlain(text, site.body)
    if occurrences ~= 1 then
        bad("body text occurs " .. occurrences .. " times, expected exactly once")
        return problems
    end
    local line = lineOfPlain(text, site.body)

    -- The innermost walked function around that line.
    local found = {}
    local smallest
    for _, record in ipairs(records) do
        if record.line <= line and line <= record.last then
            local span = record.last - record.line
            if smallest == nil or span < smallest then smallest, found = span, {} end
            if span == smallest then found[#found + 1] = record end
        end
    end
    if #found == 0 then
        bad("no walked function holds line " .. line .. "; the scenario never reaches this relay")
        return problems
    end

    -- One statement: the function's own text, minus comments, is the body
    -- between "function (...)" and "end".
    local lines = readLines(text)
    local first = found[1]
    local parts = {}
    for i = first.line, first.last do
        parts[#parts + 1] = (lines[i]:gsub("%-%-.*$", ""))
    end
    local flat = table.concat(parts, " "):gsub("%s+", " ")
    local at = flat:find(site.body, 1, true)
    if not at then
        bad("the function around the body text does not contain it")
    else
        local rest = flat:sub(1, at - 1) .. " " .. flat:sub(at + #site.body)
        if not rest:match("^.-function%s*[%w_%.:]*%b()%s*end[%s%),;]*$") then
            bad("the function is more than the one forwarding statement: " .. flat)
        end
    end

    for _, record in ipairs(found) do
        local others, sawModule = 0, false
        for _, up in ipairs(record.upvalues) do
            if rawequal(up.value, moduleTable) then
                sawModule = true
            elseif type(up.value) == "table" then
                others = others + 1
            else
                bad("upvalue '" .. up.name .. "' is a " .. type(up.value) .. "; a relay holds tables only")
            end
        end
        if others > site.others then
            bad("holds " .. others .. " tables besides the module table, at most " .. site.others .. " allowed")
        end
        if site.moduleToo == false and sawModule then
            bad("holds the module table, which this relay must not")
        end
        if site.moduleToo ~= false and not sawModule and site.others == 0 then
            bad("does not hold the module table")
        end
    end
    return problems
end

local function readSource(file)
    local f = assert(io.open(T.foundryRoot .. "/" .. file, "rb"))
    local text = f:read("*a")
    f:close()
    return text
end

test("every callback relay is in place once its module has moved its state", function()
    local F, _, result = currentScenario()
    local checked = 0
    for _, site in ipairs(SITES) do
        local file = fileOfModule(site.module)
        local text = readSource(file)
        if isMoved(site.module) then
            local records = {}
            for _, record in ipairs(result.functions) do
                if record.file == file then records[#records + 1] = record end
            end
            local problems = checkSite(site, text, records, F[site.module])
            T.eq(#problems, 0, table.concat(problems, "; "))
            checked = checked + 1
        else
            T.truthy(countPlain(text, site.body) <= 1, site.id .. ": body text occurs more than once")
        end
    end
    local pending = 0
    for _, site in ipairs(SITES) do
        if not isMoved(site.module) then pending = pending + 1 end
    end
    T.eq(checked + pending, #SITES, "every site is either checked or waiting for its module")
end)

test("no callback relay can stay unchecked after every module has moved", function()
    T.eq(#SITES, 8, "the eight relay sites")
    local seen = {}
    for _, site in ipairs(SITES) do
        T.falsy(seen[site.id], "site listed twice: " .. site.id)
        seen[site.id] = true
    end
    -- A site is waiting only while its module still has expected entries, so
    -- an empty expected list leaves no site waiting.
    local emptied = {}
    for _, site in ipairs(SITES) do
        local list = EXPECTED[fileOfModule(site.module)]
        emptied[site.module] = (list == nil or #list == 0)
    end
    for _, site in ipairs(SITES) do
        T.eq(emptied[site.module], isMoved(site.module), site.module .. ": waiting state follows the expected list")
    end
end)

test("relay self-check: a forwarding function holding the module table and one instance passes", function()
    local text = table.concat({
        "local M = ...",
        "local function build(c)",
        "    return function(a, b)",
        "        return M._impl.go(c, a, b)",
        "    end",
        "end",
        "return build",
    }, "\n")
    local M = {}
    local chunk = assert(loadstring(text, "@Fixture/Modules/Relay.lua"))
    local relay = chunk(M)({})
    local result = walker.walk({ F = M, roots = { { relay } } })
    local site = { id = "fixture", body = "return M._impl.go(c, a, b)", others = 1 }
    T.eq(#checkSite(site, text, result.functions, M), 0, "no problems")
end)

test("relay self-check: extra statements, extra tables, scalars and a missing module table are reported", function()
    local M = {}
    local function problemsFor(text, site, args)
        local chunk = assert(loadstring(text, "@Fixture/Modules/Relay.lua"))
        local relay = chunk(M, unpack(args))
        local result = walker.walk({ F = M, roots = { { relay } } })
        return checkSite(site, text, result.functions, M)
    end
    local extraStatement = table.concat({
        "local M, c = ...",
        "return function(a)",
        "    print(a)",
        "    return M._impl.go(c, a)",
        "end",
    }, "\n")
    local site = { id = "fixture", body = "return M._impl.go(c, a)", others = 1 }
    T.truthy(#problemsFor(extraStatement, site, { {} }) > 0, "an extra statement is reported")

    local twoTables = table.concat({
        "local M, c, d = ...",
        "return function(a)",
        "    return M._impl.go(c, d, a)",
        "end",
    }, "\n")
    T.truthy(#problemsFor(twoTables, { id = "fixture", body = "return M._impl.go(c, d, a)", others = 1 }, { {}, {} }) > 0,
        "a second table is reported")

    local scalar = table.concat({
        "local M, n = ...",
        "return function(a)",
        "    return M._impl.go(n, a)",
        "end",
    }, "\n")
    T.truthy(#problemsFor(scalar, { id = "fixture", body = "return M._impl.go(n, a)", others = 1 }, { 5 }) > 0,
        "a number upvalue is reported")

    local noModule = table.concat({
        "local c = ...",
        "return function(a)",
        "    return go(c, a)",
        "end",
    }, "\n")
    local chunk = assert(loadstring(noModule, "@Fixture/Modules/Relay.lua"))
    local relay = chunk({})
    local result = walker.walk({ F = M, roots = { { relay } } })
    T.truthy(#checkSite({ id = "fixture", body = "return go(c, a)", others = 0 }, noModule, result.functions, M) > 0,
        "a relay without the module table is reported when one is required")
end)

test("relay self-check: a body text that occurs twice, or never, is reported", function()
    local M = {}
    local site = { id = "fixture", body = "return M._impl.go()", others = 0 }
    T.truthy(#checkSite(site, "return M._impl.go()\nreturn M._impl.go()", {}, M) > 0, "twice")
    T.truthy(#checkSite(site, "nothing here", {}, M) > 0, "never")
end)

test("relay self-check: a one-method-call relay that holds only its instance passes", function()
    local text = table.concat({
        "local c = ...",
        "return function(msg)",
        "    c:Dispatch(msg)",
        "end",
    }, "\n")
    local M = {}
    local relay = assert(loadstring(text, "@Fixture/Modules/Relay.lua"))({})
    local result = walker.walk({ F = M, roots = { { relay } } })
    local site = { id = "slash", body = "c:Dispatch(msg)", others = 1, moduleToo = false }
    T.eq(#checkSite(site, text, result.functions, M), 0, "no problems")
end)

--------------------------------------------------------------------------------
-- instance fields
--------------------------------------------------------------------------------

-- The raw keys of each kind of instance in the 1.0.114 release, for the
-- instances the scenario builds. Pinned from the release copy by the test
-- below, so a typo here cannot go unnoticed.
local BASE_KEYS = {
    commandsController = { "_byName", "_destroyed", "_name", "_restrictionEvents", "_slashGlobals", "_slashListKey", "_slashes" },
    dbController = {},
    dbStore = { "addonName", "charKey", "defaults", "destroyed", "materialized", "onMismatch", "profileKey", "sections", "sizeWarningHandlers", "sv", "svName" },
    eventsBucket = { "_cancelled", "_controller", "_edge", "_events", "_handler", "_interval", "_timer" },
    eventsController = { "_bucketEvents", "_buckets", "_destroyed", "_frame", "_handlers", "_owner" },
    lifecycleController = { "_addonName", "_destroyed", "_hooks", "_identityHeld", "_owner", "_registered" },
    lifecycleControllerReleased = { "_addonName", "_destroyed", "_hooks", "_owner", "_registered" },
    listController = { "_destroyed", "_inInitializer", "_name", "_scrollBar", "_scrollBox", "_view" },
    menuController = { "_builder", "_destroyed", "_generatorWrapper", "_name" },
    settingsCanvasRecord = { "category", "frame", "kind", "layout", "mode", "title" },
    settingsController = { "_category", "_destroyed", "_initializer", "_isSettingsController", "_kind", "_launch", "_layout", "_mode", "_name" },
    settingsRecord = { "buttonText", "category", "initializer", "kind", "layout", "mode", "title" },
    tooltipController = { "_destroyed", "_handler", "_isTooltipController", "_name", "_next", "_type" },
    windowRecord = { "default", "geometry", "handle", "win" },
}

-- Fields the move adds, by instance type: the module whose entries must be
-- gone first, and the keys. While the module still has expected entries the
-- keys must be absent; once it has none they must be present. Either way the
-- comparison is exact.
local ADDITIONS = {
    eventsController = { module = "Events", keys = { "_onceHandlers" } },
    listController = { module = "List", keys = { "_extentFn", "_initFn" } },
    settingsRecord = { module = "Settings", keys = { "name" } },
    settingsCanvasRecord = { module = "Settings", keys = { "name" } },
}

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    return keys
end

-- A table held as state: from the module's _state when it has one, else from
-- an upvalue of one of the module's functions.
local function stateTable(module, name)
    if type(module._state) == "table" and module._state[name] ~= nil then return module._state[name] end
    for _, value in pairs(module) do
        if type(value) == "function" then
            local i = 1
            while true do
                local upName, upValue = debug.getupvalue(value, i)
                if not upName then break end
                if upName == name and upValue ~= nil then return upValue end
                i = i + 1
            end
        end
    end
end

local function collectKeys(F, s)
    local keys = {}
    keys.commandsController = sortedKeys(s.inst.commands)
    keys.eventsController = sortedKeys(s.inst.events)
    keys.eventsBucket = sortedKeys(s.inst.bucket)
    keys.lifecycleController = sortedKeys(s.inst.lifecycle)
    keys.lifecycleControllerReleased = sortedKeys(s.inst.lifecycleReleased)
    keys.dbController = sortedKeys(s.inst.db)
    keys.dbStore = sortedKeys(stateTable(F.DB, "controllerStore")[s.inst.db])
    keys.listController = sortedKeys(s.inst.list)
    keys.settingsController = sortedKeys(s.inst.settings)
    keys.settingsRecord = sortedKeys(stateTable(F.Settings, "registeredCategories")["ScenarioLauncher"])
    keys.settingsCanvasRecord = sortedKeys(stateTable(F.Settings, "registeredCategories")["ScenarioCanvas"])
    keys.tooltipController = sortedKeys(s.inst.tooltip)
    keys.menuController = sortedKeys(s.inst.menu)
    keys.windowRecord = sortedKeys(stateTable(F.Window, "attached")[s.inst.windowFrame])
    return keys
end

local function join(list) return table.concat(list, ",") end

test("instance fields of the 1.0.114 release are as pinned in this file", function()
    local F = surfaces.load("pinned")
    local keys = collectKeys(F, runScenario(F))
    local names = {}
    for name in pairs(keys) do names[#names + 1] = name end
    table.sort(names)
    if os.getenv("FOUNDRY_REACHABILITY_REPORT") then
        for _, name in ipairs(names) do
            report(string.format("    %s = { \"%s\" },", name, table.concat(keys[name], "\", \"")))
        end
    end
    for _, name in ipairs(names) do
        T.eq(BASE_KEYS[name] ~= nil, true, "a pinned key list exists for " .. name)
        T.eq(join(keys[name]), join(BASE_KEYS[name]), "release keys of " .. name)
    end
    for name in pairs(BASE_KEYS) do T.truthy(keys[name], "pinned list " .. name .. " matches a collected type") end
end)

test("instance fields are the 1.0.114 set plus exactly the additions of the modules that have moved", function()
    local F = surfaces.load("current")
    local keys = collectKeys(F, runScenario(F))
    for name, base in pairs(BASE_KEYS) do
        local want = {}
        for _, k in ipairs(base) do want[#want + 1] = k end
        local addition = ADDITIONS[name]
        if addition and isMoved(addition.module) then
            for _, k in ipairs(addition.keys) do want[#want + 1] = k end
        end
        table.sort(want)
        T.eq(join(keys[name]), join(want), "raw keys of " .. name)
    end
end)

test("the DB store record has exactly 11 keys", function()
    local F = surfaces.load("current")
    local s = runScenario(F)
    T.eq(#collectKeys(F, s).dbStore, 11, "store record keys")
end)

return tests

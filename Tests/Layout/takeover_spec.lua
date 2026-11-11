-- A newer copy of the library taking over an older one in place, one unit at a
-- time. A unit is the core (the four methods on the library table) or one
-- module. This file holds the machinery the takeover is built against:
--
--   * a ledger of the units that still serve the older copy's code after a
--     newer copy has loaded over it; each unit leaves the list when it takes
--     over, and the list is empty when they all do;
--   * the matrix of cases in which a newer copy must change nothing: a build
--     that is not newer, a layout it does not recognise, the player already
--     logged in, combat, a higher API version on the serving side;
--   * a scan of the shape of each file after its decision block, with the files
--     that have such a block still to join;
--   * self-tests for the snapshot used to show that nothing changed.
--
-- The serving copy is either the current code under build 2 (loaded with
-- T.loadBuild) or the pinned layout-1 copy, which has no build number. The
-- incoming copy is the current code under build 3.

local T = ...

local SN = assert(loadfile(T.testsDir .. "/Layout/snapshot.lua"))(T)
local surfaces = assert(loadfile(T.testsDir .. "/Layout/surfaces.lua"))(T)
local slots = assert(loadfile(T.testsDir .. "/Layout/slots.lua"))(T)

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local UNITS = { "core", "Commands", "Events", "Lifecycle", "DB", "List", "Settings", "Tooltip", "Menu", "Window" }
local FILE = {
    core = "Foundry.lua",
    Commands = "Modules/Commands.lua", Events = "Modules/Events.lua", Lifecycle = "Modules/Lifecycle.lua",
    DB = "Modules/DB.lua", List = "Modules/List.lua", Settings = "Modules/Settings.lua",
    Tooltip = "Modules/Tooltip.lua", Menu = "Modules/Menu.lua", Window = "Modules/Window.lua",
}

local SERVING_BUILD, INCOMING_BUILD = 2, 3

--------------------------------------------------------------------------------
-- Units still on the older copy's code
--------------------------------------------------------------------------------

-- The units whose code is still the older copy's after a newer copy has loaded
-- over it. The ledger test holds the list to exactly the units that still serve
-- older code. Every unit takes over now, so the list is empty and the test is
-- strict: no unit may serve older code. A unit named here would also be held
-- back from the cases below that need the raise for a refused takeover.
local STILL_OLDER = {}

local function pending(unit)
    for _, name in ipairs(STILL_OLDER) do
        if name == unit then return true end
    end
    return false
end

local function unitTable(F, unit)
    if unit == "core" then return F end
    return F[unit]
end

local function isOlderFunction(fn)
    if type(fn) ~= "function" then return false end
    local source = debug.getinfo(fn, "S").source:gsub("\\", "/")
    return source:find("/OldCopies/layout1/", 1, true) ~= nil
end

-- path -> function for one unit: its own functions, and every function in a
-- table below it except its saved state. For the core, the methods on the
-- library table.
local function codeOf(F, unit)
    local out = {}
    if unit == "core" then
        for key, value in pairs(F) do
            if type(value) == "function" then out[key] = value end
        end
        return out
    end
    local seen = {}
    local function walk(prefix, tbl)
        if seen[tbl] then return end
        seen[tbl] = true
        for key, value in pairs(tbl) do
            local path = prefix .. tostring(key)
            if type(value) == "function" then
                out[path] = value
            elseif type(value) == "table" and not (prefix == "" and key == "_state") then
                walk(path .. ".", value)
            end
        end
    end
    walk("", F[unit])
    return out
end

local function sortedNames(set)
    local out = {}
    for name in pairs(set) do out[#out + 1] = name end
    table.sort(out)
    return out
end

-- Loads the files of a copy one at a time, as the client does: an error in one
-- file does not stop the next. Returns the errors keyed by file.
local function loadEach(spec)
    local errors = {}
    for _, rel in ipairs(spec.files or T.FOUNDRY_FILES) do
        local ok, err = pcall(T.loadBuild, {
            build = spec.build, addonName = spec.addonName, version = spec.version, files = { rel },
        })
        if not ok then errors[rel] = tostring(err) end
    end
    return errors
end

local function firstError(errors)
    local _, message = next(errors)
    return tostring(message)
end

-- Instances of every module, built without any login event, so that a unit's
-- state is as a session before login would leave it.
local function buildInstances(F)
    local inst = {}
    T.loadedAddons["TakeoverAddon"] = true
    inst.db = F.DB:New({
        name = "TakeoverAddon", sv = "TestDB", defaultProfile = true,
        defaults = { profile = { a = 1 }, global = { g = 1 } },
    })
    local events = F.Events:New("TakeoverAddon")
    events:RegisterOnce("TAKEOVER_ONCE", function() end)
    inst.events = events
    inst.bucket = events:RegisterBucket({ events = "TAKEOVER_BUCKET", interval = 5, handler = function() end })
    _G.Enum = {
        AddOnRestrictionType = { Combat = 0, Encounter = 1, ChallengeMode = 2, PvPMatch = 3, Map = 4, Chat = 5 },
        AddOnRestrictionState = { Inactive = 0, Activating = 1, Active = 2 },
    }
    _G.C_RestrictedActions = { IsAddOnRestrictionActive = function() return false end }
    _G.C_EventUtils = { IsEventValid = function() return true end }
    inst.commands = F.Commands:New({ name = "Takeover", slashes = { "/tko" }, restrictionNotice = true })
    inst.guarded = F.Commands:New({
        name = "TakeoverGuarded", slashes = { "/tkg" }, guard = F.Commands.Guards.NotRestricted,
    })
    inst.panel = surfaces.installSettingsLauncher()
    inst.settings = F.Settings:New({
        title = "TakeoverCanvas", frame = { GetObjectType = function() return "Frame" end },
    })
    inst.launcher = F.Settings:New({ title = "TakeoverLauncher", buttonText = "Open", launch = function() end })
    inst.processor = surfaces.installTooltipProcessor()
    inst.tooltip = F.Tooltip:New({ type = 1, handler = function() end })
    inst.menuUtil = surfaces.installMenuUtil()
    inst.menu = F.Menu:New({ builder = function() end })
    local win = _G.CreateFrame("Frame", nil, _G.UIParent)
    F.Window:Attach(win, { handle = win, geometry = {}, default = { "CENTER", "CENTER", 0, 0 } })
    inst.windowFrame = win
    inst.list = F.List:New({
        name = "TakeoverList", parent = {}, elementType = "Button",
        extentCalculator = function() return 20 end, initializer = function() end,
    })
    inst.lifecycle = F.Lifecycle:New(nil, "TakeoverLifecycle")
    inst.lifecycle:OnAddonLoaded(function() end)
    return inst
end

-- instance -> the unit it belongs to and the _impl table it takes as metatable
local INSTANCE_META = {
    { "db", "DB", "controllerMeta" },
    { "events", "Events", "Controller" }, { "bucket", "Events", "Bucket" },
    { "commands", "Commands", "Controller" }, { "guarded", "Commands", "Controller" },
    { "settings", "Settings", "Controller" }, { "tooltip", "Tooltip", "Controller" },
    { "menu", "Menu", "Controller" }, { "list", "List", "Controller" },
    { "lifecycle", "Lifecycle", "Controller" },
}

-- What the build-3 copy defines for each unit, read from a fresh load.
local function definedByNewerCopy()
    T.installMocks("@project-version@")
    local F = T.loadBuild({ build = INCOMING_BUILD })
    local defined = {}
    for _, unit in ipairs(UNITS) do defined[unit] = codeOf(F, unit) end
    return defined
end

test("the ledger names only units, each once", function()
    local seen = {}
    for _, name in ipairs(STILL_OLDER) do
        T.truthy(FILE[name] ~= nil, "'" .. tostring(name) .. "' is a unit")
        T.falsy(seen[name], name .. " is listed once")
        seen[name] = true
    end
end)

test("after a newer copy loads over the layout-1 copy, every unit serves the newer code", function()
    local defined = definedByNewerCopy()
    for _, unit in ipairs(UNITS) do
        T.truthy(next(defined[unit]) ~= nil, unit .. " defines functions in the newer copy")
    end
    T.installMocks("@project-version@")
    local F = T.loadOldCopy("layout1", "ServingHost")
    buildInstances(F)
    local errors = loadEach({ build = INCOMING_BUILD, addonName = "IncomingHost" })
    T.eq(next(errors), nil, "the incoming copy raised nothing")
    local older, example = {}, {}
    for _, unit in ipairs(UNITS) do
        for path, fn in pairs(codeOf(F, unit)) do
            if defined[unit][path] ~= nil and isOlderFunction(fn) then
                older[unit] = true
                example[unit] = example[unit] or path
            end
        end
    end
    local expected = {}
    for _, name in ipairs(STILL_OLDER) do expected[name] = true end
    local got, want = table.concat(sortedNames(older), ","), table.concat(sortedNames(expected), ",")
    if got ~= want then
        local detail = {}
        for _, unit in ipairs(sortedNames(older)) do detail[#detail + 1] = unit .. " (" .. example[unit] .. ")" end
        error("units still serving the older copy's code: [" .. got .. "], the ledger lists: [" .. want
            .. "]; first older function per unit: " .. table.concat(detail, ", "), 0)
    end
end)

test("instances made before a newer copy loads keep their metatable, which is the implementation table the unit serves", function()
    T.installMocks("@project-version@")
    local F = T.loadOldCopy("layout1", "ServingHost")
    local inst = buildInstances(F)
    local before = {}
    for _, row in ipairs(INSTANCE_META) do
        local object = assert(inst[row[1]], row[1] .. " was built")
        before[row[1]] = getmetatable(object)
        T.truthy(before[row[1]] ~= nil, row[1] .. " has a metatable")
    end
    local errors = loadEach({ build = INCOMING_BUILD, addonName = "IncomingHost" })
    T.eq(next(errors), nil, "the incoming copy raised nothing")
    for _, row in ipairs(INSTANCE_META) do
        local name, unit, implName = row[1], row[2], row[3]
        T.truthy(rawequal(getmetatable(inst[name]), before[name]), name .. " keeps its metatable")
        T.truthy(rawequal(getmetatable(inst[name]), F[unit]._impl[implName]),
            name .. "'s metatable is " .. unit .. "._impl." .. implName)
    end
end)

--------------------------------------------------------------------------------
-- The generic matrix: a newer copy that must change nothing
--------------------------------------------------------------------------------

local function releaseMode(mode) return mode == "release" end

-- Resets the mocks and loads the serving copy: kind "current" is the current
-- code under build 2; "layout1" is the pinned copy, which has no build number.
local function serve(kind, mode)
    T.installMocks(releaseMode(mode) and "1.0.0" or "@project-version@")
    local version = releaseMode(mode) and "1.0.1" or nil
    if kind == "layout1" then
        return T.loadOldCopy("layout1", "ServingHost", version)
    end
    return T.loadBuild({ build = SERVING_BUILD, addonName = "ServingHost", version = version })
end

local function incomingVersion(mode) return releaseMode(mode) and "1.0.2" or nil end

local function setBuild(value)
    return function(_, unitTbl) rawset(unitTbl, "_build", value) end
end

local function setLayout(value)
    return function(_, unitTbl) rawset(unitTbl, "_layoutVersion", value) end
end

-- name        the case, in plain words
-- inject      puts the serving copy in that state (called with the library
--             table, the unit's table and the unit's name)
-- outcome     the word the record carries when a unit declines for this reason
-- refused     true when the outcome is a refusal, which raises in a serving
--             development copy
-- coreOutcome the word the core's own record carries when it differs from the
--             modules' (a core with no layout is an older copy, not a layout
--             this copy does not recognise)
-- kinds       the serving copies the case runs over
local BUILD_CASES = {
    { name = "an equal build", inject = setBuild(INCOMING_BUILD) },
    { name = "a lower build", inject = setBuild(INCOMING_BUILD + 1) },
    { name = "a build written as a string", inject = setBuild("2") },
    { name = "a build that is not a whole number", inject = setBuild(1.5) },
    { name = "a build that is not a number at all", inject = setBuild(0 / 0) },
    { name = "an infinite build", inject = setBuild(math.huge) },
    { name = "a negative infinite build", inject = setBuild(-math.huge) },
    { name = "a build of zero", inject = setBuild(0) },
    { name = "a negative build", inject = setBuild(-3) },
}
for _, case in ipairs(BUILD_CASES) do case.outcome = "not used" end

local OTHER_CASES = {
    { name = "a unit with layout 2", inject = setLayout(2), outcome = "layout" },
    { name = "a unit with no layout", inject = setLayout(nil), outcome = "layout", coreOutcome = "not used" },
    { name = "a player who is already logged in",
        inject = function() T.loggedIn = true end, outcome = "after login", layout1 = true },
    { name = "a player in combat",
        inject = function() T.inCombat = true end, outcome = "combat", layout1 = true },
    { name = "a higher API version on the serving side",
        inject = function(_, unitTbl) unitTbl.API_VERSION = 99 end,
        outcome = "refused: api version", refused = true, layout1 = true },
}

-- One case, one serving copy, one mode, one unit: the incoming copy's file for
-- that unit loads alone; nothing may change in the serving copy, a release
-- build prints nothing, and a development build raises only for a refusal.
local function row(case, kind, mode, unit)
    local who = string.format("%s over %s, %s build, %s: ", case.name,
        kind == "layout1" and "the layout-1 copy" or "build 2", mode, unit)
    local F = serve(kind, mode)
    case.inject(F, unitTable(F, unit), unit)
    local copies = F._state.copies
    local appendedBefore = #copies
    local before = SN.take(F)
    local ok, err = pcall(T.loadBuild, {
        build = INCOMING_BUILD, addonName = "IncomingHost", version = incomingVersion(mode), files = { FILE[unit] },
    })
    local changes = SN.diff(before, SN.take(F), unit == "core" and { copies = 1 } or nil)
    T.eq(#changes, 0, who .. "nothing changes, but: " .. table.concat(changes, "; "))

    if unit ~= "core" then
        T.eq(#copies, appendedBefore, who .. "a module file leaves the record alone")
    else
        T.eq(#copies, appendedBefore + 1, who .. "the core records one entry")
        local entry = copies[appendedBefore + 1]
        T.eq(entry.unit, "core", who .. "entry unit")
        T.eq(entry.source, "IncomingHost", who .. "entry source")
        T.eq(entry.version, releaseMode(mode) and "1.0.2" or "dev", who .. "entry version is the incoming copy's")
        T.eq(entry.apiVersion, 7, who .. "entry API version")
        T.eq(entry.build, INCOMING_BUILD, who .. "entry build")
        T.eq(entry.outcome, case.coreOutcome or case.outcome, who .. "entry outcome")
    end

    if releaseMode(mode) then
        T.truthy(ok, who .. "a release build raises nothing: " .. tostring(err))
    elseif case.refused then
        if not pending(unit) then
            T.falsy(ok, who .. "a development build raises for a refusal")
            T.truthy(tostring(err):find(case.outcome, 1, true), who .. "the error names '" .. case.outcome
                .. "': " .. tostring(err))
            if unit == "core" then
                T.eq(#copies, appendedBefore + 1, who .. "the record is written before the error")
                T.truthy(tostring(err):find("Foundry-1.0: a newer copy from IncomingHost did not upgrade the active copy ("
                    .. case.outcome .. ")", 1, true), who .. "the error text: " .. tostring(err))
            else
                T.truthy(tostring(err):find("Foundry-1.0: " .. unit .. ": a newer copy from IncomingHost did not upgrade the active copy ("
                    .. case.outcome .. ")", 1, true), who .. "the error text: " .. tostring(err))
            end
        end
    else
        T.truthy(ok, who .. "a development build raises nothing here: " .. tostring(err))
    end
end

local function runCase(case, kind)
    for _, mode in ipairs({ "release", "dev" }) do
        for _, unit in ipairs(case.units or UNITS) do row(case, kind, mode, unit) end
    end
end

for _, case in ipairs(BUILD_CASES) do
    test("a copy facing " .. case.name .. " on the serving side takes over no unit and changes nothing", function()
        runCase(case, "current")
    end)
end
for _, case in ipairs(OTHER_CASES) do
    test("a copy facing " .. case.name .. " takes over no unit and changes nothing", function()
        runCase(case, "current")
    end)
    if case.layout1 then
        test("a copy facing " .. case.name .. " takes over no unit of the layout-1 copy and changes nothing", function()
            runCase(case, "layout1")
        end)
    end
end

-- DB reads Lifecycle and Events when it is created; a serving copy lacking
-- what it needs is refused without the long message a fresh load prints.
local PREREQUISITES = {
    { name = "no Lifecycle", outcome = "refused: lifecycle seams",
        inject = function(F) rawset(F, "Lifecycle", nil) end },
    { name = "a Lifecycle without the post-logout seam", outcome = "refused: lifecycle seams",
        inject = function(F) F.Lifecycle._RegisterPostLogout = nil end },
    { name = "a Lifecycle without the player-identity check", outcome = "refused: lifecycle seams",
        inject = function(F) F.Lifecycle._PlayerIdentity = nil end },
    { name = "no Events", outcome = "refused: events",
        inject = function(F) rawset(F, "Events", nil) end },
    { name = "an Events without New", outcome = "refused: events",
        inject = function(F) F.Events.New = nil end },
}

-- The library lists the module, but its field on the library table is gone:
-- the newer file takes nothing and writes nothing, as when it stood down.
test("a newer module file facing a module the library lists but no longer holds changes nothing and raises nothing", function()
    local modules = {}
    for _, unit in ipairs(UNITS) do
        if unit ~= "core" then modules[#modules + 1] = unit end
    end
    for _, kind in ipairs({ "current", "layout1" }) do
        runCase({
            name = "a module listed with no field", outcome = "not used", units = modules,
            inject = function(F, _, unit) rawset(F, unit, nil) end,
        }, kind)
    end
end)

test("a newer DB declines a serving copy that lacks what DB needs, prints nothing and changes nothing", function()
    for _, case in ipairs(PREREQUISITES) do
        runCase({
            name = "a serving copy with " .. case.name, inject = case.inject, outcome = case.outcome,
            refused = true, units = { "DB" },
        }, "current")
    end
end)

-- The serving copy is the 1.0.114 release in full: no layout, no record, state
-- held in upvalues.
test("a newer copy over the whole 1.0.114 release takes over nothing and changes nothing", function()
    for _, mode in ipairs({ "release", "dev" }) do
        T.installMocks(releaseMode(mode) and "1.0.0" or "@project-version@")
        local F = T.loadOldCopy("v1.0.114", "ServingHost", releaseMode(mode) and "1.0.114" or nil)
        local before = SN.take(F)
        local errors = loadEach({ build = INCOMING_BUILD, addonName = "IncomingHost", version = incomingVersion(mode) })
        T.eq(next(errors), nil, mode .. ": the incoming copy raised nothing: " .. firstError(errors))
        local changes = SN.diff(before, SN.take(F))
        T.eq(#changes, 0, mode .. ": nothing changes, but: " .. table.concat(changes, "; "))
        T.eq(rawget(F, "_state"), nil, mode .. ": no state appears on a library without it")
    end
end)

-- The serving copy is a mixture: the layout-1 core and DB around the 1.0.114
-- Commands, Events and Lifecycle, which have no layout. DB cannot be taken over
-- because its Lifecycle is not layout 1.
test("a newer DB over a Lifecycle with no layout declines and changes nothing", function()
    local FILES = { "Modules/Commands.lua", "Modules/Events.lua", "Modules/Lifecycle.lua", "Modules/DB.lua" }
    for _, mode in ipairs({ "release", "dev" }) do
        T.installMocks(releaseMode(mode) and "1.0.0" or "@project-version@")
        local version = releaseMode(mode) and "1.0.1" or nil
        local layout1, old = T.testsDir .. "/OldCopies/layout1", T.testsDir .. "/OldCopies/v1.0.114"
        T.loadCopy({ root = layout1, files = { "Foundry.lua" }, addonName = "ServingHost", version = version })
        T.loadCopy({ root = old, files = { "Modules/Commands.lua", "Modules/Events.lua", "Modules/Lifecycle.lua" },
            addonName = "ServingHost", version = version })
        T.loadCopy({ root = layout1, files = { "Modules/DB.lua" }, addonName = "ServingHost", version = version })
        local F = _G.Foundry_1_0
        T.eq(F.Lifecycle._layoutVersion, nil, mode .. ": the serving Lifecycle has no layout")
        T.eq(F.DB._layoutVersion, 1, mode .. ": the serving DB is layout 1")
        local appended = #F._state.copies
        local before = SN.take(F)
        local errors = loadEach({
            build = INCOMING_BUILD, addonName = "IncomingHost", version = incomingVersion(mode), files = FILES,
        })
        local changes = SN.diff(before, SN.take(F))
        T.eq(#changes, 0, mode .. ": nothing changes, but: " .. table.concat(changes, "; "))
        T.eq(#F._state.copies, appended, mode .. ": a module file records nothing")
        for _, rel in ipairs(FILES) do
            if rel == "Modules/DB.lua" and not releaseMode(mode) and not pending("DB") then
                T.truthy(errors[rel] and errors[rel]:find("refused: lifecycle layout", 1, true),
                    mode .. ": DB's refusal raises in a development build: " .. tostring(errors[rel]))
            else
                T.eq(errors[rel], nil, mode .. ": " .. rel .. " raises nothing")
            end
        end
    end
end)

-- The v1.0.4 copy serves the core and four modules; the layout-1 copy then loads
-- and fills in the modules v1.0.4 lacks, so those are layout-1 modules under a
-- core that carries no layout marker. A newer copy must leave all of it alone.
test("a newer copy over layout-1 modules sitting under a core with no layout takes over no unit and changes nothing", function()
    local FILLED = { List = "New", Settings = "New", Tooltip = "New", Menu = "New", Window = "Attach" }
    local KEPT = { "Commands", "Events", "Lifecycle", "DB" }
    for _, mode in ipairs({ "release", "dev" }) do
        T.installMocks(releaseMode(mode) and "1.0.0" or "@project-version@")
        local version = releaseMode(mode) and "1.0.1" or nil
        local old4, layout1 = T.testsDir .. "/OldCopies/v1.0.4", T.testsDir .. "/OldCopies/layout1"
        T.loadCopy({ root = old4, files = T.OLD_COPIES["v1.0.4"], addonName = "ServingHost", version = version })
        local errors = {}
        for _, rel in ipairs(T.OLD_COPIES.layout1) do
            local ok, err = pcall(T.loadCopy, { root = layout1, files = { rel }, addonName = "FillerHost", version = version })
            if not ok then errors[rel] = tostring(err) end
        end
        -- the layout-1 core stands down, and says so only in a development build
        T.eq(errors["Foundry.lua"] ~= nil, not releaseMode(mode), mode .. ": the layout-1 core's stand-down raises in development only")
        errors["Foundry.lua"] = nil
        T.eq(next(errors), nil, mode .. ": no layout-1 module raised: " .. firstError(errors))
        local F = _G.Foundry_1_0
        T.eq(rawget(F, "_layoutVersion"), nil, mode .. ": the core carries no layout marker")
        for unit, method in pairs(FILLED) do
            T.eq(rawget(F[unit], "_layoutVersion"), 1, mode .. ": " .. unit .. " is a layout-1 module")
            T.truthy(isOlderFunction(F[unit][method]), mode .. ": " .. unit .. " serves the layout-1 code")
        end
        for _, unit in ipairs(KEPT) do
            T.eq(rawget(F[unit], "_layoutVersion"), nil, mode .. ": " .. unit .. " stays the v1.0.4 module")
        end
        T.eq(#T.output, 0, mode .. ": loading the older copies prints nothing")
        local before = SN.take(F)
        errors = loadEach({ build = INCOMING_BUILD, addonName = "IncomingHost", version = incomingVersion(mode) })
        T.eq(errors["Foundry.lua"] ~= nil, not releaseMode(mode), mode .. ": the newer core's stand-down raises in development only")
        errors["Foundry.lua"] = nil
        T.eq(next(errors), nil, mode .. ": no newer module raised: " .. firstError(errors))
        local changes = SN.diff(before, SN.take(F))
        T.eq(#changes, 0, mode .. ": nothing changes, but: " .. table.concat(changes, "; "))
        T.eq(#T.output, 0, mode .. ": nothing is printed")
        for unit, method in pairs(FILLED) do
            T.eq(rawget(F[unit], "_build"), nil, mode .. ": " .. unit .. " was not taken over")
            T.truthy(isOlderFunction(F[unit][method]), mode .. ": " .. unit .. " still serves the layout-1 code")
        end
    end
end)

-- A whole incoming copy, while the player is logged in or in combat: no unit
-- is used, and nothing is printed.
test("a whole newer copy loading while the player is logged in or in combat changes nothing", function()
    for _, flag in ipairs({ "loggedIn", "inCombat" }) do
        for _, mode in ipairs({ "release", "dev" }) do
            local F = serve("current", mode)
            T[flag] = true
            local appended = #F._state.copies
            local before = SN.take(F)
            local errors = loadEach({ build = INCOMING_BUILD, addonName = "IncomingHost", version = incomingVersion(mode) })
            local changes = SN.diff(before, SN.take(F), { copies = 1 })
            T.eq(#changes, 0, flag .. ", " .. mode .. ": nothing changes, but: " .. table.concat(changes, "; "))
            T.eq(next(errors), nil, flag .. ", " .. mode .. ": nothing raised: " .. firstError(errors))
            T.eq(#F._state.copies, appended + 1, flag .. ", " .. mode .. ": only the core records")
        end
    end
end)

--------------------------------------------------------------------------------
-- The core
--------------------------------------------------------------------------------

local API_LINE = "local API_VERSION = 7"

-- A replace map giving the loaded copy another API version.
local function apiVersion(n) return { [API_LINE] = "local API_VERSION = " .. n } end

local function merge(a, b)
    local out = {}
    for k, v in pairs(a or {}) do out[k] = v end
    for k, v in pairs(b or {}) do out[k] = v end
    return out
end

-- Loads the incoming copy's core file alone.
local function loadCore(spec)
    return T.loadBuild({
        build = spec.build or INCOMING_BUILD, addonName = spec.addonName or "IncomingHost",
        version = spec.version, files = { "Foundry.lua" }, replace = spec.replace,
    })
end

local METHODS = { "RaiseDevError", "RegisterModule", "HasModule", "RequireModule" }

local function buildOf(fn)
    return debug.getinfo(fn, "S").source:gsub("\\", "/"):match("/build%-(%d+)/")
end

test("a newer copy takes over the library core: the four methods are new, the library keeps its identity, version, source, dev flag and load token, and the API version reads the newer value", function()
    for _, kind in ipairs({ "current", "layout1" }) do
        for _, mode in ipairs({ "release", "dev" }) do
            local who = kind .. ", " .. mode .. ": "
            local F = serve(kind, mode)
            local kept = {
                VERSION = F.VERSION, SOURCE = F.SOURCE, IS_DEV_BUILD = F.IS_DEV_BUILD, token = F._LOAD_TOKEN,
                modules = F._state.modules, state = F._state, impl = F.Commands._impl,
            }
            local older = {}
            for _, name in ipairs(METHODS) do older[name] = F[name] end
            local copies = #F._state.copies
            local result = loadCore({ version = incomingVersion(mode), replace = apiVersion(8) })
            T.truthy(rawequal(result, F), who .. "the library table is the same table")
            T.truthy(rawequal(_G.Foundry_1_0, F), who .. "the global is unchanged")
            for _, name in ipairs(METHODS) do
                T.truthy(F[name] ~= older[name], who .. name .. " is redefined")
                T.eq(buildOf(F[name]), tostring(INCOMING_BUILD), who .. name .. " is the incoming copy's code")
            end
            T.eq(F.VERSION, kept.VERSION, who .. "version is kept")
            T.eq(F.SOURCE, kept.SOURCE, who .. "source is kept")
            T.eq(F.IS_DEV_BUILD, kept.IS_DEV_BUILD, who .. "dev flag is kept")
            T.truthy(rawequal(F._LOAD_TOKEN, kept.token), who .. "load token is kept")
            T.truthy(rawequal(F._state, kept.state), who .. "state table is kept")
            T.truthy(rawequal(F._state.modules, kept.modules), who .. "module list is kept")
            T.truthy(rawequal(F.Commands._impl, kept.impl), who .. "modules are untouched")
            T.eq(F.API_VERSION, 8, who .. "API version reads the newer value")
            T.eq(F._build, INCOMING_BUILD, who .. "build is the newer number")
            T.eq(F._source, "IncomingHost", who .. "the newer copy's addon is named")
            T.eq(F._layoutVersion, 1, who .. "layout version")
            T.eq(#F._state.copies, copies + 1, who .. "one entry is recorded")
            T.eq(F._state.copies[copies + 1].outcome, "upgraded to", who .. "outcome")
            T.eq(#T.output, 0, who .. "nothing is printed")
            local probe = {}
            T.truthy(rawequal(F:RegisterModule("TakeoverProbe", probe), probe), who .. "the new RegisterModule works")
            T.truthy(rawequal(F.TakeoverProbe, probe) and F:HasModule("TakeoverProbe"), who .. "HasModule sees it")
            T.truthy(rawequal(F:RequireModule("TakeoverProbe"), probe), who .. "RequireModule returns it")
        end
    end
end)

test("a newer copy declines a library whose module list does not match its fields, records it, and raises only in a development serving copy", function()
    local cases = {
        { name = "a registered name whose field is another table",
            inject = function(F) F._state.modules.Probe = {}; rawset(F, "Probe", {}) end },
        { name = "a registered name with no field on the library",
            inject = function(F) F._state.modules.Probe = {} end },
        { name = "a module list that is not a table",
            inject = function(F) F._state.modules = "not a table" end },
    }
    for _, case in ipairs(cases) do
        runCase({
            name = "a serving core with " .. case.name, inject = case.inject,
            outcome = "refused: module list", refused = true, units = { "core" },
        }, "current")
    end
end)

test("the core records one entry per loading copy with its build, and a upgraded entry carries the incoming copy's own version and source", function()
    T.installMocks("1.0.0")
    local F = T.loadBuild({ build = SERVING_BUILD, addonName = "HostA", version = "1.0.1" })
    local steps = {
        { build = 3, name = "HostB", version = "1.0.2", outcome = "upgraded to" },
        { build = 3, name = "HostC", version = "1.0.3", outcome = "not used" },
        { build = 2, name = "HostD", version = "1.0.4", outcome = "not used" },
        { build = 4, name = "HostE", version = "1.0.5", outcome = "upgraded to" },
    }
    for _, step in ipairs(steps) do
        loadCore({ build = step.build, addonName = step.name, version = step.version })
    end
    local copies = F._state.copies
    T.eq(#copies, #steps, "one entry per loading copy")
    for i, step in ipairs(steps) do
        local entry = copies[i]
        local keys = {}
        for k in pairs(entry) do keys[#keys + 1] = k end
        table.sort(keys)
        T.eq(table.concat(keys, ","), "apiVersion,build,outcome,source,unit,version", "entry " .. i .. " fields")
        T.eq(entry.source, step.name, "entry " .. i .. " source")
        T.eq(entry.version, step.version, "entry " .. i .. " version")
        T.eq(entry.build, step.build, "entry " .. i .. " build")
        T.eq(entry.apiVersion, 7, "entry " .. i .. " API version")
        T.eq(entry.unit, "core", "entry " .. i .. " unit")
        T.eq(entry.outcome, step.outcome, "entry " .. i .. " outcome")
    end
    T.eq(F.SOURCE, "HostA", "the first copy's name is kept")
    T.eq(F.VERSION, "1.0.1", "the first copy's version is kept")
    T.eq(F._source, "HostE", "the last copy to take over is named")
    T.eq(F._build, 4, "and its build is the library's")
end)

test("a newer copy over a layout-1 core takes it over and records it, and over a 1.0.114 core records nothing", function()
    local F = serve("layout1", "release")
    T.eq(#F._state.copies, 0, "no entries yet")
    loadCore({ version = "1.0.2" })
    T.eq(#F._state.copies, 1, "the layout-1 core keeps a record")
    T.eq(F._state.copies[1].outcome, "upgraded to", "outcome")
    T.installMocks("1.0.0")
    local old = T.loadOldCopy("v1.0.114", "ServingHost", "1.0.114")
    loadCore({ version = "1.0.2" })
    T.eq(rawget(old, "_state"), nil, "a core with no state gets none")
    T.eq(rawget(old, "_build"), nil, "and no build")
    T.eq(#T.output, 0, "nothing is printed")
end)

test("the two suppression messages fire for a 1.0.114 core and for an equal build, and stay silent when the core takes over", function()
    local DEV = "@project-version@"
    -- a 1.0.114 release core, then a development copy
    T.installMocks("1.0.0")
    T.loadOldCopy("v1.0.114", "ServingHost", "1.0.114")
    loadCore({ version = DEV })
    T.outputContains("Foundry-1.0: an enabled Foundry-1.0 DevBuild was suppressed; the first-loaded release copy (version 1.0.114) is serving and this DevBuild loaded nothing",
        "the DevBuild message")
    -- a 1.0.114 development core, then a copy with another API version
    T.installMocks(DEV)
    T.loadOldCopy("v1.0.114", "ServingHost")
    local ok, err = pcall(loadCore, { replace = apiVersion(8) })
    T.falsy(ok, "a development 1.0.114 core raises")
    T.truthy(tostring(err):find("Foundry-1.0: a redundant embedded Foundry-1.0 copy was suppressed; the first-loaded copy (API_VERSION 7) is serving and this copy (API_VERSION 8) loaded nothing", 1, true),
        "the redundant copy message: " .. tostring(err))
    -- an equal build
    T.installMocks(DEV)
    T.loadBuild({ build = INCOMING_BUILD, addonName = "ServingHost", files = { "Foundry.lua" }, replace = apiVersion(6) })
    ok, err = pcall(loadCore, {})
    T.falsy(ok, "an equal build raises in a development serving copy")
    T.truthy(tostring(err):find("(API_VERSION 6) is serving and this copy (API_VERSION 7) loaded nothing", 1, true),
        "equal build message: " .. tostring(err))
    T.installMocks("1.0.0")
    T.loadBuild({ build = INCOMING_BUILD, addonName = "ServingHost", version = "1.0.1", files = { "Foundry.lua" } })
    loadCore({ version = DEV })
    T.outputContains("an enabled Foundry-1.0 DevBuild was suppressed", "equal build, release serving")
    -- a takeover is silent, development over development and development over release
    T.installMocks(DEV)
    T.loadBuild({ build = SERVING_BUILD, addonName = "ServingHost", files = { "Foundry.lua" } })
    ok, err = pcall(loadCore, { replace = apiVersion(8) })
    T.truthy(ok, "a takeover raises nothing: " .. tostring(err))
    T.eq(#T.output, 0, "and prints nothing")
    T.installMocks("1.0.0")
    T.loadBuild({ build = SERVING_BUILD, addonName = "ServingHost", version = "1.0.1", files = { "Foundry.lua" } })
    ok, err = pcall(loadCore, { version = DEV, replace = apiVersion(8) })
    T.truthy(ok, "a development takeover of a release core raises nothing: " .. tostring(err))
    T.eq(#T.output, 0, "and prints nothing")
end)

test("a taken-over core leaves the /foundry command with the first copy, which lists the upgraded entry", function()
    local F = serve("current", "dev")
    local command = _G.SlashCmdList.FOUNDRY
    T.eq(type(command), "function", "the first copy registered the command")
    loadCore({ replace = apiVersion(8) })
    T.truthy(rawequal(_G.SlashCmdList.FOUNDRY, command), "the command is the first copy's")
    T.eq(_G.SLASH_FOUNDRY1, "/foundry", "the slash name is unchanged")
    T.output = {}
    command("copies")
    T.outputContains("Foundry: active copy: ServingHost, version dev, API version 8", "the first copy stays the active copy")
    T.outputContains("Foundry: every module comes from the active copy", "no module has moved yet")
    T.outputContains("Foundry: upgraded to: IncomingHost, version dev, API version 8", "the record lists the takeover")
    T.truthy(rawequal(_G.Foundry_1_0, F), "the library table is the same")
end)

test("a copy that fails partway through taking over leaves the version, build and source of the active copy unchanged", function()
    local lines = { "function F:RaiseDevError(message)", "F.API_VERSION = API_VERSION" }
    for _, kind in ipairs({ "current", "layout1" }) do
        for _, mode in ipairs({ "release", "dev" }) do
            for _, line in ipairs(lines) do
                local who = kind .. ", " .. mode .. ", failing before '" .. line .. "': "
                local F = serve(kind, mode)
                local before = {
                    api = F.API_VERSION, build = rawget(F, "_build"), source = rawget(F, "_source"),
                    version = F.VERSION, serving = F.SOURCE,
                }
                local copies = #F._state.copies
                local ok, err = pcall(loadCore, {
                    version = incomingVersion(mode), replace = merge(apiVersion(8), T.plantError(line, "planted failure")),
                })
                T.falsy(ok, who .. "the copy fails")
                T.truthy(tostring(err):find("planted failure", 1, true), who .. "at the planted line: " .. tostring(err))
                T.eq(F.API_VERSION, before.api, who .. "API version")
                T.eq(rawget(F, "_build"), before.build, who .. "build")
                T.eq(rawget(F, "_source"), before.source, who .. "source")
                T.eq(F.VERSION, before.version, who .. "version")
                T.eq(F.SOURCE, before.serving, who .. "serving source")
                T.eq(#F._state.copies, copies, who .. "no entry claims a takeover")
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local LIFECYCLE_API_LINE = "local API_VERSION = 4"

-- Loads the incoming copy's Lifecycle file alone.
local function loadLifecycle(spec)
    spec = spec or {}
    return T.loadBuild({
        build = spec.build or INCOMING_BUILD, addonName = spec.addonName or "IncomingHost",
        version = spec.version, files = { FILE.Lifecycle }, replace = spec.replace,
    })
end

local function setScriptCount()
    local n = 0
    for _, frame in ipairs(T.frames) do n = n + #frame.calls.SetScript end
    return n
end

local function framesRegistering(event)
    local n = 0
    for _, frame in ipairs(T.frames) do
        for _, call in ipairs(frame.calls.RegisterEvent) do
            if call[1] == event then n = n + 1; break end
        end
    end
    return n
end

-- The functions an older copy's relays and still-running code call by name, as
-- unit and path. Older code reaches the newer code only through these names, so
-- neither copy may rename them.
local FROZEN_TARGETS = {
    { "Lifecycle", "_impl.pollTick" },
    { "Lifecycle", "_impl.onEvent" },
    { "DB", "_impl.onLogout" },
    { "Commands", "_impl.Controller.Dispatch" },
    { "List", "_impl.initRow" },
    { "List", "_impl.extent" },
    { "Tooltip", "_impl.dispatch" },
    { "Settings", "_impl.launcherClick" },
    { "Menu", "_impl.generate" },
    { "Window", "_impl.dragStart" },
    { "Window", "_impl.dragStop" },
    -- Private methods and functions that older code still running during a
    -- takeover (an in-flight dispatch, a function a consumer kept) calls by
    -- name through the serving tables.
    { "Lifecycle", "_impl.Controller._fireAddonLoaded" },
    { "Lifecycle", "_impl.Controller._fireLogin" },
    { "Lifecycle", "_impl.Controller._fireLogout" },
    { "Lifecycle", "_impl.Controller._fireUnloading" },
    { "Commands", "_impl.Controller._print" },
    { "Commands", "_impl.Controller._match" },
    { "Commands", "_impl.Controller.PrintHelp" },
    { "Events", "_impl.Controller.Unregister" },
    { "Events", "_impl.Bucket._teardown" },
    { "DB", "_impl.onSavedVariablesTooLarge" },
}

local function resolve(F, unit, path)
    local value = unitTable(F, unit)
    for key in path:gmatch("[^%.]+") do
        if type(value) ~= "table" then return nil end
        value = value[key]
    end
    return value
end

test("every function an older copy's relays or still-running code call by name exists under that name in the layout-1 copy and in the current code", function()
    local copies = {
        { "the layout-1 copy", function() return T.loadOldCopy("layout1", "ServingHost") end },
        { "the current code", function() return T.loadBuild({ build = INCOMING_BUILD }) end },
    }
    for _, copy in ipairs(copies) do
        T.installMocks("@project-version@")
        local F = copy[2]()
        for _, target in ipairs(FROZEN_TARGETS) do
            T.eq(type(resolve(F, target[1], target[2])), "function", copy[1] .. ": " .. target[1] .. "." .. target[2])
        end
    end
end)

local function pack(...) return { n = select("#", ...), ... } end

-- The older dispatch reads two values from each fire method: whether the hook
-- raised, and the error. A fire method with no hook, or on a destroyed
-- controller, returns false; each hook fires once.
test("the older and newer Lifecycle fire methods return whether the hook raised and its error, and fire a hook once", function()
    local PHASES = {
        { fire = "_fireAddonLoaded", register = "OnAddonLoaded" },
        { fire = "_fireLogin", register = "OnLogin" },
        { fire = "_fireLogout", register = "OnLogout" },
        { fire = "_fireUnloading", register = "OnUnloading", arg = true },
    }
    local copies = {
        { "the layout-1 copy", function() return T.loadOldCopy("layout1", "ServingHost") end },
        { "the current code", function() return T.loadBuild({ build = INCOMING_BUILD }) end },
    }
    for _, copy in ipairs(copies) do
        T.installMocks("@project-version@")
        local F = copy[2]()
        for _, phase in ipairs(PHASES) do
            local who = copy[1] .. ", " .. phase.fire .. ": "
            local ctrl = F.Lifecycle:New(nil, "Fire" .. phase.fire)
            T.eq(select("#", ctrl[phase.fire](ctrl)), 1, who .. "no hook returns one value")
            T.eq(ctrl[phase.fire](ctrl), false, who .. "no hook returns false")

            local seen, count = nil, 0
            ctrl[phase.register](ctrl, function(...) count = count + 1; seen = pack(...) end)
            local result = pack(ctrl[phase.fire](ctrl, "closing"))
            T.eq(result[1], false, who .. "a quiet hook returns false")
            T.eq(count, 1, who .. "the hook ran")
            T.eq(seen.n, phase.arg and 2 or 1, who .. "the hook's argument count")
            T.eq(seen[2], phase.arg and "closing" or nil, who .. "the hook's second argument")
            T.eq(ctrl[phase.fire](ctrl), false, who .. "a hook fires once")
            T.eq(count, 1, who .. "and is not run again")

            local other = F.Lifecycle:New(nil, "Raise" .. phase.fire)
            other[phase.register](other, function() error("hook failed", 0) end)
            local raised = pack(other[phase.fire](other))
            T.eq(raised[1], true, who .. "a raising hook returns true")
            T.eq(raised[2], "hook failed", who .. "and its error")
            T.eq(other[phase.fire](other), false, who .. "a raised hook is not run again")
        end
    end
end)

test("a newer Lifecycle takes over with the same dispatcher frame and no SetScript, and the older relay runs the newer event handler once", function()
    for _, kind in ipairs({ "layout1", "current" }) do
        for _, mode in ipairs({ "release", "dev" }) do
            local who = kind .. ", " .. mode .. ": "
            local F = serve(kind, mode)
            local inst = buildInstances(F)
            local L = F.Lifecycle
            local S, I = L._state, L._impl
            -- one controller held for identity, and one logout hook, both made
            -- by the serving copy
            local released, loggedOut = 0, 0
            inst.lifecycle:OnLogout(function() loggedOut = loggedOut + 1 end)
            T.identity.name = nil
            T.loadedAddons["TakeoverHeld"] = true
            local held = L:New(nil, "TakeoverHeld")
            held:OnAddonLoaded(function() released = released + 1 end)
            T.eq(#S.identityHeld, 1, who .. "a controller is held for identity")
            local dispatcher, script = S.dispatcher, S.dispatcher._scripts.OnEvent
            local postLogout, entries = S.postLogout, #S.postLogout
            local setScripts = setScriptCount()

            local errors = loadEach({ build = INCOMING_BUILD, addonName = "IncomingHost", version = incomingVersion(mode) })
            T.eq(next(errors), nil, who .. "the incoming copy raised nothing: " .. firstError(errors))
            T.truthy(rawequal(F.Lifecycle, L), who .. "the module table is the same")
            T.truthy(rawequal(L._state, S) and rawequal(L._impl, I), who .. "state and implementation tables are kept")
            T.truthy(rawequal(S.dispatcher, dispatcher), who .. "the dispatcher frame is the same")
            T.eq(setScriptCount(), setScripts, who .. "no frame logs a SetScript")
            T.eq(framesRegistering("PLAYER_LOGOUT"), 1, who .. "one frame registers the logout event")
            T.truthy(rawequal(dispatcher._scripts.OnEvent, script), who .. "the dispatcher keeps its script")
            if kind == "layout1" then
                T.truthy(isOlderFunction(script), who .. "the script is the older copy's relay")
            end
            T.truthy(rawequal(S.postLogout, postLogout) and #postLogout == entries, who .. "the logout list is kept")
            T.eq(#S.identityHeld, 1, who .. "the held controller is still held")
            T.eq(L.API_VERSION, 4, who .. "API version")
            T.eq(L._build, INCOMING_BUILD, who .. "build is the newer number")
            T.eq(L._source, "IncomingHost", who .. "the newer copy's addon is named")
            T.eq(L._layoutVersion, 1, who .. "layout version")

            local newer = I.onEvent
            T.eq(buildOf(newer), tostring(INCOMING_BUILD), who .. "the event handler is the newer copy's")
            local calls = 0
            I.onEvent = function(...) calls = calls + 1; return newer(...) end
            T.identity.name = "Tester"
            T.Fire(dispatcher, "UNIT_NAME_UPDATE", "player")
            I.onEvent = newer
            T.eq(calls, 1, who .. "the newer event handler runs once")
            T.eq(released, 1, who .. "the held controller is released by the newer code")
            T.eq(L._identityResolvedBy, "UNIT_NAME_UPDATE", who .. "released on the name update")
            T.Fire(dispatcher, "PLAYER_LOGOUT")
            T.eq(loggedOut, 1, who .. "a logout hook registered before the takeover runs once")
            T.eq(#T.output, 0, who .. "nothing is printed")
        end
    end
end)

test("a Lifecycle taken over keeps how the player's identity was resolved and whether a surname lagged", function()
    for _, kind in ipairs({ "layout1", "current" }) do
        local F = serve(kind, "dev")
        F.Lifecycle._identityResolvedBy = "POLL"
        F.Lifecycle._surnameLagObserved = true
        loadLifecycle()
        T.eq(F.Lifecycle._build, INCOMING_BUILD, kind .. ": the newer copy upgraded")
        T.eq(F.Lifecycle._identityResolvedBy, "POLL", kind .. ": how identity was resolved")
        T.eq(F.Lifecycle._surnameLagObserved, true, kind .. ": a surname lag")
    end
end)

test("a newer Lifecycle taking over before any dispatcher exists makes no SetScript, and the next New creates exactly one frame", function()
    for _, kind in ipairs({ "layout1", "current" }) do
        for _, mode in ipairs({ "release", "dev" }) do
            local who = kind .. ", " .. mode .. ": "
            local F = serve(kind, mode)
            local S = F.Lifecycle._state
            T.eq(S.dispatcher, nil, who .. "no dispatcher yet")
            local frames, setScripts = #T.frames, setScriptCount()
            loadLifecycle({ version = incomingVersion(mode) })
            T.eq(F.Lifecycle._build, INCOMING_BUILD, who .. "the newer copy upgraded")
            T.eq(#T.frames, frames, who .. "no frame is made")
            T.eq(setScriptCount(), setScripts, who .. "no SetScript")
            T.eq(S.dispatcher, nil, who .. "still no dispatcher")
            F.Lifecycle:New(nil, "AfterTakeover")
            T.eq(#T.frames, frames + 1, who .. "the next New creates one frame")
            T.truthy(S.dispatcher ~= nil, who .. "the dispatcher exists")
            T.eq(framesRegistering("PLAYER_LOGOUT"), 1, who .. "one frame registers the logout event")
            T.eq(buildOf(S.dispatcher._scripts.OnEvent), tostring(INCOMING_BUILD), who .. "its script is the newer copy's")
        end
    end
end)

local function setState(key, value)
    return function(_, unitTbl) unitTbl._state[key] = value end
end

local LIFECYCLE_PROOFS = {
    { name = "a logout list that is not a table", inject = setState("postLogout", false),
        outcome = "refused: logout list", refused = true },
    { name = "a Lifecycle whose login already fired", inject = setState("loginFired", true), outcome = "after login" },
    { name = "a dispatcher that is not a table", inject = setState("dispatcher", "frame"),
        outcome = "refused: shape", refused = true },
    { name = "a Lifecycle with no state table", inject = function(_, unitTbl) unitTbl._state = nil end,
        outcome = "refused: shape", refused = true },
    { name = "a Lifecycle with no implementation table", inject = function(_, unitTbl) unitTbl._impl = nil end,
        outcome = "refused: shape", refused = true },
    { name = "a Lifecycle with no controller implementation",
        inject = function(_, unitTbl) unitTbl._impl.Controller = nil end, outcome = "refused: shape", refused = true },
}
for _, key in ipairs({ "byAddonName", "ownedNames", "loginControllers", "unloadingControllers", "identityHeld" }) do
    LIFECYCLE_PROOFS[#LIFECYCLE_PROOFS + 1] = {
        name = "a state table " .. key .. " that is not a table", inject = setState(key, true),
        outcome = "refused: shape", refused = true,
    }
end
for _, key in ipairs({ "unloadingSupported", "loginFired", "identityWatching", "pollScheduled", "identityStopped",
    "devNoticePrinted", "surnameSettled" }) do
    LIFECYCLE_PROOFS[#LIFECYCLE_PROOFS + 1] = {
        name = "a state flag " .. key .. " that is not a boolean", inject = setState(key, {}),
        outcome = "refused: shape", refused = true,
    }
end

test("a newer Lifecycle declines a serving Lifecycle whose state it cannot adopt, changes nothing, and raises only in a development serving copy for a refusal", function()
    for _, case in ipairs(LIFECYCLE_PROOFS) do
        for _, kind in ipairs({ "current", "layout1" }) do
            runCase({
                name = "a serving copy with " .. case.name, inject = case.inject, outcome = case.outcome,
                refused = case.refused, units = { "Lifecycle" },
            }, kind)
        end
    end
end)

test("a Lifecycle that fails partway through taking over leaves the version, build and source of the active copy unchanged", function()
    local lines = { "local Lifecycle = served or {}", "local function ensureDispatcher()", "Lifecycle.API_VERSION = API_VERSION" }
    for _, kind in ipairs({ "current", "layout1" }) do
        for _, mode in ipairs({ "release", "dev" }) do
            for _, line in ipairs(lines) do
                local who = kind .. ", " .. mode .. ", failing before '" .. line .. "': "
                local F = serve(kind, mode)
                local L = F.Lifecycle
                local before = { api = rawget(L, "API_VERSION"), build = rawget(L, "_build"), source = rawget(L, "_source") }
                local ok, err = pcall(loadLifecycle, {
                    version = incomingVersion(mode),
                    replace = merge({ [LIFECYCLE_API_LINE] = "local API_VERSION = 5" }, T.plantError(line, "planted failure")),
                })
                T.falsy(ok, who .. "the copy fails")
                T.truthy(tostring(err):find("planted failure", 1, true), who .. "at the planted line: " .. tostring(err))
                T.truthy(rawequal(F.Lifecycle, L), who .. "the module is the same table")
                T.eq(rawget(L, "API_VERSION"), before.api, who .. "API version")
                T.eq(rawget(L, "_build"), before.build, who .. "build")
                T.eq(rawget(L, "_source"), before.source, who .. "source")
            end
        end
    end
end)

test("the older and newer copies return the same player identity in every mocked identity state", function()
    local STATES = {
        { name = "a plain realm", identity = { name = "Tester", realm = "Test Realm" } },
        { name = "region-unique names with a surname", regional = true,
            identity = { name = "Tester", realm = "Test Realm", surname = "Smith" } },
        { name = "region-unique names with the surname unsettled", regional = true,
            identity = { name = "Tester", realm = "Test Realm" } },
        { name = "region-unique names with the surname settled absent", regional = true, settled = true,
            identity = { name = "Tester", realm = "Test Realm" } },
        { name = "a missing name", identity = { realm = "Test Realm" } },
        { name = "a missing realm", identity = { name = "Tester" } },
    }
    T.installMocks("@project-version@")
    local F = T.loadOldCopy("layout1", "ServingHost")
    local older = F.Lifecycle._PlayerIdentity
    loadLifecycle()
    local newer = F.Lifecycle._PlayerIdentity
    T.truthy(isOlderFunction(older), "the first is the older copy's")
    T.eq(buildOf(newer), tostring(INCOMING_BUILD), "the second is the newer copy's")
    local S = F.Lifecycle._state
    for _, state in ipairs(STATES) do
        T.identity = state.identity
        T.SetRegional(state.regional)
        S.surnameSettled = state.settled == true
        local a, b = pack(older()), pack(newer())
        T.eq(b.n, a.n, state.name .. ": number of returns")
        for i = 1, a.n do
            T.eq(b[i], a[i], state.name .. ": return " .. i)
        end
    end
end)

--------------------------------------------------------------------------------
-- DB
--------------------------------------------------------------------------------

local DB_API_LINE = "local API_VERSION = 2"

local LIFECYCLE_AND_BEFORE = { "Foundry.lua", "Modules/Commands.lua", "Modules/Events.lua", "Modules/Lifecycle.lua" }
local AFTER_DB = { "Modules/List.lua", "Modules/Settings.lua", "Modules/Tooltip.lua", "Modules/Menu.lua", "Modules/Window.lua" }

local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deepCopy(v) end
    return out
end

-- The first path at which two values differ, or nil.
local function firstDifference(a, b, path)
    path = path or "root"
    if type(a) ~= "table" or type(b) ~= "table" then
        if a ~= b then return path .. ": " .. tostring(a) .. " vs " .. tostring(b) end
        return nil
    end
    for k, v in pairs(a) do
        local found = firstDifference(v, b[k], path .. "." .. tostring(k))
        if found then return found end
    end
    for k, v in pairs(b) do
        if a[k] == nil then return path .. "." .. tostring(k) .. ": nil vs " .. tostring(v) end
    end
    return nil
end

local function timesListed(list, value)
    local n = 0
    for i = 1, #list do
        if rawequal(list[i], value) then n = n + 1 end
    end
    return n
end

local function callCount(frame, method)
    return #(frame.calls[method] or {})
end

local function fireLogout(F)
    T.Fire(F.Lifecycle._state.dispatcher, "PLAYER_LOGOUT")
end

-- Loads the incoming copy's DB file alone.
local function loadDB(spec)
    spec = spec or {}
    return T.loadBuild({
        build = INCOMING_BUILD, addonName = "IncomingHost", version = spec.version,
        files = { FILE.DB }, replace = spec.replace,
    })
end

-- Loads the whole incoming copy, counting the calls DB makes to Lifecycle's
-- post-logout seam while its own file loads. Returns that count and the errors.
local function loadOverWatchingLogoutSeam(F, mode)
    local version = incomingVersion(mode)
    local errors = loadEach({ build = INCOMING_BUILD, addonName = "IncomingHost", version = version,
        files = LIFECYCLE_AND_BEFORE })
    local seamCalls = slots.countCalls(F.Lifecycle, "_RegisterPostLogout", function()
        local ok, err = pcall(loadDB, { version = version })
        if not ok then errors[FILE.DB] = tostring(err) end
    end)
    for rel, err in pairs(loadEach({ build = INCOMING_BUILD, addonName = "IncomingHost", version = version,
        files = AFTER_DB })) do
        errors[rel] = err
    end
    return seamCalls, errors
end

test("a newer DB takes over with the same logout entry, stores, saved data and size-warning controller, swapping only the handlers they hold", function()
    for _, kind in ipairs({ "layout1", "current" }) do
        for _, mode in ipairs({ "release", "dev" }) do
            local who = kind .. ", " .. mode .. ": "
            local F = serve(kind, mode)
            local inst = buildInstances(F)
            local D = F.DB
            local S, I = D._state, D._impl
            local plain = D:New({ name = "TakeoverAddon", sv = "TestPlainDB", defaultProfile = true })
            inst.db.profile.b = 2
            inst.db.global.g = 5
            plain.global.kept = true
            local postLogout = F.Lifecycle._state.postLogout
            local entries, entry = #postLogout, S.postLogoutEntry
            T.eq(timesListed(postLogout, entry), 1, who .. "the serving copy registered one entry")
            local stores, storeList = S.stores, {}
            for i = 1, #stores do storeList[i] = stores[i] end
            local controllerStore, byController = S.controllerStore, {}
            for c, store in pairs(controllerStore) do byController[c] = store end
            local records = {}
            for i = 1, #stores do
                local fields = {}
                for k, v in pairs(stores[i]) do fields[k] = v end
                records[i] = fields
            end
            local saved = { TestDB = deepCopy(_G.TestDB), TestPlainDB = deepCopy(_G.TestPlainDB) }
            local savedTables = { TestDB = _G.TestDB, TestPlainDB = _G.TestPlainDB }
            local warn = S.sizeWarningEvents
            local warnFrame, warnHandlers = warn._frame, warn._handlers
            local registers, unregisters = callCount(warnFrame, "RegisterEvent"), callCount(warnFrame, "UnregisterEvent")
            local impl = { Controller = I.Controller, controllerMeta = I.controllerMeta }

            local seamCalls, errors = loadOverWatchingLogoutSeam(F, mode)
            T.eq(next(errors), nil, who .. "the incoming copy raised nothing: " .. firstError(errors))
            T.eq(D._build, INCOMING_BUILD, who .. "DB upgraded")
            T.eq(D._source, "IncomingHost", who .. "the newer copy's addon is named")
            T.eq(D.API_VERSION, 2, who .. "API version")
            T.eq(D._layoutVersion, 1, who .. "layout version")
            T.truthy(rawequal(F.DB, D) and rawequal(D._state, S) and rawequal(D._impl, I),
                who .. "the module, state and implementation tables are kept")
            T.truthy(rawequal(I.Controller, impl.Controller) and rawequal(I.controllerMeta, impl.controllerMeta),
                who .. "the controller tables are kept")

            T.eq(seamCalls, 0, who .. "the post-logout seam is not called")
            T.truthy(rawequal(F.Lifecycle._state.postLogout, postLogout), who .. "the logout list is kept")
            T.eq(#postLogout, entries, who .. "the logout list has as many entries as before")
            T.truthy(rawequal(S.postLogoutEntry, entry), who .. "the logout entry is the same function")
            T.eq(timesListed(postLogout, entry), 1, who .. "and is listed once")
            if kind == "layout1" then
                T.truthy(isOlderFunction(entry), who .. "the entry is the older copy's relay")
            end

            T.truthy(rawequal(S.stores, stores) and #stores == #storeList, who .. "the store list is kept")
            for i = 1, #storeList do
                T.truthy(rawequal(stores[i], storeList[i]), who .. "store " .. i .. " is kept")
            end
            T.truthy(rawequal(S.controllerStore, controllerStore), who .. "the controller-store map is kept")
            local mapped = 0
            for c, store in pairs(controllerStore) do
                mapped = mapped + 1
                T.truthy(rawequal(byController[c], store), who .. "a controller keeps its store")
            end
            local mappedBefore = 0
            for _ in pairs(byController) do mappedBefore = mappedBefore + 1 end
            T.eq(mapped, mappedBefore, who .. "the controller-store map has as many entries")
            for i = 1, #stores do
                for k, v in pairs(records[i]) do
                    if k ~= "onMismatch" then
                        T.truthy(rawequal(stores[i][k], v), who .. "store " .. i .. " keeps " .. k)
                    end
                end
                for k in pairs(stores[i]) do
                    T.truthy(records[i][k] ~= nil, who .. "store " .. i .. " gains no field " .. k)
                end
                T.truthy(stores[i].onMismatch ~= records[i].onMismatch, who .. "store " .. i .. " has a new mismatch handler")
                T.eq(buildOf(stores[i].onMismatch), tostring(INCOMING_BUILD), who .. "store " .. i .. "'s mismatch handler is the newer copy's")
            end
            for name, value in pairs(saved) do
                T.truthy(rawequal(_G[name], savedTables[name]), who .. name .. " is the same table")
                T.eq(firstDifference(value, _G[name]), nil, who .. name .. " is unchanged")
            end

            T.truthy(rawequal(S.sizeWarningEvents, warn) and rawequal(warn._handlers, warnHandlers),
                who .. "the size-warning controller is kept")
            T.truthy(rawequal(warnHandlers.SAVED_VARIABLES_TOO_LARGE, I.onSavedVariablesTooLarge),
                who .. "the size-warning handler is the serving implementation's")
            T.eq(buildOf(I.onSavedVariablesTooLarge), tostring(INCOMING_BUILD), who .. "which is the newer copy's")
            T.eq(callCount(warnFrame, "RegisterEvent"), registers, who .. "no event is registered")
            T.eq(callCount(warnFrame, "UnregisterEvent"), unregisters, who .. "no event is unregistered")

            T.eq(buildOf(I.controllerMeta.__index), tostring(INCOMING_BUILD), who .. "the db lookup is the newer copy's")
            local value
            local lookups = slots.countCalls(I.controllerMeta, "__index", function() value = inst.db.profile end)
            T.eq(lookups, 1, who .. "db.profile on a db made before the takeover reads through the newer lookup")
            T.eq(value.b, 2, who .. "and finds the value written before")

            local newer = I.onLogout
            T.eq(buildOf(newer), tostring(INCOMING_BUILD), who .. "the logout strip is the newer copy's")
            local strips = slots.countCalls(I, "onLogout", function() fireLogout(F) end)
            T.eq(strips, 1, who .. "the logout event runs the newer strip once")
            local profile = _G.TestDB.profiles.Default
            T.eq(profile.a, nil, who .. "a default-equal value is stripped")
            T.eq(profile.b, 2, who .. "a set value is kept")
            T.eq(_G.TestPlainDB.global.kept, true, who .. "a db without defaults keeps its data")
            T.eq(#T.output, 0, who .. "nothing is printed")
        end
    end
end)

test("a newer DB over a serving DB with no db yet takes over, and the first New after it registers exactly one logout entry", function()
    for _, kind in ipairs({ "layout1", "current" }) do
        for _, mode in ipairs({ "release", "dev" }) do
            local who = kind .. ", " .. mode .. ": "
            local F = serve(kind, mode)
            local S = F.DB._state
            T.eq(S.postLogoutRegistered, false, who .. "nothing registered yet")
            local seamCalls, errors = loadOverWatchingLogoutSeam(F, mode)
            T.eq(next(errors), nil, who .. "the incoming copy raised nothing: " .. firstError(errors))
            T.eq(F.DB._build, INCOMING_BUILD, who .. "DB upgraded")
            T.eq(seamCalls, 0, who .. "the post-logout seam is not called")
            local postLogout = F.Lifecycle._state.postLogout
            local entries = #postLogout
            T.loadedAddons["TakeoverAddon"] = true
            local db = F.DB:New({ name = "TakeoverAddon", sv = "TestDB", defaultProfile = true,
                defaults = { profile = { a = 1 } } })
            T.eq(#postLogout, entries + 1, who .. "the first New adds one entry")
            T.eq(timesListed(postLogout, S.postLogoutEntry), 1, who .. "and it is the logout entry")
            T.eq(buildOf(S.postLogoutEntry), tostring(INCOMING_BUILD), who .. "made by the newer copy")
            T.loadedAddons["TakeoverOther"] = true
            F.DB:New({ name = "TakeoverOther", sv = "TestOtherDB", defaultProfile = true })
            T.eq(#postLogout, entries + 1, who .. "a second New adds none")
            db.profile.b = 2
            local strips = slots.countCalls(F.DB._impl, "onLogout", function() fireLogout(F) end)
            T.eq(strips, 1, who .. "the strip runs once at logout")
            T.eq(_G.TestDB.profiles.Default.a, nil, who .. "a default-equal value is stripped")
        end
    end
end)

local function makeDB(F)
    T.loadedAddons["TakeoverAddon"] = true
    return F.DB:New({ name = "TakeoverAddon", sv = "TestDB", defaultProfile = true, defaults = { profile = { a = 1 } } })
end

local function withDB(change)
    return function(F, unitTbl)
        makeDB(F)
        change(F, unitTbl, unitTbl._state)
    end
end

local DB_PROOFS = {
    { name = "a logout entry listed twice", outcome = "refused: logout entry",
        inject = withDB(function(F, _, S)
            local list = F.Lifecycle._state.postLogout
            list[#list + 1] = S.postLogoutEntry
        end) },
    { name = "a logout entry missing from the list", outcome = "refused: logout entry",
        inject = withDB(function(F, _, S)
            local list = F.Lifecycle._state.postLogout
            for i = #list, 1, -1 do
                if rawequal(list[i], S.postLogoutEntry) then table.remove(list, i) end
            end
        end) },
    { name = "a logout entry listed but not recorded as registered", outcome = "refused: logout entry",
        inject = withDB(function(_, _, S) S.postLogoutRegistered = false end) },
    { name = "a controller whose store is not in the store list", outcome = "refused: stores",
        inject = withDB(function(_, _, S) S.controllerStore[{}] = {} end) },
    { name = "a store with a field it is never built with", outcome = "refused: store record",
        inject = withDB(function(_, _, S) S.stores[1].extra = true end) },
    { name = "a store whose destroyed flag is not a boolean", outcome = "refused: store record",
        inject = withDB(function(_, _, S) S.stores[1].destroyed = "no" end) },
    { name = "a store with no mismatch handler", outcome = "refused: store record",
        inject = withDB(function(_, _, S) S.stores[1].onMismatch = nil end) },
    { name = "a store list holding something other than a store", outcome = "refused: store record",
        inject = withDB(function(_, _, S) S.stores[#S.stores + 1] = "store" end) },
    { name = "a size-warning handler that is not the serving one", outcome = "refused: size warning",
        inject = withDB(function(_, _, S) S.sizeWarningEvents._handlers.SAVED_VARIABLES_TOO_LARGE = function() end end) },
    { name = "an Events with layout 2 while a size-warning controller exists", outcome = "refused: size warning",
        inject = withDB(function(F) rawset(F.Events, "_layoutVersion", 2) end) },
    { name = "a Lifecycle with no layout", outcome = "refused: lifecycle layout",
        inject = function(F) rawset(F.Lifecycle, "_layoutVersion", nil) end },
    { name = "a Lifecycle whose logout list is not a table", outcome = "refused: lifecycle layout",
        inject = function(F) F.Lifecycle._state.postLogout = false end },
    { name = "a DB with no state table", outcome = "refused: shape",
        inject = function(_, unitTbl) unitTbl._state = nil end },
    { name = "a DB with no controller lookup table", outcome = "refused: shape",
        inject = function(_, unitTbl) unitTbl._impl.controllerMeta = nil end },
    { name = "a store list that is not a table", outcome = "refused: shape",
        inject = function(_, unitTbl) unitTbl._state.stores = "stores" end },
    { name = "a registered flag that is not a boolean", outcome = "refused: shape",
        inject = function(_, unitTbl) unitTbl._state.postLogoutRegistered = 1 end },
}

test("a newer DB declines a serving DB whose logout entry, stores or size warning it cannot adopt, changes nothing, and raises only in a development serving copy", function()
    for _, case in ipairs(DB_PROOFS) do
        for _, kind in ipairs({ "current", "layout1" }) do
            runCase({
                name = "a serving copy with " .. case.name, inject = case.inject, outcome = case.outcome,
                refused = true, units = { "DB" },
            }, kind)
        end
    end
end)

test("a newer DB taking over from inside an older db's migration leaves that db working, with one logout entry and one strip", function()
    for _, kind in ipairs({ "layout1", "current" }) do
        for _, mode in ipairs({ "release", "dev" }) do
            local who = kind .. ", " .. mode .. ": "
            local F = serve(kind, mode)
            local postLogout = F.Lifecycle._state.postLogout
            local entries = #postLogout
            T.loadedAddons["MigrateAddon"] = true
            _G.MigrateDB = { global = { version = 1, old = true } }
            local migrations, errors = 0, nil
            local db = F.DB:New({
                name = "MigrateAddon", sv = "MigrateDB", defaultProfile = true,
                defaults = { global = { d = 1 }, profile = { a = 1 } },
                schema = { version = 2, key = "global.version", migrate = function(c, from)
                    migrations = migrations + 1
                    errors = loadEach({ build = INCOMING_BUILD, addonName = "IncomingHost", version = incomingVersion(mode) })
                    c.global.migratedFrom = from
                end },
            })
            T.eq(next(errors), nil, who .. "the incoming copy raised nothing: " .. firstError(errors))
            local D = F.DB
            T.eq(D._build, INCOMING_BUILD, who .. "DB upgraded during the migration")
            T.eq(migrations, 1, who .. "the migration ran once")
            T.truthy(db ~= nil, who .. "New returned a db")
            T.eq(db.global.migratedFrom, 1, who .. "the migration saw the stored version")
            T.eq(db.global.version, 2, who .. "the stamp is written")
            T.eq(db.global.d, 1, who .. "defaults apply")
            db.profile.b = 2
            T.eq(#postLogout, entries + 1, who .. "one logout entry was added")
            T.eq(timesListed(postLogout, D._state.postLogoutEntry), 1, who .. "and it is the logout entry")
            T.truthy(rawequal(D._state.sizeWarningEvents._handlers.SAVED_VARIABLES_TOO_LARGE, D._impl.onSavedVariablesTooLarge),
                who .. "the size warning is the serving handler")
            T.eq(buildOf(D._impl.onSavedVariablesTooLarge), tostring(INCOMING_BUILD), who .. "which is the newer copy's")
            local strips = slots.countCalls(D._impl, "onLogout", function() fireLogout(F) end)
            T.eq(strips, 1, who .. "the strip runs once at logout")
            T.eq(_G.MigrateDB.global.d, nil, who .. "a default-equal global is stripped")
            T.eq(_G.MigrateDB.global.version, 2, who .. "the stamp is kept")
            T.eq(_G.MigrateDB.profiles.Default.b, 2, who .. "a set value is kept")
            T.eq(#T.output, 0, who .. "nothing is printed")
        end
    end
end)

-- Every committed saved-data fixture, with its global name.
local FIXTURES = {
    { "bawrspam_sanitized.lua", "BawrSpamDB" },
    { "downgrade_stamped.lua", "SyntheticDB" },
    { "empty.lua", "SyntheticDB" },
    { "empty_profile_materialized.lua", "SyntheticDB" },
    { "homestead_sanitized.lua", "HomesteadDB" },
    { "malformed_char_bucket.lua", "SyntheticDB" },
    { "malformed_profile_entry.lua", "SyntheticDB" },
    { "malformed_profilekeys_entry.lua", "SyntheticDB" },
    { "malformed_profilekeys_nontable.lua", "SyntheticDB" },
    { "malformed_sv_nontable.lua", "SyntheticDB" },
}

local PARITY_DEFAULTS = {
    profile = { a = 1, flag = true, nested = { on = true, size = 3 } },
    char = { c = 0, seen = {} },
    global = { g = 1, list = { x = 1 } },
}

-- One session over a fixture: a db is made, read and written, then the player
-- logs out. how is "older" (the layout-1 copy alone), "taken over" (the
-- layout-1 copy makes the db, then the newer copy takes over before the writes)
-- or "newer" (the current code alone). Returns what the session left behind.
local function sessionOver(file, globalName, how)
    T.installMocks("1.0.0")
    local F
    if how == "newer" then
        F = T.loadBuild({ build = INCOMING_BUILD, addonName = "ServingHost", version = "1.0.1" })
    else
        F = T.loadOldCopy("layout1", "ServingHost", "1.0.1")
    end
    _G[globalName] = deepCopy(T.loadFixture(T.testsDir .. "/DB/fixtures/" .. file)[globalName])
    T.loadedAddons["ParityAddon"] = true
    local ok, db = pcall(F.DB.New, F.DB, {
        name = "ParityAddon", sv = globalName, defaultProfile = true, defaults = deepCopy(PARITY_DEFAULTS),
    })
    if how == "taken over" then
        local errors = loadEach({ build = INCOMING_BUILD, addonName = "IncomingHost", version = "1.0.2" })
        T.eq(next(errors), nil, file .. ": the incoming copy raised nothing: " .. firstError(errors))
        T.eq(F.DB._build, INCOMING_BUILD, file .. ": DB upgraded")
    end
    if ok then
        local profile, char, global = db.profile, db.char, db.global
        profile.a = 1
        profile.extra = 5
        if type(profile.nested) == "table" then profile.nested.size = 4 end
        char.c = 0
        char.level = 10
        global.g = 2
        local _ = db.sv
    end
    if F.Lifecycle._state.dispatcher then fireLogout(F) end
    return { ok = ok, err = not ok and tostring(db) or nil, saved = deepCopy(_G[globalName]),
        output = table.concat(T.output, "\n") }
end

test("the older and newer copies give the same saved file after applying and stripping defaults on each saved-data fixture", function()
    for _, fixture in ipairs(FIXTURES) do
        local file, globalName = fixture[1], fixture[2]
        local older = sessionOver(file, globalName, "older")
        for _, how in ipairs({ "taken over", "newer" }) do
            local got = sessionOver(file, globalName, how)
            local who = file .. ", " .. how .. ": "
            T.eq(got.ok, older.ok, who .. "the db is made exactly when the older copy makes it")
            T.eq(got.err, older.err, who .. "the same refusal")
            T.eq(firstDifference(older.saved, got.saved), nil, who .. "the same saved file")
            T.eq(got.output, older.output, who .. "the same output")
        end
    end
end)

test("a handler the newer copy writes into an events controller is called with the event name first, whether Events stays older or is taken over too", function()
    local withoutEvents = {}
    for _, rel in ipairs(T.FOUNDRY_FILES) do
        if rel ~= FILE.Events then withoutEvents[#withoutEvents + 1] = rel end
    end
    for _, kind in ipairs({ "layout1", "current" }) do
        for _, events in ipairs({ "older", "newer" }) do
            local who = kind .. ", Events " .. events .. ": "
            local F = serve(kind, "release")
            local inst = buildInstances(F)
            local calls = {}
            inst.db:OnSavedVariablesTooLarge(function(...) calls[#calls + 1] = { ... } end)
            local olderNew = F.Events.New
            local errors = loadEach({
                build = INCOMING_BUILD, addonName = "IncomingHost", version = "1.0.2",
                files = events == "older" and withoutEvents or nil,
            })
            T.eq(next(errors), nil, who .. "the incoming copy raised nothing: " .. firstError(errors))
            T.eq(F.DB._build, INCOMING_BUILD, who .. "DB upgraded")
            if events == "older" then
                T.truthy(rawequal(F.Events.New, olderNew), who .. "Events stays the older copy's")
            else
                T.truthy(F.Events.New ~= olderNew, who .. "Events is the newer copy's")
            end
            local warn = F.DB._state.sizeWarningEvents
            T.eq(buildOf(warn._handlers.SAVED_VARIABLES_TOO_LARGE), tostring(INCOMING_BUILD), who .. "the slot holds the newer handler")
            T.Fire(warn._frame, "SAVED_VARIABLES_TOO_LARGE", "TakeoverAddon")
            T.eq(#calls, 1, who .. "the db's size-warning handler runs once")
            T.truthy(rawequal(calls[1][1], inst.db), who .. "with the db")
            T.eq(calls[1][2], "TakeoverAddon", who .. "the addon name")
            T.eq(calls[1][3], "TestDB", who .. "and the saved-variable name")
            T.outputContains("DB: addon 'TakeoverAddon' SavedVariables globals 'TestDB' were too large", who .. "the warning is printed")
        end
    end
end)

test("a DB that fails partway through taking over leaves the version, build and source of the active copy unchanged", function()
    local lines = { "local DB = served or {}", "local function onLogout()", "if takingOver then", "DB.API_VERSION = API_VERSION" }
    for _, kind in ipairs({ "current", "layout1" }) do
        for _, mode in ipairs({ "release", "dev" }) do
            for _, line in ipairs(lines) do
                local who = kind .. ", " .. mode .. ", failing before '" .. line .. "': "
                local F = serve(kind, mode)
                local D = F.DB
                local before = { api = rawget(D, "API_VERSION"), build = rawget(D, "_build"), source = rawget(D, "_source") }
                local ok, err = pcall(loadDB, {
                    version = incomingVersion(mode),
                    replace = merge({ [DB_API_LINE] = "local API_VERSION = 3" }, T.plantError(line, "planted failure")),
                })
                T.falsy(ok, who .. "the copy fails")
                T.truthy(tostring(err):find("planted failure", 1, true), who .. "at the planted line: " .. tostring(err))
                T.truthy(rawequal(F.DB, D), who .. "the module is the same table")
                T.eq(rawget(D, "API_VERSION"), before.api, who .. "API version")
                T.eq(rawget(D, "_build"), before.build, who .. "build")
                T.eq(rawget(D, "_source"), before.source, who .. "source")
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- Events and Commands
--------------------------------------------------------------------------------

local MODULE_API_LINE = "local API_VERSION = 2"

-- Loads the incoming copy's file for one module alone.
local function loadModule(unit, spec)
    spec = spec or {}
    return T.loadBuild({
        build = INCOMING_BUILD, addonName = "IncomingHost", version = spec.version,
        files = { FILE[unit] }, replace = spec.replace,
    })
end

local CLIENT_CALLS = { "RegisterEvent", "UnregisterEvent", "RegisterUnitEvent", "UnregisterAllEvents", "SetScript" }

-- Per frame the library made, how many of each client call it has logged.
local function clientCalls()
    local log = {}
    for i, frame in ipairs(T.frames) do
        local counts = {}
        for _, method in ipairs(CLIENT_CALLS) do counts[method] = #(frame.calls[method] or {}) end
        log[i] = counts
    end
    return log
end

local function firstCallDifference(before, after)
    if #before ~= #after then return "frames: " .. #before .. " before, " .. #after .. " after" end
    for i = 1, #before do
        for _, method in ipairs(CLIENT_CALLS) do
            if before[i][method] ~= after[i][method] then
                return "frame " .. i .. " " .. method .. ": " .. before[i][method] .. " before, " .. after[i][method] .. " after"
            end
        end
    end
    return nil
end

local function withInstances(change)
    return function(F, unitTbl) change(F, unitTbl, buildInstances(F)) end
end

test("a newer Events takes over with the same controllers and frames, rebuilds the once closures and the bucket fire functions, and makes no client call", function()
    for _, kind in ipairs({ "layout1", "current" }) do
        for _, mode in ipairs({ "release", "dev" }) do
            local who = kind .. ", " .. mode .. ": "
            local F = serve(kind, mode)
            local inst = buildInstances(F)
            local E = F.Events
            local S, I = E._state, E._impl
            local c = inst.events
            local frame, handlers = c._frame, c._handlers
            local plain, onceRuns, bucketRuns = {}, 0, 0
            c:Register("TAKEOVER_PLAIN", function(...) plain[#plain + 1] = { ... } end)
            c:RegisterOnce("TAKEOVER_ONCE_TWO", function() onceRuns = onceRuns + 1 end)
            local bucket = c:RegisterBucket({
                events = { "TAKEOVER_BUCKET_TWO", "TAKEOVER_BUCKET_THREE" }, interval = 5,
                handler = function() bucketRuns = bucketRuns + 1 end,
            })
            T.Fire(frame, "TAKEOVER_BUCKET_TWO")
            local window = bucket._timer
            T.truthy(window ~= nil, who .. "a window is open before the takeover")
            local script = frame._scripts.OnEvent
            local oldOnce, oldBucket = handlers.TAKEOVER_ONCE_TWO, handlers.TAKEOVER_BUCKET_TWO
            local oldFirstOnce, oldFirstBucket = handlers.TAKEOVER_ONCE, handlers.TAKEOVER_BUCKET
            local consumerOnce = c._onceHandlers.TAKEOVER_ONCE_TWO
            local impl = { Controller = I.Controller, Bucket = I.Bucket }
            local before, timers = clientCalls(), #T.timers

            local ok, err = pcall(loadModule, "Events", { version = incomingVersion(mode) })
            T.truthy(ok, who .. "the incoming Events raised nothing: " .. tostring(err))
            T.eq(E._build, INCOMING_BUILD, who .. "Events upgraded")
            T.eq(E._source, "IncomingHost", who .. "the newer copy's addon is named")
            T.eq(E.API_VERSION, 2, who .. "API version")
            T.truthy(rawequal(F.Events, E) and rawequal(E._state, S) and rawequal(E._impl, I),
                who .. "the module, state and implementation tables are kept")
            T.truthy(rawequal(I.Controller, impl.Controller) and rawequal(I.Bucket, impl.Bucket),
                who .. "the controller and bucket tables are kept")
            T.truthy(rawequal(getmetatable(c), I.Controller) and rawequal(getmetatable(bucket), I.Bucket),
                who .. "controllers and buckets made before keep serving through the same tables")
            T.eq(buildOf(I.Controller.Register), tostring(INCOMING_BUILD), who .. "Register is the newer copy's")
            T.eq(buildOf(I.Bucket.Cancel), tostring(INCOMING_BUILD), who .. "Cancel is the newer copy's")
            T.truthy(S.instances[c], who .. "the controller is still listed")

            T.eq(firstCallDifference(before, clientCalls()), nil, who .. "no client call is made")
            T.eq(#T.timers, timers, who .. "no timer is made")
            T.truthy(rawequal(c._handlers, handlers), who .. "the handler table is kept")
            T.truthy(rawequal(frame._scripts.OnEvent, script), who .. "the frame keeps its script")
            if kind == "layout1" then
                T.truthy(isOlderFunction(script), who .. "which is the older copy's closure")
            end
            T.truthy(handlers.TAKEOVER_ONCE_TWO ~= oldOnce and handlers.TAKEOVER_ONCE ~= oldFirstOnce,
                who .. "each once closure is replaced")
            T.eq(buildOf(handlers.TAKEOVER_ONCE_TWO), tostring(INCOMING_BUILD), who .. "the once closure is the newer copy's")
            T.eq(buildOf(handlers.TAKEOVER_ONCE), tostring(INCOMING_BUILD), who .. "and so is the first one")
            T.truthy(rawequal(c._onceHandlers.TAKEOVER_ONCE_TWO, consumerOnce), who .. "the consumer handler is kept")
            T.truthy(handlers.TAKEOVER_BUCKET_TWO ~= oldBucket and handlers.TAKEOVER_BUCKET ~= oldFirstBucket,
                who .. "each bucket fire function is replaced")
            T.eq(buildOf(handlers.TAKEOVER_BUCKET_TWO), tostring(INCOMING_BUILD), who .. "the fire function is the newer copy's")
            T.truthy(rawequal(handlers.TAKEOVER_BUCKET_TWO, handlers.TAKEOVER_BUCKET_THREE),
                who .. "a bucket's events share one fire function")
            T.truthy(rawequal(bucket._timer, window), who .. "the open window keeps its timer")

            -- the older closure on the frame now dispatches to the newer handlers
            T.Fire(frame, "TAKEOVER_PLAIN", "a", "b")
            T.eq(#plain, 1, who .. "a plain handler runs once")
            T.eq(plain[1][1], "TAKEOVER_PLAIN", who .. "with the event name first")
            T.eq(plain[1][3], "b", who .. "and the arguments after it")

            local unregisters = callCount(frame, "UnregisterEvent")
            T.Fire(frame, "TAKEOVER_ONCE_TWO", "x")
            T.eq(onceRuns, 1, who .. "the once handler runs")
            T.eq(callCount(frame, "UnregisterEvent"), unregisters + 1, who .. "and unregisters its event")
            T.falsy(c:IsRegistered("TAKEOVER_ONCE_TWO"), who .. "the event is no longer registered")
            T.eq(c._onceHandlers.TAKEOVER_ONCE_TWO, nil, who .. "its once entry is gone")
            T.Fire(frame, "TAKEOVER_ONCE_TWO", "x")
            T.eq(onceRuns, 1, who .. "it does not run again")

            -- the window opened by the older fire function ends in one handler call
            T.Fire(frame, "TAKEOVER_BUCKET_THREE")
            T.eq(#T.timers, timers, who .. "the newer fire function opens no second window")
            T.FireTimer(window)
            T.eq(bucketRuns, 1, who .. "the handler runs once for that window")
            T.falsy(bucket:IsPending(), who .. "and nothing is pending")
            T.Fire(frame, "TAKEOVER_BUCKET_TWO")
            T.eq(#T.timers, timers + 1, who .. "the next event opens a new window")
            T.FireTimer(bucket._timer)
            T.eq(bucketRuns, 2, who .. "which ends in one more call")

            c:Register("TAKEOVER_AFTER", function() end)
            T.truthy(c:IsRegistered("TAKEOVER_AFTER"), who .. "a registration after the takeover works")
            T.eq(#T.output, 0, who .. "nothing is printed")
        end
    end
end)

test("a trailing bucket open at the takeover calls its handler exactly once, after its quiet window", function()
    for _, kind in ipairs({ "layout1", "current" }) do
        local who = kind .. ": "
        local F = serve(kind, "release")
        local c = F.Events:New("TakeoverTrailing")
        local runs = 0
        local bucket = c:RegisterBucket({
            events = "TAKEOVER_TRAILING", interval = 5, edge = "trailing", handler = function() runs = runs + 1 end,
        })
        T.Fire(c._frame, "TAKEOVER_TRAILING")
        T.now = 2
        T.Fire(c._frame, "TAKEOVER_TRAILING")
        local first, timers = bucket._timer, #T.timers
        T.eq(timers, 1, who .. "one timer opened for the window")
        loadModule("Events", { version = "1.0.2" })
        T.eq(F.Events._build, INCOMING_BUILD, who .. "Events upgraded")
        T.now = 3
        T.Fire(c._frame, "TAKEOVER_TRAILING")
        T.eq(#T.timers, timers, who .. "the newer fire function adds no timer")
        T.now = 5
        T.FireTimer(first)
        T.eq(runs, 0, who .. "the window is extended by the later event")
        T.truthy(bucket:IsPending(), who .. "and a timer waits for the new end")
        T.eq(#T.timers, timers + 1, who .. "one timer re-armed")
        T.now = 8
        T.FireTimer(bucket._timer)
        T.eq(runs, 1, who .. "the handler runs once")
        T.falsy(bucket:IsPending(), who .. "nothing is pending")
        T.eq(#T.output, 0, who .. "nothing is printed")
    end
end)

test("a newer Events takes over when nothing needs a timer, even without one, and over no controllers at all", function()
    for _, kind in ipairs({ "layout1", "current" }) do
        local F = serve(kind, "release")
        _G.C_Timer = nil
        _G.GetTime = nil
        loadModule("Events", { version = "1.0.2" })
        T.eq(F.Events._build, INCOMING_BUILD, kind .. ": with no controller")
        local c = F.Events:New("TakeoverPlain")
        c:RegisterOnce("TAKEOVER_ONCE", function() end)
        T.falsy(pcall(c.RegisterBucket, c, { events = "TAKEOVER_BUCKET", interval = 5, handler = function() end }),
            kind .. ": a bucket needs the timer")
        local E = F.Events
        E._build = SERVING_BUILD
        loadModule("Events", { version = "1.0.2" })
        T.eq(E._build, INCOMING_BUILD, kind .. ": with a controller that holds a once handler and no bucket")
    end
end)

local EVENTS_PROOFS = {
    { name = "a controller whose handler table is not a table", outcome = "refused: shape",
        inject = withInstances(function(_, _, inst) inst.events._handlers = "handlers" end) },
    { name = "a controller with nothing registered whose handler table is not a table", outcome = "refused: shape",
        inject = function(F) F.Events:New("TakeoverBare")._handlers = "handlers" end },
    { name = "a controller whose bucket list is not a table", outcome = "refused: shape",
        inject = withInstances(function(_, _, inst) inst.events._buckets = "buckets" end) },
    { name = "a controller whose bucket-event table is not a table", outcome = "refused: shape",
        inject = withInstances(function(_, _, inst) inst.events._bucketEvents = "events" end) },
    { name = "a controller whose once table is not a table", outcome = "refused: shape",
        inject = withInstances(function(_, _, inst) inst.events._onceHandlers = "once" end) },
    { name = "a once entry with no handler in the handler table", outcome = "refused: shape",
        inject = withInstances(function(_, _, inst) inst.events._handlers.TAKEOVER_ONCE = nil end) },
    { name = "a once entry whose handler is not a function", outcome = "refused: shape",
        inject = withInstances(function(_, _, inst) inst.events._onceHandlers.TAKEOVER_ONCE = "handler" end) },
    { name = "a once entry whose stored closure is not a function", outcome = "refused: shape",
        inject = withInstances(function(_, _, inst) inst.events._handlers.TAKEOVER_ONCE = "closure" end) },
    { name = "a bucket whose event list is not a table", outcome = "refused: shape",
        inject = withInstances(function(_, _, inst) inst.bucket._events = "events" end) },
    { name = "a bucket event that is not a string", outcome = "refused: shape",
        inject = withInstances(function(_, _, inst) inst.bucket._events[1] = 5 end) },
    { name = "a bucket event that is not a string but has a handler", outcome = "refused: shape",
        inject = withInstances(function(_, _, inst)
            inst.bucket._events[1] = 5
            inst.events._handlers[5] = function() end
        end) },
    { name = "a bucket event with no handler in the handler table", outcome = "refused: shape",
        inject = withInstances(function(_, _, inst) inst.events._handlers.TAKEOVER_BUCKET = nil end) },
    { name = "a bucket list holding something other than a bucket", outcome = "refused: shape",
        inject = withInstances(function(_, _, inst) inst.events._buckets[#inst.events._buckets + 1] = "bucket" end) },
    { name = "a list of live controllers that is not a table", outcome = "refused: shape",
        inject = function(_, unitTbl) unitTbl._state.instances = "controllers" end },
    { name = "a live controller that is not a table", outcome = "refused: shape",
        inject = function(_, unitTbl) unitTbl._state.instances["controller"] = true end },
    { name = "no state table", outcome = "refused: shape",
        inject = function(_, unitTbl) unitTbl._state = nil end },
    { name = "no implementation table", outcome = "refused: shape",
        inject = function(_, unitTbl) unitTbl._impl = nil end },
    { name = "no controller implementation", outcome = "refused: shape",
        inject = function(_, unitTbl) unitTbl._impl.Controller = nil end },
    { name = "no bucket implementation", outcome = "refused: shape",
        inject = function(_, unitTbl) unitTbl._impl.Bucket = nil end },
    { name = "a bucket and no timer table", outcome = "refused: timer",
        inject = withInstances(function() _G.C_Timer = nil end) },
    { name = "a bucket and a timer table without NewTimer", outcome = "refused: timer",
        inject = withInstances(function() _G.C_Timer.NewTimer = nil end) },
    { name = "a bucket and no clock", outcome = "refused: timer",
        inject = withInstances(function() _G.GetTime = nil end) },
}

test("a newer Events declines a serving Events whose controllers it cannot adopt, changes nothing, and raises only in a development serving copy", function()
    for _, case in ipairs(EVENTS_PROOFS) do
        for _, kind in ipairs({ "current", "layout1" }) do
            runCase({
                name = "a serving copy with " .. case.name, inject = case.inject, outcome = case.outcome,
                refused = true, units = { "Events" },
            }, kind)
        end
    end
end)

test("an Events that fails partway through taking over leaves the version, build and source of the active copy unchanged", function()
    local lines = { "local Events = served or {}", "local function makeOnEvent(c)", "function Events:New(owner)",
        "if takingOver then", "Events.API_VERSION = API_VERSION" }
    for _, kind in ipairs({ "current", "layout1" }) do
        for _, mode in ipairs({ "release", "dev" }) do
            for _, line in ipairs(lines) do
                local who = kind .. ", " .. mode .. ", failing before '" .. line .. "': "
                local F = serve(kind, mode)
                buildInstances(F)
                local E = F.Events
                local before = { api = rawget(E, "API_VERSION"), build = rawget(E, "_build"), source = rawget(E, "_source") }
                local ok, err = pcall(loadModule, "Events", {
                    version = incomingVersion(mode),
                    replace = merge({ [MODULE_API_LINE] = "local API_VERSION = 3" }, T.plantError(line, "planted failure")),
                })
                T.falsy(ok, who .. "the copy fails")
                T.truthy(tostring(err):find("planted failure", 1, true), who .. "at the planted line: " .. tostring(err))
                T.truthy(rawequal(F.Events, E), who .. "the module is the same table")
                T.eq(rawget(E, "API_VERSION"), before.api, who .. "API version")
                T.eq(rawget(E, "_build"), before.build, who .. "build")
                T.eq(rawget(E, "_source"), before.source, who .. "source")
            end
        end
    end
end)

test("a newer Commands takes over, re-pointing the built-in guard and the restriction handler and leaving a consumer's guard alone, with no client call", function()
    for _, kind in ipairs({ "layout1", "current" }) do
        for _, mode in ipairs({ "release", "dev" }) do
            local who = kind .. ", " .. mode .. ": "
            local F = serve(kind, mode)
            local inst = buildInstances(F)
            local C = F.Commands
            local S, I = C._state, C._impl
            local ownGuard = function() return true end
            local own = C:New({ name = "TakeoverOwn", slashes = { "/tko3" }, guard = ownGuard })
            local guards, olderGuard = C.Guards, C.Guards.NotRestricted
            local restriction = inst.commands._restrictionEvents
            local handlers, olderSlot = restriction._handlers, restriction._handlers.ADDON_RESTRICTION_STATE_CHANGED
            local slot, guardedSlot = _G.SlashCmdList.TAKEOVER, _G.SlashCmdList.TAKEOVERGUARDED
            local impl = { Controller = I.Controller }
            T.truthy(rawequal(inst.guarded._guard, olderGuard), who .. "the guarded controller holds the built-in guard")
            local before = clientCalls()

            local ok, err = pcall(loadModule, "Commands", { version = incomingVersion(mode) })
            T.truthy(ok, who .. "the incoming Commands raised nothing: " .. tostring(err))
            T.eq(C._build, INCOMING_BUILD, who .. "Commands upgraded")
            T.eq(C._source, "IncomingHost", who .. "the newer copy's addon is named")
            T.eq(C.API_VERSION, 2, who .. "API version")
            T.truthy(rawequal(F.Commands, C) and rawequal(C._state, S) and rawequal(C._impl, I),
                who .. "the module, state and implementation tables are kept")
            T.truthy(rawequal(I.Controller, impl.Controller) and rawequal(getmetatable(inst.commands), I.Controller),
                who .. "the controller table is kept and serves the controllers made before")
            T.truthy(rawequal(C.Guards, guards), who .. "the guard table is kept")
            T.eq(firstCallDifference(before, clientCalls()), nil, who .. "no client call is made")

            T.truthy(C.Guards.NotRestricted ~= olderGuard, who .. "the built-in guard is redefined")
            T.eq(buildOf(C.Guards.NotRestricted), tostring(INCOMING_BUILD), who .. "as the newer copy's")
            T.truthy(rawequal(inst.guarded._guard, C.Guards.NotRestricted), who .. "the controller that held it holds the new one")
            T.truthy(rawequal(own._guard, ownGuard), who .. "a consumer's own guard is untouched")
            T.eq(inst.commands._guard, nil, who .. "a controller with no guard still has none")

            T.truthy(rawequal(restriction._handlers, handlers), who .. "the restriction controller keeps its handler table")
            T.truthy(handlers.ADDON_RESTRICTION_STATE_CHANGED ~= olderSlot, who .. "the restriction handler is replaced")
            T.eq(buildOf(handlers.ADDON_RESTRICTION_STATE_CHANGED), tostring(INCOMING_BUILD),
                who .. "with the newer copy's")
            T.Fire(restriction._frame, "ADDON_RESTRICTION_STATE_CHANGED", 0, 1)
            local notices = 0
            for _, line in ipairs(T.output) do
                if line == "Commands are about to be paused while combat restrictions activate." then notices = notices + 1 end
            end
            T.eq(notices, 1, who .. "the notice is printed once")

            T.truthy(rawequal(_G.SlashCmdList.TAKEOVER, slot) and rawequal(_G.SlashCmdList.TAKEOVERGUARDED, guardedSlot),
                who .. "the slash entries are kept")
            _G.C_RestrictedActions.IsAddOnRestrictionActive = function() return true end
            T.output = {}
            guardedSlot("")
            T.eq(T.output[1], "Commands are unavailable while combat restrictions are active.", who .. "the guard refuses")
            T.eq(#T.output, 1, who .. "and nothing else is printed")
        end
    end
end)

test("an older slash entry calls the newer Dispatch once, by name", function()
    for _, kind in ipairs({ "layout1", "current" }) do
        for _, mode in ipairs({ "release", "dev" }) do
            local who = kind .. ", " .. mode .. ": "
            local F = serve(kind, mode)
            local inst = buildInstances(F)
            inst.commands:Register({ name = "ping", handler = function() end })
            local slot = _G.SlashCmdList.TAKEOVER
            if kind == "layout1" then
                T.truthy(isOlderFunction(slot), who .. "the slash entry is the older copy's relay")
            end
            loadModule("Commands", { version = incomingVersion(mode) })
            local C = F.Commands
            T.eq(C._build, INCOMING_BUILD, who .. "Commands upgraded")
            T.truthy(rawequal(_G.SlashCmdList.TAKEOVER, slot), who .. "the entry is kept")
            T.eq(buildOf(C._impl.Controller.Dispatch), tostring(INCOMING_BUILD), who .. "Dispatch is the newer copy's")
            T.output = {}
            local runs = slots.countCalls(C._impl.Controller, "Dispatch", function() slot("") end)
            T.eq(runs, 1, who .. "the entry runs the newer Dispatch once")
            T.truthy(#T.output > 0, who .. "which prints the help")
        end
    end
end)

local COMMANDS_PROOFS = {
    { name = "a list of live controllers that is not a table", outcome = "refused: shape",
        inject = function(_, unitTbl) unitTbl._state.instances = "controllers" end },
    { name = "a live controller that is not a table", outcome = "refused: shape",
        inject = function(_, unitTbl) unitTbl._state.instances["controller"] = true end },
    { name = "no state table", outcome = "refused: shape",
        inject = function(_, unitTbl) unitTbl._state = nil end },
    { name = "no implementation table", outcome = "refused: shape",
        inject = function(_, unitTbl) unitTbl._impl = nil end },
    { name = "no controller implementation", outcome = "refused: shape",
        inject = function(_, unitTbl) unitTbl._impl.Controller = nil end },
    { name = "no guard table", outcome = "refused: shape",
        inject = function(_, unitTbl) unitTbl.Guards = nil end },
    { name = "a built-in guard that is not a function", outcome = "refused: shape",
        inject = function(_, unitTbl) unitTbl.Guards.NotRestricted = "guard" end },
    { name = "a restriction controller that is not a table", outcome = "refused: shape",
        inject = withInstances(function(_, _, inst) inst.commands._restrictionEvents = true end) },
    { name = "a restriction controller with no handler table", outcome = "refused: shape",
        inject = withInstances(function(_, _, inst) inst.commands._restrictionEvents._handlers = nil end) },
    { name = "a restriction controller whose handler table is not a table", outcome = "refused: shape",
        inject = withInstances(function(_, _, inst) inst.commands._restrictionEvents._handlers = "handlers" end) },
    { name = "a restriction controller with no restriction handler", outcome = "refused: shape",
        inject = withInstances(function(_, _, inst)
            inst.commands._restrictionEvents._handlers.ADDON_RESTRICTION_STATE_CHANGED = nil
        end) },
    { name = "a restriction handler that is not a function", outcome = "refused: shape",
        inject = withInstances(function(_, _, inst)
            inst.commands._restrictionEvents._handlers.ADDON_RESTRICTION_STATE_CHANGED = "handler"
        end) },
    { name = "a restriction controller and an Events with layout 2", outcome = "refused: events layout",
        inject = withInstances(function(F) rawset(F.Events, "_layoutVersion", 2) end) },
    { name = "a restriction controller and an Events with no layout", outcome = "refused: events layout",
        inject = withInstances(function(F) rawset(F.Events, "_layoutVersion", nil) end) },
}

test("a newer Commands declines a serving Commands whose controllers it cannot adopt, changes nothing, and raises only in a development serving copy", function()
    for _, case in ipairs(COMMANDS_PROOFS) do
        for _, kind in ipairs({ "current", "layout1" }) do
            runCase({
                name = "a serving copy with " .. case.name, inject = case.inject, outcome = case.outcome,
                refused = true, units = { "Commands" },
            }, kind)
        end
    end
end)

test("a newer Commands takes over an Events of another layout when no controller holds a restriction handler", function()
    for _, kind in ipairs({ "layout1", "current" }) do
        local F = serve(kind, "release")
        F.Commands:New({ name = "TakeoverPlain", slashes = { "/tkp" } })
        rawset(F.Events, "_layoutVersion", 2)
        loadModule("Commands", { version = "1.0.2" })
        T.eq(F.Commands._build, INCOMING_BUILD, kind .. ": Commands upgraded")
    end
end)

test("a Commands that fails partway through taking over leaves the version, build and source of the active copy unchanged", function()
    local lines = { "local Commands = served or {}", "local function makeRestrictionHandler(c)",
        "function Commands:New(config)", "if takingOver then", "Commands.API_VERSION = API_VERSION" }
    for _, kind in ipairs({ "current", "layout1" }) do
        for _, mode in ipairs({ "release", "dev" }) do
            for _, line in ipairs(lines) do
                local who = kind .. ", " .. mode .. ", failing before '" .. line .. "': "
                local F = serve(kind, mode)
                buildInstances(F)
                local C = F.Commands
                local before = { api = rawget(C, "API_VERSION"), build = rawget(C, "_build"), source = rawget(C, "_source") }
                local ok, err = pcall(loadModule, "Commands", {
                    version = incomingVersion(mode),
                    replace = merge({ [MODULE_API_LINE] = "local API_VERSION = 3" }, T.plantError(line, "planted failure")),
                })
                T.falsy(ok, who .. "the copy fails")
                T.truthy(tostring(err):find("planted failure", 1, true), who .. "at the planted line: " .. tostring(err))
                T.truthy(rawequal(F.Commands, C), who .. "the module is the same table")
                T.eq(rawget(C, "API_VERSION"), before.api, who .. "API version")
                T.eq(rawget(C, "_build"), before.build, who .. "build")
                T.eq(rawget(C, "_source"), before.source, who .. "source")
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- List, Settings, Tooltip, Menu and Window
--------------------------------------------------------------------------------

local UI_UNITS = { "List", "Settings", "Tooltip", "Menu", "Window" }
-- The public entry point each unit redefines, and the API version each file carries.
local UI_ENTRY = { List = "New", Settings = "New", Tooltip = "New", Menu = "New", Window = "Attach" }
local UI_API = { List = 1, Settings = 2, Tooltip = 1, Menu = 1, Window = 1 }

local SETTINGS_REGISTRATIONS = {
    "RegisterCanvasLayoutCategory", "RegisterCanvasLayoutSubcategory", "RegisterVerticalLayoutCategory",
    "RegisterInitializer", "RegisterAddOnCategory",
}

-- Wraps each { table, key } while run() executes and returns how many calls
-- the wrappers saw in all.
local function countAll(targets, run)
    local originals, total = {}, 0
    for i, target in ipairs(targets) do
        local tbl, key = target[1], target[2]
        local fn = tbl[key]
        originals[i] = fn
        if type(fn) == "function" then
            tbl[key] = function(...)
                total = total + 1
                return fn(...)
            end
        end
    end
    local ok, err = pcall(run)
    for i, target in ipairs(targets) do target[1][target[2]] = originals[i] end
    if not ok then error(err, 0) end
    return total
end

-- The calls through which a module could reach the client or the library's
-- registry: its own registration, frames, the scrolling list, the settings
-- panel, the tooltip processor and the menu utility.
local function clientTargets(F)
    local targets = {
        { F, "RegisterModule" }, { _G, "CreateFrame" }, { _G, "CreateScrollBoxListLinearView" },
        { _G, "CreateDataProvider" }, { _G, "CreateSettingsButtonInitializer" },
        { _G.TooltipDataProcessor, "AddTooltipPostCall" }, { _G.MenuUtil, "CreateContextMenu" },
    }
    for _, key in ipairs(SETTINGS_REGISTRATIONS) do targets[#targets + 1] = { _G.Settings, key } end
    return targets
end

local function settingsTargets()
    local targets = { { _G, "CreateSettingsButtonInitializer" } }
    for _, key in ipairs(SETTINGS_REGISTRATIONS) do targets[#targets + 1] = { _G.Settings, key } end
    return targets
end

-- Every slash name the client holds: the handler table's keys and the SLASH_ globals.
local function slashKeys()
    local keys = {}
    for key in pairs(_G.SlashCmdList) do keys[#keys + 1] = "SlashCmdList." .. tostring(key) end
    for key in pairs(_G) do
        if type(key) == "string" and key:match("^SLASH_") then keys[#keys + 1] = key end
    end
    table.sort(keys)
    return table.concat(keys, ",")
end

local UI_API_LINES = {}
for unit, n in pairs(UI_API) do UI_API_LINES[unit] = "local API_VERSION = " .. n end

test("a newer List, Settings, Tooltip, Menu or Window takes over the serving module in place, redefines its functions and makes no client call", function()
    for _, unit in ipairs(UI_UNITS) do
        for _, kind in ipairs({ "layout1", "current" }) do
            for _, mode in ipairs({ "release", "dev" }) do
                local who = unit .. ", " .. kind .. ", " .. mode .. ": "
                local F = serve(kind, mode)
                local inst = buildInstances(F)
                local M = F[unit]
                local S, I = M._state, M._impl
                local kept = {}
                for key, value in pairs(S) do kept[key] = value end
                local controller = I.Controller
                local olderEntry = M[UI_ENTRY[unit]]
                local copies, frames, printed = #F._state.copies, #T.frames, #T.output
                local before, slash = clientCalls(), slashKeys()
                local views, posts = #T.views, #inst.processor.postCalls

                local ok, err
                local calls = countAll(clientTargets(F), function()
                    ok, err = pcall(loadModule, unit, { version = incomingVersion(mode) })
                end)
                T.truthy(ok, who .. "the incoming file raised nothing: " .. tostring(err))
                T.eq(calls, 0, who .. "no registration, frame or client surface call")
                T.eq(firstCallDifference(before, clientCalls()), nil, who .. "no frame call is logged")
                T.eq(#T.frames, frames, who .. "no frame is made")
                T.eq(#T.views, views, who .. "no scrolling list view is made")
                T.eq(#inst.processor.postCalls, posts, who .. "no tooltip post-call is added")
                T.eq(slashKeys(), slash, who .. "no slash name appears")
                T.eq(#F._state.copies, copies, who .. "a module file leaves the record alone")
                T.eq(#T.output, printed, who .. "nothing is printed")

                T.truthy(rawequal(F[unit], M) and rawequal(M._state, S) and rawequal(M._impl, I),
                    who .. "the module, state and implementation tables are kept")
                for key, value in pairs(kept) do
                    T.truthy(rawequal(S[key], value), who .. "state '" .. key .. "' is kept")
                end
                if controller then
                    T.truthy(rawequal(I.Controller, controller), who .. "the controller table is kept")
                end
                T.eq(M._build, INCOMING_BUILD, who .. "build is the newer number")
                T.eq(M._source, "IncomingHost", who .. "the newer copy's addon is named")
                T.eq(M.API_VERSION, UI_API[unit], who .. "API version")
                T.eq(M._layoutVersion, 1, who .. "layout version")
                T.truthy(M[UI_ENTRY[unit]] ~= olderEntry, who .. UI_ENTRY[unit] .. " is redefined")
                T.eq(buildOf(M[UI_ENTRY[unit]]), tostring(INCOMING_BUILD), who .. UI_ENTRY[unit] .. " is the newer copy's")
                local replaced = 0
                for key, value in pairs(I) do
                    if type(value) == "function" then
                        replaced = replaced + 1
                        T.eq(buildOf(value), tostring(INCOMING_BUILD), who .. "_impl." .. tostring(key) .. " is the newer copy's")
                    end
                end
                T.truthy(replaced > 0, who .. "implementation functions were checked")
            end
        end
    end
end)

-- name         the relay, in plain words
-- unit/target  the function on the module's implementation table it calls by name
-- slot         reads the function the client keeps, from the instances made before
-- call         calls the slot the way the client does
local RELAYS = {
    { name = "the list's row initializer", unit = "List", target = "initRow",
        slot = function(inst) return inst.list:GetNativeHandles().view._initializer end,
        call = function(slot) slot({}, {}) end },
    { name = "the list's extent calculator", unit = "List", target = "extent",
        slot = function(inst) return inst.list:GetNativeHandles().view._calc end,
        call = function(slot) T.eq(slot(1, {}), 20, "the extent") end },
    { name = "the tooltip post-call", unit = "Tooltip", target = "dispatch",
        slot = function(inst) return inst.processor.postCalls[1].fn end,
        call = function(slot) slot(surfaces.makeTooltip(), {}) end },
    { name = "the settings launcher click", unit = "Settings", target = "launcherClick",
        slot = function(inst) return inst.panel.clicks[#inst.panel.clicks] end,
        call = function(slot) slot({}, "LeftButton", false) end },
    { name = "the menu generator", unit = "Menu", target = "generate",
        slot = function(inst) return inst.menu._generatorWrapper end,
        call = function(slot) slot({}, surfaces.makeRootDescription()) end },
    { name = "the window's drag start script", unit = "Window", target = "dragStart",
        slot = function(inst) return inst.windowFrame._scripts.OnDragStart end,
        call = function(slot) slot() end },
    { name = "the window's drag stop script", unit = "Window", target = "dragStop",
        slot = function(inst) return inst.windowFrame._scripts.OnDragStop end,
        call = function(slot) slot() end },
}

test("a relay an older copy made reaches the newer implementation function by name, once, and the slot that holds it is not touched", function()
    for _, relay in ipairs(RELAYS) do
        for _, kind in ipairs({ "layout1", "current" }) do
            local who = relay.name .. ", " .. kind .. ": "
            local F = serve(kind, "dev")
            local inst = buildInstances(F)
            local slot = relay.slot(inst)
            T.eq(type(slot), "function", who .. "the client holds a function")
            if kind == "layout1" then
                T.truthy(isOlderFunction(slot), who .. "the slot holds the older copy's relay")
            else
                T.eq(buildOf(slot), tostring(SERVING_BUILD), who .. "the slot holds the serving build's relay")
            end
            loadModule(relay.unit, { version = nil })
            T.eq(F[relay.unit]._build, INCOMING_BUILD, who .. "the unit upgraded")
            T.truthy(rawequal(relay.slot(inst), slot), who .. "the slot is unchanged")
            local impl = F[relay.unit]._impl
            T.eq(buildOf(impl[relay.target]), tostring(INCOMING_BUILD), who .. relay.target .. " is the newer copy's")
            T.eq(slots.countCalls(impl, relay.target, function() relay.call(slot) end), 1,
                who .. "the relay calls the newer " .. relay.target .. " once")
        end
    end
end)

test("after a takeover a Settings New of an already registered category reuses it and registers nothing, and an older launcher click reaches the new controller", function()
    for _, kind in ipairs({ "layout1", "current" }) do
        for _, mode in ipairs({ "release", "dev" }) do
            local who = kind .. ", " .. mode .. ": "
            local F = serve(kind, mode)
            local inst = buildInstances(F)
            local canvas = inst.settings:GetNativeHandles()
            local launcher = inst.launcher:GetNativeHandles()
            local click = inst.panel.clicks[#inst.panel.clicks]
            loadModule("Settings", { version = incomingVersion(mode) })
            T.eq(F.Settings._build, INCOMING_BUILD, who .. "Settings upgraded")
            inst.settings:Destroy()
            inst.launcher:Destroy()
            local launched, again, launcherAgain = 0, nil, nil
            local registrations = countAll(settingsTargets(), function()
                again = F.Settings:New({ title = "TakeoverCanvas", frame = canvas.frame })
                launcherAgain = F.Settings:New({
                    title = "TakeoverLauncher", buttonText = "Open", launch = function() launched = launched + 1 end,
                })
            end)
            T.eq(registrations, 0, who .. "the same categories register nothing again")
            T.truthy(again and launcherAgain, who .. "both New calls return a controller")
            T.truthy(rawequal(again:GetNativeHandles().category, canvas.category), who .. "the canvas category is reused")
            T.truthy(rawequal(launcherAgain:GetNativeHandles().category, launcher.category), who .. "the launcher category is reused")
            click({}, "LeftButton", false)
            T.eq(launched, 1, who .. "the click made before the takeover launches through the new controller")
            local fresh = countAll(settingsTargets(), function()
                F.Settings:New({ title = "TakeoverOther", frame = { GetObjectType = function() return "Frame" end } })
            end)
            T.truthy(fresh > 0, who .. "a category not seen before does register")
            T.eq(#T.output, 0, who .. "nothing is printed")
        end
    end
end)

test("after a takeover a Tooltip New of a known type adds no post-call, a new type adds one, and the older post-call runs the new controller", function()
    for _, kind in ipairs({ "layout1", "current" }) do
        for _, mode in ipairs({ "release", "dev" }) do
            local who = kind .. ", " .. mode .. ": "
            local F = serve(kind, mode)
            local inst = buildInstances(F)
            local postCalls = inst.processor.postCalls
            local posts = #postCalls
            loadModule("Tooltip", { version = incomingVersion(mode) })
            T.eq(F.Tooltip._build, INCOMING_BUILD, who .. "Tooltip upgraded")
            T.eq(#postCalls, posts, who .. "the takeover adds no post-call")
            local ran = 0
            F.Tooltip:New({ type = 1, name = "TakeoverSecond", handler = function() ran = ran + 1 end })
            T.eq(#postCalls, posts, who .. "a known type adds no post-call")
            postCalls[1].fn(surfaces.makeTooltip(), {})
            T.eq(ran, 1, who .. "the post-call made before the takeover runs the new controller once")
            F.Tooltip:New({ type = 2, handler = function() end })
            T.eq(#postCalls, posts + 1, who .. "a type not seen before adds one post-call")
            T.eq(#T.output, 0, who .. "nothing is printed")
        end
    end
end)

test("a window made before a takeover saves its position through the newer code when dragged, with no SetScript", function()
    for _, kind in ipairs({ "layout1", "current" }) do
        for _, mode in ipairs({ "release", "dev" }) do
            local who = kind .. ", " .. mode .. ": "
            local F = serve(kind, mode)
            local inst = buildInstances(F)
            local win = inst.windowFrame
            local onStart, onStop = win._scripts.OnDragStart, win._scripts.OnDragStop
            local setScripts = setScriptCount()
            loadModule("Window", { version = incomingVersion(mode) })
            local W = F.Window
            T.eq(W._build, INCOMING_BUILD, who .. "Window upgraded")
            T.eq(setScriptCount(), setScripts, who .. "the takeover logs no SetScript")
            T.truthy(rawequal(win._scripts.OnDragStart, onStart) and rawequal(win._scripts.OnDragStop, onStop),
                who .. "the drag scripts are kept")
            if kind == "layout1" then
                T.truthy(isOlderFunction(onStop), who .. "the stop script is the older copy's relay")
            end
            local geometry = W._state.attached[win].geometry
            win:ClearAllPoints()
            win:SetPoint("TOPLEFT", _G.UIParent, "TOPLEFT", 12, -34)
            local starts = #win.calls.StartMoving
            T.eq(slots.countCalls(W._impl, "dragStart", function() onStart() end), 1, who .. "the newer drag start runs once")
            T.eq(#win.calls.StartMoving, starts + 1, who .. "and starts the move")
            T.eq(slots.countCalls(W._impl, "dragStop", function() onStop() end), 1, who .. "the newer drag stop runs once")
            T.eq(buildOf(W._impl.saveGeometry), tostring(INCOMING_BUILD), who .. "and the save it makes is the newer copy's")
            T.eq(geometry.point, "TOPLEFT", who .. "the position is saved")
            T.eq(geometry.x, 12, who .. "x")
            T.eq(geometry.y, -34, who .. "y")
            T.eq(setScriptCount(), setScripts, who .. "no SetScript is logged by the drag either")
            T.eq(#T.output, 0, who .. "nothing is printed")
        end
    end
end)

test("controllers made before a takeover of List or Menu keep working with the newer code, and new ones join them", function()
    for _, kind in ipairs({ "layout1", "current" }) do
        local who = kind .. ": "
        local F = serve(kind, "dev")
        local inst = buildInstances(F)
        loadModule("List", { version = nil })
        loadModule("Menu", { version = nil })
        T.eq(F.List._build, INCOMING_BUILD, who .. "List upgraded")
        T.eq(F.Menu._build, INCOMING_BUILD, who .. "Menu upgraded")
        inst.list:SetData({ {}, {} })
        T.eq(inst.list:GetNativeHandles().dataProvider:GetSize(), 2, who .. "a list made before takes data")
        local list = F.List:New({
            name = "TakeoverListAfter", parent = {}, elementType = "Button", extent = 20, initializer = function() end,
        })
        T.truthy(F.List._state.instances[inst.list] and F.List._state.instances[list], who .. "both lists are listed")
        local built = 0
        local menu = F.Menu:New({ builder = function() built = built + 1 end })
        T.eq(menu._name, "F.Menu.anon.2", who .. "the anonymous name counter carries on")
        inst.menu._generatorWrapper({}, surfaces.makeRootDescription())
        T.eq(built, 0, who .. "the first menu's builder is its own")
        menu._generatorWrapper({}, surfaces.makeRootDescription())
        T.eq(built, 1, who .. "the new menu builds")
        T.truthy(F.Menu._state.instances[inst.menu] and F.Menu._state.instances[menu], who .. "both menus are listed")
    end
end)

test("a whole newer copy loading over the layout-1 copy adds no slash name and leaves the library command alone", function()
    for _, kind in ipairs({ "layout1", "current" }) do
        local F = serve(kind, "dev")
        buildInstances(F)
        local command, slash = _G.SlashCmdList.FOUNDRY, slashKeys()
        local errors = loadEach({ build = INCOMING_BUILD, addonName = "IncomingHost" })
        T.eq(next(errors), nil, kind .. ": the incoming copy raised nothing: " .. firstError(errors))
        T.eq(slashKeys(), slash, kind .. ": no slash name appears")
        T.truthy(rawequal(_G.SlashCmdList.FOUNDRY, command), kind .. ": the /foundry command is the first copy's")
        T.truthy(rawequal(_G.Foundry_1_0, F), kind .. ": the library table is the same")
    end
end)

test("after a whole newer copy loads over the layout-1 copy, /foundry copies lists every module as coming from it and one upgraded line", function()
    for _, kind in ipairs({ "layout1", "current" }) do
        local F = serve(kind, "dev")
        buildInstances(F)
        local errors = loadEach({ build = INCOMING_BUILD, addonName = "IncomingHost" })
        T.eq(next(errors), nil, kind .. ": the incoming copy raised nothing: " .. firstError(errors))
        T.output = {}
        _G.SlashCmdList.FOUNDRY("copies")
        local text = "\n" .. table.concat(T.output, "\n") .. "\n"
        for _, unit in ipairs(UNITS) do
            if unit ~= "core" then
                T.truthy(text:find("\nFoundry: " .. unit .. " comes from IncomingHost\n", 1, true),
                    kind .. ": " .. unit .. " comes from the newer copy: " .. text)
            end
        end
        T.falsy(text:find("every module comes from the active copy", 1, true), kind .. ": the modules are not the active copy's")
        local tookOver = 0
        for _, line in ipairs(T.output) do
            if line:find("Foundry: upgraded to: ", 1, true) == 1 then tookOver = tookOver + 1 end
        end
        T.eq(tookOver, 1, kind .. ": one upgraded line")
        T.truthy(text:find("\nFoundry: upgraded to: IncomingHost, version dev, API version 7\n", 1, true),
            kind .. ": the line names the newer copy: " .. text)
    end
end)

test("a trimmed newer copy without Window leaves Window on the older copy while every other unit takes over", function()
    local files = {}
    for _, rel in ipairs(T.FOUNDRY_FILES) do
        if rel ~= FILE.Window then files[#files + 1] = rel end
    end
    T.truthy(#files == #T.FOUNDRY_FILES - 1, "Window is the one file left out")
    local F = serve("layout1", "release")
    local inst = buildInstances(F)
    local errors = loadEach({ build = INCOMING_BUILD, addonName = "IncomingHost", version = "1.0.2", files = files })
    T.eq(next(errors), nil, "the trimmed copy raised nothing: " .. firstError(errors))
    for _, unit in ipairs(UNITS) do
        if unit ~= "core" and unit ~= "Window" then
            T.eq(F[unit]._build, INCOMING_BUILD, unit .. " upgraded")
        end
    end
    T.eq(rawget(F.Window, "_build"), nil, "Window has no build")
    T.truthy(isOlderFunction(F.Window.Attach) and isOlderFunction(F.Window._impl.dragStop), "Window is still the older copy's code")
    T.eq(F.Window._source, "ServingHost", "and still names the first copy")
    local win = _G.CreateFrame("Frame", nil, _G.UIParent)
    T.truthy(F.Window:Attach(win, { handle = win, geometry = {}, default = { "CENTER", "CENTER", 0, 0 } }), "it still attaches a window")
    T.truthy(inst.windowFrame ~= nil, "the window made before is untouched")
end)

local UI_PARTWAY = {
    List = { "local List = served or {}", "local function initRow(c, frame, elementData)", "function List:New(config)",
        "List.API_VERSION = API_VERSION" },
    Settings = { "local Settings = served or {}", "local function launcherClick(record)", "function Settings:New(config)",
        "Settings.API_VERSION = API_VERSION" },
    Tooltip = { "local Tooltip = served or {}", "local function dispatch(list, tooltip, data)", "function Tooltip:New(config)",
        "Tooltip.API_VERSION = API_VERSION" },
    Menu = { "local Menu = served or {}", "local function generate(c, owner, rootDescription, ...)", "function Menu:New(config)",
        "Menu.API_VERSION = API_VERSION" },
    Window = { "local Window = served or {}", "local function dragStart(record)", "function Window:Attach(win, config)",
        "Window.API_VERSION = API_VERSION" },
}

test("a List, Settings, Tooltip, Menu or Window that fails partway through taking over leaves the version, build and source of the active copy unchanged", function()
    for _, unit in ipairs(UI_UNITS) do
        for _, kind in ipairs({ "current", "layout1" }) do
            for _, mode in ipairs({ "release", "dev" }) do
                for _, line in ipairs(UI_PARTWAY[unit]) do
                    local who = unit .. ", " .. kind .. ", " .. mode .. ", failing before '" .. line .. "': "
                    local F = serve(kind, mode)
                    buildInstances(F)
                    local M = F[unit]
                    local before = { api = rawget(M, "API_VERSION"), build = rawget(M, "_build"), source = rawget(M, "_source") }
                    local ok, err = pcall(loadModule, unit, {
                        version = incomingVersion(mode),
                        replace = merge({ [UI_API_LINES[unit]] = "local API_VERSION = " .. (UI_API[unit] + 1) },
                            T.plantError(line, "planted failure")),
                    })
                    T.falsy(ok, who .. "the copy fails")
                    T.truthy(tostring(err):find("planted failure", 1, true), who .. "at the planted line: " .. tostring(err))
                    T.truthy(rawequal(F[unit], M), who .. "the module is the same table")
                    T.eq(rawget(M, "API_VERSION"), before.api, who .. "API version")
                    T.eq(rawget(M, "_build"), before.build, who .. "build")
                    T.eq(rawget(M, "_source"), before.source, who .. "source")
                end
            end
        end
    end
end)

local function stateKey(key, value)
    return function(_, unitTbl) unitTbl._state[key] = value end
end

local function noState(_, unitTbl) unitTbl._state = nil end
local function noImpl(_, unitTbl) unitTbl._impl = nil end
local function noController(_, unitTbl) unitTbl._impl.Controller = nil end

local UI_PROOFS = {
    List = {
        { name = "a list of live controllers that is not a table", inject = stateKey("instances", "controllers") },
        { name = "no state table", inject = noState },
        { name = "no implementation table", inject = noImpl },
        { name = "no controller implementation", inject = noController },
    },
    Settings = {
        { name = "a live-name table that is not a table", inject = stateKey("liveKeys", "names") },
        { name = "a registered-category table that is not a table", inject = stateKey("registeredCategories", "categories") },
        { name = "no state table", inject = noState },
        { name = "no implementation table", inject = noImpl },
        { name = "no controller implementation", inject = noController },
    },
    Tooltip = {
        { name = "a live-name table that is not a table", inject = stateKey("liveKeys", "names") },
        { name = "a dispatcher table that is not a table", inject = stateKey("dispatchers", "dispatchers") },
        { name = "no state table", inject = noState },
        { name = "no implementation table", inject = noImpl },
        { name = "no controller implementation", inject = noController },
    },
    Menu = {
        { name = "a list of live controllers that is not a table", inject = stateKey("instances", "controllers") },
        { name = "a live-name table that is not a table", inject = stateKey("liveKeys", "names") },
        { name = "an anonymous-name counter that is not a number", inject = stateKey("anonCounter", "1") },
        { name = "no state table", inject = noState },
        { name = "no implementation table", inject = noImpl },
        { name = "no controller implementation", inject = noController },
    },
    Window = {
        { name = "an attached-window table that is not a table", inject = stateKey("attached", "windows") },
        { name = "no state table", inject = noState },
        { name = "no implementation table", inject = noImpl },
    },
}

test("a newer List, Settings, Tooltip, Menu or Window declines a serving module whose state it cannot adopt, changes nothing, and raises only in a development serving copy", function()
    for _, unit in ipairs(UI_UNITS) do
        for _, case in ipairs(UI_PROOFS[unit]) do
            for _, kind in ipairs({ "current", "layout1" }) do
                runCase({
                    name = "a serving copy with " .. case.name, inject = case.inject, outcome = "refused: shape",
                    refused = true, units = { unit },
                }, kind)
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- The shape of each file after its decision block
--------------------------------------------------------------------------------

-- The files whose shape is not scanned yet. A file joins the scan when its
-- decision block lands and its unit leaves the ledger.
local SHAPE_PENDING = {}

-- The last line of the decision block; every top-level statement after it is
-- scanned.
local DECISION_END = "^local takingOver = served ~= nil$"
local DECISION_END_CORE = "^local takingOver = existing ~= nil$"

local KEYWORDS = {
    ["and"] = true, ["or"] = true, ["not"] = true, ["if"] = true, ["then"] = true, ["function"] = true,
    ["return"] = true, ["in"] = true, ["elseif"] = true, ["while"] = true, ["until"] = true, ["do"] = true,
    ["for"] = true, ["local"] = true, ["else"] = true, ["end"] = true,
}

-- One line with strings reduced to "" and the comment cut off.
local function clean(line)
    local out, i, n = {}, 1, #line
    while i <= n do
        local c = line:sub(i, i)
        if c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local d = line:sub(j, j)
                if d == "\\" then
                    j = j + 2
                elseif d == c then
                    break
                else
                    j = j + 1
                end
            end
            out[#out + 1] = '""'
            i = j + 1
        elseif c == "-" and line:sub(i + 1, i + 1) == "-" then
            break
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

-- The top-level statements of a source text, from line `first` on:
-- { line = n, first = <the first line, cleaned>, text = <all its lines, cleaned and joined>,
--   exempt = <inside a guarded block> }. A top-level line is one that starts in column 0 and is not
-- a comment, the middle of a long string, or the closing of an earlier statement.
local function statements(text, first)
    local out, lineNo, long, block = {}, 0, nil, false
    local current
    for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
        lineNo = lineNo + 1
        raw = raw:gsub("\r$", "")
        local skip = false
        if long then
            if raw:find("%]" .. long .. "%]") then long = nil end
            skip = true
        else
            local comment = raw:match("^%s*%-%-%[(=*)%[")
            local opening = comment or clean(raw):match("%[(=*)%[")
            if opening then
                local _, openEnd = raw:find("%[" .. opening .. "%[")
                if not raw:find("%]" .. opening .. "%]", openEnd + 1) then long = opening end
                if comment then skip = true end
            end
        end
        if lineNo >= first and not skip then
            local starts = raw:match("^%S") and not raw:match("^%-%-")
                and not raw:match("^end") and not raw:match("^[%}%)]") and not raw:match("^else")
                and not raw:match("^until")
            if starts then
                local guard = raw:match("^if not takingOver then$") or raw:match("^if takingOver then$")
                current = { line = lineNo, first = clean(raw), text = clean(raw), exempt = block or guard ~= nil }
                if guard then block = true end
                out[#out + 1] = current
            elseif raw:match("^end$") and block then
                block = false
            elseif current and raw:match("%S") then
                current.text = current.text .. " " .. clean(raw)
            end
        end
    end
    return out
end

-- Calls: a name, `)` or `]` followed by an argument list, a method call, or a
-- name followed by a string or table argument.
local function hasCall(text)
    for name in text:gmatch("([%a_][%w_]*)%s*%(") do
        if not KEYWORDS[name] then return true end
    end
    if text:find("[%)%]]%s*%(") then return true end
    if text:find(":[%a_][%w_]*%s*[%(\"{]") then return true end
    for name in text:gmatch("([%a_][%w_]*)%s*[\"{]") do
        if not KEYWORDS[name] then return true end
    end
    return false
end

-- The first identifier indexed in the text whose root is not allowed, or nil.
local function foreignIndex(text, allowed)
    for pos, name, after in text:gmatch("()([%a_][%w_]*)()") do
        local before = pos > 1 and text:sub(pos - 1, pos - 1) or ""
        local nextChar = text:sub(after, after)
        if not before:match("[%.:%w_]") and (nextChar == "." or nextChar == "[") then
            if not (allowed[name] or name:match("^[A-Z][A-Z0-9_]+$")) then return name end
        end
    end
    return nil
end

local function allowedRoots(rel)
    local unit = rel:match("^Modules/(%w+)%.lua$")
    local roots = { S = true, I = true, Controller = true, Bucket = true, controllerMeta = true }
    if unit then roots[unit] = true else roots.F = true end
    return roots
end

-- The scan's rule is the forbidden class: after the decision block and outside
-- the guarded blocks, a top-level statement is a definition, a forward
-- declaration, a constant or alias, or a write into a bound table; it makes no
-- call and indexes nothing but the bound tables, S, I and constants. Returns
-- the violations as "file:line: reason".
local function scanShape(rel, text)
    local found = {}
    local start
    local lineNo = 0
    local marker = rel == FILE.core and DECISION_END_CORE or DECISION_END
    for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
        lineNo = lineNo + 1
        if raw:gsub("\r$", ""):match(marker) then start = lineNo; break end
    end
    if not start then return { rel .. ": no decision block ends with '" .. marker .. "'" } end
    local roots = allowedRoots(rel)
    for _, st in ipairs(statements(text, start + 1)) do
        if not st.exempt then
            local where = rel .. ":" .. st.line .. ": "
            local first = st.first
            local reason
            if first:match("^local function [%a_][%w_]*%(") then
                -- a definition: its body is not a top-level statement
            elseif first:match("^function [%a_][%w_]*[%.:][%w_%.:]*%(") then
                local root = first:match("^function ([%a_][%w_]*)")
                if not roots[root] then reason = "defines into '" .. root .. "', which is not a bound table" end
            elseif first:match("^[%a_][%w_]* = function%(") then
                -- a forward-declared local given its body
            elseif first:match("^[%a_][%w_%.]* = function%(") then
                local root = first:match("^([%a_][%w_]*)")
                if not roots[root] then reason = "assigns into '" .. root .. "', which is not a bound table" end
            elseif first:match("^local [%a_][%w_]*$") or first:match("^local [%a_][%w_]*, [%a_][%w_, ]*$") then
                -- a forward declaration
            elseif first:match("^local [%a_][%w_, ]* = ") then
                local rhs = st.text:match(" = (.*)$")
                if hasCall(rhs) then
                    reason = "a constant or alias that makes a call"
                else
                    local bad = foreignIndex(rhs, roots)
                    if bad then reason = "indexes '" .. bad .. "', which is not a bound table, S, I or a constant" end
                end
            elseif first:match("^[%a_][%w_]*[%.%[]") and first:find(" = ", 1, true) then
                local root = first:match("^([%a_][%w_]*)")
                local rhs = st.text:match(" = (.*)$")
                if not roots[root] then
                    reason = "writes into '" .. root .. "', which is not a bound table"
                elseif hasCall(rhs) then
                    reason = "a write whose value makes a call"
                else
                    local bad = foreignIndex(rhs, roots)
                    if bad then reason = "indexes '" .. bad .. "', which is not a bound table, S, I or a constant" end
                end
            else
                reason = "not a definition, constant or write into a bound table: " .. first
            end
            if reason then found[#found + 1] = where .. reason end
        end
    end
    return found
end

local function readFile(rel)
    local handle = assert(io.open(T.foundryRoot .. "/" .. rel, "rb"))
    local text = handle:read("*a")
    handle:close()
    return text
end

local function isPendingFile(rel)
    for _, name in ipairs(SHAPE_PENDING) do
        if name == rel then return true end
    end
    return false
end

-- Every form a top-level statement takes in the library files at the base of
-- this work. The scan above is the forbidden class; this list is the survey it
-- was written against, and the survey test keeps it complete.
local SURVEYED_FORMS = {
    { "a local function", function(s) return s:match("^local function [%a_][%w_]*%(") end },
    { "a function defined into a table", function(s) return s:match("^function [%a_][%w_]*[%.:][%w_%.:]*%(") end },
    { "a forward declaration", function(s)
        return s:match("^local [%a_][%w_]*$") or s:match("^local [%a_][%w_]*, [%a_][%w_, ]*$") end },
    { "a forward-declared local given its body", function(s) return s:match("^[%a_][%w_]* = function%(") end },
    { "a local constant, alias or table", function(s) return s:match("^local [%a_][%w_, ]* = ") end },
    { "a write into a table", function(s) return s:match("^[%a_][%w_]*[%.%[]") and s:find(" = ", 1, true) end },
    { "a guard before the file body", function(s) return s:match("^if ") end },
    { "a call", function(s) return s:match("^[%a_][%w_]*[:%.]?[%w_]*%(") end },
}

test("every top-level statement in the library files has a form the scan was written against", function()
    local unknown = {}
    for _, rel in ipairs(T.FOUNDRY_FILES) do
        for _, st in ipairs(statements(readFile(rel), 1)) do
            local known = false
            for _, form in ipairs(SURVEYED_FORMS) do
                if form[2](st.first) then known = true; break end
            end
            if not known then unknown[#unknown + 1] = rel .. ":" .. st.line .. ": " .. st.first end
        end
    end
    T.eq(#unknown, 0, "statements with a form not surveyed: " .. table.concat(unknown, "; "))
end)

local GOOD_SHAPE = [==[
local F = _G.Foundry_1_0
local BUILD = 1
local served = F:HasModule("Events") and F.Events or nil
local takingOver = served ~= nil
local Events = served or {}
if not takingOver then
    Events._layoutVersion = 1
    Events._state = { instances = setmetatable({}, { __mode = "k" }) }
    Events._impl = {}
end
Events.API_VERSION = API_VERSION
local S, I = Events._state, Events._impl
local Controller = I.Controller or {}
Controller.__index = Controller
local LIMIT = 5
local NOTE = "a call(like this) in a string" ..
    "and more"
local TEXT = [[
a line in column 0
foo(bar)
]]
local WORDS = {
    one = "x",
    two = "y",
}
local function helper(a)
    return a
end
function Controller:Do()
    helper(1)
end
function Events.Guards.NotRestricted()
    return true
end
local pollTick, schedulePoll
pollTick = function()
    helper(2)
end
local priorGuard = takingOver and Events.Guards.NotRestricted or nil
I.Controller = Controller
if takingOver then
    I.x = helper(3)
else
    F:RegisterModule("Events", Events)
end
]==]

local function withTail(statement)
    return (GOOD_SHAPE:gsub("I%.Controller = Controller\n", "I.Controller = Controller\n" .. statement .. "\n", 1))
end

test("the shape scan accepts definitions, constants, aliases and writes into bound tables", function()
    local found = scanShape("Modules/Events.lua", GOOD_SHAPE)
    T.eq(#found, 0, "violations: " .. table.concat(found, "; "))
end)

test("the shape scan names the file and line of a top-level call, a foreign index or any other statement", function()
    local line = 0
    for l in GOOD_SHAPE:gmatch("([^\n]*)\n") do
        line = line + 1
        if l == "I.Controller = Controller" then break end
    end
    local bad = {
        'print("loaded")',
        "F:RegisterModule('Again', Events)",
        "local copy = F.something",
        "local made = helper(1)",
        "Other.field = 1",
        "I.value = Events.make()",
        "for i = 1, 3 do",
        "if LIMIT then",
        "return",
    }
    for _, statement in ipairs(bad) do
        local found = scanShape("Modules/Events.lua", withTail(statement))
        T.eq(#found, 1, "'" .. statement .. "' is the only violation: " .. table.concat(found, "; "))
        T.truthy(found[1]:find("Modules/Events.lua:" .. (line + 1) .. ": ", 1, true),
            "'" .. statement .. "' is named with its line: " .. found[1])
    end
end)

test("the shape scan reports a file whose decision block is missing", function()
    local found = scanShape("Modules/Menu.lua", "local F = _G.Foundry_1_0\nlocal Menu = {}\n")
    T.eq(#found, 1, "one violation")
    T.truthy(found[1]:find("no decision block", 1, true), found[1])
end)

test("every library file that has a decision block keeps to the allowed shapes after it", function()
    local scanned = 0
    for _, rel in ipairs(T.FOUNDRY_FILES) do
        if not isPendingFile(rel) then
            scanned = scanned + 1
            local found = scanShape(rel, readFile(rel))
            T.eq(#found, 0, table.concat(found, "; "))
        end
    end
    T.eq(scanned + #SHAPE_PENDING, #T.FOUNDRY_FILES, "every file is either scanned or pending")
    for _, rel in ipairs(SHAPE_PENDING) do
        T.truthy(FILE[rel:match("^Modules/(%w+)%.lua$") or "core"] == rel, "'" .. rel .. "' is a library file")
    end
end)

-- A module file reads the library's layout only through rawget and never reads
-- the library's shared state: on an older library table a plain lookup may be
-- answered by something the module did not mean to read.
test("a module file with a decision block reads neither the library's state nor its layout through a plain lookup", function()
    local scanned = 0
    for _, rel in ipairs(T.FOUNDRY_FILES) do
        if rel ~= FILE.core and not isPendingFile(rel) then
            scanned = scanned + 1
            local n = 0
            for raw in (readFile(rel) .. "\n"):gmatch("([^\n]*)\n") do
                n = n + 1
                local where = rel .. ":" .. n .. ": " .. raw
                local code = clean(raw)
                T.falsy(code:find("F%s*%.%s*_state") or code:find("F%s*%.%s*_layoutVersion"), where)
                for key in raw:gmatch('rawget%(%s*F%s*,%s*"([^"]*)"') do
                    T.eq(key, "_layoutVersion", where)
                end
            end
        end
    end
    T.truthy(scanned > 0, "at least one module file is scanned")
end)

--------------------------------------------------------------------------------
-- The snapshot itself
--------------------------------------------------------------------------------

local function diffAfter(change, ignore)
    local F = T.fresh()
    local fixture = _G.CreateFrame("Frame")
    _G.TestDB = { profileKeys = { a = 1 } }
    local before = SN.take(F)
    change(F, fixture)
    return SN.diff(before, SN.take(F), ignore)
end

local function mentions(changes, text)
    for _, line in ipairs(changes) do
        if line:find(text, 1, true) then return true end
    end
    return false
end

test("a snapshot of an untouched library shows no difference from itself", function()
    T.eq(#diffAfter(function() end), 0, "changes")
end)

test("a snapshot detects a replaced function", function()
    local changes = diffAfter(function(F) F.Commands.New = function() end end)
    T.truthy(mentions(changes, "Commands.New: replaced"), "reported: " .. table.concat(changes, "; "))
end)

test("a snapshot detects a function replaced by an identical one", function()
    local changes = diffAfter(function(F)
        local original = F.Events.New
        F.Events.New = function(...) return original(...) end
    end)
    T.truthy(mentions(changes, "Events.New: replaced"), "reported: " .. table.concat(changes, "; "))
end)

test("a snapshot detects an added key and a removed key", function()
    local added = diffAfter(function(F) F._state.extra = 1 end)
    T.truthy(mentions(added, "extra: added"), "added: " .. table.concat(added, "; "))
    local removed = diffAfter(function(F) F.DB._build = nil; F.DB._source = nil end)
    T.truthy(mentions(removed, "_source: removed"), "removed: " .. table.concat(removed, "; "))
end)

test("a snapshot detects a table swapped for an equal copy", function()
    local changes = diffAfter(function(F)
        local copy = {}
        for k, v in pairs(F._state.modules) do copy[k] = v end
        F._state.modules = copy
    end)
    T.truthy(mentions(changes, "modules: replaced"), "reported: " .. table.concat(changes, "; "))
end)

test("a snapshot detects one new SetScript log entry on a frame the library did not make", function()
    local changes = diffAfter(function(_, frame) frame:SetScript("OnUpdate", function() end) end)
    T.truthy(#changes > 0, "reported")
    T.truthy(mentions(changes, "SetScript"), "names the log: " .. table.concat(changes, "; "))
end)

test("a snapshot detects one new line of chat output", function()
    local changes = diffAfter(function() print("one line") end)
    T.truthy(#changes > 0, "reported")
    T.truthy(mentions(changes, "output"), "names the output: " .. table.concat(changes, "; "))
end)

test("a snapshot detects one changed saved-variable key", function()
    local changes = diffAfter(function() _G.TestDB.profileKeys.a = 2 end)
    T.truthy(mentions(changes, "TestDB.profileKeys.a: replaced"), "reported: " .. table.concat(changes, "; "))
end)

test("a snapshot detects a changed script on a frame, a new timer and a new slash entry", function()
    local scripts = diffAfter(function(_, frame)
        frame._scripts.OnEvent = function() end
    end)
    T.truthy(mentions(scripts, "_scripts.OnEvent: added"), "script: " .. table.concat(scripts, "; "))
    local timers = diffAfter(function() _G.C_Timer.After(1, function() end) end)
    T.truthy(#timers > 0, "timer: reported")
    local slash = diffAfter(function() _G.SlashCmdList.OTHER = function() end end)
    T.truthy(mentions(slash, "SlashCmdList.OTHER: added"), "slash: " .. table.concat(slash, "; "))
end)

test("a snapshot allows the appended record entry when told to, and nothing else", function()
    local function append(count)
        return function(F)
            for i = 1, count do F._state.copies[#F._state.copies + 1] = { unit = "core", n = i } end
        end
    end
    T.truthy(#diffAfter(append(1)) > 0, "an appended entry is a change by default")
    T.eq(#diffAfter(append(1), { copies = 1 }), 0, "one entry allowed")
    T.truthy(#diffAfter(append(2), { copies = 1 }) > 0, "two entries are more than allowed")
    local rewritten = diffAfter(function(F)
        F._state.copies[1] = { unit = "core" }
        F._state.extra = true
    end, { copies = 1 })
    T.truthy(mentions(rewritten, "extra: added"), "another change is still reported")
end)

return tests

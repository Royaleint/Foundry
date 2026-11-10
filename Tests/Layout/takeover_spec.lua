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
-- over it. Each unit's task deletes its own name once the unit takes over; the
-- ledger test then holds the list to exactly the units that still serve older
-- code. With the list empty the test is strict: no unit may serve older code.
-- The same list holds back every case below that needs behaviour the unit does not
-- have yet (the record's outcome words, the raise for a refused takeover).
local STILL_OLDER = { "core", "Commands", "Events", "Lifecycle", "DB", "List", "Settings", "Tooltip", "Menu", "Window" }

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
    surfaces.installSettingsLauncher()
    inst.settings = F.Settings:New({
        title = "TakeoverCanvas", frame = { GetObjectType = function() return "Frame" end },
    })
    surfaces.installTooltipProcessor()
    inst.tooltip = F.Tooltip:New({ type = 1, handler = function() end })
    surfaces.installMenuUtil()
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
-- coreRecord  "any" when the core's record entry is not pinned for this case
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
    { name = "a unit with layout 2", inject = setLayout(2), outcome = "layout", coreRecord = "any" },
    { name = "a unit with no layout", inject = setLayout(nil), outcome = "layout", coreRecord = "any" },
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
    elseif case.coreRecord ~= "any" and (case.outcome == "not used" or not pending(unit)) then
        T.eq(#copies, appendedBefore + 1, who .. "the core records one entry")
        local entry = copies[appendedBefore + 1]
        T.eq(entry.unit, "core", who .. "entry unit")
        T.eq(entry.source, "IncomingHost", who .. "entry source")
        T.eq(entry.outcome, case.outcome, who .. "entry outcome")
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
    local FILES = { "Foundry.lua", "Modules/Commands.lua", "Modules/Events.lua", "Modules/Lifecycle.lua", "Modules/DB.lua" }
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
        local changes = SN.diff(before, SN.take(F), { copies = 1 })
        T.eq(#changes, 0, mode .. ": nothing changes, but: " .. table.concat(changes, "; "))
        T.eq(#F._state.copies, appended + 1, mode .. ": only the core records")
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
-- The shape of each file after its decision block
--------------------------------------------------------------------------------

-- The files whose shape is not scanned yet. A file joins the scan when its
-- decision block lands and its unit leaves the ledger.
local SHAPE_PENDING = {
    "Foundry.lua", "Modules/Commands.lua", "Modules/Events.lua", "Modules/Lifecycle.lua", "Modules/DB.lua",
    "Modules/List.lua", "Modules/Settings.lua", "Modules/Tooltip.lua", "Modules/Menu.lua", "Modules/Window.lua",
}

-- The last line of the decision block; every top-level statement after it is
-- scanned.
local DECISION_END = "^local takingOver = served ~= nil$"

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
    for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
        lineNo = lineNo + 1
        if raw:gsub("\r$", ""):match(DECISION_END) then start = lineNo; break end
    end
    if not start then return { rel .. ": no decision block ends with '" .. DECISION_END .. "'" } end
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

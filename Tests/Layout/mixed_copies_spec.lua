-- Copies of the library from different releases loaded into one session, in
-- either order. The first copy keeps serving, a later copy stands down module
-- by module, modules the first copy lacks are taken from the later one and
-- work, and nothing is printed in a release build.
--
-- Most cases are relative to the 1.0.114 release: the current code takes the
-- role of the newer copy in one run, the pinned 1.0.114 copy takes the same
-- role in another, and everything a player or an addon can observe has to
-- match. The key sets on the library and module tables are then checked for
-- exactly the fields the current layout adds.

local T = ...

local surfaces = assert(loadfile(T.testsDir .. "/Layout/surfaces.lua"))(T)
local scenario = assert(loadfile(T.testsDir .. "/Layout/scenario.lua"))(T, surfaces)

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local MODULES = { "Commands", "Events", "Lifecycle", "DB", "List", "Settings", "Tooltip", "Menu", "Window" }
local LIBRARY_ADDITIONS = { "_build", "_layoutVersion", "_source", "_state" }
local MODULE_ADDITIONS = { "_build", "_impl", "_layoutVersion", "_source", "_state" }

local DEV_STAMP = "dev-1a2b3c4"
local OWN_DEV_NAME = "Foundry-1.0_DevBuild"

--------------------------------------------------------------------------------
-- Loading copies
--------------------------------------------------------------------------------

-- Each kind is a set of files with a root. "base" is the 1.0.114 release
-- standing in for the current code.
local KINDS = {
    old4   = { root = function() return T.testsDir .. "/OldCopies/v1.0.4" end,   files = function() return T.OLD_COPIES["v1.0.4"] end },
    old114 = { root = function() return T.testsDir .. "/OldCopies/v1.0.114" end, files = function() return T.OLD_COPIES["v1.0.114"] end },
    new    = { root = function() return T.foundryRoot end,                       files = function() return T.FOUNDRY_FILES end },
}
KINDS.base = KINDS.old114

local RELEASE_VERSION = { old4 = "1.0.4", old114 = "1.0.114", new = "1.0.200", base = "1.0.200" }

-- Loads a copy one file at a time, the way the client does: an error in one
-- file does not stop the next. Returns the errors, in order.
-- spec: kind, addonName, version (nil keeps the mock's default), skip (set of
-- module names whose files are left out)
local function loadKind(spec)
    local kind = KINDS[spec.kind]
    local errors = {}
    for _, rel in ipairs(kind.files()) do
        local module = rel:match("^Modules/(%w+)%.lua$")
        if not (module and spec.skip and spec.skip[module]) then
            local ok, err = pcall(T.loadCopy, {
                root = kind.root(), files = { rel },
                addonName = spec.addonName, version = spec.version,
            })
            if not ok then errors[#errors + 1] = tostring(err) end
        end
    end
    return errors
end

-- Resets the mocks and loads each entry in order. mode is "release" (every
-- copy answers a real version number) or "dev" (every copy answers the
-- unpackaged token). Returns the library table serving and the errors of
-- each load.
local function stack(entries, mode)
    T.installMocks("@project-version@")
    local errors = {}
    for i, entry in ipairs(entries) do
        local version = entry.version
        if version == nil and mode == "release" then version = RELEASE_VERSION[entry.kind] end
        errors[i] = loadKind({
            kind = entry.kind, addonName = entry.addonName or ("Host" .. i),
            version = version, skip = entry.skip,
        })
    end
    return _G.Foundry_1_0, errors
end

--------------------------------------------------------------------------------
-- Observing
--------------------------------------------------------------------------------

local function sortedKeys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = tostring(k) end
    table.sort(out)
    return out
end

local function keyString(t) return table.concat(sortedKeys(t), ",") end

local function setOf(list)
    local s = {}
    for _, v in ipairs(list) do s[v] = true end
    return s
end

local function splitKeys(s)
    local out = {}
    for k in s:gmatch("[^,]+") do out[#out + 1] = k end
    return out
end

-- The keys in after that are not in before, as a comma-separated string.
local function addedKeys(before, after)
    local have, out = setOf(splitKeys(before)), {}
    for _, k in ipairs(splitKeys(after)) do
        if not have[k] then out[#out + 1] = k end
    end
    return table.concat(out, ",")
end

-- The key string of a base key set plus the fields the current layout adds.
local function withAdditions(keys, additions)
    local set = setOf(splitKeys(keys))
    for _, k in ipairs(additions) do set[k] = true end
    return keyString(set)
end

-- Error text without its location, and without the directory of the file.
local function normalise(msg)
    msg = surfaces.normalise(msg)
    return (msg:gsub("%S*OldCopies[/\\]v[%d%.]+[/\\]", ""))
end

local function messageOf(err)
    return (tostring(err):gsub("^.-%.lua:%d+: ", ""))
end

-- Which copy a function came from, by its source file.
local function originOf(fn)
    local source = debug.getinfo(fn, "S").source
    if source:find("OldCopies[/\\]v1%.0%.4[/\\]") then return "old4" end
    if source:find("OldCopies[/\\]v1%.0%.114[/\\]") then return "old114" end
    return "new"
end

local function libraryOrigin(F) return originOf(F.HasModule) end

local function moduleOrigin(F, name)
    local m = F[name]
    if not m then return nil end
    return originOf(m.New or m.Attach)
end

local function dispatcherFrames()
    local n = 0
    for _, frame in ipairs(T.frames) do
        for _, call in ipairs(frame.calls.RegisterEvent) do
            if call[1] == "PLAYER_LOGOUT" then n = n + 1; break end
        end
    end
    return n
end

-- The number of functions waiting to run when the player logs out.
local function logoutEntries(F)
    local L = F.Lifecycle
    if L._layoutVersion then return #L._state.postLogout end
    for i = 1, 100 do
        local name, value = debug.getupvalue(L._RegisterPostLogout, i)
        if not name then break end
        if name == "postLogout" then return #value end
    end
    error("no logout list found on the serving Lifecycle")
end

local function registrations(F)
    local events = {}
    for i, frame in ipairs(T.frames) do
        for _, call in ipairs(frame.calls.RegisterEvent) do
            events[#events + 1] = i .. ":" .. tostring(call[1])
        end
    end
    local slashes = {}
    -- FOUNDRY is the /foundry copies command a current serving copy adds on its own
    -- (copies_record_spec); the pinned release has none.
    for k in pairs(SlashCmdList) do
        if k ~= "FOUNDRY" then slashes[#slashes + 1] = k end
    end
    table.sort(slashes)
    local present = {}
    for _, name in ipairs(MODULES) do
        if F:HasModule(name) then present[#present + 1] = name end
    end
    return {
        frames = #T.frames,
        events = table.concat(events, ","),
        slashes = table.concat(slashes, ","),
        timers = #T.afters,
        modules = table.concat(present, ","),
    }
end

local function copyList(list)
    local out = {}
    for i, v in ipairs(list) do out[i] = v end
    return out
end

-- What can be seen of the serving library right now.
local function snapshot(F)
    local snap = {
        output = copyList(T.output),
        registrations = registrations(F),
        libraryKeys = keyString(F),
        libraryOrigin = libraryOrigin(F),
        moduleKeys = {}, moduleOrigin = {}, moduleTables = {},
    }
    for _, name in ipairs(MODULES) do
        if F[name] then
            snap.moduleKeys[name] = keyString(F[name])
            snap.moduleOrigin[name] = moduleOrigin(F, name)
            snap.moduleTables[name] = F[name]
        end
    end
    return snap
end

local function assertRegistrationsEqual(a, b, what)
    for _, field in ipairs({ "frames", "events", "slashes", "timers", "modules" }) do
        T.eq(a[field], b[field], what .. ": " .. field)
    end
end

local function assertErrorsEqual(a, b, what)
    T.eq(#a, #b, what .. ": number of loads")
    for i = 1, #a do
        T.eq(#a[i], #b[i], what .. ": errors in load " .. i)
        for j = 1, #a[i] do
            T.eq(normalise(a[i][j]), normalise(b[i][j]), what .. ": error " .. i .. "." .. j)
        end
    end
end

--------------------------------------------------------------------------------
-- Using a library
--------------------------------------------------------------------------------

local function describe(v)
    if type(v) ~= "table" then return tostring(v) end
    local entries = {}
    for k, val in pairs(v) do entries[#entries + 1] = { tostring(k), describe(val) } end
    table.sort(entries, function(a, b) return a[1] < b[1] end)
    local parts = {}
    for i, e in ipairs(entries) do parts[i] = e[1] .. "=" .. e[2] end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- Uses every module the library has, once, and records what happened.
-- Anything raised is recorded rather than thrown, so two runs can be compared
-- whole. Returns the trace and the number of recorded errors.
local function use(F)
    local trace, failures = {}, 0
    local function note(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        trace[#trace + 1] = table.concat(parts, " ")
    end
    local function step(label, fn)
        local ok, err = pcall(fn)
        if not ok then
            failures = failures + 1
            note("error in " .. label .. ": " .. normalise(err))
        end
    end

    T.loadedAddons["MixedAddon"] = true
    step("DB", function()
        local db1 = F.DB:New({
            name = "MixedAddon", sv = "TestDB", defaultProfile = true,
            defaults = { profile = { size = 3 }, global = { flag = true } },
        })
        local db2 = F.DB:New({
            name = "MixedAddon", sv = "TestDB2", defaultProfile = true,
            defaults = { global = { other = 1 } },
        })
        note("db", db1.profile.size, db1.global.flag, db2.global.other)
        db1.profile.size = 9
    end)

    step("Events", function()
        local ev = F.Events:New("MixedAddon")
        ev:Register("MIXED_EVENT", function(event, arg) note("event", event, arg) end)
        ev:RegisterOnce("MIXED_ONCE", function(event, arg) note("once", event, arg) end)
        local frame = T.frames[#T.frames]
        T.Fire(frame, "MIXED_EVENT", 1)
        T.Fire(frame, "MIXED_ONCE", 2)
        T.Fire(frame, "MIXED_ONCE", 3)
    end)

    step("Commands", function()
        local cmds = F.Commands:New({ name = "Mixed", slashes = { "/mixed" } })
        cmds:Register({ name = "go", handler = function(...) note("slash", ...) end })
        SlashCmdList["MIXED"]("go now")
    end)

    local dispatcher
    step("Lifecycle", function()
        local lc = F.Lifecycle:New(nil, "MixedLC")
        lc:OnAddonLoaded(function() note("addon loaded") end)
        lc:OnLogin(function() note("login") end)
        lc:OnLogout(function() note("logout") end)
        dispatcher = surfaces.dispatcherFrame()
        T.Fire(dispatcher, "ADDON_LOADED", "MixedLC")
        T.Fire(dispatcher, "PLAYER_LOGIN")
    end)

    if F.List then step("List", function()
        local list = F.List:New({
            name = "MixedList", parent = {}, elementType = "Button",
            extentCalculator = function() return 20 end, initializer = function() note("row") end,
        })
        list:SetData({ { id = 1 } })
        note("list", type(list:GetNativeHandles().view))
    end) end

    if F.Settings then step("Settings", function()
        surfaces.installSettingsLauncher()
        local page = F.Settings:New({ title = "MixedPage", frame = { GetObjectType = function() return "Frame" end } })
        note("settings", type(page))
    end) end

    if F.Tooltip then step("Tooltip", function()
        local processor = surfaces.installTooltipProcessor()
        F.Tooltip:New({ type = 1, handler = function() note("tooltip") end })
        processor.postCalls[1].fn(surfaces.makeTooltip(), {})
    end) end

    if F.Menu then step("Menu", function()
        local menuUtil = surfaces.installMenuUtil()
        local menu = F.Menu:New({ builder = function() note("menu") end })
        menu:CreateContextMenu({})
        menuUtil.createCalls[1].generator({}, surfaces.makeRootDescription())
    end) end

    if F.Window then step("Window", function()
        local win = _G.CreateFrame("Frame", nil, _G.UIParent)
        F.Window:Attach(win, { handle = win, geometry = {}, default = { "CENTER", "CENTER", 0, 0 } })
        note("window attached")
    end) end

    step("logout", function()
        T.Fire(dispatcher, "PLAYER_LOGOUT")
        note("saved", describe(_G.TestDB), describe(_G.TestDB2))
    end)
    return trace, failures
end

--------------------------------------------------------------------------------
-- Orders of loading
--------------------------------------------------------------------------------

-- An old copy and the newer one, in either order. "new" is replaced by
-- "base" for the run the current code is compared against.
local ORDERS = {
    { name = "1.0.4 serving, newer later",   first = "old4",   second = "new" },
    { name = "1.0.114 serving, newer later", first = "old114", second = "new" },
    { name = "newer serving, 1.0.4 later",   first = "new",    second = "old4" },
    { name = "newer serving, 1.0.114 later", first = "new",    second = "old114" },
}

local function swapNew(kind, replacement)
    return kind == "new" and replacement or kind
end

local function runOrder(order, newKind, mode)
    local F, errors = stack({
        { kind = swapNew(order.first, newKind), addonName = "FirstHost" },
        { kind = swapNew(order.second, newKind), addonName = "SecondHost" },
    }, mode)
    local loaded = snapshot(F)
    loaded.errors = errors
    local trace, failures = use(F)
    return {
        F = F, loaded = loaded, used = snapshot(F), trace = trace, failures = failures,
        logoutEntries = logoutEntries(F), dispatchers = dispatcherFrames(),
    }
end

--------------------------------------------------------------------------------
-- The first copy keeps serving
--------------------------------------------------------------------------------

for _, mode in ipairs({ "release", "dev" }) do
    for _, firstKind in ipairs({ "old4", "old114" }) do
        test("the " .. firstKind .. " copy keeps serving when the current copy loads later (" .. mode .. " build)", function()
            T.installMocks("@project-version@")
            loadKind({ kind = firstKind, addonName = "FirstHost", version = mode == "release" and RELEASE_VERSION[firstKind] or nil })
            local F = _G.Foundry_1_0
            local before = snapshot(F)
            local frames = #T.frames
            local errors = loadKind({ kind = "new", addonName = "SecondHost", version = mode == "release" and RELEASE_VERSION.new or nil })
            local after = snapshot(F)

            T.eq(_G.Foundry_1_0, F, "the first copy keeps the global")
            -- A module the first copy lacks is the only thing that may appear.
            T.eq(addedKeys(before.libraryKeys, after.libraryKeys),
                firstKind == "old4" and "List,Menu,Settings,Tooltip,Window" or "", "keys added to the library table")
            T.eq(after.libraryOrigin, firstKind, "library table still runs the first copy's code")
            T.eq(#T.frames, frames, "no frame created")
            for _, name in ipairs({ "Commands", "Events", "Lifecycle", "DB" }) do
                T.eq(after.moduleTables[name], before.moduleTables[name], name .. " is still the first copy's table")
                T.eq(after.moduleKeys[name], before.moduleKeys[name], name .. " gained no key")
                T.eq(after.moduleOrigin[name], firstKind, name .. " still runs the first copy's code")
            end
            if mode == "release" then
                T.eq(#errors, 0, "no file raised an error")
                T.eq(#T.output, 0, "nothing printed")
            end
            if firstKind == "old114" then
                for _, name in ipairs(MODULES) do
                    T.eq(after.moduleTables[name], before.moduleTables[name], name .. " table unchanged")
                    T.eq(after.moduleOrigin[name], "old114", name .. " stayed with the first copy")
                end
            end
        end)
    end
end

--------------------------------------------------------------------------------
-- Observed the same as the 1.0.114 release
--------------------------------------------------------------------------------

for _, mode in ipairs({ "release", "dev" }) do
    for _, order in ipairs(ORDERS) do
        test(order.name .. ": outputs, errors, frames and registrations match the 1.0.114 release (" .. mode .. " build)", function()
            local current = runOrder(order, "new", mode)
            local baseline = runOrder(order, "base", mode)

            assertErrorsEqual(current.loaded.errors, baseline.loaded.errors, "load errors")
            T.eq(table.concat(current.loaded.output, "|"), table.concat(baseline.loaded.output, "|"), "output while loading")
            assertRegistrationsEqual(current.loaded.registrations, baseline.loaded.registrations, "after loading")

            T.eq(current.failures, baseline.failures, "number of failed steps while using the libraries")
            T.eq(table.concat(current.trace, "\n"), table.concat(baseline.trace, "\n"), "what using every module did")
            T.eq(table.concat(current.used.output, "|"), table.concat(baseline.used.output, "|"), "output after use")
            assertRegistrationsEqual(current.used.registrations, baseline.used.registrations, "after use")
            T.eq(current.logoutEntries, baseline.logoutEntries, "logout entries")
            T.eq(current.dispatchers, baseline.dispatchers, "dispatcher frames")
        end)

        test(order.name .. ": key sets differ from the 1.0.114 release only by the layout fields (" .. mode .. " build)", function()
            local current = runOrder(order, "new", mode)
            local baseline = runOrder(order, "base", mode)

            local libraryFromNew = current.loaded.libraryOrigin == "new"
            T.eq(baseline.loaded.libraryOrigin, libraryFromNew and "old114" or current.loaded.libraryOrigin, "library table origin")
            T.eq(current.loaded.libraryKeys,
                libraryFromNew and withAdditions(baseline.loaded.libraryKeys, LIBRARY_ADDITIONS) or baseline.loaded.libraryKeys,
                "library table keys")

            for _, name in ipairs(MODULES) do
                local origin = current.loaded.moduleOrigin[name]
                T.eq(baseline.loaded.moduleOrigin[name], origin == "new" and "old114" or origin, name .. " origin")
                if origin == "new" then
                    T.eq(current.loaded.moduleKeys[name],
                        withAdditions(baseline.loaded.moduleKeys[name], MODULE_ADDITIONS), name .. " keys")
                else
                    T.eq(current.loaded.moduleKeys[name], baseline.loaded.moduleKeys[name], name .. " keys")
                end
                -- Using the modules adds nothing to their tables either.
                T.eq(current.used.moduleKeys[name], current.loaded.moduleKeys[name], name .. " keys after use")
            end
            T.eq(current.used.libraryKeys, current.loaded.libraryKeys, "library keys after use")
        end)
    end
end

test("a current copy adds exactly four keys to the library table and five to each module, and removes none", function()
    T.installMocks("@project-version@")
    loadKind({ kind = "base", addonName = "OnlyHost", version = "1.0.200" })
    local baseline = snapshot(_G.Foundry_1_0)
    T.installMocks("@project-version@")
    loadKind({ kind = "new", addonName = "OnlyHost", version = "1.0.200" })
    local current = snapshot(_G.Foundry_1_0)

    local function added(baseKeys, currentKeys)
        local baseSet, have, out = setOf(splitKeys(baseKeys)), setOf(splitKeys(currentKeys)), {}
        for k in pairs(baseSet) do T.truthy(have[k], "kept " .. k) end
        for _, k in ipairs(splitKeys(currentKeys)) do
            if not baseSet[k] then out[#out + 1] = k end
        end
        return table.concat(out, ",")
    end
    T.eq(added(baseline.libraryKeys, current.libraryKeys), "_build,_layoutVersion,_source,_state", "keys added to the library table")
    for _, name in ipairs(MODULES) do
        T.eq(added(baseline.moduleKeys[name], current.moduleKeys[name]), "_build,_impl,_layoutVersion,_source,_state", "keys added to " .. name)
    end
end)

--------------------------------------------------------------------------------
-- Modules missing from the first copy graft in from the later one
--------------------------------------------------------------------------------

test("modules missing from a 1.0.4 copy come from the current copy loaded later, and they work", function()
    local F = stack({
        { kind = "old4", addonName = "FirstHost" },
        { kind = "new", addonName = "SecondHost" },
    }, "release")
    for _, name in ipairs({ "List", "Settings", "Tooltip", "Menu", "Window" }) do
        T.truthy(F:HasModule(name), name .. " present")
        T.eq(moduleOrigin(F, name), "new", name .. " comes from the current copy")
        T.eq(F[name]._source, "SecondHost", name .. " records the copy it came from")
        T.eq(F[name]._layoutVersion, 1, name .. " layout version")
    end
    for _, name in ipairs({ "Commands", "Events", "Lifecycle", "DB" }) do
        T.eq(moduleOrigin(F, name), "old4", name .. " stays with the first copy")
        T.eq(F[name]._layoutVersion, nil, name .. " has no layout fields")
    end
    local trace, failures = use(F)
    T.eq(failures, 0, "every module worked: " .. table.concat(trace, " | "))
    T.eq(#T.output, 0, "nothing printed")
end)

test("a current module loaded onto an older library table reads none of the new layout fields", function()
    for _, firstKind in ipairs({ "old4", "old114" }) do
        T.installMocks("@project-version@")
        loadKind({ kind = firstKind, addonName = "FirstHost", version = RELEASE_VERSION[firstKind] })
        local F = _G.Foundry_1_0
        local missing = {}
        setmetatable(F, { __index = function(_, key) missing[#missing + 1] = tostring(key) end })
        loadKind({ kind = "new", addonName = "SecondHost", version = RELEASE_VERSION.new })
        setmetatable(F, nil)
        local seen = setOf(missing)
        T.falsy(seen._state, firstKind .. ": the state field is never read")
        T.falsy(seen._layoutVersion, firstKind .. ": the layout version is never read")
        T.falsy(seen._impl, firstKind .. ": the implementation table is never read")
        T.eq(rawget(F, "_state"), nil, firstKind .. ": the older library table gains no state")
        T.eq(rawget(F, "_layoutVersion"), nil, firstKind .. ": the older library table gains no layout version")
    end
end)

test("a trimmed 1.0.114 library takes the current DB and Window modules, and they work", function()
    local F = stack({
        { kind = "old114", addonName = "FirstHost", skip = { DB = true, Window = true } },
        { kind = "new", addonName = "SecondHost" },
    }, "release")
    T.eq(moduleOrigin(F, "DB"), "new", "DB comes from the current copy")
    T.eq(moduleOrigin(F, "Window"), "new", "Window comes from the current copy")
    for _, name in ipairs({ "Commands", "Events", "Lifecycle", "List", "Settings", "Tooltip", "Menu" }) do
        T.eq(moduleOrigin(F, name), "old114", name .. " stays with the first copy")
    end
    T.eq(F.DB._layoutVersion, 1, "DB layout version")
    local trace, failures = use(F)
    T.eq(failures, 0, "every module worked: " .. table.concat(trace, " | "))
    T.eq(logoutEntries(F), 1, "one logout entry")
    T.eq(dispatcherFrames(), 1, "one dispatcher frame")
    T.eq(#T.output, 0, "nothing printed")
end)

test("a trimmed current library takes the 1.0.114 Menu and Window modules, listed without layout fields", function()
    local F = stack({
        { kind = "new", addonName = "FirstHost", skip = { Menu = true, Window = true } },
        { kind = "old114", addonName = "SecondHost" },
    }, "release")
    for _, name in ipairs({ "Menu", "Window" }) do
        T.eq(moduleOrigin(F, name), "old114", name .. " comes from the older copy")
        T.eq(F._state.modules[name], F[name], name .. " is listed on the state table")
        T.eq(F[name]._layoutVersion, nil, name .. " has no layout version")
        T.eq(F[name]._state, nil, name .. " has no state table")
    end
    for _, name in ipairs({ "Commands", "Events", "Lifecycle", "DB", "List", "Settings", "Tooltip" }) do
        T.eq(moduleOrigin(F, name), "new", name .. " stays with the first copy")
        T.eq(F._state.modules[name], F[name], name .. " is listed on the state table")
    end
    local trace, failures = use(F)
    T.eq(failures, 0, "every module worked: " .. table.concat(trace, " | "))
    T.eq(logoutEntries(F), 1, "one logout entry")
    T.eq(dispatcherFrames(), 1, "one dispatcher frame")
    T.eq(#T.output, 0, "nothing printed")
end)

test("an older copy loaded after the current one asks the state table whether a module is present", function()
    local F = stack({ { kind = "new", addonName = "FirstHost" } }, "release")
    F._state.modules.Probe = {}
    T.truthy(F:HasModule("Probe"), "a name on the state table is present")
    F._state.modules.Probe = nil
    T.falsy(F:HasModule("Probe"), "and absent once removed")

    -- Take Window off the state table only: the older copy's Window file asks
    -- the list, finds nothing, and registers itself.
    local window = F.Window
    F._state.modules.Window = nil
    F.Window = nil
    loadKind({ kind = "old114", addonName = "SecondHost", version = RELEASE_VERSION.old114 })
    T.truthy(F.Window ~= nil and F.Window ~= window, "the older Window took the empty place")
    T.eq(F._state.modules.Window, F.Window, "and is listed on the state table")
    T.eq(moduleOrigin(F, "Window"), "old114", "it runs the older copy's code")
    for _, name in ipairs({ "Commands", "Events", "Lifecycle", "DB", "List", "Settings", "Tooltip", "Menu" }) do
        T.eq(moduleOrigin(F, name), "new", name .. " untouched")
    end
end)

--------------------------------------------------------------------------------
-- One dispatcher frame and one logout entry
--------------------------------------------------------------------------------

for _, order in ipairs(ORDERS) do
    test(order.name .. ": one dispatcher frame and one logout entry after two databases and a lifecycle controller exist", function()
        local run = runOrder(order, "new", "release")
        T.eq(run.failures, 0, "every module worked: " .. table.concat(run.trace, " | "))
        T.eq(run.dispatchers, 1, "dispatcher frames")
        T.eq(run.logoutEntries, 1, "logout entries")
        T.eq(#run.used.output, 0, "nothing printed")
    end)
end

test("one dispatcher frame and one logout entry after the full scenario on the current copy alone", function()
    local F = stack({ { kind = "new", addonName = "OnlyHost" } }, "release")
    scenario.run(F)
    T.eq(dispatcherFrames(), 1, "dispatcher frames")
    T.eq(logoutEntries(F), 1, "logout entries")
end)

test("one dispatcher frame and one logout entry when more copies load after the scenario", function()
    local F = stack({ { kind = "new", addonName = "OnlyHost" } }, "release")
    scenario.run(F)
    loadKind({ kind = "new", addonName = "OtherHost", version = RELEASE_VERSION.new })
    loadKind({ kind = "old114", addonName = "OldHost", version = RELEASE_VERSION.old114 })
    T.eq(dispatcherFrames(), 1, "dispatcher frames")
    T.eq(logoutEntries(F), 1, "logout entries")
end)

--------------------------------------------------------------------------------
-- Loading every file a second time
--------------------------------------------------------------------------------

-- Every table and scalar reachable from root, as path -> description, so two
-- walks of the same tables can be compared whole.
local function deepSnapshot(root)
    local seen, out = {}, {}
    local function walk(value, path)
        if type(value) ~= "table" then
            out[path] = type(value) .. ":" .. tostring(value)
            return
        end
        out[path] = "table:" .. tostring(value)
        if seen[value] then return end
        seen[value] = true
        local byName = {}
        for k in pairs(value) do byName[tostring(k)] = k end
        for name, k in pairs(byName) do walk(value[k], path .. "/" .. name) end
        local mt = getmetatable(value)
        if mt then walk(mt, path .. "/<metatable>") end
    end
    walk(root, "root")
    return out
end

local function assertSnapshotsEqual(a, b, what)
    for path, desc in pairs(a) do
        if b[path] ~= desc then
            error(what .. ": " .. path .. " changed from " .. desc .. " to " .. tostring(b[path]), 2)
        end
    end
    for path, desc in pairs(b) do
        if a[path] == nil then error(what .. ": " .. path .. " appeared (" .. desc .. ")", 2) end
    end
end

test("loading every file a second time against a used library changes no state, makes no frame and prints nothing", function()
    local F = stack({ { kind = "new", addonName = "OnlyHost" } }, "release")
    scenario.run(F)
    -- The record of copies not used grows by one per copy loaded; the rest of the library state does not.
    local view = {}
    local function libraryState()
        for key in pairs(view) do view[key] = nil end
        for key, value in pairs(F._state) do
            if key ~= "copies" then view[key] = value end
        end
        return view
    end
    local roots = {}
    local recordBefore = {}
    for i, entry in ipairs(F._state.copies) do recordBefore[i] = entry end
    roots.record = recordBefore
    for _, name in ipairs(MODULES) do roots[name] = { state = F[name]._state, impl = F[name]._impl } end
    local before = { library = deepSnapshot(libraryState()) }
    for label, root in pairs(roots) do before[label] = deepSnapshot(root) end
    local seenBefore = snapshot(F)
    local frames = #T.frames
    T.eq(#T.output, 0, "nothing printed by the scenario")

    for _, name in ipairs({ "OnlyHost", "AnotherHost" }) do
        local errors = loadKind({ kind = "new", addonName = name, version = RELEASE_VERSION.new })
        T.eq(#errors, 0, "no file raised an error")
    end

    T.eq(#F._state.copies, #recordBefore + 2, "each later copy added one entry to the record")
    for i, entry in ipairs(recordBefore) do
        T.eq(F._state.copies[i], entry, "record entry " .. i .. " is unchanged")
    end
    assertSnapshotsEqual(before.library, deepSnapshot(libraryState()), "library state")
    for label, root in pairs(roots) do
        assertSnapshotsEqual(before[label], deepSnapshot(root), label .. " state")
    end
    local seenAfter = snapshot(F)
    T.eq(seenAfter.libraryKeys, seenBefore.libraryKeys, "library keys")
    for _, name in ipairs(MODULES) do
        T.eq(seenAfter.moduleTables[name], seenBefore.moduleTables[name], name .. " is the same table")
        T.eq(seenAfter.moduleKeys[name], seenBefore.moduleKeys[name], name .. " keys")
    end
    T.eq(#T.frames, frames, "no frame created")
    T.eq(#T.output, 0, "nothing printed")
    T.eq(dispatcherFrames(), 1, "dispatcher frames")
    T.eq(logoutEntries(F), 1, "logout entries")
end)

--------------------------------------------------------------------------------
-- Nothing printed in a release build
--------------------------------------------------------------------------------

local KIND_NAMES = { "old4", "old114", "new" }

for _, first in ipairs(KIND_NAMES) do
    for _, second in ipairs(KIND_NAMES) do
        test("release build silent: " .. first .. " serving, " .. second .. " loaded later, and the current copy after that", function()
            local F, errors = stack({
                { kind = first, addonName = "FirstHost" },
                { kind = second, addonName = "SecondHost" },
                { kind = "new", addonName = "ThirdHost" },
            }, "release")
            for i, list in ipairs(errors) do T.eq(#list, 0, "copy " .. i .. " raised no error") end
            T.eq(table.concat(T.output, "\n"), "", "printed while loading")
            local trace, failures = use(F)
            T.eq(failures, 0, "every module worked: " .. table.concat(trace, " | "))
            T.eq(table.concat(T.output, "\n"), "", "printed while using")
        end)
    end
end

--------------------------------------------------------------------------------
-- Development builds
--------------------------------------------------------------------------------

local SUPPRESSED = "Foundry-1.0: an enabled Foundry-1.0 DevBuild was suppressed; "
    .. "the first-loaded release copy (version %s) is serving and this DevBuild loaded nothing"

for _, firstKind in ipairs({ "old4", "old114" }) do
    test("a development build of the current copy loaded after the " .. firstKind .. " release prints the single suppressed line", function()
        T.installMocks("@project-version@")
        local release = RELEASE_VERSION[firstKind]
        loadKind({ kind = firstKind, addonName = "FirstHost", version = release })
        local F = _G.Foundry_1_0
        local before = snapshot(F)
        local frames = #T.frames

        local errors = loadKind({ kind = "new", addonName = OWN_DEV_NAME, version = DEV_STAMP })
        T.eq(#errors, 0, "no file raised an error: the serving release copy prints instead")
        T.eq(#T.output, 1, "exactly one line printed")
        T.eq(T.output[1], SUPPRESSED:format(release), "the line")
        T.eq(#T.frames, frames, "no frame created")
        T.eq(addedKeys(before.libraryKeys, snapshot(F).libraryKeys),
            firstKind == "old4" and "List,Menu,Settings,Tooltip,Window" or "", "keys added to the library table")
        T.eq(snapshot(F).moduleTables.Commands, before.moduleTables.Commands, "Commands untouched")
        T.eq(F.Commands._layoutVersion, nil, "and without layout fields")
        T.eq(_G.Foundry_1_0, F, "the release copy keeps the global")
    end)

    test("the current copy loaded after the " .. firstKind .. " release under a host addon name with a development stamp is silent", function()
        T.installMocks("@project-version@")
        loadKind({ kind = firstKind, addonName = "FirstHost", version = RELEASE_VERSION[firstKind] })
        local F = _G.Foundry_1_0
        local before = snapshot(F)
        local frames = #T.frames
        local errors = loadKind({ kind = "new", addonName = "SomeHostAddon", version = DEV_STAMP })
        T.eq(#errors, 0, "no file raised an error")
        T.eq(#T.output, 0, "nothing printed")
        T.eq(#T.frames, frames, "no frame created")
        local after = snapshot(F)
        T.eq(addedKeys(before.libraryKeys, after.libraryKeys),
            firstKind == "old4" and "List,Menu,Settings,Tooltip,Window" or "", "keys added to the library table")
        for _, name in ipairs({ "Commands", "Events", "Lifecycle", "DB" }) do
            T.eq(after.moduleTables[name], before.moduleTables[name], name .. " untouched")
        end
    end)
end

local function assertNothingChanged(F, before, frames)
    local after = snapshot(F)
    T.eq(#T.output, 0, "nothing printed")
    T.eq(#T.frames, frames, "no frame created")
    T.eq(after.libraryKeys, before.libraryKeys, "library table untouched")
    for _, name in ipairs(MODULES) do
        T.eq(after.moduleTables[name], before.moduleTables[name], name .. " table untouched")
        T.eq(after.moduleKeys[name], before.moduleKeys[name], name .. " keys untouched")
        T.eq(after.moduleOrigin[name], "new", name .. " still the current copy's")
        T.eq(F._state.modules[name], F[name], name .. " still listed on the state table")
    end
    T.eq(after.registrations.events, before.registrations.events, "no event registered")
    T.eq(after.registrations.slashes, before.registrations.slashes, "no slash command registered")
    T.eq(after.registrations.timers, before.registrations.timers, "no timer started")
end

test("a development build of the current copy serving, with 1.0.4 loaded later, raises 1.0.4's own suppression error and nothing changes", function()
    T.installMocks("@project-version@")
    loadKind({ kind = "new", addonName = OWN_DEV_NAME, version = DEV_STAMP })
    local F = _G.Foundry_1_0
    T.eq(F.IS_DEV_BUILD, true, "the serving copy reads as a development build")
    local before = snapshot(F)
    local frames = #T.frames

    local errors = loadKind({ kind = "old4", addonName = "OldHost", version = RELEASE_VERSION.old4 })
    T.eq(#errors, 1, "exactly one file raised")
    T.truthy(errors[1]:find("OldCopies", 1, true) and errors[1]:find("Foundry.lua", 1, true), "raised by the 1.0.4 library file")
    T.eq(messageOf(errors[1]),
        "Foundry-1.0: a redundant embedded Foundry-1.0 copy was suppressed; the first-loaded copy is serving",
        "the message")
    assertNothingChanged(F, before, frames)
end)

test("a development build of the current copy serving, with 1.0.114 loaded later, is silent and nothing changes", function()
    T.installMocks("@project-version@")
    loadKind({ kind = "new", addonName = OWN_DEV_NAME, version = DEV_STAMP })
    local F = _G.Foundry_1_0
    T.eq(F.IS_DEV_BUILD, true, "the serving copy reads as a development build")
    local before = snapshot(F)
    local frames = #T.frames

    local errors = loadKind({ kind = "old114", addonName = "OldHost", version = RELEASE_VERSION.old114 })
    T.eq(#errors, 0, "no file raised an error")
    assertNothingChanged(F, before, frames)
end)

return tests

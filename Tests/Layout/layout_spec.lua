-- The library table's layout header and shared state, and the source rule
-- that keeps module state off file-level locals.

local T = ...

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

test("the serving copy carries the layout version and the state table", function()
    local F = T.fresh()
    T.eq(F._layoutVersion, 1, "layout version")
    T.eq(type(F._state), "table", "state table")
    T.eq(type(F._state.modules), "table", "module list")
end)

test("the module methods use the module list held on the state table", function()
    local F = T.fresh()
    local mod = { API_VERSION = 3 }
    T.falsy(F:HasModule("Probe"), "absent before registering")
    T.eq(F:RegisterModule("Probe", mod), mod, "register returns the module")
    T.eq(F._state.modules.Probe, mod, "listed on the state table")
    T.truthy(F:HasModule("Probe"), "found after registering")
    T.eq(F:RequireModule("Probe", 3), mod, "required module")

    local other = { API_VERSION = 1 }
    F._state.modules.Planted = other
    T.truthy(F:HasModule("Planted"), "a module placed on the table is seen")
    T.eq(F:RequireModule("Planted"), other, "and required")
    F._state.modules.Planted = nil
    T.falsy(F:HasModule("Planted"), "and gone when removed")
end)

test("every bundled module is listed on the state table", function()
    local F = T.fresh()
    for _, name in ipairs({ "Commands", "Events", "Lifecycle", "DB", "List", "Settings", "Tooltip", "Menu", "Window" }) do
        T.truthy(F._state.modules[name] ~= nil, name .. " listed")
        T.eq(F._state.modules[name], F[name], name .. " is the module on the table")
    end
end)

test("a copy that stands down leaves the serving table untouched", function()
    local F = T.fresh()
    local state, modules = F._state, F._state.modules
    F:RegisterModule("Probe", {})
    local chunk = assert(loadfile(T.foundryRoot .. "/Foundry.lua"))
    chunk("Foundry-1.0")
    T.eq(_G.Foundry_1_0, F, "the first copy keeps the global")
    T.eq(F._state, state, "state table unchanged")
    T.eq(F._state.modules, modules, "module list unchanged")
    T.truthy(F:HasModule("Probe"), "earlier registration kept")
    T.eq(F._layoutVersion, 1, "layout version unchanged")
end)

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local LIFECYCLE_STATE_TABLES = {
    "byAddonName", "ownedNames", "loginControllers", "unloadingControllers", "postLogout", "identityHeld",
}
local LIFECYCLE_STATE_FLAGS = {
    "unloadingSupported", "loginFired", "identityWatching", "pollScheduled", "identityStopped",
    "devNoticePrinted", "surnameSettled",
}
local LIFECYCLE_IMPL = {
    "Controller", "onEvent", "pollTick", "releaseIdentityHeld", "holdForIdentity", "schedulePoll",
    "surfaceHookError", "identityResolved", "stopWatching", "ensureDispatcher",
}

test("Lifecycle carries the layout header, its state and its implementation", function()
    local F = T.fresh()
    local L = F.Lifecycle
    T.eq(L._layoutVersion, 1, "layout version")
    T.eq(L._source, "Foundry-1.0", "source addon name")
    T.eq(L._build, nil, "no build stamp yet")
    T.eq(type(L._state), "table", "state table")
    T.eq(type(L._impl), "table", "implementation table")
    for _, name in ipairs(LIFECYCLE_STATE_TABLES) do
        T.eq(type(L._state[name]), "table", "state " .. name)
    end
    for _, name in ipairs(LIFECYCLE_STATE_FLAGS) do
        T.eq(L._state[name], false, "flag " .. name .. " starts false")
    end
    T.eq(L._state.dispatcher, nil, "no dispatcher before the first controller")
    for _, name in ipairs(LIFECYCLE_IMPL) do
        T.eq(type(L._impl[name]), name == "Controller" and "table" or "function", "implementation " .. name)
    end
    local c = L:New(nil, "LayoutHeader")
    T.eq(getmetatable(c), L._impl.Controller, "controllers use the published method table")
end)

test("Lifecycle's dispatcher runs the event handler published on the module table", function()
    local F = T.fresh()
    local L = F.Lifecycle
    local c = L:New(nil, "LayoutDispatcher")
    local frame = L._state.dispatcher
    T.truthy(frame, "dispatcher created by the first controller")
    T.eq(frame, T.frames[1], "the one dispatcher frame")
    T.eq(frame:GetScript("OnEvent"), L._impl.onEvent, "OnEvent is the published handler")
    T.eq(c:GetNativeHandles().frame, frame, "consumers are handed the same frame")
    L:New(nil, "LayoutDispatcherTwo")
    T.eq(L._state.dispatcher, frame, "a second controller keeps the frame")
    T.eq(#T.frames, 1, "no second frame")
end)

test("after one identity hold is released, a second hold uses the live held set and fires on time", function()
    local F = T.fresh()
    local L = F.Lifecycle
    T.SetRegional(true)   -- surname missing until the first poll settles it
    local frame

    local firstFired = 0
    local a = L:New(nil, "HoldFirst")
    a:OnAddonLoaded(function() firstFired = firstFired + 1 end)
    frame = L._state.dispatcher
    T.Fire(frame, "ADDON_LOADED", "HoldFirst")
    local firstSet = L._state.identityHeld
    T.eq(firstSet[1], a, "first controller held")
    T.eq(firstFired, 0, "not fired while held")
    T.Fire(frame, "PLAYER_LOGIN")
    T.Fire(frame, "PLAYER_ENTERING_WORLD")
    T.RunAfters()
    T.eq(firstFired, 1, "first hold released by the poll")
    T.eq(L._identityResolvedBy, "POLL", "released by the poll")
    T.truthy(L._state.identityHeld ~= firstSet, "the held set was replaced on release")
    T.eq(#L._state.identityHeld, 0, "nothing held after release")
    T.falsy(L._state.identityWatching, "identity events no longer watched")

    -- The name goes missing again, so the next controllers are held.
    T.identity = { name = "Unknown", realm = T.identity.realm }
    local addonFired, loginFired, droppedFired = 0, 0, 0
    local b = L:New(nil, "HoldSecond")
    b:OnAddonLoaded(function() addonFired = addonFired + 1 end)
    local d = L:New(nil, "HoldDropped")
    d:OnAddonLoaded(function() droppedFired = droppedFired + 1 end)
    T.Fire(frame, "ADDON_LOADED", "HoldSecond")
    T.Fire(frame, "ADDON_LOADED", "HoldDropped")
    b:OnLogin(function() loginFired = loginFired + 1 end)   -- held, so it waits for the release
    local held = L._state.identityHeld
    T.eq(#held, 2, "both held in the live set")
    T.eq(held[1], b, "second controller held first")
    T.eq(held[2], d, "third controller held next")
    T.eq(#firstSet, 1, "the released set is left as it was")
    T.truthy(L._state.identityWatching, "identity events watched again")
    T.eq(addonFired + loginFired, 0, "nothing fired while the name is missing")

    d:Destroy()
    T.eq(#L._state.identityHeld, 1, "a destroyed controller leaves the live set")
    T.eq(L._state.identityHeld[1], b, "the other stays held")

    T.Fire(frame, "UNIT_NAME_UPDATE", "player")
    T.RunAfters()
    T.eq(addonFired + loginFired, 0, "still held while the name is missing")
    T.eq(#T.afters, 1, "the poll re-armed itself")

    T.identity = { name = "Tester", realm = T.identity.realm }
    T.Fire(frame, "UNIT_NAME_UPDATE", "player")
    T.eq(addonFired, 1, "addon-loaded fired when the name arrived")
    T.eq(loginFired, 1, "login fired with it")
    T.eq(L._identityResolvedBy, "UNIT_NAME_UPDATE", "released by the name update")
    T.eq(#L._state.identityHeld, 0, "nothing held after the second release")
    T.RunAfters()
    T.eq(addonFired + loginFired, 2, "the pending poll fires nothing more")
    T.eq(droppedFired, 0, "the destroyed controller never fired")
end)

test("entering the world after a release there reads the new, empty held set", function()
    local F = T.fresh()
    local L = F.Lifecycle
    T.identity = { name = "Unknown", realm = T.identity.realm }
    local fired = 0
    local c = L:New(nil, "HoldEnterWorld")
    c:OnAddonLoaded(function() fired = fired + 1 end)
    local frame = L._state.dispatcher
    T.Fire(frame, "ADDON_LOADED", "HoldEnterWorld")
    T.Fire(frame, "PLAYER_LOGIN")
    T.eq(fired, 0, "held through login while the name is missing")
    T.eq(#T.afters, 0, "no poll before entering the world")

    T.identity = { name = "Tester", realm = T.identity.realm }
    T.Fire(frame, "PLAYER_ENTERING_WORLD")
    T.eq(fired, 1, "released on entering the world")
    T.eq(L._identityResolvedBy, "PLAYER_ENTERING_WORLD", "released by entering the world")
    T.eq(#T.output, 0, "no waiting notice once the hold is released")
    T.falsy(L._state.devNoticePrinted, "the notice was not used up")
    T.eq(#T.afters, 0, "no poll scheduled")
end)

test("the poll timer reaches whatever pollTick the module table holds when it fires", function()
    local F = T.fresh()
    local L = F.Lifecycle
    T.SetRegional(true)
    local c = L:New(nil, "PollRelay")
    c:OnAddonLoaded(function() end)
    local frame = L._state.dispatcher
    T.Fire(frame, "ADDON_LOADED", "PollRelay")
    T.Fire(frame, "PLAYER_LOGIN")
    T.Fire(frame, "PLAYER_ENTERING_WORLD")
    T.eq(#T.afters, 1, "one poll pending")
    T.truthy(T.afters[1].cb ~= L._impl.pollTick, "the timer holds a relay, not the tick itself")

    local original = L._impl.pollTick
    local calls = 0
    L._impl.pollTick = function() calls = calls + 1 end
    T.RunAfters()
    L._impl.pollTick = original
    T.eq(calls, 1, "the replaced tick ran once")
    T.eq(L._state.identityHeld[1], c, "the original tick did not run")
end)

--------------------------------------------------------------------------------
-- DB
--------------------------------------------------------------------------------

local DB_STATE_TABLES = { "liveControllers", "liveControllersByAddon", "controllerStore", "stores" }
local DB_IMPL = {
    "Controller", "controllerMeta", "onLogout", "onSavedVariablesTooLarge", "materialize", "makeOnMismatch",
}

local function newStore(F, sv, defaults)
    T.loadedAddons["LayoutDBAddon"] = true
    return F.DB:New({
        name = "LayoutDBAddon", sv = sv, defaultProfile = true,
        defaults = defaults or { profile = { size = 3 }, global = { flag = true } },
    })
end

-- How many times fn appears in the logout list of the Lifecycle serving F:
-- its state table when it has one, else the list _RegisterPostLogout holds.
local function logoutEntries(F, fn)
    local list = F.Lifecycle._layoutVersion and F.Lifecycle._state.postLogout
    if not list then
        local i = 1
        while true do
            local name, value = debug.getupvalue(F.Lifecycle._RegisterPostLogout, i)
            if not name then break end
            if name == "postLogout" then list = value end
            i = i + 1
        end
    end
    local n = 0
    for i = 1, #list do
        if rawequal(list[i], fn) then n = n + 1 end
    end
    return n, #list
end

-- The frame Lifecycle delivers its events through: the one that registered PLAYER_LOGOUT.
local function logoutFrame()
    for _, frame in ipairs(T.frames) do
        for _, call in ipairs(frame.calls.RegisterEvent) do
            if call[1] == "PLAYER_LOGOUT" then return frame end
        end
    end
end

local function deepEqual(a, b, path, diffs)
    if type(a) ~= type(b) then
        diffs[#diffs + 1] = path .. ": " .. type(a) .. " vs " .. type(b)
    elseif type(a) ~= "table" then
        if a ~= b then diffs[#diffs + 1] = path .. ": " .. tostring(a) .. " vs " .. tostring(b) end
    else
        for k, v in pairs(a) do deepEqual(v, b[k], path .. "." .. tostring(k), diffs) end
        for k, v in pairs(b) do
            if a[k] == nil then deepEqual(nil, v, path .. "." .. tostring(k), diffs) end
        end
    end
    return diffs
end

test("DB carries the layout header, its state and its implementation", function()
    local F = T.fresh()
    local D = F.DB
    T.eq(D._layoutVersion, 1, "layout version")
    T.eq(D._source, "Foundry-1.0", "source addon name")
    T.eq(D._build, nil, "no build stamp yet")
    T.eq(type(D._state), "table", "state table")
    T.eq(type(D._impl), "table", "implementation table")
    for _, name in ipairs(DB_STATE_TABLES) do
        T.eq(type(D._state[name]), "table", "state " .. name)
    end
    T.eq(D._state.postLogoutRegistered, false, "logout entry not registered before the first store")
    T.eq(D._state.postLogoutEntry, nil, "no logout entry before the first store")
    T.eq(D._state.sizeWarningEvents, nil, "no size-warning events before the first store")
    for _, name in ipairs(DB_IMPL) do
        local want = (name == "Controller" or name == "controllerMeta") and "table" or "function"
        T.eq(type(D._impl[name]), want, "implementation " .. name)
    end
end)

test("DB controllers use the published metatable, and the store record is held on the state table", function()
    local F = T.fresh()
    local D = F.DB
    local meta = D._impl.controllerMeta
    local db = newStore(F, "LayoutMetaDB")
    T.eq(getmetatable(db), meta, "a controller's metatable is the published one")
    T.eq(D._state.controllerStore[db].svName, "LayoutMetaDB", "store record found on the state table")
    T.eq(D._state.stores[1], D._state.controllerStore[db], "the same record is listed in stores")
    T.eq(D._state.liveControllers.LayoutMetaDB, db, "live controller listed by saved-variables name")
    T.eq(D._state.liveControllersByAddon.LayoutDBAddon[1], db, "live controller listed by addon")
    T.eq(type(D._state.controllerStore[db].onMismatch), "function", "store has its mismatch handler")
    local second = newStore(F, "LayoutMetaDB2")
    T.eq(D._impl.controllerMeta, meta, "the metatable keeps its identity")
    T.eq(getmetatable(second), meta, "a later controller shares it")
    T.eq(getmetatable(db), meta, "the first controller still uses it")
end)

test("DB registers its size warning through the published handler", function()
    local F = T.fresh()
    local D = F.DB
    newStore(F, "LayoutSizeDB")
    local events = D._state.sizeWarningEvents
    T.truthy(events, "size-warning events created by the first store")
    T.eq(events._handlers.SAVED_VARIABLES_TOO_LARGE, D._impl.onSavedVariablesTooLarge,
        "the handler is the published one")
    newStore(F, "LayoutSizeDB2")
    T.eq(D._state.sizeWarningEvents, events, "a second store keeps the same events object")
end)

test("DB has exactly one logout entry however stores come and go and however often the file loads", function()
    local F = T.fresh()
    local D = F.DB
    local first = newStore(F, "LayoutLogoutDB")
    local entry = D._state.postLogoutEntry
    T.eq(type(entry), "function", "entry recorded at the first store")
    T.truthy(entry ~= D._impl.onLogout, "the entry is a relay, not the strip itself")
    T.eq(D._state.postLogoutRegistered, true, "flag set")
    T.eq(logoutEntries(F, entry), 1, "one entry after the first store")

    newStore(F, "LayoutLogoutDB2")
    T.eq(D._state.postLogoutEntry, entry, "the entry keeps its identity")
    local n, total = logoutEntries(F, entry)
    T.eq(n, 1, "one entry after two stores")
    T.eq(total, 1, "nothing else in the logout list")

    first:Destroy()
    newStore(F, "LayoutLogoutDB")
    n, total = logoutEntries(F, entry)
    T.eq(n, 1, "one entry after a store is destroyed and re-created")
    T.eq(total, 1, "nothing else in the logout list after re-creating")

    local state, impl = D._state, D._impl
    T.loadModule("Modules/DB.lua")
    T.eq(F.DB, D, "a second copy of the file stands down")
    T.eq(D._state, state, "state table unchanged")
    T.eq(D._impl, impl, "implementation table unchanged")
    newStore(F, "LayoutLogoutDB3")
    n, total = logoutEntries(F, entry)
    T.eq(n, 1, "one entry after a second copy stands down and another store is made")
    T.eq(total, 1, "the second copy added nothing to the logout list")
end)

test("the logout entry reaches whatever strip the module table holds when logout fires", function()
    local F = T.fresh()
    local D = F.DB
    local db = newStore(F, "LayoutRelayDB")
    local _ = db.profile
    local original = D._impl.onLogout
    local calls = 0
    D._impl.onLogout = function() calls = calls + 1 end
    T.Fire(F.Lifecycle._state.dispatcher, "PLAYER_LOGOUT")
    D._impl.onLogout = original
    T.eq(calls, 1, "the replaced strip ran once")
    T.eq(_G.LayoutRelayDB.profiles.Default.size, 3, "the original strip did not run")
    T.eq(D._impl.onLogout, original, "the strip is restored")
end)

-- The 1.0.114 release core and every module but DB, then this DB.lua under a
-- host addon name, the way a newer embed fills in a module an older core lacks.
local OLD_WITHOUT_DB = {}
for _, rel in ipairs(T.OLD_COPIES["v1.0.114"]) do
    if rel ~= "Modules/DB.lua" then OLD_WITHOUT_DB[#OLD_WITHOUT_DB + 1] = rel end
end

local function graftSteps(F)
    _G.GraftDB = { profiles = { Default = { size = 3, other = 2 } }, char = { Stale = {} } }
    _G.GraftDB2 = nil
    local db = newStore(F, "GraftDB", { profile = { size = 3, keep = 1 }, global = { flag = true } })
    db.profile.keep = 4
    local _ = db.global
    newStore(F, "GraftDB2")
    T.Fire(logoutFrame(), "PLAYER_LOGOUT")
    return { GraftDB = _G.GraftDB, GraftDB2 = _G.GraftDB2 }
end

test("this DB on a 1.0.114 core registers one logout entry, strips once and saves what the release saves", function()
    T.installMocks("@project-version@")
    T.loadCopy({ root = T.testsDir .. "/OldCopies/v1.0.114", files = OLD_WITHOUT_DB, addonName = "OldHost", version = "1.0.114" })
    local F = T.loadCopy({ root = T.foundryRoot, files = { "Modules/DB.lua" }, addonName = "NewHost" })
    T.eq(F.Lifecycle._layoutVersion, nil, "the serving Lifecycle is the release's")
    T.eq(F.DB._source, "NewHost", "DB is this copy's")
    local original = F.DB._impl.onLogout
    local strips = 0
    F.DB._impl.onLogout = function() strips = strips + 1; return original() end
    local grafted = graftSteps(F)
    F.DB._impl.onLogout = original
    local n, total = logoutEntries(F, F.DB._state.postLogoutEntry)
    T.eq(n, 1, "the release's logout list holds the entry once")
    T.eq(total, 1, "and nothing else")
    T.eq(strips, 1, "the strip ran once")

    T.installMocks("@project-version@")
    local old = T.loadOldCopy("v1.0.114", "OldHost", "1.0.114")
    local released = graftSteps(old)
    T.truthy(not rawequal(grafted.GraftDB2, released.GraftDB2), "each run saves its own tables")
    local diffs = deepEqual(grafted, released, "saved", {})
    T.eq(#diffs, 0, "saved data differs from the release: " .. table.concat(diffs, "; "))
end)

test("this DB loaded after a 1.0.114 DB stands down and adds no logout entry", function()
    T.installMocks("@project-version@")
    local F = T.loadOldCopy("v1.0.114", "OldHost", "1.0.114")
    local served = F.DB
    T.loadCopy({ root = T.foundryRoot, files = { "Modules/DB.lua" }, addonName = "NewHost" })
    T.eq(F.DB, served, "the release DB keeps serving")
    T.eq(served._state, nil, "nothing was written onto the release DB")
    newStore(F, "StandDownDB")
    newStore(F, "StandDownDB2")
    local _, total = logoutEntries(F, nil)
    T.eq(total, 1, "the release DB registered its own single entry, and nothing else was added")
end)

--------------------------------------------------------------------------------
-- state never declared as a file-level local
--------------------------------------------------------------------------------

-- Names that must not be declared as locals, by file. A file is checked once
-- it has no entries left in the reachability expected list.
local FORBIDDEN = {
    ["Modules/Lifecycle.lua"] = { "identityHeld", "dispatcher" },
    ["Modules/DB.lua"] = { "sizeWarningEvents" },
}

local function readSource(file)
    local f = assert(io.open(T.foundryRoot .. "/" .. file, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

-- Lines that declare `name` as a local: `local name`, `local a, name = ...`
-- and `local function name`. Comment text is ignored.
local function declarations(src, name)
    local found = {}
    local n = 0
    for line in (src .. "\n"):gmatch("(.-)\r?\n") do
        n = n + 1
        local code = line:gsub("%-%-.*$", "")
        local hit = code:match("^%s*local%s+function%s+([%w_]+)") == name
        local list = code:match("^%s*local%s+([%w_,%s]-)%s*=") or code:match("^%s*local%s+([%w_,%s]+)%s*$")
        if list and not code:match("^%s*local%s+function") then
            for ident in list:gmatch("[%w_]+") do
                if ident == name then hit = true end
            end
        end
        if hit then found[#found + 1] = n end
    end
    return found
end

test("the declaration scan recognises the forms it looks for", function()
    local src = table.concat({
        "local identityHeld = false",
        "local a, identityHeld = 1, 2",
        "local function identityHeld() end",
        "local identityHeld",
        "  local x = identityHeld",
        "-- local identityHeld = 1",
        "F._state.identityHeld = 1",
        "local identityHeldCount = 0",
    }, "\n")
    local lines = declarations(src, "identityHeld")
    T.eq(#lines, 4, "declarations found")
    T.eq(lines[1], 1, "first")
    T.eq(lines[4], 4, "last")
end)

local checked = {}

for file, names in pairs(FORBIDDEN) do
    test(file .. " declares none of its state as file-level locals once it is moved", function()
        local remaining = T.expectedTrapped[file]
        if remaining and #remaining > 0 then return end   -- not moved yet: rule not active
        local src = readSource(file)
        T.truthy(#src > 0, "source read")
        checked[file] = true
        for _, name in ipairs(names) do
            local lines = declarations(src, name)
            T.eq(#lines, 0, name .. " declared as a local at line " .. tostring(lines[1]))
        end
    end)
end

test("once the expected list is empty every file above has been checked", function()
    for _, list in pairs(T.expectedTrapped) do
        if #list > 0 then return end
    end
    for file in pairs(FORBIDDEN) do
        T.truthy(checked[file], file .. " was never checked although nothing is left in the expected list")
    end
end)

return tests

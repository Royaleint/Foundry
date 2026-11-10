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

-- Handover: a second copy of the library installed over one that is already
-- serving, with instances built before the swap. The test installer
-- (installer.lua) does the swap; these cases check what it leaves behind:
--   * no function from the first load is reachable after the swap, except in
--     the slots the client keeps (a slash handler, a timer callback, a
--     tooltip post-call, ...), and each of those reaches the swapped-in code;
--   * instances built before the swap behave as they would without it;
--   * the library's tables keep their identity across the swap;
--   * the installer refuses state it cannot carry over, naming where it is;
--   * an independent walk finds none of the second copy's own tables left in
--     any upvalue.

local T = ...

local surfaces = assert(loadfile(T.testsDir .. "/Layout/surfaces.lua"))(T)
local W = assert(loadfile(T.testsDir .. "/Layout/walker.lua"))(T)
local scenario = assert(loadfile(T.testsDir .. "/Layout/scenario.lua"))(T, surfaces)

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local function prepared()
    local F = surfaces.load("current")
    return F, scenario.run(F)
end

local function swap(F)
    return T.installSecondCopy(F)
end

local function isLibraryFunction(fn)
    local info = debug.getinfo(fn, "S")
    return info.what ~= "C" and W.isLibrarySource(info.source)
end

local function siteOf(fn)
    local info = debug.getinfo(fn, "S")
    return W.fileOf(info.source) .. ":" .. info.linedefined
end

local function rootsOf(F, s)
    local roots = { F }
    for _, holder in ipairs(s.holders) do roots[#roots + 1] = holder end
    return roots
end

-- Calls visit(holder, key, value, kind) for every edge reachable from roots:
-- table keys, values (except under the mock call logs) and metatables, and the
-- upvalues of library functions. kind is "key", "field", "metatable" or
-- "upvalue". Returns the set of everything visited.
local function eachEdge(roots, visit)
    local seen, stack, n = {}, {}, 0
    local function push(v)
        local kind = type(v)
        if (kind == "table" or kind == "function") and not seen[v] then
            seen[v] = true; n = n + 1; stack[n] = v
        end
    end
    for _, root in ipairs(roots) do push(root) end
    while n > 0 do
        local item = stack[n]; stack[n] = nil; n = n - 1
        if type(item) == "table" then
            for k, v in pairs(item) do
                visit(item, k, k, "key"); push(k)
                if not W.SKIP_KEYS[k] then visit(item, k, v, "field"); push(v) end
            end
            local mt = getmetatable(item)
            if mt ~= nil then visit(item, "(metatable)", mt, "metatable"); push(mt) end
        elseif isLibraryFunction(item) then
            local i = 1
            while true do
                local name, value = debug.getupvalue(item, i)
                if not name then break end
                visit(item, name, value, "upvalue"); push(value)
                i = i + 1
            end
        end
    end
    return seen
end

local function libraryFunctionsReachable(F, s)
    local found = {}
    for item in pairs(eachEdge(rootsOf(F, s), function() end)) do
        if type(item) == "function" and isLibraryFunction(item) then found[item] = true end
    end
    return found
end

-- The slots the client or a test keeps a library function in for the
-- session. A swap cannot reach into them, so each holds a relay that looks
-- its target up on the module table when called.
local function namedSlots(F, s)
    local afterEntries, timerHandles, postCallEntries, createEntries = {}, {}, {}, {}
    for _, entry in ipairs(T.afters) do afterEntries[entry] = true end
    for _, handle in ipairs(T.timers) do timerHandles[handle] = true end
    for _, entry in ipairs(s.processor.postCalls) do postCallEntries[entry] = true end
    for _, entry in ipairs(s.menuUtil.createCalls) do createEntries[entry] = true end
    local view = s.inst.list:GetNativeHandles().view
    local lifecycleState, dbState = F.Lifecycle._state, F.DB._state
    local menus = F.Menu._state.instances
    local dispatcher = lifecycleState.dispatcher
    local dragScripts = {}
    for _, record in pairs(F.Window._state.attached) do dragScripts[record.handle._scripts] = true end
    return function(holder, key, value)
        return (holder == lifecycleState.postLogout and rawequal(value, dbState.postLogoutEntry))
            or (holder == dbState and key == "postLogoutEntry")
            or holder == _G.SlashCmdList
            or (afterEntries[holder] and key == "cb")
            or (postCallEntries[holder] and key == "fn")
            or holder == s.panel.clicks
            or (menus[holder] and key == "_generatorWrapper")
            or holder == s.button.setups
            or (createEntries[holder] and key == "generator")
            or (holder == view and (key == "_initializer" or key == "_calc"))
            or (timerHandles[holder] and key == "_callback")
            or (holder == dispatcher and key == "_onEvent")
            or (holder == dispatcher._scripts and key == "OnEvent")
            or (dragScripts[holder] and (key == "OnDragStart" or key == "OnDragStop"))
            or false
    end
end

-- The limits a swap cannot cover: a public library function the consumer
-- took by value before the swap stays the first-load function. The concrete
-- case is a Commands controller's guard, and only when it is the first load's
-- built-in guard.
local function namedLimits(F, firstGuard)
    local commands = F.Commands._state.instances
    return function(holder, key, value)
        return (commands[holder] and key == "_guard" and rawequal(value, firstGuard)) or false
    end
end

local function describeEdge(holder, key, kind)
    if kind == "upvalue" then return "upvalue '" .. key .. "' of " .. siteOf(holder) end
    return kind .. " '" .. tostring(key) .. "' of a table"
end

-- First-load functions still reachable after the swap anywhere but a named
-- slot or limit, or as a function's own upvalue (a closure that reschedules
-- itself).
local function oldFunctionsOutsideSlots(F, s, old, firstGuard)
    local isSlot, isLimit = namedSlots(F, s), namedLimits(F, firstGuard)
    local found = {}
    eachEdge(rootsOf(F, s), function(holder, key, value, kind)
        if type(value) == "function" and old[value] then
            local allowed = (kind == "field" and (isSlot(holder, key, value) or isLimit(holder, key, value)))
                or (kind == "upvalue" and rawequal(value, holder))
            if not allowed then
                found[#found + 1] = siteOf(value) .. " held by " .. describeEdge(holder, key, kind)
            end
        end
    end)
    table.sort(found)
    return found
end

-- Replaces tbl[key] with a counting wrapper while run() executes.
local function countCalls(tbl, key, run)
    local target, n = tbl[key], 0
    T.eq(type(target), "function", "the spied target " .. tostring(key))
    tbl[key] = function(...)
        n = n + 1
        return target(...)
    end
    local ok, err = pcall(run)
    tbl[key] = target
    if not ok then error(err, 0) end
    return n
end

local function countOf(list, label)
    local n = 0
    for _, v in ipairs(list) do if v == label then n = n + 1 end end
    return n
end

local function pendingTimers()
    local pending = {}
    for _, handle in ipairs(T.timers) do
        if not handle._cancelled and not handle._fired then pending[#pending + 1] = handle end
    end
    return pending
end

-- A slot's value, read before the swap: it must be a library function.
local function slotBeforeSwap(value, what)
    T.eq(type(value), "function", what .. " holds a function")
    T.truthy(isLibraryFunction(value), what .. " holds a library function")
    return value
end

--------------------------------------------------------------------------------
-- The rehearsal itself
--------------------------------------------------------------------------------

test("a load in rehearsal mode serves the second copy's functions", function()
    T.lastSecondCopy = nil
    local F = surfaces.load("current")
    if not T.REHEARSE then
        T.eq(T.lastSecondCopy, nil, "a plain load installs no second copy")
        return
    end
    local F2 = T.lastSecondCopy
    T.truthy(F2 and not rawequal(F2, F), "a second copy was built")
    T.truthy(rawequal(F.RegisterModule, F2.RegisterModule), "the library table serves the second copy's methods")
    local checked = 0
    for name, M in pairs(F._state.modules) do
        for key, value in pairs(M._impl) do
            if type(value) == "function" then
                T.truthy(rawequal(value, F2._state.modules[name]._impl[key]),
                    name .. "._impl." .. tostring(key) .. " is the second copy's")
                checked = checked + 1
            end
        end
    end
    T.truthy(checked > 0, "implementation functions were compared")
end)

test("loading a second copy beside a serving one changes nothing outside its own environment", function()
    local F, s = prepared()
    local counts = { frames = #T.frames, output = #T.output, timers = #T.timers, afters = #T.afters }
    local globals, slash = {}, {}
    for k, v in pairs(_G) do globals[k] = v end
    for k, v in pairs(_G.SlashCmdList) do slash[k] = v end
    local serving = {}
    local function snapshot(label, t)
        local copy = {}
        for k, v in pairs(t) do copy[k] = v end
        serving[#serving + 1] = { label = label, t = t, copy = copy }
    end
    snapshot("the library table", F)
    snapshot("the library table._state", F._state)
    for name, M in pairs(F._state.modules) do
        snapshot(name, M)
        snapshot(name .. "._state", M._state)
        snapshot(name .. "._impl", M._impl)
    end

    local F2, env = T.shadowLoad(T.FOUNDRY_FILES, "Foundry-1.0")

    T.eq(#T.frames, counts.frames, "frames created")
    T.eq(#T.output, counts.output, "output lines")
    T.eq(#T.timers, counts.timers, "timers started")
    T.eq(#T.afters, counts.afters, "ticks scheduled")
    for k, v in pairs(_G) do T.truthy(rawequal(globals[k], v), "global '" .. tostring(k) .. "' unchanged") end
    for k in pairs(globals) do T.truthy(rawget(_G, k) ~= nil, "global '" .. tostring(k) .. "' still set") end
    for k, v in pairs(_G.SlashCmdList) do
        T.truthy(rawequal(slash[k], v), "slash handler '" .. tostring(k) .. "' unchanged")
    end
    for k in pairs(slash) do T.truthy(_G.SlashCmdList[k] ~= nil, "slash handler '" .. tostring(k) .. "' still set") end
    for _, snap in ipairs(serving) do
        for k, v in pairs(snap.t) do
            T.truthy(rawequal(snap.copy[k], v), snap.label .. "." .. tostring(k) .. " unchanged")
        end
        for k in pairs(snap.copy) do
            T.truthy(rawget(snap.t, k) ~= nil, snap.label .. "." .. tostring(k) .. " still set")
        end
    end

    T.truthy(type(F2) == "table" and not rawequal(F2, F), "the second copy built its own library table")
    for name, M in pairs(F._state.modules) do
        local M2 = F2._state.modules[name]
        T.truthy(type(M2) == "table" and not rawequal(M2, M), name .. " is a table of the second copy's own")
    end
    local keys = {}
    for k in pairs(env) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    T.eq(table.concat(keys, ","), "Foundry_1_0,_G", "the environment's own keys")
    T.truthy(rawequal(env._G, env), "the environment is its own _G")
    T.truthy(rawequal(_G.Foundry_1_0, F), "the serving copy is still the global library table")
    T.truthy(s.inst.db ~= nil, "the scenario ran")
end)

--------------------------------------------------------------------------------
-- First-load functions after the swap
--------------------------------------------------------------------------------

test("after the swap no first-load function is reachable outside a slot the client keeps", function()
    local F, s = prepared()
    local old = libraryFunctionsReachable(F, s)
    local firstGuard = F.Commands.Guards.NotRestricted
    swap(F)
    local found = oldFunctionsOutsideSlots(F, s, old, firstGuard)
    T.eq(#found, 0, "first-load functions outside a slot:\n    " .. table.concat(found, "\n    "))
end)

test("a guard taken by value before the swap stays the first load's, and still answers correctly", function()
    local F, s = prepared()
    local firstGuard = slotBeforeSwap(F.Commands.Guards.NotRestricted, "the built-in guard")
    T.truthy(rawequal(s.inst.guarded._guard, firstGuard), "the guarded controller holds the built-in guard")
    local name, value = debug.getupvalue(firstGuard, 1)
    T.eq(name, "restrictionTypes", "the guard's only upvalue")
    T.eq(debug.getupvalue(firstGuard, 2), nil, "the guard has one upvalue")
    T.truthy(W.isConstant("Modules/Commands.lua", name) and type(value) == "table", "the upvalue is a shared constant")
    swap(F)
    local guard = F.Commands.Guards.NotRestricted
    T.truthy(not rawequal(guard, firstGuard), "the module table serves the swapped-in guard")
    T.truthy(rawequal(s.inst.guarded._guard, firstGuard), "the controller still holds the first load's guard")
    local function answers(fn)
        local allowed, reason = fn("")
        return tostring(allowed) .. " " .. tostring(reason)
    end
    T.eq(answers(firstGuard), answers(guard), "with no restriction active")
    _G.C_RestrictedActions.IsAddOnRestrictionActive = function(restriction)
        return restriction == _G.Enum.AddOnRestrictionType.Encounter
    end
    T.eq(answers(firstGuard), answers(guard), "with an encounter restriction active")
    T.eq(answers(firstGuard), "false Commands are unavailable while encounter restrictions are active.", "the refusal")
end)

test("the logout entry is registered once and reaches the swapped-in strip", function()
    local F = prepared()
    local entry = slotBeforeSwap(F.DB._state.postLogoutEntry, "the DB logout entry")
    swap(F)
    T.truthy(rawequal(F.DB._state.postLogoutEntry, entry), "the swap leaves the logout entry in place")
    local held = 0
    for _, fn in ipairs(F.Lifecycle._state.postLogout) do
        if rawequal(fn, entry) then held = held + 1 end
    end
    T.eq(held, 1, "post-logout holds the entry")
    T.eq(countCalls(F.DB._impl, "onLogout", function() entry() end), 1, "swapped-in strip calls")
end)

test("the slash handler reaches the swapped-in dispatch", function()
    local F, s = prepared()
    local handler = slotBeforeSwap(_G.SlashCmdList.SCENARIO, "the slash handler")
    swap(F)
    T.truthy(rawequal(_G.SlashCmdList.SCENARIO, handler), "the swap leaves the slash handler in place")
    T.eq(countCalls(F.Commands._impl.Controller, "Dispatch", function() handler("go") end), 1,
        "swapped-in dispatch calls")
    T.eq(s.slashRan, 1, "the command ran")
end)

test("the pending poll tick reaches the swapped-in tick", function()
    local F = prepared()
    local entry
    for _, e in ipairs(T.afters) do
        if not e.fired then entry = e end
    end
    T.truthy(entry, "a poll tick is pending")
    local tick = slotBeforeSwap(entry.cb, "the pending tick")
    swap(F)
    T.truthy(rawequal(entry.cb, tick), "the swap leaves the pending tick in place")
    T.eq(countCalls(F.Lifecycle._impl, "pollTick", function() tick() end), 1, "swapped-in tick calls")
end)

test("the tooltip post-call reaches the swapped-in dispatch", function()
    local F, s = prepared()
    local postCall = slotBeforeSwap(s.processor.postCalls[1].fn, "the tooltip post-call")
    swap(F)
    T.eq(countCalls(F.Tooltip._impl, "dispatch", function() postCall(surfaces.makeTooltip(), {}) end), 1,
        "swapped-in dispatch calls")
    T.eq(countOf(s.calls, "tooltip first"), 1, "the first handler ran")
end)

test("the launcher click reaches the swapped-in click", function()
    local F, s = prepared()
    local click = slotBeforeSwap(s.panel.clicks[#s.panel.clicks], "the launcher click")
    local launched = s.launched
    swap(F)
    T.eq(countCalls(F.Settings._impl, "launcherClick", function() click({}, "LeftButton", false) end), 1,
        "swapped-in click calls")
    T.eq(s.launched, launched + 1, "the launcher ran")
end)

test("the menu generator reaches the swapped-in generate", function()
    local F, s = prepared()
    local generator = slotBeforeSwap(s.inst.menu._generatorWrapper, "the menu generator")
    T.truthy(rawequal(s.button.setups[1], generator), "the dropdown holds the generator")
    T.truthy(rawequal(s.menuUtil.createCalls[1].generator, generator), "the context menu was given the generator")
    swap(F)
    T.eq(countCalls(F.Menu._impl, "generate", function() generator({}, surfaces.makeRootDescription()) end), 1,
        "swapped-in generate calls")
end)

test("the list's initializer and calculator reach the swapped-in wrappers", function()
    local F, s = prepared()
    local view = s.inst.list:GetNativeHandles().view
    local initializer = slotBeforeSwap(view._initializer, "the list initializer")
    local calculator = slotBeforeSwap(view._calc, "the list calculator")
    swap(F)
    T.eq(countCalls(F.List._impl, "initRow", function() initializer({}, {}) end), 1, "swapped-in initRow calls")
    T.eq(countCalls(F.List._impl, "extent", function() T.eq(calculator(1, {}), 20, "extent") end), 1,
        "swapped-in extent calls")
end)

test("the Lifecycle dispatcher's script reaches the swapped-in event handler", function()
    local F = prepared()
    local frame = F.Lifecycle._state.dispatcher
    local script = slotBeforeSwap(frame:GetScript("OnEvent"), "the dispatcher script")
    swap(F)
    T.truthy(rawequal(frame:GetScript("OnEvent"), script), "the swap leaves the dispatcher script in place")
    T.eq(countCalls(F.Lifecycle._impl, "onEvent", function() script(frame, "ADDON_LOADED", "Nothing") end), 1,
        "swapped-in event handler calls")
end)

test("the window's drag scripts reach the swapped-in drag handlers", function()
    local F = prepared()
    local _, record = next(F.Window._state.attached)
    local handle = record.handle
    local onDragStart = slotBeforeSwap(handle:GetScript("OnDragStart"), "the drag start script")
    local onDragStop = slotBeforeSwap(handle:GetScript("OnDragStop"), "the drag stop script")
    swap(F)
    T.truthy(rawequal(handle:GetScript("OnDragStart"), onDragStart), "the swap leaves the drag start script in place")
    T.truthy(rawequal(handle:GetScript("OnDragStop"), onDragStop), "the swap leaves the drag stop script in place")
    T.eq(countCalls(F.Window._impl, "dragStart", function() onDragStart(handle) end), 1, "swapped-in drag start calls")
    T.eq(countCalls(F.Window._impl, "dragStop", function() onDragStop(handle) end), 1, "swapped-in drag stop calls")
end)

-- The pending flush is the one closure a swap leaves running as it was: the
-- timer holds it and it calls the handler directly.
test("the bucket's pending flush runs the handler once", function()
    local F, s = prepared()
    local pending = pendingTimers()
    T.eq(#pending, 1, "pending timers")
    local handle = pending[1]
    local flush = slotBeforeSwap(handle._callback, "the bucket timer")
    swap(F)
    T.truthy(rawequal(handle._callback, flush), "the swap leaves the timer's callback in place")
    T.now = 10
    T.FireTimer(handle)
    T.eq(countOf(s.calls, "events bucket"), 1, "bucket handler calls")
    T.eq(#pendingTimers(), 0, "timers pending after the flush")
end)

--------------------------------------------------------------------------------
-- Instances built before the swap
--------------------------------------------------------------------------------

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

-- Drives every instance the scenario built; returns what happened, as lines,
-- ending with the window's saved geometry and the saved data after logout.
local function exercise(F, s)
    local firstCall, firstOutput = #s.calls + 1, #T.output + 1
    local ev = s.inst.events
    T.Fire(ev._frame, "SCENARIO_ONCE")
    T.Fire(ev._frame, "SCENARIO_ONCE")
    T.Fire(ev._frame, "SCENARIO_PLAIN")
    T.Fire(ev._frame, "SCENARIO_BUCKET")
    T.now = 10
    for _, handle in ipairs(pendingTimers()) do T.FireTimer(handle) end
    _G.SlashCmdList.SCENARIO("go")
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
    local geometry = describe(s.windowGeometry)
    s.panel.clicks[#s.panel.clicks]({}, "LeftButton", false)
    -- A dev build raises the size warning after the callbacks run.
    local ok, sizeErr = pcall(T.Fire, F.DB._state.sizeWarningEvents._frame, "SAVED_VARIABLES_TOO_LARGE", "ScenarioAddon")
    T.falsy(ok, "the size warning raises in a dev build")
    T.identity = { name = "Tester", realm = T.identity.realm }
    T.RunAfters()
    s.inst.db.profile.a = 7
    T.Fire(surfaces.dispatcherFrame(), "PLAYER_LOGOUT")

    local lines = { "raised " .. surfaces.normalise(sizeErr) }
    for i = firstCall, #s.calls do lines[#lines + 1] = "call " .. s.calls[i] end
    for i = firstOutput, #T.output do lines[#lines + 1] = "print " .. T.output[i] end
    lines[#lines + 1] = "geometry " .. geometry
    lines[#lines + 1] = "saved TestDB " .. describe(_G.TestDB)
    lines[#lines + 1] = "saved TestDB2 " .. describe(_G.TestDB2)
    return lines
end

test("instances built before the swap behave as they would without it", function()
    local F, s = prepared()
    local plain = exercise(F, s)
    T.eq(s.windowGeometry.point, "TOPLEFT", "the drag stop saved the window's point")
    T.eq(s.windowGeometry.x, 12, "the drag stop saved the window's offset")
    local saved = _G.TestDB
    T.eq(saved.profiles.Default.a, 7, "the changed profile value is saved")
    T.eq(saved.global.g, nil, "the default-equal global value is stripped")
    T.eq(saved.global.schemaStamp, 1, "the schema stamp is saved")

    F, s = prepared()
    swap(F)
    local swapped = exercise(F, s)

    for i = 1, math.max(#plain, #swapped) do
        T.eq(swapped[i], plain[i], "what the instances did, line " .. i)
    end
    for _, label in ipairs({
        "events once", "events plain", "events bucket", "command go", "tooltip first", "tooltip second",
        "tooltip other type", "menu builder", "list calculator", "list initializer", "settings launch",
        "db size warning", "lifecycle B addon loaded", "lifecycle A logout",
    }) do
        T.truthy(countOf(swapped, "call " .. label) > 0, "'" .. label .. "' ran after the swap")
    end
    T.eq(countOf(swapped, "call events once"), 1, "the once handler ran once")
    T.outputContains("restrictions activate", "the restriction notice")
end)

--------------------------------------------------------------------------------
-- Identity of the library's tables
--------------------------------------------------------------------------------

-- Tables the library replaces by design, so they do not keep their identity
-- across a session.
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

test("the swap keeps the identity of every library table", function()
    local F = prepared()
    local before = layoutTables(F)
    swap(F)
    local changed = identityChanges(before, layoutTables(F))
    T.eq(#changed, 0, "tables replaced by the swap: " .. table.concat(changed, ", "))
end)

test("a session with a swap replaces only the tables the library replaces by design", function()
    local F = surfaces.load("current")
    local fresh = layoutTables(F)
    local s = scenario.run(F)
    swap(F)
    exercise(F, s)
    local after = layoutTables(F)
    local changed = identityChanges(fresh, after, REPLACED_BY_DESIGN)
    T.eq(#changed, 0, "tables replaced: " .. table.concat(changed, ", "))
    for path in pairs(REPLACED_BY_DESIGN) do
        T.truthy(not rawequal(fresh[path], after[path]), path .. " was replaced during the session")
    end
end)

--------------------------------------------------------------------------------
-- What the installer refuses
--------------------------------------------------------------------------------

-- Every table a module table holds besides _state and _impl is carried over
-- key by key; a new one must be added here on purpose.
test("the module tables hold no tables besides _state and _impl other than the known ones", function()
    local F = surfaces.load("current")
    local found = {}
    for name, M in pairs(F._state.modules) do
        for key, value in pairs(M) do
            if type(value) == "table" and key ~= "_state" and key ~= "_impl" then
                found[#found + 1] = name .. "." .. tostring(key)
            end
        end
    end
    table.sort(found)
    T.eq(table.concat(found, ", "), "Commands.Guards", "public tables on module tables")
end)

local function installWithFixture(rel)
    local F = surfaces.load("current")
    T.loadModule(rel)
    local files = {}
    for i, file in ipairs(T.FOUNDRY_FILES) do files[i] = file end
    files[#files + 1] = rel
    local F2, env = T.shadowLoad(files, "Foundry-1.0")
    return T.raises(function()
        T.installer().install({ F = F, F2 = F2, env = env })
    end, "installing over " .. rel)
end

test("the installer refuses a table only an implementation function can reach", function()
    local err = tostring(installWithFixture("Tests/Layout/fixtures/capture_table.lua"))
    T.truthy(err:find("capture_table.lua:14 upvalue 'hidden' (a table) is not mapped through the layout", 1, true),
        "the refusal names the function and the upvalue (got: " .. err .. ")")
end)

test("the installer refuses a flag a module function keeps in a local", function()
    local err = tostring(installWithFixture("Tests/Layout/fixtures/capture_flag.lua"))
    T.truthy(err:find("capture_flag.lua:14 upvalue 'enabled' (a boolean) is not mapped through the layout", 1, true),
        "the refusal names the function and the upvalue (got: " .. err .. ")")
end)

test("the installer refuses a public module table holding anything but library functions", function()
    local err = tostring(installWithFixture("Tests/Layout/fixtures/capture_public.lua"))
    for _, expected in ipairs({
        "CapturePublic.Helpers.options: a table the layout has no rule for",
        "CapturePublic.Helpers.Check: a function the layout has no rule for",
    }) do
        T.truthy(err:find(expected, 1, true), "the refusal names '" .. expected .. "' (got: " .. err .. ")")
    end
end)

--------------------------------------------------------------------------------
-- Independent check
--------------------------------------------------------------------------------

-- Every table the second copy built, found without the installer: from its
-- library table and its environment's own keys, following table edges and
-- library-function upvalues, never the environment's read-through to _G.
-- Allowed constants are left out: they are kept as they are by design.
local function shadowTables(F2, env)
    local tables, seen, stack, n = {}, {}, {}, 0
    local function push(v)
        local kind = type(v)
        if (kind == "table" or kind == "function") and not seen[v] then
            seen[v] = true; n = n + 1; stack[n] = v
        end
    end
    push(F2)
    for k, v in next, env do push(k); push(v) end
    while n > 0 do
        local item = stack[n]; stack[n] = nil; n = n - 1
        if type(item) == "table" then
            tables[item] = true
            for k, v in next, item do push(k); push(v) end
            if not rawequal(item, env) then
                local mt = getmetatable(item)
                if mt ~= nil then push(mt) end
            end
        elseif isLibraryFunction(item) then
            local file = W.fileOf(debug.getinfo(item, "S").source)
            local i = 1
            while true do
                local name, value = debug.getupvalue(item, i)
                if not name then break end
                if not W.isConstant(file, name) then push(value) end
                i = i + 1
            end
        end
    end
    return tables
end

test("after the swap no upvalue reachable from the serving copy holds a table of the second copy's", function()
    local F, s = prepared()
    local F2, env = T.shadowLoad(T.FOUNDRY_FILES, "Foundry-1.0")
    local shadow = shadowTables(F2, env)
    T.truthy(shadow[F2] and shadow[env], "the walk found the second copy's own tables")
    T.installer().install({ F = F, F2 = F2, env = env })

    local leaked, wrongEnv, functions = {}, {}, 0
    local seen = eachEdge(rootsOf(F, s), function(holder, key, value, kind)
        if kind == "upvalue" and type(value) == "table" and shadow[value] then
            leaked[#leaked + 1] = "upvalue '" .. key .. "' of " .. siteOf(holder)
        end
    end)
    for item in pairs(seen) do
        if type(item) == "function" and isLibraryFunction(item) then
            functions = functions + 1
            if not rawequal(getfenv(item), _G) then wrongEnv[#wrongEnv + 1] = siteOf(item) end
        end
    end
    table.sort(leaked)
    table.sort(wrongEnv)
    T.truthy(functions > 0, "library functions were walked")
    T.eq(#leaked, 0, "upvalues holding the second copy's tables:\n    " .. table.concat(leaked, "\n    "))
    T.eq(#wrongEnv, 0, "functions not running in the real global table: " .. table.concat(wrongEnv, ", "))
end)

return tests

-- Helpers shared by the Layout specs that look for functions of one copy
-- inside the tables of another: the edge walk over a serving copy, the named
-- slots the client keeps a function in, and the counters that watch a call.
-- Not a suite of its own.

local T = ...

local W = assert(loadfile(T.testsDir .. "/Layout/walker.lua"))(T)

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

return {
    isLibraryFunction = isLibraryFunction,
    siteOf = siteOf,
    rootsOf = rootsOf,
    eachEdge = eachEdge,
    libraryFunctionsReachable = libraryFunctionsReachable,
    namedSlots = namedSlots,
    namedLimits = namedLimits,
    describeEdge = describeEdge,
    oldFunctionsOutsideSlots = oldFunctionsOutsideSlots,
    countCalls = countCalls,
    countOf = countOf,
    pendingTimers = pendingTimers,
    slotBeforeSwap = slotBeforeSwap,
}

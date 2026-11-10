-- Test installer: swaps a second, shadow-loaded copy of the library in over
-- the copy that is serving, the way a later copy would take over a running
-- one. Test-only; nothing here ships.
--
-- INS.install{ F = serving, F2 = second copy, env = its shadow environment }
--   1. Map     the second copy's library table, module tables, their _state
--              and _impl tables, and every table value in each _state and
--              _impl (key by key), onto the serving copy's tables, and each
--              other table on a module table (Commands.Guards), which may hold
--              only library functions. A serving object is only ever an image
--              of this map.
--   2. Copy    the library table's four methods, every function on each
--              module table and in each _impl, and the functions held in each
--              _impl table and each other module-table table, in place, so the
--              serving tables keep their identity.
--   3. Rebind  every upvalue of each copied function: a library function is
--              rebound in turn; a mapped table is set to its image; an image
--              (a sibling closure sharing the upvalue was rebound first) and
--              an allowed constant or function stay. Anything else fails,
--              naming the function's file:line and the upvalue. Each rebound
--              function then runs in the real global table.
--   4. Re-point what the client holds through a handle, using the new
--              factories.
--   5. Check   the shadow environment holds only Foundry_1_0 and _G.
-- Any failure raises before the next step; nothing is skipped.

local T = ...

local W = assert(loadfile(T.testsDir .. "/Layout/walker.lua"))(T)

local INS = {}

local F_METHODS = { "RaiseDevError", "RegisterModule", "HasModule", "RequireModule" }

local function isLibraryFunction(fn)
    local info = debug.getinfo(fn, "S")
    return info.what ~= "C" and W.isLibrarySource(info.source)
end

local function siteOf(fn)
    local info = debug.getinfo(fn, "S")
    return W.fileOf(info.source), info.linedefined
end

local function raise(failures)
    error("installer:\n  " .. table.concat(failures, "\n  "), 0)
end

function INS.install(opts)
    local F, F2, env = opts.F, opts.F2, opts.env
    local isConstant = opts.constants or W.isConstant
    local isAllowedFunction = opts.functions or W.isAllowedFunction
    local failures = {}
    local function fail(msg) failures[#failures + 1] = msg end

    if type(F2) ~= "table" or rawequal(F2, F) then
        raise({ "the second copy did not build a library table of its own" })
    end

    -- 1. Map.
    local map, images = {}, {}
    local function bind(from, to, label)
        if type(to) ~= "table" then
            fail(label .. ": the serving copy has a " .. type(to) .. " here, not a table")
        elseif map[from] ~= nil and not rawequal(map[from], to) then
            fail(label .. ": reached twice, mapping to two different serving tables")
        elseif images[to] ~= nil and not rawequal(images[to], from) then
            fail(label .. ": its serving table is already the image of another table")
        else
            map[from], images[to] = to, from
        end
    end
    local function bindParts(M2, M, label, parts)
        for _, part in ipairs(parts) do
            local t2 = rawget(M2, part)
            if type(t2) ~= "table" then
                fail(label .. "." .. part .. ": the second copy has no such table")
            else
                local t = rawget(M, part)
                bind(t2, t, label .. "." .. part)
                if type(t) == "table" then
                    for k, v in pairs(t2) do
                        if type(v) == "table" then bind(v, t[k], label .. "." .. part .. "." .. tostring(k)) end
                    end
                end
            end
        end
    end

    bind(F2, F, "the library table")
    if F2._layoutVersion == nil or F._layoutVersion ~= F2._layoutVersion then
        fail("the library table: layout version " .. tostring(F._layoutVersion)
            .. " is not the second copy's " .. tostring(F2._layoutVersion))
    end
    bindParts(F2, F, "the library table", { "_state" })
    local modules2 = type(F2._state) == "table" and F2._state.modules or {}
    local modules = type(F._state) == "table" and F._state.modules or {}
    local names = {}
    for name in pairs(modules2) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local M2, M = modules2[name], modules[name]
        if type(M) ~= "table" then
            fail(name .. ": not present in the serving copy")
        else
            bind(M2, M, name)
            if M2._layoutVersion == nil or M._layoutVersion ~= M2._layoutVersion then
                fail(name .. ": layout version " .. tostring(M._layoutVersion)
                    .. " is not the second copy's " .. tostring(M2._layoutVersion))
            end
            bindParts(M2, M, name, { "_state", "_impl" })
            for key, value in pairs(M2) do
                if type(value) == "table" and key ~= "_state" and key ~= "_impl" then
                    local label = name .. "." .. tostring(key)
                    bind(value, M[key], label)
                    for k, v in pairs(value) do
                        if type(v) ~= "function" or not isLibraryFunction(v) then
                            fail(label .. "." .. tostring(k) .. ": a " .. type(v)
                                .. " the layout has no rule for (only library functions are carried over)")
                        end
                    end
                end
            end
        end
    end
    if #failures > 0 then raise(failures) end

    -- 2. Copy.
    local copied = {}
    local function copy(to, key, fn)
        to[key] = fn
        copied[#copied + 1] = fn
    end
    local isMethod = {}
    for _, key in ipairs(F_METHODS) do
        isMethod[key] = true
        if type(F2[key]) ~= "function" then fail("the library table: method '" .. key .. "' is missing") end
    end
    for key, value in pairs(F2) do
        if type(value) == "function" and not isMethod[key] then
            fail("the library table: function '" .. tostring(key) .. "' is not one of the four methods")
        end
    end
    if #failures > 0 then raise(failures) end
    for _, key in ipairs(F_METHODS) do copy(F, key, F2[key]) end
    for _, name in ipairs(names) do
        local M2, M = modules2[name], modules[name]
        for key, value in pairs(M2) do
            if type(value) == "function" then
                copy(M, key, value)
            elseif type(value) == "table" and key ~= "_state" and key ~= "_impl" then
                for k, v in pairs(value) do copy(M[key], k, v) end
            end
        end
        local I2, I = M2._impl, M._impl
        for key, value in pairs(I2) do
            if type(value) == "function" then
                copy(I, key, value)
            elseif type(value) == "table" then
                local target = I[key]
                for k, v in pairs(value) do
                    if type(v) == "function" then copy(target, k, v) end
                end
            end
        end
    end
    if #failures > 0 then raise(failures) end

    -- 3. Rebind.
    local rebound = {}
    local function rebind(fn)
        if rebound[fn] then return end
        rebound[fn] = true
        local file, line = siteOf(fn)
        local i = 1
        while true do
            local name, value = debug.getupvalue(fn, i)
            if not name then break end
            local kind = type(value)
            if kind == "table" and map[value] ~= nil then
                debug.setupvalue(fn, i, map[value])
            elseif kind == "table" and images[value] ~= nil then
                -- A sibling closure sharing this upvalue was rebound first.
            elseif isConstant(file, name) then
                -- Never written after load.
            elseif kind == "function" and isLibraryFunction(value) then
                rebind(value)
            elseif kind == "function" and isAllowedFunction(file, name) then
                -- A client function the library is allowed to capture.
            else
                fail(("%s:%d upvalue '%s' (a %s) is not mapped through the layout")
                    :format(file, line, name, kind))
            end
            i = i + 1
        end
        setfenv(fn, _G)
    end
    for _, fn in ipairs(copied) do rebind(fn) end
    if #failures > 0 then raise(failures) end

    -- 4. Re-point, with the factories now on the serving tables.
    local Lifecycle = modules.Lifecycle
    if Lifecycle and Lifecycle._state.dispatcher then
        Lifecycle._state.dispatcher:SetScript("OnEvent", Lifecycle._impl.onEvent)
    end

    local DB = modules.DB
    if DB then
        local sizeEvents = DB._state.sizeWarningEvents
        if sizeEvents then
            sizeEvents:Unregister("SAVED_VARIABLES_TOO_LARGE")
            sizeEvents:Register("SAVED_VARIABLES_TOO_LARGE", DB._impl.onSavedVariablesTooLarge)
            if sizeEvents._handlers.SAVED_VARIABLES_TOO_LARGE ~= DB._impl.onSavedVariablesTooLarge then
                fail("DB: the size warning handler did not register again")
            end
        end
        for _, store in ipairs(DB._state.stores) do
            store.onMismatch = DB._impl.makeOnMismatch()
        end
    end

    local Window = modules.Window
    if Window then
        for _, record in pairs(Window._state.attached) do
            local onDragStart, onDragStop = Window._impl.makeDragScripts(record)
            record.handle:SetScript("OnDragStart", onDragStart)
            record.handle:SetScript("OnDragStop", onDragStop)
        end
    end

    local Events = modules.Events
    if Events then
        for c in pairs(Events._state.instances) do
            c._frame:SetScript("OnEvent", Events._impl.makeOnEvent(c))
            if c._onceHandlers then
                for event, handler in pairs(c._onceHandlers) do
                    c._handlers[event] = Events._impl.makeOnce(c, handler)
                end
            end
            for _, bucket in ipairs(c._buckets) do
                local _, onFire = Events._impl.makeBucketFns(bucket)
                for _, event in ipairs(bucket._events) do
                    c._handlers[event] = onFire
                end
            end
        end
    end

    local Commands = modules.Commands
    if Commands then
        for c in pairs(Commands._state.instances) do
            local events = c._restrictionEvents
            if events then
                local handler = Commands._impl.makeRestrictionHandler(c)
                events:Unregister("ADDON_RESTRICTION_STATE_CHANGED")
                events:Register("ADDON_RESTRICTION_STATE_CHANGED", handler)
                if events._handlers.ADDON_RESTRICTION_STATE_CHANGED ~= handler then
                    fail("Commands: the restriction handler for '" .. tostring(c._name) .. "' did not register again")
                end
            end
        end
    end
    if #failures > 0 then raise(failures) end

    -- 5. The shadow environment gained nothing but the library table.
    for key in pairs(env) do
        if key ~= "Foundry_1_0" and key ~= "_G" then
            fail("the shadow environment holds '" .. tostring(key) .. "'")
        end
    end
    if #failures > 0 then raise(failures) end

    return { map = map, images = images, copied = copied, rebound = rebound }
end

return INS

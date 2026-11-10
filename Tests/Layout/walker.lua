-- Reachability walker for the Layout specs.
--
-- Answers one question: is any state that a library function relies on kept
-- somewhere a later copy of the library could not find it? A function that
-- captures a table in a local variable (an upvalue) keeps that table out of
-- reach unless the table is also reachable through the library's own tables.
--
-- W.walk{...} visits everything reachable from a set of roots and checks the
-- upvalues of every function that came from the library's own source files.
--
--   F          the library table
--   roots      extra starting points: tables or functions the client or a test
--              holds on to (frames, slash handlers, timers, click functions)
--   isLibrary  function(source) -> boolean; which chunks count as the
--              library's own (default: Foundry.lua and Modules/, not the
--              pinned copies under OldCopies)
--   constants  function(file, name) -> boolean; upvalues that are allowed
--              because they are never written after load
--   functions  function(file, name) -> boolean; function upvalues allowed
--              although they are neither library code nor reachable
--   skipKeys   set of table keys never followed (the mock call logs)
--
-- Two sets are built:
--   layout   tables and functions reachable from F by table edges alone
--            (keys, values and metatables; never through an upvalue)
--   walk     everything the walk visited, which also follows the upvalues of
--            library functions and starts from the extra roots
--
-- An upvalue of a library function is fine when it is
--   * a function that is library code, or in the layout set, or allowed;
--   * F;
--   * an allowed constant (by file and name);
--   * a table in the layout set.
-- Anything else (a table only a closure can reach, a boolean, a number, nil,
-- an unlisted string, a consumer function nothing else holds) is trapped.

local W = {}

function W.isLibrarySource(source)
    local s = tostring(source):gsub("\\", "/")
    if s:find("/OldCopies/", 1, true) then return false end
    return s:find("/Modules/", 1, true) ~= nil or s:find("Foundry%.lua$") ~= nil
end

-- "Modules/DB.lua" or "Foundry.lua" from a chunk name.
function W.fileOf(source)
    local s = tostring(source):gsub("^@", ""):gsub("\\", "/")
    return s:match("(Modules/[^/]+)$") or s:match("([^/]+)$") or s
end

local function neverAllowed() return false end

-- Pushes every table edge of `t` onto `stack`.
local function edges(t, skipKeys, push)
    for k, v in pairs(t) do
        push(k)
        if not (skipKeys and skipKeys[k]) then push(v) end
    end
    local mt = getmetatable(t)
    if mt ~= nil then push(mt) end
end

function W.walk(opts)
    local F = assert(opts.F, "walk: F is required")
    local isLibrary = opts.isLibrary or W.isLibrarySource
    local isConstant = opts.constants or neverAllowed
    local isAllowedFunction = opts.functions or neverAllowed
    local skipKeys = opts.skipKeys

    -- The layout set: table edges only, from F.
    local layoutTables, layoutFunctions = {}, {}
    do
        local stack, n = { F }, 1
        local function push(v)
            local kind = type(v)
            if kind == "table" then
                if not layoutTables[v] then layoutTables[v] = true; n = n + 1; stack[n] = v end
            elseif kind == "function" then
                layoutFunctions[v] = true
            end
        end
        while n > 0 do
            local t = stack[n]; stack[n] = nil; n = n - 1
            edges(t, skipKeys, push)
        end
    end

    -- The walk.
    local seenTables, seenFunctions = {}, {}
    local functions = {}   -- library functions: { fn, file, line, last, upvalues }
    local trapped = {}     -- "file:name" -> { file, name, sites = { "file:line", ... }, why }
    local order = {}

    local function trap(file, name, line, why)
        local key = file .. ":" .. name
        local entry = trapped[key]
        if not entry then
            entry = { file = file, name = name, sites = {}, why = why }
            trapped[key] = entry
            order[#order + 1] = key
        end
        entry.sites[#entry.sites + 1] = file .. ":" .. tostring(line)
    end

    local stack, n = {}, 0
    local function push(v)
        local kind = type(v)
        if kind == "table" then
            if not seenTables[v] then seenTables[v] = true; n = n + 1; stack[n] = v end
        elseif kind == "function" then
            if not seenFunctions[v] then seenFunctions[v] = true; n = n + 1; stack[n] = v end
        end
    end

    local function checkFunction(fn)
        local info = debug.getinfo(fn, "S")
        if info.what == "C" or not isLibrary(info.source) then return end
        local file = W.fileOf(info.source)
        local record = { fn = fn, file = file, line = info.linedefined, last = info.lastlinedefined, upvalues = {} }
        functions[#functions + 1] = record
        local i = 1
        while true do
            local name, value = debug.getupvalue(fn, i)
            if not name then break end
            record.upvalues[#record.upvalues + 1] = { name = name, value = value }
            local ok, why = false, nil
            local kind = type(value)
            if rawequal(value, F) then
                ok = true
            elseif isConstant(file, name) then
                ok = true
            elseif kind == "function" then
                local vinfo = debug.getinfo(value, "S")
                ok = (vinfo.what ~= "C" and isLibrary(vinfo.source))
                    or layoutFunctions[value] == true
                    or isAllowedFunction(file, name)
                why = "function"
            elseif kind == "table" then
                ok = layoutTables[value] == true
                why = "table"
            else
                why = kind
            end
            if not ok then trap(file, name, info.linedefined, why or kind) end
            push(value)
            i = i + 1
        end
    end

    push(F)
    for _, root in ipairs(opts.roots or {}) do push(root) end
    while n > 0 do
        local item = stack[n]; stack[n] = nil; n = n - 1
        if type(item) == "table" then
            edges(item, skipKeys, push)
        else
            checkFunction(item)
        end
    end

    return {
        trapped = trapped,
        order = order,
        functions = functions,
        layoutTables = layoutTables,
        layoutFunctions = layoutFunctions,
        seenTables = seenTables,
        seenFunctions = seenFunctions,
    }
end

-- { [file] = { name, ... } } with sorted names, from a walk result.
function W.trappedByFile(result)
    local byFile = {}
    for _, key in ipairs(result.order) do
        local e = result.trapped[key]
        byFile[e.file] = byFile[e.file] or {}
        table.insert(byFile[e.file], e.name)
    end
    for _, names in pairs(byFile) do table.sort(names) end
    return byFile
end

return W

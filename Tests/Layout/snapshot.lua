-- Snapshots of everything one load of the library could change, and the
-- difference between two of them. Used to show that a copy which does not take
-- over leaves the serving copy untouched. Not a suite of its own.
--
--   local before = SN.take(F)
--   ... load the incoming copy ...
--   local changes = SN.diff(before, SN.take(F))      -- {} when nothing changed
--
-- A snapshot covers every table reachable from the library table and from the
-- test mocks that stand for the client (frames and their call logs, timers,
-- pending after-callbacks, SlashCmdList, the chat output and the named saved
-- variable globals). Each table is recorded with its fields, so a function or a
-- table that is replaced shows as a change even when the new value looks the
-- same: functions and tables are compared by identity, tables also by contents.

local T = ...

local SN = {}

-- The globals a test may use as a saved variable (T.installMocks clears the
-- same names).
local SAVED_VARIABLES = {
    "HomesteadDB", "BawrSpamDB", "TestDB", "TestDB2", "SyntheticDB",
    "DB_A", "DB_B", "FxHomestead", "FxBawrSpam",
}

local function sameValue(a, b)
    return rawequal(a, b) or (a ~= a and b ~= b)
end

local function sortedKeyList(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
    return keys
end

-- Records one table: its label, fields and metatable.
local function record(snapshot, label, tbl)
    local fields, count = {}, 0
    for k, v in pairs(tbl) do
        fields[k] = v
        count = count + 1
    end
    snapshot.tables[tbl] = { label = label, fields = fields, count = count, meta = getmetatable(tbl) }
    snapshot.order[#snapshot.order + 1] = tbl
end

-- opts.roots: extra named tables to cover, as { label = table }
function SN.take(F, opts)
    opts = opts or {}
    local snapshot = { tables = {}, order = {}, root = F }
    local roots = {
        { "F", F },
        { "frames", T.frames }, { "timers", T.timers }, { "afters", T.afters },
        { "SlashCmdList", _G.SlashCmdList }, { "output", T.output },
    }
    for _, name in ipairs(SAVED_VARIABLES) do
        if type(rawget(_G, name)) == "table" then roots[#roots + 1] = { name, rawget(_G, name) } end
    end
    for _, name in ipairs(opts.sv or {}) do
        if type(rawget(_G, name)) == "table" then roots[#roots + 1] = { name, rawget(_G, name) } end
    end
    for label, tbl in pairs(opts.roots or {}) do roots[#roots + 1] = { label, tbl } end

    local queue, head = {}, 1
    local function visit(label, value)
        if type(value) == "table" and not snapshot.tables[value] then
            record(snapshot, label, value)
            queue[#queue + 1] = value
        end
    end
    for _, root in ipairs(roots) do visit(root[1], root[2]) end
    while head <= #queue do
        local tbl = queue[head]; head = head + 1
        local label = snapshot.tables[tbl].label
        for _, k in ipairs(sortedKeyList(tbl)) do
            visit(label .. "." .. tostring(k), rawget(tbl, k))
            visit(label .. ".<key " .. tostring(k) .. ">", k)
        end
        local meta = getmetatable(tbl)
        if meta ~= nil then visit(label .. ".<metatable>", meta) end
    end

    local state = type(F) == "table" and rawget(F, "_state") or nil
    snapshot.copies = type(state) == "table" and type(rawget(state, "copies")) == "table"
        and rawget(state, "copies") or nil
    return snapshot
end

-- The differences between two snapshots, as lines; empty when nothing changed.
-- ignore.copies = n allows up to n entries to be appended to F._state.copies
-- (the record of copies that did not take over), and nothing else.
function SN.diff(a, b, ignore)
    ignore = ignore or {}
    local changes = {}
    if not rawequal(a.root, b.root) then
        changes[#changes + 1] = "the library table was replaced"
        return changes
    end
    for _, tbl in ipairs(a.order) do
        local before, after = a.tables[tbl], b.tables[tbl]
        local label = before.label
        if not after then
            changes[#changes + 1] = label .. ": no longer reachable"
        else
            local exempt = {}
            if tbl == a.copies and (ignore.copies or 0) > 0 then
                for k in pairs(after.fields) do
                    if type(k) == "number" and k > before.count and k <= before.count + ignore.copies
                        and before.fields[k] == nil then
                        exempt[k] = true
                    end
                end
            end
            for _, k in ipairs(sortedKeyList(before.fields)) do
                if after.fields[k] == nil then
                    changes[#changes + 1] = label .. "." .. tostring(k) .. ": removed"
                elseif not sameValue(before.fields[k], after.fields[k]) then
                    changes[#changes + 1] = label .. "." .. tostring(k) .. ": replaced ("
                        .. type(before.fields[k]) .. " -> " .. type(after.fields[k]) .. ")"
                end
            end
            for _, k in ipairs(sortedKeyList(after.fields)) do
                if before.fields[k] == nil and not exempt[k] then
                    changes[#changes + 1] = label .. "." .. tostring(k) .. ": added"
                end
            end
            if not rawequal(before.meta, after.meta) then
                changes[#changes + 1] = label .. ": metatable replaced"
            end
        end
    end
    return changes
end

return SN

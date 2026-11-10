-- The record of copies that stood down, the serving copy named in the missing
-- module error, and the /foundry copies command.
--
-- Modules a later copy fills in for a serving copy that lacks them are covered
-- by mixed_copies_spec (a 1.0.4 copy and a trimmed current copy as the first
-- copy); the command cases here show those modules in its output.

local T = ...

local walker = assert(loadfile(T.testsDir .. "/Layout/walker.lua"))(T)

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local OLD_VERSION = { ["v1.0.4"] = "1.0.4", ["v1.0.114"] = "1.0.114" }

-- Loads one copy a file at a time, as the client does: an error in one file
-- does not stop the next. tag is nil for the current code, or a pinned
-- release. spec.skip is a set of module names left out. Returns the errors.
local function load(tag, addonName, version, skip)
    local root, files = T.foundryRoot, T.FOUNDRY_FILES
    if tag then root, files = T.testsDir .. "/OldCopies/" .. tag, T.OLD_COPIES[tag] end
    local errors = {}
    for _, rel in ipairs(files) do
        local module = rel:match("^Modules/(%w+)%.lua$")
        if not (module and skip and skip[module]) then
            local ok, err = pcall(T.loadCopy, { root = root, files = { rel }, addonName = addonName, version = version })
            if not ok then errors[#errors + 1] = tostring(err) end
        end
    end
    return errors
end

-- Release builds: every copy answers a real version number.
local function releaseStack(entries)
    T.installMocks("1.0.0")
    local errors = {}
    for i, e in ipairs(entries) do
        errors[i] = load(e.tag, e.name, e.version or (e.tag and OLD_VERSION[e.tag]) or "1.0.200", e.skip)
    end
    return _G.Foundry_1_0, errors
end

local function keyString(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = tostring(k) end
    table.sort(out)
    return table.concat(out, ",")
end

local function run(arg)
    T.output = {}
    _G.SlashCmdList.FOUNDRY(arg)
    local lines = T.output
    T.output = {}
    return lines
end

--------------------------------------------------------------------------------
-- the record
--------------------------------------------------------------------------------

test("the serving copy creates an empty record", function()
    for _, mode in ipairs({ "release", "dev" }) do
        if mode == "release" then
            releaseStack({ { name = "HostA" } })
        else
            T.installMocks("@project-version@")
            load(nil, "HostA", nil)
        end
        local F = _G.Foundry_1_0
        T.eq(type(F._state.copies), "table", mode .. ": record exists")
        T.eq(#F._state.copies, 0, mode .. ": record is empty")
        T.eq(next(F._state.copies), nil, mode .. ": record has no other keys")
    end
end)

test("a later copy appends exactly one entry with the right fields", function()
    local F = releaseStack({ { name = "HostA", version = "1.0.200" }, { name = "HostB", version = "1.0.201" } })
    local copies = F._state.copies
    T.eq(#copies, 1, "one entry for the whole copy")
    local entry = copies[1]
    T.eq(keyString(entry), "apiVersion,outcome,source,unit,version", "exact fields")
    T.eq(entry.source, "HostB", "source")
    T.eq(entry.version, "1.0.201", "version")
    T.eq(entry.apiVersion, F.API_VERSION, "api version")
    T.eq(entry.unit, "core", "unit")
    T.eq(entry.outcome, "stood down", "outcome")
    T.eq(entry.build, nil, "build is left absent")
    T.eq(F.SOURCE, "HostA", "the serving copy is unchanged")
end)

test("two later copies append two entries in load order", function()
    local F = releaseStack({
        { name = "HostA" }, { name = "HostB", version = "1.0.201" }, { name = "HostC", version = "1.0.202" },
    })
    local copies = F._state.copies
    T.eq(#copies, 2, "two entries")
    T.eq(copies[1].source, "HostB", "first later copy first")
    T.eq(copies[2].source, "HostC", "second later copy second")
    T.eq(copies[2].version, "1.0.202", "second version")
end)

test("a development build of a later copy is recorded and its suppression message still raises", function()
    T.installMocks("1.0.0")
    load(nil, "HostA", "1.0.200")
    local F = _G.Foundry_1_0
    local errors = load(nil, "HostB", "@project-version@")
    T.eq(#F._state.copies, 1, "recorded before the message")
    T.eq(F._state.copies[1].source, "HostB", "the later copy")
    T.eq(#errors, 0, "a release serving copy prints the message instead of raising")
    T.outputContains("an enabled Foundry-1.0 DevBuild was suppressed", "the existing message still appears")
end)

for _, tag in ipairs({ "v1.0.4", "v1.0.114" }) do
    test("nothing is created or written when " .. tag .. " serves", function()
        local F = releaseStack({ { tag = tag, name = "HostA" } })
        load(nil, "HostB", "1.0.201")
        load(tag, "HostC", OLD_VERSION[tag])
        T.eq(rawget(F, "_state"), nil, "no state table")
        T.eq(rawget(F, "copies"), nil, "no copies on the library table")
        T.eq(#T.output, 0, "nothing printed")
        T.eq(_G.SlashCmdList.FOUNDRY, nil, "no command from the older serving copy")
    end)
end

test("nothing is created when the serving copy has a state table without a record", function()
    local F = releaseStack({ { name = "HostA" } })
    F._state.copies = nil
    load(nil, "HostB", "1.0.201")
    T.eq(F._state.copies, nil, "no record created by a later copy")
    F._state.copies = "not a table"
    load(nil, "HostC", "1.0.202")
    T.eq(F._state.copies, "not a table", "a non-table is left alone")
end)

test("loading copies prints nothing and raises nothing in release and development builds", function()
    local _, errors = releaseStack({ { name = "HostA" }, { name = "HostB" }, { tag = "v1.0.114", name = "HostC" } })
    T.eq(#T.output, 0, "release: nothing printed")
    for i = 1, 3 do T.eq(#errors[i], 0, "release: no error in copy " .. i) end

    T.installMocks("@project-version@")
    local e1 = load(nil, "HostA", nil)
    local e2 = load(nil, "HostB", nil)
    T.eq(#T.output, 0, "dev: nothing printed")
    T.eq(#e1, 0, "dev: serving copy loads cleanly")
    T.eq(#e2, 0, "dev: a later copy of the same API stands down silently")
    T.eq(#_G.Foundry_1_0._state.copies, 1, "dev: and is recorded")
end)

--------------------------------------------------------------------------------
-- the missing module error
--------------------------------------------------------------------------------

test("the missing module error keeps its leading text and names the serving copy", function()
    local F = releaseStack({ { name = "HostA", version = "1.0.200" }, { name = "HostB", version = "1.0.201" } })
    local err = T.raises(function() F:RequireModule("Nope") end, "missing module")
    T.truthy(err:find("Foundry-1.0: required module 'Nope' is not present in this build.", 1, true), "old leading text: " .. err)
    T.truthy(err:find("HostA", 1, true), "serving source: " .. err)
    T.truthy(err:find("1.0.200", 1, true), "serving version: " .. err)
    T.truthy(err:find("API version " .. F.API_VERSION, 1, true), "serving api version: " .. err)
    T.falsy(err:find("HostB", 1, true), "not the copy that stood down")
    T.truthy(err:find("copies_record_spec.lua", 1, true), "the location is still the caller: " .. err)
    T.eq(err:match("(Foundry%-1%.0: required.*)$"),
        "Foundry-1.0: required module 'Nope' is not present in this build. Serving copy: HostA, version 1.0.200, API version 7.",
        "exact text")
end)

--------------------------------------------------------------------------------
-- /foundry copies
--------------------------------------------------------------------------------

test("the command on a single copy", function()
    releaseStack({ { name = "HostA", version = "1.0.200" } })
    T.eq(#T.output, 0, "nothing printed at load")
    T.eq(_G.SLASH_FOUNDRY1, "/foundry", "slash name")
    T.eq(type(_G.SlashCmdList.FOUNDRY), "function", "handler")
    T.eq(table.concat(run("copies"), "\n"), table.concat({
        "Foundry: serving copy: HostA, version 1.0.200, API version 7",
        "Foundry: every module comes from the serving copy",
        "Foundry: no copy stood down",
    }, "\n"), "output")
    T.eq(table.concat(run("  COPIES  "), "\n"), table.concat(run("copies"), "\n"), "case and spaces do not matter")
end)

test("the command lists a copy that stood down", function()
    releaseStack({ { name = "HostA", version = "1.0.200" }, { name = "HostB", version = "1.0.201" },
        { name = "HostC", version = "1.0.202" } })
    T.eq(table.concat(run("copies"), "\n"), table.concat({
        "Foundry: serving copy: HostA, version 1.0.200, API version 7",
        "Foundry: every module comes from the serving copy",
        "Foundry: stood down: HostB, version 1.0.201, API version 7",
        "Foundry: stood down: HostC, version 1.0.202, API version 7",
    }, "\n"), "output")
end)

test("the command lists modules filled in from another copy", function()
    local F = releaseStack({
        { name = "HostA", version = "1.0.200", skip = { Window = true, Menu = true } },
        { name = "HostB", version = "1.0.201" },
    })
    T.eq(F.Menu._source, "HostB", "Menu came from the later copy")
    local lines = run("copies")
    T.eq(table.concat(lines, "\n"), table.concat({
        "Foundry: serving copy: HostA, version 1.0.200, API version 7",
        "Foundry: Menu comes from HostB",
        "Foundry: Window comes from HostB",
        "Foundry: stood down: HostB, version 1.0.201, API version 7",
    }, "\n"), "output")
end)

test("the command names a module from an older copy that carries no source", function()
    releaseStack({
        { name = "HostA", skip = { Window = true } },
        { tag = "v1.0.114", name = "HostB" },
    })
    T.eq(table.concat(run("copies"), "\n"), table.concat({
        "Foundry: serving copy: HostA, version 1.0.200, API version 7",
        "Foundry: Window comes from an older copy",
        "Foundry: no copy stood down",
    }, "\n"), "output")
end)

test("any other argument prints one usage line", function()
    releaseStack({ { name = "HostA" } })
    for _, arg in ipairs({ "", "   ", "help", "copy", "x copies" }) do
        local lines = run(arg)
        T.eq(#lines, 1, "[" .. arg .. "] line count")
        T.eq(lines[1], "Foundry: type /foundry copies to see which copies of the library are loaded", "[" .. arg .. "] usage")
    end
    T.eq(#run(nil), 1, "no argument at all")
end)

test("the command is registered once and an existing owner is left alone", function()
    local F = releaseStack({ { name = "HostA" } })
    local handler = _G.SlashCmdList.FOUNDRY
    load(nil, "HostB", "1.0.201")
    load(nil, "HostC", "1.0.202")
    T.eq(_G.SlashCmdList.FOUNDRY, handler, "later copies do not replace the handler")
    T.eq(_G.SLASH_FOUNDRY1, "/foundry", "slash name unchanged")
    T.eq(_G.SLASH_FOUNDRY2, nil, "no second name")
    T.eq(#F._state.copies, 2, "both recorded")

    -- A key already taken by another addon.
    T.installMocks("1.0.0")
    local theirs = function() end
    _G.SlashCmdList.FOUNDRY = theirs
    load(nil, "HostA", "1.0.200")
    T.eq(_G.SlashCmdList.FOUNDRY, theirs, "an existing handler is kept")
    T.eq(_G.SLASH_FOUNDRY1, nil, "and no slash name is claimed")

    -- A slash name already taken under the same key's global.
    T.installMocks("1.0.0")
    _G.SLASH_FOUNDRY1 = "/theirs"
    load(nil, "HostA", "1.0.200")
    T.eq(_G.SLASH_FOUNDRY1, "/theirs", "an existing slash name is kept")
    T.eq(_G.SlashCmdList.FOUNDRY, nil, "and no handler is added")
end)

test("the command handler keeps nothing but the library table out of reach", function()
    local F = releaseStack({ { name = "HostA" }, { name = "HostB" } })
    local result = walker.walk({
        F = F, roots = { _G.SlashCmdList.FOUNDRY },
        constants = walker.isConstant, functions = walker.isAllowedFunction, skipKeys = walker.SKIP_KEYS,
    })
    local names = walker.trappedByFile(result)["Foundry.lua"]
    T.eq(names and table.concat(names, ",") or "", "", "no upvalue of a Foundry.lua function is out of reach")
    local reached = false
    for _, record in ipairs(result.functions) do
        if record.fn == _G.SlashCmdList.FOUNDRY then reached = true end
    end
    T.truthy(reached, "the walk checked the handler")
end)

return tests

-- Tests for the pinned release copies under Tests/OldCopies, and for the
-- harness pieces that load them (T.loadCopy, the per-name Version map).
--
-- Two earlier releases are kept as source: v1.0.4 (five files) and v1.0.114
-- (ten files). Later tests load them next to the current code and compare
-- behaviour, saved data, error messages and instruction counts. The copies
-- never change.

local T = ...

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local copiesDir = T.testsDir .. "/OldCopies"
local digestLib = assert(loadfile(copiesDir .. "/digest.lua"))()
local pinned = assert(loadfile(copiesDir .. "/digests.lua"))()

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local function hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function compiledHeader()
    return hex(string.dump(function() end):sub(1, 12))
end

--------------------------------------------------------------------------------
-- The copies match their releases
--------------------------------------------------------------------------------

test("the compiled-form digests were taken on the same Lua build layout as this run", function()
    T.eq(compiledHeader(), pinned.header,
        "compiled chunk header (regenerate Tests/OldCopies/digests.lua on this build)")
end)

test("release 1.0.4 copies compile to the same bytes as the release source", function()
    local rows = pinned.copies["v1.0.4"]
    for _, rel in ipairs(T.OLD_COPIES["v1.0.4"]) do
        local source = readFile(copiesDir .. "/v1.0.4/" .. rel)
        T.eq(digestLib.digest(digestLib.compiledForm(source)), rows[rel].dump,
            "compiled form of " .. rel)
    end
end)

test("release 1.0.114 copies are byte-identical to the release source", function()
    local rows = pinned.copies["v1.0.114"]
    for _, rel in ipairs(T.OLD_COPIES["v1.0.114"]) do
        local source = readFile(copiesDir .. "/v1.0.114/" .. rel)
        T.eq(digestLib.digest(source), rows[rel].source, "source of " .. rel)
        T.eq(digestLib.digest(digestLib.compiledForm(source)), rows[rel].dump,
            "compiled form of " .. rel)
    end
end)

test("the layout-1 copy is byte-identical to its commit", function()
    local rows = pinned.copies["layout1"]
    for _, rel in ipairs(T.OLD_COPIES["layout1"]) do
        local source = readFile(copiesDir .. "/layout1/" .. rel)
        T.eq(digestLib.digest(source), rows[rel].source, "source of " .. rel)
        T.eq(digestLib.digest(digestLib.compiledForm(source)), rows[rel].dump,
            "compiled form of " .. rel)
        T.falsy(source:find("\nlocal BUILD = ", 1, true), rel .. " carries no build number")
    end
end)

test("release 1.0.4 copies keep only the three released error strings that contain a section mark", function()
    local marked = {}
    for _, rel in ipairs(T.OLD_COPIES["v1.0.4"]) do
        local n = 0
        for line in readFile(copiesDir .. "/v1.0.4/" .. rel):gmatch("[^\n]+") do
            if line:find("\194\167", 1, true) then
                n = n + 1
                T.truthy(line:find('"[^"]*\194\167'),
                    rel .. ": a section mark survives only inside an error string")
            end
        end
        marked[rel] = n
    end
    T.eq(marked["Modules/DB.lua"], 3, "DB.lua keeps its three released strings")
    marked["Modules/DB.lua"] = nil
    for rel, n in pairs(marked) do T.eq(n, 0, rel .. " has no section mark") end
end)

--------------------------------------------------------------------------------
-- Harness: the per-name Version map
--------------------------------------------------------------------------------

test("the Version answered for an addon name can differ per name; other names keep the default", function()
    T.installMocks("@project-version@")
    T.addonVersions["Host"] = "1.2.3"
    T.eq(C_AddOns.GetAddOnMetadata("Host", "Version"), "1.2.3", "overridden name")
    T.eq(C_AddOns.GetAddOnMetadata("Foundry-1.0", "Version"), "@project-version@", "other name")
    T.eq(C_AddOns.GetAddOnMetadata("Host", "Title"), nil, "other keys are still nil")
    T.installMocks("@project-version@")
    T.eq(C_AddOns.GetAddOnMetadata("Host", "Version"), "@project-version@", "the map resets with the mocks")
end)

test("loadCopy applies its version to the copy it loads, as a release build", function()
    T.installMocks("@project-version@")
    local F = T.loadOldCopy("v1.0.114", "HostAddon", "1.2.3")
    T.eq(F.SOURCE, "HostAddon", "copy loaded under the host name")
    T.eq(F.IS_DEV_BUILD, false, "a real version reads as a release build")
    T.eq(F.VERSION, "1.2.3", "version taken from the map")
end)

--------------------------------------------------------------------------------
-- Harness: loading the current code under another build number
--------------------------------------------------------------------------------

test("loadBuild writes the number to the one build line and leaves lines that only look like it", function()
    local seen
    local source = "local BUILD = 4\nseen(BUILD)\n-- local BUILD = 9\n    local BUILD = 3\nseen(BUILD)\n"
    _G.seen = function(v) seen = v end
    T.installMocks("@project-version@")
    local ok, err = pcall(T.loadBuild, { build = 7, files = { "Foundry.lua" }, text = { ["Foundry.lua"] = source } })
    _G.seen = nil
    T.truthy(ok, "loads: " .. tostring(err))
    T.eq(seen, 3, "the indented line still shadows, and the commented one is untouched")
end)

test("loadBuild reads the number back from the line it wrote", function()
    T.installMocks("@project-version@")
    local reads = {}
    _G.seen = function(v) reads[#reads + 1] = v end
    T.loadBuild({ build = 12, files = { "Foundry.lua" }, text = { ["Foundry.lua"] =
        "local BUILD = 1\nseen(BUILD)\n" } })
    _G.seen = nil
    T.eq(reads[1], 12, "the written number")
end)

test("loadBuild refuses a file with no build line or with two", function()
    T.installMocks("@project-version@")
    T.raises(function()
        T.loadBuild({ build = 2, files = { "Foundry.lua" }, text = { ["Foundry.lua"] = "local x = 1\n" } })
    end, "no build line", "0 build lines")
    T.raises(function()
        T.loadBuild({ build = 2, files = { "Foundry.lua" }, text = { ["Foundry.lua"] =
            "local BUILD = 1\nlocal BUILD = 2\n" } })
    end, "two build lines", "2 build lines")
end)

test("loadBuild replaces an exact line once and refuses a line that matches zero or two times", function()
    T.installMocks("@project-version@")
    local reads = {}
    _G.seen = function(v) reads[#reads + 1] = v end
    local text = { ["Foundry.lua"] = "local BUILD = 1\nlocal marker = 'a'\nseen(marker)\n" }
    T.loadBuild({ build = 2, files = { "Foundry.lua" }, text = text,
        replace = { ["local marker = 'a'"] = "local marker = 'b'" } })
    T.eq(reads[1], "b", "the line was replaced")
    T.raises(function()
        T.loadBuild({ build = 2, files = { "Foundry.lua" }, text = text, replace = { ["local missing = 1"] = "x" } })
    end, "zero matches", "matched 0 times")
    local twice = { ["Foundry.lua"] = "local BUILD = 1\nlocal marker = 'a'\nlocal marker = 'a'\n" }
    T.raises(function()
        T.loadBuild({ build = 2, files = { "Foundry.lua" }, text = twice,
            replace = { ["local marker = 'a'"] = "local marker = 'b'" } })
    end, "two matches", "matched 2 times")
    _G.seen = nil
end)

test("a build loaded by loadBuild reads as library source and builds are told apart by their path", function()
    local walker = assert(loadfile(T.testsDir .. "/Layout/walker.lua"))(T)
    T.installMocks("@project-version@")
    local F2 = T.loadBuild({ build = 2, addonName = "HostTwo" })
    T.eq(F2._build, 2, "build written to the library table")
    local source = debug.getinfo(F2.HasModule, "S").source
    T.truthy(source:find("/build-2/Foundry.lua", 1, true), "build segment in the source of the core: " .. source)
    T.truthy(walker.isLibrarySource(source), "the core reads as library source")
    local events = debug.getinfo(F2.Events.New, "S").source
    T.truthy(events:find("/build-2/Modules/Events.lua", 1, true), "module source: " .. events)
    T.truthy(walker.isLibrarySource(events), "a module reads as library source")
    T.installMocks("@project-version@")
    local F3 = T.loadBuild({ build = 3, addonName = "HostThree" })
    T.truthy(debug.getinfo(F3.HasModule, "S").source:find("/build-3/", 1, true), "the other build is told apart")
    T.eq(F3.Events._build, 3, "module build")
end)

test("a pinned copy does not read as library source, so the walker never counts it", function()
    local walker = assert(loadfile(T.testsDir .. "/Layout/walker.lua"))(T)
    T.installMocks("@project-version@")
    local F = T.loadOldCopy("layout1")
    T.falsy(walker.isLibrarySource(debug.getinfo(F.HasModule, "S").source), "layout-1 core")
    T.falsy(walker.isLibrarySource(debug.getinfo(F.Events.New, "S").source), "layout-1 module")
end)

test("plantError makes a copy fail just before the named line, after the lines above it ran", function()
    T.installMocks("@project-version@")
    local err = T.raises(function()
        T.loadBuild({ build = 2, files = { "Foundry.lua" }, replace = T.plantError("local existing = _G.Foundry_1_0", "boom") })
    end, "planted error", "boom")
    T.truthy(tostring(err):find("/build-2/Foundry.lua", 1, true), "raised from the loaded chunk: " .. tostring(err))
    T.eq(_G.Foundry_1_0, nil, "nothing was published before the error")
end)

--------------------------------------------------------------------------------
-- Both copies load and run under today's mocks
--------------------------------------------------------------------------------

-- The frame Lifecycle drives its events through: the one that registered
-- PLAYER_LOGOUT. Not always frames[1] once other modules have made frames.
local function dispatcherFrame()
    for _, frame in ipairs(T.frames) do
        for _, call in ipairs(frame.calls.RegisterEvent) do
            if call[1] == "PLAYER_LOGOUT" then return frame end
        end
    end
end

local function newDbOver(F, addon, sv)
    T.loadedAddons[addon] = true
    return F.DB:New({
        name = addon, sv = sv, defaultProfile = true,
        defaults = { profile = { size = 3 }, global = { flag = true } },
    })
end

local function exerciseCommonModules(F)
    -- Events: a registered handler runs when the frame delivers its event.
    local seen = {}
    local ev = F.Events:New("OldCopyAddon")
    ev:Register("PLAYER_ENTERING_WORLD", function(event, arg) seen[#seen + 1] = event .. ":" .. tostring(arg) end)
    T.Fire(T.frames[#T.frames], "PLAYER_ENTERING_WORLD", 7)
    T.eq(seen[1], "PLAYER_ENTERING_WORLD:7", "event delivered to the handler")

    -- Commands: the slash entry runs a registered subcommand.
    local ran = 0
    local cmds = F.Commands:New({ name = "OldCopyCmd", slashes = { "/occ" } })
    cmds:Register({ name = "go", handler = function() ran = ran + 1 end })
    SlashCmdList["OLDCOPYCMD"]("go")
    T.eq(ran, 1, "slash dispatch reached the subcommand")

    -- DB: defaults appear on read and are stripped again at logout.
    local db = newDbOver(F, "OldCopyAddon", "TestDB")
    T.eq(db.profile.size, 3, "profile default readable")
    T.eq(db.global.flag, true, "global default readable")
    T.Fire(dispatcherFrame(), "PLAYER_LOGOUT")
    T.eq(TestDB.global, nil, "default-only global section stripped at logout")
end

test("release 1.0.4 copy loads and runs under the current mocks", function()
    T.installMocks("@project-version@")
    local F = T.loadOldCopy("v1.0.4")
    T.eq(F.API_VERSION, 4, "API version of the pinned copy")
    for _, name in ipairs({ "Commands", "Events", "Lifecycle", "DB" }) do
        T.truthy(F:HasModule(name), name .. " present")
    end
    for _, name in ipairs({ "List", "Settings", "Tooltip", "Menu", "Window" }) do
        T.falsy(F:HasModule(name), name .. " absent in this release")
    end
    exerciseCommonModules(F)
end)

test("release 1.0.114 copy loads and runs under the current mocks", function()
    T.installMocks("@project-version@")
    local F = T.loadOldCopy("v1.0.114")
    T.eq(F.API_VERSION, 7, "API version of the pinned copy")
    for _, name in ipairs({ "Commands", "Events", "Lifecycle", "DB", "List",
        "Settings", "Tooltip", "Menu", "Window" }) do
        T.truthy(F:HasModule(name), name .. " present")
    end
    exerciseCommonModules(F)
    local list = F.List:New({
        name = "OldCopyList", parent = {}, elementType = "Button",
        extent = 20, initializer = function() end,
    })
    list:SetData({ { id = 1 } })
    T.eq(type(list:GetNativeHandles().view), "table", "List built over the mock view")
end)

test("the layout-1 copy loads and runs under the current mocks", function()
    T.installMocks("@project-version@")
    local F = T.loadOldCopy("layout1")
    T.eq(F.API_VERSION, 7, "API version of the pinned copy")
    T.eq(F._layoutVersion, 1, "layout of the library table")
    T.eq(F._build, nil, "the library table has no build number")
    local modules = { "Commands", "Events", "Lifecycle", "DB", "List",
        "Settings", "Tooltip", "Menu", "Window" }
    for _, name in ipairs(modules) do
        T.truthy(F:HasModule(name), name .. " present")
        T.eq(F[name]._layoutVersion, 1, name .. " layout")
        T.eq(F[name]._build, nil, name .. " has no build number")
    end
    exerciseCommonModules(F)
    local list = F.List:New({
        name = "OldCopyList", parent = {}, elementType = "Button",
        extent = 20, initializer = function() end,
    })
    list:SetData({ { id = 1 } })
    T.eq(type(list:GetNativeHandles().view), "table", "List built over the mock view")
end)

test("a pinned copy and the current code can be loaded one after the other in the same process", function()
    T.installMocks("@project-version@")
    local old = T.loadOldCopy("v1.0.114")
    T.installMocks("@project-version@")
    local current = T.loadFoundry()
    T.truthy(old ~= current, "separate library tables")
    T.eq(current.API_VERSION, old.API_VERSION, "same API version today")
end)

return tests

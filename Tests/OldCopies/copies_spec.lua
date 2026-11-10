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

test("a pinned copy and the current code can be loaded one after the other in the same process", function()
    T.installMocks("@project-version@")
    local old = T.loadOldCopy("v1.0.114")
    T.installMocks("@project-version@")
    local current = T.loadFoundry()
    T.truthy(old ~= current, "separate library tables")
    T.eq(current.API_VERSION, old.API_VERSION, "same API version today")
end)

return tests

-- The build number: one constant every library file carries, so that a later
-- copy can tell whether another is newer. All ten files agree, the value is a
-- positive whole number, and a fresh load publishes it on the library table
-- and on every module.

local T = ...

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local MODULES = { "Commands", "Events", "Lifecycle", "DB", "List", "Settings", "Tooltip", "Menu", "Window" }

-- Every line of one file, with carriage returns removed.
local function linesOf(rel)
    local handle = assert(io.open(T.foundryRoot .. "/" .. rel, "rb"))
    local text = handle:read("*a")
    handle:close()
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = (line:gsub("\r$", ""))
    end
    return lines
end

-- The numbers on every line of one file that matches the shared pattern.
local function buildLines(rel)
    local values = {}
    for _, line in ipairs(linesOf(rel)) do
        local value = line:match(T.BUILD_LINE)
        if value then values[#values + 1] = tonumber(value) end
    end
    return values
end

test("the build line pattern is the one the test loader shares", function()
    T.eq(T.BUILD_LINE, "^local BUILD = (%d+)$", "build line pattern")
end)

test("every library file has exactly one build line, and all ten agree", function()
    T.eq(#T.FOUNDRY_FILES, 10, "library files")
    local first
    for _, rel in ipairs(T.FOUNDRY_FILES) do
        local values = buildLines(rel)
        T.eq(#values, 1, rel .. " build lines")
        first = first or values[1]
        T.eq(values[1], first, rel .. " build number")
    end
end)

test("the build number is a positive whole number", function()
    local value = buildLines("Foundry.lua")[1]
    T.eq(type(value), "number", "build number type")
    T.truthy(value >= 1, "build number is at least 1")
    T.eq(value, math.floor(value), "build number is whole")
end)

test("a fresh load publishes the build number and source on the library table", function()
    local F = T.fresh()
    T.eq(F._build, buildLines("Foundry.lua")[1], "library build")
    T.eq(F._source, "Foundry-1.0", "library source")
end)

test("a fresh load publishes the build number on each module", function()
    local F = T.fresh()
    local expected = buildLines("Foundry.lua")[1]
    for _, name in ipairs(MODULES) do
        T.eq(type(F[name]._build), "number", name .. " build type")
        T.eq(F[name]._build, expected, name .. " build")
    end
end)

test("no library file uses the debug library", function()
    for _, rel in ipairs(T.FOUNDRY_FILES) do
        for number, line in ipairs(linesOf(rel)) do
            T.falsy(line:find("debug%."), rel .. ":" .. number .. " uses the debug library")
        end
    end
end)

return tests

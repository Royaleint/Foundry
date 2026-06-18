-- Foundry packaging contract tests. Loaded by Tests/run.lua, which passes the
-- harness table T. Returns a list of { name, fn } cases.

local T = ...

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local function readAll(path)
    local f = assert(io.open(path, "r"))
    local text = f:read("*a")
    f:close()
    return text
end

local function normalize(path)
    return (path:gsub("\\", "/"))
end

local function runtimeTocFiles(path)
    local files = {}
    for line in readAll(path):gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not line:find("^#") and not line:find("^##") then
            files[#files + 1] = normalize(line)
        end
    end
    return files
end

local function manifestScriptFiles(path)
    local files = {}
    for file in readAll(path):gmatch('<Script%s+file="([^"]+)"%s*/>') do
        files[#files + 1] = normalize(file)
    end
    return files
end

local function eqList(actual, expected, label)
    T.eq(#actual, #expected, label .. " length")
    for i = 1, #expected do
        T.eq(actual[i], expected[i], label .. " item " .. i)
    end
end

test("embedded manifest loads the same runtime Lua files as the standalone TOC", function()
    local tocFiles = runtimeTocFiles(T.foundryRoot .. "/Foundry-1.0.toc")
    local manifestFiles = manifestScriptFiles(T.foundryRoot .. "/Foundry-1.0.xml")

    eqList(manifestFiles, tocFiles, "manifest vs toc")
end)

return tests

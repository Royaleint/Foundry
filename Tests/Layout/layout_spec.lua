-- The library table's layout header and shared state, and the source rule
-- that keeps module state off file-level locals.

local T = ...

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

test("the serving copy carries the layout version and the state table", function()
    local F = T.fresh()
    T.eq(F._layoutVersion, 1, "layout version")
    T.eq(type(F._state), "table", "state table")
    T.eq(type(F._state.modules), "table", "module list")
end)

test("the module methods use the module list held on the state table", function()
    local F = T.fresh()
    local mod = { API_VERSION = 3 }
    T.falsy(F:HasModule("Probe"), "absent before registering")
    T.eq(F:RegisterModule("Probe", mod), mod, "register returns the module")
    T.eq(F._state.modules.Probe, mod, "listed on the state table")
    T.truthy(F:HasModule("Probe"), "found after registering")
    T.eq(F:RequireModule("Probe", 3), mod, "required module")

    local other = { API_VERSION = 1 }
    F._state.modules.Planted = other
    T.truthy(F:HasModule("Planted"), "a module placed on the table is seen")
    T.eq(F:RequireModule("Planted"), other, "and required")
    F._state.modules.Planted = nil
    T.falsy(F:HasModule("Planted"), "and gone when removed")
end)

test("every bundled module is listed on the state table", function()
    local F = T.fresh()
    for _, name in ipairs({ "Commands", "Events", "Lifecycle", "DB", "List", "Settings", "Tooltip", "Menu", "Window" }) do
        T.truthy(F._state.modules[name] ~= nil, name .. " listed")
        T.eq(F._state.modules[name], F[name], name .. " is the module on the table")
    end
end)

test("a copy that stands down leaves the serving table untouched", function()
    local F = T.fresh()
    local state, modules = F._state, F._state.modules
    F:RegisterModule("Probe", {})
    local chunk = assert(loadfile(T.foundryRoot .. "/Foundry.lua"))
    chunk("Foundry-1.0")
    T.eq(_G.Foundry_1_0, F, "the first copy keeps the global")
    T.eq(F._state, state, "state table unchanged")
    T.eq(F._state.modules, modules, "module list unchanged")
    T.truthy(F:HasModule("Probe"), "earlier registration kept")
    T.eq(F._layoutVersion, 1, "layout version unchanged")
end)

--------------------------------------------------------------------------------
-- state never declared as a file-level local
--------------------------------------------------------------------------------

-- Names that must not be declared as locals, by file. A file is checked once
-- it has no entries left in the reachability expected list.
local FORBIDDEN = {
    ["Modules/Lifecycle.lua"] = { "identityHeld", "dispatcher" },
    ["Modules/DB.lua"] = { "sizeWarningEvents" },
}

local function readSource(file)
    local f = assert(io.open(T.foundryRoot .. "/" .. file, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

-- Lines that declare `name` as a local: `local name`, `local a, name = ...`
-- and `local function name`. Comment text is ignored.
local function declarations(src, name)
    local found = {}
    local n = 0
    for line in (src .. "\n"):gmatch("(.-)\r?\n") do
        n = n + 1
        local code = line:gsub("%-%-.*$", "")
        local hit = code:match("^%s*local%s+function%s+([%w_]+)") == name
        local list = code:match("^%s*local%s+([%w_,%s]-)%s*=") or code:match("^%s*local%s+([%w_,%s]+)%s*$")
        if list and not code:match("^%s*local%s+function") then
            for ident in list:gmatch("[%w_]+") do
                if ident == name then hit = true end
            end
        end
        if hit then found[#found + 1] = n end
    end
    return found
end

test("the declaration scan recognises the forms it looks for", function()
    local src = table.concat({
        "local identityHeld = false",
        "local a, identityHeld = 1, 2",
        "local function identityHeld() end",
        "local identityHeld",
        "  local x = identityHeld",
        "-- local identityHeld = 1",
        "F._state.identityHeld = 1",
        "local identityHeldCount = 0",
    }, "\n")
    local lines = declarations(src, "identityHeld")
    T.eq(#lines, 4, "declarations found")
    T.eq(lines[1], 1, "first")
    T.eq(lines[4], 4, "last")
end)

local checked = {}

for file, names in pairs(FORBIDDEN) do
    test(file .. " declares none of its state as file-level locals once it is moved", function()
        local remaining = T.expectedTrapped[file]
        if remaining and #remaining > 0 then return end   -- not moved yet: rule not active
        local src = readSource(file)
        T.truthy(#src > 0, "source read")
        checked[file] = true
        for _, name in ipairs(names) do
            local lines = declarations(src, name)
            T.eq(#lines, 0, name .. " declared as a local at line " .. tostring(lines[1]))
        end
    end)
end

test("once the expected list is empty every file above has been checked", function()
    for _, list in pairs(T.expectedTrapped) do
        if #list > 0 then return end
    end
    for file in pairs(FORBIDDEN) do
        T.truthy(checked[file], file .. " was never checked although nothing is left in the expected list")
    end
end)

return tests

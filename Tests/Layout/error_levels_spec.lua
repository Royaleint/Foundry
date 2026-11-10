-- Error messages and error locations, current code against the 1.0.114
-- release.
--
-- Each case runs the same call on the pinned release copy and on the current
-- code, in dev mode, and compares the message. The directory in front of
-- Modules/ or Foundry.lua and the line numbers are removed first: a moved
-- function may change its line, never its file or its text.
--
-- Two kinds of case:
--   caller  the error is raised at a level that names the code calling the
--           library (DB's refusals, RequireModule). The message must name this
--           test file, which proves no extra function sits between the public
--           entry point and the error call.
--   module  the error is raised with the library function itself as its
--           location (dev diagnostics, levels 1 and 2). The file named must be
--           the same in both builds.
--
-- Adding a case: append to CASES. `setup(F)` (optional) prepares the build and
-- returns a context; `run(F, ctx)` makes the one call that must raise.

local T = ...

local surfaces = assert(loadfile(T.testsDir .. "/Layout/surfaces.lua"))(T)

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local function noop() end

local THIS_FILE = "error_levels_spec.lua"

--------------------------------------------------------------------------------
-- building blocks
--------------------------------------------------------------------------------

local function dbConfig(over)
    local cfg = {
        name = "ErrAddon", sv = "TestDB", defaultProfile = true,
        defaults = { profile = { size = 3 }, global = { flag = true } },
    }
    for k, v in pairs(over or {}) do cfg[k] = v end
    return cfg
end

local function loadedAddon()
    T.loadedAddons["ErrAddon"] = true
end

-- A DB controller ready for method and metamethod errors.
local function liveDb(F)
    loadedAddon()
    return { db = F.DB:New(dbConfig()) }
end

local function destroyedDb(F)
    local ctx = liveDb(F)
    ctx.db:Destroy()
    return ctx
end

-- A DB:New refusal case: `over` changes the config, `prepare` changes the
-- mocks or the saved variables before the call.
local function dbCase(name, over, prepare)
    return {
        name = name, kind = "caller",
        setup = function() loadedAddon(); if prepare then prepare() end end,
        run = function(F) F.DB:New(dbConfig(over)) end,
    }
end

--------------------------------------------------------------------------------
-- cases
--------------------------------------------------------------------------------

local CASES = {}
local function case(c) CASES[#CASES + 1] = c end

-- DB refusals: raised at level 3, so the location is this file.
case({ name = "DB:New with a non-table config", kind = "caller",
    run = function(F) F.DB:New("nope") end })
case(dbCase("DB:New with an empty name", { name = "" }))
case(dbCase("DB:New with a missing saved-variables name", { sv = false }))
case(dbCase("DB:New with non-table defaults", { defaults = 5 }))
case(dbCase("DB:New without defaultProfile", { defaultProfile = false }))
case(dbCase("DB:New with an unknown defaults section", { defaults = { bogus = {} } }))
case(dbCase("DB:New with a wildcard default", { defaults = { profile = { ["*"] = {} } } }))
case(dbCase("DB:New with a non-table schema", { schema = 5 }))
case(dbCase("DB:New with a schema version that is not positive", { schema = { version = 0 } }))
case(dbCase("DB:New with a schema key that is not a string", { schema = { version = 1, key = 5 } }))
case(dbCase("DB:New with a schema migrate that is not a function",
    { schema = { version = 1, key = "global.v", migrate = 5 } }))
case(dbCase("DB:New with a schema key not rooted at global",
    { schema = { version = 1, key = "profile.v", migrate = noop } }))
case(dbCase("DB:New with a bare section as schema key",
    { schema = { version = 1, key = "global", migrate = noop } }))
case(dbCase("DB:New with a schema key covered by defaults",
    { defaults = { global = { v = 1 } }, schema = { version = 1, key = "global.v", migrate = noop } }))
case(dbCase("DB:New while the addon has not finished loading", nil,
    function() T.loadedAddons["ErrAddon"] = "loading" end))
case(dbCase("DB:New without a player identity", nil,
    function() T.identity = { name = "Unknown", realm = "Test Realm" } end))
case(dbCase("DB:New over saved variables that are not a table", nil, function() _G.TestDB = "corrupt" end))
case(dbCase("DB:New over a malformed profileKeys", nil, function() _G.TestDB = { profileKeys = 42 } end))
case(dbCase("DB:New over a malformed profiles section", nil, function() _G.TestDB = { profiles = 42 } end))
case(dbCase("DB:New over a malformed char section", nil, function() _G.TestDB = { char = 42 } end))
case(dbCase("DB:New over a malformed global section", nil, function() _G.TestDB = { global = 42 } end))
case(dbCase("DB:New over a malformed profileKeys entry", nil, function()
    _G.TestDB = { profileKeys = { ["Tester - Test Realm"] = 7 } }
end))
case(dbCase("DB:New over a malformed profile entry", nil, function()
    _G.TestDB = { profiles = { Default = "corrupt" } }
end))
case(dbCase("DB:New over a malformed character bucket", nil, function()
    _G.TestDB = { char = { ["Tester - Test Realm"] = "corrupt" } }
end))
case(dbCase("DB:New over a save stamped by a newer build", {
    schema = { version = 1, key = "global.schemaVersion", migrate = noop },
}, function() _G.TestDB = { global = { schemaVersion = 9 } } end))
case(dbCase("DB:New when the migration raises", {
    schema = { version = 2, key = "global.schemaVersion", migrate = function() error("migrate boom", 0) end },
}, function() _G.TestDB = { global = { old = 1 } } end))
case({
    name = "DB:New while a controller is live for the same saved variables", kind = "caller",
    setup = liveDb,
    run = function(F) F.DB:New(dbConfig()) end,
})

for _, method in ipairs({ "OnReady", "OnSavedVariablesTooLarge", "GetNativeHandles", "Destroy" }) do
    case({
        name = "DB " .. method .. " called on a value that is not a controller", kind = "caller",
        setup = liveDb,
        run = function(F, ctx) ctx.db[method]({}) end,
    })
end

case({
    name = "DB section read on a destroyed controller", kind = "caller",
    setup = destroyedDb,
    run = function(F, ctx) local _ = ctx.db.profile end,
})
case({
    name = "DB sv read on a destroyed controller", kind = "caller",
    setup = destroyedDb,
    run = function(F, ctx) local _ = ctx.db.sv end,
})
for _, key in ipairs({ "realm", "locale", "SetProfile", "RegisterCallback" }) do
    case({
        name = "DB read of the unsupported field " .. key, kind = "caller",
        setup = liveDb,
        run = function(F, ctx) local _ = ctx.db[key] end,
    })
end
for _, key in ipairs({ "profile", "OnReady", "realm", "_private" }) do
    case({
        name = "DB write to the reserved or unsupported field " .. key, kind = "caller",
        setup = liveDb,
        run = function(F, ctx) ctx.db[key] = 1 end,
    })
end

-- RequireModule and RegisterModule.
case({
    name = "RequireModule for a module that is not present", kind = "caller",
    run = function(F) F:RequireModule("Nope") end,
    -- The current message adds the serving copy after the release's text.
    strip = " Serving copy:.*$",
})
case({
    name = "RequireModule for a newer API version than the module has", kind = "caller",
    run = function(F) F:RequireModule("DB", 99) end,
})
case({
    name = "RegisterModule with a bad name", kind = "module",
    run = function(F) F:RegisterModule("", {}) end,
})
case({
    name = "RegisterModule for a module that is already registered", kind = "module",
    run = function(F) F:RegisterModule("DB", {}) end,
})

-- One dev diagnostic per module: the location is the module file.
case({ name = "Commands:New with a non-table config", kind = "module",
    run = function(F) F.Commands:New("nope") end })
case({ name = "Events:New with a bad owner", kind = "module",
    run = function(F) F.Events:New(5) end })
case({ name = "Lifecycle:New with a bad owner", kind = "module",
    run = function(F) F.Lifecycle:New("nope", "ErrAddon") end })
case({ name = "DB OnReady with a handler that is not a function", kind = "module",
    setup = liveDb,
    run = function(F, ctx) ctx.db:OnReady(5) end })
case({ name = "List:New with a non-table config", kind = "module",
    run = function(F) F.List:New("nope") end })
case({ name = "Settings:New with a non-table config", kind = "module",
    run = function(F) F.Settings:New("nope") end })
case({ name = "Tooltip:New with a non-table config", kind = "module",
    run = function(F) F.Tooltip:New("nope") end })
case({ name = "Menu:New with a non-table config", kind = "module",
    run = function(F) F.Menu:New("nope") end })
case({ name = "Window:Attach with something that is not a frame", kind = "module",
    run = function(F) F.Window:Attach("nope") end })

-- A native error passed through unchanged (level 0).
case({
    name = "Events RegisterBucket when the client rejects the event", kind = "module",
    setup = function(F)
        local c = F.Events:New("ErrAddon")
        T.throwOnRegister = { BAD_EVENT = true }
        return { c = c }
    end,
    run = function(F, ctx) ctx.c:RegisterBucket({ events = { "BAD_EVENT" }, interval = 1, handler = noop }) end,
})

-- Paths that go through a callback the library hands to the client or to a
-- consumer. A relay in front of any of them must leave the message and the
-- location as they are.
case({
    name = "poll timer callback raising a consumer hook error", kind = "module",
    setup = function(F)
        T.SetRegional(true)
        local c = F.Lifecycle:New(nil, "ErrPoll")
        c:OnAddonLoaded(function() error("hook boom", 0) end)
        local frame = T.frames[1]
        T.Fire(frame, "ADDON_LOADED", "ErrPoll")
        T.Fire(frame, "PLAYER_LOGIN")
        T.Fire(frame, "PLAYER_ENTERING_WORLD")
        return { callback = T.afters[1].cb }
    end,
    run = function(F, ctx) ctx.callback() end,
})
case({
    name = "logout strip that errors", kind = "module",
    setup = function(F)
        loadedAddon()
        local db = F.DB:New(dbConfig())
        local _ = db.global
        _G.TestDB.global = setmetatable({}, { __index = function() error("strip boom", 0) end })
        return { frame = surfaces.dispatcherFrame() }
    end,
    run = function(F, ctx) T.Fire(ctx.frame, "PLAYER_LOGOUT") end,
})
case({
    name = "slash command that prints help with a faulty help function", kind = "module",
    setup = function(F)
        local c = F.Commands:New({ name = "ErrCmd", slashes = { "/errcmd" } })
        c:Register({ name = "go", handler = noop, help = function() error("help boom", 0) end })
        return { slash = SlashCmdList["ERRCMD"] }
    end,
    run = function(F, ctx) ctx.slash("help") end,
})
case({
    name = "tooltip post-call whose consumer handler raises", kind = "module",
    setup = function(F)
        local processor = surfaces.installTooltipProcessor()
        F.Tooltip:New({ type = 1, handler = function() error("handler boom") end })
        return { callback = processor.postCalls[1].fn, tooltip = surfaces.makeTooltip() }
    end,
    run = function(F, ctx) ctx.callback(ctx.tooltip, {}) end,
})
case({
    name = "settings launcher click after the controller was destroyed", kind = "module",
    setup = function(F)
        local panel = surfaces.installSettingsLauncher()
        local c = F.Settings:New({ title = "ErrPanel", buttonText = "Open", launch = noop })
        c:Destroy()
        return { click = panel.clicks[1] }
    end,
    run = function(F, ctx) ctx.click({}, "LeftButton", false) end,
})
case({
    name = "menu build whose consumer builder raises", kind = "module",
    setup = function(F)
        surfaces.installMenuUtil()
        local c = F.Menu:New({ builder = function() error("builder boom") end })
        local button = surfaces.makeDropdownButton()
        c:SetupDropdown(button)
        return { generator = button.setups[1], root = surfaces.makeRootDescription() }
    end,
    run = function(F, ctx) ctx.generator({}, ctx.root) end,
})
case({
    name = "list row initialization whose consumer initializer raises", kind = "module",
    setup = function(F)
        local c = F.List:New({
            name = "ErrList", parent = {}, elementType = "Button", extent = 20,
            initializer = function() error("initializer boom") end,
        })
        return { initializer = c:GetNativeHandles().view._initializer }
    end,
    run = function(F, ctx) ctx.initializer({}, {}) end,
})
case({
    name = "list row extent that is not a number", kind = "module",
    setup = function(F)
        local c = F.List:New({
            name = "ErrList", parent = {}, elementType = "Button",
            extentCalculator = function() return "wide" end, initializer = noop,
        })
        return { calculator = c:GetNativeHandles().view._calc }
    end,
    run = function(F, ctx) ctx.calculator(1, {}) end,
})
case({
    name = "list SetData from inside an initializer", kind = "module",
    setup = function(F)
        local c
        c = F.List:New({
            name = "ErrList", parent = {}, elementType = "Button", extent = 20,
            initializer = function() c:SetData({}) end,
        })
        return { initializer = c:GetNativeHandles().view._initializer }
    end,
    run = function(F, ctx) ctx.initializer({}, {}) end,
})

--------------------------------------------------------------------------------
-- running
--------------------------------------------------------------------------------

-- Runs one case on one build; returns the raised message.
local function raised(c, buildName)
    local F = surfaces.load(buildName)
    local ctx = c.setup and c.setup(F) or nil
    local ok, err = pcall(c.run, F, ctx)
    T.falsy(ok, c.name .. " (" .. buildName .. "): expected an error")
    T.eq(type(err), "string", c.name .. " (" .. buildName .. "): error is a string")
    return err
end

for _, c in ipairs(CASES) do
    test("error messages and locations match the 1.0.114 release: " .. c.name, function()
        local pinned = raised(c, "pinned")
        local current = raised(c, "current")
        if c.strip then
            local stripped, count = current:gsub(c.strip, "")
            T.eq(count, 1, "the trailing text is present once")
            current = stripped
        end
        T.eq(surfaces.normalise(current), surfaces.normalise(pinned), "message and file")
        if c.kind == "caller" then
            T.truthy(current:find(THIS_FILE, 1, true), "the location names the caller: " .. current)
            T.truthy(pinned:find(THIS_FILE, 1, true), "the release's location names the caller: " .. pinned)
        end
    end)
end

test("the cases cover both kinds of location the library produces", function()
    local kinds = {}
    for _, c in ipairs(CASES) do kinds[c.kind] = (kinds[c.kind] or 0) + 1 end
    T.truthy((kinds.caller or 0) >= 30, "caller-located cases")
    T.truthy((kinds.module or 0) >= 15, "module-located cases")
end)

return tests

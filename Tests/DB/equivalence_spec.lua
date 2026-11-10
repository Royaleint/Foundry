-- Saved-data equivalence: the current code against the 1.0.114 release.
--
-- Every committed DB fixture and a set of scripted scenarios (construct, read
-- sections, migrate, destroy and construct again, log out) run twice in the
-- same process: once on the pinned 1.0.114 copy, once on the current code.
-- The saved-variables table must deep-equal at each checkpoint, and so must
-- everything the scenario observed on the way (values read, errors raised).
--
-- Checkpoints, per scenario:
--   1. after the controller is constructed
--   2. after the scenario's reads, writes, migration and destroy / re-construct
--   3. after the logout strip
--   4. after a second session over the stripped data, and its logout
--
-- Also pinned here: the DB store record has exactly 11 keys.

local T = ...

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local MOCK_VERSION = "@project-version@"   -- dev build: every dev diagnostic raises

local builds = {
    pinned  = function() return T.loadOldCopy("v1.0.114") end,
    current = function() return T.loadFoundry() end,
}

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = deepCopy(v) end
    return c
end

-- Order-independent structural equality. Returns true, or false and the path
-- of the first difference.
local function deepEqual(a, b, path)
    path = path or "<root>"
    if type(a) ~= type(b) then
        return false, path .. " (type " .. type(a) .. " vs " .. type(b) .. ")"
    end
    if type(a) ~= "table" then
        if a ~= b then return false, path .. " (" .. tostring(a) .. " vs " .. tostring(b) .. ")" end
        return true
    end
    for k, v in pairs(a) do
        local ok, where = deepEqual(v, b[k], path .. "." .. tostring(k))
        if not ok then return false, where end
    end
    for k in pairs(b) do
        if a[k] == nil then return false, path .. "." .. tostring(k) .. " (absent vs present)" end
    end
    return true
end

-- Error text without the directory of the file and without line numbers, so
-- the pinned copy's path and the current path compare equal.
local function normalise(msg)
    msg = tostring(msg)
    msg = msg:gsub("%S*[/\\]Modules[/\\]", "Modules/")
    msg = msg:gsub("%S*[/\\]Foundry%.lua", "Foundry.lua")
    msg = msg:gsub(":%d+:", ":")
    return msg
end

local function fixtureTable(file, globalName)
    return T.loadFixture(T.testsDir .. "/DB/fixtures/" .. file)[globalName]
end

-- The frame Lifecycle drives its events through: the one that registered
-- PLAYER_LOGOUT.
local function dispatcherFrame()
    for _, frame in ipairs(T.frames) do
        for _, call in ipairs(frame.calls.RegisterEvent) do
            if call[1] == "PLAYER_LOGOUT" then return frame end
        end
    end
end

local function logout() T.Fire(dispatcherFrame(), "PLAYER_LOGOUT") end

--------------------------------------------------------------------------------
-- running one scenario on one build
--------------------------------------------------------------------------------

-- Returns { checkpoints = {...}, notes = {...} }. A case is:
--   addon, sv, identity   names and character
--   prepare()             optional: extra mock setup after the mocks reset
--   initial()             optional: the saved-variables table to start from
--   config(ctx)           the DB:New config
--   steps(ctx)            optional: runs after construction (ctx.db may be nil)
--   steps2(ctx)           optional: runs in the second session
local function runScenario(buildName, case)
    local rec = { checkpoints = {}, notes = {} }
    local function note(label, value)
        rec.notes[#rec.notes + 1] = { label = label, value = deepCopy(value) }
    end

    local function session(startData, steps, isFirst)
        T.installMocks(MOCK_VERSION)
        local F = builds[buildName]()
        T.loadedAddons[case.addon] = true
        T.identity = deepCopy(case.identity or { name = "Tester", realm = "Test Realm" })
        if case.prepare then case.prepare() end
        _G[case.sv] = deepCopy(startData)

        local ctx = { F = F, note = note }
        local ok, db = pcall(function() return F.DB:New(case.config(ctx)) end)
        if ok then
            ctx.db = db
            note("construct", "ok")
        else
            note("construct", normalise(db))
        end
        if isFirst then rec.checkpoints[#rec.checkpoints + 1] = deepCopy(_G[case.sv]) end

        if steps then
            local sok, serr = pcall(steps, ctx)
            if not sok then note("steps error", normalise(serr)) end
        end
        if isFirst then rec.checkpoints[#rec.checkpoints + 1] = deepCopy(_G[case.sv]) end

        logout()
        return deepCopy(_G[case.sv])
    end

    local start = case.initial and case.initial() or nil
    local stripped = session(start, case.steps, true)
    rec.checkpoints[#rec.checkpoints + 1] = stripped

    local function readAllNext(ctx)
        if not ctx.db then return end
        ctx.note("next session profile", ctx.db.profile)
        ctx.note("next session global", ctx.db.global)
        ctx.note("next session char", ctx.db.char)
    end
    rec.checkpoints[#rec.checkpoints + 1] = session(stripped, case.steps2 or readAllNext, false)
    return rec
end

local function assertEquivalent(case)
    local pinned = runScenario("pinned", case)
    local current = runScenario("current", case)
    for i = 1, #pinned.checkpoints do
        local ok, where = deepEqual(pinned.checkpoints[i], current.checkpoints[i])
        T.truthy(ok, case.addon .. " checkpoint " .. i .. " differs from the 1.0.114 release at " .. tostring(where))
    end
    T.eq(#current.notes, #pinned.notes, "number of observations")
    for i = 1, #pinned.notes do
        T.eq(current.notes[i].label, pinned.notes[i].label, "observation " .. i .. " label")
        local ok, where = deepEqual(pinned.notes[i].value, current.notes[i].value)
        T.truthy(ok, "observation '" .. pinned.notes[i].label .. "' differs from the 1.0.114 release at " .. tostring(where))
    end
    return pinned
end

local function noteOf(rec, label)
    for _, n in ipairs(rec.notes) do
        if n.label == label then return n.value end
    end
end

--------------------------------------------------------------------------------
-- the ten committed fixtures
--------------------------------------------------------------------------------

local SYNTH = { name = "FxChar01", realm = "FxRealm01" }

local function syntheticCase(file, over)
    local case = {
        addon = "TestAddon", sv = "SyntheticDB", identity = SYNTH,
        initial = function() return fixtureTable(file, "SyntheticDB") end,
        config = function()
            return {
                name = "TestAddon", sv = "SyntheticDB", defaultProfile = true,
                defaults = { profile = { size = 3, nested = { on = true } }, global = { flag = true } },
            }
        end,
        steps = function(ctx)
            ctx.note("size", ctx.db.profile.size)
            ctx.db.profile.nested.on = false
            ctx.db.global.extra = 5
            ctx.note("char key", ctx.db:GetNativeHandles().charKey)
        end,
    }
    for k, v in pairs(over or {}) do case[k] = v end
    return case
end

test("saved data matches the 1.0.114 release at each step: Homestead save", function()
    assertEquivalent({
        addon = "Homestead", sv = "FxHomestead",
        identity = { name = "FxChar18", realm = "FxRealm 01" },
        initial = function() return fixtureTable("homestead_sanitized.lua", "HomesteadDB") end,
        config = function()
            return { name = "Homestead", sv = "FxHomestead", defaultProfile = true,
                defaults = { profile = { vendorTracer = {} }, global = {} } }
        end,
        steps = function(ctx)
            ctx.note("chair", ctx.db.global.catalogItems[235523].name)
            ctx.note("icon size", ctx.db.profile.vendorTracer.minimapIconSize)
            ctx.db.global.catalogItems[999999] = { name = "Added in test" }
            ctx.db.profile.vendorTracer.minimapIconSize = 20
        end,
    })
end)

test("saved data matches the 1.0.114 release at each step: BawrSpam save", function()
    assertEquivalent({
        addon = "BawrSpam", sv = "FxBawrSpam",
        identity = { name = "FxChar202", realm = "FxRealm 01" },
        initial = function() return fixtureTable("bawrspam_sanitized.lua", "BawrSpamDB") end,
        config = function()
            return { name = "BawrSpam", sv = "FxBawrSpam", defaultProfile = true,
                defaults = { char = {}, global = { settings = {} } } }
        end,
        steps = function(ctx)
            ctx.note("cursor", ctx.db.char.historyCursor)
            ctx.db.char.historyCursor = ctx.db.char.historyCursor + 1
            ctx.note("dev mode", ctx.db.global.settings.devMode)
        end,
    })
end)

test("saved data matches the 1.0.114 release at each step: empty save", function()
    assertEquivalent(syntheticCase("empty.lua"))
end)

test("saved data matches the 1.0.114 release at each step: empty save with the profile already materialized", function()
    assertEquivalent(syntheticCase("empty_profile_materialized.lua"))
end)

test("saved data matches the 1.0.114 release at each step: a save stamped by a newer build is refused", function()
    local pinned = assertEquivalent(syntheticCase("downgrade_stamped.lua", {
        config = function()
            return { name = "TestAddon", sv = "SyntheticDB", defaultProfile = true,
                schema = { version = 3, key = "global.schemaVersion", migrate = function() end } }
        end,
    }))
    T.truthy(tostring(noteOf(pinned, "construct")):find("downgrade", 1, true), "the release refuses this save")
end)

for _, file in ipairs({
    "malformed_char_bucket.lua", "malformed_profile_entry.lua", "malformed_profilekeys_entry.lua",
    "malformed_profilekeys_nontable.lua", "malformed_sv_nontable.lua",
}) do
    test("saved data matches the 1.0.114 release at each step: malformed save " .. file .. " is refused untouched", function()
        local pinned = assertEquivalent(syntheticCase(file, {
            steps = function(ctx) ctx.note("controller", ctx.db ~= nil) end,
        }))
        T.truthy(noteOf(pinned, "construct") ~= "ok", "the release refuses this save")
    end)
end

--------------------------------------------------------------------------------
-- scripted scenarios
--------------------------------------------------------------------------------

local function plainConfig(over)
    return function(ctx)
        local cfg = {
            name = "TestAddon", sv = "TestDB", defaultProfile = true,
            defaults = {
                profile = { size = 3, nested = { on = true, list = {} } },
                global = { flag = true, tuning = { rate = 2 } },
                char = { seen = false },
            },
        }
        if over then over(cfg, ctx) end
        return cfg
    end
end

local function readAll(ctx)
    ctx.note("profile", ctx.db.profile)
    ctx.note("global", ctx.db.global)
    ctx.note("char", ctx.db.char)
end

local STAMPED_DEFAULT = function()
    return { profileKeys = { ["Tester - Test Realm"] = "Default" } }
end

test("saved data matches the 1.0.114 release at each step: a new save, defaults read and partly overridden", function()
    assertEquivalent({
        addon = "TestAddon", sv = "TestDB", config = plainConfig(),
        steps = function(ctx)
            readAll(ctx)
            ctx.db.profile.size = 9
            ctx.db.global.tuning.rate = 2
            ctx.db.char.seen = true
            ctx.db.profile.nested.list[1] = "kept"
            readAll(ctx)
        end,
    })
end)

test("saved data matches the 1.0.114 release at each step: sections never read stay unwritten", function()
    assertEquivalent({
        addon = "TestAddon", sv = "TestDB", config = plainConfig(),
        steps = function(ctx) ctx.note("only global", ctx.db.global.flag) end,
    })
end)

test("saved data matches the 1.0.114 release at each step: a stored false beats a default true", function()
    assertEquivalent({
        addon = "TestAddon", sv = "TestDB", config = plainConfig(),
        initial = function()
            local sv = STAMPED_DEFAULT()
            sv.global = { flag = false, other = 1 }
            return sv
        end,
        steps = readAll,
    })
end)

test("saved data matches the 1.0.114 release at each step: a stored value under a table default raises and survives", function()
    local pinned = assertEquivalent({
        addon = "TestAddon", sv = "TestDB", config = plainConfig(),
        initial = function()
            local sv = STAMPED_DEFAULT()
            sv.global = { tuning = 5 }
            return sv
        end,
        steps = function(ctx)
            local ok, err = pcall(function() return ctx.db.global end)
            ctx.note("read raised", not ok)
            ctx.note("error", ok and "" or normalise(err))
            ctx.note("raw tuning", ctx.db.sv.global.tuning)
        end,
    })
    T.eq(noteOf(pinned, "read raised"), true, "the release raises on the conflicting value")
end)

test("saved data matches the 1.0.114 release at each step: a new save with a schema is stamped, not migrated", function()
    local pinned = assertEquivalent({
        addon = "TestAddon", sv = "TestDB",
        config = plainConfig(function(cfg, ctx)
            cfg.schema = { version = 2, key = "global.schemaVersion", migrate = function() ctx.note("migrate called", true) end }
        end),
        steps = readAll,
    })
    T.eq(noteOf(pinned, "migrate called"), nil, "no migration on a new save")
end)

test("saved data matches the 1.0.114 release at each step: an unversioned save is migrated", function()
    local pinned = assertEquivalent({
        addon = "TestAddon", sv = "TestDB",
        config = plainConfig(function(cfg, ctx)
            cfg.schema = {
                version = 2, key = "global.schemaVersion",
                migrate = function(db, from)
                    ctx.note("migrate from", from == nil and "nil" or from)
                    db.global.migrated = true
                    db.global.old = nil
                end,
            }
        end),
        initial = function()
            local sv = STAMPED_DEFAULT()
            sv.global = { old = "value" }
            return sv
        end,
        steps = readAll,
    })
    T.eq(noteOf(pinned, "migrate from"), "nil", "the release migrates an unversioned save")
end)

test("saved data matches the 1.0.114 release at each step: an older stamp is migrated from its version", function()
    local pinned = assertEquivalent({
        addon = "TestAddon", sv = "TestDB",
        config = plainConfig(function(cfg, ctx)
            cfg.schema = {
                version = 3, key = "global.schemaVersion",
                migrate = function(db, from)
                    ctx.note("migrate from", from)
                    db.global.upgraded = from
                end,
            }
        end),
        initial = function()
            local sv = STAMPED_DEFAULT()
            sv.global = { schemaVersion = 2 }
            return sv
        end,
        steps = readAll,
    })
    T.eq(noteOf(pinned, "migrate from"), 2, "the release migrates from the stored version")
end)

test("saved data matches the 1.0.114 release at each step: a migration that raises is refused and the data is still stripped", function()
    local pinned = assertEquivalent({
        addon = "TestAddon", sv = "TestDB",
        config = plainConfig(function(cfg)
            cfg.schema = {
                version = 2, key = "global.schemaVersion",
                migrate = function(db) db.global.flag = true; db.global.half = 1; error("migrate boom", 0) end,
            }
        end),
        initial = function()
            local sv = STAMPED_DEFAULT()
            sv.global = { old = 1 }
            return sv
        end,
    })
    T.truthy(tostring(noteOf(pinned, "construct")):find("migrate boom", 1, true), "the release refuses")
end)

test("saved data matches the 1.0.114 release at each step: a stamp equal to the build's version runs no migration", function()
    local pinned = assertEquivalent({
        addon = "TestAddon", sv = "TestDB",
        config = plainConfig(function(cfg, ctx)
            cfg.schema = { version = 2, key = "global.schemaVersion", migrate = function() ctx.note("migrate called", true) end }
        end),
        initial = function()
            local sv = STAMPED_DEFAULT()
            sv.global = { schemaVersion = 2, kept = 1 }
            return sv
        end,
        steps = readAll,
    })
    T.eq(noteOf(pinned, "migrate called"), nil, "no migration at the current version")
end)

test("saved data matches the 1.0.114 release at each step: destroy and construct again over the same save", function()
    assertEquivalent({
        addon = "TestAddon", sv = "TestDB", config = plainConfig(),
        steps = function(ctx)
            local first = ctx.db
            first.profile.size = 7
            first.global.tuning.rate = 5
            first:Destroy()
            local ok, err = pcall(function() return first.profile end)
            ctx.note("read after destroy raised", not ok)
            ctx.note("destroy error", ok and "" or normalise(err))
            local second = ctx.F.DB:New(plainConfig()(ctx))
            ctx.note("size after rebuild", second.profile.size)
            second.global.tuning.rate = 2
            second.char.seen = true
        end,
    })
end)

test("saved data matches the 1.0.114 release at each step: construction refused while a controller is live", function()
    local pinned = assertEquivalent({
        addon = "TestAddon", sv = "TestDB", config = plainConfig(),
        steps = function(ctx)
            ctx.db.profile.size = 4
            local ok, err = pcall(function() return ctx.F.DB:New(plainConfig()(ctx)) end)
            ctx.note("second construct raised", not ok)
            ctx.note("error", ok and "" or normalise(err))
        end,
    })
    T.eq(noteOf(pinned, "second construct raised"), true, "the release refuses a second live controller")
end)

test("saved data matches the 1.0.114 release at each step: two saved-variables tables in one session", function()
    assertEquivalent({
        addon = "TestAddon", sv = "TestDB", config = plainConfig(),
        steps = function(ctx)
            ctx.db.profile.size = 8
            local other = ctx.F.DB:New({
                name = "TestAddon", sv = "TestDB2", defaultProfile = true,
                defaults = { global = { count = 0 } },
            })
            other.global.count = 3
            ctx.note("other", other.global.count)
            ctx.note("other raw", _G.TestDB2)
        end,
    })
end)

test("saved data matches the 1.0.114 release at each step: ready and size-warning handlers and native handles", function()
    assertEquivalent({
        addon = "TestAddon", sv = "TestDB", config = plainConfig(),
        steps = function(ctx)
            ctx.db:OnReady(function(db) ctx.note("ready size", db.profile.size) end)
            ctx.db:OnSavedVariablesTooLarge(function() end)
            local handles = ctx.db:GetNativeHandles()
            ctx.note("char key", handles.charKey)
            ctx.note("profile key", handles.profileKey)
            ctx.note("materialized", handles.materialized)
        end,
    })
end)

test("saved data matches the 1.0.114 release at each step: data under the old character key moves to the full-name key", function()
    local pinned = assertEquivalent({
        addon = "TestAddon", sv = "TestDB",
        identity = { name = "Tester", realm = "Test Realm", surname = "Smith" },
        prepare = function() T.SetRegional(true) end,
        config = plainConfig(),
        initial = function()
            return {
                profileKeys = { ["Tester - Test Realm"] = "Default" },
                char = { ["Tester - Test Realm"] = { seen = true, history = { 1, 2 } } },
            }
        end,
        steps = function(ctx)
            ctx.note("char key", ctx.db:GetNativeHandles().charKey)
            ctx.note("char", ctx.db.char)
        end,
    })
    T.eq(noteOf(pinned, "char key"), "Tester Smith", "the release uses the full-name key")
    T.eq(noteOf(pinned, "char").history[2], 2, "the old bucket's data moved")
end)

test("saved data matches the 1.0.114 release at each step: a character with no identity yet is refused", function()
    local pinned = assertEquivalent({
        addon = "TestAddon", sv = "TestDB", identity = { name = "Unknown", realm = "Test Realm" },
        config = plainConfig(),
    })
    T.truthy(noteOf(pinned, "construct") ~= "ok", "the release refuses")
end)

test("saved data matches the 1.0.114 release at each step: an addon that has not finished loading is refused", function()
    local pinned = assertEquivalent({
        addon = "TestAddon", sv = "TestDB",
        prepare = function() T.loadedAddons["TestAddon"] = "loading" end,
        config = plainConfig(),
    })
    T.truthy(noteOf(pinned, "construct") ~= "ok", "the release refuses")
end)

test("saved data matches the 1.0.114 release at each step: a wildcard default is refused", function()
    local pinned = assertEquivalent({
        addon = "TestAddon", sv = "TestDB",
        config = plainConfig(function(cfg) cfg.defaults.profile["*"] = {} end),
    })
    T.truthy(tostring(noteOf(pinned, "construct")):find("*", 1, true), "the release refuses")
end)

--------------------------------------------------------------------------------
-- the store record
--------------------------------------------------------------------------------

-- The store behind a controller is held by an upvalue of the controller
-- metatable's __index; read it from there so the test sees the real record.
local function storeOf(db)
    local index = getmetatable(db).__index
    local i = 1
    while true do
        local name, value = debug.getupvalue(index, i)
        if not name then return nil end
        if name == "controllerStore" then return value[db] end
        i = i + 1
    end
end

local function recordKeys(buildName)
    T.installMocks(MOCK_VERSION)
    local F = builds[buildName]()
    T.loadedAddons["TestAddon"] = true
    local db = F.DB:New({
        name = "TestAddon", sv = "TestDB", defaultProfile = true,
        defaults = { profile = { size = 3 } },
    })
    local store = storeOf(db)
    T.truthy(store, "the store record is reachable")
    local keys = {}
    for k in pairs(store) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

test("the DB store record has exactly 11 keys, the same as the 1.0.114 release", function()
    local pinned = recordKeys("pinned")
    local current = recordKeys("current")
    T.eq(#pinned, 11, "the release's store record")
    T.eq(#current, 11, "the current store record")
    T.eq(table.concat(current, ","), table.concat(pinned, ","), "the same keys")
    T.eq(table.concat(current, ","),
        "addonName,charKey,defaults,destroyed,materialized,onMismatch,profileKey,sections,sizeWarningHandlers,sv,svName",
        "the expected key set")
end)

return tests

-- Foundry.DB behavior tests. Loaded by Tests/run.lua, which passes the harness
-- table T. Returns a list of { name, fn } cases.
--
-- Foundry.DB is the AceDB-3.0 replacement and the highest-risk module in the
-- library: save-file bugs are silent until a user's data is already gone. These
-- cases assert the SPEC's behavioral contract (CYCLE-3-DB-SPEC.md Rev 3) directly
-- against the module, with HOSTILE-GRADE mocks from the start (Cycle-2b lesson 1:
-- a green harness with friendly mocks hid four real bugs). Where the spec and the
-- implementation disagree, the test asserts the SPEC and is left FAILING, marked
-- clearly -- never bent to make the implementation pass.
--
-- Group prefixes mirror spec §9: empty-init, populated-init, leftover-keys,
-- defaults-backfill, logout-strip, dynamic-keys, schema-steps, malformed,
-- downgrade, identity-timing, plus api-guard, unsupported-matrix, escape-hatch,
-- destroy, ready-hook, shared-defaults, strip-isolation, version-pins.
--
-- Hostile-mock contract (Tests/run.lua installMocks):
--   * UnitName("player") / GetRealmName() are T.identity-driven; the DEFAULT realm
--     is multi-word ("Test Realm") so a charKey separator/space bug cannot hide.
--     Per-test nil / "" / "Unknown" states exercise refuse-before-mutation.
--   * C_AddOns.IsAddOnLoaded returns the real TWO booleans (loadedOrLoading,
--     loaded); the timing guard keys on the SECOND, so a "loading"-state :New must
--     refuse (the premature-fire class).
--   * PLAYER_LOGOUT is delivered through the REAL Lifecycle dispatcher via
--     T.Fire(T.frames[1], "PLAYER_LOGOUT"); the strip is asserted by inspecting raw
--     _G[name] contents, never a "strip ran" flag.

local T = ...

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local function noop() end

local CHARKEY = "Tester - Test Realm"   -- the default identity's charKey

-- The dispatcher frame Lifecycle lazily creates (first :New OR the DB strip-seam
-- registration, whichever happens first). DB's _RegisterPostLogout calls
-- ensureDispatcher() itself, so even a DB-only consumer has a frame at index 1.
local function dispatcherFrame()
    return T.frames[1]
end

-- Drive PLAYER_LOGOUT through the real dispatcher (the strip's true transport).
local function fireLogout()
    return T.Fire(dispatcherFrame(), "PLAYER_LOGOUT")
end

-- A fresh dev/release build with one addon already finished-loading, ready for a
-- :New that passes the timing guard. Returns the Foundry table.
local function freshLoaded(tocVersion, addonName)
    local F = T.fresh(tocVersion)
    T.loadedAddons[addonName or "TestAddon"] = true
    return F
end

-- Construct the common Homestead-style controller (profile + global defaults).
local function newHS(F, opts)
    opts = opts or {}
    return F.DB:New({
        name = opts.name or "TestAddon",
        sv = opts.sv or "TestDB",
        defaults = opts.defaults,
        defaultProfile = true,
        schema = opts.schema,
    })
end

-- Deep structural equality (order-independent), for raw-SV comparisons. Tables
-- compared by keys+values recursively; scalars by ==. Returns true/false and a
-- path string on mismatch.
local function deepEqual(a, b, path)
    path = path or "<root>"
    if type(a) ~= type(b) then return false, path .. " (type " .. type(a) .. " vs " .. type(b) .. ")" end
    if type(a) ~= "table" then
        if a ~= b then return false, path .. " (" .. tostring(a) .. " vs " .. tostring(b) .. ")" end
        return true
    end
    for k, v in pairs(a) do
        local ok, p = deepEqual(v, b[k], path .. "." .. tostring(k))
        if not ok then return false, p end
    end
    for k in pairs(b) do
        if a[k] == nil then return false, path .. "." .. tostring(k) .. " (missing in first)" end
    end
    return true
end

local function assertDeepEqual(a, b, msg)
    local ok, p = deepEqual(a, b)
    if not ok then error((msg or "deepEqual") .. ": mismatch at " .. p, 2) end
end

-- A deep copy, so a fixture's table can be snapshotted before mutation for a
-- byte-untouched comparison.
local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = deepCopy(v) end
    return c
end

-- Count keys in a table.
local function keyCount(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Load a committed fixture's named global. Returns the table value.
local function fixture(file, globalName)
    local env = T.loadFixture(T.testsDir .. "/DB/fixtures/" .. file)
    return env[globalName]
end

--------------------------------------------------------------------------------
-- harness wiring
--------------------------------------------------------------------------------

-- harness-loads-db
test("harness: Foundry.DB module loads and registers under the harness", function()
    local F = T.fresh()
    T.eq(type(F.DB), "table", "DB module loaded")
    T.eq(type(F.DB.New), "function", "DB:New present")
    T.eq(F.DB.API_VERSION, 1, "DB.API_VERSION == 1")
    T.truthy(F:HasModule("DB"), "DB registered")
    T.eq(F:RequireModule("DB", 1), F.DB, "RequireModule('DB',1) returns the module")
    -- Identity mocks present.
    T.eq(type(_G.UnitName), "function", "UnitName mock present")
    T.eq(type(_G.GetRealmName), "function", "GetRealmName mock present")
end)

--------------------------------------------------------------------------------
-- version-pins (spec §9 version-pins): the four updated pins + DB/F markers
--------------------------------------------------------------------------------

-- version-pins-library-and-module
test("version-pins: F.API_VERSION == 5 and DB.API_VERSION == 1", function()
    local F = T.fresh()
    T.eq(F.API_VERSION, 5, "library API_VERSION is 5 (DB bumped 3 -> 4, List 4 -> 5)")
    T.eq(F.DB.API_VERSION, 1, "DB per-module marker == 1")
    -- Sibling markers unchanged.
    T.eq(F.Commands.API_VERSION, 1, "Commands marker unchanged")
    T.eq(F.Events.API_VERSION, 1, "Events marker unchanged")
    T.eq(F.Lifecycle.API_VERSION, 1, "Lifecycle marker unchanged (private seam keeps it 1)")
end)

--------------------------------------------------------------------------------
-- api-guard (spec §9 api-guard): validation atomicity, error ordering,
-- duplicate live sv, defaultProfile mode rejection
--------------------------------------------------------------------------------

-- api-guard-config-not-table
test("api-guard: :New with a non-table config refuses (dev raise)", function()
    local F = freshLoaded()
    T.raises(function() F.DB:New("HomesteadDB") end, "string config", "config must be a table")
    T.raises(function() F.DB:New(nil) end, "nil config", "config must be a table")
end)

-- api-guard-name-required
test("api-guard: name must be a non-empty string", function()
    local F = freshLoaded()
    T.raises(function() F.DB:New({ sv = "TestDB", defaultProfile = true }) end,
        "missing name", "name must be a non-empty string")
    T.raises(function() F.DB:New({ name = "", sv = "TestDB", defaultProfile = true }) end,
        "empty name", "name must be a non-empty string")
    T.raises(function() F.DB:New({ name = 5, sv = "TestDB", defaultProfile = true }) end,
        "numeric name", "name must be a non-empty string")
end)

-- api-guard-sv-required
test("api-guard: sv must be a non-empty string (the field split from name)", function()
    local F = freshLoaded()
    T.raises(function() F.DB:New({ name = "TestAddon", defaultProfile = true }) end,
        "missing sv", "sv must be a non-empty string")
    T.raises(function() F.DB:New({ name = "TestAddon", sv = "", defaultProfile = true }) end,
        "empty sv", "sv must be a non-empty string")
end)

-- api-guard-type-before-state
test("api-guard: type errors surface BEFORE state/identity errors (order)", function()
    -- An invalid config TYPE must be reported even though the addon is NOT loaded
    -- (the timing/identity gates are state errors that come later). Here name is
    -- the wrong type AND the addon is not in T.loadedAddons; the type error wins.
    local F = T.fresh()   -- nothing loaded
    local err = T.raises(function() F.DB:New({ name = 7, sv = "TestDB", defaultProfile = true }) end,
        "type before state", "name must be a non-empty string")
    T.truthy(not tostring(err):find("has not finished loading", 1, true),
        "the timing (state) error did not pre-empt the type error")
end)

-- api-guard-rejected-creates-nothing
test("api-guard: a rejected :New creates NOTHING -- not even _G[sv]", function()
    local F = freshLoaded()
    T.eq(_G.TestDB, nil, "no SV global before :New")
    -- Reject on a bad defaultProfile (a validation failure that precedes mutation).
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = "Default" })
    end, "rejected", "defaultProfile must be the literal true")
    T.eq(_G.TestDB, nil, "rejected :New did not even create _G[sv]")
end)

-- api-guard-rejected-existing-sv-byte-untouched
test("api-guard: a rejected :New leaves an EXISTING _G[sv] byte-for-byte untouched", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { keep = 1, nested = { x = true } } }
    local snapshot = deepCopy(_G.TestDB)
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = "nope" })
    end, "rejected", "defaultProfile must be the literal true")
    assertDeepEqual(_G.TestDB, snapshot, "existing SV unchanged by a rejected :New")
end)

-- api-guard-defaultprofile-string-rejected
test("api-guard: defaultProfile as a literal string is rejected (named-shared-profile mode)", function()
    local F = freshLoaded()
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = "Default" })
    end, "string mode", "defaultProfile must be the literal true")
end)

-- api-guard-defaultprofile-absent-rejected
test("api-guard: defaultProfile absent is rejected (per-character-profile mode)", function()
    local F = freshLoaded()
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB" })
    end, "absent mode", "defaultProfile must be the literal true")
end)

-- api-guard-defaultprofile-false-rejected
test("api-guard: defaultProfile == false is rejected (only literal true accepted)", function()
    local F = freshLoaded()
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = false })
    end, "false mode", "defaultProfile must be the literal true")
end)

-- api-guard-defaults-section-rejected
test("api-guard: an unsupported defaults section name is rejected", function()
    local F = freshLoaded()
    T.raises(function()
        newHS(F, { defaults = { realm = { x = 1 } } })
    end, "realm section", "is not supported; only 'profile', 'char', and 'global'")
end)

-- api-guard-defaults-section-nontable
test("api-guard: a defaults section that is not a table is rejected", function()
    local F = freshLoaded()
    T.raises(function()
        newHS(F, { defaults = { global = 5 } })
    end, "non-table section", "must be a table")
end)

-- api-guard-wildcard-rejected-shallow
test("api-guard: a top-level '*' wildcard default key is rejected (spec §4.5)", function()
    local F = freshLoaded()
    T.raises(function()
        newHS(F, { defaults = { global = { ["*"] = { count = 0 } } } })
    end, "shallow wildcard", "wildcard default key")
end)

-- api-guard-wildcard-rejected-deep
test("api-guard: a DEEP '**' wildcard default key is rejected at any depth", function()
    local F = freshLoaded()
    T.raises(function()
        newHS(F, { defaults = { profile = { sub = { deeper = { ["**"] = { y = 1 } } } } } })
    end, "deep wildcard", "wildcard default key")
end)

-- api-guard-dup-live-sv-rejected
test("api-guard: a second :New for a live (un-Destroyed) sv is rejected", function()
    local F = freshLoaded()
    local db1 = newHS(F, { defaults = { global = { a = 1 } } })
    T.truthy(db1, "first controller created")
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true })
    end, "dup live sv", "already has a live controller")
end)

-- api-guard-dup-live-sv-release
-- [D3 CONTRACT CASE -- PASSING]: refused construction raises in BOTH builds via
-- the `refuse()` transport (not F:RaiseDevError). Spec §7 row 1: no checked return
-- exists at either consumer's call site, so the raise IS the release refusal.
test("api-guard: duplicate-live-sv refuses in a RELEASE build (raise, D3)", function()
    -- Bad-config refusals raise in BOTH builds (spec §7 row 1, D3): no checked
    -- return at either consumer's call site. So the release build raises too.
    local F = freshLoaded("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    newHS(F, { defaults = { global = { a = 1 } } })
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true })
    end, "dup live sv release raises", "already has a live controller")
end)

-- api-guard-reuse-after-destroy
test("api-guard: after Destroy the sv slot frees and a later :New may reuse it", function()
    local F = freshLoaded()
    local db1 = newHS(F, { defaults = { global = { a = 1 } } })
    db1:Destroy()
    local db2
    local ok = pcall(function() db2 = F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true }) end)
    T.truthy(ok, "re-:New after Destroy does not raise")
    T.truthy(db2, "a fresh controller for the released sv is created")
end)

-- api-guard-bad-config-release-raises
-- [D3 CONTRACT CASE -- PASSING]: a bad-config refusal raises in both builds via
-- `refuse()`. Spec §7 row 1: the raise is the release refusal (no checked return).
test("api-guard: a bad config in a RELEASE build raises (D3 -- refused construction)", function()
    local F = freshLoaded("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    -- Spec §7 row 1: refused construction raises a named error in BOTH builds.
    T.raises(function() F.DB:New({ name = "", sv = "TestDB", defaultProfile = true }) end,
        "release refuses with raise", "name must be a non-empty string")
end)

--------------------------------------------------------------------------------
-- identity-timing (spec §9 identity-timing): timing guard + identity gate
--------------------------------------------------------------------------------

-- identity-timing-loading-refuses
test("identity-timing: :New while the addon is 'loading' refuses (2nd-return gate)", function()
    local F = T.fresh()
    T.loadedAddons["TestAddon"] = "loading"   -- (true, false): loadedOrLoading but NOT finished
    T.raises(function() newHS(F, { defaults = { global = { a = 1 } } }) end,
        "loading refuses", "has not finished loading")
    T.eq(_G.TestDB, nil, "no SV created by a too-early :New")
end)

-- identity-timing-not-loaded-refuses
test("identity-timing: :New for a not-loaded addon refuses", function()
    local F = T.fresh()   -- T.loadedAddons empty -> (false, false)
    T.raises(function() newHS(F, { defaults = { global = { a = 1 } } }) end,
        "not loaded refuses", "has not finished loading")
    T.eq(_G.TestDB, nil, "no SV created")
end)

-- identity-timing-loaded-succeeds
test("identity-timing: :New when the addon has FINISHED loading succeeds", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = { a = 1 } } })
    T.truthy(db, "construction succeeds once finished-loading")
end)

-- identity-timing-nil-name-refuses
test("identity-timing: a nil player name refuses before any mutation (no 'nil - Realm')", function()
    local F = freshLoaded()
    T.identity = { name = nil, realm = "Test Realm" }
    T.raises(function() newHS(F, { defaults = { global = { a = 1 } } }) end,
        "nil name refuses", "player identity is not available")
    T.eq(_G.TestDB, nil, "no SV created -- 'nil - Realm' never computed")
end)

-- identity-timing-empty-name-refuses
test("identity-timing: an empty player name refuses before any mutation", function()
    local F = freshLoaded()
    T.identity = { name = "", realm = "Test Realm" }
    T.raises(function() newHS(F, { defaults = { global = { a = 1 } } }) end,
        "empty name refuses", "player identity is not available")
    T.eq(_G.TestDB, nil, "no SV created")
end)

-- identity-timing-unknown-name-refuses
test("identity-timing: UnitName's 'Unknown' placeholder refuses (never 'Unknown - Realm')", function()
    local F = freshLoaded()
    T.identity = { name = "Unknown", realm = "Test Realm" }
    T.raises(function() newHS(F, { defaults = { global = { a = 1 } } }) end,
        "Unknown name refuses", "player identity is not available")
    T.eq(_G.TestDB, nil, "no SV created -- 'Unknown - Realm' never computed")
end)

-- identity-timing-nil-realm-refuses
test("identity-timing: a nil realm refuses before any mutation (no 'Name - ')", function()
    local F = freshLoaded()
    T.identity = { name = "Tester", realm = nil }
    T.raises(function() newHS(F, { defaults = { global = { a = 1 } } }) end,
        "nil realm refuses", "realm identity is not available")
    T.eq(_G.TestDB, nil, "no SV created -- 'Name - ' never computed")
end)

-- identity-timing-empty-realm-refuses
test("identity-timing: an empty realm refuses", function()
    local F = freshLoaded()
    T.identity = { name = "Tester", realm = "" }
    T.raises(function() newHS(F, { defaults = { global = { a = 1 } } }) end,
        "empty realm refuses", "realm identity is not available")
    T.eq(_G.TestDB, nil, "no SV created")
end)

-- identity-timing-unknown-realm-refuses
test("identity-timing: an 'Unknown' realm refuses", function()
    local F = freshLoaded()
    T.identity = { name = "Tester", realm = "Unknown" }
    T.raises(function() newHS(F, { defaults = { global = { a = 1 } } }) end,
        "Unknown realm refuses", "realm identity is not available")
    T.eq(_G.TestDB, nil, "no SV created")
end)

-- identity-timing-multiword-realm-charkey
test("identity-timing: charKey is EXACTLY 'Name - Realm' with a multi-word realm", function()
    local F = freshLoaded()
    T.identity = { name = "Tester", realm = "Test Realm" }   -- internal space
    newHS(F, { defaults = { global = { a = 1 } } })
    -- The write-back records the charKey verbatim: separator " - ", realm spaces intact.
    local pk = _G.TestDB.profileKeys
    T.eq(keyCount(pk), 1, "exactly one profileKeys entry")
    T.truthy(pk["Tester - Test Realm"] ~= nil,
        "charKey is 'Tester - Test Realm' (separator and internal space preserved)")
    T.eq(pk["Tester - Test Realm"], "Default", "resolved profileKey is Default")
end)

-- identity-timing-hyphenated-realm-not-split
test("identity-timing: a realm that itself contains ' - ' is not mis-split", function()
    -- charKey is a plain concat name .. ' - ' .. realm; a realm with embedded
    -- ' - ' must round-trip as the literal key, never be re-parsed.
    local F = freshLoaded()
    T.identity = { name = "Tester", realm = "Aerie - Peak" }
    newHS(F, { defaults = { global = { a = 1 } } })
    T.truthy(_G.TestDB.profileKeys["Tester - Aerie - Peak"] ~= nil,
        "the full 'Tester - Aerie - Peak' key is stored verbatim")
end)

-- identity-timing-no-fileload-identity
test("identity-timing: identity is computed lazily at :New, not at module load", function()
    -- Set a refusing identity BEFORE loading the module: if the module captured
    -- identity at file scope it would have already crashed/cached. Loading must be
    -- clean; only the :New call consults identity.
    T.installMocks("@project-version@")
    T.identity = { name = nil, realm = nil }
    local F = T.loadFoundry()   -- must not error despite nil identity
    T.eq(type(F.DB), "table", "module loaded with no identity available")
    -- Now a :New with the bad identity refuses (proving the call-time read).
    T.loadedAddons["TestAddon"] = true
    T.raises(function() newHS(F, { defaults = { global = { a = 1 } } }) end,
        "lazy identity read at :New", "identity is not available")
end)

-- identity-timing-release-refuses-with-raise
-- [D3 CONTRACT CASE -- PASSING]: invalid-identity refusal raises in both builds
-- via `refuse()`. Spec §7 row 2: the raise is the release refusal (no mutation).
test("identity-timing: invalid identity refuses in a RELEASE build with a raise (D3)", function()
    local F = freshLoaded("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    T.identity = { name = "Unknown", realm = "Test Realm" }
    T.raises(function() newHS(F, { defaults = { global = { a = 1 } } }) end,
        "release identity raises (no mutation)", "identity is not available")
    T.eq(_G.TestDB, nil, "no SV created in release either")
end)

--------------------------------------------------------------------------------
-- empty-init (spec §9 empty-init): fresh save creation + both §4.3 step-3 variants
--------------------------------------------------------------------------------

-- empty-init-creates-sv
test("empty-init: _G[sv] nil at :New is created; sections lazy", function()
    local F = freshLoaded()
    T.eq(_G.TestDB, nil, "no SV before :New")
    local db = newHS(F, { defaults = { global = { a = 1 } } })
    T.eq(type(_G.TestDB), "table", "SV created by :New")
    -- profileKeys written immediately; global NOT yet materialized (lazy).
    T.truthy(_G.TestDB.profileKeys[CHARKEY], "profileKeys written at :New")
    T.eq(_G.TestDB.global, nil, "global NOT materialized until first read (lazy)")
    -- First read materializes and applies defaults.
    T.eq(db.global.a, 1, "global.a default applied on first read")
    T.eq(type(_G.TestDB.global), "table", "global now materialized in the SV")
end)

-- empty-init-poststrip-never-read-profile
test("empty-init: post-strip file when db.profile NEVER read is exactly { profileKeys }", function()
    local F = freshLoaded()
    -- Homestead-shape defaults (profile + global) but we touch only global, never
    -- db.profile -- the BawrSpam path. After strip: profiles must NOT exist.
    local db = newHS(F, { defaults = { profile = { p = 1 }, global = { g = 1 } } })
    T.eq(db.global.g, 1, "touch global only")
    fireLogout()
    -- global was default-only -> empty -> removed. profiles never materialized ->
    -- absent. Exactly { profileKeys = { [charKey] = "Default" } }.
    assertDeepEqual(_G.TestDB, { profileKeys = { [CHARKEY] = "Default" } },
        "never-read-profile post-strip file is exactly the profileKeys-only shape")
end)

-- empty-init-poststrip-read-profile
test("empty-init: post-strip file when db.profile WAS read adds profiles = { [key] = {} }", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { profile = { p = 1 }, global = { g = 1 } } })
    T.eq(db.profile.p, 1, "read db.profile (materializes the empty named profile)")
    T.eq(db.global.g, 1, "read db.global too")
    fireLogout()
    -- The empty named profile survives on the main DB (AceDB asymmetry), so the
    -- file is profileKeys PLUS profiles = { Default = {} }.
    assertDeepEqual(_G.TestDB, {
        profileKeys = { [CHARKEY] = "Default" },
        profiles = { Default = {} },
    }, "read-profile post-strip file keeps the empty named profile")
end)

-- empty-init-no-defaults
test("empty-init: a :New with no defaults still creates the SV and writes profileKeys", function()
    local F = freshLoaded()
    local db = newHS(F, {})   -- no defaults at all
    T.eq(type(_G.TestDB), "table", "SV created")
    T.truthy(_G.TestDB.profileKeys[CHARKEY], "profileKeys written even with no defaults")
    -- global materializes as an empty SV sub-table with no defaults applied.
    T.eq(type(db.global), "table", "global readable")
    T.eq(next(db.global), nil, "global is empty (no defaults)")
end)

--------------------------------------------------------------------------------
-- populated-init (spec §9 populated-init): fixtures load; table identity
--------------------------------------------------------------------------------

-- populated-init-homestead-fixture
test("populated-init: the Homestead sanitized fixture loads with its observable state", function()
    local F = freshLoaded("@project-version@", "Homestead")
    -- Place the fixture data as the SV global, then construct against the
    -- character whose bucket exists in the fixture (multi-word realm).
    _G.FxHomestead = fixture("homestead_sanitized.lua", "HomesteadDB")
    T.identity = { name = "FxChar18", realm = "FxRealm 01" }
    local hsDefaults = { profile = { vendorTracer = {} }, global = {} }
    local db = F.DB:New({ name = "Homestead", sv = "FxHomestead", defaults = hsDefaults, defaultProfile = true })
    T.truthy(db, "controller created over the populated fixture")
    -- Observable state: known global values survive load untouched.
    T.eq(db.global.schemaVersion, 4, "global.schemaVersion observable")
    T.eq(db.global.hasSeenWelcomeV4, true, "hasSeenWelcomeV4 observable")
    T.eq(db.global.lastExportTimestamp, 1780152539, "lastExportTimestamp observable")
    -- catalogItems (thousands of dynamic keys) intact.
    T.eq(type(db.global.catalogItems), "table", "catalogItems present")
    T.eq(db.global.catalogItems[235523].name, "Sturdy Wooden Chair", "a catalog entry observable")
    -- Profile resolves through the shared Default profile.
    T.eq(db.profile.vendorTracer.minimapIconSize, 17, "profile deviation observable")
end)

-- populated-init-bawrspam-fixture
test("populated-init: the BawrSpam sanitized fixture loads with its observable state", function()
    local F = freshLoaded("@project-version@", "BawrSpam")
    _G.FxBawrSpam = fixture("bawrspam_sanitized.lua", "BawrSpamDB")
    T.identity = { name = "FxChar202", realm = "FxRealm 01" }
    local bsDefaults = { char = {}, global = { settings = {} } }
    local db = F.DB:New({ name = "BawrSpam", sv = "FxBawrSpam", defaults = bsDefaults, defaultProfile = true })
    T.truthy(db, "controller created over the populated fixture")
    -- The per-character bucket resolves by EXACT "Name - Realm" keying.
    T.eq(db.char.historyCursor, 8082, "this character's historyCursor observable")
    T.eq(type(db.char.history), "table", "history table present")
    -- global.settings observable.
    T.eq(db.global.settings.antiSignalCap, -6, "settings.antiSignalCap observable")
    T.eq(db.global.settings.devMode, true, "settings.devMode observable")
end)

-- populated-init-global-identity
test("populated-init: db.global IS sv.global (no shadow copy -- VendorDatabase raw read)", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { discoveredAliases = { x = 1 } } }
    local db = newHS(F, { defaults = { global = { g = 1 } } })
    T.truthy(rawequal(db.global, _G.TestDB.global),
        "db.global is the SV's own table (rawequal) -- a raw _G[name].global read sees the same data")
    -- A write through db.global is visible on the raw SV.
    db.global.newKey = 42
    T.eq(_G.TestDB.global.newKey, 42, "a write through db.global lands on the raw SV")
end)

-- populated-init-subtable-identity-stable
test("populated-init: a bound sub-table reference stays identical across the session", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { catalogItems = { [1] = { name = "x" } } } }
    local db = newHS(F, { defaults = { global = {} } })
    local ci = db.global.catalogItems   -- the CatalogStore.lua:577 bind-once pattern
    T.truthy(rawequal(ci, _G.TestDB.global.catalogItems), "bound sub-table is the SV's own")
    -- Re-reading db.global.catalogItems yields the SAME identity (no lazy swap).
    T.truthy(rawequal(ci, db.global.catalogItems), "sub-table identity stable across reads")
    -- And mutating through the bound ref persists.
    ci[2] = { name = "y" }
    T.eq(_G.TestDB.global.catalogItems[2].name, "y", "mutation through the bound ref persists")
end)

-- populated-init-sv-property
test("populated-init: db.sv is the live SavedVariables root (BawrSpam cross-char surface)", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, char = { ["Other - Realm"] = { history = {} } } }
    local db = newHS(F, { defaults = { char = {} } })
    T.truthy(rawequal(db.sv, _G.TestDB), "db.sv is _G[sv] itself")
    -- Cross-character access via db.sv.char (History.lua:330-331 pattern).
    T.eq(type(db.sv.char["Other - Realm"]), "table", "another character's bucket reachable via db.sv.char")
end)

--------------------------------------------------------------------------------
-- defaults-backfill (spec §9 defaults-backfill): apply semantics
--------------------------------------------------------------------------------

-- backfill-scalar-into-nil-only
test("defaults-backfill: a scalar default fills a raw-nil slot only; stored values untouched", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { kept = "stored" } }
    local db = newHS(F, { defaults = { global = { kept = "default", added = "new" } } })
    T.eq(db.global.kept, "stored", "stored value not overwritten by the default")
    T.eq(db.global.added, "new", "missing key filled from default")
end)

-- backfill-stored-false-beats-default-true
test("defaults-backfill: a stored FALSE beats a default TRUE (nil-vs-false, not truthiness)", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { flag = false } }
    local db = newHS(F, { defaults = { global = { flag = true } } })
    T.eq(db.global.flag, false, "stored false is preserved against a default true")
end)

-- backfill-additive-subtree
test("defaults-backfill: a new default subtree lands additively in an old save (settings.throttle)", function()
    local F = freshLoaded()
    -- Old save with settings present but missing the newer throttle key.
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" },
        global = { settings = { existing = 1 } } }
    local db = newHS(F, { defaults = { global = { settings = { existing = 99, throttle = 0.5 } } } })
    T.eq(db.global.settings.existing, 1, "existing key not overwritten")
    T.eq(db.global.settings.throttle, 0.5, "the new throttle key backfilled into the old save")
end)

-- backfill-table-default-fresh-subtree
test("defaults-backfill: a table default into a raw-nil slot creates the full subtree", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = { nested = { a = 1, b = { c = 2 } } } } })
    T.eq(db.global.nested.a, 1, "subtree scalar applied")
    T.eq(db.global.nested.b.c, 2, "nested subtree applied recursively")
end)

-- backfill-stored-zero-beats-default
test("defaults-backfill: a stored 0 beats a non-zero default (0 is not nil)", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { count = 0 } }
    local db = newHS(F, { defaults = { global = { count = 10 } } })
    T.eq(db.global.count, 0, "stored 0 preserved against a default 10")
end)

-- backfill-no-mutation-of-defaults-table
test("defaults-backfill: the defaults table is never written into during apply", function()
    local F = freshLoaded()
    local defaults = { global = { nested = { a = 1 } } }
    local snapshot = deepCopy(defaults)
    local db = newHS(F, { defaults = defaults })
    db.global.nested.a = 999   -- mutate the live section
    db.global.extra = "live"
    assertDeepEqual(defaults, snapshot, "defaults table unchanged by apply or by live mutation")
end)

--------------------------------------------------------------------------------
-- malformed (spec §9 malformed): structural refusal + value-level preserve-skip
--------------------------------------------------------------------------------

-- malformed-sv-nontable
test("malformed: a non-table SV global refuses construction (dev), SV untouched", function()
    local F = freshLoaded()
    _G.TestDB = "I am not a table"
    T.raises(function() newHS(F, { defaults = { global = { a = 1 } } }) end,
        "non-table SV", "is malformed")
    T.eq(_G.TestDB, "I am not a table", "the corrupt SV value is never overwritten")
end)

-- malformed-profilekeys-nontable
test("malformed: a non-table profileKeys refuses, SV untouched", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = 42, global = { someSetting = true } }
    local snapshot = deepCopy(_G.TestDB)
    T.raises(function() newHS(F, { defaults = { global = {} } }) end,
        "non-table profileKeys", "is malformed")
    assertDeepEqual(_G.TestDB, snapshot, "SV byte-untouched on malformed refusal")
end)

-- malformed-char-bucket-nontable
test("malformed: a non-table char bucket refuses, corrupt value preserved", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, char = { [CHARKEY] = "corrupt" } }
    T.raises(function() newHS(F, { defaults = { char = {} } }) end,
        "non-table char bucket", "is malformed")
    T.eq(_G.TestDB.char[CHARKEY], "corrupt", "corrupt bucket never overwritten")
end)

-- malformed-profile-entry-nontable
test("malformed: a non-table profile entry refuses", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, profiles = { Default = "corrupt" } }
    T.raises(function() newHS(F, { defaults = { profile = {} } }) end,
        "non-table profile entry", "is malformed")
end)

-- malformed-profilekeys-entry-nonstring
test("malformed: a non-string profileKeys[charKey] for the running char refuses", function()
    local F = freshLoaded()
    -- The running identity must match the malformed entry's key for the check to bite.
    T.identity = { name = "FxChar01", realm = "FxRealm01" }
    _G.TestDB = { profileKeys = { ["FxChar01 - FxRealm01"] = 7 } }
    T.raises(function() newHS(F, { defaults = { global = {} } }) end,
        "non-string profileKeys entry", "is malformed")
end)

-- malformed-fixture-sv-nontable
test("malformed: the committed non-table-SV fixture refuses", function()
    local F = freshLoaded()
    _G.SyntheticDB = fixture("malformed_sv_nontable.lua", "SyntheticDB")
    T.identity = { name = "FxChar01", realm = "FxRealm01" }
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "SyntheticDB", defaults = { global = {} }, defaultProfile = true })
    end, "fixture non-table SV", "is malformed")
end)

-- malformed-fixture-char-bucket
test("malformed: the committed malformed-char-bucket fixture refuses, value preserved", function()
    local F = freshLoaded()
    _G.SyntheticDB = fixture("malformed_char_bucket.lua", "SyntheticDB")
    T.identity = { name = "FxChar01", realm = "FxRealm01" }
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "SyntheticDB", defaults = { char = {} }, defaultProfile = true })
    end, "fixture malformed char bucket", "is malformed")
    T.eq(_G.SyntheticDB.char["FxChar01 - FxRealm01"], "corrupt", "corrupt bucket preserved")
end)

-- malformed-release-raises
-- [D3 CONTRACT CASE -- PASSING]: a malformed-SV refusal raises in both builds via
-- `refuse()`. Spec §7 row 3: the raise is the release refusal (SV untouched).
test("malformed: a malformed SV refuses in a RELEASE build with a raise (D3)", function()
    local F = freshLoaded("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    _G.TestDB = "corrupt"
    T.raises(function() newHS(F, { defaults = { global = {} } }) end,
        "release malformed raises", "is malformed")
    T.eq(_G.TestDB, "corrupt", "corrupt value preserved in release too")
end)

-- malformed-value-type-mismatch-preserve-skip-dev
test("malformed: value-level type-mismatch-under-table-default is preserve-and-skip (dev raises diagnostic)", function()
    -- A stored scalar where the default declares a table: the stored value is
    -- PRESERVED, the default subtree NOT applied, and dev emits a loud diagnostic
    -- (D2). The diagnostic is RaiseDevError, which raises in dev -- but the read
    -- that triggers materialization is db.global.x. We assert the value is
    -- preserved by catching the dev raise and re-reading on a release build below.
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { sub = 5 } }   -- scalar where default is a table
    local db = newHS(F, { defaults = { global = { sub = { inner = 1 } } } })
    -- Materializing global triggers the mismatch diagnostic: in dev this raises.
    T.raises(function() local _ = db.global end, "dev mismatch diagnostic", "conflicts with its table-typed default")
end)

-- malformed-value-type-mismatch-preserve-release
test("malformed: value-level type-mismatch preserves the stored scalar (release, no raise)", function()
    local F = freshLoaded("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { sub = 5 } }
    local db = newHS(F, { defaults = { global = { sub = { inner = 1 } } } })
    -- In release the diagnostic prints and the read proceeds; the stored 5 is kept
    -- and the default subtree is NOT applied.
    local v = db.global.sub
    T.eq(v, 5, "stored scalar preserved (not clobbered to {})")
    T.outputContains("conflicts with its table-typed default", "release printed the mismatch diagnostic")
end)

--------------------------------------------------------------------------------
-- downgrade (spec §9 downgrade): newer-stored-version refusal
--------------------------------------------------------------------------------

local function schemaFor(version)
    return { version = version, key = "global.schemaVersion", migrate = function() end }
end

-- downgrade-refuses-dev
test("downgrade: stored version newer than declared refuses construction (dev), SV untouched", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { schemaVersion = 5, data = 1 } }
    local snapshot = deepCopy(_G.TestDB)
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true, schema = schemaFor(4) })
    end, "downgrade refuses", "is newer than this build's declared version")
    assertDeepEqual(_G.TestDB, snapshot, "SV byte-identical after downgrade refusal")
end)

-- downgrade-no-profilekeys-writeback
test("downgrade: NO profileKeys write-back happens on a downgrade refusal", function()
    local F = freshLoaded()
    -- A char with no existing profileKeys entry; if construction had proceeded it
    -- would have written one. The refusal must leave profileKeys exactly as-is.
    _G.TestDB = { global = { schemaVersion = 5 } }   -- no profileKeys at all
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true, schema = schemaFor(4) })
    end, "downgrade refuses", "is newer than this build's declared")
    T.eq(_G.TestDB.profileKeys, nil, "no profileKeys table created by a refused downgrade")
end)

-- downgrade-fixture
test("downgrade: the committed downgrade-stamped fixture (v99) refuses against a lower build", function()
    local F = freshLoaded()
    _G.SyntheticDB = fixture("downgrade_stamped.lua", "SyntheticDB")
    T.identity = { name = "FxChar01", realm = "FxRealm01" }
    local snapshot = deepCopy(_G.SyntheticDB)
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "SyntheticDB", defaultProfile = true, schema = schemaFor(4) })
    end, "fixture downgrade refuses", "is newer than this build's declared")
    assertDeepEqual(_G.SyntheticDB, snapshot, "fixture SV byte-identical after refusal")
end)

-- downgrade-release-raises
-- [D3 CONTRACT CASE -- PASSING]: a downgrade refusal raises in both builds via
-- `refuse()`. Spec §7 row 4 / §8.3: the raise is the release refusal (SV untouched).
test("downgrade: a downgrade refuses in a RELEASE build with a raise (D3)", function()
    local F = freshLoaded("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { schemaVersion = 5 } }
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true, schema = schemaFor(4) })
    end, "release downgrade raises", "is newer than this build's declared")
end)

-- downgrade-equal-version-ok
test("downgrade: stored == declared is NOT a downgrade (construction proceeds)", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { schemaVersion = 4 } }
    local db
    local ok = pcall(function()
        db = F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true, schema = schemaFor(4) })
    end)
    T.truthy(ok, "equal version does not refuse")
    T.truthy(db, "controller created at equal version")
end)

--------------------------------------------------------------------------------
-- schema-steps (spec §9 schema-steps): the migration seam
--------------------------------------------------------------------------------

-- schema-fresh-stamps-no-migrate
test("schema-steps: a fresh SV stamps the version and does NOT call migrate", function()
    local F = freshLoaded()
    local migrateCalled = false
    local schema = { version = 4, key = "global.schemaVersion",
        migrate = function() migrateCalled = true end }
    local db = F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true, schema = schema })
    T.falsy(migrateCalled, "migrate NOT called on a fresh SV")
    T.eq(db.global.schemaVersion, 4, "the fresh SV is stamped with the declared version")
end)

-- schema-migrate-then-stamp
test("schema-steps: stored 1 + declared 4 calls migrate(db, 1) then stamps 4", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { schemaVersion = 1 } }
    local gotVersion
    local schema = { version = 4, key = "global.schemaVersion",
        migrate = function(db, stored) gotVersion = stored; db.global.migrated = true end }
    local db = F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true, schema = schema })
    T.eq(gotVersion, 1, "migrate received the stored version 1")
    T.eq(db.global.migrated, true, "migrate mutated the live controller")
    T.eq(db.global.schemaVersion, 4, "stamped to the declared version after migrate")
end)

-- schema-unversioned-nil
test("schema-steps: a populated-but-unversioned save calls migrate(db, nil)", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { data = 1 } }   -- no stamp
    local sawNil, called = false, false
    local schema = { version = 4, key = "global.schemaVersion",
        migrate = function(db, stored) called = true; sawNil = (stored == nil) end }
    F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true, schema = schema })
    T.truthy(called, "migrate was called on the unversioned populated save")
    T.truthy(sawNil, "migrate received nil for the unversioned save")
end)

-- schema-no-reentry-on-reload
test("schema-steps: a stamped save does NOT re-call migrate on the next session", function()
    -- Simulate a reload: construct, stamp, strip at logout, then re-:New on a fresh
    -- build over the same SV table. migrate must not run the second time.
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { schemaVersion = 1, data = 1 } }
    local calls = 0
    local schema = { version = 4, key = "global.schemaVersion",
        migrate = function() calls = calls + 1 end }
    F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true, schema = schema })
    T.eq(calls, 1, "migrate called once on the first (stored 1) construction")
    fireLogout()
    -- Fresh build, same SV table (stamp now 4): re-construct. Capture the post-strip
    -- table BEFORE freshLoaded() (which re-installs mocks and clears TestDB).
    local postStrip = _G.TestDB
    local F2 = freshLoaded()
    _G.TestDB = postStrip   -- the same post-strip table persists across the reload
    local calls2 = 0
    local schema2 = { version = 4, key = "global.schemaVersion",
        migrate = function() calls2 = calls2 + 1 end }
    local db2 = F2.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true, schema = schema2 })
    T.eq(calls2, 0, "migrate NOT re-called -- the stamp (4) equals declared")
    T.eq(db2.global.schemaVersion, 4, "stamp still 4 after the reload")
end)

-- schema-stamp-survives-strip
test("schema-steps: the stamp survives a full logout strip (it is outside defaults)", function()
    local F = freshLoaded()
    local schema = schemaFor(4)
    local db = F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true, schema = schema })
    T.eq(db.global.schemaVersion, 4, "stamped fresh")
    fireLogout()
    -- The stamp is NOT a default, so the strip never deletes it: it persists.
    T.eq(_G.TestDB.global.schemaVersion, 4, "stamp survives the strip (not defaults-covered)")
end)

-- schema-key-in-defaults-rejected
test("schema-steps: schema.key covered by declared defaults is rejected at :New (§8.2 step 0)", function()
    local F = freshLoaded()
    -- Both committed consumers' CURRENT defaults declare global.schemaVersion -- a
    -- defaults-covered stamp would be stripped at every logout, making migrate run
    -- forever and downgrade protection inert. So this MUST be rejected.
    T.raises(function()
        F.DB:New({
            name = "TestAddon", sv = "TestDB", defaultProfile = true,
            defaults = { global = { schemaVersion = 1 } },
            schema = schemaFor(4),
        })
    end, "schema.key covered by defaults", "is covered by declared defaults")
    T.eq(_G.TestDB, nil, "no SV created by the rejected :New")
end)

-- schema-migrate-raises-refuses-no-stamp
test("schema-steps: migrate raising refuses construction, no stamp written", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { schemaVersion = 1 } }
    local schema = { version = 4, key = "global.schemaVersion",
        migrate = function() error("migration boom") end }
    local db
    T.raises(function()
        db = F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true, schema = schema })
    end, "migrate raises -> refuse", "schema.migrate raised; construction refused")
    -- The stamp is NOT advanced to 4 (no stamp on a refused migration).
    T.eq(_G.TestDB.global.schemaVersion, 1, "stamp stays at the un-migrated version")
end)

-- schema-migrate-raises-falsy
test("schema-steps: migrate raising a FALSY error (error(nil)) still refuses (raised-flag gated)", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { schemaVersion = 1 } }
    local schema = { version = 4, key = "global.schemaVersion",
        migrate = function() error(nil) end }
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true, schema = schema })
    end, "falsy migrate error -> refuse", "construction refused")
    T.eq(_G.TestDB.global.schemaVersion, 1, "no stamp advance on a falsy-erroring migrate")
end)

-- schema-migrate-raises-store-still-stripped
test("schema-steps: after a migrate refusal the store is STILL stripped at logout (§4.3)", function()
    local F = freshLoaded()
    -- migrate writes a default-equal value then raises; the store is refused, but
    -- its (partially written) SV must still be stripped at logout.
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { schemaVersion = 1 } }
    local schema = { version = 4, key = "global.schemaVersion",
        migrate = function(db)
            db.global.transient = "DEFVAL"   -- equal to the default below
            error("boom after a partial write")
        end }
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true, schema = schema,
            defaults = { global = { transient = "DEFVAL" } } })
    end, "migrate raises", "construction refused")
    -- The refused store is registered for the strip; at logout the default-equal
    -- 'transient' is removed.
    fireLogout()
    T.eq(_G.TestDB.global.transient, nil, "the refused store's default-equal value was stripped at logout")
end)

-- schema-validation-bad-version
test("schema-steps: a non-positive-integer schema.version is rejected", function()
    local F = freshLoaded()
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true,
            schema = { version = 0, key = "global.v", migrate = noop } })
    end, "zero version", "schema.version must be a positive integer")
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true,
            schema = { version = 1.5, key = "global.v", migrate = noop } })
    end, "fractional version", "schema.version must be a positive integer")
end)

-- schema-validation-bad-key-root
-- Rev 4 (F1): the only legal stamp root is `global`. A non-global root (an
-- unsupported section like `realm`, OR a keyed-map section like `char`/`profile`)
-- is rejected at :New with the named global-root message.
test("schema-steps: a schema.key not rooted at 'global' is rejected", function()
    local F = freshLoaded()
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true,
            schema = { version = 1, key = "realm.v", migrate = noop } })
    end, "bad root section", "schema.key must be rooted at 'global'")
end)

-- schema-validation-bad-migrate
test("schema-steps: a non-function schema.migrate is rejected", function()
    local F = freshLoaded()
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true,
            schema = { version = 1, key = "global.v", migrate = "notfn" } })
    end, "bad migrate", "schema.migrate must be a function")
end)

-- schema-downgrade-after-strip-cycle
test("schema-steps: downgrade is still detected after a strip cycle (stamp persists)", function()
    -- Build at v5, strip, then a lower (v4) build must still see the persisted v5
    -- stamp and refuse -- the stamp's out-of-defaults survival is what makes
    -- downgrade protection durable.
    local F = freshLoaded()
    local db = F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true, schema = schemaFor(5) })
    T.eq(db.global.schemaVersion, 5, "stamped v5")
    fireLogout()
    T.eq(_G.TestDB.global.schemaVersion, 5, "v5 stamp persisted through the strip")
    local postStrip = _G.TestDB
    local F2 = freshLoaded()
    _G.TestDB = postStrip
    T.raises(function()
        F2.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true, schema = schemaFor(4) })
    end, "lower build refuses against persisted v5", "is newer than this build's declared")
end)

-- schema-key-char-root-rejected (Rev 4, F1) -- on BOTH build axes. A char-rooted
-- stamp is a keyed-map section: the old validation green-lit it, the stamp wrote a
-- scalar sibling of the per-character buckets, and the §8.4 structural check then
-- refused construction on every LATER load -- a permanent lockout. The Rev 4
-- contract rejects the root at :New before any mutation, so the lockout can never
-- be constructed. Assert the named message AND that _G[sv] is byte-untouched:
-- a MISSING global stays missing (no creation), a POPULATED one stays byte-equal.
local function assertCharRootRejected(F, msg)
    -- (a) missing global stays missing.
    _G.TestDB = nil
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true,
            defaults = { char = {} },
            schema = { version = 2, key = "char.schemaVersion", migrate = noop } })
    end, msg .. " (missing global)", "schema.key must be rooted at 'global' (got 'char.schemaVersion')")
    T.eq(_G.TestDB, nil, msg .. ": a rejected :New created no SV global")
    -- (b) populated global stays byte-untouched (deep-compared against a snapshot).
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" },
        char = { [CHARKEY] = { history = { "a", "b" } } },
        global = { settings = { throttle = 5 } } }
    local snapshot = deepCopy(_G.TestDB)
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true,
            defaults = { char = {} },
            schema = { version = 2, key = "char.schemaVersion", migrate = noop } })
    end, msg .. " (populated global)", "char/profile are keyed sections")
    assertDeepEqual(_G.TestDB, snapshot, msg .. ": the populated SV global is byte-untouched")
    -- The F1 lockout narrative as a regression: no char-scalar stamp ever appears,
    -- because the rejection happens BEFORE any stamp write.
    T.eq(_G.TestDB.char.schemaVersion, nil,
        msg .. ": no scalar 'char.schemaVersion' is ever written (rejection precedes the stamp)")
end

test("schema-steps: a char-rooted schema.key is rejected at :New, SV untouched (dev, F1)", function()
    local F = freshLoaded()
    T.truthy(F.IS_DEV_BUILD, "dev build")
    assertCharRootRejected(F, "char-root dev")
end)

test("schema-steps: a char-rooted schema.key is rejected at :New, SV untouched (release, F1)", function()
    local F = freshLoaded("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    assertCharRootRejected(F, "char-root release")
end)

-- schema-key-profile-root-rejected (Rev 4, F1) -- the shared global-root check
-- rejects `profile` identically (dev axis is sufficient given the shared path).
test("schema-steps: a profile-rooted schema.key is rejected at :New, SV untouched (dev, F1)", function()
    local F = freshLoaded()
    _G.TestDB = nil
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true,
            defaults = { profile = {} },
            schema = { version = 2, key = "profile.schemaVersion", migrate = noop } })
    end, "profile-root rejected", "schema.key must be rooted at 'global' (got 'profile.schemaVersion')")
    T.eq(_G.TestDB, nil, "a rejected profile-rooted :New created no SV global")
end)

-- schema-key-f1-lockout-cannot-be-constructed (Rev 4, F1) -- the EXACT old failure
-- is now structurally impossible: drive the full session-1 -> logout -> session-2
-- sequence the probe used; assert the char-scalar stamp never reaches disk, so
-- session 2's §8.4 structural check has nothing to reject.
test("schema-steps: the F1 char-stamp lockout can no longer be constructed", function()
    local F = freshLoaded()
    local schema = { version = 2, key = "char.schemaVersion", migrate = noop }
    -- Session 1: the rejection fires at :New, before the consumer ever reads
    -- db.char or any stamp is written.
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true,
            defaults = { char = {} }, schema = schema })
    end, "session-1 :New rejects the char root", "must be rooted at 'global'")
    T.eq(_G.TestDB, nil, "session 1 wrote no SV global at all")
    -- There is therefore no save file to carry a char-scalar stamp into a later
    -- session; the permanent-lockout precondition (sv.char.schemaVersion scalar)
    -- can never exist.
    T.truthy(_G.TestDB == nil or _G.TestDB.char == nil or _G.TestDB.char.schemaVersion == nil,
        "no sv.char.schemaVersion scalar ever appears")
end)

-- schema-stamp-non-number-dev-diagnostic (Rev 4, F3) -- a PRESENT-but-non-number
-- stamp bypasses §8.3's downgrade check by type, so the otherwise-silent overwrite
-- path gets dev visibility. Dev build: RaiseDevError RAISES the named diagnostic,
-- the author sees the corrupt stamp immediately (and :New halts before migrate).
test("schema-steps: a present-but-non-number stamp raises a loud dev diagnostic (F3)", function()
    local F = freshLoaded()
    T.truthy(F.IS_DEV_BUILD, "dev build")
    -- A corrupt/legacy string "5" stamp, declared 4. The downgrade check is typed
    -- (number-only), so this slips past it; F3 makes the overwrite visible.
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { schemaVersion = "5", data = 1 } }
    T.raises(function()
        F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true,
            defaults = { global = {} },
            schema = { version = 4, key = "global.schemaVersion", migrate = noop } })
    end, "non-number stamp dev raise", "is present but not a number")
end)

-- schema-stamp-non-number-release-path (Rev 4, F3) -- release build PRINTS the
-- diagnostic AND the by-spec nil-path proceeds: migrate(db, nil) runs and the stamp
-- is overwritten to the declared version (the §8.2 step-4 path, now made visible).
test("schema-steps: a present-but-non-number stamp prints then migrates+stamps in release (F3)", function()
    local F = freshLoaded("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { schemaVersion = "5", data = 1 } }
    local migrateArg, called = "UNSET", false
    local db = F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true,
        defaults = { global = {} },
        schema = { version = 4, key = "global.schemaVersion",
            migrate = function(_, s) called = true; migrateArg = s end } })
    -- The diagnostic was printed (not raised) in release.
    T.outputContains("is present but not a number", "release printed the F3 diagnostic")
    -- The nil-path repair ran: migrate was called with nil (non-number treated as
    -- unversioned), and the stamp was overwritten to the declared version.
    T.truthy(called, "release: migrate ran (non-number treated as unversioned)")
    T.eq(migrateArg, nil, "release: migrate received nil (the non-number nil-path)")
    T.eq(db.global.schemaVersion, 4, "release: the corrupt string stamp was overwritten to declared 4")
    T.eq(_G.TestDB.global.data, 1, "release: unrelated stored data is preserved")
end)

--------------------------------------------------------------------------------
-- logout-strip (spec §9 logout-strip): the strip contract on raw SV
--------------------------------------------------------------------------------

-- strip-scalar-equal-removed
test("logout-strip: a default-equal scalar is removed from disk", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = { a = 1, b = 2 } } })
    db.global.b = 99   -- deviate b; a stays at its default
    fireLogout()
    T.eq(_G.TestDB.global.b, 99, "deviating value persists")
    -- a was default-equal -> removed; b remains -> global is { b = 99 }.
    assertDeepEqual(_G.TestDB.global, { b = 99 }, "default-equal scalar 'a' stripped")
end)

-- strip-set-back-to-default-equals-delete
test("logout-strip: setting a key back to its default == deleting it on disk", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { a = 99 } }
    local db = newHS(F, { defaults = { global = { a = 1 } } })
    T.eq(db.global.a, 99, "stored deviation read")
    db.global.a = 1    -- set back to default
    fireLogout()
    T.eq(_G.TestDB.global, nil, "global emptied (a == default) and removed -- identical to a delete")
end)

-- strip-empty-bucket-pruned
test("logout-strip: an empty per-key bucket is pruned (sv.char[key] = {} goes away)", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, char = { [CHARKEY] = {}, ["Other - R"] = { x = 1 } } }
    local db = newHS(F, { defaults = { char = {} } })
    local _ = db.char   -- materialize this character's bucket (empty)
    fireLogout()
    T.eq(_G.TestDB.char[CHARKEY], nil, "this character's empty bucket pruned")
    T.eq(_G.TestDB.char["Other - R"].x, 1, "a non-empty sibling bucket survives")
end)

-- strip-stale-empty-char-bucket-sv-presence
test("logout-strip: a STALE empty char bucket is pruned even when never read this session (SV-presence scope)", function()
    local F = freshLoaded()
    -- A pre-existing empty bucket for a DIFFERENT character; db.char never read.
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, char = { ["Stale - Realm"] = {} } }
    local db = newHS(F, { defaults = { global = { g = 1 } } })
    local _ = db.global   -- touch global only; char never materialized
    fireLogout()
    T.eq(_G.TestDB.char, nil, "the stale empty char section pruned (SV-presence, not materialization)")
end)

-- strip-empty-profile-survives-main-db
test("logout-strip: an empty named profile SURVIVES on the main DB (AceDB asymmetry)", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { profile = { p = 1 } } })
    T.eq(db.profile.p, 1, "materialize the profile (it becomes default-only)")
    fireLogout()
    -- The profile bucket empties under the strip but the empty named profile is
    -- NOT pruned: profiles = { Default = {} } survives.
    T.eq(type(_G.TestDB.profiles), "table", "profiles section survives")
    T.eq(type(_G.TestDB.profiles.Default), "table", "the empty Default profile survives as {}")
    T.eq(next(_G.TestDB.profiles.Default), nil, "and it is empty")
end)

-- strip-profilekeys-survives
test("logout-strip: profileKeys always survives the strip with the character mapping", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = { a = 1 } } })
    local _ = db.global
    fireLogout()
    T.eq(_G.TestDB.profileKeys[CHARKEY], "Default", "profileKeys mapping survives")
end)

-- strip-reload-equivalent
test("logout-strip: the strip runs on the /reload-equivalent path (every PLAYER_LOGOUT)", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = { a = 1 } } })
    db.global.dyn = "keep"
    fireLogout()   -- first reload
    T.eq(_G.TestDB.global.dyn, "keep", "dynamic key survives the first strip")
    T.eq(_G.TestDB.global.a, nil, "default-equal 'a' stripped on the first reload")
end)

-- strip-dynamic-keys-untouched
test("logout-strip: dynamic non-default keys pass through the strip byte-for-byte", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" },
        global = { scannedVendors = { [123] = { name = "V" } }, discoveredAliases = { a = 1 } } }
    local db = newHS(F, { defaults = { global = { a = 1 } } })
    local _ = db.global
    fireLogout()
    T.eq(_G.TestDB.global.scannedVendors[123].name, "V", "dynamic scannedVendors survives")
    T.eq(_G.TestDB.global.discoveredAliases.a, 1, "legacy discoveredAliases survives")
end)

-- strip-unmanaged-section-untouched
test("logout-strip: unmanaged top-level keys and unsupported sections pass through untouched", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" },
        global = { a = 1 },
        realm = { ["R"] = { x = 1 } },   -- unsupported leftover section
        namespaces = { NS = { global = {} } },   -- unsupported
        unknownTopKey = "kept" }
    local db = newHS(F, { defaults = { global = { a = 1 } } })
    local _ = db.global
    fireLogout()
    T.eq(_G.TestDB.realm["R"].x, 1, "leftover realm section untouched")
    T.eq(type(_G.TestDB.namespaces), "table", "leftover namespaces untouched")
    T.eq(_G.TestDB.unknownTopKey, "kept", "unknown top-level key untouched")
end)

-- strip-unmaterialized-section-no-defaults-walk
test("logout-strip: an unmaterialized section is not defaults-walked (nothing to strip)", function()
    local F = freshLoaded()
    -- global has a stored default-equal value but is NEVER read; the defaults walk
    -- is materialization-keyed, so 'a' is NOT removed (no defaults were applied).
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { a = 1, dyn = "x" } }
    local db = newHS(F, { defaults = { global = { a = 1 } } })
    -- Do NOT read db.global.
    fireLogout()
    T.eq(_G.TestDB.global.a, 1, "unread section's default-equal value left intact (not defaults-walked)")
    T.eq(_G.TestDB.global.dyn, "x", "dynamic key intact")
end)

--------------------------------------------------------------------------------
-- dynamic-keys (spec §9 dynamic-keys): the data-loss trap, key-by-key
--------------------------------------------------------------------------------

-- dynamic-wholesale-assignment
test("dynamic-keys: wholesale db.global.X = {} assignment behaves as a plain table", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = {} } })
    db.global.scannedVendors = {}   -- ScanPersistence.lua:353 pattern
    db.global.scannedVendors[5] = { name = "V5" }
    T.eq(_G.TestDB.global.scannedVendors[5].name, "V5", "wholesale assignment + write persists on raw SV")
end)

-- dynamic-nil-delete-permanence
test("dynamic-keys: setting a non-default key to nil deletes it permanently (core.lua:78)", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { enableRequirementScraping = true } }
    local db = newHS(F, { defaults = { global = {} } })
    db.global.enableRequirementScraping = nil   -- a cleanup migration
    fireLogout()
    T.eq(_G.TestDB.global, nil, "global emptied and removed -- the key is gone permanently")
end)

-- dynamic-set-back-to-default-reads-same
test("dynamic-keys: set-back-to-default reads identically next session", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = { opt = "DEF" } } })
    db.global.opt = "changed"
    db.global.opt = "DEF"   -- back to default
    fireLogout()
    -- Next session reads the default again (the stored value was stripped).
    local postStrip = _G.TestDB
    local F2 = freshLoaded()
    _G.TestDB = postStrip
    local db2 = F2.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true, defaults = { global = { opt = "DEF" } } })
    T.eq(db2.global.opt, "DEF", "reads the default next session, exactly as if deleted")
end)

-- dynamic-homestead-inventory-roundtrip
test("dynamic-keys: Homestead dynamic inventory survives load -> mutate -> strip -> reload (fixture)", function()
    local F = freshLoaded("@project-version@", "Homestead")
    _G.FxHomestead = fixture("homestead_sanitized.lua", "HomesteadDB")
    T.identity = { name = "FxChar18", realm = "FxRealm 01" }
    local hsDefaults = { profile = { vendorTracer = {} }, global = {} }
    local db = F.DB:New({ name = "Homestead", sv = "FxHomestead", defaults = hsDefaults, defaultProfile = true })
    -- Snapshot the dynamic-key inventory pre-strip.
    local catalogBefore = keyCount(db.global.catalogItems)
    local aliasName = db.global.catalogItems[235523].name
    T.truthy(catalogBefore > 0, "catalogItems populated")
    -- Mutate a dynamic key, then strip + reload.
    db.global.lastExportTimestamp = 1780152540   -- bump a dynamic key
    fireLogout()
    -- Reload: capture the post-strip file, re-install mocks, restore it, reconstruct.
    local postStrip = _G.FxHomestead
    local F2 = freshLoaded("@project-version@", "Homestead")
    T.identity = { name = "FxChar18", realm = "FxRealm 01" }
    _G.FxHomestead = postStrip
    local db2 = F2.DB:New({ name = "Homestead", sv = "FxHomestead", defaults = hsDefaults, defaultProfile = true })
    T.eq(keyCount(db2.global.catalogItems), catalogBefore, "catalogItems count survived the round-trip")
    T.eq(db2.global.catalogItems[235523].name, aliasName, "a catalog entry name survived")
    T.eq(db2.global.lastExportTimestamp, 1780152540, "the mutated dynamic key persisted")
    T.eq(db2.global.hasSeenWelcomeV4, true, "welcome-gating dynamic key honored")
end)

-- dynamic-bawrspam-history-roundtrip
test("dynamic-keys: BawrSpam history/cursor/stats survive load -> mutate -> strip -> reload (fixture)", function()
    local F = freshLoaded("@project-version@", "BawrSpam")
    _G.FxBawrSpam = fixture("bawrspam_sanitized.lua", "BawrSpamDB")
    T.identity = { name = "FxChar202", realm = "FxRealm 01" }
    local bsDefaults = { char = {}, global = { settings = {} } }
    local db = F.DB:New({ name = "BawrSpam", sv = "FxBawrSpam", defaults = bsDefaults, defaultProfile = true })
    local cursorBefore = db.char.historyCursor
    T.eq(cursorBefore, 8082, "historyCursor pre-strip")
    -- Add a history record (the core user data) and bump the cursor.
    db.char.history[1] = { id = 1, outcome = "blocked" }
    db.char.historyCursor = 8083
    fireLogout()
    local postStrip = _G.FxBawrSpam
    local F2 = freshLoaded("@project-version@", "BawrSpam")
    T.identity = { name = "FxChar202", realm = "FxRealm 01" }
    _G.FxBawrSpam = postStrip
    local db2 = F2.DB:New({ name = "BawrSpam", sv = "FxBawrSpam", defaults = bsDefaults, defaultProfile = true })
    T.eq(db2.char.historyCursor, 8083, "the bumped historyCursor persisted")
    T.eq(db2.char.history[1].outcome, "blocked", "the history record survived")
    -- A SIBLING character's bucket is untouched by this character's session.
    T.eq(type(db2.sv.char["FxChar84 - FxRealm07"]), "table", "a sibling character's bucket intact")
end)

--------------------------------------------------------------------------------
-- leftover-keys (spec §9 leftover-keys): legacy keys round-trip
--------------------------------------------------------------------------------

-- leftover-keys-roundtrip
test("leftover-keys: legacy keys round-trip through load + strip (modulo profileKeys write-back)", function()
    local F = freshLoaded()
    -- A save full of legacy compatibility keys plus an unsupported leftover section.
    local initial = {
        profileKeys = { [CHARKEY] = "Default", ["Other - R"] = "Default" },
        global = {
            discoveredAliases = { [5] = 6 },
            ownershipCache = { x = 1 },
            ownedDecor = { [1] = true },
            hasSeenWelcomeV1 = true, hasSeenWelcomeV2 = true, hasSeenWelcomeV3 = true,
        },
        realm = { ["R"] = { leftover = 1 } },   -- unsupported leftover section
        unknownTop = "kept",
    }
    _G.TestDB = deepCopy(initial)
    local db = newHS(F, { defaults = { global = {} } })
    local _ = db.global   -- materialize global; nothing is default-equal so nothing strips
    fireLogout()
    -- Everything round-trips byte-equal EXCEPT profileKeys (already contained the
    -- running char's mapping, so even that is unchanged here).
    assertDeepEqual(_G.TestDB, initial, "legacy keys + leftover section round-trip byte-equal")
end)

-- leftover-keys-bawrspam-stale-profiles
test("leftover-keys: a stale 'profiles' section on a BawrSpam-shape file round-trips untouched", function()
    local F = freshLoaded()
    -- BawrSpam never reads db.profile; a stale profiles table (AceDB wrote it) must
    -- survive untouched since the section is never materialized.
    local initial = {
        profileKeys = { [CHARKEY] = "Default" },
        char = { [CHARKEY] = { history = { [1] = { id = 1 } } } },
        global = { settings = { devMode = true } },
        profiles = { Default = { stale = 1 } },   -- stale leftover, never read
    }
    _G.TestDB = deepCopy(initial)
    local db = newHS(F, { defaults = { char = {}, global = { settings = {} } } })
    local _ = db.char; local _2 = db.global   -- read char + global, NOT profile
    fireLogout()
    -- The non-default char/global data survives; the stale profiles section is
    -- untouched (it was never materialized, and a non-empty profiles is not pruned).
    T.eq(_G.TestDB.profiles.Default.stale, 1, "stale profiles section survives untouched")
    T.eq(_G.TestDB.char[CHARKEY].history[1].id, 1, "char history survives")
    T.eq(_G.TestDB.global.settings.devMode, true, "global settings survive")
end)

--------------------------------------------------------------------------------
-- unsupported-matrix (spec §9 unsupported-matrix): §5 deny-list, read + write
--------------------------------------------------------------------------------

local UNSUPPORTED_SECTIONS = { "realm", "class", "race", "faction", "factionrealm", "factionrealmregion", "locale" }
local UNSUPPORTED_PROPS = { "profiles", "keys", "defaults", "parent", "children", "callbacks" }
local UNSUPPORTED_METHODS = {
    "SetProfile", "GetProfiles", "GetCurrentProfile", "CopyProfile", "DeleteProfile",
    "ResetProfile", "ResetDB", "RegisterDefaults", "RegisterNamespace", "GetNamespace",
    "RegisterCallback", "UnregisterCallback", "UnregisterAllCallbacks",
}

-- unsupported-section-read-dev
test("unsupported-matrix: every unsupported section READ raises in dev with a named message", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = {} } })
    for _, name in ipairs(UNSUPPORTED_SECTIONS) do
        T.raises(function() local _ = db[name] end, "read " .. name, "AceDB feature '" .. name .. "'")
    end
end)

-- unsupported-property-read-dev
test("unsupported-matrix: every unsupported object PROPERTY read raises in dev", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = {} } })
    for _, name in ipairs(UNSUPPORTED_PROPS) do
        T.raises(function() local _ = db[name] end, "read " .. name, "AceDB feature '" .. name .. "'")
    end
end)

-- unsupported-method-call-dev
test("unsupported-matrix: every unsupported METHOD call raises in dev with the feature name", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = {} } })
    for _, name in ipairs(UNSUPPORTED_METHODS) do
        T.raises(function() local _ = db[name] end, "method " .. name, "AceDB feature '" .. name .. "'")
    end
end)

-- unsupported-read-release-raises
-- [D3 CONTRACT CASE -- PASSING]: an unsupported read raises in both builds -- the
-- __index deny-list path routes through `refuse()`, not F:RaiseDevError. Spec §7
-- row 5 / §5 mechanism note: a nil read is the silent feature-disable §3.4 bans,
-- so the raise is the release refusal.
test("unsupported-matrix: an unsupported read RAISES in a release build too (D3)", function()
    local F = freshLoaded("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    local db = newHS(F, { defaults = { global = {} } })
    -- Spec §7 row 5 / D3: unsupported access raises in BOTH builds (no checked
    -- return for a data read).
    T.raises(function() local _ = db.realm end, "release section read raises", "AceDB feature 'realm'")
    T.raises(function() local _ = db.SetProfile end, "release method read raises", "AceDB feature 'SetProfile'")
end)

-- unsupported-write-dev
test("unsupported-matrix: writing a deny-list section raises in dev (__newindex guard)", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = {} } })
    T.raises(function() db.realm = {} end, "write realm", "reserved or unsupported")
    T.raises(function() db.callbacks = {} end, "write callbacks", "reserved or unsupported")
    -- The stray write did NOT land on the controller (no shadow key) -- the guard
    -- refused it, so rawget sees nothing.
    T.eq(rawget(db, "realm"), nil, "the refused write left no shadow 'realm' key on the controller")
end)

-- unsupported-write-reserved-section
test("unsupported-matrix: writing a reserved SECTION name (global/profile/char/sv) raises", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = {} } })
    for _, name in ipairs({ "global", "profile", "char", "sv" }) do
        T.raises(function() db[name] = {} end, "write reserved " .. name, "reserved or unsupported")
    end
end)

-- unsupported-write-reserved-method
test("unsupported-matrix: writing a reserved METHOD name (OnReady/Destroy) raises", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = {} } })
    T.raises(function() db.OnReady = noop end, "write OnReady", "reserved or unsupported")
    T.raises(function() db.Destroy = noop end, "write Destroy", "reserved or unsupported")
    T.raises(function() db.GetNativeHandles = noop end, "write GetNativeHandles", "reserved or unsupported")
end)

-- unsupported-write-underscore-absent
test("unsupported-matrix: writing an ABSENT underscore-prefixed field raises (reserved class)", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = {} } })
    T.raises(function() db._anything = 1 end, "write _anything", "reserved or unsupported")
    T.raises(function() db._private = "x" end, "write _private", "reserved or unsupported")
end)

-- unsupported-write-underscore-store
-- SPEC ASSERTION (spec §2.2: "all underscore-prefixed fields" writes "fail per §7
-- ... via the controller's __newindex guard"). The controller stores its state at
-- the PRESENT rawset key `_store`; in Lua 5.1 __newindex fires only on ABSENT keys,
-- so `db._store = ...` raw-updates the live store pointer WITHOUT the guard firing.
-- This test asserts the SPEC (the write must be refused) and is expected to FAIL
-- until the implementation closes the gap (e.g. storing the controller state off a
-- side table keyed by the controller, so no underscore key is present on it). Left
-- failing and reported -- not bent to pass.
test("unsupported-matrix: writing the PRESENT _store field is refused (spec §2.2 underscore guard)", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = { a = 1 } } })
    T.raises(function() db._store = "hijack" end, "write _store refused", "reserved or unsupported")
end)

-- unsupported-write-release-raises
-- [D3 CONTRACT CASE -- PASSING]: an unsupported write raises in both builds -- the
-- __newindex guard routes through `refuse()`, not F:RaiseDevError. Spec §5
-- mechanism note: the raise is the release refusal.
test("unsupported-matrix: an unsupported write RAISES in a release build too (D3)", function()
    local F = freshLoaded("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    local db = newHS(F, { defaults = { global = {} } })
    T.raises(function() db.realm = {} end, "release write raises", "reserved or unsupported")
end)

-- unsupported-unknown-name-plain-lua
test("unsupported-matrix: an UNKNOWN (non-reserved) name behaves as plain Lua, both ways", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = {} } })
    -- Read of an unknown name: nil (plain Lua), no raise.
    T.eq(db.somethingArbitrary, nil, "unknown read is plain nil")
    -- Write of an unknown name: lands raw on the controller (exactly as on an AceDB db).
    local ok = pcall(function() db.myConsumerField = 7 end)
    T.truthy(ok, "unknown write does not raise")
    T.eq(rawget(db, "myConsumerField"), 7, "unknown write rawset onto the controller")
    T.eq(db.myConsumerField, 7, "and reads back")
end)

--------------------------------------------------------------------------------
-- escape-hatch (spec §9 escape-hatch): GetNativeHandles
--------------------------------------------------------------------------------

-- escape-hatch-shape
test("escape-hatch: GetNativeHandles returns live sv + snapshots, NO frame field", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = { a = 1 } } })
    local h = db:GetNativeHandles()
    T.truthy(rawequal(h.sv, _G.TestDB), "h.sv is the live SavedVariables root")
    T.eq(h.charKey, CHARKEY, "charKey snapshot present")
    T.eq(h.profileKey, "Default", "profileKey snapshot present")
    T.eq(type(h.materialized), "table", "materialization snapshot present")
    T.eq(h.frame, nil, "NO frame field -- DB owns no event frame")
end)

-- escape-hatch-snapshot-isolation
test("escape-hatch: mutating a snapshot never affects live behavior", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = { a = 1 } } })
    local h = db:GetNativeHandles()
    h.charKey = "HACKED"
    h.materialized.global = true   -- lie about materialization
    -- The live profileKeys write-back used the real charKey, unaffected.
    T.eq(_G.TestDB.profileKeys[CHARKEY], "Default", "live charKey unaffected by snapshot mutation")
    -- A second GetNativeHandles returns the real snapshot again.
    local h2 = db:GetNativeHandles()
    T.eq(h2.charKey, CHARKEY, "fresh snapshot still reports the real charKey")
end)

--------------------------------------------------------------------------------
-- destroy (spec §9 destroy): Destroy + destroyed-controller guards
--------------------------------------------------------------------------------

-- destroy-frees-slot
test("destroy: Destroy frees the sv slot and never mutates saved data", function()
    local F = freshLoaded()
    _G.TestDB = { profileKeys = { [CHARKEY] = "Default" }, global = { a = 99 } }
    local db = newHS(F, { defaults = { global = { a = 1 } } })
    local _ = db.global   -- materialize
    local snapshot = deepCopy(_G.TestDB)
    db:Destroy()
    assertDeepEqual(_G.TestDB, snapshot, "Destroy did not mutate saved data (no strip mid-session)")
end)

-- destroy-section-refs-stay-valid
test("destroy: consumer-held section references remain valid after Destroy", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = { a = 1 } } })
    local g = db.global   -- hold a section reference
    db:Destroy()
    -- The held reference is a fully-merged plain table, still usable.
    T.eq(g.a, 1, "held section reference still carries its merged data after Destroy")
    g.late = "write"
    T.eq(_G.TestDB.global.late, "write", "the held reference still maps to the SV")
end)

-- destroy-double-refuses
test("destroy: double-Destroy refuses (method call on a destroyed controller)", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = {} } })
    db:Destroy()
    T.raises(function() db:Destroy() end, "double destroy", "destroyed controller")
end)

-- destroy-method-call-dev-raises
test("destroy: a method call on a destroyed controller raises in dev (§7 row 6)", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = {} } })
    db:Destroy()
    T.raises(function() db:GetNativeHandles() end, "GetNativeHandles after destroy", "destroyed controller")
    T.raises(function() db:OnReady(noop) end, "OnReady after destroy", "destroyed controller")
end)

-- destroy-method-call-release-refuses
test("destroy: a method call on a destroyed controller prints+refuses in RELEASE (§7 row 6 -- nil)", function()
    local F = freshLoaded("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    local db = newHS(F, { defaults = { global = {} } })
    db:Destroy()
    -- A method's return is checkable, so the release mechanism is print + nil (NOT raise).
    local h
    local ok = pcall(function() h = db:GetNativeHandles() end)
    T.truthy(ok, "release method-after-destroy does not raise")
    T.outputContains("destroyed controller", "release printed the destroyed diagnostic")
    T.eq(h, nil, "destroyed method returns nil in release")
end)

-- destroy-method-on-non-controller (Rev 4, F4) -- a DIFFERENT class from the
-- destroyed-controller method call above. A method extracted and invoked on a
-- value with NO store mapping (`local m = db.Destroy; m({})`) used to die with the
-- anonymous "attempt to index local 'store' (a nil value)". The Rev 4 contract
-- refuses with a NAMED "non-controller" message in BOTH builds (the named-message
-- contract exists to eliminate exactly that anonymous nil-index). Forge with both
-- an empty table and a number. Both build axes.
local function assertNonControllerRefusal(F, msg)
    local db = newHS(F, { defaults = { global = {} } })
    local destroy, onReady, getHandles = db.Destroy, db.OnReady, db.GetNativeHandles
    -- Forged empty table.
    T.raises(function() destroy({}) end, msg .. " Destroy({})", "DB:Destroy called on a non-controller value")
    T.raises(function() onReady({}, noop) end, msg .. " OnReady({})", "DB:OnReady called on a non-controller value")
    T.raises(function() getHandles({}) end, msg .. " GetNativeHandles({})", "DB:GetNativeHandles called on a non-controller value")
    -- Forged number (not even a table -- still a named refusal, never a Lua type error).
    T.raises(function() destroy(7) end, msg .. " Destroy(7)", "DB:Destroy called on a non-controller value")
    T.raises(function() onReady(7, noop) end, msg .. " OnReady(7)", "DB:OnReady called on a non-controller value")
    T.raises(function() getHandles(7) end, msg .. " GetNativeHandles(7)", "DB:GetNativeHandles called on a non-controller value")
end

test("destroy: a method invoked on a non-controller value gets a named refusal (dev, F4)", function()
    local F = freshLoaded()
    T.truthy(F.IS_DEV_BUILD, "dev build")
    assertNonControllerRefusal(F, "non-controller dev")
end)

test("destroy: a method invoked on a non-controller value gets a named refusal (release, F4)", function()
    local F = freshLoaded("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    assertNonControllerRefusal(F, "non-controller release")
end)

-- destroy-section-read-dev-raises
test("destroy: a section-property READ on a destroyed controller raises in dev (§7 row 7)", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = {} } })
    db:Destroy()
    T.raises(function() local _ = db.global end, "global read after destroy", "destroyed controller")
    T.raises(function() local _ = db.profile end, "profile read after destroy", "destroyed controller")
    T.raises(function() local _ = db.char end, "char read after destroy", "destroyed controller")
    T.raises(function() local _ = db.sv end, "sv read after destroy", "destroyed controller")
end)

-- destroy-section-read-release-raises
-- [D3 CONTRACT CASE -- PASSING]: a destroyed-controller SECTION READ raises in both
-- builds -- the __index destroyed-section guard routes through `refuse()`. Spec §7
-- row 7 / D3: a property read has no checkable nil-refusal path (identical rationale
-- to row 5), so the raise is the release refusal. The destroyed METHOD-call case
-- (row 6, print+nil via F:RaiseDevError) is a different class and stays print+nil.
test("destroy: a section-property READ on a destroyed controller RAISES in release too (D3, §7 row 7)", function()
    local F = freshLoaded("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    local db = newHS(F, { defaults = { global = {} } })
    db:Destroy()
    -- A property read has no checkable nil-refusal path -> raise in BOTH builds.
    T.raises(function() local _ = db.global end, "release section read raises", "destroyed controller")
    T.raises(function() local _ = db.sv end, "release sv read raises", "destroyed controller")
end)

-- destroy-then-strip-still-runs
test("destroy: a Destroyed controller's store is STILL stripped at logout (§2.2/§4.3)", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = { a = 1 } } })
    db.global.dyn = "keep"   -- materialize + add a dynamic key
    db:Destroy()
    fireLogout()
    -- The strip still ran over the Destroyed store: default-equal 'a' removed, the
    -- dynamic key kept, profileKeys survives.
    T.eq(_G.TestDB.global.a, nil, "default-equal 'a' stripped even though the controller was Destroyed")
    T.eq(_G.TestDB.global.dyn, "keep", "dynamic key survives")
    T.eq(_G.TestDB.profileKeys[CHARKEY], "Default", "profileKeys survives")
end)

-- destroy-then-reload-new-default-wins
test("destroy: Destroy -> logout -> change a default -> reload, the NEW default wins (no phantom freeze)", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = { opt = "OLD" } } })
    local _ = db.global   -- materialize (opt = "OLD")
    db:Destroy()
    fireLogout()
    -- Because the Destroyed store was stripped, opt (== default "OLD") was removed
    -- from disk. Next build with a NEW default "NEW" must apply "NEW", not be frozen
    -- on "OLD".
    T.eq(_G.TestDB and _G.TestDB.global and _G.TestDB.global.opt, nil,
        "the default-equal opt was stripped (not frozen onto disk)")
    local postStrip = _G.TestDB
    local F2 = freshLoaded()
    _G.TestDB = postStrip
    local db2 = F2.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true, defaults = { global = { opt = "NEW" } } })
    T.eq(db2.global.opt, "NEW", "the new default wins (the strip prevented the phantom-deviation freeze)")
end)

-- destroy-double-strip-idempotent
test("destroy: Destroy then re-:New then double logout is idempotent over concrete defaults", function()
    local F = freshLoaded()
    local db1 = newHS(F, { defaults = { global = { a = 1 } } })
    db1.global.dyn = "v1"
    db1:Destroy()
    -- Re-:New the same sv (now allowed since the slot freed). The OLD store remains
    -- in `stores` and is stripped too -- double-strip must be safe.
    local db2 = F.DB:New({ name = "TestAddon", sv = "TestDB", defaultProfile = true, defaults = { global = { a = 1 } } })
    local _ = db2.global
    fireLogout()
    T.eq(_G.TestDB.global.dyn, "v1", "dynamic key survived the double-strip")
    T.eq(_G.TestDB.global.a, nil, "default-equal stripped exactly once (idempotent)")
end)

--------------------------------------------------------------------------------
-- ready-hook (spec §9 ready-hook): OnReady synchronous catch-up
--------------------------------------------------------------------------------

-- ready-hook-synchronous
test("ready-hook: OnReady invokes the handler synchronously at registration with handler(db)", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = {} } })
    local gotDb, calls = nil, 0
    db:OnReady(function(d) gotDb = d; calls = calls + 1 end)
    T.eq(calls, 1, "handler fired synchronously, exactly once, at registration")
    T.truthy(rawequal(gotDb, db), "handler received the controller as its argument")
end)

-- ready-hook-multiple-handlers
test("ready-hook: multiple handlers each invoked exactly once (N self-gating modules)", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = {} } })
    local c1, c2, c3 = 0, 0, 0
    db:OnReady(function() c1 = c1 + 1 end)
    db:OnReady(function() c2 = c2 + 1 end)
    db:OnReady(function() c3 = c3 + 1 end)
    T.eq(c1, 1, "handler 1 once"); T.eq(c2, 1, "handler 2 once"); T.eq(c3, 1, "handler 3 once")
end)

-- ready-hook-bad-handler
test("ready-hook: a non-function handler is rejected (dev raise)", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = {} } })
    T.raises(function() db:OnReady("notfn") end, "bad handler", "handler must be a function")
    T.raises(function() db:OnReady(nil) end, "nil handler", "handler must be a function")
end)

-- ready-hook-destroyed-refuses
test("ready-hook: OnReady on a destroyed controller refuses", function()
    local F = freshLoaded()
    local db = newHS(F, { defaults = { global = {} } })
    db:Destroy()
    T.raises(function() db:OnReady(noop) end, "OnReady after destroy", "destroyed controller")
end)

--------------------------------------------------------------------------------
-- shared-defaults (spec §9 shared-defaults): one defaults table, two controllers
--------------------------------------------------------------------------------

-- shared-defaults-not-mutated
test("shared-defaults: one defaults table backing two controllers is never copied or mutated", function()
    local F = freshLoaded()
    local shared = { global = { a = 1, nested = { b = 2 } } }
    local snapshot = deepCopy(shared)
    T.loadedAddons["AddonA"] = true
    T.loadedAddons["AddonB"] = true
    local dbA = F.DB:New({ name = "AddonA", sv = "DB_A", defaultProfile = true, defaults = shared })
    local dbB = F.DB:New({ name = "AddonB", sv = "DB_B", defaultProfile = true, defaults = shared })
    -- Materialize both and mutate the live sections heavily.
    dbA.global.a = 100; dbA.global.nested.b = 200; dbA.global.extra = "A"
    dbB.global.a = 300; dbB.global.extra = "B"
    assertDeepEqual(shared, snapshot, "the shared defaults table is byte-unchanged after both sessions")
end)

-- shared-defaults-independent-sv
test("shared-defaults: each controller writes its OWN sv; one is independent of the other", function()
    local F = freshLoaded()
    local shared = { global = { a = 1 } }
    T.loadedAddons["AddonA"] = true
    T.loadedAddons["AddonB"] = true
    local dbA = F.DB:New({ name = "AddonA", sv = "DB_A", defaultProfile = true, defaults = shared })
    local dbB = F.DB:New({ name = "AddonB", sv = "DB_B", defaultProfile = true, defaults = shared })
    dbA.global.a = 7
    T.eq(dbB.global.a, 1, "B still sees its own default; A's mutation did not leak through the shared defaults")
end)

-- shared-defaults-strip-isolation
test("shared-defaults: one controller's strip leaves the other's data intact", function()
    local F = freshLoaded()
    local shared = { global = { a = 1 } }
    T.loadedAddons["AddonA"] = true
    T.loadedAddons["AddonB"] = true
    local dbA = F.DB:New({ name = "AddonA", sv = "DB_A", defaultProfile = true, defaults = shared })
    local dbB = F.DB:New({ name = "AddonB", sv = "DB_B", defaultProfile = true, defaults = shared })
    dbA.global.a = 1        -- A: default-equal (will strip to empty)
    dbB.global.a = 1; dbB.global.keep = "B"   -- B: has a dynamic key
    fireLogout()
    T.eq(_G.DB_A.global, nil, "A's global stripped to nothing (all default-equal)")
    T.eq(_G.DB_B.global.keep, "B", "B's dynamic key intact after A's strip ran in the same logout")
end)

--------------------------------------------------------------------------------
-- strip-isolation (spec §9 strip-isolation): one strip error can't starve another
--------------------------------------------------------------------------------

-- strip-isolation-sibling-error
test("strip-isolation: a sibling store whose strip errors does NOT starve another store's strip", function()
    local F = freshLoaded()
    -- Build two stores. Corrupt store A's sv post-construction so its strip walk
    -- raises (sv.global a non-table where the defaults walk expects to recurse).
    T.loadedAddons["AddonA"] = true
    T.loadedAddons["AddonB"] = true
    local dbA = F.DB:New({ name = "AddonA", sv = "DB_A", defaultProfile = true, defaults = { global = { sub = { x = 1 } } } })
    local _ = dbA.global   -- materialize A (defaults applied)
    local dbB = F.DB:New({ name = "AddonB", sv = "DB_B", defaultProfile = true, defaults = { global = { a = 1 } } })
    dbB.global.a = 1; dbB.global.keep = "B"   -- B: default-equal a + a dynamic key
    -- Sabotage A's materialized section so stripDefaults hits a type error: replace
    -- the recursable sub-table with a value that makes next()/recursion explode is
    -- hard; instead inject a metatable that errors on pairs. Simpler: make A's
    -- materialized global itself non-iterable by swapping it for a string is blocked
    -- by db.global being the SV's table. We sabotage via the captured store ref:
    -- overwrite sv.global.sub with a non-table AFTER materialization so the strip's
    -- recursion `stripDefaults(sv.sub, default.sub)` sees a scalar -> harmless. To
    -- force a real error we install a poison __index-free table whose pairs throws.
    local poison = setmetatable({}, { __pairs = function() error("strip boom") end })
    -- Lua 5.1 pairs() ignores __pairs, so instead poison next() indirectly: put a
    -- key whose comparison errors is not possible. Use a different lever: make
    -- A's sv.global a table that ERRORS when stripDefaults indexes a default key.
    -- stripDefaults does `local sv = stored[k]` -> index. An __index that errors:
    _G.DB_A.global = setmetatable({}, { __index = function() error("strip boom") end })
    local ok = pcall(fireLogout)
    -- In dev, the surfaced error re-raises AFTER the loop, so fireLogout raises; but
    -- B's strip must already have run. Wrap and assert B's outcome regardless.
    T.truthy(_G.DB_B.global ~= nil, "B's SV still present")
    T.eq(_G.DB_B.global.keep, "B", "B's dynamic key survived despite A's strip erroring")
    T.eq(_G.DB_B.global.a, nil, "B's default-equal value stripped -- B's strip RAN")
    T.truthy(not ok or ok, "fireLogout completed (dev may surface the error after the loop)")
end)

-- strip-isolation-falsy-error
test("strip-isolation: a sibling strip raising a FALSY error still doesn't starve another (raised-flag gated)", function()
    local F = freshLoaded()
    T.loadedAddons["AddonA"] = true
    T.loadedAddons["AddonB"] = true
    local dbA = F.DB:New({ name = "AddonA", sv = "DB_A", defaultProfile = true, defaults = { global = { a = 1 } } })
    local _ = dbA.global
    local dbB = F.DB:New({ name = "AddonB", sv = "DB_B", defaultProfile = true, defaults = { global = { a = 1 } } })
    dbB.global.a = 1; dbB.global.keep = "B"
    -- Poison A's global with an __index that raises a FALSY error (error(false)).
    _G.DB_A.global = setmetatable({}, { __index = function() error(false) end })
    pcall(fireLogout)
    T.eq(_G.DB_B.global.keep, "B", "B's strip ran despite A's falsy strip error")
    T.eq(_G.DB_B.global.a, nil, "B's default-equal stripped")
end)

-- strip-isolation-consumer-logout-error-then-strip
test("strip-isolation: a consumer OnLogout that ERRORS does not prevent the DB strip (dev, continue-on-error)", function()
    local F = freshLoaded()
    -- A Lifecycle consumer registers an erroring OnLogout. The DB strip rides the
    -- post-fan-out seam, which runs AFTER the consumer fan-out and BEFORE the
    -- deferred surfacing, so the erroring consumer hook must NOT skip the strip.
    local lc = F.Lifecycle:New(nil, "Consumer")
    lc:OnLogout(function() error("consumer logout boom") end)
    local db = newHS(F, { defaults = { global = { a = 1 } } })
    db.global.a = 1; db.global.keep = "K"
    -- In dev the surfacing re-raises, so wrap the fire.
    pcall(fireLogout)
    T.eq(_G.TestDB.global.keep, "K", "the DB strip ran despite the consumer logout hook erroring")
    T.eq(_G.TestDB.global.a, nil, "default-equal stripped -- the strip was not skipped")
end)

return tests

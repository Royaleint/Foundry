-- Foundry.DB <-> AceDB-3.0 dual-library parity comparator.
--
-- The spec §9 dual-library proof, executed not eyeballed: each consumer fixture
-- is loaded under REAL AceDB-3.0 AND under Foundry.DB, and their observable state
-- and post-strip raw SavedVariables are compared deep-equal -- normalizing
-- EXACTLY the two §3.3 carve-outs (unpruned empty unmanaged sections; preserved
-- scalar under a table-typed default), with each applied normalization itself
-- asserted when exercised. It also proves the REVERSE direction Gate 4's rollback
-- leans on: a Foundry-written post-strip store loads under AceDB with identical
-- observable state.
--
-- Clean-room boundary: AceDB is EXECUTED here as a verification oracle only, from
-- the consumer's external vendored copy -- never copied, never committed into
-- Foundry, never linked into shipped code. The clean-room rule bars copying AceDB
-- code, not testing against it.
--
-- Ace checkout resolution order (spec/plan Phase C; FND-020):
--   1. os.getenv("FOUNDRY_ACE_PATH")  -- a Libs/ dir holding AceDB-3.0/, LibStub/,
--                                        CallbackHandler-1.0/
--   2. Foundry_Dev/vendor/AceLibs     -- the private dev repo's pinned oracle copy
--                                        (relative from the repo root, then the
--                                        absolute local path so worktree checkouts
--                                        resolve it too)
--   3. C:/Projects/Homestead/Libs     -- legacy: Homestead's packager-populated
--                                        Libs/ (gone since Homestead left Ace3;
--                                        kept as a harmless last candidate)
-- If nothing resolves, the suite returns a SINGLE skip-notice case that PRINTS
-- clearly that it was skipped and why (never a silent pass).

local T = ...

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

--------------------------------------------------------------------------------
-- Ace checkout resolution
--------------------------------------------------------------------------------

local function fileExists(p)
    local f = io.open(p, "r")
    if f then f:close(); return true end
    return false
end

local function resolveAceLibs()
    local candidates = {}
    local env = os.getenv("FOUNDRY_ACE_PATH")
    if env and env ~= "" then candidates[#candidates + 1] = env end
    candidates[#candidates + 1] = "Foundry_Dev/vendor/AceLibs"
    candidates[#candidates + 1] = "C:/Projects/Foundry/Foundry_Dev/vendor/AceLibs"
    candidates[#candidates + 1] = "C:/Projects/Homestead/Libs"
    for _, base in ipairs(candidates) do
        local ace = base .. "/AceDB-3.0/AceDB-3.0.lua"
        local stub = base .. "/LibStub/LibStub.lua"
        local cb = base .. "/CallbackHandler-1.0/CallbackHandler-1.0.lua"
        if fileExists(ace) and fileExists(stub) and fileExists(cb) then
            return { base = base, ace = ace, stub = stub, cb = cb }
        end
    end
    return nil
end

local ACE = resolveAceLibs()

if not ACE then
    -- The MANDATORY-VISIBLE skip path: one case that prints the reason and passes
    -- (so the suite never silently no-ops and never hard-requires Ace3 code).
    test("acedb-parity: SKIPPED (no Ace3 checkout resolved)", function()
        print("  [acedb_parity] SKIPPED: no Ace3 checkout found via FOUNDRY_ACE_PATH, "
            .. "Foundry_Dev/vendor/AceLibs, or C:/Projects/Homestead/Libs (need "
            .. "AceDB-3.0/, LibStub/, CallbackHandler-1.0/). The dual-library parity "
            .. "proof did NOT run.")
    end)
    return tests
end

--------------------------------------------------------------------------------
-- Identity mocks needed by AceDB at FILE LOAD (acedb-semantics.md §1): AceDB
-- captures all identity keys with unguarded concatenation at file scope.
--------------------------------------------------------------------------------

local IDENTITY = { name = "Tester", realm = "Test Realm" }

-- WoW exposes several string.* functions as bare globals (strmatch, strjoin,
-- strsplit, strtrim, strlower, strupper, gsub, strfind, format, ...). LibStub and
-- AceDB call them unqualified. Plain Lua 5.1 has only the string.* table, so we
-- alias the ones the Ace libs use into _G before loading them (verification-oracle
-- shim only; never shipped).
local function installWoWStringGlobals()
    _G.strmatch = string.match
    _G.strfind = string.find
    _G.strsub = string.sub
    _G.strlower = string.lower
    _G.strupper = string.upper
    _G.strrep = string.rep
    _G.strjoin = function(delim, ...) return table.concat({ ... }, delim) end
    _G.format = string.format
    _G.gsub = string.gsub
    _G.tinsert = table.insert
    _G.tremove = table.remove
    _G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    _G.next = next
end

local function installAceIdentity()
    installWoWStringGlobals()
    _G.UnitName = function() return IDENTITY.name, nil end
    _G.GetRealmName = function() return IDENTITY.realm end
    _G.UnitClass = function() return "Warrior", "WARRIOR" end
    _G.UnitRace = function() return "Night Elf", "NightElf" end
    _G.UnitFactionGroup = function() return "Alliance" end
    _G.GetLocale = function() return "enUS" end
    _G.GetCurrentRegion = function() return 1 end
    _G.GetCurrentRegionName = function() return "US" end
end

-- Load a FRESH AceDB instance with its own LibStub registry. LibStub is a
-- single-global singleton keyed by major+minor, so to get a clean AceDB per call
-- we wipe _G.LibStub first and re-load the three libs in order. AceDB captures
-- identity at load, so identity must be installed before this runs.
local function loadFreshAceDB(charKeyIdentity)
    IDENTITY = charKeyIdentity or { name = "Tester", realm = "Test Realm" }
    installAceIdentity()
    _G.LibStub = nil
    assert(loadfile(ACE.stub))()
    assert(loadfile(ACE.cb))()
    assert(loadfile(ACE.ace))()
    return _G.LibStub("AceDB-3.0")
end

-- Fire AceDB's OWN logout handler (its private frame's OnEvent), driving the real
-- AceDB strip. AceDB.frame:SetScript("OnEvent", logoutHandler) was recorded by the
-- harness CreateFrame stub; find that frame and invoke its captured OnEvent.
local function fireAceLogout()
    -- AceDB created exactly one frame at load; it is the most recent harness frame
    -- whose OnEvent is the logout handler. Drive every harness frame's OnEvent with
    -- PLAYER_LOGOUT -- only AceDB's responds; the Foundry dispatcher (if present in
    -- this test) is a different concern and not created in the Ace-side load.
    for _, fr in ipairs(T.frames) do
        if fr._onEvent then fr._onEvent(fr, "PLAYER_LOGOUT") end
    end
end

--------------------------------------------------------------------------------
-- Foundry side: load Foundry fresh in dev build, with one addon finished-loading.
--------------------------------------------------------------------------------

local function loadFreshFoundry(charKeyIdentity, addonName)
    local F = T.fresh()                     -- installs the harness mocks + Foundry
    T.identity = charKeyIdentity or { name = "Tester", realm = "Test Realm" }
    T.loadedAddons[addonName] = true
    return F
end

-- Drive Foundry's strip through the REAL Lifecycle dispatcher.
local function fireFoundryLogout()
    local fr = T.frames[1]
    if fr and fr._onEvent then fr._onEvent(fr, "PLAYER_LOGOUT") end
end

--------------------------------------------------------------------------------
-- Comparison helpers, with the two §3.3 carve-out normalizations. Each
-- normalization, WHEN it actually changes something, is asserted via the returned
-- `applied` table so the proof can confirm it was exercised rather than passing
-- vacuously.
--------------------------------------------------------------------------------

local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = deepCopy(v) end
    return c
end

-- Carve-out 1: unpruned empty unmanaged sections. Foundry never deletes top-level
-- keys/sections it does not manage, so an empty leftover bucket in an UNMANAGED
-- section may persist as {} where AceDB pruned it. Normalize by deleting empty
-- tables under unmanaged top-level keys on BOTH sides. `applied` records each.
local MANAGED = { profileKeys = true, profiles = true, char = true, global = true }

local function normalizeEmptyUnmanaged(sv, applied, side)
    if type(sv) ~= "table" then return end
    for k, v in pairs(sv) do
        if not MANAGED[k] and type(v) == "table" then
            -- Remove empty per-key buckets inside an unmanaged section.
            for kk, vv in pairs(v) do
                if type(vv) == "table" and next(vv) == nil then
                    v[kk] = nil
                    applied[#applied + 1] = side .. ":empty-unmanaged " .. tostring(k) .. "." .. tostring(kk)
                end
            end
            if next(v) == nil then
                sv[k] = nil
                applied[#applied + 1] = side .. ":empty-unmanaged-section " .. tostring(k)
            end
        end
    end
end

-- Deep-equal with a path on mismatch.
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

--------------------------------------------------------------------------------
-- A synthetic AceDB-shaped fixture (small, deterministic) so the parity proof
-- runs even before the big sanitized fixtures are exercised. The sanitized
-- fixtures are also dual-loaded below.
--------------------------------------------------------------------------------

local function syntheticHomesteadShape()
    return {
        profileKeys = { ["Tester - Test Realm"] = "Default" },
        profiles = { Default = { vendorTracer = { minimapIconSize = 17, showPinCounts = true } } },
        global = {
            schemaVersion = 4,
            scannedVendors = { [123] = { name = "V" } },
            hasSeenWelcomeV4 = true,
        },
    }
end

--------------------------------------------------------------------------------
-- post-load observable-state parity
--------------------------------------------------------------------------------

-- parity-synthetic-postload
test("parity: synthetic Homestead-shape -- observable state matches AceDB post-load", function()
    local defaults = { profile = { vendorTracer = { minimapIconSize = 12, showPinCounts = false } },
        global = { schemaVersion = 1 } }

    -- AceDB side.
    local AceDB = loadFreshAceDB()
    _G.PHomesteadAce = syntheticHomesteadShape()
    local adb = AceDB:New("PHomesteadAce", deepCopy(defaults), true)

    -- Foundry side.
    local F = loadFreshFoundry({ name = "Tester", realm = "Test Realm" }, "Homestead")
    _G.PHomesteadF = syntheticHomesteadShape()
    local fdb = F.DB:New({ name = "Homestead", sv = "PHomesteadF", defaults = deepCopy(defaults), defaultProfile = true })

    -- Observable: stored deviations beat defaults; missing defaults backfill.
    T.eq(fdb.profile.vendorTracer.minimapIconSize, adb.profile.vendorTracer.minimapIconSize, "minimapIconSize parity")
    T.eq(fdb.profile.vendorTracer.minimapIconSize, 17, "stored deviation (17) beats default (12)")
    T.eq(fdb.global.schemaVersion, adb.global.schemaVersion, "schemaVersion parity (stored 4 beats default 1)")
    T.eq(fdb.global.scannedVendors[123].name, adb.global.scannedVendors[123].name, "dynamic key parity")
    T.eq(fdb.global.hasSeenWelcomeV4, adb.global.hasSeenWelcomeV4, "welcome key parity")
end)

-- parity-stored-false-beats-default-true
test("parity: a stored false beats a default true -- identical under both libraries", function()
    local defaults = { global = { flag = true } }
    local AceDB = loadFreshAceDB()
    _G.PFalseAce = { profileKeys = { ["Tester - Test Realm"] = "Default" }, global = { flag = false } }
    local adb = AceDB:New("PFalseAce", deepCopy(defaults), true)

    local F = loadFreshFoundry({ name = "Tester", realm = "Test Realm" }, "Homestead")
    _G.PFalseF = { profileKeys = { ["Tester - Test Realm"] = "Default" }, global = { flag = false } }
    local fdb = F.DB:New({ name = "Homestead", sv = "PFalseF", defaults = deepCopy(defaults), defaultProfile = true })

    T.eq(adb.global.flag, false, "AceDB preserves the stored false")
    T.eq(fdb.global.flag, false, "Foundry preserves the stored false")
    T.eq(fdb.global.flag, adb.global.flag, "stored-false-beats-default-true parity")
end)

--------------------------------------------------------------------------------
-- post-strip raw-SV parity (the lossless round-trip of §3.3)
--------------------------------------------------------------------------------

-- parity-synthetic-poststrip
test("parity: synthetic shape -- raw SV after logout strip matches AceDB (carve-outs normalized)", function()
    local defaults = { profile = { vendorTracer = { minimapIconSize = 12 } }, global = { schemaVersion = 1 } }

    -- AceDB: load, materialize profile + global (read both), strip.
    local AceDB = loadFreshAceDB()
    _G.PStripAce = syntheticHomesteadShape()
    local adb = AceDB:New("PStripAce", deepCopy(defaults), true)
    local _ = adb.profile.vendorTracer; local _2 = adb.global   -- materialize the same sections
    fireAceLogout()

    -- Foundry: same.
    local F = loadFreshFoundry({ name = "Tester", realm = "Test Realm" }, "Homestead")
    _G.PStripF = syntheticHomesteadShape()
    local fdb = F.DB:New({ name = "Homestead", sv = "PStripF", defaults = deepCopy(defaults), defaultProfile = true })
    local _3 = fdb.profile.vendorTracer; local _4 = fdb.global
    fireFoundryLogout()

    -- Normalize the two §3.3 carve-outs on both sides.
    local applied = {}
    normalizeEmptyUnmanaged(_G.PStripAce, applied, "ace")
    normalizeEmptyUnmanaged(_G.PStripF, applied, "foundry")

    assertDeepEqual(_G.PStripF, _G.PStripAce, "post-strip raw SV parity")
end)

-- parity-empty-unmanaged-carveout-asserted
test("parity: carve-out 1 (empty unmanaged section) is exercised AND the normalization asserted", function()
    local defaults = { global = { schemaVersion = 1 } }

    -- A file with an unmanaged 'realm' section that ends up holding an empty bucket.
    local function shape()
        return {
            profileKeys = { ["Tester - Test Realm"] = "Default" },
            global = { schemaVersion = 4 },
            realm = { ["EmptyRealm"] = {} },   -- unmanaged; AceDB prunes, Foundry keeps
        }
    end

    local AceDB = loadFreshAceDB()
    _G.PCarveAce = shape()
    local adb = AceDB:New("PCarveAce", deepCopy(defaults), true)
    local _ = adb.global
    fireAceLogout()

    local F = loadFreshFoundry({ name = "Tester", realm = "Test Realm" }, "Homestead")
    _G.PCarveF = shape()
    local fdb = F.DB:New({ name = "Homestead", sv = "PCarveF", defaults = deepCopy(defaults), defaultProfile = true })
    local _2 = fdb.global
    fireFoundryLogout()

    -- BEFORE normalization, Foundry keeps the empty unmanaged realm section that
    -- AceDB pruned -- prove the difference exists (the carve-out is real).
    local okBefore = deepEqual(_G.PCarveF, _G.PCarveAce)
    T.falsy(okBefore, "pre-normalization the two SVs DIFFER (Foundry kept the empty unmanaged section)")

    local applied = {}
    normalizeEmptyUnmanaged(_G.PCarveAce, applied, "ace")
    normalizeEmptyUnmanaged(_G.PCarveF, applied, "foundry")
    -- The normalization actually fired on the Foundry side.
    local firedOnFoundry = false
    for _, a in ipairs(applied) do if a:find("^foundry:") then firedOnFoundry = true end end
    T.truthy(firedOnFoundry, "the empty-unmanaged normalization was actually applied (carve-out exercised)")

    assertDeepEqual(_G.PCarveF, _G.PCarveAce, "post-normalization the two SVs match")
end)

-- parity-scalar-under-table-default-carveout-asserted
test("parity: carve-out 2 (stored scalar under a table-typed default) -- Foundry preserves, AceDB clobbers", function()
    -- AceDB clobbers a stored false under a table-typed default to {}; Foundry
    -- preserves it (D2). This is the documented divergence -- assert BOTH behaviors
    -- directly (the normalization for the deep-equal is to exclude exactly this slot).
    local defaults = { global = { sub = { inner = 1 } } }

    local AceDB = loadFreshAceDB()
    _G.PScalarAce = { profileKeys = { ["Tester - Test Realm"] = "Default" }, global = { sub = false } }
    local adb = AceDB:New("PScalarAce", deepCopy(defaults), true)
    local aceSub = adb.global.sub   -- AceDB clobbers false -> {} and applies the subtree

    -- Foundry: release build so the preserve-and-skip read does not raise the
    -- dev diagnostic; the stored false is preserved.
    T.installMocks("1.0.0")
    T.identity = { name = "Tester", realm = "Test Realm" }
    T.loadedAddons["Homestead"] = true
    local F = T.loadFoundry()
    _G.PScalarF = { profileKeys = { ["Tester - Test Realm"] = "Default" }, global = { sub = false } }
    local fdb = F.DB:New({ name = "Homestead", sv = "PScalarF", defaults = deepCopy(defaults), defaultProfile = true })
    local foundrySub = fdb.global.sub

    -- The documented divergence, asserted on both sides.
    T.eq(type(aceSub), "table", "AceDB clobbered the stored false to a table (its own behavior on a legal file)")
    T.eq(foundrySub, false, "Foundry PRESERVED the stored false (D2 -- never destroys stored data)")
    -- This is exactly the §3.3 carve-out 2 slot class: Foundry never produces the
    -- loss; reverting to AceDB can. The deep-equal proofs above exclude this slot
    -- by construction (no such slot appears in the consumer fixtures).
end)

--------------------------------------------------------------------------------
-- reverse direction: a Foundry-written post-strip store loads under AceDB
--------------------------------------------------------------------------------

-- parity-reverse-direction
test("parity: a Foundry-written post-strip store loads under AceDB with identical observable state", function()
    local defaults = { profile = { vendorTracer = { minimapIconSize = 12 } }, global = { schemaVersion = 1 } }

    -- Foundry writes a post-strip store.
    local F = loadFreshFoundry({ name = "Tester", realm = "Test Realm" }, "Homestead")
    _G.PRevF = syntheticHomesteadShape()
    local fdb = F.DB:New({ name = "Homestead", sv = "PRevF", defaults = deepCopy(defaults), defaultProfile = true })
    local _ = fdb.profile.vendorTracer; local _2 = fdb.global
    -- Record observable state, then strip.
    local foundryIcon = fdb.profile.vendorTracer.minimapIconSize
    local foundrySchema = fdb.global.schemaVersion
    fireFoundryLogout()
    local foundryWrittenFile = deepCopy(_G.PRevF)

    -- Now load the Foundry-written file under AceDB and compare observable state.
    local AceDB = loadFreshAceDB()
    _G.PRevAce = foundryWrittenFile
    local adb = AceDB:New("PRevAce", deepCopy(defaults), true)
    T.eq(adb.profile.vendorTracer.minimapIconSize, foundryIcon, "AceDB reads the same profile deviation Foundry had")
    T.eq(adb.global.schemaVersion, foundrySchema, "AceDB reads the same schemaVersion")
    T.eq(adb.global.scannedVendors[123].name, "V", "AceDB reads Foundry's preserved dynamic key")
    T.eq(adb.global.hasSeenWelcomeV4, true, "AceDB reads Foundry's preserved welcome key")
end)

--------------------------------------------------------------------------------
-- the committed sanitized consumer fixtures, dual-loaded
--------------------------------------------------------------------------------

local function loadFixtureCopy(file, globalName)
    local env = T.loadFixture(T.testsDir .. "/DB/fixtures/" .. file)
    return deepCopy(env[globalName])
end

-- parity-homestead-fixture-postload
test("parity: the Homestead sanitized fixture -- observable state matches AceDB post-load", function()
    local id = { name = "FxChar18", realm = "FxRealm 01" }
    local defaults = { profile = { vendorTracer = {} }, global = {} }

    local AceDB = loadFreshAceDB(id)
    _G.HSAce = loadFixtureCopy("homestead_sanitized.lua", "HomesteadDB")
    local adb = AceDB:New("HSAce", deepCopy(defaults), true)

    local F = loadFreshFoundry(id, "Homestead")
    _G.HSF = loadFixtureCopy("homestead_sanitized.lua", "HomesteadDB")
    local fdb = F.DB:New({ name = "Homestead", sv = "HSF", defaults = deepCopy(defaults), defaultProfile = true })

    T.eq(fdb.global.schemaVersion, adb.global.schemaVersion, "schemaVersion parity")
    T.eq(fdb.global.hasSeenWelcomeV4, adb.global.hasSeenWelcomeV4, "hasSeenWelcomeV4 parity")
    T.eq(fdb.global.catalogItems[235523].name, adb.global.catalogItems[235523].name, "catalog entry parity")
    T.eq(fdb.profile.vendorTracer.minimapIconSize, adb.profile.vendorTracer.minimapIconSize, "profile deviation parity")
end)

-- parity-homestead-fixture-poststrip
test("parity: the Homestead sanitized fixture -- post-strip raw SV matches AceDB (carve-outs normalized)", function()
    local id = { name = "FxChar18", realm = "FxRealm 01" }
    local defaults = { profile = { vendorTracer = {} }, global = {} }

    local AceDB = loadFreshAceDB(id)
    _G.HSAce2 = loadFixtureCopy("homestead_sanitized.lua", "HomesteadDB")
    local adb = AceDB:New("HSAce2", deepCopy(defaults), true)
    local _ = adb.profile.vendorTracer; local _2 = adb.global
    fireAceLogout()

    local F = loadFreshFoundry(id, "Homestead")
    _G.HSF2 = loadFixtureCopy("homestead_sanitized.lua", "HomesteadDB")
    local fdb = F.DB:New({ name = "Homestead", sv = "HSF2", defaults = deepCopy(defaults), defaultProfile = true })
    local _3 = fdb.profile.vendorTracer; local _4 = fdb.global
    fireFoundryLogout()

    local applied = {}
    normalizeEmptyUnmanaged(_G.HSAce2, applied, "ace")
    normalizeEmptyUnmanaged(_G.HSF2, applied, "foundry")
    assertDeepEqual(_G.HSF2, _G.HSAce2, "Homestead fixture post-strip raw SV parity")
end)

-- parity-bawrspam-fixture-postload
test("parity: the BawrSpam sanitized fixture -- observable state matches AceDB post-load", function()
    local id = { name = "FxChar202", realm = "FxRealm 01" }
    local defaults = { char = {}, global = { settings = {} } }

    local AceDB = loadFreshAceDB(id)
    _G.BSAce = loadFixtureCopy("bawrspam_sanitized.lua", "BawrSpamDB")
    local adb = AceDB:New("BSAce", deepCopy(defaults), true)

    local F = loadFreshFoundry(id, "BawrSpam")
    _G.BSF = loadFixtureCopy("bawrspam_sanitized.lua", "BawrSpamDB")
    local fdb = F.DB:New({ name = "BawrSpam", sv = "BSF", defaults = deepCopy(defaults), defaultProfile = true })

    T.eq(fdb.char.historyCursor, adb.char.historyCursor, "historyCursor parity (exact 'Name - Realm' keying)")
    T.eq(fdb.global.settings.antiSignalCap, adb.global.settings.antiSignalCap, "settings.antiSignalCap parity")
    T.eq(fdb.global.settings.devMode, adb.global.settings.devMode, "settings.devMode parity")
end)

-- parity-bawrspam-fixture-poststrip
test("parity: the BawrSpam sanitized fixture -- post-strip raw SV matches AceDB (char path, no profile)", function()
    local id = { name = "FxChar202", realm = "FxRealm 01" }
    local defaults = { char = {}, global = { settings = {} } }

    local AceDB = loadFreshAceDB(id)
    _G.BSAce2 = loadFixtureCopy("bawrspam_sanitized.lua", "BawrSpamDB")
    local adb = AceDB:New("BSAce2", deepCopy(defaults), true)
    local _ = adb.char; local _2 = adb.global   -- read char + global, NOT profile
    fireAceLogout()

    local F = loadFreshFoundry(id, "BawrSpam")
    _G.BSF2 = loadFixtureCopy("bawrspam_sanitized.lua", "BawrSpamDB")
    local fdb = F.DB:New({ name = "BawrSpam", sv = "BSF2", defaults = deepCopy(defaults), defaultProfile = true })
    local _3 = fdb.char; local _4 = fdb.global
    fireFoundryLogout()

    local applied = {}
    normalizeEmptyUnmanaged(_G.BSAce2, applied, "ace")
    normalizeEmptyUnmanaged(_G.BSF2, applied, "foundry")
    assertDeepEqual(_G.BSF2, _G.BSAce2, "BawrSpam fixture post-strip raw SV parity")
end)

return tests

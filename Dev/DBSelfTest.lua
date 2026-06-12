-- Foundry.DB in-game self-test (DEV-ONLY — never ships).
--
-- DB's load-bearing behaviors are unobservable by ordinary play: SavedVariables
-- load/write timing happens once per session, and the defaults strip runs at
-- PLAYER_LOGOUT — after the player can no longer look. This command makes them
-- observable by driving a SYNTHETIC SavedVariables store (never a consumer's
-- real file) through the full lifecycle — create, defaults, writes, a simulated
-- logout strip via the dev-only Lifecycle:_TestFire seam, and a re-init over the
-- stripped store — printing a labelled PASS/FAIL report. It also carries the
-- read-only inspect probe (/foundrydb inspect <SVGlobal>) that Phases D/E use to
-- record pre- and post-migration baselines against real files.
--
-- CAUTION (combined dev sessions): the simulated strip drives PLAYER_LOGOUT
-- through the LIVE shared dispatcher, so it fires the real post-logout strip
-- across EVERY DB store constructed this session and any pending consumer logout
-- hooks — and CONSUMES those hooks: Lifecycle hooks are one-shot with
-- re-registration refused, so a consumer's logout work will silently not run at
-- the real session end after a simulated fire. Before Phases D/E land, only this
-- file's synthetic stores exist and the fire is harmless. AFTER a consumer
-- migrates onto Foundry.DB, running the walk in that consumer's live session
-- strips the consumer's real section tables mid-session (defaults re-apply only
-- at next construction). Run the walk in a dev session, not on a live migrated
-- character.
--
-- TRIPLE-GATED OFF for players:
--   (1) This file is NOT listed in Foundry-1.0.toc, so a packaged release never
--       contains it (the primary gate — exactly like Tests/).
--   (2) Both registration AND every command handler early-return through
--       F:RaiseDevError when not F.IS_DEV_BUILD, so even if the file were force-
--       loaded it refuses in a release build.
--   (3) The commands are registered through a private F.Commands:New controller
--       (/foundrydb — its OWN controller and slash; Commands:New refuses
--       duplicate slashes, so sharing /foundrydev would silently drop whichever
--       Dev file loads second), so no raw SLASH_* global is ever written.

-- The TOC-loaded vararg: DB:New's timing guard gates on
-- C_AddOns.IsAddOnLoaded(config.name)'s SECOND return, so the synthetic config
-- must name the addon this file actually loaded under (the dev working copy's
-- folder name, whatever it is locally).
local ADDON_NAME = ...

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: DBSelfTest.lua requires the Foundry-1.0 bootstrap "
        .. "(Foundry.lua) to have loaded first; _G.Foundry_1_0 is missing.", 0)
end

-- Gate (2a): never even build the commands in a release build.
if not F.IS_DEV_BUILD then
    return
end

--------------------------------------------------------------------------------
-- Report plumbing (the LifecycleSelfTest template)
--------------------------------------------------------------------------------

-- Each run accumulates a fresh report; a check() appends a labelled line and
-- tracks pass/fail counts so the run can print a final summary. Failing checks
-- are prefixed "FAIL:" and the run CONTINUES, so the developer sees the full
-- picture in one pass rather than aborting at the first failure.
local function newReport(out)
    return {
        out = out,
        passed = 0,
        failed = 0,
    }
end

local function check(report, ok, label)
    if ok then
        report.passed = report.passed + 1
        report.out("  ok:   " .. label)
    else
        report.failed = report.failed + 1
        report.out("  FAIL: " .. label)
    end
    return ok
end

-- A per-run counter makes each run's synthetic SV global name unique so a second
-- run never collides with a global a prior run failed to release (defense in
-- depth; the run already cleans up everything it creates). No WoW time global is
-- used, so the file stays luacheck-clean against the Foundry config.
local runSeq = 0
local function nextStamp()
    runSeq = runSeq + 1
    return tostring(runSeq)
end

local function countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Deep structural signature of a value: sorted keys, types, and scalar values,
-- recursively. Two uses, both proofs-by-comparison: the inspect probe wrote
-- NOTHING into the store it read, and the consumer's defaults table was never
-- written into across the full drive. Synthetic data only (acyclic, string
-- keys), so plain recursion is safe.
local function signature(v)
    if type(v) ~= "table" then
        return type(v) .. "=" .. tostring(v)
    end
    local names, byName = {}, {}
    for k, val in pairs(v) do
        local kn = tostring(k)
        names[#names + 1] = kn
        byName[kn] = val
    end
    table.sort(names)
    local parts = {}
    for i = 1, #names do
        parts[#parts + 1] = names[i] .. "{" .. signature(byName[names[i]]) .. "}"
    end
    return table.concat(parts, ",")
end

--------------------------------------------------------------------------------
-- The read-only inspect collector (shared by the probe command and the walk's
-- probe self-check)
--------------------------------------------------------------------------------

-- Collect a report over a raw SavedVariables global. PURE READS: it indexes
-- _G[name] and iterates with pairs(); it never assigns, never constructs a DB
-- controller, and never materializes a section — so it is byte-safe against a
-- live AceDB-managed OR Foundry-managed file (the Phase D/E baseline tool runs
-- on the still-AceDB build first).
local function collectInspect(name)
    local sv = _G[name]
    if sv == nil then
        return { present = false }
    end
    if type(sv) ~= "table" then
        return { present = true, malformedType = type(sv) }
    end

    local r = {
        present = true,
        topLevelCount = countKeys(sv),
        buckets = {},
        others = {},
    }
    if sv.profileKeys ~= nil then
        r.profileKeys = (type(sv.profileKeys) == "table")
            and countKeys(sv.profileKeys) or ("non-table (" .. type(sv.profileKeys) .. ")")
    end
    if sv.global ~= nil then
        r.globalCount = (type(sv.global) == "table")
            and countKeys(sv.global) or ("non-table (" .. type(sv.global) .. ")")
    end
    for _, section in ipairs({ "profiles", "char" }) do
        if type(sv[section]) == "table" then
            local list = {}
            for k, v in pairs(sv[section]) do
                list[#list + 1] = {
                    key = tostring(k),
                    kind = type(v),
                    count = (type(v) == "table") and countKeys(v) or nil,
                }
            end
            table.sort(list, function(a, b) return a.key < b.key end)
            r.buckets[section] = list
        elseif sv[section] ~= nil then
            r.buckets[section] = "non-table (" .. type(sv[section]) .. ")"
        end
    end
    for k, v in pairs(sv) do
        if k ~= "profileKeys" and k ~= "profiles" and k ~= "char" and k ~= "global" then
            r.others[#r.others + 1] = {
                key = tostring(k),
                kind = type(v),
                count = (type(v) == "table") and countKeys(v) or nil,
            }
        end
    end
    table.sort(r.others, function(a, b) return a.key < b.key end)
    return r
end

local function printInspect(name, r, out)
    if not r.present then
        out("Foundry.DB inspect: _G['" .. name .. "'] is not present (nil).")
        return
    end
    if r.malformedType then
        out("Foundry.DB inspect: _G['" .. name .. "'] is a " .. r.malformedType
            .. ", not a table.")
        return
    end
    out("Foundry.DB inspect '" .. name .. "' (read-only):")
    out("  top-level keys: " .. r.topLevelCount)
    out("  profileKeys: " .. (r.profileKeys == nil and "absent"
        or (type(r.profileKeys) == "number" and (r.profileKeys .. " entries") or r.profileKeys)))
    for _, section in ipairs({ "profiles", "char" }) do
        local buckets = r.buckets[section]
        if buckets == nil then
            out("  " .. section .. ": absent")
        elseif type(buckets) == "string" then
            out("  " .. section .. ": " .. buckets)
        else
            out("  " .. section .. ": " .. #buckets .. " bucket(s)")
            for i = 1, #buckets do
                local b = buckets[i]
                if b.count ~= nil then
                    out("    ['" .. b.key .. "']: " .. b.count .. " keys")
                else
                    out("    ['" .. b.key .. "']: " .. b.kind .. " (non-table)")
                end
            end
        end
    end
    out("  global: " .. (r.globalCount == nil and "absent"
        or (type(r.globalCount) == "number" and (r.globalCount .. " keys") or r.globalCount)))
    for i = 1, #r.others do
        local o = r.others[i]
        if o.count ~= nil then
            out("  (unmanaged) " .. o.key .. ": table, " .. o.count .. " keys")
        else
            out("  (unmanaged) " .. o.key .. ": " .. o.kind)
        end
    end
end

--------------------------------------------------------------------------------
-- The main walk: create -> defaults -> writes -> simulated strip -> re-init ->
-- probe self-check, all against a synthetic SV global.
--------------------------------------------------------------------------------

-- A fresh defaults table per construction (DB holds defaults by reference;
-- independent tables keep the two :New calls honest).
local function makeDefaults()
    return {
        profile = { enabled = true, scale = 1.25, nested = { color = "blue" } },
        char = { seen = false },
        global = { counter = 0 },
    }
end

local function runWalk(out)
    local report = newReport(out)
    out("Foundry.DB self-test: create -> defaults -> writes -> strip -> re-init")

    local DB = F.DB
    if not DB then
        out("  FAIL: F.DB module is not present")
        report.failed = report.failed + 1
        return report
    end
    local Lifecycle = F.Lifecycle
    if not Lifecycle then
        out("  FAIL: F.Lifecycle module is not present (the strip seam rides it)")
        report.failed = report.failed + 1
        return report
    end

    local svName = "FoundryDBSelfTest_SV" .. nextStamp()
    if _G[svName] ~= nil then
        out("  FAIL: synthetic global '" .. svName .. "' already exists; aborting")
        report.failed = report.failed + 1
        return report
    end

    local defaults = makeDefaults()
    local defaultsSig = signature(defaults)

    -- 1. Fresh create.
    local okNew, db = pcall(DB.New, DB, {
        name = ADDON_NAME,
        sv = svName,
        defaults = defaults,
        defaultProfile = true,
    })
    if not check(report, okNew and db ~= nil, "New() returned a controller for a fresh SV") then
        out("  (" .. tostring(db) .. ")")
        out(string.format("Summary: %d ok, %d FAIL (aborted: no controller)",
            report.passed, report.failed))
        return report
    end

    local sv = _G[svName]
    check(report, type(sv) == "table", "fresh SavedVariables global was created")

    local handles = db:GetNativeHandles()
    check(report, handles ~= nil and handles.sv == sv,
        "GetNativeHandles returns the live SV root")
    check(report, handles ~= nil and handles.profileKey == "Default",
        "profileKey resolved to 'Default'")
    check(report, handles ~= nil and type(handles.charKey) == "string"
        and type(sv.profileKeys) == "table"
        and sv.profileKeys[handles.charKey] == "Default",
        "profileKeys write-back recorded this character -> 'Default'")

    -- 2. Defaults apply on first section read (materialization).
    check(report, db.profile.enabled == true, "profile default applied (enabled == true)")
    check(report, db.profile.nested.color == "blue", "nested profile default applied")
    check(report, db.char.seen == false, "char default applied (a FALSE default lands as false)")
    check(report, db.global.counter == 0, "global default applied")

    -- 3. Writes: a deviation, a false-over-true flip, a dynamic key.
    db.profile.scale = 2
    db.profile.enabled = false
    db.profile.customKey = 42
    check(report, type(sv.profiles) == "table"
        and type(sv.profiles["Default"]) == "table"
        and sv.profiles["Default"].scale == 2,
        "a section write lands in the live SV table")

    -- 4. One live controller per sv name while this one is alive.
    local okDup, dupErr = pcall(DB.New, DB, {
        name = ADDON_NAME, sv = svName, defaults = makeDefaults(), defaultProfile = true,
    })
    check(report, not okDup
        and tostring(dupErr):find("already has a live controller", 1, true) ~= nil,
        "a second :New for the same sv is refused while a controller is live")

    -- 5. Simulated strip: drive PLAYER_LOGOUT through the live shared dispatcher
    -- (the dev-only seam; valid because the strip transport is LOCKED to the
    -- dispatcher's own OnEvent — under any other transport this would silently
    -- exercise nothing). pcall'd: in a combined dev session another consumer's
    -- logout hook may raise through the dispatcher's deferred surfacing AFTER the
    -- strip has run; the walk notes it and continues so cleanup still happens.
    local okFire, fireErr = pcall(Lifecycle._TestFire, Lifecycle, "logout")
    if not okFire then
        out("  note: the simulated logout surfaced a hook error from another "
            .. "consumer (the strip itself already ran): " .. tostring(fireErr))
    end
    local bucket = type(sv.profiles) == "table" and sv.profiles["Default"] or nil
    check(report, type(bucket) == "table", "profile bucket survived the strip")
    if type(bucket) == "table" then
        check(report, bucket.scale == 2, "deviated value survived the strip")
        check(report, bucket.enabled == false,
            "stored FALSE under a TRUE default survived the strip (nil-vs-false)")
        check(report, bucket.customKey == 42, "dynamic (non-default) key survived the strip")
        check(report, bucket.nested == nil,
            "default-equal subtree was stripped (emptied table removed)")
    end
    check(report, sv.char == nil, "all-default char section stripped and pruned")
    check(report, sv.global == nil, "all-default global section stripped and pruned")
    check(report, type(sv.profileKeys) == "table" and handles ~= nil
        and sv.profileKeys[handles.charKey] == "Default",
        "profileKeys survived the strip")

    -- 6. Re-init: Destroy, then a second :New over the stripped store.
    db:Destroy()
    local okDead = pcall(function() return db.profile end)
    check(report, not okDead, "a section read on a destroyed controller raises (both builds)")

    local okNew2, db2 = pcall(DB.New, DB, {
        name = ADDON_NAME, sv = svName, defaults = makeDefaults(), defaultProfile = true,
    })
    check(report, okNew2 and db2 ~= nil, "Destroy released the sv slot; re-:New succeeded")
    if okNew2 and db2 then
        check(report, _G[svName] == sv, "re-init kept the same SV table identity")
        check(report, db2.profile.enabled == false,
            "re-init: stored false still beats the true default (nil-vs-false)")
        check(report, db2.profile.scale == 2, "re-init: deviated value persisted")
        check(report, db2.profile.customKey == 42, "re-init: dynamic key persisted")
        check(report, db2.profile.nested.color == "blue", "re-init: stripped default backfilled")
        check(report, db2.char.seen == false, "re-init: char default re-applied")
        check(report, db2.global.counter == 0, "re-init: global default re-applied")
    end

    -- 7. Probe self-check: the inspect collector reads the synthetic store
    -- correctly and provably writes nothing (the Phase D/E evidence tool is
    -- itself verified in-game before it judges real data).
    local beforeSig = signature(sv)
    local probe = collectInspect(svName)
    check(report, signature(sv) == beforeSig,
        "inspect probe wrote NOTHING (deep signature unchanged)")
    check(report, probe.present == true, "probe: synthetic SV reported present")
    check(report, probe.profileKeys == 1, "probe: profileKeys entry count correct (1)")
    local pb = type(probe.buckets) == "table" and probe.buckets.profiles or nil
    check(report, type(pb) == "table" and #pb == 1 and pb[1].key == "Default"
        and pb[1].count == 4,
        "probe: profile bucket counts correct (Default: 4 keys)")
    local cb = type(probe.buckets) == "table" and probe.buckets.char or nil
    check(report, type(cb) == "table" and #cb == 1 and cb[1].count == 1,
        "probe: char bucket counts correct (1 bucket, 1 key)")
    check(report, probe.globalCount == 1, "probe: global key count correct (1)")

    -- 8. The defaults table the consumer handed in was never written into.
    check(report, signature(defaults) == defaultsSig,
        "consumer defaults table unpolluted after the full drive")

    -- 9. Cleanup: Destroy the controller and release the synthetic global.
    -- (The stores stay registered for the session-end strip by design; stripping
    -- them again is an idempotent no-op over the captured refs.)
    if okNew2 and db2 then
        pcall(db2.Destroy, db2)
    end
    _G[svName] = nil

    out(string.format("Summary: %d ok, %d FAIL", report.passed, report.failed))
    return report
end

--------------------------------------------------------------------------------
-- The error drive: a migrate that raises must REFUSE construction with the
-- pre-existing store intact (a half-migrated store is never handed out), and the
-- refusal must release the sv slot so a clean retry succeeds.
--------------------------------------------------------------------------------

local function runErrorTest(out)
    local report = newReport(out)
    out("Foundry.DB self-test: migrate-raises => refused construction, store intact")

    local DB = F.DB
    if not DB then
        out("  FAIL: F.DB module is not present")
        report.failed = report.failed + 1
        return report
    end

    local svName = "FoundryDBSelfTestErr_SV" .. nextStamp()
    if _G[svName] ~= nil then
        out("  FAIL: synthetic global '" .. svName .. "' already exists; aborting")
        report.failed = report.failed + 1
        return report
    end

    -- Pre-seed a populated, UNVERSIONED store: a declared schema with no stored
    -- stamp means migrate(db, nil) runs inside :New.
    _G[svName] = { global = { keep = "me" } }

    local sawDb, sawVersion = nil, "unset"
    local okNew, err = pcall(DB.New, DB, {
        name = ADDON_NAME,
        sv = svName,
        defaultProfile = true,
        schema = {
            version = 2,
            key = "global.schemaVersion",
            migrate = function(db, storedVersion)
                sawDb, sawVersion = db, storedVersion
                error("Foundry self-test: intentional migrate error")
            end,
        },
    })

    check(report, sawDb ~= nil, "migrate ran and received the controller")
    check(report, sawVersion == nil, "an unversioned store migrates as storedVersion == nil")
    check(report, not okNew, "a raised migrate REFUSED construction")
    check(report, tostring(err):find("schema.migrate raised", 1, true) ~= nil,
        "the refusal carries the named migrate-raised message")
    check(report, tostring(err):find("intentional migrate error", 1, true) ~= nil,
        "the refusal carries the consumer's own error")

    local sv = _G[svName]
    check(report, type(sv) == "table" and type(sv.global) == "table"
        and sv.global.keep == "me",
        "store intact: pre-existing data untouched by the refused construction")
    check(report, type(sv) == "table" and type(sv.global) == "table"
        and sv.global.schemaVersion == nil,
        "no version stamp was written on the refused path")
    if sawDb ~= nil then
        local okDead = pcall(function() return sawDb.profile end)
        check(report, not okDead, "the refused controller was revoked (section read raises)")
    end

    -- The refusal released the sv slot: a clean migrate may re-run on the SAME sv.
    local okRetry, db = pcall(DB.New, DB, {
        name = ADDON_NAME,
        sv = svName,
        defaultProfile = true,
        schema = { version = 2, key = "global.schemaVersion", migrate = function() end },
    })
    check(report, okRetry and db ~= nil,
        "the refused :New released the sv slot (clean retry succeeded)")
    if okRetry and db then
        check(report, type(sv.global) == "table" and sv.global.schemaVersion == 2,
            "the clean retry stamped the declared schema version")
        check(report, type(sv.global) == "table" and sv.global.keep == "me",
            "pre-existing data survived the clean migrate")
        pcall(db.Destroy, db)
    end

    _G[svName] = nil
    out(string.format("Summary: %d ok, %d FAIL", report.passed, report.failed))
    return report
end

--------------------------------------------------------------------------------
-- Command registration (gate 2b + 2c)
--------------------------------------------------------------------------------

-- A private printer so the report routes through one place (and so the harness
-- could swap it). In-game this is the default chat frame via print.
local function emit(line)
    print(line)
end

-- Gate (2b): every handler ALSO early-returns through RaiseDevError if somehow
-- reached in a release build — defense in depth behind the file-level return and
-- the TOC exclusion.
local function walkHandler()
    if not F.IS_DEV_BUILD then
        F:RaiseDevError("DB self-test is dev-build only")
        return
    end
    runWalk(emit)
end

local function errorTestHandler()
    if not F.IS_DEV_BUILD then
        F:RaiseDevError("DB self-test is dev-build only")
        return
    end
    runErrorTest(emit)
end

local function inspectHandler(rest)
    if not F.IS_DEV_BUILD then
        F:RaiseDevError("DB inspect probe is dev-build only")
        return
    end
    local name = type(rest) == "string" and rest:match("^%S+") or nil
    if not name then
        emit("Usage: /foundrydb inspect <SavedVariablesGlobalName>"
            .. "  (e.g. /foundrydb inspect HomesteadDB)")
        return
    end
    printInspect(name, collectInspect(name), emit)
end

-- Gate (2c): register through a private F.Commands controller, so no raw SLASH_*
-- global is written. /foundrydb is DB's OWN dev surface (it cannot share
-- /foundrydev — Commands:New refuses duplicate slashes, and in a combined dev
-- session the second registrant would silently lose its command). The walk
-- requires the EXPLICIT `walk` subcommand; bare /foundrydb prints help. The
-- Phase D/E worksheets type `/foundrydb inspect ...` repeatedly in sessions
-- where a consumer's real store is live — a dropped word must print help, never
-- fire the simulated logout.
local devCommands = F.Commands and F.Commands:New({
    name = "FoundryDB",
    slashes = { "/foundrydb" },
    description = "Foundry.DB developer self-test (dev-build only).",
})

if devCommands then
    devCommands:Register({
        name = "walk",
        help = "Run the full synthetic walk: create -> defaults -> writes -> simulated strip -> re-init.",
        handler = walkHandler,
    })
    devCommands:Register({
        name = "errortest",
        help = "Run the migrate-raises drive: refused construction, store intact.",
        handler = errorTestHandler,
    })
    devCommands:Register({
        name = "inspect",
        args = "<SVGlobal>",
        help = "Read-only SavedVariables report: section presence and key counts (works under AceDB or Foundry.DB).",
        handler = inspectHandler,
    })
end

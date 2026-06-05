-- Foundry.Lifecycle in-game self-test (DEV-ONLY — never ships).
--
-- Lifecycle is the hardest Foundry module to observe in-game: every phase fires
-- once, at a moment the player cannot replay (ADDON_LOADED cannot replay without
-- a client restart; PLAYER_LOGOUT ends the session). The login-catch-up,
-- idempotency, Destroy-suppresses-logout, and continue-on-error behaviors are
-- therefore unverifiable by ordinary play. This command makes them observable by
-- driving synthetic controllers through the LIVE shared dispatcher via the
-- dev-only Lifecycle:_TestFire seam (the in-game analogue of the harness T.Fire),
-- printing a labelled PASS/FAIL report.
--
-- TRIPLE-GATED OFF for players:
--   (1) This file is NOT listed in Foundry-1.0.toc, so a packaged release never
--       contains it (the primary gate — exactly like Tests/).
--   (2) Both registration AND the command handler early-return through
--       F:RaiseDevError when not F.IS_DEV_BUILD, so even if the file were force-
--       loaded it refuses in a release build.
--   (3) The command is registered through a private F.Commands:New controller
--       (/foundrydev), so no raw SLASH_* global is ever written for players.

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: LifecycleSelfTest.lua requires the Foundry-1.0 bootstrap "
        .. "(Foundry.lua) to have loaded first; _G.Foundry_1_0 is missing.", 0)
end

-- Gate (2a): never even build the command in a release build.
if not F.IS_DEV_BUILD then
    return
end

--------------------------------------------------------------------------------
-- Report plumbing
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

-- Snapshot the key SET (not values) of a table so adopt-existing pollution is
-- detectable: Lifecycle must write NOTHING into the owner, so this string is
-- identical before and after :New and after every phase.
local function keySet(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    return table.concat(keys, ",")
end

-- Count the live controllers the dispatcher currently tracks for login/logout.
-- GetNativeHandles exposes the live shared dispatcher frame; the controller-count
-- baseline is proven indirectly by firing logout and counting hits, so this file
-- needs no private dispatcher access (it stays below the public surface).

-- A per-run counter makes each run's synthetic addonNames unique so a second run
-- never collides with a name a prior run failed to release (defense in depth; the
-- run already Destroys everything it creates). No WoW time global is used, so the
-- file stays luacheck-clean against the Foundry config.
local runSeq = 0
local function nextStamp()
    runSeq = runSeq + 1
    return tostring(runSeq)
end

--------------------------------------------------------------------------------
-- The main lifecycle drive: New(adopt) -> addon-loaded -> login -> logout ->
-- Destroy, with a late controller proving login catch-up and a sibling proving
-- per-owner logout suppression after Destroy.
--------------------------------------------------------------------------------

local function runLifecycle(out)
    local report = newReport(out)
    out("Foundry.Lifecycle self-test: create -> phases -> Destroy")

    local Lifecycle = F.Lifecycle
    if not Lifecycle then
        out("  FAIL: F.Lifecycle module is not present")
        report.failed = report.failed + 1
        return report
    end

    -- Unique synthetic addon names so the run never collides with a real
    -- controller's ownedNames registry (and so repeated runs do not clash, the
    -- run Destroys everything it creates before returning).
    local stamp = nextStamp()
    local nameA = "FoundryDevSelfTestA_" .. stamp
    local nameLate = "FoundryDevSelfTestLate_" .. stamp
    local nameSibling = "FoundryDevSelfTestSibling_" .. stamp

    -- Synthetic owner tables (the adopt-existing primary form). Track their key
    -- sets so we can prove zero pollution after every phase.
    local ownerA = { realKey = 1, method = function() end }
    local beforeA = keySet(ownerA)

    -- Phase results captured by the synthetic hooks.
    local hits = { al = 0, login = 0, logout = 0 }
    local lateLoginAtNew = nil
    local siblingLogout = 0

    -- 1. New(adopt-existing) + owner-not-polluted.
    local cA = Lifecycle:New(ownerA, nameA)
    check(report, cA ~= nil, "New(adopt) returned a controller")
    check(report, cA and cA._owner == ownerA, "New adopted the SAME owner identity")
    check(report, keySet(ownerA) == beforeA, "New wrote NO bookkeeping into the owner (key set unchanged)")

    if not cA then
        out(string.format("Summary: %d ok, %d FAIL (aborted: no controller)", report.passed, report.failed))
        return report
    end

    cA:OnAddonLoaded(function(o)
        hits.al = hits.al + 1
        check(report, o == ownerA, "addon-loaded hook received the adopted owner")
    end)
    cA:OnLogin(function() hits.login = hits.login + 1 end)
    cA:OnLogout(function() hits.logout = hits.logout + 1 end)

    -- 2. addon-loaded: fires once, does not re-fire.
    Lifecycle:_TestFire("addon-loaded", nameA)
    check(report, hits.al == 1, "addon-loaded fired once (#1)")
    Lifecycle:_TestFire("addon-loaded", nameA)
    check(report, hits.al == 1, "a second ADDON_LOADED does NOT re-fire (idempotent)")
    check(report, keySet(ownerA) == beforeA, "owner key set unchanged after addon-loaded")

    -- 3. login: fires once, does not re-fire.
    Lifecycle:_TestFire("login")
    check(report, hits.login == 1, "login fired once")
    Lifecycle:_TestFire("login")
    check(report, hits.login == 1, "a second PLAYER_LOGIN does NOT re-fire (idempotent)")
    check(report, keySet(ownerA) == beforeA, "owner key set unchanged after login")

    -- 4. Late controller created AFTER login proves the central login catch-up:
    --    its OnLogin must fire IMMEDIATELY (synchronously) inside registration,
    --    because the dispatcher-global loginFired flag is already set.
    local cLate = Lifecycle:New(nil, nameLate)
    check(report, cLate ~= nil, "late controller created after login")
    if cLate then
        cLate:OnLogin(function() lateLoginAtNew = true end)
        check(report, lateLoginAtNew == true,
            "LATE controller: login fired IMMEDIATELY on hook registration (catch-up)")
    end

    -- 5. A still-live sibling that subscribes logout — used to prove per-owner
    --    logout suppression below (destroyed A suppressed, live sibling fires).
    local cSibling = Lifecycle:New(nil, nameSibling)
    check(report, cSibling ~= nil, "live sibling controller created")
    if cSibling then
        cSibling:OnLogout(function() siblingLogout = siblingLogout + 1 end)
    end

    -- 6. Destroy A: unsubscribes, releases refs; logout for A must be suppressed.
    cA:Destroy()
    check(report, cA._destroyed == true, "Destroy marked the controller destroyed")
    check(report, cA._owner == nil, "Destroy released the owner ref")
    check(report, keySet(ownerA) == beforeA, "owner key set unchanged after Destroy (no pollution)")
    -- Destroy itself must NOT have fired logout.
    check(report, hits.logout == 0, "Destroy did NOT fire the logout hook")
    -- A method after Destroy refuses (dev raise -> pcall'd here so the run continues).
    local okAfter = pcall(function() cA:OnLogin(function() end) end)
    check(report, not okAfter, "a method after Destroy fails loudly in dev")

    -- 7. logout: destroyed A is SUPPRESSED; the live sibling STILL fires.
    Lifecycle:_TestFire("logout")
    check(report, hits.logout == 0, "destroyed A's logout SUPPRESSED")
    check(report, siblingLogout == 1, "live sibling's logout STILL fired")

    -- 8. Tear down everything this run created and prove the dispatcher returns to
    --    baseline (no synthetic controllers left subscribed). Re-firing logout
    --    after destroying all of them must hit nothing.
    if cLate then cLate:Destroy() end
    if cSibling then cSibling:Destroy() end
    local postCleanupLogout = siblingLogout
    Lifecycle:_TestFire("logout")
    check(report, siblingLogout == postCleanupLogout,
        "dispatcher controller-count back to baseline (no synthetic controller fires after cleanup)")

    -- 9. Released names may be re-:New'd (ownedNames cleared on Destroy).
    local reuse = Lifecycle:New(nil, nameA)
    check(report, reuse ~= nil, "released addonName may be re-:New'd after Destroy")
    if reuse then reuse:Destroy() end

    out(string.format("Summary: %d ok, %d FAIL", report.passed, report.failed))
    return report
end

--------------------------------------------------------------------------------
-- The error-continue drive: two login hooks, the FIRST error()s. Prove the
-- SECOND still ran (fan-out completed) AND the error surfaced AFTER the fan-out
-- (not at the throw site) — the single most important Lifecycle guarantee (Q5).
--------------------------------------------------------------------------------

local function runErrorTest(out)
    local report = newReport(out)
    out("Foundry.Lifecycle self-test: continue-on-error (login fan-out)")

    local Lifecycle = F.Lifecycle
    local stamp = nextStamp()
    local nameA = "FoundryDevErrA_" .. stamp
    local nameB = "FoundryDevErrB_" .. stamp

    local aRan, bRan = false, false
    local cA = Lifecycle:New(nil, nameA)
    local cB = Lifecycle:New(nil, nameB)

    if not (cA and cB) then
        out("  FAIL: could not create the two error-test controllers")
        report.failed = report.failed + 1
        if cA then cA:Destroy() end
        if cB then cB:Destroy() end
        return report
    end

    cA:OnLogin(function()
        aRan = true
        error("Foundry self-test: intentional login error from controller A")
    end)
    cB:OnLogin(function() bRan = true end)

    -- In a dev build the dispatcher re-raises AFTER the fan-out, so the fire
    -- itself raises — pcall it so the run continues, then assert that B's
    -- side-effect is ALREADY present, proving the loop completed BEFORE the error
    -- surfaced (the error did NOT abort dispatch at the throw site).
    local fireOk, fireErr = pcall(function() Lifecycle:_TestFire("login") end)

    check(report, aRan, "controller A's login hook ran (and threw)")
    check(report, bRan,
        "controller B's login hook STILL RAN despite A throwing (fan-out completed)")
    -- Dev: the fire raised after the fan-out, carrying A's error.
    check(report, not fireOk,
        "the error SURFACED after fan-out (dev build raised once the loop finished)")
    check(report, fireErr ~= nil and tostring(fireErr):find("intentional login error", 1, true) ~= nil,
        "the surfaced error is controller A's")

    cA:Destroy()
    cB:Destroy()

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

-- Gate (2b): the handler ALSO early-returns through RaiseDevError if somehow
-- reached in a release build — defense in depth behind the file-level return and
-- the TOC exclusion.
local function lifecycleHandler(rest)
    if not F.IS_DEV_BUILD then
        F:RaiseDevError("Lifecycle self-test is dev-build only")
        return
    end
    rest = (rest or ""):lower()
    if rest:find("^errortest") then
        runErrorTest(emit)
    else
        runLifecycle(emit)
    end
end

-- Gate (2c): register through a private F.Commands controller, so no raw SLASH_*
-- global is written. /foundrydev is the dev surface; "lifecycle" is its only
-- subcommand this cycle.
local devCommands = F.Commands and F.Commands:New({
    name = "FoundryDev",
    slashes = { "/foundrydev" },
    description = "Foundry developer tools (dev-build only).",
})

if devCommands then
    devCommands:Register({
        name = "lifecycle",
        args = "[errortest]",
        help = "Run the Foundry.Lifecycle in-game self-test (add 'errortest' for the continue-on-error case).",
        handler = lifecycleHandler,
    })
end

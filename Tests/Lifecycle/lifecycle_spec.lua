-- Foundry.Lifecycle behavior tests. Loaded by Tests/run.lua, which passes the
-- harness table T. Returns a list of { name, fn } cases covering the §2 contract
-- (CYCLE-2B-LIFECYCLE plan) and the §3 Phase C enumeration: the single shared
-- dispatcher (one frame, three RegisterEvent, O(1) demux); New/adopt-existing
-- with ZERO owner-table pollution; Load-on-Demand catch-up and the
-- addon-loaded-vs-login asymmetry; idempotency; re-register rejection in BOTH
-- windows (before AND after addon-loaded fires) and again-permitted after
-- Destroy; the locked continue-on-error contract (fan-out completes, the error
-- surfaces AFTER the loop, never at the throw site); Destroy (unsubscribe,
-- does-not-fire-logout, per-owner suppression while a sibling's logout still
-- fires, methods-after-Destroy refuse, double-Destroy refuses); and
-- GetNativeHandles (live shared frame + read-only snapshot; two controllers'
-- .frame are the SAME identity).
--
-- Harness note: T.fresh() installs the additive CreateFrame("Frame") stub
-- (T.frames records every frame; each frame logs RegisterEvent and captures the
-- OnEvent script), mocks C_AddOns.IsAddOnLoaded (driven by T.loadedAddons), and
-- loads Modules/Lifecycle.lua, so each case starts from a clean dev (or release)
-- build with zero frames created and fresh dispatcher upvalues (the module is
-- re-executed per load, so its file-scope dispatcher state is per-test).
-- T.Fire(frame, event, ...) synthesizes a native OnEvent delivery: the
-- dispatcher frame is T.frames[1] (lazily created on the first :New).

local T = ...

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local function noop() end

-- Snapshot the key SET of a table (not values) so adopt-existing pollution is
-- detectable byte-for-byte: sort the keys and concat. Lifecycle must write
-- NOTHING into the owner, so this string is identical before and after :New and
-- after every phase.
local function keySet(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    return table.concat(keys, ",")
end

-- The dispatcher frame is the one and only frame created on the first :New.
local function dispatcherFrame()
    return T.frames[1]
end

--------------------------------------------------------------------------------
-- Harness / bootstrap / module-reg
--------------------------------------------------------------------------------

-- harness-stub
test("harness: CreateFrame stub records native calls and Lifecycle.lua loads", function()
    local F = T.fresh()
    T.eq(type(F.Lifecycle), "table", "Lifecycle module loaded")
    T.eq(type(F.Lifecycle.New), "function", "Lifecycle:New present")
    -- loadFoundry creates no frames; only the first :New does.
    T.eq(#T.frames, 0, "no frames before :New")
    F.Lifecycle:New(nil, "Stub")
    T.eq(#T.frames, 1, "one dispatcher frame after first :New")
    local fr = dispatcherFrame()
    T.eq(type(fr._onEvent), "function", "OnEvent captured on the dispatcher")
    T.eq(type(T.Fire), "function", "Fire helper present")
    T.eq(type(_G.C_AddOns.IsAddOnLoaded), "function", "IsAddOnLoaded mock present")
end)

-- bootstrap-detect
test("bootstrap dev/release detection on the Lifecycle build", function()
    T.installMocks("@project-version@"); local F1 = T.loadFoundry()
    T.truthy(F1.IS_DEV_BUILD, "literal token -> dev")
    T.installMocks("2.3.4"); local F2 = T.loadFoundry()
    T.falsy(F2.IS_DEV_BUILD, "real version -> release")
    T.installMocks("2.3.4"); _G.FOUNDRY_DEV_BUILD_OVERRIDE = true; local F3 = T.loadFoundry()
    T.truthy(F3.IS_DEV_BUILD, "override forces dev even on a real version")
end)

-- module-reg
test("HasModule / RequireModule behavior for Lifecycle; additive version markers", function()
    local F = T.fresh()
    T.truthy(F:HasModule("Lifecycle"), "has Lifecycle")
    T.eq(F:RequireModule("Lifecycle"), F.Lifecycle, "RequireModule returns the module")
    T.eq(F:RequireModule("Lifecycle", 1), F.Lifecycle, "RequireModule min=1 returns the module")
    T.raises(function() F:RequireModule("Lifecycle", 99) end, "above-max API raises", "API version")
    -- Per-MODULE marker is 1 (matches Commands/Events precedent; does not change).
    T.eq(F.Lifecycle.API_VERSION, 1, "Lifecycle.API_VERSION == 1")
    -- Library-wide version bumped ADDITIVELY 2 -> 3 when Lifecycle ships.
    T.eq(F.API_VERSION, 3, "library API_VERSION == 3 (additive bump)")
    -- Sibling modules still register and keep their own markers.
    T.truthy(F:HasModule("Events"), "Events still registered")
    T.truthy(F:HasModule("Commands"), "Commands still registered")
    T.eq(F.Events.API_VERSION, 1, "Events per-module marker unchanged == 1")
end)

-- one-frame-three-reg
test("first :New creates exactly one frame registering the three startup events once each", function()
    local F = T.fresh()
    F.Lifecycle:New(nil, "AddonA")
    T.eq(#T.frames, 1, "exactly one dispatcher frame")
    local fr = dispatcherFrame()
    -- Three RegisterEvent calls, one per startup signal, each exactly once.
    T.eq(#fr.calls.RegisterEvent, 3, "three RegisterEvent calls")
    local seen = {}
    for _, rec in ipairs(fr.calls.RegisterEvent) do seen[rec[1]] = (seen[rec[1]] or 0) + 1 end
    T.eq(seen["ADDON_LOADED"], 1, "ADDON_LOADED registered once")
    T.eq(seen["PLAYER_LOGIN"], 1, "PLAYER_LOGIN registered once")
    T.eq(seen["PLAYER_LOGOUT"], 1, "PLAYER_LOGOUT registered once")
    T.truthy(not fr:IsShown(), "dispatcher frame hidden")
end)

-- lazy-frame
test("module load registers nothing; the frame is lazily created on first :New only", function()
    local F = T.fresh()
    -- Nothing created at module load.
    T.eq(#T.frames, 0, "no frame at load")
    local a = F.Lifecycle:New(nil, "A")
    T.eq(#T.frames, 1, "frame created on first :New")
    -- A second and third :New reuse the same dispatcher (NO new frame).
    local b = F.Lifecycle:New(nil, "B")
    local c = F.Lifecycle:New(nil, "C")
    T.eq(#T.frames, 1, "still one frame after three :New (shared dispatcher)")
    T.eq(#dispatcherFrame().calls.RegisterEvent, 3, "still three RegisterEvent total (registered once)")
    T.truthy(a ~= b and b ~= c, "distinct controllers")
end)

--------------------------------------------------------------------------------
-- New / adopt-existing (Q4)
--------------------------------------------------------------------------------

-- new-surface
test("New returns a controller exposing the published methods", function()
    local F = T.fresh()
    local c = F.Lifecycle:New(nil, "MyAddon")
    T.truthy(c, "controller created")
    for _, m in ipairs({ "OnAddonLoaded", "OnLogin", "OnLogout", "GetNativeHandles", "Destroy" }) do
        T.eq(type(c[m]), "function", "method " .. m)
    end
end)

-- adopt-identity
test("New adopts the SAME owner table identity (does not wrap or replace it)", function()
    local F = T.fresh()
    local owner = { existing = true }
    local c = F.Lifecycle:New(owner, "MyAddon")
    T.eq(c._owner, owner, "controller holds the same owner identity")
    -- The hook receives that exact owner back as its argument.
    local got
    c:OnLogin(function(o) got = o end)
    T.Fire(dispatcherFrame(), "PLAYER_LOGIN")
    T.eq(got, owner, "login hook receives the adopted owner identity")
end)

-- adopt-zero-pollution
test("adopt writes NO bookkeeping into the owner: key set unchanged after :New", function()
    local F = T.fresh()
    local owner = { a = 1, b = 2, method = noop }
    local before = keySet(owner)
    F.Lifecycle:New(owner, "MyAddon")
    T.eq(keySet(owner), before, "owner key set byte-for-byte unchanged after :New")
end)

-- fresh-object-secondary
test("the secondary fresh-object form (nil owner) yields a usable controller", function()
    local F = T.fresh()
    local c = F.Lifecycle:New(nil, "MyAddon")
    T.truthy(c, "controller created with nil owner")
    local fired = false
    c:OnLogin(function() fired = true end)
    T.Fire(dispatcherFrame(), "PLAYER_LOGIN")
    T.truthy(fired, "fresh-object controller's hook fires")
end)

-- new-invalid-owner-dev
test("New rejects a non-table owner loudly in a dev build, atomically", function()
    local F = T.fresh()
    for _, bad in ipairs({ "str", 123, true, function() end }) do
        T.raises(function() F.Lifecycle:New(bad, "Addon") end,
            "owner " .. tostring(bad), "owner, when supplied, must be a table")
    end
    -- No frame created by a rejected :New (validation precedes ensureDispatcher).
    T.eq(#T.frames, 0, "no frame created on rejected :New")
end)

-- new-invalid-addonname-dev
test("New rejects a non-string / empty addonName loudly in a dev build", function()
    local F = T.fresh()
    for _, bad in ipairs({ "", 123, true, {} }) do
        T.raises(function() F.Lifecycle:New({}, bad) end,
            "addonName " .. tostring(bad), "addonName must be a non-empty string")
    end
    T.raises(function() F.Lifecycle:New({}, nil) end, "nil addonName", "addonName must be a non-empty string")
    T.eq(#T.frames, 0, "no frame created on rejected :New")
end)

-- new-invalid-release
test("New refuses an invalid argument in a release build (prints, returns nil)", function()
    local F = T.fresh("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    local c
    local ok = pcall(function() c = F.Lifecycle:New({}, "") end)
    T.truthy(ok, "no raise in release build")
    T.outputContains("addonName must be a non-empty string", "diagnostic printed in release")
    T.eq(c, nil, "returned controller is nil")
end)

--------------------------------------------------------------------------------
-- Single shared dispatcher / demux (Q2)
--------------------------------------------------------------------------------

-- one-frame-many-controllers
test("five controllers share ONE dispatcher frame with a single set of registrations", function()
    local F = T.fresh()
    for i = 1, 5 do F.Lifecycle:New(nil, "Addon" .. i) end
    T.eq(#T.frames, 1, "one frame across five controllers")
    local seen = {}
    for _, rec in ipairs(dispatcherFrame().calls.RegisterEvent) do seen[rec[1]] = (seen[rec[1]] or 0) + 1 end
    T.eq(seen["ADDON_LOADED"], 1, "ADDON_LOADED registered exactly once for the whole library")
    T.eq(seen["PLAYER_LOGIN"], 1, "PLAYER_LOGIN registered once")
    T.eq(seen["PLAYER_LOGOUT"], 1, "PLAYER_LOGOUT registered once")
end)

-- demux-by-name
test("ADDON_LOADED is demuxed by name: only the matching controller fires", function()
    local F = T.fresh()
    local a = F.Lifecycle:New(nil, "AddonA")
    local b = F.Lifecycle:New(nil, "AddonB")
    local fr = dispatcherFrame()
    local aHits, bHits = 0, 0
    a:OnAddonLoaded(function() aHits = aHits + 1 end)
    b:OnAddonLoaded(function() bHits = bHits + 1 end)
    T.Fire(fr, "ADDON_LOADED", "AddonA")
    T.eq(aHits, 1, "A's addon-loaded fired")
    T.eq(bHits, 0, "B untouched by A's ADDON_LOADED")
    -- An unknown name is a no-op (no error, nothing fires).
    local ok = pcall(function() T.Fire(fr, "ADDON_LOADED", "SomeOtherAddon") end)
    T.truthy(ok, "unknown ADDON_LOADED name is a safe no-op")
    T.eq(aHits, 1, "A unchanged by unknown name"); T.eq(bHits, 0, "B unchanged by unknown name")
    T.Fire(fr, "ADDON_LOADED", "AddonB")
    T.eq(bHits, 1, "B's addon-loaded fired on its own name")
end)

-- login-logout-fanout
test("PLAYER_LOGIN / PLAYER_LOGOUT fan out to every login/logout controller once", function()
    local F = T.fresh()
    local fr
    local hits = { login = 0, logout = 0 }
    for i = 1, 3 do
        local c = F.Lifecycle:New(nil, "Addon" .. i)
        fr = fr or dispatcherFrame()
        c:OnLogin(function() hits.login = hits.login + 1 end)
        c:OnLogout(function() hits.logout = hits.logout + 1 end)
    end
    T.Fire(fr, "PLAYER_LOGIN")
    T.eq(hits.login, 3, "all three login hooks fired once")
    T.Fire(fr, "PLAYER_LOGOUT")
    T.eq(hits.logout, 3, "all three logout hooks fired once")
end)

-- o1-150-controllers
test("150 controllers stay O(1): one frame, one ADDON_LOADED registration, no wake-up storm", function()
    local F = T.fresh()
    local hits = {}
    for i = 1, 150 do
        local c = F.Lifecycle:New(nil, "Addon" .. i)
        hits[i] = 0
        c:OnAddonLoaded(function() hits[i] = hits[i] + 1 end)
    end
    -- Still exactly one frame and one ADDON_LOADED registration for 150 consumers.
    T.eq(#T.frames, 1, "one dispatcher frame for 150 controllers")
    local adCount = 0
    for _, rec in ipairs(dispatcherFrame().calls.RegisterEvent) do
        if rec[1] == "ADDON_LOADED" then adCount = adCount + 1 end
    end
    T.eq(adCount, 1, "ADDON_LOADED registered exactly once regardless of consumer count")
    -- Firing ONE name fires exactly ONE hook (demux, not a broadcast storm).
    T.Fire(dispatcherFrame(), "ADDON_LOADED", "Addon42")
    local total = 0
    for i = 1, 150 do total = total + hits[i] end
    T.eq(total, 1, "exactly one hook fired across 150 controllers")
    T.eq(hits[42], 1, "and it was the matching controller's hook")
end)

-- central-login-flag
test("the login-fired flag is dispatcher-global, not per-controller", function()
    local F = T.fresh()
    local early = F.Lifecycle:New(nil, "Early")
    early:OnLogin(noop)
    -- Login fires before a later controller exists.
    T.Fire(dispatcherFrame(), "PLAYER_LOGIN")
    -- A controller created AFTER login sees the global flag and catches up.
    local late = F.Lifecycle:New(nil, "Late")
    local lateFired = false
    late:OnLogin(function() lateFired = true end)
    T.truthy(lateFired, "late controller's login catches up via the dispatcher-global flag")
end)

--------------------------------------------------------------------------------
-- Catch-up / Load-on-Demand (Q2)
--------------------------------------------------------------------------------

-- catchup-login-before
test("a controller registered before login fires on PLAYER_LOGIN (not before)", function()
    local F = T.fresh()
    local c = F.Lifecycle:New(nil, "A")
    local fired = 0
    c:OnLogin(function() fired = fired + 1 end)
    T.eq(fired, 0, "does not fire at registration time (login has not happened)")
    T.Fire(dispatcherFrame(), "PLAYER_LOGIN")
    T.eq(fired, 1, "fires once on PLAYER_LOGIN")
end)

-- catchup-login-after
test("a controller registered after login catches up synchronously inside :New's hook, once", function()
    local F = T.fresh()
    local first = F.Lifecycle:New(nil, "First")
    first:OnLogin(noop)
    T.Fire(dispatcherFrame(), "PLAYER_LOGIN")
    -- Now login has fired; a late controller's OnLogin fires immediately.
    local late = F.Lifecycle:New(nil, "Late")
    local fired = 0
    late:OnLogin(function() fired = fired + 1 end)
    T.eq(fired, 1, "login hook fired immediately (synchronous catch-up) at registration")
    -- A subsequent PLAYER_LOGIN must not double-fire the caught-up hook.
    T.Fire(dispatcherFrame(), "PLAYER_LOGIN")
    T.eq(fired, 1, "no second fire on a stray later PLAYER_LOGIN")
end)

-- catchup-addonloaded-already
test("an already-loaded addon's addon-loaded hook catches up synchronously and is not enrolled", function()
    local F = T.fresh()
    local c = F.Lifecycle:New(nil, "AlreadyUp")
    T.loadedAddons["AlreadyUp"] = true   -- the addon is already loaded
    local fired = 0
    c:OnAddonLoaded(function() fired = fired + 1 end)
    T.eq(fired, 1, "addon-loaded fired immediately via catch-up")
    -- It is NOT enrolled for a future ADDON_LOADED: a later signal does not re-fire.
    T.Fire(dispatcherFrame(), "ADDON_LOADED", "AlreadyUp")
    T.eq(fired, 1, "a later ADDON_LOADED does not re-fire the caught-up hook")
end)

-- catchup-addonloaded-not-replayed
test("a genuinely-missed addon-loaded does NOT replay; a late controller gets login only", function()
    local F = T.fresh()
    -- Controller A exists and the game's ADDON_LOADED for "LateAddon" passes
    -- while NO controller for it was registered (a genuinely missed signal).
    local seed = F.Lifecycle:New(nil, "Seed")
    seed:OnLogin(noop)
    local fr = dispatcherFrame()
    T.Fire(fr, "ADDON_LOADED", "LateAddon")  -- nobody is listening for it
    T.Fire(fr, "PLAYER_LOGIN")
    -- Now a controller for LateAddon registers AFTER its ADDON_LOADED passed.
    -- IsAddOnLoaded reports false (not in T.loadedAddons), so addon-loaded does
    -- NOT replay; only login catches up.
    local late = F.Lifecycle:New(nil, "LateAddon")
    local adFired, loginFired = 0, 0
    late:OnAddonLoaded(function() adFired = adFired + 1 end)
    late:OnLogin(function() loginFired = loginFired + 1 end)
    T.eq(adFired, 0, "missed addon-loaded does NOT replay")
    T.eq(loginFired, 1, "login DOES catch up")
    -- A later ADDON_LOADED for that name would still fire it (it is enrolled),
    -- but the already-passed one is not replayed -- that is the asymmetry.
    T.Fire(fr, "ADDON_LOADED", "LateAddon")
    T.eq(adFired, 1, "a fresh future ADDON_LOADED still fires the enrolled hook")
end)

--------------------------------------------------------------------------------
-- Idempotency
--------------------------------------------------------------------------------

-- idempotent-each-phase
test("each phase fires exactly once; a stray second signal does not re-run it", function()
    local F = T.fresh()
    local c = F.Lifecycle:New(nil, "A")
    local fr = dispatcherFrame()
    local al, lo, lg = 0, 0, 0
    c:OnAddonLoaded(function() al = al + 1 end)
    c:OnLogin(function() lo = lo + 1 end)
    c:OnLogout(function() lg = lg + 1 end)
    T.Fire(fr, "ADDON_LOADED", "A"); T.Fire(fr, "ADDON_LOADED", "A")
    T.Fire(fr, "PLAYER_LOGIN");      T.Fire(fr, "PLAYER_LOGIN")
    T.Fire(fr, "PLAYER_LOGOUT");     T.Fire(fr, "PLAYER_LOGOUT")
    T.eq(al, 1, "addon-loaded fired once despite a second ADDON_LOADED")
    T.eq(lo, 1, "login fired once despite a second PLAYER_LOGIN")
    T.eq(lg, 1, "logout fired once despite a second PLAYER_LOGOUT")
end)

-- dup-hook-rejected-dev
test("a second hook registration for the same phase is rejected via RaiseDevError (dev)", function()
    local F = T.fresh()
    local c = F.Lifecycle:New(nil, "A")
    c:OnAddonLoaded(noop)
    c:OnLogin(noop)
    c:OnLogout(noop)
    T.raises(function() c:OnAddonLoaded(noop) end, "dup addon-loaded", "one hook per phase")
    T.raises(function() c:OnLogin(noop) end, "dup login", "one hook per phase")
    T.raises(function() c:OnLogout(noop) end, "dup logout", "one hook per phase")
end)

-- dup-hook-atomic
test("a rejected duplicate hook leaves the first handler intact and still fires it", function()
    local F = T.fresh()
    local c = F.Lifecycle:New(nil, "A")
    local fr = dispatcherFrame()
    local first, second = 0, 0
    c:OnLogin(function() first = first + 1 end)
    T.raises(function() c:OnLogin(function() second = second + 1 end) end, "dup", "one hook per phase")
    T.Fire(fr, "PLAYER_LOGIN")
    T.eq(first, 1, "first login handler still live")
    T.eq(second, 0, "second handler never installed")
end)

-- hook-bad-handler
test("a non-function handler is rejected loudly (dev) for every phase, atomically", function()
    local F = T.fresh()
    local c = F.Lifecycle:New(nil, "A")
    for _, bad in ipairs({ "str", 123, true, {} }) do
        local tag = tostring(bad)
        T.raises(function() c:OnAddonLoaded(bad) end, "addon-loaded bad " .. tag, "handler must be a function")
        T.raises(function() c:OnLogin(bad) end, "login bad " .. tag, "handler must be a function")
        T.raises(function() c:OnLogout(bad) end, "logout bad " .. tag, "handler must be a function")
    end
    -- A valid registration afterward still works (nothing corrupted).
    local fired = false
    c:OnLogin(function() fired = true end)
    T.Fire(dispatcherFrame(), "PLAYER_LOGIN")
    T.truthy(fired, "valid login registration still works after rejected bad handlers")
end)

--------------------------------------------------------------------------------
-- Re-register rejection (Q2): ownedNames vs byAddonName, both windows
--------------------------------------------------------------------------------

-- rereg-before-fire
test("re-register the same addonName BEFORE addon-loaded fires is rejected; first intact", function()
    local F = T.fresh()
    local first = F.Lifecycle:New(nil, "Dup")
    T.raises(function() F.Lifecycle:New(nil, "Dup") end, "rereg before fire", "already owns a live Lifecycle")
    -- The first controller still routes (demux unbroken).
    local fired = 0
    first:OnAddonLoaded(function() fired = fired + 1 end)
    T.Fire(dispatcherFrame(), "ADDON_LOADED", "Dup")
    T.eq(fired, 1, "the first registration still receives its addon-loaded")
end)

-- rereg-after-fire
test("re-register the same addonName AFTER addon-loaded fires is STILL rejected (ownedNames-backed)", function()
    local F = T.fresh()
    local first = F.Lifecycle:New(nil, "Dup")
    local fired = 0
    first:OnAddonLoaded(function() fired = fired + 1 end)
    -- Fire addon-loaded: byAddonName is cleared (one-shot), but ownedNames persists.
    T.Fire(dispatcherFrame(), "ADDON_LOADED", "Dup")
    T.eq(fired, 1, "addon-loaded fired, clearing the one-shot demux entry")
    -- The re-register guard is backed by ownedNames, NOT byAddonName, so it must
    -- STILL reject even though byAddonName no longer holds the name.
    T.raises(function() F.Lifecycle:New(nil, "Dup") end,
        "rereg after fire", "already owns a live Lifecycle")
end)

-- rereg-distinct-ok
test("distinct addonNames never collide", function()
    local F = T.fresh()
    local a = F.Lifecycle:New(nil, "AddonA")
    local b = F.Lifecycle:New(nil, "AddonB")
    T.truthy(a and b and a ~= b, "two distinct controllers created without rejection")
end)

-- rereg-permitted-after-destroy
test("after Destroy the released addonName may be :New'd again", function()
    local F = T.fresh()
    local first = F.Lifecycle:New(nil, "Reusable")
    first:Destroy()
    local again
    local ok = pcall(function() again = F.Lifecycle:New(nil, "Reusable") end)
    T.truthy(ok, "re-:New after Destroy does not raise")
    T.truthy(again, "a fresh controller for the released name is created")
    -- And it functions.
    local fired = false
    again:OnLogin(function() fired = true end)
    T.Fire(dispatcherFrame(), "PLAYER_LOGIN")
    T.truthy(fired, "the re-created controller's hook fires")
end)

-- rereg-release
test("re-register in a release build refuses (prints, returns nil), first intact", function()
    local F = T.fresh("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    local first = F.Lifecycle:New(nil, "Dup")
    local second
    local ok = pcall(function() second = F.Lifecycle:New(nil, "Dup") end)
    T.truthy(ok, "no raise in release")
    T.outputContains("already owns a live Lifecycle", "diagnostic printed")
    T.eq(second, nil, "second :New returns nil")
    -- First still routes.
    local fired = 0
    first:OnLogin(function() fired = fired + 1 end)
    T.Fire(dispatcherFrame(), "PLAYER_LOGIN")
    T.eq(fired, 1, "first registration intact")
end)

--------------------------------------------------------------------------------
-- Error-continue (Q5): fan-out completes; error surfaces AFTER the loop
--------------------------------------------------------------------------------

-- error-continue-login-dev
test("login: first hook error()s -> the SECOND hook STILL RAN and the error surfaced AFTER fan-out (dev)", function()
    local F = T.fresh()
    local a = F.Lifecycle:New(nil, "A")
    local b = F.Lifecycle:New(nil, "B")
    local fr = dispatcherFrame()
    local bRan = false
    a:OnLogin(function() error("A login boom") end)
    b:OnLogin(function() bRan = true end)
    -- In a dev build the dispatcher re-raises AFTER the fan-out, so the Fire
    -- itself raises -- but B's side-effect must already be present, proving the
    -- loop completed before the error surfaced (not aborted at the throw site).
    local err = T.raises(function() T.Fire(fr, "PLAYER_LOGIN") end,
        "dev surfaces the captured error", "A login boom")
    T.truthy(bRan, "controller B's login hook STILL RAN despite A throwing")
    T.truthy(tostring(err):find("A login boom", 1, true), "the surfaced error is A's")
end)

-- error-continue-login-release
test("login error-continue in a release build: both ran, the diagnostic printed, no raise", function()
    local F = T.fresh("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    local a = F.Lifecycle:New(nil, "A")
    local b = F.Lifecycle:New(nil, "B")
    local fr = dispatcherFrame()
    local bRan = false
    a:OnLogin(function() error("A login boom") end)
    b:OnLogin(function() bRan = true end)
    local ok = pcall(function() T.Fire(fr, "PLAYER_LOGIN") end)
    T.truthy(ok, "release: no raise out of the fan-out")
    T.truthy(bRan, "controller B's login hook still ran")
    T.outputContains("A login boom", "the error was surfaced (printed) in release")
end)

-- error-continue-logout
test("logout error-continue: first hook throws, the sibling's logout STILL fires (dev)", function()
    local F = T.fresh()
    local a = F.Lifecycle:New(nil, "A")
    local b = F.Lifecycle:New(nil, "B")
    local fr = dispatcherFrame()
    local bRan = false
    a:OnLogout(function() error("A logout boom") end)
    b:OnLogout(function() bRan = true end)
    T.raises(function() T.Fire(fr, "PLAYER_LOGOUT") end, "dev surfaces after fan-out", "A logout boom")
    T.truthy(bRan, "controller B's logout STILL ran (Cycle-3 DB strip depends on this)")
end)

-- error-addonloaded-single-fire
test("addon-loaded: a throwing hook is captured and surfaced after its single fire (dev)", function()
    local F = T.fresh()
    local c = F.Lifecycle:New(nil, "A")
    local fr = dispatcherFrame()
    c:OnAddonLoaded(function() error("AL boom") end)
    -- ADDON_LOADED is a single fire (no fan-out), but the error is still
    -- captured-and-returned, then surfaced -- never thrown inline.
    T.raises(function() T.Fire(fr, "ADDON_LOADED", "A") end, "addon-loaded surfaces", "AL boom")
    -- The one-shot slot is cleared even though the handler threw: no re-fire.
    local ok = pcall(function() T.Fire(fr, "ADDON_LOADED", "A") end)
    T.truthy(ok, "a second ADDON_LOADED after the throw is a no-op (slot already cleared)")
end)

-- error-side-effect-present
test("dev-build error does not abort the fan-out: B's side-effect persists even though A threw", function()
    local F = T.fresh()
    local a = F.Lifecycle:New(nil, "A")
    local b = F.Lifecycle:New(nil, "B")
    local c = F.Lifecycle:New(nil, "C")
    local fr = dispatcherFrame()
    local marks = {}
    a:OnLogin(function() marks.a = true; error("A boom") end)
    b:OnLogin(function() marks.b = true end)
    c:OnLogin(function() marks.c = true end)
    -- The Fire raises in dev (after fan-out), so wrap it; then assert every
    -- controller's side-effect landed -- the fan-out reached all three.
    pcall(function() T.Fire(fr, "PLAYER_LOGIN") end)
    T.truthy(marks.a, "A ran (and threw)")
    T.truthy(marks.b, "B ran despite A's throw")
    T.truthy(marks.c, "C ran despite A's throw")
end)

--------------------------------------------------------------------------------
-- Destroy (Q8)
--------------------------------------------------------------------------------

-- destroy-unsubscribes
test("Destroy unsubscribes: later addon-loaded / login / logout do not fire the destroyed controller", function()
    local F = T.fresh()
    local c = F.Lifecycle:New(nil, "A")
    local fr = dispatcherFrame()
    local al, lo, lg = 0, 0, 0
    c:OnAddonLoaded(function() al = al + 1 end)
    c:OnLogin(function() lo = lo + 1 end)
    c:OnLogout(function() lg = lg + 1 end)
    c:Destroy()
    T.Fire(fr, "ADDON_LOADED", "A")
    T.Fire(fr, "PLAYER_LOGIN")
    T.Fire(fr, "PLAYER_LOGOUT")
    T.eq(al, 0, "addon-loaded did not fire the destroyed controller")
    T.eq(lo, 0, "login did not fire the destroyed controller")
    T.eq(lg, 0, "logout did not fire the destroyed controller")
end)

-- destroy-does-not-fire-logout
test("Destroy does NOT fire the logout hook (teardown is not a logout phase)", function()
    local F = T.fresh()
    local c = F.Lifecycle:New(nil, "A")
    local logout = 0
    c:OnLogout(function() logout = logout + 1 end)
    c:Destroy()
    T.eq(logout, 0, "Destroy did not invoke the logout hook")
end)

-- destroy-per-owner-logout-suppression
test("Destroy suppresses the destroyed owner's logout WHILE a live sibling's logout still fires", function()
    local F = T.fresh()
    local a = F.Lifecycle:New(nil, "A")
    local b = F.Lifecycle:New(nil, "B")
    local fr = dispatcherFrame()
    local aLogout, bLogout = 0, 0
    a:OnLogout(function() aLogout = aLogout + 1 end)
    b:OnLogout(function() bLogout = bLogout + 1 end)
    a:Destroy()   -- A opts out of all remaining phases, including logout
    T.Fire(fr, "PLAYER_LOGOUT")
    T.eq(aLogout, 0, "destroyed A's logout suppressed")
    T.eq(bLogout, 1, "live sibling B's logout STILL fired")
end)

-- destroy-owner-not-polluted
test("Destroy releases refs and leaves the owner key set unchanged", function()
    local F = T.fresh()
    local owner = { x = 1, y = 2 }
    local before = keySet(owner)
    local c = F.Lifecycle:New(owner, "A")
    c:OnLogin(noop)
    c:Destroy()
    T.eq(keySet(owner), before, "owner key set unchanged through :New + Destroy")
    T.eq(c._owner, nil, "controller released the owner ref")
end)

-- destroy-methods-fail-dev
test("after Destroy every controller method fails loudly in dev with its own message", function()
    local F = T.fresh()
    local c = F.Lifecycle:New(nil, "A")
    c:Destroy()
    T.raises(function() c:OnAddonLoaded(noop) end, "OnAddonLoaded", "destroyed controller")
    T.raises(function() c:OnLogin(noop) end, "OnLogin", "destroyed controller")
    T.raises(function() c:OnLogout(noop) end, "OnLogout", "destroyed controller")
    T.raises(function() c:GetNativeHandles() end, "GetNativeHandles", "destroyed controller")
    T.raises(function() c:Destroy() end, "Destroy", "destroyed controller")
end)

-- destroy-double-refuses
test("double Destroy refuses, not a silent second teardown", function()
    local F = T.fresh()
    local c = F.Lifecycle:New(nil, "A")
    c:Destroy()
    T.eq(c._destroyed, true, "destroyed flag set after first Destroy")
    T.raises(function() c:Destroy() end, "double destroy", "destroyed controller")
    T.eq(c._destroyed, true, "destroyed flag unchanged by the refused second Destroy")
end)

-- destroy-release-refuses
test("release build: a method after Destroy refuses without working", function()
    local F = T.fresh("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    local c = F.Lifecycle:New(nil, "A")
    c:Destroy()
    local ok = pcall(function() c:OnLogin(noop) end)
    T.truthy(ok, "no raise in release after destroy")
    T.outputContains("destroyed controller", "diagnostic printed")
    -- GetNativeHandles after destroy returns nil (guard early-returns).
    local handles
    local okG = pcall(function() handles = c:GetNativeHandles() end)
    T.truthy(okG, "no raise")
    T.eq(handles, nil, "GetNativeHandles returns nil after destroy in release")
end)

-- destroy-shared-frame-survives
test("a controller's Destroy never destroys the shared dispatcher frame; siblings keep working", function()
    local F = T.fresh()
    local a = F.Lifecycle:New(nil, "A")
    local b = F.Lifecycle:New(nil, "B")
    local fr = dispatcherFrame()
    a:Destroy()
    -- The frame is untouched: still has its three registrations and live OnEvent.
    T.eq(type(fr._onEvent), "function", "dispatcher OnEvent still attached after a controller Destroy")
    T.eq(#fr.calls.UnregisterAllEvents, 0, "shared frame never UnregisterAllEvents'd by a controller Destroy")
    -- B still works through the same live frame.
    local fired = false
    b:OnLogin(function() fired = true end)
    T.Fire(fr, "PLAYER_LOGIN")
    T.truthy(fired, "sibling B still dispatches through the shared frame")
end)

--------------------------------------------------------------------------------
-- GetNativeHandles
--------------------------------------------------------------------------------

-- gnh-shape-snapshot
test("GetNativeHandles returns the live shared frame and a read-only hook snapshot", function()
    local F = T.fresh()
    local c = F.Lifecycle:New(nil, "A")
    local fr = dispatcherFrame()
    local alFn = function() end
    c:OnAddonLoaded(alFn)
    local h = c:GetNativeHandles()
    T.eq(h.frame, fr, "frame is the live shared dispatcher")
    T.eq(type(h.hooks), "table", "hooks is a table")
    T.eq(h.hooks.addonLoaded, alFn, "hooks.addonLoaded is the registered handler")
    T.eq(h.hooks.login, nil, "no login hook registered yet")
    -- Mutating the snapshot cannot affect live dispatch.
    h.hooks.addonLoaded = nil
    h.hooks.login = function() error("never") end
    local fired = 0
    -- The real registered addon-loaded still fires (snapshot mutation ignored).
    -- (Use a fresh controller because alFn was a no-op; re-prove via a counting fn.)
    local c2 = F.Lifecycle:New(nil, "B")
    local fired2 = 0
    c2:OnAddonLoaded(function() fired2 = fired2 + 1 end)
    local h2 = c2:GetNativeHandles()
    h2.hooks.addonLoaded = nil   -- mutate snapshot
    T.Fire(fr, "ADDON_LOADED", "B")
    T.eq(fired2, 1, "snapshot mutation did not affect live dispatch")
    T.eq(fired, 0, "the injected snapshot login was never dispatched")
end)

-- gnh-same-frame-identity
test("two controllers' GetNativeHandles().frame are the SAME shared identity (inverse of Events)", function()
    local F = T.fresh()
    local a = F.Lifecycle:New(nil, "A")
    local b = F.Lifecycle:New(nil, "B")
    local ha, hb = a:GetNativeHandles(), b:GetNativeHandles()
    T.eq(ha.frame, hb.frame, "both controllers see the SAME dispatcher frame (shared by design)")
    -- But each gets its own distinct hook snapshot table.
    T.truthy(ha.hooks ~= hb.hooks, "distinct per-controller hook snapshots")
end)

--------------------------------------------------------------------------------
-- Dev-only _TestFire seam (Phase F.2 release-axis coverage)
--
-- _TestFire is the in-game analogue of T.Fire: it drives a startup phase through
-- the LIVE shared dispatcher's real OnEvent path WITHOUT touching the frame's
-- event registration, so the dev-gated self-test can exercise phases the player
-- cannot replay. It MUST be hard-gated on F.IS_DEV_BUILD so the instrument can
-- never become a player-reachable phase injector in a release build.
--------------------------------------------------------------------------------

-- testfire-dev-drives-phase
test("_TestFire (dev) drives a phase through the LIVE dispatcher without touching registration", function()
    local F = T.fresh()
    T.truthy(F.IS_DEV_BUILD, "dev build")
    local c = F.Lifecycle:New(nil, "A")
    local fr = dispatcherFrame()
    local regBefore = #fr.calls.RegisterEvent
    local al, lo, lg = 0, 0, 0
    c:OnAddonLoaded(function() al = al + 1 end)
    c:OnLogin(function() lo = lo + 1 end)
    c:OnLogout(function() lg = lg + 1 end)
    -- Each phase fires through the real demux/fan-out, exactly as T.Fire would.
    F.Lifecycle:_TestFire("addon-loaded", "A")
    F.Lifecycle:_TestFire("login")
    F.Lifecycle:_TestFire("logout")
    T.eq(al, 1, "addon-loaded fired via _TestFire")
    T.eq(lo, 1, "login fired via _TestFire")
    T.eq(lg, 1, "logout fired via _TestFire")
    -- The seam NEVER registers events: the registration count is unchanged and no
    -- second frame was created (it drives the existing live frame's OnEvent only).
    T.eq(#fr.calls.RegisterEvent, regBefore, "_TestFire added NO event registration")
    T.eq(#T.frames, 1, "_TestFire created no new frame")
end)

-- testfire-release-refuses
test("_TestFire REFUSES in a release build (prints, fires nothing) — never a player phase injector", function()
    local F = T.fresh("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    local c = F.Lifecycle:New(nil, "A")
    local fired = 0
    c:OnLogin(function() fired = fired + 1 end)
    -- Release: the dev-only gate fires FIRST; it prints a diagnostic, returns, and
    -- drives no phase. This is the guarantee that the seam cannot inject phases
    -- into a player's session.
    local ok = pcall(function() F.Lifecycle:_TestFire("login") end)
    T.truthy(ok, "release _TestFire does not raise")
    T.outputContains("dev-build only", "release _TestFire printed the dev-only refusal")
    T.eq(fired, 0, "release _TestFire fired NO phase")
    -- The real signal path is unaffected: a genuine PLAYER_LOGIN still works.
    T.Fire(dispatcherFrame(), "PLAYER_LOGIN")
    T.eq(fired, 1, "the real dispatcher path is untouched by the refused _TestFire")
end)

-- testfire-dev-raises-in-release-build-via-override
test("_TestFire refusal is gated on IS_DEV_BUILD, not the build axis literal: override release stays usable", function()
    -- A forced dev build on a real version string (override) is still a dev build,
    -- so _TestFire works — proving the gate keys on IS_DEV_BUILD, the single source
    -- of truth, not on the raw token.
    T.installMocks("9.9.9"); _G.FOUNDRY_DEV_BUILD_OVERRIDE = true
    local F = T.loadFoundry()
    T.truthy(F.IS_DEV_BUILD, "override forces dev on a real version")
    local c = F.Lifecycle:New(nil, "A")
    local lo = 0
    c:OnLogin(function() lo = lo + 1 end)
    F.Lifecycle:_TestFire("login")
    T.eq(lo, 1, "_TestFire drives the phase under a forced-dev override")
end)

-- testfire-guards
test("_TestFire (dev) refuses before any dispatcher exists and rejects an unknown phase", function()
    local F = T.fresh()
    -- No :New yet -> no dispatcher -> refuse loudly (nothing to drive).
    T.raises(function() F.Lifecycle:_TestFire("login") end, "no dispatcher", "no dispatcher yet")
    -- With a dispatcher, an unknown phase is rejected; 'addon-loaded' needs a name.
    F.Lifecycle:New(nil, "A")
    T.raises(function() F.Lifecycle:_TestFire("bogus") end, "unknown phase", "unknown phase")
    T.raises(function() F.Lifecycle:_TestFire("addon-loaded") end, "missing name", "requires a non-empty addonName")
end)

--------------------------------------------------------------------------------
-- Owner-pollution net (consolidated)
--------------------------------------------------------------------------------

-- pollution-net
test("owner key set is unchanged after EACH of addon-loaded -> login -> logout -> Destroy", function()
    local F = T.fresh()
    local owner = { realKey = 1, anotherKey = noop }
    local before = keySet(owner)
    local c = F.Lifecycle:New(owner, "A")
    local fr = dispatcherFrame()
    c:OnAddonLoaded(noop)
    c:OnLogin(noop)
    c:OnLogout(noop)
    T.eq(keySet(owner), before, "unchanged after :New + hook registration")
    T.Fire(fr, "ADDON_LOADED", "A")
    T.eq(keySet(owner), before, "unchanged after addon-loaded")
    T.Fire(fr, "PLAYER_LOGIN")
    T.eq(keySet(owner), before, "unchanged after login")
    T.Fire(fr, "PLAYER_LOGOUT")
    T.eq(keySet(owner), before, "unchanged after logout")
    c:Destroy()
    T.eq(keySet(owner), before, "unchanged after Destroy")
end)

--------------------------------------------------------------------------------
-- Hostile-review regression (findings 1-4, 2026-06-03)
--
-- These lock four bugs the out-of-game harness originally missed because its
-- mocks/cases did not model the real semantics. Each FAILED against the first
-- B+C implementation and PASSES against the fix.
--   1. Premature addon-loaded fire: catch-up gated on IsAddOnLoaded's FIRST
--      return (loadedOrLoading), firing mid-load before SavedVariables exist.
--   2. Falsy hook-error silently swallowed: `if err then surface` dropped
--      error(nil)/error(false)/error() (a §3.4.1 fail-loud violation).
--   3. Re-entrancy skip: inserting into loginControllers during a pairs() fan-out
--      (a hook that :New+:OnLogin a controller) skipped existing subscribers.
--   4. Post-fire re-register accepted: the one-shot cleared the hook slot, so the
--      "already registered" guard went blind and a second OnX after fire slipped.
--------------------------------------------------------------------------------

-- finding-1-no-premature-fire-while-loading
test("finding-1: addon-loaded catch-up does NOT fire while the addon is merely LOADING (IsAddOnLoaded 2nd return)", function()
    local F = T.fresh()
    T.loadedAddons["A"] = "loading"   -- (loadedOrLoading=true, loaded=false)
    local c = F.Lifecycle:New(nil, "A")
    local fired = 0
    c:OnAddonLoaded(function() fired = fired + 1 end)
    T.eq(fired, 0, "NO premature fire mid-load (SavedVariables not yet available)")
    -- the controller stays enrolled; the REAL ADDON_LOADED fires it once
    T.Fire(dispatcherFrame(), "ADDON_LOADED", "A")
    T.eq(fired, 1, "fires once on the real ADDON_LOADED")
    T.Fire(dispatcherFrame(), "ADDON_LOADED", "A")
    T.eq(fired, 1, "one-shot: a second real ADDON_LOADED does not re-fire")
end)

-- finding-1-catchup-when-finished
test("finding-1: addon-loaded catch-up DOES fire when the addon has FINISHED loading (2nd return true)", function()
    local F = T.fresh()
    T.loadedAddons["A"] = true        -- (loadedOrLoading=true, loaded=true)
    local c = F.Lifecycle:New(nil, "A")
    local fired = 0
    c:OnAddonLoaded(function() fired = fired + 1 end)
    T.eq(fired, 1, "catch-up fires synchronously when finished loading")
    T.Fire(dispatcherFrame(), "ADDON_LOADED", "A")
    T.eq(fired, 1, "no double-fire from a later real ADDON_LOADED")
end)

-- finding-2-falsy-login-error-dev
test("finding-2: (dev) a login hook that error(nil)s STILL surfaces AND the fan-out completes (no silent swallow)", function()
    local F = T.fresh()
    local aRan, bRan = false, false
    local ca = F.Lifecycle:New(nil, "A"); ca:OnLogin(function() aRan = true; error(nil) end)
    local cb = F.Lifecycle:New(nil, "B"); cb:OnLogin(function() bRan = true end)
    -- dev: the captured FALSY error is surfaced AFTER the fan-out -> RaiseDevError raises
    T.raises(function() T.Fire(dispatcherFrame(), "PLAYER_LOGIN") end, "falsy login error surfaces", "phase hook errored")
    T.truthy(aRan, "controller A ran")
    T.truthy(bRan, "controller B STILL ran (fan-out completed despite A's falsy error)")
end)

-- finding-2-falsy-login-error-release
test("finding-2: (release) a login hook that error(false)s STILL prints a diagnostic (never swallowed)", function()
    local F = T.fresh("1.0.0")
    local bRan = false
    local ca = F.Lifecycle:New(nil, "A"); ca:OnLogin(function() error(false) end)
    local cb = F.Lifecycle:New(nil, "B"); cb:OnLogin(function() bRan = true end)
    T.Fire(dispatcherFrame(), "PLAYER_LOGIN")   -- release: prints, never raises
    T.truthy(bRan, "controller B ran")
    T.outputContains("phase hook errored", "the falsy error was surfaced (printed), not swallowed")
end)

-- finding-2-falsy-addonloaded-error-dev
test("finding-2: (dev) a bare error() in an addon-loaded hook surfaces on the single-fire path", function()
    local F = T.fresh()
    local c = F.Lifecycle:New(nil, "A")
    c:OnAddonLoaded(function() error() end)   -- bare error -> pcall returns (false, nil)
    T.raises(function() T.Fire(dispatcherFrame(), "ADDON_LOADED", "A") end,
        "falsy addon-loaded error surfaces", "phase hook errored")
end)

-- finding-3-reentrant-newborn-no-skip
test("finding-3: a hook that :New+:OnLogin a controller mid-fan-out skips NO existing subscriber (snapshot)", function()
    local F = T.fresh()
    local N = 32
    local fired = {}
    for i = 1, N do
        local name = "C" .. i
        fired[name] = 0
        local c = F.Lifecycle:New(nil, name)
        c:OnLogin(function()
            fired[name] = fired[name] + 1
            if i == N then
                -- register a NEWBORN controller mid-fan-out (mutates loginControllers)
                local nc = F.Lifecycle:New(nil, "Newborn")
                nc:OnLogin(function() fired["Newborn"] = (fired["Newborn"] or 0) + 1 end)
            end
        end)
    end
    T.Fire(dispatcherFrame(), "PLAYER_LOGIN")
    local missed = 0
    for i = 1, N do if fired["C" .. i] ~= 1 then missed = missed + 1 end end
    T.eq(missed, 0, "every existing controller's login hook fired exactly once (no skip)")
    T.eq(fired["Newborn"], 1, "the mid-fan-out newborn fired exactly once via catch-up")
end)

-- finding-4-postfire-reregister-rejected-login
test("finding-4: re-registering a login hook AFTER it fired is rejected (one hook per phase, even post-fire)", function()
    local F = T.fresh()
    local c = F.Lifecycle:New(nil, "A")
    c:OnLogin(noop)
    T.Fire(dispatcherFrame(), "PLAYER_LOGIN")   -- fires + one-shot clears the live hook slot
    T.raises(function() c:OnLogin(noop) end, "post-fire login re-register rejected", "already registered")
end)

-- finding-4-postfire-reregister-rejected-addonloaded
test("finding-4: re-registering an addon-loaded hook AFTER it fired is rejected", function()
    local F = T.fresh()
    local c = F.Lifecycle:New(nil, "A")
    c:OnAddonLoaded(noop)
    T.Fire(dispatcherFrame(), "ADDON_LOADED", "A")
    T.raises(function() c:OnAddonLoaded(noop) end, "post-fire addon-loaded re-register rejected", "already registered")
end)

return tests

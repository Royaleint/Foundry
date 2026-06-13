-- Foundry.Lifecycle
--
-- The AceAddon-3.0 replacement: addon-object creation plus correctly-timed
-- startup callbacks. A single Foundry-private dispatcher frame owns the three
-- WoW startup signals (ADDON_LOADED / PLAYER_LOGIN / PLAYER_LOGOUT) once for the
-- whole library; per-owner controllers subscribe to phase hooks over it. This
-- keeps 100+ consumers O(1) per startup signal (ADDON_LOADED is demuxed by
-- addon name, never a wake-up storm). The native dispatcher frame stays
-- reachable underneath via :GetNativeHandles().
--
-- Three HONEST raw-signal hooks, named after the WoW events they bridge:
-- :OnAddonLoaded, :OnLogin, :OnLogout. There is deliberately no "ready" hook
-- (DB loaded + defaults + migrations) -- that guarantee cannot be true until
-- Foundry.DB lands; naming one now would imply a guarantee not yet carried.

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: Lifecycle.lua requires the Foundry-1.0 bootstrap (Foundry.lua) "
        .. "to have loaded first; _G.Foundry_1_0 is missing.", 0)
end
-- Guarded-embedding stand-down (§2.2b): if this module is already registered on the
-- winning copy, this is a redundant embedded copy — load nothing. Silent no-op on
-- the first load (not registered yet). Zero new surface on F (HasModule already exists).
if F:HasModule("Lifecycle") then return end

local Lifecycle = {}
Lifecycle.API_VERSION = 1

--------------------------------------------------------------------------------
-- Shared private dispatcher (one set of upvalues per loaded library)
--------------------------------------------------------------------------------

-- These upvalues are shared across every controller this library hands out.
-- The dispatcher frame is created LAZILY on the first :New (module load
-- registers nothing -- consistent with Events creating no frame until needed).
local dispatcher = nil       -- the single CreateFrame("Frame"), created on first New
local byAddonName = {}        -- addonName -> controller  (PENDING ADDON_LOADED demux only; cleared one-shot on fire)
local ownedNames = {}         -- addonName -> controller  (PERSISTENT: lives until Destroy; backs re-register rejection)
local loginControllers = {}   -- controller -> true  (set: who wants login/logout phases)
local loginFired = false      -- central "PLAYER_LOGIN already fired" flag
local postLogout = {}          -- array of private post-logout callbacks (Cycle-3 DB strip seam)

-- Surface a captured hook error through F:RaiseDevError. The captured value may
-- be ANY Lua value -- INCLUDING a falsy one (a hook that called error(nil),
-- error(false), or bare error()). The dispatcher must NEVER decide whether to
-- surface by testing the captured value's truthiness -- that silently swallows a
-- falsy error (a Charter §3.4.1 fail-loud violation). The boolean "raised" flag
-- returned by each _fire* is the sole gate; this helper normalizes the value into
-- a non-empty diagnostic so a surfaced error is always meaningful.
local function surfaceHookError(phase, err)
    F:RaiseDevError("Lifecycle: a '" .. phase .. "' phase hook errored: " .. tostring(err))
end

-- Lazily create and wire the single shared dispatcher frame. Idempotent: every
-- call after the first returns without touching the existing frame, so the
-- three RegisterEvent calls happen exactly once for the whole library.
local function ensureDispatcher()
    if dispatcher then return end

    local frame = CreateFrame("Frame")
    frame:Hide()

    -- Demux by event name, then (for ADDON_LOADED) by addon name. Each _fire*
    -- CAPTURES-AND-RETURNS its subscriber's error (never throws inline); the
    -- dispatcher surfaces captured errors only AFTER the fan-out completes, so
    -- one bad hook cannot abort the loop and starve the other consumers' phases
    -- (the locked continue-on-error contract).
    frame:SetScript("OnEvent", function(_, event, ...)
        if event == "ADDON_LOADED" then
            local loadedName = ...
            local c = byAddonName[loadedName]   -- O(1) demux; nil for addons we don't track
            if c then
                byAddonName[loadedName] = nil   -- one-shot demux clear (ownedNames KEPT)
                local raised, err = c:_fireAddonLoaded() -- single fire; raised flag, never thrown inline
                if raised then surfaceHookError("addon-loaded", err) end
            end
        elseif event == "PLAYER_LOGIN" then
            loginFired = true                   -- central flag, set once
            -- SNAPSHOT the subscriber set BEFORE the fan-out: a hook may New +
            -- OnLogin a controller mid-loop, mutating loginControllers DURING the
            -- traversal. In Lua 5.1, assigning a new key while iterating a table
            -- with pairs() is undefined and can SKIP existing entries, starving
            -- other consumers' phases. Iterating a pre-fan-out array copy fixes the
            -- membership at fire time; a controller registered mid-fan-out is
            -- intentionally NOT in this snapshot and catches up synchronously in
            -- OnLogin (loginFired is already true).
            local snapshot, n = {}, 0
            for c in pairs(loginControllers) do n = n + 1; snapshot[n] = c end
            local raised, firstErr = false, nil
            for i = 1, n do
                local r, e = snapshot[i]:_fireLogin() -- never aborts; returns (raised, err)
                if r and not raised then raised, firstErr = true, e end
            end
            if raised then surfaceHookError("login", firstErr) end  -- surface ONLY after the full fan-out
        elseif event == "PLAYER_LOGOUT" then
            local snapshot, n = {}, 0
            for c in pairs(loginControllers) do n = n + 1; snapshot[n] = c end
            local raised, firstErr = false, nil
            for i = 1, n do
                local r, e = snapshot[i]:_fireLogout()
                if r and not raised then raised, firstErr = true, e end
            end
            -- Post-logout fan-out (private seam). Runs strictly AFTER the consumer
            -- logout fan-out completes -- so a consumer's final writes are in place
            -- before the DB strip walks them (spec §6.4 contract 2) -- and strictly
            -- BEFORE the deferred surfacing below: in a dev build surfaceHookError
            -- raises, which would abort this branch and skip the strip whenever a
            -- consumer logout hook errored, defeating the continue-on-error contract
            -- the strip depends on (spec §6.4 contract 1). Each callback is captured
            -- so one cannot starve another or the surfacing; a raised post-logout
            -- callback is surfaced after the loop on its own gate (the registrant --
            -- DB -- owns finer pcall-per-store isolation beneath this).
            local plRaised, plFirstErr = false, nil
            for i = 1, #postLogout do
                local ok, e = pcall(postLogout[i])
                if not ok and not plRaised then plRaised, plFirstErr = true, e end
            end
            if raised then surfaceHookError("logout", firstErr) end
            if plRaised then surfaceHookError("post-logout", plFirstErr) end
        end
    end)

    frame:RegisterEvent("ADDON_LOADED")
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:RegisterEvent("PLAYER_LOGOUT")

    dispatcher = frame
end

-- Private post-logout-fan-out registration seam (Cycle-3 deliverable; spec §6.4,
-- plan R2). Internal surface only -- the dot-call underscore name keeps it off
-- the public controller API, so Lifecycle.API_VERSION stays 1 (the _TestFire
-- precedent). Foundry.DB registers its logout strip here exactly once, at its
-- first :New. It calls ensureDispatcher() itself so the dispatcher and its
-- PLAYER_LOGOUT registration exist even for a DB-only consumer that never calls
-- Lifecycle:New -- otherwise that consumer's strip would never be delivered
-- (spec §6.4 contract 1 holds Lifecycle-controller-or-not). The registered
-- callbacks run after the consumer logout fan-out and before deferred error
-- surfacing (see the PLAYER_LOGOUT branch above).
function Lifecycle._RegisterPostLogout(fn)
    if type(fn) ~= "function" then
        F:RaiseDevError("Lifecycle._RegisterPostLogout: fn must be a function")
        return
    end
    ensureDispatcher()
    postLogout[#postLogout + 1] = fn
end

--------------------------------------------------------------------------------
-- Controller
--------------------------------------------------------------------------------

local Controller = {}
Controller.__index = Controller

-- Private fire wrappers the dispatcher calls. Each pcall-wraps the SUBSCRIBER's
-- handler and RETURNS (raised, err): a boolean RAISED flag plus the captured
-- value -- which may itself be FALSY (a hook that called error(nil), error(false),
-- or bare error()). The dispatcher gates surfacing on the RAISED flag, never the
-- value's truthiness, so a falsy error is never silently swallowed. The wrapper
-- never calls RaiseDevError itself un-pcall'd: in a dev build RaiseDevError
-- error()s, which would abort the dispatcher's fan-out loop and starve the
-- remaining subscribers. The dispatcher surfaces the captured error AFTER the
-- fan-out. A controller unsubscribed mid-loop (Destroy) is skipped. Each phase is
-- one-shot: the hook is cleared before invocation so a second signal does not
-- re-fire it.

function Controller:_fireAddonLoaded()
    if self._destroyed then return false end
    local fn = self._hooks.addonLoaded
    if not fn then return false end
    self._hooks.addonLoaded = nil   -- one-shot: free the slot before invoking
    local ok, err = pcall(fn, self._owner)
    if not ok then return true, err end   -- RAISED (err may be nil/false); the flag is the gate
    return false
end

function Controller:_fireLogin()
    if self._destroyed then return false end
    local fn = self._hooks.login
    if not fn then return false end
    self._hooks.login = nil
    local ok, err = pcall(fn, self._owner)
    if not ok then return true, err end
    return false
end

function Controller:_fireLogout()
    if self._destroyed then return false end
    local fn = self._hooks.logout
    if not fn then return false end
    self._hooks.logout = nil
    local ok, err = pcall(fn, self._owner)
    if not ok then return true, err end
    return false
end

-- Register the one-shot addon-loaded hook. Fires once when ADDON_LOADED matches
-- addonName, OR immediately via catch-up if the addon is already loaded. A
-- second registration is rejected via RaiseDevError (one hook per phase per
-- controller; mirrors Events' one-handler-per-event). Validation is atomic: a
-- rejected call mutates nothing.
function Controller:OnAddonLoaded(handler)
    if self._destroyed then
        F:RaiseDevError("Lifecycle:OnAddonLoaded called on a destroyed controller")
        return
    end
    if type(handler) ~= "function" then
        F:RaiseDevError("Lifecycle:OnAddonLoaded: handler must be a function")
        return
    end
    if self._registered.addonLoaded then
        F:RaiseDevError("Lifecycle:OnAddonLoaded: an addon-loaded hook is already "
            .. "registered for '" .. self._addonName .. "'; one hook per phase per controller")
        return
    end

    self._registered.addonLoaded = true
    self._hooks.addonLoaded = handler

    -- Load-on-Demand catch-up: fire now ONLY if the addon has FINISHED loading.
    -- C_AddOns.IsAddOnLoaded returns TWO booleans, (loadedOrLoading, loaded): the
    -- FIRST is true while the addon is still LOADING. Gating on it would fire the
    -- addon-loaded hook mid-load -- BEFORE SavedVariables are available -- which
    -- defeats the hook's whole purpose (a consumer registering for its OWN addon
    -- during that addon's own file load is exactly this case). Gate on the SECOND
    -- value (finished loading). A still-loading or not-yet-loaded addon stays
    -- enrolled in byAddonName and fires on the real ADDON_LOADED. The catch-up is
    -- synchronous inside this registration call.
    local alreadyLoaded = false
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        local _, loaded = C_AddOns.IsAddOnLoaded(self._addonName)
        alreadyLoaded = (loaded == true)
    end
    if alreadyLoaded then
        byAddonName[self._addonName] = nil
        local raised, err = self:_fireAddonLoaded()
        if raised then surfaceHookError("addon-loaded", err) end
    end
end

-- Register the one-shot player-login hook. Fires once on PLAYER_LOGIN, OR
-- immediately via catch-up if login already fired. Adds the controller to the
-- login/logout broadcast set. Re-register rejected. Validation is atomic.
function Controller:OnLogin(handler)
    if self._destroyed then
        F:RaiseDevError("Lifecycle:OnLogin called on a destroyed controller")
        return
    end
    if type(handler) ~= "function" then
        F:RaiseDevError("Lifecycle:OnLogin: handler must be a function")
        return
    end
    if self._registered.login then
        F:RaiseDevError("Lifecycle:OnLogin: a login hook is already registered for '"
            .. self._addonName .. "'; one hook per phase per controller")
        return
    end

    self._registered.login = true
    self._hooks.login = handler
    loginControllers[self] = true

    -- Login catch-up: if PLAYER_LOGIN already fired, fire now (synchronously).
    -- This is the central replacement for a consumer hand-rolling a post-login
    -- retry timer.
    if loginFired then
        local raised, err = self:_fireLogin()
        if raised then surfaceHookError("login", err) end
    end
end

-- Register the one-shot player-logout hook. Fires once on PLAYER_LOGOUT. Adds
-- the controller to the login/logout broadcast set. Re-register rejected.
-- Logout is a game-signal phase; it is NOT fired by Destroy. Validation is
-- atomic.
function Controller:OnLogout(handler)
    if self._destroyed then
        F:RaiseDevError("Lifecycle:OnLogout called on a destroyed controller")
        return
    end
    if type(handler) ~= "function" then
        F:RaiseDevError("Lifecycle:OnLogout: handler must be a function")
        return
    end
    if self._registered.logout then
        F:RaiseDevError("Lifecycle:OnLogout: a logout hook is already registered for '"
            .. self._addonName .. "'; one hook per phase per controller")
        return
    end

    self._registered.logout = true
    self._hooks.logout = handler
    loginControllers[self] = true
end

-- The progressive-disclosure escape hatch. Returns the live SHARED dispatcher
-- frame and a shallow read-only snapshot of this controller's hook set. Mutating
-- the snapshot cannot affect live dispatch; the frame, by contrast, is the live
-- shared object (two controllers' .frame return the same identity by design --
-- the inverse of Events' per-controller frame).
function Controller:GetNativeHandles()
    if self._destroyed then
        F:RaiseDevError("Lifecycle:GetNativeHandles called on a destroyed controller")
        return
    end
    local snapshot = {
        addonLoaded = self._hooks.addonLoaded,
        login = self._hooks.login,
        logout = self._hooks.logout,
    }
    return {
        frame = dispatcher,
        hooks = snapshot,
    }
end

-- Tear down: unsubscribe from every dispatcher table, release refs, mark
-- destroyed. After this, every controller method fails loudly in dev /
-- refuses-and-prints in release (mirrors Events' destroyed-controller guard).
-- Releasing the addonName from ownedNames lets a later :New reuse it.
-- Explicitly DOES NOT fire the logout hook: Destroy opts the owner out of all
-- remaining phases, including logout. The shared dispatcher frame is never
-- destroyed by a controller's Destroy -- it is library state, kept alive for the
-- session. Double-Destroy refuses.
function Controller:Destroy()
    if self._destroyed then
        F:RaiseDevError("Lifecycle:Destroy called on a destroyed controller")
        return
    end
    byAddonName[self._addonName] = nil
    ownedNames[self._addonName] = nil
    loginControllers[self] = nil
    self._hooks = {}
    self._registered = {}
    self._owner = nil
    self._destroyed = true
end

--------------------------------------------------------------------------------
-- Factory
--------------------------------------------------------------------------------

-- Create a per-owner controller. PRIMARY form adopts an EXISTING table: owner is
-- the consumer's real addon table (Homestead's HA.Addon, BawrSpam's NS). The
-- secondary form (omit/pass nil owner) yields a plain {} controller-only object.
-- GUARDRAIL: Lifecycle writes NOTHING into owner; all bookkeeping lives on the
-- controller and the dispatcher upvalues. addonName is the TOC addon name used
-- as the ADDON_LOADED demux key. A second :New for an addonName that already
-- owns a live Lifecycle is rejected via RaiseDevError (checks the PERSISTENT
-- ownedNames registry, not the one-shot byAddonName demux, so the guard holds
-- for the controller's whole life -- before OR after its addon-loaded fires).
function Lifecycle:New(owner, addonName)
    if owner ~= nil and type(owner) ~= "table" then
        F:RaiseDevError("Lifecycle:New: owner, when supplied, must be a table")
        return
    end
    if type(addonName) ~= "string" or addonName == "" then
        F:RaiseDevError("Lifecycle:New: addonName must be a non-empty string")
        return
    end
    if ownedNames[addonName] then
        F:RaiseDevError("Lifecycle:New: addonName '" .. addonName
            .. "' already owns a live Lifecycle controller; Destroy it first to re-register")
        return
    end

    ensureDispatcher()

    local c = setmetatable({}, Controller)
    c._owner = owner or {}
    c._addonName = addonName
    c._hooks = {}
    -- _registered persists a phase's registration for the controller's whole life,
    -- separate from _hooks (which the one-shot fire CLEARS). The re-register guard
    -- checks _registered, so a SECOND OnX is rejected even AFTER its phase fired --
    -- the cleared _hooks slot must not silently reopen registration.
    c._registered = { addonLoaded = false, login = false, logout = false }
    c._destroyed = false

    -- Enrol for the PENDING ADDON_LOADED demux and the PERSISTENT re-register
    -- registry. If the addon is already loaded, OnAddonLoaded's catch-up clears
    -- the byAddonName entry at hook-registration time.
    byAddonName[addonName] = c
    ownedNames[addonName] = c

    return c
end

--------------------------------------------------------------------------------
-- Dev-only test seam
--------------------------------------------------------------------------------

-- The in-game analogue of the out-of-game harness's T.Fire: drive a startup
-- phase through the LIVE shared dispatcher's real OnEvent path WITHOUT touching
-- the frame's event registration (no fake RegisterEvent, no second frame). This
-- exists so the otherwise-unobservable phases (ADDON_LOADED cannot replay without
-- a client restart; PLAYER_LOGOUT ends the session) can be exercised by the
-- dev-gated Lifecycle self-test (Dev/LifecycleSelfTest.lua).
--
-- TRIPLE-GATED below the public surface and HARD-gated on F.IS_DEV_BUILD: in a
-- release build it routes to F:RaiseDevError and does nothing, so it can never
-- become a player-reachable phase injector. It also refuses if no :New has yet
-- created the dispatcher (nothing to drive).
--
-- `phase` is one of "addon-loaded" | "login" | "logout"; for "addon-loaded",
-- `addonName` is the demux key the dispatcher matches (mirrors the WoW payload).
function Lifecycle:_TestFire(phase, addonName)
    if not F.IS_DEV_BUILD then
        F:RaiseDevError("Lifecycle:_TestFire is dev-build only and must never run in a "
            .. "release build (it is a phase injector)")
        return
    end
    if not dispatcher or not dispatcher:GetScript("OnEvent") then
        F:RaiseDevError("Lifecycle:_TestFire: no dispatcher yet; create a controller "
            .. "with :New before firing a phase")
        return
    end

    local onEvent = dispatcher:GetScript("OnEvent")
    if phase == "addon-loaded" then
        if type(addonName) ~= "string" or addonName == "" then
            F:RaiseDevError("Lifecycle:_TestFire: 'addon-loaded' requires a non-empty addonName")
            return
        end
        onEvent(dispatcher, "ADDON_LOADED", addonName)
    elseif phase == "login" then
        onEvent(dispatcher, "PLAYER_LOGIN")
    elseif phase == "logout" then
        onEvent(dispatcher, "PLAYER_LOGOUT")
    else
        F:RaiseDevError("Lifecycle:_TestFire: unknown phase '" .. tostring(phase)
            .. "'; expected 'addon-loaded', 'login', or 'logout'")
    end
end

F:RegisterModule("Lifecycle", Lifecycle)

-- Foundry.Lifecycle
--
-- The AceAddon-3.0 replacement: addon-object creation plus correctly-timed
-- startup callbacks. A single Foundry-private dispatcher frame owns the three
-- core WoW startup signals (ADDON_LOADED / PLAYER_LOGIN / PLAYER_LOGOUT), plus
-- ADDONS_UNLOADING where the client validates it, once for the
-- whole library; per-owner controllers subscribe to phase hooks over it. This
-- keeps 100+ consumers O(1) per startup signal (ADDON_LOADED is demuxed by
-- addon name, never a wake-up storm). The native dispatcher frame stays
-- reachable underneath via :GetNativeHandles().
--
-- Four HONEST raw-signal hooks, named after the WoW events they bridge:
-- :OnAddonLoaded, :OnLogin, :OnUnloading, :OnLogout. OnUnloading is available
-- only where ADDONS_UNLOADING is a valid client event; it does not promise an
-- ordering relation with PLAYER_LOGOUT. There is deliberately no "ready" hook
-- (DB loaded + defaults + migrations) -- that guarantee cannot be true until
-- Foundry.DB lands; naming one now would imply a guarantee not yet carried.
--
-- addon-loaded can wait: on some clients, ADDON_LOADED (and even
-- PLAYER_ENTERING_WORLD) can fire before the client has resolved the
-- player's own name and realm -- a fresh client session logs in with the
-- character's identity still unresolved for a moment. A controller that
-- reaches ADDON_LOADED while that identity is unresolved is held rather than
-- fired; it releases (addon-loaded, then login if login already fired) the
-- moment the name and realm are known, so a consumer that constructs its
-- database in the addon-loaded hook, as the docs direct, never gets handed a
-- refused construction over a placeholder name. Where identity is already
-- known at ADDON_LOADED -- every case but that one -- nothing is held, no
-- extra events are registered, and no timer runs.

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: Lifecycle.lua requires the Foundry-1.0 bootstrap (Foundry.lua) "
        .. "to have loaded first; _G.Foundry_1_0 is missing.", 0)
end
-- Guarded-embedding stand-down (§2.2b): if this module is already registered on the
-- winning copy, this is a redundant embedded copy — load nothing.
if F:HasModule("Lifecycle") then return end

local Lifecycle = {}
Lifecycle.API_VERSION = 3

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
local unloadingControllers = {} -- registration-ordered controllers who want the pre-unload phase
local unloadingSupported = false
local loginFired = false      -- central "PLAYER_LOGIN already fired" flag
local postLogout = {}          -- array of private post-logout callbacks (DB strip seam)

-- Identity-hold state (addon-loaded can wait, see the header note above).
local identityHeld = {}       -- ordered array of controllers held for identity
local identityWatching = false  -- PLAYER_ENTERING_WORLD/UNIT_NAME_UPDATE/PLAYER_REGEN_ENABLED registered?
local pollScheduled = false    -- a C_Timer.After(1, pollTick) is already in flight
local identityStopped = false  -- set at logout/unloading: never release again this session
local devNoticePrinted = false -- the one-line dev notice fires at most once per session
Lifecycle._identityResolvedBy = nil  -- private trace: which event released the hold

-- Surface a captured hook error through F:RaiseDevError. The captured value
-- may be ANY Lua value, including a falsy one (error(nil), error(false), bare
-- error()). Surfacing must gate on the boolean "raised" flag each _fire*
-- returns, never on the value's truthiness -- truthiness would silently
-- swallow a falsy error (Charter §3.4.1).
local function surfaceHookError(phase, err)
    F:RaiseDevError("Lifecycle: a '" .. phase .. "' phase hook errored: " .. tostring(err))
end

-- Resolve the running character's name and realm AT CALL TIME (never cached,
-- never upvalued at file scope). Foundry.DB's identity gate shares this exact
-- check, so "what counts as resolved" has one definition. A client that has
-- not yet resolved the player's own unit -- observed on a cold client-session
-- login -- reports nil, "", or the literal "Unknown"; a non-English client
-- reports its own localized placeholder instead (the same value the client
-- itself compares a unit name against elsewhere). Returns (name, realm) on
-- success, or (nil, msg) on refusal. No side effects.
function Lifecycle._PlayerIdentity()
    local name = UnitName("player")
    local realm = GetRealmName()
    local unknown = _G.UNKNOWNOBJECT
    if type(unknown) ~= "string" then unknown = nil end

    if type(name) ~= "string" or name == "" or name == "Unknown" or (unknown and name == unknown) then
        return nil, "player identity is not available yet (UnitName returned '" .. tostring(name) .. "')"
    end
    if type(realm) ~= "string" or realm == "" or realm == "Unknown" or (unknown and realm == unknown) then
        return nil, "realm identity is not available yet (GetRealmName returned '" .. tostring(realm) .. "')"
    end
    return name, realm
end

-- Forward-declared: schedulePoll and pollTick call each other and are called
-- by holdForIdentity below, before either gets its real body further down.
local schedulePoll
local pollTick

-- Register the shared watch events the first time any controller is held,
-- idempotent per controller. A login-only controller (one that never calls
-- OnAddonLoaded) is held here too, via the ADDON_LOADED dispatch's demux
-- entry: its login then waits for identity as well, since a login-phase
-- construct benefits from the same hold.
local function holdForIdentity(c)
    if c._identityHeld then return end
    c._identityHeld = true
    identityHeld[#identityHeld + 1] = c
    if not identityWatching then
        dispatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
        dispatcher:RegisterUnitEvent("UNIT_NAME_UPDATE", "player")
        dispatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
        identityWatching = true
    end
    -- PLAYER_ENTERING_WORLD may already be past (a controller can be held
    -- after login, e.g. an LoD catch-up); the poll covers that gap.
    if loginFired then
        schedulePoll()
    end
end

-- Unregister the watch events. Called on release, when Destroy empties the
-- held list, and at logout/unloading. A pending poll tick still fires (the
-- WoW API's C_Timer.After, unlike C_Timer.NewTimer, gives no cancel handle),
-- but no-ops through identityStopped or an empty list.
local function stopWatching()
    if not identityWatching then return end
    dispatcher:UnregisterEvent("PLAYER_ENTERING_WORLD")
    dispatcher:UnregisterEvent("UNIT_NAME_UPDATE")
    dispatcher:UnregisterEvent("PLAYER_REGEN_ENABLED")
    identityWatching = false
end

-- Release every held controller if identity now resolves. Returns false (and
-- releases nothing) if the list is empty, the session already stopped
-- releasing (logout/unloading), the player is in combat (Foundry is a shared
-- library; a consumer that creates secure frames at startup would hit
-- ADDON_ACTION_BLOCKED if release ran during a reconnect into combat), or
-- identity still fails to resolve. Otherwise fans out addon-loaded first,
-- then login (only if PLAYER_LOGIN already fired), and returns
-- (true, alRaised, alErr, lgRaised, lgErr) -- it NEVER surfaces an error
-- itself; each dispatcher branch surfaces after its own state work
-- completes (addon-loaded, then login, then the branch's own error).
local function releaseIdentityHeld(eventName)
    if #identityHeld == 0 or identityStopped then return false end
    if InCombatLockdown() then return false end
    if not Lifecycle._PlayerIdentity() then return false end

    local snapshot = identityHeld
    identityHeld = {}
    stopWatching()
    Lifecycle._identityResolvedBy = eventName

    local alRaised, alErr = false, nil
    for i = 1, #snapshot do
        local c = snapshot[i]
        if not c._destroyed then
            c._identityHeld = nil
            local r, e = c:_fireAddonLoaded()
            if r and not alRaised then alRaised, alErr = true, e end
        end
    end

    local lgRaised, lgErr = false, nil
    if loginFired then
        for i = 1, #snapshot do
            local c = snapshot[i]
            if not c._destroyed then
                local r, e = c:_fireLogin()
                if r and not lgRaised then lgRaised, lgErr = true, e end
            end
        end
    end

    return true, alRaised, alErr, lgRaised, lgErr
end

-- The no-UNIT_NAME_UPDATE fallback: the client cannot render the player's own
-- unit without a name, so identity always resolves eventually -- there is no
-- cap. Each tick costs one identity check (two API calls, up to four
-- compares) and re-arms itself only while something is still held.
pollTick = function()
    pollScheduled = false
    if identityStopped or #identityHeld == 0 then return end
    local _, alRaised, alErr, lgRaised, lgErr = releaseIdentityHeld("POLL")
    if alRaised then surfaceHookError("addon-loaded", alErr) end
    if lgRaised then surfaceHookError("login", lgErr) end
    if #identityHeld > 0 then
        schedulePoll()
    end
end

schedulePoll = function()
    if pollScheduled or #identityHeld == 0 or identityStopped then return end
    pollScheduled = true
    C_Timer.After(1, pollTick)
end

-- Lazily create and wire the single shared dispatcher frame. Idempotent: every
-- call after the first returns without touching the existing frame, so the
-- three RegisterEvent calls happen exactly once for the whole library.
local function ensureDispatcher()
    if dispatcher then return end

    local frame = CreateFrame("Frame")
    frame:Hide()

    -- Demux by event name, then (for ADDON_LOADED) by addon name. Each _fire*
    -- captures-and-returns its subscriber's error (never throws inline); the
    -- dispatcher surfaces captured errors only AFTER the fan-out completes, so
    -- one bad hook cannot abort the loop and starve other consumers' phases
    -- (continue-on-error contract).
    frame:SetScript("OnEvent", function(_, event, ...)
        if event == "ADDON_LOADED" then
            local loadedName = ...
            -- A later ADDON_LOADED -- for ANY addon, not just a held one's own --
            -- can be the moment identity resolves, so try a release first: a
            -- controller due to fire THIS SAME ADDON_LOADED can still be held
            -- if identity is not resolved either way.
            local _, relAlRaised, relAlErr, relLgRaised, relLgErr = releaseIdentityHeld("ADDON_LOADED")
            local c = byAddonName[loadedName]   -- O(1) demux; nil for addons we don't track
            local raised, err
            if c then
                byAddonName[loadedName] = nil   -- one-shot demux clear (ownedNames KEPT)
                -- If anything is still held (the release above may have refused --
                -- combat, or identity still unresolved for the held set), this
                -- controller joins the hold too, even if ITS OWN identity check
                -- would pass: firing it now would let it run ahead of an
                -- already-waiting controller, and in the combat case, ahead of
                -- the very deferral that's holding the other one back.
                if #identityHeld == 0 and Lifecycle._PlayerIdentity() then
                    raised, err = c:_fireAddonLoaded() -- single fire; raised flag, never thrown inline
                else
                    holdForIdentity(c)
                end
            end
            if relAlRaised then surfaceHookError("addon-loaded", relAlErr) end
            if relLgRaised then surfaceHookError("login", relLgErr) end
            if raised then surfaceHookError("addon-loaded", err) end
        elseif event == "PLAYER_LOGIN" then
            -- Release BEFORE setting loginFired: a controller released here gets
            -- its login from the ordinary fan-out below, because release's own
            -- login fan is gated on loginFired and has not seen it flip yet.
            local _, relAlRaised, relAlErr, relLgRaised, relLgErr = releaseIdentityHeld("PLAYER_LOGIN")
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
                local c = snapshot[i]
                if not c._identityHeld then    -- a held controller's login stays queued
                    local r, e = c:_fireLogin() -- never aborts; returns (raised, err)
                    if r and not raised then raised, firstErr = true, e end
                end
            end
            if relAlRaised then surfaceHookError("addon-loaded", relAlErr) end
            if relLgRaised then surfaceHookError("login", relLgErr) end
            if raised then surfaceHookError("login", firstErr) end  -- surface ONLY after the full fan-out
        elseif event == "PLAYER_ENTERING_WORLD" then
            local _, relAlRaised, relAlErr, relLgRaised, relLgErr = releaseIdentityHeld("PLAYER_ENTERING_WORLD")
            if #identityHeld > 0 then
                schedulePoll()   -- PLAYER_ENTERING_WORLD may be the last resolution
                                 -- signal before UNIT_NAME_UPDATE; keep covering the gap
                if F.IS_DEV_BUILD and not devNoticePrinted then
                    devNoticePrinted = true
                    local names = {}
                    for i = 1, #identityHeld do
                        names[#names + 1] = identityHeld[i]._addonName
                    end
                    print("Foundry-1.0: Lifecycle: waiting for the character's name before starting "
                        .. table.concat(names, ", "))
                end
            end
            if relAlRaised then surfaceHookError("addon-loaded", relAlErr) end
            if relLgRaised then surfaceHookError("login", relLgErr) end
        elseif event == "UNIT_NAME_UPDATE" then
            -- Unit-registered to "player" only; no unit-argument compare needed.
            local _, relAlRaised, relAlErr, relLgRaised, relLgErr = releaseIdentityHeld("UNIT_NAME_UPDATE")
            if relAlRaised then surfaceHookError("addon-loaded", relAlErr) end
            if relLgRaised then surfaceHookError("login", relLgErr) end
        elseif event == "PLAYER_REGEN_ENABLED" then
            local _, relAlRaised, relAlErr, relLgRaised, relLgErr = releaseIdentityHeld("PLAYER_REGEN_ENABLED")
            if relAlRaised then surfaceHookError("addon-loaded", relAlErr) end
            if relLgRaised then surfaceHookError("login", relLgErr) end
        elseif event == "ADDONS_UNLOADING" and unloadingSupported then
            identityStopped = true   -- a held session never fires its hooks or writes
            stopWatching()
            local closingClient = ...
            local snapshot, n = {}, 0
            for i = 1, #unloadingControllers do
                n = n + 1
                snapshot[n] = unloadingControllers[i]
            end
            local raised, firstErr = false, nil
            for i = 1, n do
                local c = snapshot[i]
                if not c._identityHeld then
                    local r, e = c:_fireUnloading(closingClient)
                    if r and not raised then raised, firstErr = true, e end
                end
            end
            if raised then surfaceHookError("unloading", firstErr) end
        elseif event == "PLAYER_LOGOUT" then
            identityStopped = true   -- a held session never fires its hooks or writes
            stopWatching()
            local snapshot, n = {}, 0
            for c in pairs(loginControllers) do n = n + 1; snapshot[n] = c end
            local raised, firstErr = false, nil
            for i = 1, n do
                local c = snapshot[i]
                if not c._identityHeld then
                    local r, e = c:_fireLogout()
                    if r and not raised then raised, firstErr = true, e end
                end
            end
            -- Post-logout fan-out (private seam). Runs strictly AFTER the consumer
            -- logout fan-out completes -- so a consumer's final writes are in place
            -- before the DB strip walks them (spec §6.4 contract 2) -- and strictly
            -- BEFORE the deferred surfacing below: surfacing first would raise (dev
            -- build) and skip the strip whenever a consumer logout hook errored,
            -- defeating the continue-on-error contract the strip depends on (§6.4
            -- contract 1). Each callback is captured so one cannot starve another;
            -- DB owns finer pcall-per-store isolation beneath this.
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
    local eventUtils = _G.C_EventUtils
    if eventUtils and type(eventUtils.IsEventValid) == "function"
        and eventUtils.IsEventValid("ADDONS_UNLOADING") then
        frame:RegisterEvent("ADDONS_UNLOADING")
        unloadingSupported = true
    end

    -- Late-creation catch-up (the login analogue of OnAddonLoaded's
    -- IsAddOnLoaded probe): if the first controller of the session is created
    -- after PLAYER_LOGIN (an all-Load-on-Demand consumer), the one-shot event
    -- has already fired and will never reach this frame. Seed loginFired from
    -- the authoritative IsLoggedIn() at dispatcher-creation time so OnLogin
    -- handlers aren't silently dropped.
    if type(IsLoggedIn) == "function" and IsLoggedIn() then
        loginFired = true
    end

    dispatcher = frame
end

-- Private post-logout-fan-out registration seam (spec §6.4). The underscore
-- name keeps it off the public API, so it does not affect Lifecycle.API_VERSION (the
-- _TestFire precedent). Foundry.DB registers its logout strip here exactly
-- once, at its first :New, and calls ensureDispatcher() itself so the
-- PLAYER_LOGOUT registration exists even for a DB-only consumer that never
-- calls Lifecycle:New (§6.4 contract 1 holds regardless). Registered
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

-- Private fire wrappers the dispatcher calls. Each pcall-wraps the subscriber's
-- handler and returns (raised, err): a boolean flag plus the captured value,
-- which may itself be falsy. The dispatcher gates surfacing on the flag, never
-- the value's truthiness, so a falsy error is never swallowed, and surfaces it
-- only AFTER the fan-out completes (an un-pcall'd RaiseDevError here would
-- abort the loop and starve remaining subscribers). A controller unsubscribed
-- mid-loop (Destroy) is skipped. Each phase is one-shot: the hook is cleared
-- before invocation so a second signal does not re-fire it.

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

function Controller:_fireUnloading(closingClient)
    if self._destroyed then return false end
    local fn = self._hooks.unloading
    if not fn then return false end
    self._hooks.unloading = nil
    local ok, err = pcall(fn, self._owner, closingClient)
    if not ok then return true, err end
    return false
end

-- Register the one-shot addon-loaded hook. Fires once when ADDON_LOADED matches
-- addonName, OR immediately via catch-up if the addon is already loaded -- unless
-- the character's identity is not yet resolved, in which case the catch-up holds
-- the controller instead of firing (see the header note on addon-loaded holds). A
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

    -- Load-on-Demand catch-up, synchronous inside this registration call (the
    -- hook can fire before this method returns -- re-entrancy-relevant timing):
    -- fire now ONLY if the addon has FINISHED loading.
    -- IsAddOnLoaded returns (loadedOrLoading, loaded); the first is true while
    -- still loading, and gating on it would fire the hook before SavedVariables
    -- are available -- defeating the hook's purpose for a consumer registering
    -- during its own addon's load. Gate on the second (finished) value; a
    -- still-loading addon stays enrolled and fires on the real ADDON_LOADED.
    local alreadyLoaded = false
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        local _, loaded = C_AddOns.IsAddOnLoaded(self._addonName)
        alreadyLoaded = (loaded == true)
    end
    if alreadyLoaded then
        byAddonName[self._addonName] = nil
        -- If anything is still held, this controller joins the hold too, even
        -- if its own identity check would pass: firing here would let it run
        -- ahead of an already-waiting controller (see the ADDON_LOADED branch
        -- for the same rule and why it matters in combat).
        if #identityHeld == 0 and Lifecycle._PlayerIdentity() then
            local raised, err = self:_fireAddonLoaded()
            if raised then surfaceHookError("addon-loaded", err) end
        else
            holdForIdentity(self)
        end
    end
end

-- Register the one-shot player-login hook. Fires once on PLAYER_LOGIN, OR
-- immediately via catch-up if login already fired -- unless this controller is
-- currently held for identity, in which case the catch-up waits too (a
-- login-phase construct benefits from the hold exactly as an addon-loaded one
-- does; see the header note). Adds the controller to the login/logout
-- broadcast set. Re-register rejected. Validation is atomic.
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

    -- Login catch-up: if PLAYER_LOGIN already fired, fire now (synchronously) --
    -- unless this controller is currently held for identity; its login then
    -- catches up on release instead. This is the central replacement for a
    -- consumer hand-rolling a post-login retry timer.
    if loginFired and not self._identityHeld then
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

-- Register the one-shot pre-unload hook. It fires when the client emits
-- ADDONS_UNLOADING, passing its closingClient boolean. Clients that do not
-- expose a valid ADDONS_UNLOADING event keep the hook silent. This hook and
-- OnLogout bridge distinct native events; no ordering relation is promised.
function Controller:OnUnloading(handler)
    if self._destroyed then
        F:RaiseDevError("Lifecycle:OnUnloading called on a destroyed controller")
        return
    end
    if type(handler) ~= "function" then
        F:RaiseDevError("Lifecycle:OnUnloading: handler must be a function")
        return
    end
    if self._registered.unloading then
        F:RaiseDevError("Lifecycle:OnUnloading: an unloading hook is already registered for '"
            .. self._addonName .. "'; one hook per phase per controller")
        return
    end

    self._registered.unloading = true
    self._hooks.unloading = handler
    unloadingControllers[#unloadingControllers + 1] = self
end

-- The escape hatch. Returns the live SHARED dispatcher frame and a shallow
-- read-only snapshot of this controller's hook set; mutating the snapshot
-- cannot affect live dispatch. Two controllers' .frame return the same
-- identity by design -- the inverse of Events' per-controller frame.
function Controller:GetNativeHandles()
    if self._destroyed then
        F:RaiseDevError("Lifecycle:GetNativeHandles called on a destroyed controller")
        return
    end
    local snapshot = {
        addonLoaded = self._hooks.addonLoaded,
        login = self._hooks.login,
        logout = self._hooks.logout,
        unloading = self._hooks.unloading,
    }
    return {
        frame = dispatcher,
        hooks = snapshot,
    }
end

-- Tear down: unsubscribe from every dispatcher table, release refs, mark
-- destroyed. Releasing addonName from ownedNames lets a later :New reuse it.
-- Explicitly DOES NOT fire the logout hook -- Destroy opts the owner out of
-- all remaining phases, including logout. The shared dispatcher frame is
-- never destroyed here; it is library state, kept alive for the session.
function Controller:Destroy()
    if self._destroyed then
        F:RaiseDevError("Lifecycle:Destroy called on a destroyed controller")
        return
    end
    byAddonName[self._addonName] = nil
    ownedNames[self._addonName] = nil
    loginControllers[self] = nil
    for i = #unloadingControllers, 1, -1 do
        if unloadingControllers[i] == self then
            table.remove(unloadingControllers, i)
            break
        end
    end
    if self._identityHeld then
        for i = #identityHeld, 1, -1 do
            if identityHeld[i] == self then
                table.remove(identityHeld, i)
                break
            end
        end
        self._identityHeld = nil
        if #identityHeld == 0 then
            stopWatching()
        end
    end
    self._hooks = {}
    self._registered = {}
    self._owner = nil
    self._destroyed = true
end

--------------------------------------------------------------------------------
-- Factory
--------------------------------------------------------------------------------

-- Create a per-owner controller. Primary form adopts an EXISTING table: owner
-- is the consumer's real addon table (Homestead's HA.Addon, BawrSpam's NS).
-- The secondary form (nil owner) yields a plain {} controller-only object.
-- Lifecycle writes NOTHING into owner; all bookkeeping lives on the controller
-- and the dispatcher upvalues. addonName is the TOC name used as the
-- ADDON_LOADED demux key. A second :New for an addonName that already owns a
-- live Lifecycle is rejected -- checked against the PERSISTENT ownedNames
-- registry, not the one-shot byAddonName demux, so the guard holds for the
-- controller's whole life.
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
    -- _registered persists a phase's registration for the controller's whole
    -- life, separate from _hooks (which the one-shot fire clears) -- a second
    -- OnX is rejected even after its phase fired.
    c._registered = { addonLoaded = false, login = false, logout = false, unloading = false }
    c._destroyed = false

    -- Enrol for the pending ADDON_LOADED demux and the persistent re-register
    -- registry; OnAddonLoaded's catch-up clears byAddonName if already loaded.
    byAddonName[addonName] = c
    ownedNames[addonName] = c

    return c
end

--------------------------------------------------------------------------------
-- Dev-only test seam
--------------------------------------------------------------------------------

-- The in-game analogue of the out-of-game harness's T.Fire: drive a startup
-- phase through the LIVE shared dispatcher's real OnEvent path without
-- touching the frame's event registration. Exists so the otherwise-
-- unobservable phases (ADDON_LOADED can't replay without a client restart;
-- PLAYER_LOGOUT ends the session) can be exercised by the dev-gated Lifecycle
-- self-test (Dev/LifecycleSelfTest.lua).
--
-- Hard-gated on F.IS_DEV_BUILD: a release build routes to F:RaiseDevError and
-- does nothing, so it can never become a player-reachable phase injector. It
-- also refuses if no :New has yet created the dispatcher.
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

-- Foundry.Lifecycle
--
-- AceAddon-3.0 replacement: addon-object creation plus correctly-timed
-- startup callbacks. Subscribe via :OnAddonLoaded, :OnLogin, :OnLogout,
-- :OnUnloading; the native dispatcher frame is reachable via
-- :GetNativeHandles().
--
-- The addon-loaded hook can be delayed: if the player's identity is not yet
-- resolved (name/realm, or on some clients name/surname), addon-loaded and
-- queued login hooks wait until it resolves, so a hook that builds a database
-- never sees a placeholder identity. Release also waits for combat to end; a
-- surname that never arrives releases under the first name about 1s after
-- entering the world.

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: Lifecycle.lua requires the Foundry-1.0 bootstrap (Foundry.lua) "
        .. "to have loaded first; _G.Foundry_1_0 is missing.", 0)
end
-- Redundant embedded copy of an already-registered module; load nothing.
if F:HasModule("Lifecycle") then return end

local Lifecycle = {}
Lifecycle.API_VERSION = 4

--------------------------------------------------------------------------------
-- Shared private dispatcher
--------------------------------------------------------------------------------

-- All module state lives on the module table. dispatcher is set once, when it
-- is first needed; identityHeld is replaced on every release, so
-- it and the flags are always read through the state table.
Lifecycle._layoutVersion = 1
Lifecycle._source = ...
Lifecycle._state = {
    -- byAddonName: one-shot ADDON_LOADED demux, cleared on fire. ownedNames:
    -- persists until Destroy, backs re-register refusal.
    byAddonName = {},
    ownedNames = {},
    -- Controllers wanting login OR logout; PLAYER_LOGOUT fans out over this
    -- set too.
    loginControllers = {},
    unloadingControllers = {},
    unloadingSupported = false,
    loginFired = false,
    postLogout = {},

    identityHeld = {},
    identityWatching = false,
    pollScheduled = false,
    identityStopped = false,
    devNoticePrinted = false,
    surnameSettled = false,
}
Lifecycle._impl = {}
local S, I = Lifecycle._state, Lifecycle._impl
local byAddonName, ownedNames = S.byAddonName, S.ownedNames
local loginControllers, unloadingControllers = S.loginControllers, S.unloadingControllers
local postLogout = S.postLogout

Lifecycle._identityResolvedBy = nil
Lifecycle._surnameLagObserved = nil

-- Gate callers on the raised flag, not the error value -- it may be falsy.
local function surfaceHookError(phase, err)
    F:RaiseDevError("Lifecycle: a '" .. phase .. "' phase hook errored: " .. tostring(err))
end
I.surfaceHookError = surfaceHookError

-- Returns (name, realm, key, legacyKey), or (nil, msg, reason) if identity
-- has not resolved yet. On a region-wide-unique-names client, key is
-- name+surname rather than name+realm.
-- Foundry.DB keys each character's saved data on this return value; changing
-- its format moves every consumer's per-character data.
function Lifecycle._PlayerIdentity()
    local regionalUnique = type(_G.RegionalUniqueNamesEnabled) == "function"
        and _G.RegionalUniqueNamesEnabled() == true
    local regionalName = regionalUnique and type(_G.UnitNameUnmodified) == "function"

    local name, surname
    if regionalName then
        name, surname = _G.UnitNameUnmodified("player")
    else
        name = UnitName("player")
    end
    local realm = GetRealmName()
    local unknown = _G.UNKNOWNOBJECT
    if type(unknown) ~= "string" then unknown = nil end

    if type(name) ~= "string" or name == "" or name == "Unknown" or (unknown and name == unknown) then
        return nil, "player identity is not available yet (UnitName returned '" .. tostring(name) .. "')"
    end
    if type(realm) ~= "string" or realm == "" or realm == "Unknown" or (unknown and realm == unknown) then
        return nil, "realm identity is not available yet (GetRealmName returned '" .. tostring(realm) .. "')"
    end

    if not regionalName then
        return name, realm, name .. " - " .. realm, nil
    end

    if type(surname) ~= "string" then surname = nil end

    if surname == nil then
        if not S.surnameSettled then
            return nil, "player surname is not available yet (UnitNameUnmodified returned no surname)", "surname"
        end
        return name, realm, name, nil
    end

    return name, realm, name .. " " .. surname, name .. " - " .. realm
end

local function identityResolved()
    local name, _, reason = Lifecycle._PlayerIdentity()
    if not name and reason == "surname" then Lifecycle._surnameLagObserved = true end
    return name ~= nil
end
I.identityResolved = identityResolved

local schedulePoll
local pollTick

local function holdForIdentity(c)
    if c._identityHeld then return end
    c._identityHeld = true
    S.identityHeld[#S.identityHeld + 1] = c
    if not S.identityWatching then
        S.dispatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
        S.dispatcher:RegisterUnitEvent("UNIT_NAME_UPDATE", "player")
        S.dispatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
        S.identityWatching = true
    end
    if S.loginFired then
        schedulePoll()
    end
end
I.holdForIdentity = holdForIdentity

-- C_Timer.After gives no cancel handle, so a pending poll tick still fires.
local function stopWatching()
    if not S.identityWatching then return end
    S.dispatcher:UnregisterEvent("PLAYER_ENTERING_WORLD")
    S.dispatcher:UnregisterEvent("UNIT_NAME_UPDATE")
    S.dispatcher:UnregisterEvent("PLAYER_REGEN_ENABLED")
    S.identityWatching = false
end
I.stopWatching = stopWatching

-- Refuses to release while the player is in combat, since a consumer that
-- creates secure frames at startup could trip ADDON_ACTION_BLOCKED.
local function releaseIdentityHeld(eventName)
    if #S.identityHeld == 0 or S.identityStopped then return false end
    if InCombatLockdown() then return false end
    if not identityResolved() then return false end

    -- The released set is walked from this snapshot; a controller held while
    -- the hooks below run joins the fresh set.
    local snapshot = S.identityHeld
    S.identityHeld = {}
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
    if S.loginFired then
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
I.releaseIdentityHeld = releaseIdentityHeld

-- Fallback poll for clients that never fire UNIT_NAME_UPDATE; its first
-- tick also settles a missing surname.
pollTick = function()
    S.surnameSettled = true
    S.pollScheduled = false
    if S.identityStopped or #S.identityHeld == 0 then return end
    local _, alRaised, alErr, lgRaised, lgErr = releaseIdentityHeld("POLL")
    if alRaised then surfaceHookError("addon-loaded", alErr) end
    if lgRaised then surfaceHookError("login", lgErr) end
    if #S.identityHeld > 0 then
        schedulePoll()
    end
end
I.pollTick = pollTick

-- The timer holds this rather than pollTick, so a pending tick runs the
-- pollTick on the module table when it fires.
local function pollRelay()
    return Lifecycle._impl.pollTick()
end

schedulePoll = function()
    if S.pollScheduled or #S.identityHeld == 0 or S.identityStopped then return end
    S.pollScheduled = true
    C_Timer.After(1, pollRelay)
end
I.schedulePoll = schedulePoll

-- Hooks run under pcall; each loop's first error is held until every
-- hook has run, since raising mid-loop starves the rest. In a dev build
-- only the first held error raises.
local function onEvent(_, event, ...)
    if event == "ADDON_LOADED" then
        local loadedName = ...
        local _, relAlRaised, relAlErr, relLgRaised, relLgErr = releaseIdentityHeld("ADDON_LOADED")
        local c = byAddonName[loadedName]
        local raised, err
        if c then
            byAddonName[loadedName] = nil
            -- Held if anything else is still held, even if this
            -- controller's own identity check would pass, so it never
            -- runs ahead of an already-waiting controller.
            if #S.identityHeld == 0 and identityResolved() then
                raised, err = c:_fireAddonLoaded()
            else
                holdForIdentity(c)
            end
        end
        if relAlRaised then surfaceHookError("addon-loaded", relAlErr) end
        if relLgRaised then surfaceHookError("login", relLgErr) end
        if raised then surfaceHookError("addon-loaded", err) end
    elseif event == "PLAYER_LOGIN" then
        -- Released before loginFired flips, so a released controller
        -- gets its login from the fan-out below, not from release.
        local _, relAlRaised, relAlErr, relLgRaised, relLgErr = releaseIdentityHeld("PLAYER_LOGIN")
        S.loginFired = true
        -- Snapshot before the fan-out: mutating loginControllers with
        -- pairs() mid-iteration is undefined in Lua 5.1.
        local snapshot, n = {}, 0
        for c in pairs(loginControllers) do n = n + 1; snapshot[n] = c end
        local raised, firstErr = false, nil
        for i = 1, n do
            local c = snapshot[i]
            if not c._identityHeld then
                local r, e = c:_fireLogin()
                if r and not raised then raised, firstErr = true, e end
            end
        end
        if relAlRaised then surfaceHookError("addon-loaded", relAlErr) end
        if relLgRaised then surfaceHookError("login", relLgErr) end
        if raised then surfaceHookError("login", firstErr) end
    elseif event == "PLAYER_ENTERING_WORLD" then
        local _, relAlRaised, relAlErr, relLgRaised, relLgErr = releaseIdentityHeld("PLAYER_ENTERING_WORLD")
        if #S.identityHeld > 0 then
            schedulePoll()
            if F.IS_DEV_BUILD and not S.devNoticePrinted then
                S.devNoticePrinted = true
                local names = {}
                for i = 1, #S.identityHeld do
                    names[#names + 1] = S.identityHeld[i]._addonName
                end
                print("Foundry-1.0: Lifecycle: waiting for the character's name or surname before starting "
                    .. table.concat(names, ", "))
            end
        end
        if relAlRaised then surfaceHookError("addon-loaded", relAlErr) end
        if relLgRaised then surfaceHookError("login", relLgErr) end
    elseif event == "UNIT_NAME_UPDATE" then
        local _, relAlRaised, relAlErr, relLgRaised, relLgErr = releaseIdentityHeld("UNIT_NAME_UPDATE")
        if relAlRaised then surfaceHookError("addon-loaded", relAlErr) end
        if relLgRaised then surfaceHookError("login", relLgErr) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        local _, relAlRaised, relAlErr, relLgRaised, relLgErr = releaseIdentityHeld("PLAYER_REGEN_ENABLED")
        if relAlRaised then surfaceHookError("addon-loaded", relAlErr) end
        if relLgRaised then surfaceHookError("login", relLgErr) end
    elseif event == "ADDONS_UNLOADING" and S.unloadingSupported then
        S.identityStopped = true
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
        S.identityStopped = true
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
        -- Runs after consumer logout hooks and before error surfacing,
        -- so the DB strip sees final writes even if a hook errored.
        local plRaised, plFirstErr = false, nil
        for i = 1, #postLogout do
            local ok, e = pcall(postLogout[i])
            if not ok and not plRaised then plRaised, plFirstErr = true, e end
        end
        if raised then surfaceHookError("logout", firstErr) end
        if plRaised then surfaceHookError("post-logout", plFirstErr) end
    end
end
I.onEvent = onEvent

-- The dispatcher frame holds this rather than onEvent, so the frame keeps one
-- script for the session and each event runs the onEvent on the module table.
local function dispatcherRelay(...)
    return Lifecycle._impl.onEvent(...)
end

local function ensureDispatcher()
    if S.dispatcher then return end

    local frame = CreateFrame("Frame")
    frame:Hide()
    frame:SetScript("OnEvent", dispatcherRelay)

    frame:RegisterEvent("ADDON_LOADED")
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:RegisterEvent("PLAYER_LOGOUT")
    local eventUtils = _G.C_EventUtils
    if eventUtils and type(eventUtils.IsEventValid) == "function"
        and eventUtils.IsEventValid("ADDONS_UNLOADING") then
        frame:RegisterEvent("ADDONS_UNLOADING")
        S.unloadingSupported = true
    end

    -- Seeds loginFired from IsLoggedIn(), since a dispatcher created after
    -- PLAYER_LOGIN (all-Load-on-Demand) never sees that one-shot event.
    if type(IsLoggedIn) == "function" and IsLoggedIn() then
        S.loginFired = true
    end

    S.dispatcher = frame
end
I.ensureDispatcher = ensureDispatcher

-- Private seam Foundry.DB uses to register its logout strip.
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
I.Controller = Controller

function Controller:_fireAddonLoaded()
    if self._destroyed then return false end
    local fn = self._hooks.addonLoaded
    if not fn then return false end
    self._hooks.addonLoaded = nil
    local ok, err = pcall(fn, self._owner)
    if not ok then return true, err end
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

-- Fires once when ADDON_LOADED matches, or synchronously, before this call
-- returns, if the addon is already loaded (deferred if identity is still
-- resolving). One hook per phase per controller; re-registering raises a
-- dev error.
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

    -- IsAddOnLoaded's second return is "finished"; gating on the first would
    -- fire before SavedVariables exist.
    local alreadyLoaded = false
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        local _, loaded = C_AddOns.IsAddOnLoaded(self._addonName)
        alreadyLoaded = (loaded == true)
    end
    if alreadyLoaded then
        byAddonName[self._addonName] = nil
        if #S.identityHeld == 0 and identityResolved() then
            local raised, err = self:_fireAddonLoaded()
            if raised then surfaceHookError("addon-loaded", err) end
        else
            holdForIdentity(self)
        end
    end
end

-- Fires once on PLAYER_LOGIN, or synchronously, before this call returns,
-- if login already fired (deferred if this controller is held for
-- identity). Re-registering raises a dev error.
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

    if S.loginFired and not self._identityHeld then
        local raised, err = self:_fireLogin()
        if raised then surfaceHookError("login", err) end
    end
end

-- Fires once on PLAYER_LOGOUT. Not fired by Destroy, and not fired for a
-- controller still held waiting for identity. Re-registering raises a dev error.
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

-- Fires once on ADDONS_UNLOADING, passing closingClient. Silent on clients
-- without that event, and not fired for a controller still held waiting for
-- identity. No ordering relation with OnLogout is promised.
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

-- Returns the shared dispatcher frame and a read-only snapshot of this
-- controller's hooks, for advanced/escape-hatch use.
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
        frame = S.dispatcher,
        hooks = snapshot,
    }
end

-- Unsubscribes from every phase and frees the addon name for reuse. Does not
-- fire the logout hook.
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
        for i = #S.identityHeld, 1, -1 do
            if S.identityHeld[i] == self then
                table.remove(S.identityHeld, i)
                break
            end
        end
        self._identityHeld = nil
        if #S.identityHeld == 0 then
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

-- Creates a per-owner controller. owner (optional) is the consumer's own
-- addon table; addonName is the TOC name used to match ADDON_LOADED. A
-- second :New for a live addonName raises a dev error until Destroy'd.
-- Lifecycle writes nothing into owner.
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
    -- _registered outlives _hooks (cleared on fire), so a second OnX is
    -- refused even after its phase fired.
    c._registered = { addonLoaded = false, login = false, logout = false, unloading = false }
    c._destroyed = false

    byAddonName[addonName] = c
    ownedNames[addonName] = c

    return c
end

--------------------------------------------------------------------------------
-- Dev-only test seam
--------------------------------------------------------------------------------

-- Dev-build-only test seam; replays a startup phase through the live
-- dispatcher. Never available in a release build.
function Lifecycle:_TestFire(phase, addonName)
    if not F.IS_DEV_BUILD then
        F:RaiseDevError("Lifecycle:_TestFire is dev-build only and must never run in a "
            .. "release build (it is a phase injector)")
        return
    end
    if not S.dispatcher or not S.dispatcher:GetScript("OnEvent") then
        F:RaiseDevError("Lifecycle:_TestFire: no dispatcher yet; create a controller "
            .. "with :New before firing a phase")
        return
    end

    local script = S.dispatcher:GetScript("OnEvent")
    if phase == "addon-loaded" then
        if type(addonName) ~= "string" or addonName == "" then
            F:RaiseDevError("Lifecycle:_TestFire: 'addon-loaded' requires a non-empty addonName")
            return
        end
        script(S.dispatcher, "ADDON_LOADED", addonName)
    elseif phase == "login" then
        script(S.dispatcher, "PLAYER_LOGIN")
    elseif phase == "logout" then
        script(S.dispatcher, "PLAYER_LOGOUT")
    else
        F:RaiseDevError("Lifecycle:_TestFire: unknown phase '" .. tostring(phase)
            .. "'; expected 'addon-loaded', 'login', or 'logout'")
    end
end

F:RegisterModule("Lifecycle", Lifecycle)

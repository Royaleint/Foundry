-- Foundry.DB
--
-- An AceDB-3.0 replacement: loads SavedVariables, applies defaults, runs
-- migrations, and exposes the live section tables (profile / char / global /
-- sv), stripping default-equal values back out at logout.
--
-- Clean-room: behavior-compatible with AceDB-3.0, no AceDB code reproduced.

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: DB.lua requires the Foundry-1.0 bootstrap (Foundry.lua) "
        .. "to have loaded first; _G.Foundry_1_0 is missing.", 0)
end
-- Already registered on the winning copy: this is a redundant embedded copy.
if F:HasModule("DB") then return end

if type(F.Lifecycle) ~= "table"
    or type(F.Lifecycle._RegisterPostLogout) ~= "function"
    or type(F.Lifecycle._PlayerIdentity) ~= "function" then
    F:RaiseDevError("DB requires Lifecycle's post-logout seam "
        .. "(F.Lifecycle._RegisterPostLogout) and its player-identity check "
        .. "(F.Lifecycle._PlayerIdentity), which the Foundry core serving this "
        .. "session does not provide. The Foundry core serving this session reports "
        .. "version " .. tostring(F.VERSION) .. " (API_VERSION " .. tostring(F.API_VERSION)
        .. "), from " .. tostring(F.SOURCE) .. ". This has two possible causes: either "
        .. "an older standalone Foundry addon won the runtime and is serving everyone "
        .. "(update that addon to a newer version), or Foundry's files loaded in the "
        .. "wrong order and Lifecycle has not run yet (load through Foundry-1.0.xml, "
        .. "or list Lifecycle ahead of DB by hand). DB is unavailable this session.")
    return
end
if type(F.Events) ~= "table" or type(F.Events.New) ~= "function" then
    F:RaiseDevError("DB requires Foundry.Events, which the Foundry core serving this "
        .. "session does not provide. The Foundry core serving this session reports "
        .. "version " .. tostring(F.VERSION) .. ", from " .. tostring(F.SOURCE)
        .. ". This has two possible causes: either an older standalone Foundry addon "
        .. "won the runtime and is serving everyone (update that addon to a newer "
        .. "version), or Foundry's files loaded in the wrong order and Events has "
        .. "not run yet (load through Foundry-1.0.xml, or list Events ahead of DB "
        .. "by hand). DB is unavailable this session.")
    return
end

local DB = {}
DB.API_VERSION = 2

--------------------------------------------------------------------------------
-- Shared private state (one set of upvalues per loaded library, lazy)
--------------------------------------------------------------------------------

local liveControllers = {}

local liveControllersByAddon = {}

-- Held OFF the controller: a present `_store` field would bypass
-- __newindex's write-guard (Lua 5.1 only traps ABSENT keys).
local controllerStore = {}

local stores = {}

local postLogoutRegistered = false

local sizeWarningEvents = nil

local SECTION_GLOBAL = "global"
local SECTION_PROFILE = "profile"
local SECTION_CHAR = "char"

-- Unsupported AceDB surface; accessing any of these names raises loudly
-- instead of returning nil or writing silently.
local DENY_LIST = {
    realm = true, class = true, race = true, faction = true,
    factionrealm = true, factionrealmregion = true, locale = true,
    profiles = true, keys = true, defaults = true, parent = true, children = true,
    callbacks = true,
    SetProfile = true, GetProfiles = true, GetCurrentProfile = true,
    CopyProfile = true, DeleteProfile = true, ResetProfile = true, ResetDB = true,
    RegisterDefaults = true, RegisterNamespace = true, GetNamespace = true,
    RegisterCallback = true, UnregisterCallback = true, UnregisterAllCallbacks = true,
}

-- Reserved field names (sections, methods, underscore-prefixed); writing to
-- any of these raises.
local RESERVED = {
    profile = true, char = true, global = true, sv = true,
    OnReady = true, OnSavedVariablesTooLarge = true, GetNativeHandles = true, Destroy = true,
}

local REFERENCE_TAIL = "; see the DB Reference page"

-- Raises in both dev and release builds -- do not swap for RaiseDevError.
local function refuse(msg)
    error("Foundry-1.0: " .. tostring(msg), 3)
end

local function onSavedVariablesTooLarge(_, addonName)
    local controllers = liveControllersByAddon[addonName]
    if not controllers then return end
    local svNames, callbackFailed, callbackErr = {}, false, nil
    local snapshot = {}
    for i = 1, #controllers do
        local controller = controllers[i]
        local store = controllerStore[controller]
        local handlers = {}
        if store and not store.destroyed then
            for j = 1, #store.sizeWarningHandlers do
                handlers[j] = store.sizeWarningHandlers[j]
            end
            svNames[#svNames + 1] = store.svName
        end
        snapshot[i] = { controller = controller, store = store, handlers = handlers }
    end
    for i = 1, #snapshot do
        local recipient = snapshot[i]
        local controller, store = recipient.controller, recipient.store
        if store then
            for j = 1, #recipient.handlers do
                local handler = recipient.handlers[j]
                local ok, err = pcall(handler, controller, addonName, store.svName)
                if not ok then
                    if not callbackFailed then callbackErr = err end
                    callbackFailed = true
                end
            end
        end
    end
    if #svNames > 0 then
        local message = "DB: addon '" .. addonName .. "' SavedVariables globals '"
            .. table.concat(svNames, "', '") .. "' were too large for the client to save"
        if callbackFailed then
            message = message .. "; a size-warning callback errored: " .. tostring(callbackErr)
        end
        F:RaiseDevError(message)
    end
end

local function registerSizeWarning()
    if sizeWarningEvents then return end
    sizeWarningEvents = F.Events:New("Foundry.DB")
    sizeWarningEvents:Register("SAVED_VARIABLES_TOO_LARGE", onSavedVariablesTooLarge)
end

--------------------------------------------------------------------------------
-- Defaults application, stripping, and helpers
--------------------------------------------------------------------------------

-- Defaults tables may not use wildcard ('*' / '**') keys; DB:New rejects them.
local function findWildcard(tbl, pathPrefix)
    for k, v in pairs(tbl) do
        if k == "*" or k == "**" then
            return pathPrefix .. tostring(k)
        end
        if type(v) == "table" then
            local found = findWildcard(v, pathPrefix .. tostring(k) .. ".")
            if found then return found end
        end
    end
    return nil
end

-- Fills only nil slots when applying defaults: a stored `false` is never
-- overwritten by a default `true`.
local function applyDefaults(stored, defaults, onMismatch, path)
    for k, dv in pairs(defaults) do
        local sv = stored[k]
        if type(dv) == "table" then
            if sv == nil then
                local fresh = {}
                stored[k] = fresh
                applyDefaults(fresh, dv, onMismatch, path .. tostring(k) .. ".")
            elseif type(sv) == "table" then
                applyDefaults(sv, dv, onMismatch, path .. tostring(k) .. ".")
            else
                if onMismatch then onMismatch(path .. tostring(k)) end
            end
        else
            if sv == nil then
                stored[k] = dv
            end
        end
    end
end

-- Strips values equal to their default back out at logout, keeping the
-- saved file small; type-mismatched values are left untouched.
local function stripDefaults(stored, defaults)
    for k, dv in pairs(defaults) do
        local sv = stored[k]
        if type(dv) == "table" then
            if type(sv) == "table" then
                stripDefaults(sv, dv)
                if next(sv) == nil then
                    stored[k] = nil
                end
            end
        else
            if sv == dv then
                stored[k] = nil
            end
        end
    end
end

local function splitPath(path)
    local parts = {}
    for piece in tostring(path):gmatch("[^.]+") do
        parts[#parts + 1] = piece
    end
    return parts
end

--------------------------------------------------------------------------------
-- The logout strip (rides Lifecycle's post-logout seam)
--------------------------------------------------------------------------------

local function stripStore(store)
    local sv = store.sv
    if type(sv) ~= "table" then return end
    local defaults = store.defaults

    if defaults then
        if store.materialized[SECTION_GLOBAL] and type(sv.global) == "table"
            and type(defaults.global) == "table" then
            stripDefaults(sv.global, defaults.global)
        end
        if store.materialized[SECTION_PROFILE] and defaults.profile
            and type(defaults.profile) == "table"
            and type(sv.profiles) == "table"
            and type(sv.profiles[store.profileKey]) == "table" then
            stripDefaults(sv.profiles[store.profileKey], defaults.profile)
        end
        if store.materialized[SECTION_CHAR] and defaults.char
            and type(defaults.char) == "table"
            and type(sv.char) == "table"
            and type(sv.char[store.charKey]) == "table" then
            stripDefaults(sv.char[store.charKey], defaults.char)
        end
    end

    -- Only char buckets are pruned; empty named profiles deliberately
    -- survive (AceDB parity).
    if type(sv.char) == "table" then
        for key, bucket in pairs(sv.char) do
            if type(bucket) == "table" and next(bucket) == nil then
                sv.char[key] = nil
            end
        end
    end

    if type(sv.global) == "table" and next(sv.global) == nil then
        sv.global = nil
    end
    if type(sv.char) == "table" and next(sv.char) == nil then
        sv.char = nil
    end
    if type(sv.profiles) == "table" and next(sv.profiles) == nil then
        sv.profiles = nil
    end
end

-- Only the newest store per sv table strips at logout -- stripping an
-- older, Destroyed store's stale defaults could delete data the user set.
local function onLogout()
    local newest = {}
    for i = 1, #stores do newest[stores[i].sv] = stores[i] end
    local snapshot, n = {}, 0
    for i = 1, #stores do
        local s = stores[i]
        if newest[s.sv] == s then n = n + 1; snapshot[n] = s end
    end
    local raised, firstErr = false, nil
    for i = 1, n do
        local ok, err = pcall(stripStore, snapshot[i])
        if not ok and not raised then raised, firstErr = true, err end
    end
    if raised then
        F:RaiseDevError("DB: a store's logout strip errored: " .. tostring(firstErr))
    end
end

--------------------------------------------------------------------------------
-- Controller
--------------------------------------------------------------------------------

local function materialize(store, section)
    local cache = store.sections
    local existing = cache[section]
    if existing ~= nil then return existing end

    local sv = store.sv
    local defaults = store.defaults
    local tbl, sectionDefaults

    if section == SECTION_GLOBAL then
        if type(sv.global) ~= "table" then sv.global = {} end
        tbl = sv.global
        sectionDefaults = defaults and defaults.global
    elseif section == SECTION_PROFILE then
        if type(sv.profiles) ~= "table" then sv.profiles = {} end
        if type(sv.profiles[store.profileKey]) ~= "table" then
            sv.profiles[store.profileKey] = {}
        end
        tbl = sv.profiles[store.profileKey]
        sectionDefaults = defaults and defaults.profile
    elseif section == SECTION_CHAR then
        if type(sv.char) ~= "table" then sv.char = {} end
        if type(sv.char[store.charKey]) ~= "table" then
            sv.char[store.charKey] = {}
        end
        tbl = sv.char[store.charKey]
        sectionDefaults = defaults and defaults.char
    end

    -- Must flag materialized BEFORE applying defaults, or a raised
    -- onMismatch would leave partial defaults unstripped at logout.
    cache[section] = tbl
    store.materialized[section] = true

    if type(sectionDefaults) == "table" then
        applyDefaults(tbl, sectionDefaults, store.onMismatch, section .. ".")
    end

    return tbl
end

local Controller = {}

function Controller.OnReady(self, handler)
    local store = controllerStore[self]
    if store == nil then
        refuse("DB:OnReady called on a non-controller value")
    end
    if store.destroyed then
        F:RaiseDevError("DB:OnReady called on a destroyed controller")
        return
    end
    if type(handler) ~= "function" then
        F:RaiseDevError("DB:OnReady: handler must be a function")
        return
    end
    -- The ready moment completed inside :New, so every registration is a
    -- synchronous catch-up. Multiple handlers are allowed; each runs once, now.
    handler(self)
end

-- Register a handler for the client's end-of-session SavedVariables size
-- warning; fires only if this DB's addon could not be saved. Safe to
-- Destroy() the DB or register another handler from within the handler.
function Controller.OnSavedVariablesTooLarge(self, handler)
    local store = controllerStore[self]
    if store == nil then
        refuse("DB:OnSavedVariablesTooLarge called on a non-controller value")
    end
    if store.destroyed then
        F:RaiseDevError("DB:OnSavedVariablesTooLarge called on a destroyed controller")
        return
    end
    if type(handler) ~= "function" then
        F:RaiseDevError("DB:OnSavedVariablesTooLarge: handler must be a function")
        return
    end
    store.sizeWarningHandlers[#store.sizeWarningHandlers + 1] = handler
end

function Controller.GetNativeHandles(self)
    local store = controllerStore[self]
    if store == nil then
        refuse("DB:GetNativeHandles called on a non-controller value")
    end
    if store.destroyed then
        F:RaiseDevError("DB:GetNativeHandles called on a destroyed controller")
        return
    end
    -- charKey, profileKey, and materialized are SNAPSHOT copies; mutating
    -- the returned table never affects live behavior.
    local matSnapshot = {}
    for k, v in pairs(store.materialized) do matSnapshot[k] = v end
    return {
        sv = store.sv,
        charKey = store.charKey,
        profileKey = store.profileKey,
        materialized = matSnapshot,
    }
end

function Controller.Destroy(self)
    local store = controllerStore[self]
    if store == nil then
        refuse("DB:Destroy called on a non-controller value")
    end
    if store.destroyed then
        F:RaiseDevError("DB:Destroy called on a destroyed controller")
        return
    end
    -- Frees the sv slot for a later :New. Never deletes or mutates saved
    -- data; the strip still runs at logout unless a later :New covers the
    -- same sv. Existing section table references stay valid: sections are
    -- the SV's own tables, safe to cache.
    store.destroyed = true
    if liveControllers[store.svName] == self then
        liveControllers[store.svName] = nil
    end
    local byAddon = liveControllersByAddon[store.addonName]
    if byAddon then
        for i = #byAddon, 1, -1 do
            if byAddon[i] == self then
                table.remove(byAddon, i)
                break
            end
        end
        if #byAddon == 0 then
            liveControllersByAddon[store.addonName] = nil
        end
    end
    store.sizeWarningHandlers = {}
end

-- __index: sections/methods resolve normally; deny-listed names raise.
-- __newindex: reserved/deny-listed names raise; anything else is a plain
-- raw write (like a normal AceDB db object). Sections are served from the
-- store cache, never rawset on the controller, or __index/__newindex stop
-- firing for that key.
local controllerMeta = {}

function controllerMeta.__index(self, key)
    local store = controllerStore[self]

    if key == SECTION_GLOBAL or key == SECTION_PROFILE or key == SECTION_CHAR then
        if store.destroyed then
            refuse("DB: section '" .. key
                .. "' read on a destroyed controller")
        end
        return materialize(store, key)
    end

    -- db.sv: the live SavedVariables root (the unmerged store).
    if key == "sv" then
        if store.destroyed then
            refuse("DB: section 'sv' read on a destroyed controller")
        end
        return store.sv
    end

    local method = Controller[key]
    if method then return method end

    if DENY_LIST[key] then
        refuse("DB: AceDB feature '" .. key
            .. "' is not supported by Foundry.DB" .. REFERENCE_TAIL)
    end

    return nil
end

function controllerMeta.__newindex(self, key, value)
    -- Load-bearing: without this guard, `db.realm = {}` would rawset onto
    -- the controller and permanently shadow the deny-list for that key.
    if RESERVED[key] or DENY_LIST[key]
        or (type(key) == "string" and key:sub(1, 1) == "_") then
        refuse("DB: '" .. tostring(key)
            .. "' is reserved or unsupported and cannot be assigned on the controller"
            .. REFERENCE_TAIL)
    end
    rawset(self, key, value)
end

--------------------------------------------------------------------------------
-- Factory
--------------------------------------------------------------------------------

local function validateDefaults(defaults)
    for k, v in pairs(defaults) do
        if k ~= SECTION_PROFILE and k ~= SECTION_CHAR and k ~= SECTION_GLOBAL then
            return "DB:New: defaults section '" .. tostring(k)
                .. "' is not supported; only 'profile', 'char', and 'global' are"
        end
        if type(v) ~= "table" then
            return "DB:New: defaults.'" .. tostring(k) .. "' must be a table"
        end
    end
    local wildcard = findWildcard(defaults, "")
    if wildcard then
        return "DB:New: wildcard default key '" .. wildcard
            .. "' is not supported by Foundry.DB"
    end
    return nil
end

-- charKey is the full unique name on realms with region-wide unique names,
-- else "Name - Realm"; legacyKey holds the pre-upgrade key when it differs.
local function resolveCharKey()
    local name, realmOrMsg, keyOrReason, legacyKey = F.Lifecycle._PlayerIdentity()
    if not name then
        return nil, "DB:New: " .. realmOrMsg .. "; construction refused"
    end
    if type(keyOrReason) ~= "string" then
        return nil, "DB:New: the Foundry core serving this session predates the "
            .. "full-name character key; construction refused"
    end
    return keyOrReason, legacyKey, name
end

-- Read-only: decides whether to migrate data from a legacy character key
-- onto the new key. Never writes or raises.
local function planLegacyMove(existing, charKey, legacyKey, first)
    if legacyKey == nil then return false end          -- no legacy key to move
    if type(existing) ~= "table" then return false end  -- fresh SV: nothing to move

    local pk = type(existing.profileKeys) == "table" and existing.profileKeys or nil
    local ch = type(existing.char) == "table" and existing.char or nil

    local legacyProfileKey = pk and pk[legacyKey] or nil
    if legacyProfileKey == nil and not (ch and type(ch[legacyKey]) == "table") then
        return false   -- neither section holds the legacy key
    end
    if legacyProfileKey ~= nil and type(legacyProfileKey) ~= "string" then
        return false   -- malformed profileKeys[legacyKey]: skip the move, never refuse
    end

    if (pk and pk[charKey] ~= nil) or (ch and ch[charKey] ~= nil) then
        return false   -- charKey must be absent from both sections
    end

    -- A claimant is any other string key equal to `first` or prefixed "first ".
    local prefix = first .. " "
    local function hasClaimant(section)
        if not section then return false end
        for k in pairs(section) do
            if type(k) == "string" and k ~= charKey and not k:find(" - ", 1, true)
                and (k == first or k:sub(1, #prefix) == prefix) then
                return true
            end
        end
        return false
    end
    if hasClaimant(pk) or hasClaimant(ch) then return false end

    return true
end

local function readRawStamp(sv, pathParts)
    local node = sv
    for i = 1, #pathParts do
        if type(node) ~= "table" then return nil end
        node = node[pathParts[i]]
    end
    return node
end

local function writeStamp(sv, pathParts, value)
    local node = sv
    for i = 1, #pathParts - 1 do
        if type(node[pathParts[i]]) ~= "table" then
            node[pathParts[i]] = {}
        end
        node = node[pathParts[i]]
    end
    node[pathParts[#pathParts]] = value
end

function DB:New(config)
    if type(config) ~= "table" then
        refuse("DB:New: config must be a table")
    end
    if type(config.name) ~= "string" or config.name == "" then
        refuse("DB:New: name must be a non-empty string")
    end
    if type(config.sv) ~= "string" or config.sv == "" then
        refuse("DB:New: sv must be a non-empty string")
    end
    if config.defaults ~= nil and type(config.defaults) ~= "table" then
        refuse("DB:New: defaults, when supplied, must be a table")
    end

    if config.defaultProfile ~= true then
        refuse("DB:New: defaultProfile must be the literal true; "
            .. "named-shared-profile and per-character-profile modes are not "
            .. "supported by Foundry.DB")
    end

    if config.defaults then
        local err = validateDefaults(config.defaults)
        if err then
            refuse(err)
        end
    end

    local schema = config.schema
    local schemaPath
    if schema ~= nil then
        if type(schema) ~= "table" then
            refuse("DB:New: schema, when supplied, must be a table")
        end
        if type(schema.version) ~= "number" or schema.version <= 0
            or schema.version % 1 ~= 0 then
            refuse("DB:New: schema.version must be a positive integer")
        end
        if type(schema.key) ~= "string" or schema.key == "" then
            refuse("DB:New: schema.key must be a non-empty dot-path string")
        end
        if type(schema.migrate) ~= "function" then
            refuse("DB:New: schema.migrate must be a function")
        end
        schemaPath = splitPath(schema.key)
        local rootSection = schemaPath[1]
        -- Rooted at 'global' only: char/profile are keyed-map sections and
        -- can't take a flat stamp path.
        if rootSection ~= SECTION_GLOBAL then
            refuse("DB:New: schema.key must be rooted at 'global' (got '"
                .. schema.key .. "'); char/profile are keyed sections")
        end
        -- Needs a key below the root; a bare "global" would overwrite the
        -- whole section with the version number.
        if #schemaPath < 2 then
            refuse("DB:New: schema.key must name a key inside 'global' (got '"
                .. schema.key .. "'); a bare section root would overwrite the "
                .. "whole section with the version stamp")
        end
        -- Must not be covered by declared defaults, or the strip would
        -- delete the stamp and migrate() would rerun forever.
        if config.defaults then
            local node = config.defaults
            local covered = true
            for i = 1, #schemaPath do
                if type(node) ~= "table" then covered = false; break end
                node = node[schemaPath[i]]
                if node == nil then covered = false; break end
            end
            if covered then
                refuse("DB:New: schema.key '" .. schema.key
                    .. "' is covered by declared defaults; the logout strip would "
                    .. "delete the stamp whenever it equals its default. Remove the "
                    .. "stamp key from the defaults table before adopting the schema seam")
            end
        end
    end

    if liveControllers[config.sv] then
        refuse("DB:New: sv '" .. config.sv
            .. "' already has a live controller; Destroy it first to re-register")
    end

    -- Second return (finished) only: the first is true while still loading,
    -- and a :New then would be clobbered by SavedVariables restore.
    local loaded = false
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        local _, finished = C_AddOns.IsAddOnLoaded(config.name)
        loaded = (finished == true)
    end
    if not loaded then
        refuse("DB:New: addon '" .. config.name
            .. "' has not finished loading; its SavedVariables are not yet "
            .. "available. Construct DB inside the addon-loaded window")
    end

    local charKey, legacyKeyOrErr, first = resolveCharKey()
    if not charKey then
        refuse(legacyKeyOrErr)
    end
    local legacyKey = legacyKeyOrErr

    local existing = _G[config.sv]
    local freshSV = (existing == nil)
    if not freshSV then
        if type(existing) ~= "table" then
            refuse("DB:New: SavedVariables global '" .. config.sv
                .. "' is malformed (expected a table, got " .. type(existing)
                .. "); construction refused")
        end
        local malformed = nil
        if existing.profileKeys ~= nil and type(existing.profileKeys) ~= "table" then
            malformed = "profileKeys"
        elseif existing.profiles ~= nil and type(existing.profiles) ~= "table" then
            malformed = "profiles"
        elseif existing.char ~= nil and type(existing.char) ~= "table" then
            malformed = "char"
        elseif existing.global ~= nil and type(existing.global) ~= "table" then
            malformed = "global"
        end
        if not malformed and type(existing.profileKeys) == "table" then
            local pkv = existing.profileKeys[charKey]
            if pkv ~= nil and type(pkv) ~= "string" then
                malformed = "profileKeys['" .. charKey .. "']"
            end
        end
        if not malformed and type(existing.profiles) == "table" then
            for pk, pv in pairs(existing.profiles) do
                if type(pv) ~= "table" then
                    malformed = "profiles['" .. tostring(pk) .. "']"
                    break
                end
            end
        end
        if not malformed and type(existing.char) == "table" then
            for ck, cv in pairs(existing.char) do
                if type(cv) ~= "table" then
                    malformed = "char['" .. tostring(ck) .. "']"
                    break
                end
            end
        end
        if malformed then
            refuse("DB:New: SavedVariables '" .. config.sv
                .. "' is malformed at '" .. malformed
                .. "'; construction refused (the corrupt value is never overwritten)")
        end
    end

    local movePlanned = planLegacyMove(existing, charKey, legacyKey, first)

    local profileKey = "Default"
    if not freshSV and type(existing.profileKeys) == "table" then
        local lookupKey = movePlanned and legacyKey or charKey
        local saved = existing.profileKeys[lookupKey]
        if type(saved) == "string" and saved ~= "" then
            profileKey = saved
        end
    end

    local storedVersion
    if schema then
        storedVersion = readRawStamp(existing, schemaPath)  -- nil-safe (existing may be nil)
        if type(storedVersion) == "number" and storedVersion > schema.version then
            refuse("DB:New: stored schema version " .. storedVersion
                .. " is newer than this build's declared version " .. schema.version
                .. " (downgrade); construction refused, SavedVariables untouched")
        end
    end

    --==========================================================================
    -- VALIDATION COMPLETE. Nothing above this line mutates state; nothing
    -- below it may add a new validation.
    --==========================================================================

    if freshSV then
        _G[config.sv] = {}
    end
    local sv = _G[config.sv]

    -- One-time move of legacy-key data onto charKey.
    if movePlanned then
        if type(sv.char) == "table" and sv.char[legacyKey] ~= nil then
            sv.char[charKey] = sv.char[legacyKey]
            sv.char[legacyKey] = nil
        end
        if type(sv.profileKeys) == "table" then
            sv.profileKeys[legacyKey] = nil
        end
    end

    if type(sv.profileKeys) ~= "table" then sv.profileKeys = {} end
    sv.profileKeys[charKey] = profileKey

    local store = {
        addonName = config.name,
        svName = config.sv,
        sv = sv,
        defaults = config.defaults,
        charKey = charKey,
        profileKey = profileKey,
        sections = {},        -- section name -> live table (the cache)
        materialized = {},    -- section name -> true once a read begins
        sizeWarningHandlers = {},
        destroyed = false,
    }
    store.onMismatch = function(slotPath)
        F:RaiseDevError("DB: stored value at '" .. slotPath
            .. "' has a type that conflicts with its table-typed default; the "
            .. "stored value is preserved and the default subtree is not applied")
    end

    stores[#stores + 1] = store

    if not postLogoutRegistered then
        F.Lifecycle._RegisterPostLogout(onLogout)
        postLogoutRegistered = true
    end

    -- Metatable-backed; not Mixin()-able.
    local c = setmetatable({}, controllerMeta)
    controllerStore[c] = store
    liveControllers[config.sv] = c

    -- Schema migrations run synchronously inside :New; by the time :New
    -- returns, defaults are applied and migrate has already run.
    if schema then
        if freshSV then
            -- Fresh SV: stamp, migrate NOT called.
            local section = schemaPath[1]
            materialize(store, section)  -- ensure the rooted section is live
            writeStamp(sv, schemaPath, schema.version)
        elseif not (type(storedVersion) == "number" and storedVersion == schema.version) then
            -- migrate(db, nil) runs for a populated-but-unversioned save (or
            -- a non-number stamp); the nil path must be an idempotent repair.
            if storedVersion ~= nil and type(storedVersion) ~= "number" then
                F:RaiseDevError("DB:New: schema stamp at '" .. schema.key
                    .. "' is present but not a number (got a " .. type(storedVersion)
                    .. "); it bypasses the downgrade check by type and is treated as "
                    .. "unversioned -- migrate(db, nil) runs and the stamp is overwritten")
            end
            local mv = (type(storedVersion) == "number") and storedVersion or nil
            local ok, err = pcall(schema.migrate, c, mv)
            if not ok then
                -- The store stays in stores: migrate may have materialized
                -- sections that still need the logout strip.
                store.destroyed = true
                liveControllers[config.sv] = nil
                refuse("DB:New: schema.migrate raised; construction "
                    .. "refused (a half-migrated store is never handed out): "
                    .. tostring(err))
            end
            local section = schemaPath[1]
            materialize(store, section)
            writeStamp(sv, schemaPath, schema.version)
        end
    end

    local byAddon = liveControllersByAddon[config.name]
    if not byAddon then
        byAddon = {}
        liveControllersByAddon[config.name] = byAddon
    end
    byAddon[#byAddon + 1] = c
    registerSizeWarning()

    return c
end

F:RegisterModule("DB", DB)

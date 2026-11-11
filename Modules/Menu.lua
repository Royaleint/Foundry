-- Foundry.Menu
--
-- A controller for Blizzard context menus and persistent dropdowns, built
-- on MenuUtil. The builder function receives the raw rootDescription and
-- calls Create* methods on it directly. MenuResponse is a Blizzard global,
-- not re-exported here.

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: Menu.lua requires the Foundry-1.0 bootstrap (Foundry.lua) "
        .. "to have loaded first; _G.Foundry_1_0 is missing.", 0)
end

local BUILD = 2
local API_VERSION = 1

-- An older Menu already serving is upgraded in place when this copy is newer
-- and the moment is safe; otherwise it keeps serving and this file loads
-- nothing. The checks only read, in a fixed order, and the first to fail names
-- the outcome; nil means this copy upgrades. BUILD, API_VERSION, served and
-- takingOver are read at file scope only: no function below may capture them.
local served = F:HasModule("Menu") and F.Menu or nil
if served == nil and F:HasModule("Menu") then return end
if served ~= nil then
    -- rawget: a current copy reads none of the newer layout fields on an older
    -- library table through a normal lookup.
    if rawget(F, "_layoutVersion") ~= 1 then return end
    local outcome
    local build = rawget(served, "_build")
    local api = rawget(served, "API_VERSION")
    if rawget(served, "_layoutVersion") ~= 1 then
        outcome = "layout"
    elseif build ~= nil and (type(build) ~= "number" or build ~= math.floor(build)
        or build < 1 or build == math.huge or BUILD <= build) then
        outcome = "not used"
    elseif type(api) ~= "number" or api > API_VERSION then
        outcome = "refused: api version"
    elseif type(IsLoggedIn) ~= "function" or IsLoggedIn() then
        outcome = "after login"
    elseif type(InCombatLockdown) ~= "function" or InCombatLockdown() then
        outcome = "combat"
    else
        -- The state and implementation tables the definitions below write into.
        local state, impl = rawget(served, "_state"), rawget(served, "_impl")
        if type(state) ~= "table" or type(state.instances) ~= "table" or type(state.liveKeys) ~= "table"
            or type(state.anonCounter) ~= "number" or type(impl) ~= "table"
            or type(impl.Controller) ~= "table" then
            outcome = "refused: shape"
        end
    end
    if outcome then
        if outcome:sub(1, 9) == "refused: " and F.IS_DEV_BUILD then
            F:RaiseDevError("Menu: a newer copy from " .. tostring((...))
                .. " did not upgrade the active copy (" .. outcome .. ")")
        end
        return
    end
end
local takingOver = served ~= nil

-- On an upgrade every definition below lands in the serving tables, so the
-- older copy's controllers and menu generators reach the newer code.
local Menu = served or {}

-- All module state lives on the module table.
if not takingOver then
    Menu._layoutVersion = 1
    Menu._state = {
        -- Live controllers, held weakly so a dropped controller can be collected.
        instances = setmetatable({}, { __mode = "k" }),
        liveKeys = {},
        anonCounter = 0,
    }
    Menu._impl = {}
end
local S, I = Menu._state, Menu._impl
local liveKeys = S.liveKeys

--------------------------------------------------------------------------------
-- Feature detection (checked at :New, never at file scope)
--------------------------------------------------------------------------------

local function hasMenuUtil()
    return type(_G.MenuUtil) == "table"
        and type(_G.MenuUtil.CreateContextMenu) == "function"
end

--------------------------------------------------------------------------------
-- Controller
--------------------------------------------------------------------------------

local Controller = I.Controller or {}
Controller.__index = Controller
I.Controller = Controller

local function refuseIfDestroyed(self, method)
    if self._destroyed then
        F:RaiseDevError("Menu:" .. method .. " called on a destroyed controller")
        return true
    end
    return false
end

-- Opens a one-shot context menu anchored near owner; extra args forward to
-- the builder after rootDescription.
function Controller:CreateContextMenu(owner, ...)
    if refuseIfDestroyed(self, "CreateContextMenu") then return end
    _G.MenuUtil.CreateContextMenu(owner, self._generatorWrapper, ...)
end

-- Installs a persistent generator on a Blizzard DropdownButton frame.
function Controller:SetupDropdown(button)
    if refuseIfDestroyed(self, "SetupDropdown") then return end
    button:SetupMenu(self._generatorWrapper)
end

-- Destroys the controller and disables the wrapper in-place. Idempotent.
-- Clear liveKeys before nil-ing _name. An installed dropdown stays
-- attached but builds nothing after Destroy.
function Controller:Destroy()
    if self._destroyed then return end
    S.instances[self] = nil
    liveKeys[self._name] = nil
    self._destroyed = true
    self._builder          = nil
    self._name             = nil
    self._generatorWrapper = nil
end

-- Returns the raw Blizzard objects: menuUtil (_G.MenuUtil), menu (_G.Menu,
-- may be nil). Use this for Menu.ModifyMenu or other raw APIs.
function Controller:GetNativeHandles()
    if refuseIfDestroyed(self, "GetNativeHandles") then return end
    return {
        menuUtil = _G.MenuUtil,
        menu     = _G.Menu,
    }
end

--------------------------------------------------------------------------------
-- Extending Blizzard-owned tagged menus (Menu.ModifyMenu)
--------------------------------------------------------------------------------

-- To extend a Blizzard-owned tagged menu (not one this module builds), use
-- the raw Menu.ModifyMenu(tag, callback) via GetNativeHandles(). Register
-- once per tag (a second call adds a duplicate section) and read live state
-- inside the callback. It fires on every menu build, and once at registration
-- if that menu already exists, so captured values go stale.

--------------------------------------------------------------------------------
-- Factory
--------------------------------------------------------------------------------

-- Builds the menu for a controller: nothing once it is destroyed, otherwise
-- the consumer's builder.
local function generate(c, owner, rootDescription, ...)
    if c._destroyed then return end
    c._builder(owner, rootDescription, ...)
end
I.generate = generate

-- Creates a menu controller.
-- Config fields:
--   builder (required) -- function(owner, rootDescription, ...), called each
--                         time the menu opens.
--   name    (optional) -- duplicate-refusal key; defaults to an
--                         auto-generated name.
function Menu:New(config)
    if type(config) ~= "table" then
        F:RaiseDevError("Menu:New: config must be a table")
        return
    end

    local builder = config.builder
    if type(builder) ~= "function" then
        F:RaiseDevError("Menu:New: config.builder must be a function")
        return
    end

    local name = config.name
    if name ~= nil then
        if type(name) ~= "string" or name == "" then
            F:RaiseDevError("Menu:New: config.name must be a non-empty string when supplied")
            return
        end
    else
        S.anonCounter = S.anonCounter + 1
        name = "F.Menu.anon." .. S.anonCounter
    end

    if liveKeys[name] then
        F:RaiseDevError("Menu:New: a live controller already owns the name '"
            .. name .. "'; :Destroy() it before re-registering")
        return
    end

    -- Feature-detect last: a config mistake reports as the config error, not
    -- as a missing MenuUtil.
    if not hasMenuUtil() then
        F:RaiseDevError("Menu:New: MenuUtil is not available on this client; "
            .. "Foundry.Menu requires Blizzard_Menu (Retail 11.0+, Classic Era 1.15.x, "
            .. "TBC Classic 2.5.x, Pandaria Classic 5.5.x, or later)")
        return
    end

    local c = setmetatable({}, Controller)
    c._name      = name
    c._builder   = builder
    c._destroyed = false

    c._generatorWrapper = function(owner, rootDescription, ...)
        return Menu._impl.generate(c, owner, rootDescription, ...)
    end

    liveKeys[name] = true

    S.instances[c] = true
    return c
end

-- Written last, so a copy that fails before this point leaves the serving
-- Menu reporting what it did before.
Menu.API_VERSION = API_VERSION
Menu._source = ...
Menu._build = BUILD

if not takingOver then
    F:RegisterModule("Menu", Menu)
end

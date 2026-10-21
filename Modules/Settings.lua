-- Foundry.Settings
--
-- A thin bridge over Blizzard's options-panel registration surface. One :New(config)
-- registers the panel through the modern Settings.* API and returns a controller
-- that owns the registered Blizzard category object. Foundry owns only the registration and the
-- resulting category; the consumer owns the panel frame and all of its controls.

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: Settings.lua requires the Foundry-1.0 bootstrap (Foundry.lua) "
        .. "to have loaded first; _G.Foundry_1_0 is missing.", 0)
end
-- Another copy of the library already registered this module: load nothing.
if F:HasModule("Settings") then return end

local Settings = {}
Settings.API_VERSION = 1

--------------------------------------------------------------------------------
-- Module-level live-key registry
--------------------------------------------------------------------------------

local liveKeys = {}

-- Registered-category cache: Blizzard can't unregister a category, so a
-- name's first registration is permanent. A later :New reuses it if the
-- inputs match, and refuses if they don't.
local registeredCategories = {}

--------------------------------------------------------------------------------
-- API detection (feature detection, not version checks or pcall)
--------------------------------------------------------------------------------

local function hasModernSettings()
    return type(_G.Settings) == "table"
        and type(_G.Settings.RegisterCanvasLayoutCategory) == "function"
        and type(_G.Settings.RegisterAddOnCategory) == "function"
end

--------------------------------------------------------------------------------
-- Controller
--------------------------------------------------------------------------------

local Controller = {}
Controller.__index = Controller

local function refuseIfDestroyed(self, method)
    if self._destroyed then
        F:RaiseDevError("Settings:" .. method .. " called on a destroyed controller")
        return true
    end
    return false
end

-- Opens the settings panel to this controller's category by calling
-- Settings.OpenToCategory directly. No timer defer is used.
function Controller:Open()
    if refuseIfDestroyed(self, "Open") then return end
    if self._mode == "settings" then
        _G.Settings.OpenToCategory(self._category:GetID())
    else
        -- Unreachable for a live controller: :New refuses when the Settings API is missing.
        return false, "unsupported-open"
    end
end

-- Returns the numeric category ID for Settings.OpenToCategory.
function Controller:GetCategoryID()
    if refuseIfDestroyed(self, "GetCategoryID") then return end
    if self._mode == "settings" then
        return self._category:GetID()
    end
    return nil
end

-- Returns the live Blizzard objects: frame, category, categoryID, mode
-- ("settings"), layout.
function Controller:GetNativeHandles()
    if refuseIfDestroyed(self, "GetNativeHandles") then return end
    local categoryID = nil
    if self._mode == "settings" and self._category then
        categoryID = self._category:GetID()
    end
    return {
        frame      = self._frame,
        category   = self._category,
        categoryID = categoryID,
        mode       = self._mode,
        layout     = self._layout,
    }
end

-- Destroys the controller. Idempotent; does not remove the Blizzard
-- category (no such API exists).
function Controller:Destroy()
    if self._destroyed then return end
    liveKeys[self._name] = nil
    self._destroyed = true
    self._category  = nil
    self._frame     = nil
    self._name      = nil
end

--------------------------------------------------------------------------------
-- Factory
--------------------------------------------------------------------------------

-- Creates a settings controller.
-- Config fields:
--   title  (required) -- player-facing category title.
--   frame  (required) -- the consumer-built panel to register.
--   parent (optional) -- a live Foundry.Settings controller, for a subcategory.
--   name   (optional) -- duplicate-refusal key; defaults to title.
function Settings:New(config)
    if type(config) ~= "table" then
        F:RaiseDevError("Settings:New: config must be a table")
        return
    end

    local title = config.title
    if type(title) ~= "string" or title == "" then
        F:RaiseDevError("Settings:New: config.title must be a non-empty string")
        return
    end

    local frame = config.frame
    if type(frame) ~= "table" or type(frame.GetObjectType) ~= "function" then
        F:RaiseDevError("Settings:New: config.frame must be a WoW frame (table with GetObjectType)")
        return
    end

    local parent = config.parent
    if parent ~= nil then
        if type(parent) ~= "table"
            or not parent._isSettingsController
            or parent._destroyed
        then
            F:RaiseDevError("Settings:New: config.parent must be a live Foundry.Settings controller or nil")
            return
        end
    end

    local name = config.name
    if name ~= nil then
        if type(name) ~= "string" or name == "" then
            F:RaiseDevError("Settings:New: config.name must be a non-empty string when supplied")
            return
        end
    else
        name = title
    end

    if liveKeys[name] then
        F:RaiseDevError("Settings:New: a live controller already owns the name '"
            .. name .. "'; :Destroy() it before re-registering")
        return
    end

    local category
    local layout
    local mode

    -- Every check runs before any Register* call: a registered category can
    -- never be removed.
    local cached = registeredCategories[name]
    if cached then
        local parentCategory = parent and parent._category or nil
        local mismatch = (cached.frame ~= frame and "frame")
            or (cached.title ~= title and "title")
            or (cached.parentCategory ~= parentCategory and "parent")
        if mismatch then
            F:RaiseDevError("Settings:New: name '" .. name .. "' already registered a "
                .. "Blizzard category this session with a different " .. mismatch
                .. "; categories cannot be unregistered, so a re-:New must reuse "
                .. "the same registration inputs")
            return
        end
        category, layout, mode = cached.category, cached.layout, cached.mode
    elseif hasModernSettings() then
        if parent then
            if type(parent._category) ~= "table" then
                F:RaiseDevError("Settings:New: config.parent has no valid category object")
                return
            end
            -- Child: RegisterCanvasLayoutSubcategory; do NOT call RegisterAddOnCategory.
            category, layout = _G.Settings.RegisterCanvasLayoutSubcategory(
                parent._category, frame, title)
        else
            -- Root: RegisterCanvasLayoutCategory + RegisterAddOnCategory (once only).
            category, layout = _G.Settings.RegisterCanvasLayoutCategory(frame, title)
            _G.Settings.RegisterAddOnCategory(category)
        end
        mode = "settings"
    else
        F:RaiseDevError("Settings:New: Blizzard's Settings API (Settings.RegisterCanvasLayoutCategory "
            .. "and Settings.RegisterAddOnCategory) is not available on this client")
        return
    end

    registeredCategories[name] = {
        category       = category,
        layout         = layout,
        frame          = frame,
        title          = title,
        mode           = mode,
        parentCategory = parent and parent._category or nil,
    }

    local c = setmetatable({}, Controller)
    c._category            = category
    c._layout              = layout
    c._frame               = frame
    c._mode                = mode
    c._name                = name
    c._destroyed           = false
    c._isSettingsController = true

    liveKeys[name] = true

    return c
end

F:RegisterModule("Settings", Settings)

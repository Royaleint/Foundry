-- Foundry.Settings
--
-- A thin bridge over Blizzard's options-panel registration surface. One :New(config)
-- registers either a consumer-built panel or a launcher entry (a category holding one
-- button that calls a consumer function) through the modern Settings.* API, and returns
-- a controller that owns the registered Blizzard category object. Foundry owns only the
-- registration and the resulting category; the consumer owns the panel frame and its
-- controls, or the window its launch function shows.

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: Settings.lua requires the Foundry-1.0 bootstrap (Foundry.lua) "
        .. "to have loaded first; _G.Foundry_1_0 is missing.", 0)
end
-- Another copy of the library already registered this module: load nothing.
if F:HasModule("Settings") then return end

local Settings = {}
Settings.API_VERSION = 1

-- true lets the Settings search find a launcher entry by its title and button text.
local LAUNCHER_ADD_SEARCH_TAGS = true

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

local function hasLauncherSettings()
    return type(_G.Settings) == "table"
        and type(_G.Settings.RegisterVerticalLayoutCategory) == "function"
        and type(_G.Settings.RegisterInitializer) == "function"
        and type(_G.Settings.RegisterAddOnCategory) == "function"
        and type(_G.CreateSettingsButtonInitializer) == "function"
end

-- Blizzard keeps a button's click function for the session, so the button
-- calls this wrapper, which dispatches to whichever controller currently owns
-- the name. Its arguments (button, mouse button, down) are not passed on.
local function makeLauncherClick(name)
    return function()
        local c = liveKeys[name]
        if c then
            c._launch()
        elseif F.IS_DEV_BUILD then
            F:RaiseDevError("Settings: the launcher button for '" .. name
                .. "' was clicked after its controller was destroyed; call :New again "
                .. "with the same title and buttonText to restore it")
        end
    end
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

-- Returns the live Blizzard objects: frame (nil for a launcher), category, categoryID,
-- mode ("settings"), layout, initializer (launcher only), and kind ("canvas" or "launcher").
function Controller:GetNativeHandles()
    if refuseIfDestroyed(self, "GetNativeHandles") then return end
    local categoryID = nil
    if self._mode == "settings" and self._category then
        categoryID = self._category:GetID()
    end
    return {
        frame       = self._frame,
        category    = self._category,
        categoryID  = categoryID,
        mode        = self._mode,
        layout      = self._layout,
        initializer = self._initializer,
        kind        = self._kind,
    }
end

-- Destroys the controller. Idempotent; does not remove the Blizzard
-- category (no such API exists).
function Controller:Destroy()
    if self._destroyed then return end
    liveKeys[self._name] = nil
    self._destroyed   = true
    self._category    = nil
    self._frame       = nil
    self._name        = nil
    self._launch      = nil
    self._initializer = nil
end

--------------------------------------------------------------------------------
-- Factory
--------------------------------------------------------------------------------

-- Creates a settings controller.
-- Config fields:
--   title  (required) -- player-facing category title.
--   frame  -- the consumer-built panel to register. Supply frame or launch, not both.
--   launch -- a function called with no arguments when the player clicks the entry's button; use it to show your own options window.
--   buttonText -- the button label; required with launch.
--   parent (optional) -- a live Foundry.Settings controller, for a subcategory. Not supported with launch.
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
    local launch = config.launch
    local buttonText = config.buttonText
    if frame ~= nil and launch ~= nil then
        F:RaiseDevError("Settings:New: supply exactly one of config.frame or config.launch")
        return
    end
    if frame == nil and launch == nil then
        F:RaiseDevError("Settings:New: config.frame must be a WoW frame (table with GetObjectType), "
            .. "or supply config.launch instead")
        return
    end

    local kind = launch ~= nil and "launcher" or "canvas"
    if kind == "canvas" then
        if type(frame) ~= "table" or type(frame.GetObjectType) ~= "function" then
            F:RaiseDevError("Settings:New: config.frame must be a WoW frame (table with GetObjectType)")
            return
        end
        if buttonText ~= nil then
            F:RaiseDevError("Settings:New: config.buttonText is only used with config.launch")
            return
        end
    else
        if type(launch) ~= "function" then
            F:RaiseDevError("Settings:New: config.launch must be a function")
            return
        end
        if type(buttonText) ~= "string" or buttonText == "" then
            F:RaiseDevError("Settings:New: config.buttonText must be a non-empty string when config.launch is used")
            return
        end
    end

    local parent = config.parent
    if parent ~= nil then
        if kind == "launcher" then
            F:RaiseDevError("Settings:New: config.parent is not supported with config.launch")
            return
        end
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
    local initializer
    local mode

    -- Every check runs before any Register* call: a registered category can
    -- never be removed.
    local cached = registeredCategories[name]
    if cached then
        local mismatch
        if cached.kind ~= kind then
            mismatch = "kind"
        elseif kind == "canvas" then
            local parentCategory = parent and parent._category or nil
            mismatch = (cached.frame ~= frame and "frame")
                or (cached.title ~= title and "title")
                or (cached.parentCategory ~= parentCategory and "parent")
        else
            mismatch = (cached.title ~= title and "title")
                or (cached.buttonText ~= buttonText and "buttonText")
        end
        if mismatch then
            F:RaiseDevError("Settings:New: name '" .. name .. "' already registered a "
                .. "Blizzard category this session with a different " .. mismatch
                .. "; categories cannot be unregistered, so a re-:New must reuse "
                .. "the same registration inputs")
            return
        end
        category, layout, initializer, mode =
            cached.category, cached.layout, cached.initializer, cached.mode
    elseif kind == "launcher" then
        if not hasLauncherSettings() then
            F:RaiseDevError("Settings:New: Blizzard's Settings API for launcher categories "
                .. "(Settings.RegisterVerticalLayoutCategory, Settings.RegisterInitializer, "
                .. "Settings.RegisterAddOnCategory and CreateSettingsButtonInitializer) "
                .. "is not available on this client")
            return
        end
        -- RegisterAddOnCategory must come last.
        category, layout = _G.Settings.RegisterVerticalLayoutCategory(title)
        initializer = _G.CreateSettingsButtonInitializer(
            title, buttonText, makeLauncherClick(name), nil, LAUNCHER_ADD_SEARCH_TAGS)
        _G.Settings.RegisterInitializer(category, initializer)
        _G.Settings.RegisterAddOnCategory(category)
        mode = "settings"
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
        kind           = kind,
        category       = category,
        layout         = layout,
        initializer    = initializer,
        frame          = frame,
        title          = title,
        buttonText     = buttonText,
        mode           = mode,
        parentCategory = parent and parent._category or nil,
    }

    local c = setmetatable({}, Controller)
    c._kind                = kind
    c._category            = category
    c._layout              = layout
    c._initializer         = initializer
    c._frame               = frame
    c._launch              = launch
    c._mode                = mode
    c._name                = name
    c._destroyed           = false
    c._isSettingsController = true

    liveKeys[name] = c

    return c
end

F:RegisterModule("Settings", Settings)

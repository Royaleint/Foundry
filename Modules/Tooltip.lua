-- Foundry.Tooltip
--
-- A controller for Blizzard's tooltip-hook system (TooltipDataProcessor).
-- :New(config) registers a typed post-call handler, with an optional
-- tooltip-frame whitelist, and returns a controller with :Destroy() and
-- :GetNativeHandles().

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: Tooltip.lua requires the Foundry-1.0 bootstrap (Foundry.lua) "
        .. "to have loaded first; _G.Foundry_1_0 is missing.", 0)
end

local BUILD = 1
local API_VERSION = 1

-- An older Tooltip already serving is taken over in place when this copy is
-- newer and the moment is safe; otherwise it keeps serving and this file loads
-- nothing. The checks only read, in a fixed order, and the first to fail names
-- the outcome; nil means this copy takes over. BUILD, API_VERSION, served and
-- takingOver are read at file scope only: no function below may capture them.
local served = F:HasModule("Tooltip") and F.Tooltip or nil
if served == nil and F:HasModule("Tooltip") then return end
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
        if type(state) ~= "table" or type(state.liveKeys) ~= "table"
            or type(state.dispatchers) ~= "table" or type(impl) ~= "table"
            or type(impl.Controller) ~= "table" then
            outcome = "refused: shape"
        end
    end
    if outcome then
        if outcome:sub(1, 9) == "refused: " and F.IS_DEV_BUILD then
            F:RaiseDevError("Tooltip: a newer copy from " .. tostring((...))
                .. " did not take over (" .. outcome .. ")")
        end
        return
    end
end
local takingOver = served ~= nil

-- On a takeover every definition below lands in the serving tables, so the
-- older copy's controllers and post-calls reach the newer code.
local Tooltip = served or {}

-- All module state lives on the module table.
if not takingOver then
    Tooltip._layoutVersion = 1
    Tooltip._state = {
        liveKeys = {},
        dispatchers = {},   -- tooltipType -> { head = controller, tail = controller }
    }
    Tooltip._impl = {}
end
local S, I = Tooltip._state, Tooltip._impl
local liveKeys, dispatchers = S.liveKeys, S.dispatchers

--------------------------------------------------------------------------------
-- Feature detection (checked at :New, never at file scope)
--------------------------------------------------------------------------------

local function hasTooltipDataProcessor()
    return type(_G.TooltipDataProcessor) == "table"
        and type(_G.TooltipDataProcessor.AddTooltipPostCall) == "function"
end

--------------------------------------------------------------------------------
-- Per-type dispatchers
--
-- TooltipDataProcessor has no removal API, so exactly one post-call is
-- registered per tooltip type for the module lifetime. It dispatches into a
-- mutable list of live controllers, so Destroy really stops a handler running.
--
-- The list is singly linked through each controller's _next field, so that
-- removing an entry never shifts the position of another. A handler may
-- Destroy and New controllers of its own type, or trigger another render of
-- that type, while a dispatch is walking the list, and the walk needs no
-- in-progress state that an erroring handler could leave set. Two rules keep
-- an in-flight walk correct:
--   1. An unlinked entry keeps its _next. A walk standing on it still follows
--      the chain forward into entries that are in the list. The cost: a
--      destroyed controller that its owner still references keeps every
--      later controller of its type reachable. Set the handle to nil after
--      Destroy to let them be collected.
--   2. The tail is never unlinked. A controller created while a walk stands on
--      the tail is appended to the tail's _next, so that walk still reaches it.
--      A destroyed tail is unlinked by a later sweep, once something follows it.
--------------------------------------------------------------------------------

-- Unlinks destroyed controllers, except the tail (rule 2 above). Runs from
-- New and after each dispatch; the rules above make it safe while a walk is
-- in progress.
local function sweep(list)
    local prev, c = nil, list.head
    while c do
        local nextC = c._next
        if c._destroyed and nextC then
            if prev then prev._next = nextC else list.head = nextC end
        else
            prev = c
        end
        c = nextC
    end
end
I.sweep = sweep

-- Runs every live controller of one tooltip type whose filter matches.
local function dispatch(list, tooltip, data)
    local c = list.head
    while c do
        if not c._destroyed and (not c._filter or c._filter[tooltip]) then
            c._handler(tooltip, data)
        end
        -- Read after the handler: it may have appended to the tail.
        c = c._next
    end
    sweep(list)
end
I.dispatch = dispatch

local function ensureDispatcher(tooltipType)
    local list = dispatchers[tooltipType]
    if list then return list end
    list = {}
    -- Register before recording: if AddTooltipPostCall throws, no dispatcher
    -- entry is left behind for this type.
    _G.TooltipDataProcessor.AddTooltipPostCall(tooltipType, function(tooltip, data)
        return Tooltip._impl.dispatch(list, tooltip, data)
    end)
    dispatchers[tooltipType] = list
    return list
end
I.ensureDispatcher = ensureDispatcher

--------------------------------------------------------------------------------
-- Line emitters (module-level helpers)
--------------------------------------------------------------------------------

-- Adds a line to the tooltip. r, g, b default to white when omitted.
function Tooltip.AddLine(tooltip, text, r, g, b)
    tooltip:AddLine(text, r or 1, g or 1, b or 1)
end

-- Adds a blank separator line.
function Tooltip.AddSeparator(tooltip)
    tooltip:AddLine(" ")
end

--------------------------------------------------------------------------------
-- Controller
--------------------------------------------------------------------------------

local Controller = I.Controller or {}
Controller.__index = Controller
I.Controller = Controller

local function refuseIfDestroyed(self, method)
    if self._destroyed then
        F:RaiseDevError("Tooltip:" .. method .. " called on a destroyed controller")
        return true
    end
    return false
end

-- Returns the raw Blizzard objects: tooltipDataProcessor, type (the
-- registered TooltipDataType number).
function Controller:GetNativeHandles()
    if refuseIfDestroyed(self, "GetNativeHandles") then return end
    return {
        tooltipDataProcessor = _G.TooltipDataProcessor,
        type                 = self._type,
    }
end

-- Destroys the controller and frees its name. Idempotent. Only flags the
-- entry and leaves _next alone: a walk may be standing on this controller,
-- and the sweep unlinks it later.
function Controller:Destroy()
    if self._destroyed then return end
    liveKeys[self._name] = nil
    self._destroyed = true
    self._handler   = nil
    self._name      = nil
    self._filter    = nil
end

--------------------------------------------------------------------------------
-- Factory
--------------------------------------------------------------------------------

-- Creates a tooltip post-call controller.
-- Config fields:
--   type     (required) -- Enum.TooltipDataType value (a number).
--   handler  (required) -- function(tooltip, data), called per matching tooltip.
--   tooltips (optional) -- array of tooltip frames to restrict to; nil fires
--                          for all tooltips of the registered type.
--   name     (optional) -- duplicate-refusal key; defaults to tostring(type).
function Tooltip:New(config)
    if type(config) ~= "table" then
        F:RaiseDevError("Tooltip:New: config must be a table")
        return
    end

    local tooltipType = config.type
    if type(tooltipType) ~= "number" then
        F:RaiseDevError("Tooltip:New: config.type must be a number (Enum.TooltipDataType value)")
        return
    end

    local handler = config.handler
    if type(handler) ~= "function" then
        F:RaiseDevError("Tooltip:New: config.handler must be a function")
        return
    end

    local tooltips = config.tooltips
    local filter = nil
    if tooltips ~= nil then
        if type(tooltips) ~= "table" then
            F:RaiseDevError("Tooltip:New: config.tooltips must be an array of tooltip frames or nil")
            return
        end
        filter = {}
        for i = 1, #tooltips do
            local t = tooltips[i]
            if type(t) ~= "table" then
                F:RaiseDevError("Tooltip:New: config.tooltips[" .. i
                    .. "] must be a tooltip frame (table)")
                return
            end
            filter[t] = true
        end
    end

    local name = config.name
    if name ~= nil then
        if type(name) ~= "string" or name == "" then
            F:RaiseDevError("Tooltip:New: config.name must be a non-empty string when supplied")
            return
        end
    else
        name = tostring(tooltipType)
    end

    if liveKeys[name] then
        F:RaiseDevError("Tooltip:New: a live controller already owns the name '"
            .. name .. "'; :Destroy() it before re-registering")
        return
    end

    if not hasTooltipDataProcessor() then
        F:RaiseDevError("Tooltip:New: TooltipDataProcessor is not available on this client "
            .. "(it ships on Retail 10.0.2+, Classic Era 1.15.x, and Pandaria Classic "
            .. "5.5.x); Foundry.Tooltip is unavailable here")
        return
    end

    local c = setmetatable({}, Controller)
    c._type               = tooltipType
    c._handler            = handler
    c._filter             = filter
    c._name               = name
    c._destroyed          = false
    c._isTooltipController = true

    local list = ensureDispatcher(tooltipType)
    -- Also sweep here: the dispatcher only sweeps on render, so a
    -- never-rendered type would grow unbounded.
    sweep(list)
    if list.tail then list.tail._next = c else list.head = c end
    list.tail = c

    liveKeys[name] = true

    return c
end

-- Written last, so a copy that fails before this point leaves the serving
-- Tooltip reporting what it did before.
Tooltip.API_VERSION = API_VERSION
Tooltip._source = ...
Tooltip._build = BUILD

if not takingOver then
    F:RegisterModule("Tooltip", Tooltip)
end

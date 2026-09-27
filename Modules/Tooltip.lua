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
-- Already registered by another embedded copy: load nothing.
if F:HasModule("Tooltip") then return end

local Tooltip = {}
Tooltip.API_VERSION = 1

--------------------------------------------------------------------------------
-- Feature detection (checked at :New, never at file scope)
--------------------------------------------------------------------------------

local function hasTooltipDataProcessor()
    return type(_G.TooltipDataProcessor) == "table"
        and type(_G.TooltipDataProcessor.AddTooltipPostCall) == "function"
end

--------------------------------------------------------------------------------
-- Module-level live-key registry
--------------------------------------------------------------------------------

local liveKeys = {}

--------------------------------------------------------------------------------
-- Per-type dispatchers
--
-- TooltipDataProcessor has no removal API, so exactly one post-call is
-- registered per tooltip type for the module lifetime, dispatching into a
-- mutable list of live controllers -- Destroy actually stops the cost.
--------------------------------------------------------------------------------

local dispatchers = {}   -- tooltipType → array of live controllers

local function ensureDispatcher(tooltipType)
    local list = dispatchers[tooltipType]
    if list then return list end
    list = {}
    _G.TooltipDataProcessor.AddTooltipPostCall(tooltipType, function(tooltip, data)
        local i = 1
        while i <= #list do
            local c = list[i]
            if c._destroyed then
                table.remove(list, i)
            else
                if not c._filter or c._filter[tooltip] then
                    c._handler(tooltip, data)
                end
                i = i + 1
            end
        end
    end)
    dispatchers[tooltipType] = list
    return list
end

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

local Controller = {}
Controller.__index = Controller

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

-- Only flags; the dispatcher sweeps flagged entries in place, so never
-- table.remove here (mid-dispatch Destroy would corrupt the loop).
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
--   type     (required) — Enum.TooltipDataType value (a number).
--   handler  (required) — function(tooltip, data), called per matching tooltip.
--   tooltips (optional) — array of tooltip frames to restrict to; nil fires
--                         for all tooltips of the registered type.
--   name     (optional) — duplicate-refusal key; defaults to tostring(type).
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
    local i = 1
    while i <= #list do
        if list[i]._destroyed then table.remove(list, i) else i = i + 1 end
    end
    list[#list + 1] = c

    liveKeys[name] = true

    return c
end

F:RegisterModule("Tooltip", Tooltip)

-- Foundry.Tooltip
--
-- A thin bridge over Blizzard's modern tooltip-hook system (TooltipDataProcessor,
-- Retail 10.0.2+). :New(config) registers a typed post-call handler, applies an
-- optional tooltip-frame whitelist, and returns a controller with :Destroy() and
-- :GetNativeHandles(). Two line-emitter helpers are provided as module-level
-- functions. TooltipDataProcessor has no public unregister API; :Destroy() disables
-- the registered callback in-place rather than removing it from the dispatch list.
--
-- Retail-only: fails loud when TooltipDataProcessor is absent. Classic Era and
-- Pandaria Classic do not carry TooltipDataProcessor; there is no OnTooltipSetItem
-- fallback (global tooltip hijacks are out of scope per Charter §3.3).

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: Tooltip.lua requires the Foundry-1.0 bootstrap (Foundry.lua) "
        .. "to have loaded first; _G.Foundry_1_0 is missing.", 0)
end
-- Guarded-embedding stand-down (§2.2b): if this module is already registered on the
-- winning copy, this is a redundant embedded copy — load nothing.
if F:HasModule("Tooltip") then return end

local Tooltip = {}
Tooltip.API_VERSION = 1

--------------------------------------------------------------------------------
-- Feature detection (Retail-only surface; checked at :New, never at file scope)
--------------------------------------------------------------------------------

local function hasTooltipDataProcessor()
    return type(_G.TooltipDataProcessor) == "table"
        and type(_G.TooltipDataProcessor.AddTooltipPostCall) == "function"
end

--------------------------------------------------------------------------------
-- Module-level live-key registry
-- Maps name string → true for every controller that has not been :Destroy()ed.
--------------------------------------------------------------------------------

local liveKeys = {}

--------------------------------------------------------------------------------
-- Line emitters (module-level helpers)
--
-- Thin convenience wrappers for the two patterns consumers repeat most often.
-- Both operate directly on the tooltip argument passed by TooltipDataProcessor.
--------------------------------------------------------------------------------

-- Add a line to the tooltip. r, g, b default to 1, 1, 1 (white) when omitted.
function Tooltip.AddLine(tooltip, text, r, g, b)
    tooltip:AddLine(text, r or 1, g or 1, b or 1)
end

-- Add a blank separator line. Standard inter-section visual gap.
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

-- Returns the raw Blizzard objects this controller was built against. A fresh
-- table is returned per call; mutating it does not corrupt controller state.
-- Keys: tooltipDataProcessor (the _G global at :New time), type (the registered
-- TooltipDataType number).
function Controller:GetNativeHandles()
    if refuseIfDestroyed(self, "GetNativeHandles") then return end
    return {
        tooltipDataProcessor = _G.TooltipDataProcessor,
        type                 = self._type,
    }
end

-- Marks the controller destroyed, frees the duplicate-refusal key, and disables
-- the registered callback in-place. TooltipDataProcessor.AddTooltipPostCall has
-- no public removal counterpart; the registered wrapper checks _destroyed on
-- every invocation and returns immediately when set. Idempotent: a second
-- :Destroy() is a silent no-op.
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

-- Create a tooltip post-call controller. Validation is atomic: every field is
-- checked before TooltipDataProcessor.AddTooltipPostCall is called. A rejected
-- :New leaves prior registrations untouched.
--
-- Config fields:
--   type     (required) — Enum.TooltipDataType value (a number).
--   handler  (required) — function(tooltip, data) called per matching tooltip.
--   tooltips (optional) — array of tooltip frame objects; the handler fires only
--                         when the incoming tooltip is one of them. nil fires for
--                         all tooltips of the registered type.
--   name     (optional, non-empty string) — duplicate-refusal key; defaults to
--                         tostring(type) when not supplied.
function Tooltip:New(config)
    if type(config) ~= "table" then
        F:RaiseDevError("Tooltip:New: config must be a table")
        return
    end

    -- 1. Validate type.
    local tooltipType = config.type
    if type(tooltipType) ~= "number" then
        F:RaiseDevError("Tooltip:New: config.type must be a number (Enum.TooltipDataType value)")
        return
    end

    -- 2. Validate handler.
    local handler = config.handler
    if type(handler) ~= "function" then
        F:RaiseDevError("Tooltip:New: config.handler must be a function")
        return
    end

    -- 3. Validate and build the optional tooltips whitelist.
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

    -- 4. Resolve name; validate if explicitly supplied.
    local name = config.name
    if name ~= nil then
        if type(name) ~= "string" or name == "" then
            F:RaiseDevError("Tooltip:New: config.name must be a non-empty string when supplied")
            return
        end
    else
        name = tostring(tooltipType)
    end

    -- 5. Duplicate-key check.
    if liveKeys[name] then
        F:RaiseDevError("Tooltip:New: a live controller already owns the name '"
            .. name .. "'; :Destroy() it before re-registering")
        return
    end

    -- 6. Feature-detect TooltipDataProcessor (Retail-only).
    if not hasTooltipDataProcessor() then
        F:RaiseDevError("Tooltip:New: TooltipDataProcessor is not available on this client; "
            .. "Foundry.Tooltip requires Retail 10.0.2 or later")
        return
    end

    -- 7. Construct controller before registering so the upvalue captured in the
    --    callback closure is the fully-initialised controller.
    local c = setmetatable({}, Controller)
    c._type               = tooltipType
    c._handler            = handler
    c._filter             = filter
    c._name               = name
    c._destroyed          = false
    c._isTooltipController = true

    -- 8. Register with TooltipDataProcessor. The wrapper holds c by upvalue so
    --    :Destroy() (which nils c._handler and sets c._destroyed) silences all
    --    future deliveries without any public unregister call.
    _G.TooltipDataProcessor.AddTooltipPostCall(tooltipType, function(tooltip, data)
        if c._destroyed then return end
        if c._filter and not c._filter[tooltip] then return end
        c._handler(tooltip, data)
    end)

    -- 9. Register the key.
    liveKeys[name] = true

    return c
end

F:RegisterModule("Tooltip", Tooltip)

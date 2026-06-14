-- Foundry.Events
--
-- A thin registry over WoW's native frame-event system (CreateFrame("Frame"),
-- :RegisterEvent / :RegisterUnitEvent, and the OnEvent script). One controller
-- per consumer owns a single hidden frame and an event -> handler table, so
-- registration, dispatch, and teardown all live in one place. The native
-- primitive stays reachable underneath via :GetNativeHandles().

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: Events.lua requires the Foundry-1.0 bootstrap (Foundry.lua) "
        .. "to have loaded first; _G.Foundry_1_0 is missing.", 0)
end
-- Guarded-embedding stand-down (§2.2b): if this module is already registered on the
-- winning copy, this is a redundant embedded copy — load nothing. Silent no-op on
-- the first load (not registered yet). Zero new surface on F (HasModule already exists).
if F:HasModule("Events") then return end

local Events = {}
Events.API_VERSION = 1

--------------------------------------------------------------------------------
-- Controller
--------------------------------------------------------------------------------

local Controller = {}
Controller.__index = Controller

-- Register a standard frame event. One handler per event: a duplicate is
-- rejected (Foundry prefers a refused operation over a silent overwrite),
-- leaving the existing registration unchanged. Validation is atomic -- a
-- rejected call mutates neither the handler table nor the native frame.
function Controller:Register(event, handler)
    if self._destroyed then
        F:RaiseDevError("Events:Register called on a destroyed controller")
        return
    end
    if type(event) ~= "string" or event == "" then
        F:RaiseDevError("Events:Register: event must be a non-empty string")
        return
    end
    if type(handler) ~= "function" then
        F:RaiseDevError("Events:Register: event '" .. event
            .. "' requires a handler function")
        return
    end
    if self._handlers[event] then
        F:RaiseDevError("Events:Register: event '" .. event
            .. "' is already registered; Unregister it first to replace the handler")
        return
    end

    self._handlers[event] = handler
    self._frame:RegisterEvent(event)
end

-- Register a unit-filtered frame event. Identical to :Register but subscribes
-- via frame:RegisterUnitEvent(event, unit1 [, unit2]). unit1 is required;
-- unit2 is optional. Validation is atomic.
function Controller:RegisterUnit(event, handler, unit1, unit2)
    if self._destroyed then
        F:RaiseDevError("Events:RegisterUnit called on a destroyed controller")
        return
    end
    if type(event) ~= "string" or event == "" then
        F:RaiseDevError("Events:RegisterUnit: event must be a non-empty string")
        return
    end
    if type(handler) ~= "function" then
        F:RaiseDevError("Events:RegisterUnit: event '" .. event
            .. "' requires a handler function")
        return
    end
    if type(unit1) ~= "string" or unit1 == "" then
        F:RaiseDevError("Events:RegisterUnit: event '" .. event
            .. "' requires unit1 to be a non-empty string")
        return
    end
    if unit2 ~= nil and (type(unit2) ~= "string" or unit2 == "") then
        F:RaiseDevError("Events:RegisterUnit: event '" .. event
            .. "' unit2, when supplied, must be a non-empty string")
        return
    end
    if self._handlers[event] then
        F:RaiseDevError("Events:RegisterUnit: event '" .. event
            .. "' is already registered; Unregister it first to replace the handler")
        return
    end

    self._handlers[event] = handler
    if unit2 ~= nil then
        self._frame:RegisterUnitEvent(event, unit1, unit2)
    else
        self._frame:RegisterUnitEvent(event, unit1)
    end
end

-- Register a handler that auto-unregisters after its first fire, so it runs
-- exactly once. The auto-unregister happens BEFORE the consumer's handler is
-- invoked (ordering is fixed): the event slot is already free by the time the
-- handler runs, so a handler that re-registers the same event in its own body
-- behaves predictably.
function Controller:RegisterOnce(event, handler)
    if self._destroyed then
        F:RaiseDevError("Events:RegisterOnce called on a destroyed controller")
        return
    end
    if type(event) ~= "string" or event == "" then
        F:RaiseDevError("Events:RegisterOnce: event must be a non-empty string")
        return
    end
    if type(handler) ~= "function" then
        F:RaiseDevError("Events:RegisterOnce: event '" .. event
            .. "' requires a handler function")
        return
    end
    if self._handlers[event] then
        F:RaiseDevError("Events:RegisterOnce: event '" .. event
            .. "' is already registered; Unregister it first to replace the handler")
        return
    end

    -- The wrapper unregisters before invoking, so the slot is free for any
    -- re-registration the handler performs in its own body.
    local function once(ev, ...)
        self:Unregister(ev)
        handler(ev, ...)
    end

    self._handlers[event] = once
    self._frame:RegisterEvent(event)
end

-- Remove the handler for one event and call the matching native unregister.
-- Idempotent: unregistering an event that is not registered is a no-op, not an
-- error.
function Controller:Unregister(event)
    if self._destroyed then
        F:RaiseDevError("Events:Unregister called on a destroyed controller")
        return
    end
    if type(event) ~= "string" or event == "" then
        F:RaiseDevError("Events:Unregister: event must be a non-empty string")
        return
    end
    if not self._handlers[event] then return end
    self._handlers[event] = nil
    self._frame:UnregisterEvent(event)
end

-- Remove every handler this controller owns and call the native
-- UnregisterAllEvents. "Stop listening to everything I set up" in one call.
function Controller:UnregisterAll()
    if self._destroyed then
        F:RaiseDevError("Events:UnregisterAll called on a destroyed controller")
        return
    end
    for event in pairs(self._handlers) do
        self._handlers[event] = nil
    end
    self._frame:UnregisterAllEvents()
end

-- Whether this controller currently holds a handler for event. No side effects.
function Controller:IsRegistered(event)
    if self._destroyed then
        F:RaiseDevError("Events:IsRegistered called on a destroyed controller")
        return
    end
    return self._handlers[event] ~= nil
end

-- The progressive-disclosure escape hatch. Returns the live shared frame and a
-- shallow COPY (snapshot) of the event -> handler table. Mutating the snapshot
-- cannot affect live dispatch; the frame, by contrast, is the live object.
function Controller:GetNativeHandles()
    if self._destroyed then
        F:RaiseDevError("Events:GetNativeHandles called on a destroyed controller")
        return
    end
    local snapshot = {}
    for event, handler in pairs(self._handlers) do
        snapshot[event] = handler
    end
    return {
        frame = self._frame,
        handlers = snapshot,
    }
end

-- Tear down: unregister every event, clear the dispatch table, detach the
-- OnEvent script, hide and release the shared frame, mark destroyed. After
-- this, every controller method fails loudly (mirrors Commands).
function Controller:Destroy()
    if self._destroyed then
        F:RaiseDevError("Events:Destroy called on a destroyed controller")
        return
    end
    local frame = self._frame
    frame:UnregisterAllEvents()
    for event in pairs(self._handlers) do
        self._handlers[event] = nil
    end
    frame:SetScript("OnEvent", nil)
    frame:Hide()
    self._destroyed = true
end

--------------------------------------------------------------------------------
-- Factory
--------------------------------------------------------------------------------

-- Create a controller scoped to one consumer. owner is a stored identity label;
-- it is not read elsewhere (it does not name the frame, appear in diagnostics, or
-- scope :UnregisterAll, which is instance-scoped). Each call owns exactly one
-- hidden frame and one event -> handler table; no event is registered until the
-- first :Register.
function Events:New(owner)
    if type(owner) ~= "string" or owner == "" then
        F:RaiseDevError("Events:New: owner must be a non-empty string")
        return
    end

    local c = setmetatable({}, Controller)
    c._owner = owner
    c._handlers = {}
    c._destroyed = false

    local frame = CreateFrame("Frame")
    frame:Hide()
    c._frame = frame

    -- One OnEvent script for all of this controller's events. It dispatches by
    -- event name to the stored handler and drops the native frame self, calling
    -- handler(event, ...). A fire for an event with no live handler is ignored
    -- (the handler table is the source of truth; the frame can momentarily
    -- carry an event that is mid-teardown).
    frame:SetScript("OnEvent", function(_, event, ...)
        local handler = c._handlers[event]
        if handler then
            handler(event, ...)
        end
    end)

    return c
end

F:RegisterModule("Events", Events)

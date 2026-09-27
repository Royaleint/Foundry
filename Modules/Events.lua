-- Foundry.Events
--
-- A registry over WoW's frame-event system. Each :New(owner) call owns one
-- hidden frame and dispatches registered events to their handlers.

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: Events.lua requires the Foundry-1.0 bootstrap (Foundry.lua) "
        .. "to have loaded first; _G.Foundry_1_0 is missing.", 0)
end
-- Already registered by another embedded copy: load nothing.
if F:HasModule("Events") then return end

local Events = {}
Events.API_VERSION = 2

--------------------------------------------------------------------------------
-- Controller
--------------------------------------------------------------------------------

local Controller = {}
Controller.__index = Controller

-- Without C_EventUtils, an invalid event name throws from the native call;
-- the controller is left unchanged, so Register* call the native register
-- before any bookkeeping.
local function isEventValid(event)
    local eventUtils = _G.C_EventUtils
    return not eventUtils or not eventUtils.IsEventValid or eventUtils.IsEventValid(event)
end

-- Registers a frame event; handler(event, ...) fires on each occurrence.
-- Refuses a duplicate registration for the same event.
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
    if not isEventValid(event) then
        F:RaiseDevError("Events:Register: '" .. event .. "' is not a valid event on this client")
        return
    end

    self._frame:RegisterEvent(event)
    self._handlers[event] = handler
end

-- Registers a unit-filtered event via RegisterUnitEvent(event, unit1[, unit2]);
-- unit1 is required, unit2 is optional.
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
    if not isEventValid(event) then
        F:RaiseDevError("Events:RegisterUnit: '" .. event .. "' is not a valid event on this client")
        return
    end

    if unit2 ~= nil then
        self._frame:RegisterUnitEvent(event, unit1, unit2)
    else
        self._frame:RegisterUnitEvent(event, unit1)
    end
    self._handlers[event] = handler
end

-- Registers a handler that fires once, then unregisters itself (safe to
-- re-register the same event from inside the handler).
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
    if not isEventValid(event) then
        F:RaiseDevError("Events:RegisterOnce: '" .. event .. "' is not a valid event on this client")
        return
    end

    local function once(ev, ...)
        self:Unregister(ev)
        handler(ev, ...)
    end

    self._frame:RegisterEvent(event)
    self._handlers[event] = once
end

--------------------------------------------------------------------------------
-- Bucket (RegisterBucket)
--------------------------------------------------------------------------------

-- A bucket coalesces a burst of events into one delayed handler call.
local Bucket = {}
Bucket.__index = Bucket

-- Whether a flush is currently scheduled.
function Bucket:IsPending()
    return self._timer ~= nil
end

-- Cancels the bucket: unregisters its events and any pending flush.
-- Idempotent; safe after Destroy/UnregisterAll.
function Bucket:Cancel()
    if self._cancelled then return end
    local c = self._controller
    for _, event in ipairs(self._events) do
        c._handlers[event] = nil
        c._bucketEvents[event] = nil
        c._frame:UnregisterEvent(event)
    end
    for i = #c._buckets, 1, -1 do
        if c._buckets[i] == self then
            table.remove(c._buckets, i)
            break
        end
    end
    self:_teardown()
end

-- Cancels only the pending flush timer; native unregister is the caller's job.
function Bucket:_teardown()
    if self._cancelled then return end
    self._cancelled = true
    self._deadline = nil
    if self._timer then
        self._timer:Cancel()
        self._timer = nil
    end
end

-- Coalesces a burst of one or more events into one handler() call per
-- quiet-window. spec fields:
--   events   -- an event-name string, or array of event-name strings.
--   interval -- coalescing window in seconds (a number > 0).
--   edge     -- "leading" (default) or "trailing". leading: fires interval
--              after the first event; trailing: fires once events stay
--              quiet for interval.
--   handler  -- called once per window, with no arguments.
-- Returns a bucket handle exposing :Cancel() and :IsPending().
function Controller:RegisterBucket(spec)
    if self._destroyed then
        F:RaiseDevError("Events:RegisterBucket called on a destroyed controller")
        return
    end
    if type(spec) ~= "table" then
        F:RaiseDevError("Events:RegisterBucket: spec must be a table")
        return
    end

    local events = spec.events
    local list
    if type(events) == "string" then
        if events == "" then
            F:RaiseDevError("Events:RegisterBucket: events string must be non-empty")
            return
        end
        list = { events }
    elseif type(events) == "table" then
        if #events == 0 then
            F:RaiseDevError("Events:RegisterBucket: events array must be non-empty")
            return
        end
        local seen = {}
        list = {}
        for i = 1, #events do
            local ev = events[i]
            if type(ev) ~= "string" or ev == "" then
                F:RaiseDevError("Events:RegisterBucket: every event must be a non-empty string")
                return
            end
            if seen[ev] then
                F:RaiseDevError("Events:RegisterBucket: duplicate event '" .. ev
                    .. "' in the events array")
                return
            end
            seen[ev] = true
            list[#list + 1] = ev
        end
    else
        F:RaiseDevError("Events:RegisterBucket: events must be a string or an array of strings")
        return
    end

    -- Positive form rejects NaN and +inf; a "<= 0" check passes both.
    if type(spec.interval) ~= "number"
        or not (spec.interval > 0 and spec.interval < math.huge) then
        F:RaiseDevError("Events:RegisterBucket: interval must be a finite number > 0")
        return
    end

    local edge = spec.edge
    if edge == nil then
        edge = "leading"
    elseif edge ~= "leading" and edge ~= "trailing" then
        F:RaiseDevError("Events:RegisterBucket: edge must be 'leading' or 'trailing' when supplied")
        return
    end

    if type(spec.handler) ~= "function" then
        F:RaiseDevError("Events:RegisterBucket: handler must be a function")
        return
    end

    for i = 1, #list do
        if self._handlers[list[i]] then
            F:RaiseDevError("Events:RegisterBucket: event '" .. list[i]
                .. "' is already registered; Unregister it (or Cancel its bucket) first")
            return
        end
    end

    for i = 1, #list do
        if not isEventValid(list[i]) then
            F:RaiseDevError("Events:RegisterBucket: '" .. list[i]
                .. "' is not a valid event on this client")
            return
        end
    end

    local bucket = setmetatable({}, Bucket)
    bucket._controller = self
    bucket._events = list
    bucket._interval = spec.interval
    bucket._edge = edge
    bucket._handler = spec.handler
    bucket._timer = nil
    bucket._deadline = nil
    bucket._cancelled = false

    local newTimer = C_Timer.NewTimer
    local getTime = GetTime

    local function flush()
        if bucket._cancelled then return end
        local deadline = bucket._deadline
        if deadline then
            local remaining = deadline - getTime()
            if remaining > 0 then
                bucket._timer = newTimer(remaining, flush)
                return
            end
        end
        bucket._timer = nil
        bucket._deadline = nil
        bucket._handler()
    end

    local function onFire()
        if bucket._cancelled then return end
        if edge == "leading" then
            if bucket._timer then return end
            bucket._timer = newTimer(bucket._interval, flush)
        else
            bucket._deadline = getTime() + bucket._interval
            if not bucket._timer then
                bucket._timer = newTimer(bucket._interval, flush)
            end
        end
    end

    -- Without C_EventUtils a bad name can still throw here; roll back what
    -- registered so the controller is unchanged.
    local registered = 0
    local ok, nativeErr = pcall(function()
        for i = 1, #list do
            self._frame:RegisterEvent(list[i])
            registered = i
        end
    end)
    if not ok then
        for i = 1, registered do
            self._frame:UnregisterEvent(list[i])
        end
        error(nativeErr, 0)
    end

    for i = 1, #list do
        self._handlers[list[i]] = onFire
        self._bucketEvents[list[i]] = bucket
    end
    self._buckets[#self._buckets + 1] = bucket

    return bucket
end

-- Unregisters event's handler. Idempotent: a no-op if not registered.
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
    if self._bucketEvents[event] then
        F:RaiseDevError("Events:Unregister: event '" .. event
            .. "' is owned by a bucket; call bucket:Cancel() to remove it")
        return
    end
    self._handlers[event] = nil
    self._frame:UnregisterEvent(event)
end

-- Unregisters every handler this controller owns, including buckets.
function Controller:UnregisterAll()
    if self._destroyed then
        F:RaiseDevError("Events:UnregisterAll called on a destroyed controller")
        return
    end
    for i = #self._buckets, 1, -1 do
        self._buckets[i]:_teardown()
        self._buckets[i] = nil
    end
    for event in pairs(self._bucketEvents) do
        self._bucketEvents[event] = nil
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

-- Returns the raw frame and a snapshot copy of the event -> handler table.
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

-- Tears down the controller. Every method fails loudly after this.
function Controller:Destroy()
    if self._destroyed then
        F:RaiseDevError("Events:Destroy called on a destroyed controller")
        return
    end
    local frame = self._frame
    frame:UnregisterAllEvents()
    for i = #self._buckets, 1, -1 do
        self._buckets[i]:_teardown()
        self._buckets[i] = nil
    end
    for event in pairs(self._bucketEvents) do
        self._bucketEvents[event] = nil
    end
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

-- Creates a controller scoped to one consumer; owner is a stored label only.
-- No event is registered until the first :Register call.
function Events:New(owner)
    if type(owner) ~= "string" or owner == "" then
        F:RaiseDevError("Events:New: owner must be a non-empty string")
        return
    end

    local c = setmetatable({}, Controller)
    c._owner = owner
    c._handlers = {}
    c._bucketEvents = {}
    c._buckets = {}
    c._destroyed = false

    local frame = CreateFrame("Frame")
    frame:Hide()
    c._frame = frame

    frame:SetScript("OnEvent", function(_, event, ...)
        local handler = c._handlers[event]
        if handler then
            handler(event, ...)
        end
    end)

    return c
end

F:RegisterModule("Events", Events)

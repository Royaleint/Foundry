-- Foundry.List
--
-- A controller over Blizzard's ScrollBox system. :New(config) builds the
-- scroll frame, bar, view, and data provider, and returns SetData,
-- ForEachFrame, GetNativeHandles, and Destroy. Linear list view only.

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: List.lua requires the Foundry-1.0 bootstrap (Foundry.lua) "
        .. "to have loaded first; _G.Foundry_1_0 is missing.", 0)
end
-- Already registered by another embedded copy: load nothing.
if F:HasModule("List") then return end

local List = {}
List.API_VERSION = 1

--------------------------------------------------------------------------------
-- ScrollBox-system capability gate (flavor support)
--------------------------------------------------------------------------------

local function hasScrollBoxSystem()
    return type(ScrollUtil) == "table"
        and type(ScrollUtil.InitScrollBoxListWithScrollBar) == "function"
        and type(CreateScrollBoxListLinearView) == "function"
        and type(CreateDataProvider) == "function"
end

--------------------------------------------------------------------------------
-- Controller
--------------------------------------------------------------------------------

local Controller = {}
Controller.__index = Controller

local function refuseIfDestroyed(self, method)
    if self._destroyed then
        F:RaiseDevError("List:" .. method .. " called on a destroyed controller")
        return true
    end
    return false
end

-- Replaces the row set (rebuilds the DataProvider; not an in-place recycle)
-- and scrolls to top. Rows must be an array of tables.
function Controller:SetData(rows)
    if refuseIfDestroyed(self, "SetData") then return end
    -- Unsafe to call from inside an initializer callback (Blizzard's Acquire
    -- reentrancy guard doesn't cover it).
    if self._inInitializer then
        F:RaiseDevError("List:SetData: cannot mutate data from inside an initializer")
        return
    end
    if type(rows) ~= "table" then
        F:RaiseDevError("List:SetData: data must be an array of tables (non-table rows disable recycling)")
        return
    end
    for i = 1, #rows do
        if type(rows[i]) ~= "table" then
            F:RaiseDevError("List:SetData: data must be an array of tables (non-table rows disable recycling)")
            return
        end
    end
    self._scrollBox:SetDataProvider(CreateDataProvider(rows))
end

-- Iterates realized row frames for an in-place update (no provider rebuild).
-- fn(frame, elementData); a truthy return stops iteration.
function Controller:ForEachFrame(fn)
    if refuseIfDestroyed(self, "ForEachFrame") then return end
    if type(fn) ~= "function" then
        F:RaiseDevError("List:ForEachFrame: fn must be a function")
        return
    end
    return self._scrollBox:ForEachFrame(fn)
end

-- Returns the live Blizzard objects: scrollBox, scrollBar, view, dataProvider.
function Controller:GetNativeHandles()
    if refuseIfDestroyed(self, "GetNativeHandles") then return end
    return {
        scrollBox = self._scrollBox,
        scrollBar = self._scrollBar,
        view = self._view,
        dataProvider = self._view:GetDataProvider(),
    }
end

-- Tears down the list: releases the provider, hides the frames, and marks
-- the controller destroyed.
function Controller:Destroy()
    if refuseIfDestroyed(self, "Destroy") then return end
    self._scrollBox:RemoveDataProvider()
    self._scrollBox:Hide()
    self._scrollBar:Hide()
    self._scrollBox = nil
    self._scrollBar = nil
    self._view = nil
    self._managedVisBehavior = nil
    self._destroyed = true
end

--------------------------------------------------------------------------------
-- Factory
--------------------------------------------------------------------------------

-- Creates a list controller scoped to one consumer surface.
function List:New(config)
    if type(config) ~= "table" then
        F:RaiseDevError("List:New: config must be a table")
        return
    end
    if type(config.name) ~= "string" or config.name == "" then
        F:RaiseDevError("List:New: config.name must be a non-empty string")
        return
    end
    if type(config.parent) ~= "table" then
        F:RaiseDevError("List:New: config.parent must be a frame")
        return
    end

    local hasTemplate = config.template ~= nil
    local hasElementType = config.elementType ~= nil
    if not hasTemplate and not hasElementType then
        F:RaiseDevError("List:New: config requires exactly one of template or elementType")
        return
    end
    if hasTemplate and hasElementType then
        F:RaiseDevError("List:New: config.template and config.elementType are mutually exclusive")
        return
    end
    if hasTemplate and type(config.template) ~= "string" then
        F:RaiseDevError("List:New: config.template must be a string")
        return
    end
    if hasElementType and type(config.elementType) ~= "string" then
        F:RaiseDevError("List:New: config.elementType must be a string")
        return
    end

    if type(config.initializer) ~= "function" then
        F:RaiseDevError("List:New: config.initializer must be a function")
        return
    end
    if config.resetter ~= nil and type(config.resetter) ~= "function" then
        F:RaiseDevError("List:New: config.resetter must be a function")
        return
    end

    local hasExtent = config.extent ~= nil
    local hasCalc = config.extentCalculator ~= nil
    if hasExtent and hasCalc then
        F:RaiseDevError("List:New: config.extent and config.extentCalculator are mutually exclusive")
        return
    end
    if hasExtent and (type(config.extent) ~= "number" or config.extent <= 0) then
        F:RaiseDevError("List:New: config.extent must be a number > 0")
        return
    end
    if hasCalc and type(config.extentCalculator) ~= "function" then
        F:RaiseDevError("List:New: config.extentCalculator must be a function")
        return
    end
    -- elementType rows require an explicit extent or calculator; an unset
    -- one is silently clamped to 1px by Blizzard and explodes as a range
    -- error later.
    if hasElementType and not hasExtent and not hasCalc then
        F:RaiseDevError("List:New: elementType rows require config.extent (> 0) or config.extentCalculator")
        return
    end

    if config.spacing ~= nil and type(config.spacing) ~= "number" then
        F:RaiseDevError("List:New: config.spacing must be a number")
        return
    end

    if not hasScrollBoxSystem() then
        F:RaiseDevError("List:New: this client lacks the modern scrolling-list system "
            .. "(ScrollUtil/CreateScrollBoxListLinearView); Foundry.List is unavailable here")
        return
    end

    local c = setmetatable({}, Controller)
    c._destroyed = false
    c._name = config.name
    c._inInitializer = false

    local parent = config.parent
    local scrollBox = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
    local scrollBar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
    -- Default fill anchor: a starting point only. Re-anchor via
    -- :GetNativeHandles() for a custom layout.
    scrollBox:SetPoint("TOPLEFT")
    scrollBox:SetPoint("BOTTOMRIGHT")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 4, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 4, 0)

    local view = CreateScrollBoxListLinearView(0, 0, 0, 0, config.spacing or 0)

    if hasExtent then
        view:SetElementExtent(config.extent)
    elseif hasCalc then
        -- Guards the calculator's return value: a nil or non-number return
        -- would corrupt Blizzard's extent arithmetic with a cryptic crash;
        -- this raises in dev and falls back to 1px.
        local consumerCalc = config.extentCalculator
        view:SetElementExtentCalculator(function(index, elementData)
            local extent = consumerCalc(index, elementData)
            if type(extent) ~= "number" or extent <= 0 then
                F:RaiseDevError("List: extentCalculator must return a number > 0 (got "
                    .. tostring(extent) .. ")")
                return 1
            end
            return extent
        end)
    end

    -- Wraps the initializer so SetData-from-inside-it can be refused; the
    -- pcall guarantees the flag clears even when the initializer errors.
    local consumerInit = config.initializer
    local elementId = config.template or config.elementType
    view:SetElementInitializer(elementId, function(frame, elementData)
        c._inInitializer = true
        local ok, err = pcall(consumerInit, frame, elementData)
        c._inInitializer = false
        if not ok then
            error(err, 0)
        end
    end)

    if config.resetter then
        view:SetElementResetter(config.resetter)
    end

    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

    if config.managedScrollBarVisibility then
        c._managedVisBehavior = ScrollUtil.AddManagedScrollBarVisibilityBehavior(scrollBox, scrollBar)
    end

    -- Must follow the initializer: SetDataProvider errors with no element
    -- factory set.
    scrollBox:SetDataProvider(CreateDataProvider())

    c._scrollBox = scrollBox
    c._scrollBar = scrollBar
    c._view = view

    return c
end

F:RegisterModule("List", List)

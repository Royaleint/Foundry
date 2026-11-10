-- Foundry.Window
--
-- Attaches drag movement and persisted position to a caller-created,
-- UIParent-parented frame. The caller owns the frame and its drag handle.
--
-- :Attach(win, config) applies the caller's saved geometry (or the default)
-- immediately, so call it after the caller's own SavedVariables exist.
-- :Reset(win) re-applies the default without a reload.

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: Window.lua requires the Foundry-1.0 bootstrap (Foundry.lua) "
        .. "to have loaded first; _G.Foundry_1_0 is missing.", 0)
end

local BUILD = 1
local API_VERSION = 1

-- An older Window already serving is taken over in place when this copy is
-- newer and the moment is safe; otherwise it keeps serving and this file loads
-- nothing. The checks only read, in a fixed order, and the first to fail names
-- the outcome; nil means this copy takes over. BUILD, API_VERSION, served and
-- takingOver are read at file scope only: no function below may capture them.
local served = F:HasModule("Window") and F.Window or nil
if served == nil and F:HasModule("Window") then return end
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
        if type(state) ~= "table" or type(state.attached) ~= "table" or type(impl) ~= "table" then
            outcome = "refused: shape"
        end
    end
    if outcome then
        if outcome:sub(1, 9) == "refused: " and F.IS_DEV_BUILD then
            F:RaiseDevError("Window: a newer copy from " .. tostring((...))
                .. " did not take over (" .. outcome .. ")")
        end
        return
    end
end
local takingOver = served ~= nil

-- On a takeover every definition below lands in the serving tables, so the
-- drag scripts an older copy gave its windows reach the newer code.
local Window = served or {}

-- All module state lives on the module table.
if not takingOver then
    Window._layoutVersion = 1
    Window._state = {
        -- Attached frame -> record.
        attached = {},
    }
    Window._impl = {}
end
local S, I = Window._state, Window._impl
local attached = S.attached

--------------------------------------------------------------------------------
-- Anchor whitelist and geometry validation
--------------------------------------------------------------------------------

local VALID_ANCHOR_POINTS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true,
    LEFT = true, CENTER = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local function isFiniteNumber(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function isValidGeometry(t)
    return type(t) == "table"
        and VALID_ANCHOR_POINTS[t.point] == true
        and VALID_ANCHOR_POINTS[t.relPoint] == true
        and isFiniteNumber(t.x)
        and isFiniteNumber(t.y)
end

local function hasAnyGeometryKey(t)
    return t.point ~= nil or t.relPoint ~= nil or t.x ~= nil or t.y ~= nil
end

local function clearGeometry(t)
    t.point, t.relPoint, t.x, t.y = nil, nil, nil, nil
end

local function apply(win, point, relPoint, x, y)
    win:ClearAllPoints()
    win:SetPoint(point, _G.UIParent, relPoint, x, y)
end

--------------------------------------------------------------------------------
-- Save (OnDragStop)
--------------------------------------------------------------------------------

-- Skips the save (dev error) when, at drag stop, win is no longer parented
-- to UIParent or its first anchor is relative to another frame. A nil
-- relativeTo counts as UIParent-relative.
local NOT_UIPARENT_RELATIVE = "Window: attached frame's parent or anchor is no longer "
    .. "UIParent-relative; geometry not saved"

local function saveGeometry(win, geometry)
    if win:GetParent() ~= _G.UIParent then
        F:RaiseDevError(NOT_UIPARENT_RELATIVE)
        return
    end
    local point, relativeTo, relPoint, x, y = win:GetPoint(1)
    if relativeTo ~= nil and relativeTo ~= _G.UIParent then
        F:RaiseDevError(NOT_UIPARENT_RELATIVE)
        return
    end
    geometry.point, geometry.relPoint, geometry.x, geometry.y = point, relPoint, x, y
end
I.saveGeometry = saveGeometry

local function dragStart(record)
    record.win:StartMoving()
end
I.dragStart = dragStart

local function dragStop(record)
    record.win:StopMovingOrSizing()
    -- Again after every drag, so the game's layout cache does not take over the position.
    record.win:SetUserPlaced(false)
    saveGeometry(record.win, record.geometry)
end
I.dragStop = dragStop

-- Builds the OnDragStart and OnDragStop scripts for one attached window. The
-- handle keeps them for the session, so each forwards to the implementation
-- on the module table.
local function makeDragScripts(record)
    local function onDragStart()
        return Window._impl.dragStart(record)
    end
    local function onDragStop()
        return Window._impl.dragStop(record)
    end
    return onDragStart, onDragStop
end
I.makeDragScripts = makeDragScripts

--------------------------------------------------------------------------------
-- Attach
--------------------------------------------------------------------------------

-- Wires movement and persisted position onto win.
--
-- Config fields:
--   handle   (required) -- frame receiving the drag scripts; win itself or any
--                          frame the caller chooses. Foundry does not verify
--                          descent from win.
--   geometry (required) -- caller-owned table; Foundry reads/writes the four
--                          keys point/relPoint/x/y in place, held by reference.
--   default  (required) -- {point, relPoint, x, y} relative to UIParent, applied
--                          when geometry is empty or malformed. Copied at Attach
--                          so a caller mutating its own literal afterward cannot
--                          change what Reset applies.
--
-- Returns win on success, nil after a refused call.
function Window:Attach(win, config)
    if type(win) ~= "table"
        or type(win.SetMovable) ~= "function"
        or type(win.SetClampedToScreen) ~= "function"
        or type(win.StartMoving) ~= "function"
        or type(win.StopMovingOrSizing) ~= "function"
        or type(win.SetUserPlaced) ~= "function"
        or type(win.GetPoint) ~= "function"
        or type(win.ClearAllPoints) ~= "function"
        or type(win.SetPoint) ~= "function"
        or type(win.GetParent) ~= "function"
    then
        F:RaiseDevError("Window:Attach: win must be a frame")
        return nil
    end

    if win:GetParent() ~= _G.UIParent then
        F:RaiseDevError("Window:Attach: win must be parented directly to UIParent")
        return nil
    end

    if attached[win] then
        F:RaiseDevError("Window:Attach: already attached; Foundry.Window does not re-attach")
        return nil
    end

    if type(config) ~= "table" then
        F:RaiseDevError("Window:Attach: config must be a table")
        return nil
    end

    local handle = config.handle
    if type(handle) ~= "table"
        or type(handle.EnableMouse) ~= "function"
        or type(handle.RegisterForDrag) ~= "function"
        or type(handle.SetScript) ~= "function"
        or type(handle.GetScript) ~= "function"
    then
        F:RaiseDevError("Window:Attach: config.handle must be a frame")
        return nil
    end

    if handle:GetScript("OnDragStart") ~= nil or handle:GetScript("OnDragStop") ~= nil then
        F:RaiseDevError("Window:Attach: handle already has drag scripts; "
            .. "Foundry.Window owns OnDragStart/OnDragStop")
        return nil
    end

    local geometry = config.geometry
    if type(geometry) ~= "table" then
        F:RaiseDevError("Window:Attach: config.geometry must be a table")
        return nil
    end

    local default = config.default
    local defaultAsGeometry = type(default) == "table" and {
        point = default[1], relPoint = default[2], x = default[3], y = default[4],
    } or nil
    if not (defaultAsGeometry and isValidGeometry(defaultAsGeometry)) then
        F:RaiseDevError("Window:Attach: config.default must be {point, relPoint, x, y} "
            .. "with whitelisted anchor names and finite offsets")
        return nil
    end

    -- Every check runs above this line; nothing on win or handle is touched
    -- until all pass.
    win:SetMovable(true)
    win:SetUserPlaced(false) -- clears any position the game's layout cache saved, before restore
    win:SetClampedToScreen(true)

    handle:EnableMouse(true)
    handle:RegisterForDrag("LeftButton")
    local record = {
        win = win,
        handle = handle,
        geometry = geometry,
        default = { default[1], default[2], default[3], default[4] },
    }
    local onDragStart, onDragStop = makeDragScripts(record)
    handle:SetScript("OnDragStart", onDragStart)
    handle:SetScript("OnDragStop", onDragStop)
    attached[win] = record

    if isValidGeometry(geometry) then
        apply(win, geometry.point, geometry.relPoint, geometry.x, geometry.y)
    else
        if hasAnyGeometryKey(geometry) then
            clearGeometry(geometry)
        end
        apply(win, default[1], default[2], default[3], default[4])
    end

    return win
end

--------------------------------------------------------------------------------
-- Reset
--------------------------------------------------------------------------------

-- Clears the saved record and re-applies the default immediately, so a window
-- dragged somewhere unreachable comes back without a /reload.
function Window:Reset(win)
    local record = attached[win]
    if not record then
        F:RaiseDevError("Window:Reset: frame is not attached")
        return
    end
    clearGeometry(record.geometry)
    local default = record.default
    apply(win, default[1], default[2], default[3], default[4])
end

-- Written last, so a copy that fails before this point leaves the serving
-- Window reporting what it did before.
Window.API_VERSION = API_VERSION
Window._source = ...
Window._build = BUILD

if not takingOver then
    F:RegisterModule("Window", Window)
end

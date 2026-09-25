-- Foundry.Window
--
-- Attaches drag movement and persisted position to a caller-created,
-- UIParent-parented frame. The caller owns the frame and its drag handle;
-- Foundry owns SetMovable/StartMoving/StopMovingOrSizing, SetClampedToScreen,
-- validated restore/save of a caller-owned geometry table, and Reset. There
-- is no frame factory, no resize, no size persistence, no scale management,
-- and no Detach in v1 -- the caller already holds the raw frame and handle.
--
-- :Attach(win, config) validates atomically and applies the caller's saved
-- geometry (or the default) immediately, so it must be called after the
-- caller's own SavedVariables exist. :Reset(win) clears the saved record and
-- re-applies the default without a reload.

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: Window.lua requires the Foundry-1.0 bootstrap (Foundry.lua) "
        .. "to have loaded first; _G.Foundry_1_0 is missing.", 0)
end
-- Guarded-embedding stand-down (§2.2b): if this module is already registered on the
-- winning copy, this is a redundant embedded copy — load nothing.
if F:HasModule("Window") then return end

local Window = {}
Window.API_VERSION = 1

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

-- A well-formed geometry table: four keys present, point/relPoint whitelisted,
-- x/y finite numbers. Also used (with named fields) to validate config.default.
local function isValidGeometry(t)
    return type(t) == "table"
        and VALID_ANCHOR_POINTS[t.point] == true
        and VALID_ANCHOR_POINTS[t.relPoint] == true
        and isFiniteNumber(t.x)
        and isFiniteNumber(t.y)
end

-- True if any of the four geometry keys is present (a garbage-but-nonempty
-- record, distinct from a fresh/absent one).
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
-- Module-local registry
-- Maps frame → record. Keyed by frame: the frame is the owner identity, and
-- there is no per-consumer controller to hold it instead.
--------------------------------------------------------------------------------

local attached = {}

--------------------------------------------------------------------------------
-- Save (OnDragStop)
--------------------------------------------------------------------------------

-- Re-checks the UIParent precondition before writing: a caller reparenting
-- win after Attach, or a client where the frame's only anchor is not
-- relative to UIParent, each leave win without a UIParent-relative sole
-- anchor. Either way the write is skipped and a dev error raised (single
-- message; the two causes are indistinguishable from here) -- the frame
-- keeps wherever the drag left it, but nothing persists.
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

--------------------------------------------------------------------------------
-- Attach
--------------------------------------------------------------------------------

-- Wires movement and persisted position onto win. Validation is atomic:
-- nothing on win or config.handle is touched until every check passes. Each
-- failure is F:RaiseDevError + return nil (dev build raises, release build
-- prints and refuses, Foundry.lua:44-51).
--
-- Config fields:
--   handle   (required) — frame receiving the drag scripts; win itself or any
--                         frame the caller chooses. Foundry does not verify
--                         descent from win.
--   geometry (required) — caller-owned table; Foundry reads/writes the four
--                         keys point/relPoint/x/y in place, held by reference.
--   default  (required) — {point, relPoint, x, y} relative to UIParent, applied
--                         when geometry is empty or malformed. Copied at Attach
--                         so a caller mutating its own literal afterward cannot
--                         change what Reset applies.
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

    -- Every check passed; nothing above touched win or handle.

    win:SetMovable(true)
    win:SetUserPlaced(false) -- clears any position the game's layout cache saved for this frame, before restore
    win:SetClampedToScreen(true)

    handle:EnableMouse(true)
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", function()
        win:StartMoving()
    end)
    handle:SetScript("OnDragStop", function()
        win:StopMovingOrSizing()
        win:SetUserPlaced(false)
        saveGeometry(win, geometry)
    end)

    local record = {
        win = win,
        handle = handle,
        geometry = geometry,
        default = { default[1], default[2], default[3], default[4] },
    }
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

F:RegisterModule("Window", Window)

-- Shared helpers for the Layout specs: the two builds under comparison, and
-- small stand-ins for the client surfaces the optional modules need (tooltip
-- processor, menu utility, settings panel). Loaded by perf_spec and
-- error_levels_spec; not a suite of its own.

local T = ...

local S = {}

local MOCK_VERSION = "@project-version@"   -- dev build: dev diagnostics raise

-- Build names: "pinned" is the 1.0.114 release copy, "current" is the code in
-- this checkout. S.load resets the mocks and loads one of them.
S.builds = {
    pinned  = function() return T.loadOldCopy("v1.0.114") end,
    current = function() return T.loadFoundry() end,
}

function S.load(buildName, tocVersion)
    T.installMocks(tocVersion or MOCK_VERSION)
    return S.builds[buildName]()
end

-- The frame Lifecycle drives its events through: the one that registered
-- PLAYER_LOGOUT.
function S.dispatcherFrame()
    for _, frame in ipairs(T.frames) do
        for _, call in ipairs(frame.calls.RegisterEvent) do
            if call[1] == "PLAYER_LOGOUT" then return frame end
        end
    end
end

-- Error text without the directory of the file and without line numbers.
function S.normalise(msg)
    msg = tostring(msg)
    msg = msg:gsub("%S*[/\\]Modules[/\\]", "Modules/")
    msg = msg:gsub("%S*[/\\]Foundry%.lua", "Foundry.lua")
    msg = msg:gsub(":%d+:", ":")
    return msg
end

-- TooltipDataProcessor: AddTooltipPostCall records each callback.
function S.installTooltipProcessor()
    local state = { postCalls = {} }
    _G.TooltipDataProcessor = {
        AddTooltipPostCall = function(tooltipType, fn)
            state.postCalls[#state.postCalls + 1] = { type = tooltipType, fn = fn }
        end,
    }
    return state
end

-- MenuUtil and friends. CreateContextMenu records the generator it is given.
function S.installMenuUtil()
    local state = { createCalls = {} }
    _G.MenuUtil = {
        CreateContextMenu = function(owner, generator, ...)
            state.createCalls[#state.createCalls + 1] = { owner = owner, generator = generator, extra = { ... } }
        end,
    }
    _G.Menu = {}
    _G.MenuResponse = { Open = 1, Refresh = 2, Close = 3, CloseAll = 4 }
    return state
end

-- A dropdown button that records the generator given to SetupMenu.
function S.makeDropdownButton()
    local button = { setups = {} }
    function button:SetupMenu(generator)
        self.setups[#self.setups + 1] = generator
    end
    return button
end

-- A menu description that accepts the calls a builder may make.
function S.makeRootDescription()
    local root = {}
    function root:CreateButton() return S.makeRootDescription() end
    function root:SetEnabled() end
    return root
end

-- The settings panel with the button launcher: state.clicks holds the click
-- functions handed to CreateSettingsButtonInitializer.
function S.installSettingsLauncher()
    local state = { clicks = {} }
    local category = { GetID = function() return 35 end }
    _G.Settings = {
        RegisterCanvasLayoutCategory = function() return category, {} end,
        RegisterCanvasLayoutSubcategory = function() return category, {} end,
        RegisterVerticalLayoutCategory = function() return category, {} end,
        RegisterInitializer = function() end,
        RegisterAddOnCategory = function() end,
        OpenToCategory = function() end,
    }
    _G.CreateSettingsButtonInitializer = function(_, _, click)
        state.clicks[#state.clicks + 1] = click
        return {}
    end
    return state
end

-- A tooltip frame that accepts line calls.
function S.makeTooltip()
    local tooltip = {}
    function tooltip:AddLine() end
    function tooltip:AddDoubleLine() end
    return tooltip
end

return S

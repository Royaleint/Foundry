-- Installer fixture: a module whose module-table function captures a flag
-- held only in a local.
local F = _G.Foundry_1_0
if F:HasModule("CaptureFlag") then return end

local M = { API_VERSION = 1 }
M._layoutVersion = 1
M._source = ...
M._state = {}
M._impl = {}

local enabled = true

function M.IsEnabled()
    return enabled
end

F:RegisterModule("CaptureFlag", M)

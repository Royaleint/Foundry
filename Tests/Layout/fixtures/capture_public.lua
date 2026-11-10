-- Installer fixture: a module whose public table holds a nested table and a
-- function from outside the library's own files.
local F = _G.Foundry_1_0
if F:HasModule("CapturePublic") then return end

local M = { API_VERSION = 1 }
M._layoutVersion = 1
M._source = ...
M._state = {}
M._impl = {}

M.Helpers = {
    options = {},
    Check = function() return true end,
}

F:RegisterModule("CapturePublic", M)

-- Installer fixture: a module whose implementation function captures a table
-- that nothing on the module table reaches.
local F = _G.Foundry_1_0
if F:HasModule("CaptureTable") then return end

local M = { API_VERSION = 1 }
M._layoutVersion = 1
M._source = ...
M._state = {}
M._impl = {}

local hidden = {}

function M._impl.touch()
    hidden.n = (hidden.n or 0) + 1
end

F:RegisterModule("CaptureTable", M)

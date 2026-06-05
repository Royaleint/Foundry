-- Foundry — luacheck configuration.
-- WoW addon library (Lua 5.1). Run `luacheck .` from the repo root.

std = "lua51"
max_line_length = false

-- Foundry writes into the SlashCmdList table (SlashCmdList[key] = ...), so it is
-- a writable global, not read-only (luacheck treats read_globals fields as read-only).
globals = {
    "SlashCmdList",
}

-- WoW API globals Foundry only reads. Lua 5.1 builtins (print, pairs, table,
-- string, error, setmetatable, _G, ...) come from std = "lua51".
read_globals = {
    "CreateFrame",
    "C_AddOns",
}

-- The module factories (Commands:New / Events:New) take an unused `self` by the
-- method-call idiom. Benign and shared across modules.
ignore = {
    "212/self",
}

-- The dev-only test suite mocks WoW globals and never ships; don't lint it as addon code.
exclude_files = {
    "Tests/",
}

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
    "UnitName",
    "GetRealmName",
}

-- The module factories (Commands:New / Events:New) take an unused `self` by the
-- method-call idiom. Benign and shared across modules.
ignore = {
    "212/self",
}

-- The dev-only test suite mocks WoW globals and never ships; don't lint it as
-- addon code. Worktree checkouts under .worktrees/ carry their own Tests/ copies
-- that the bare "Tests/" pattern does not match from the repo root, so a
-- root-level run would re-lint them as addon code; each worktree lints itself.
exclude_files = {
    "Tests/",
    ".worktrees/",
}

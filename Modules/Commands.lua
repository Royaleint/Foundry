-- Foundry.Commands
--
-- A thin registry over WoW's native slash command system (SlashCmdList and the
-- SLASH_<NAME>N globals). One controller per consumer owns that consumer's
-- slash registrations and routes subcommands, with auto-generated help,
-- aliases, an optional guard, and clean teardown.

local F = _G.Foundry_1_0
if not F then
    error("Foundry-1.0: Commands.lua requires the Foundry-1.0 bootstrap (Foundry.lua) "
        .. "to have loaded first; _G.Foundry_1_0 is missing.", 0)
end
-- Guarded-embedding stand-down (§2.2b): if this module is already registered on the
-- winning copy, this is a redundant embedded copy — load nothing. Silent no-op on
-- the first load (not registered yet). Zero new surface on F (HasModule already exists).
if F:HasModule("Commands") then return end

local Commands = {}
Commands.API_VERSION = 1

-- Trim leading and trailing whitespace; internal whitespace is preserved.
local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

--------------------------------------------------------------------------------
-- Controller
--------------------------------------------------------------------------------

local Controller = {}
Controller.__index = Controller

-- Emit one line through the configured printer, or the default chat frame.
function Controller:_print(line)
    if self._printer then
        self._printer(line)
    else
        print(line)
    end
end

-- Register a subcommand. Validation is atomic: the primary name and every alias
-- are validated into a temporary set before any mutation, so a bad alias leaves
-- the controller unchanged rather than half-registered: Foundry prefers a
-- refused operation over a half-applied one.
function Controller:Register(spec)
    if self._destroyed then
        F:RaiseDevError("Commands:Register called on a destroyed controller")
        return
    end
    if type(spec) ~= "table" then
        F:RaiseDevError("Commands:Register: spec must be a table")
        return
    end
    if type(spec.name) ~= "string" then
        F:RaiseDevError("Commands:Register: spec.name must be a string")
        return
    end
    if spec.name == "" then
        F:RaiseDevError("Commands:Register: spec.name must be a non-empty string")
        return
    end
    if spec.name ~= trim(spec.name) then
        F:RaiseDevError("Commands:Register: spec.name '" .. spec.name
            .. "' must not have leading or trailing whitespace and must not be "
            .. "whitespace-only; Foundry rejects rather than normalizing")
        return
    end
    local primary = spec.name:lower()
    if type(spec.handler) ~= "function" then
        F:RaiseDevError("Commands:Register: subcommand '" .. primary
            .. "' requires a handler function")
        return
    end
    if primary == "help" or primary:find("^help%s") then
        F:RaiseDevError("Commands:Register: subcommand name '" .. spec.name
            .. "' is reserved: 'help' and any 'help '-prefixed name route to "
            .. "PrintHelp at dispatch, so the registration would be unreachable")
        return
    end
    if self._byName[primary] then
        F:RaiseDevError("Commands:Register: subcommand '" .. primary
            .. "' is already registered")
        return
    end

    -- Validate every alias before mutating anything.
    local aliasKeys, aliasDisplays = {}, {}
    if spec.aliases ~= nil then
        if type(spec.aliases) ~= "table" then
            F:RaiseDevError("Commands:Register: spec.aliases must be a table")
            return
        end
        local localSeen = { [primary] = true }
        for i, raw in ipairs(spec.aliases) do
            if type(raw) ~= "string" then
                F:RaiseDevError("Commands:Register: aliases[" .. i
                    .. "] must be a string (got " .. type(raw) .. ")")
                return
            end
            if raw == "" then
                F:RaiseDevError("Commands:Register: aliases[" .. i .. "] must be a non-empty string")
                return
            end
            if raw ~= trim(raw) then
                F:RaiseDevError("Commands:Register: alias '" .. raw .. "' (aliases[" .. i
                    .. "]) must not have leading or trailing whitespace")
                return
            end
            local alias = raw:lower()
            if alias == "help" or alias:find("^help%s") then
                F:RaiseDevError("Commands:Register: alias '" .. raw .. "' (aliases[" .. i
                    .. "]) is reserved; 'help' and 'help '-prefixed names route to "
                    .. "PrintHelp at dispatch and would be unreachable")
                return
            end
            if self._byName[alias] or localSeen[alias] then
                F:RaiseDevError("Commands:Register: alias '" .. alias .. "' (aliases[" .. i
                    .. "]) collides with an existing or duplicate registration")
                return
            end
            localSeen[alias] = true
            aliasKeys[#aliasKeys + 1] = alias
            aliasDisplays[#aliasDisplays + 1] = raw
        end
    end

    -- All valid; commit atomically.
    local entry = {
        name = primary,
        display = spec.name,
        args = spec.args,
        help = spec.help,
        handler = spec.handler,
        aliasKeys = aliasKeys,
        aliasDisplays = aliasDisplays,
    }
    self._byName[primary] = entry
    for _, alias in ipairs(aliasKeys) do
        self._byName[alias] = entry
    end
end

-- Remove a subcommand by its primary name or any alias. Idempotent.
function Controller:Unregister(name)
    if type(name) ~= "string" then
        F:RaiseDevError("Commands:Unregister: name must be a string")
        return
    end
    local entry = self._byName[name:lower()]
    if not entry then return end
    self._byName[entry.name] = nil
    for _, alias in ipairs(entry.aliasKeys) do
        self._byName[alias] = nil
    end
end

-- Find the longest registered name (primary or alias) that is a word-boundary
-- prefix of the input. Returns the matched entry and the original-case
-- remainder, or nil.
function Controller:_match(trimmed)
    local lowered = trimmed:lower()
    local best, bestLen
    for key, entry in pairs(self._byName) do
        local klen = #key
        if (not bestLen or klen > bestLen)
            and (lowered == key
                or (lowered:sub(1, klen) == key and lowered:sub(klen + 1, klen + 1) == " ")) then
            best, bestLen = entry, klen
        end
    end
    if not best then return nil end
    return best, trim(trimmed:sub(bestLen + 1))
end

-- Drive the controller from a raw input string.
function Controller:Dispatch(input)
    if self._destroyed then return end
    input = input or ""

    -- 1. Guard runs first, on the raw input.
    if self._guard then
        local allowed, reason = self._guard(input)
        if not allowed then
            if reason and reason ~= "" then
                self:_print(reason)
            end
            return
        end
    end

    local trimmed = trim(input)

    -- 2. Empty input.
    if trimmed == "" then
        if self._defaultHandler then
            self._defaultHandler()
        else
            self:PrintHelp()
        end
        return
    end

    -- 3. Reserved 'help' token at a word boundary.
    local lowered = trimmed:lower()
    if lowered == "help" or lowered:match("^help%s") then
        self:PrintHelp()
        return
    end

    -- 4. Longest-prefix subcommand match.
    local entry, remainder = self:_match(trimmed)
    if entry then
        entry.handler(remainder)
        return
    end

    -- 5. Unknown command. Print the (consumer-overridable) message
    -- only; the auto-help command list is NOT appended. A consumer that wants
    -- to point users at the list includes a hint in `unknownMessage`
    -- (e.g. "type /x help"). Foundry hardcodes no player-facing string.
    local msg = self._unknownMessage
    if type(msg) == "function" then
        msg = msg(trimmed)
    end
    if msg == nil then
        msg = "Unknown command: " .. trimmed
    end
    if msg ~= "" then
        self:_print(msg)
    end
end

-- Emit the auto-generated help.
function Controller:PrintHelp()
    local seen, list = {}, {}
    for _, entry in pairs(self._byName) do
        if not seen[entry] then
            seen[entry] = true
            list[#list + 1] = entry
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)

    if self._description then
        self:_print(self._description)
        self:_print("")
    end

    local slash = self._slashes[1]
    for _, entry in ipairs(list) do
        local line = slash .. " " .. entry.display
        if #entry.aliasDisplays > 0 then
            local aliases = {}
            for i = 1, #entry.aliasDisplays do
                aliases[i] = entry.aliasDisplays[i]
            end
            table.sort(aliases, function(a, b) return a:lower() < b:lower() end)
            line = line .. " (" .. table.concat(aliases, ", ") .. ")"
        end
        if entry.args and entry.args ~= "" then
            line = line .. " " .. entry.args
        end
        local help = entry.help
        if type(help) == "function" then
            help = help()
        end
        if help and help ~= "" then
            line = line .. "  -- " .. tostring(help)
        end
        self:_print(line)
    end
end

-- The progressive-disclosure escape hatch.
function Controller:GetNativeHandles()
    local globals = {}
    for i = 1, #self._slashGlobals do
        globals[i] = self._slashGlobals[i]
    end
    return {
        slashListKey = self._slashListKey,
        slashGlobals = globals,
        handler = SlashCmdList[self._slashListKey],
    }
end

-- Tear down every slash registration this controller owns.
function Controller:Destroy()
    if self._slashListKey then
        SlashCmdList[self._slashListKey] = nil
    end
    for i = 1, #self._slashGlobals do
        _G[self._slashGlobals[i]] = nil
    end
    self._byName = {}
    self._slashGlobals = {}
    self._destroyed = true
end

--------------------------------------------------------------------------------
-- Factory
--------------------------------------------------------------------------------

-- Create a controller scoped to one consumer.
function Commands:New(config)
    if type(config) ~= "table" then
        F:RaiseDevError("Commands:New: config must be a table")
        return
    end
    if type(config.name) ~= "string" or config.name == "" then
        F:RaiseDevError("Commands:New: config.name must be a non-empty string")
        return
    end
    if type(config.slashes) ~= "table" or #config.slashes < 1 then
        F:RaiseDevError("Commands:New: config.slashes must be an array with at least one entry")
        return
    end
    for _, field in ipairs({ "defaultHandler", "guard", "printer" }) do
        if config[field] ~= nil and type(config[field]) ~= "function" then
            F:RaiseDevError("Commands:New: " .. field .. " must be a function")
            return
        end
    end
    if config.description ~= nil and type(config.description) ~= "string" then
        F:RaiseDevError("Commands:New: description must be a string")
        return
    end
    if config.unknownMessage ~= nil
        and type(config.unknownMessage) ~= "string"
        and type(config.unknownMessage) ~= "function" then
        F:RaiseDevError("Commands:New: unknownMessage must be a string or a function")
        return
    end

    -- Normalize and validate the slash strings up front, before any mutation.
    local slashes = {}
    for i = 1, #config.slashes do
        local s = config.slashes[i]
        if type(s) ~= "string" or s == "" then
            F:RaiseDevError("Commands:New: slashes[" .. i .. "] must be a non-empty string")
            return
        end
        if s:sub(1, 1) ~= "/" then
            s = "/" .. s
        end
        local body = s:sub(2)
        if body == "" or body:find("%s") or body:find("/", 1, true) then
            F:RaiseDevError("Commands:New: slash '" .. s
                .. "' must be a single slash token: no internal whitespace and "
                .. "no embedded slashes beyond an optional leading one")
            return
        end
        slashes[i] = s
    end

    local key = config.name:upper()

    -- Slash-name collision detection before any global mutation.
    local collision
    if SlashCmdList[key] ~= nil then
        collision = "SlashCmdList key '" .. key .. "'"
    else
        for i = 1, #slashes do
            if _G["SLASH_" .. key .. i] ~= nil then
                collision = "global 'SLASH_" .. key .. i .. "'"
                break
            end
        end
    end
    if collision then
        F:RaiseDevError("Commands:New: slash-name collision on " .. collision
            .. " for name '" .. config.name .. "'; refusing to overwrite")
        return
    end

    local c = setmetatable({}, Controller)
    c._name = config.name
    c._description = config.description
    c._defaultHandler = config.defaultHandler
    c._guard = config.guard
    c._printer = config.printer
    c._unknownMessage = config.unknownMessage
    c._byName = {}
    c._slashListKey = key
    c._slashes = slashes
    c._slashGlobals = {}

    for i = 1, #slashes do
        local g = "SLASH_" .. key .. i
        _G[g] = slashes[i]
        c._slashGlobals[i] = g
    end

    SlashCmdList[key] = function(msg)
        c:Dispatch(msg)
    end

    return c
end

F:RegisterModule("Commands", Commands)

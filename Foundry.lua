-- Foundry-1.0 bootstrap.
--
-- The single entry point that establishes the Foundry namespace: creates
-- _G.Foundry_1_0, derives IS_DEV_BUILD and VERSION from the packaged version
-- token, sets API_VERSION, and provides module registration/access. Registers
-- no events, touches no SavedVariables, depends on no other module.

local ADDON_NAME = ...

local BUILD = 1

-- Built by concatenation: a literal token here would get rewritten by the
-- packager too, and this file would read as a dev build after packaging.
local VERSION_TOKEN = "@" .. "project-version" .. "@"
local DEV_VERSION = "dev"

-- Foundry's own folders. An embedded copy reads the host addon's TOC, so only
-- these names may treat a "dev-" version as Foundry's own stamp.
local OWN_FOLDERS = { ["Foundry-1.0"] = true, ["Foundry-1.0_DevBuild"] = true }

local tocVersion = C_AddOns and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")

-- _G.FOUNDRY_DEV_BUILD_OVERRIDE (set before this file loads) forces dev
-- builds on for local testing.
local override = _G.FOUNDRY_DEV_BUILD_OVERRIDE
local isStamped = OWN_FOLDERS[ADDON_NAME] == true
    and type(tocVersion) == "string"
    and tocVersion:sub(1, 4) == "dev-"
local isDevBuild = (tocVersion == nil)
    or (tocVersion == VERSION_TOKEN)
    or isStamped
    or (override ~= nil and override ~= false)

local F = {}
F.IS_DEV_BUILD = isDevBuild
F.VERSION = isStamped and tocVersion or (isDevBuild and DEV_VERSION or tocVersion)
F.SOURCE = ADDON_NAME
F.API_VERSION = 7
F._LOAD_TOKEN = {}   -- per-load identity token

-- Dev builds raise; release builds print and return, so callers must still
-- handle the failure path themselves.
function F:RaiseDevError(message)
    message = "Foundry-1.0: " .. tostring(message)
    if self.IS_DEV_BUILD then
        error(message, 2)
    else
        print(message)
    end
end

-- Modules register as they load. Reach one directly (F.Commands), or
-- defensively via :HasModule / :RequireModule.
function F:RegisterModule(name, module)
    if type(name) ~= "string" or name == "" then
        self:RaiseDevError("RegisterModule: name must be a non-empty string")
        return
    end
    if F._state.modules[name] then
        self:RaiseDevError("RegisterModule: module '" .. name .. "' is already registered")
        return
    end
    F._state.modules[name] = module
    self[name] = module
    return module
end

function F:HasModule(name)
    return F._state.modules[name] ~= nil
end

function F:RequireModule(name, minApiVersion)
    local module = F._state.modules[name]
    if not module then
        error("Foundry-1.0: required module '" .. tostring(name)
            .. "' is not present in this build. Active copy: " .. tostring(F.SOURCE)
            .. ", version " .. tostring(F.VERSION) .. ", API version "
            .. tostring(F.API_VERSION) .. ".", 2)
    end
    if minApiVersion ~= nil then
        local level = module.API_VERSION or 0
        if level < minApiVersion then
            error(("Foundry-1.0: module '%s' is API version %d, but the caller requires at least %d.")
                :format(name, level, minApiVersion), 2)
        end
    end
    return module
end

-- First-loaded wins; a later copy must not overwrite _G.Foundry_1_0, or a
-- second live instance would double-run DB's logout strip and corrupt saves.
local existing = _G.Foundry_1_0
if existing then
    -- rawget: a current copy reads none of the newer layout fields on an older
    -- library table through a normal lookup.
    local state = rawget(existing, "_state")
    if type(state) == "table" and type(state.copies) == "table" then
        state.copies[#state.copies + 1] = {
            source = ADDON_NAME, version = F.VERSION, apiVersion = F.API_VERSION,
            unit = "core", outcome = "not used",
        }
    end
    -- Suppression rests on the API_VERSION check only -- _LOAD_TOKEN is
    -- always unequal across loads, so it filters nothing.
    if F.IS_DEV_BUILD and not existing.IS_DEV_BUILD then
        existing:RaiseDevError("an enabled Foundry-1.0 DevBuild was suppressed; "
            .. "the first-loaded release copy (version " .. tostring(existing.VERSION)
            .. ") is serving and this DevBuild loaded nothing")
    elseif existing.IS_DEV_BUILD and existing._LOAD_TOKEN ~= F._LOAD_TOKEN
        and existing.API_VERSION ~= F.API_VERSION then
        existing:RaiseDevError("a redundant embedded Foundry-1.0 copy was suppressed; "
            .. "the first-loaded copy (API_VERSION " .. tostring(existing.API_VERSION)
            .. ") is serving and this copy (API_VERSION " .. tostring(F.API_VERSION)
            .. ") loaded nothing")
    end
    return
end

-- Only the serving copy carries the layout version and the shared state table.
F._layoutVersion = 1
F._build = BUILD
F._source = ADDON_NAME
F._state = { modules = {}, copies = {} }

-- No plain _G.Foundry; consumers bind _G.Foundry_1_0 explicitly.
_G.Foundry_1_0 = F

-- /foundry copies. Registered by the serving copy only, straight on the
-- client tables so a trimmed copy without Commands still has it, and only when
-- both names are free.
if SlashCmdList and SlashCmdList.FOUNDRY == nil and _G.SLASH_FOUNDRY1 == nil then
    _G.SLASH_FOUNDRY1 = "/foundry"
    SlashCmdList.FOUNDRY = function(message)
        local word = tostring(message or ""):match("^%s*(%S*)"):lower()
        if word ~= "copies" then
            print("Foundry: type /foundry copies to list the loaded copies of the Foundry library")
            return
        end
        print(("Foundry: active copy: %s, version %s, API version %s")
            :format(tostring(F.SOURCE), tostring(F.VERSION), tostring(F.API_VERSION)))
        local names = {}
        for name, module in pairs(F._state.modules) do
            if module._source ~= F.SOURCE then names[#names + 1] = name end
        end
        table.sort(names)
        for _, name in ipairs(names) do
            print(("Foundry: %s comes from %s"):format(name, F._state.modules[name]._source or "an older copy that does not name its addon"))
        end
        if #names == 0 then
            print("Foundry: every module comes from the active copy")
        end
        local copies = F._state.copies
        for _, copy in ipairs(copies) do
            print(("Foundry: %s: %s, version %s, API version %s")
                :format(tostring(copy.outcome), tostring(copy.source), tostring(copy.version), tostring(copy.apiVersion)))
        end
        if #copies == 0 then
            print("Foundry: no other copies recorded (copies older than this version are not listed)")
        end
    end
end

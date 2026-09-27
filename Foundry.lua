-- Foundry-1.0 bootstrap.
--
-- The single entry point that establishes the Foundry namespace: creates
-- _G.Foundry_1_0, derives IS_DEV_BUILD and VERSION from the packaged version
-- token, sets API_VERSION, and provides module registration/access. Registers
-- no events, touches no SavedVariables, depends on no other module.

local ADDON_NAME = ...

-- Built by concatenation: a literal token here would get rewritten by the
-- packager too, and this file would read as a dev build after packaging.
local VERSION_TOKEN = "@" .. "project-version" .. "@"
local DEV_VERSION = "dev"

local tocVersion = C_AddOns and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")

-- _G.FOUNDRY_DEV_BUILD_OVERRIDE (set before this file loads) forces dev
-- builds on for local testing.
local override = _G.FOUNDRY_DEV_BUILD_OVERRIDE
local isDevBuild = (tocVersion == nil)
    or (tocVersion == VERSION_TOKEN)
    or (override ~= nil and override ~= false)

local F = {}
F.IS_DEV_BUILD = isDevBuild
F.VERSION = isDevBuild and DEV_VERSION or tocVersion
F.SOURCE = ADDON_NAME
F.API_VERSION = 6
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
local modules = {}

function F:RegisterModule(name, module)
    if type(name) ~= "string" or name == "" then
        self:RaiseDevError("RegisterModule: name must be a non-empty string")
        return
    end
    if modules[name] then
        self:RaiseDevError("RegisterModule: module '" .. name .. "' is already registered")
        return
    end
    modules[name] = module
    self[name] = module
    return module
end

function F:HasModule(name)
    return modules[name] ~= nil
end

function F:RequireModule(name, minApiVersion)
    local module = modules[name]
    if not module then
        error("Foundry-1.0: required module '" .. tostring(name)
            .. "' is not present in this build.", 2)
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

-- No plain _G.Foundry; consumers bind _G.Foundry_1_0 explicitly.
_G.Foundry_1_0 = F

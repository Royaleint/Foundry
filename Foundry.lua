-- Foundry-1.0 bootstrap.
--
-- The single entry point that establishes the Foundry namespace. It creates
-- _G.Foundry_1_0, derives IS_DEV_BUILD and VERSION from the @project-version@
-- packaging token, sets API_VERSION, provides the shared fail-loud helper, and
-- establishes module registration and access. It registers no events, touches
-- no SavedVariables, and depends on none of the modules.

local ADDON_NAME = ...

-- The packaging-version sentinel is built by concatenation so the contiguous
-- literal never appears in this source file. The BigWigs/CurseForge packager
-- substitutes that token across ALL packaged files, not just the TOC, so a
-- hardcoded contiguous sentinel here would itself be rewritten to the real
-- version at package time, making the dev-build comparison below true in a
-- packaged release (a false dev build). Splitting it keeps the sentinel intact.
local VERSION_TOKEN = "@" .. "project-version" .. "@"
local DEV_VERSION = "dev"

-- 1. Read the version the packager wrote into the TOC. C_AddOns.GetAddOnMetadata
--    is the current-retail metadata API (the bare GetAddOnMetadata global routes
--    to it). When Foundry runs from unpackaged source the packager has not run,
--    so this still returns the literal token.
local tocVersion = C_AddOns and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")

-- 2. Dev-build detection. An unsubstituted token, or no
--    version at all, means we are running from a developer's working copy. An
--    author may force IS_DEV_BUILD on for local testing by setting the global
--    _G.FOUNDRY_DEV_BUILD_OVERRIDE truthy before this bootstrap runs; that
--    override lives in the consumer's own code, so a packaged release cannot
--    accidentally ship dev-on once the packager substitutes the token. The
--    release-pipeline sanity check is the
--    contracted complement that guards against a pipeline shipping the literal
--    token.
local override = _G.FOUNDRY_DEV_BUILD_OVERRIDE
local isDevBuild = (tocVersion == nil)
    or (tocVersion == VERSION_TOKEN)
    or (override ~= nil and override ~= false)

local F = {}
F.IS_DEV_BUILD = isDevBuild
F.VERSION = isDevBuild and DEV_VERSION or tocVersion
F.API_VERSION = 5
F._LOAD_TOKEN = {}   -- per-load identity token (guarded-embed §2.2c)

-- 3. Shared fail-loud helper. In a dev build an unsupported
--    or unsafe condition raises a Lua error so the author sees it immediately.
--    In a release build the same condition prints a clear diagnostic and returns,
--    leaving the caller to refuse the operation rather than raising into an
--    unsuspecting player's session. Neither path silently swallows the condition.
function F:RaiseDevError(message)
    message = "Foundry-1.0: " .. tostring(message)
    if self.IS_DEV_BUILD then
        error(message, 2)
    else
        print(message)
    end
end

-- 4. Module registry and access. Module files register
--    themselves as they load (the TOC loads this bootstrap first). Consumers
--    reach a module directly (F.Commands) on the common path, or defensively
--    through :HasModule / :RequireModule.
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

-- 5. Bootstrap gate: if a copy of this major version already claimed the runtime
--    symbol (a standalone or an earlier-loading consumer's embed), this copy must
--    NOT overwrite it. The first copy to load wins and serves everyone; later copies
--    load nothing. Replacing the table would create a second live library instance
--    (split-brain dispatcher; double DB logout strip = save corruption). §2.2a + §2.3.
local existing = _G.Foundry_1_0
if existing then
    -- Emit a dev diagnostic when a genuinely different copy is suppressed (§2.3).
    -- Gated on IS_DEV_BUILD (winner's build flag) so release builds are silent;
    -- on token identity (NOT version string — SV-3) so the same copy loaded twice
    -- doesn't fire spuriously; and (FND-007 #2) on an API_VERSION SKEW between the
    -- suppressed copy and the winner, so a same-version multi-embed dev setup
    -- (several addons each shipping the identical Foundry) stays silent and only a
    -- real version mismatch — the case worth a dev's attention — speaks up.
    --
    -- DEV-ENVIRONMENT NOISE TUNING ONLY. This whole branch is gated on the WINNER's
    -- IS_DEV_BUILD, so in a real production graft (the winner is a live release
    -- standalone) it NEVER fires. It is NOT production graft protection -- DB.lua's
    -- RaiseDevError graft-guard is the sole production guard for the consequential
    -- (DB) graft. This message exists purely to cut noise in dev setups.
    if existing.IS_DEV_BUILD and existing._LOAD_TOKEN ~= F._LOAD_TOKEN
        and existing.API_VERSION ~= F.API_VERSION then
        existing:RaiseDevError("a redundant embedded Foundry-1.0 copy was suppressed; "
            .. "the first-loaded copy (API_VERSION " .. tostring(existing.API_VERSION)
            .. ") is serving and this copy (API_VERSION " .. tostring(F.API_VERSION)
            .. ") loaded nothing")
    end
    return
end

-- 6. Publish under the major-version-qualified global. There
--    is no plain _G.Foundry; consumers bind _G.Foundry_1_0 explicitly.
_G.Foundry_1_0 = F

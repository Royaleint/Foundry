-- Foundry bootstrap (Foundry.lua) behavior tests. Loaded by Tests/run.lua, which
-- passes the harness table T. Returns a list of { name, fn } cases.
--
-- Scope: the FND-007 #2 version-aware suppression diagnostic. When a copy of the
-- major version already won _G.Foundry_1_0, a later-loading copy must suppress
-- itself (the bootstrap gate). In a DEV winner we emit a diagnostic, but ONLY on
-- an API_VERSION skew between the suppressed copy and the winner -- same-version
-- multi-embed dev setups stay silent, and a release winner never fires at all.
--
-- These cases inject a FAKE `existing` core into _G.Foundry_1_0 (with a capturing
-- RaiseDevError) and then loadfile Foundry.lua against it via T.loadModule, so the
-- real bootstrap's suppression branch runs against controlled winner fields.

local T = ...

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

-- Build a fake winning core and install it as _G.Foundry_1_0. Captures every
-- RaiseDevError message into `captured`. Returns the fake (so a case can read
-- back its fields). installMocks must have run first (it sets _G.Foundry_1_0 = nil
-- and provides the version metadata the loaded copy reads).
local function injectExisting(opts)
    local captured = {}
    local fake = {
        IS_DEV_BUILD = opts.IS_DEV_BUILD,
        API_VERSION = opts.API_VERSION,
        _LOAD_TOKEN = {},          -- a distinct token: never matches the fresh copy's
        captured = captured,
    }
    function fake:RaiseDevError(message)
        captured[#captured + 1] = tostring(message)
    end
    _G.Foundry_1_0 = fake
    return fake
end

-- Load Foundry.lua against the already-injected winner. The loaded copy hardcodes
-- API_VERSION = 5; installMocks("@project-version@") makes the LOADED copy a dev
-- build, but the suppression branch is gated on the WINNER's IS_DEV_BUILD, so the
-- loaded copy's flag is irrelevant to whether the diagnostic fires.
local function loadBootstrap(tocVersion)
    T.installMocks(tocVersion or "@project-version@")
    return tocVersion
end

local function containsAll(messages, ...)
    local needles = { ... }
    for _, needle in ipairs(needles) do
        local hit = false
        for _, m in ipairs(messages) do
            if m:find(needle, 1, true) then hit = true; break end
        end
        if not hit then return false, needle end
    end
    return true
end

-- (i) dev winner + API_VERSION skew (winner 4 vs loaded 5) -> diagnostic FIRES,
-- naming both versions; the winner remains in place (suppression held).
test("suppression: dev winner with API_VERSION skew fires and names both versions", function()
    loadBootstrap()
    local fake = injectExisting({ IS_DEV_BUILD = true, API_VERSION = 4 })
    T.loadModule("Foundry.lua")
    T.eq(_G.Foundry_1_0, fake, "the winning copy stays installed (later copy suppressed)")
    T.eq(#fake.captured, 1, "exactly one diagnostic fired")
    local ok, missing = containsAll(fake.captured, "suppressed", "4", "5")
    T.truthy(ok, "diagnostic names both API versions (missing: " .. tostring(missing) .. ")")
end)

-- (ii) dev winner + SAME API_VERSION (winner 5 == loaded 5) -> SILENT. A
-- same-version multi-embed dev setup must not nag.
test("suppression: dev winner with same API_VERSION is silent", function()
    loadBootstrap()
    local fake = injectExisting({ IS_DEV_BUILD = true, API_VERSION = 5 })
    T.loadModule("Foundry.lua")
    T.eq(_G.Foundry_1_0, fake, "the winning copy stays installed")
    T.eq(#fake.captured, 0, "no diagnostic on a same-version embed")
end)

-- (iii) RELEASE winner -> SILENT regardless of version. Proves the branch is
-- DEV-ONLY noise tuning: a real production graft (live release standalone winning)
-- never fires. Exercised with a skew so only the IS_DEV_BUILD gate can keep it quiet.
test("suppression: release winner is silent even with an API_VERSION skew", function()
    loadBootstrap()
    local fake = injectExisting({ IS_DEV_BUILD = false, API_VERSION = 4 })
    T.loadModule("Foundry.lua")
    T.eq(_G.Foundry_1_0, fake, "the winning copy stays installed")
    T.eq(#fake.captured, 0, "release winner never fires -- not production graft protection")
end)

-- Red-without-change: case (ii) is the discriminator for the FND-007 #2 change,
-- NOT case (i). Case (i) fires with or without the third condition (4 ~= 5 is true
-- either way), so it cannot prove the change. Case (ii) can: with the third
-- condition (existing.API_VERSION ~= F.API_VERSION) deleted from Foundry.lua, the
-- same-version embed (5 == 5) fires a spurious diagnostic and this suite reports
--   "no diagnostic on a same-version embed: expected \"0\", got \"1\""
-- (observed by temporarily striking that clause, then restored to green).

return tests

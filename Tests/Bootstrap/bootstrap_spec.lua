-- Foundry bootstrap (Foundry.lua) behavior tests. Loaded by Tests/run.lua, which
-- passes the harness table T. Returns a list of { name, fn } cases.
--
-- Scope: the version-aware suppression diagnostic. When a copy of the
-- major version already won _G.Foundry_1_0, a later-loading copy must suppress
-- itself (the bootstrap gate). A DEV winner emits a diagnostic only on API_VERSION
-- skew; a release winner emits only when it suppresses an enabled DevBuild.
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
        VERSION = opts.VERSION,
        _LOAD_TOKEN = {},          -- a distinct token: never matches the fresh copy's
        captured = captured,
    }
    function fake:RaiseDevError(message)
        captured[#captured + 1] = tostring(message)
    end
    _G.Foundry_1_0 = fake
    return fake
end

-- Load Foundry.lua against the already-injected winner. installMocks
-- ("@project-version@") makes the LOADED copy a dev build, but the suppression
-- branch is gated on the WINNER's IS_DEV_BUILD, so the loaded copy's flag is
-- irrelevant to whether the diagnostic fires.
local function loadBootstrap(tocVersion)
    T.installMocks(tocVersion or "@project-version@")
    return tocVersion
end

-- The loaded copy's API_VERSION, DERIVED by loading Foundry.lua once with no
-- winner installed (the fresh copy wins and reports itself). Never hardcode it
-- here: a hardcoded pin silently turned case (ii) below from a same-version
-- embed into a skew when the library bumped 5 -> 6, leaving the same-version
-- silence clause with no test covering it.
local function currentApiVersion()
    T.installMocks("@project-version@")
    T.loadModule("Foundry.lua")
    return _G.Foundry_1_0.API_VERSION
end

test("bootstrap: SOURCE identifies the folder that supplied the winning Foundry copy", function()
    T.installMocks("@project-version@")
    T.loadModule("Foundry.lua")
    T.eq(_G.Foundry_1_0.SOURCE, "Foundry-1.0", "SOURCE is the winning addon folder")
end)

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

-- (i) dev winner + API_VERSION skew (winner one behind the loaded copy) ->
-- diagnostic FIRES, naming both versions; the winner remains in place
-- (suppression held).
test("suppression: dev winner with API_VERSION skew fires and names both versions", function()
    local current = currentApiVersion()
    loadBootstrap()
    local fake = injectExisting({ IS_DEV_BUILD = true, API_VERSION = current - 1 })
    T.loadModule("Foundry.lua")
    T.eq(_G.Foundry_1_0, fake, "the winning copy stays installed (later copy suppressed)")
    T.eq(#fake.captured, 1, "exactly one diagnostic fired")
    local ok, missing = containsAll(fake.captured, "suppressed",
        tostring(current - 1), tostring(current))
    T.truthy(ok, "diagnostic names both API versions (missing: " .. tostring(missing) .. ")")
end)

-- (ii) dev winner + SAME API_VERSION (winner matches the loaded copy) -> SILENT.
-- A same-version multi-embed dev setup must not nag. The winner's version is
-- derived so this case keeps testing a genuine same-version embed across bumps.
test("suppression: dev winner with same API_VERSION is silent", function()
    local current = currentApiVersion()
    loadBootstrap()
    local fake = injectExisting({ IS_DEV_BUILD = true, API_VERSION = current })
    T.loadModule("Foundry.lua")
    T.eq(_G.Foundry_1_0, fake, "the winning copy stays installed")
    T.eq(#fake.captured, 0, "no diagnostic on a same-version embed")
end)

-- (iii) release-over-release stays silent regardless of API version skew.
test("suppression: release winner is silent when it suppresses another release", function()
    local current = currentApiVersion()
    loadBootstrap("1.0.105")
    local fake = injectExisting({ IS_DEV_BUILD = false, API_VERSION = current - 1, VERSION = "1.0.104" })
    T.loadModule("Foundry.lua")
    T.eq(_G.Foundry_1_0, fake, "the winning copy stays installed")
    T.eq(#fake.captured, 0, "release-over-release remains silent")
end)

test("suppression: release winner reports when it suppresses an enabled DevBuild", function()
    local current = currentApiVersion()
    loadBootstrap("@project-version@")
    local fake = injectExisting({ IS_DEV_BUILD = false, API_VERSION = current, VERSION = "1.0.104" })
    T.loadModule("Foundry.lua")
    T.eq(#fake.captured, 1, "release winner prints exactly one DevBuild diagnostic")
    local ok, missing = containsAll(fake.captured, "DevBuild", "1.0.104", "loaded nothing")
    T.truthy(ok, "diagnostic names the release winner and the suppressed DevBuild (missing: " .. tostring(missing) .. ")")
end)

-- A dev- stamped version in Foundry's own folder is a dev build and shows the stamp.
-- Only the standalone folders count; an embedded copy reads the host's TOC.
local function loadAs(addonName, tocVersion)
    T.installMocks(tocVersion)
    assert(loadfile(T.foundryRoot .. "/Foundry.lua"))(addonName)
    return _G.Foundry_1_0
end

test("stamp: dev- version in the standalone folder is a dev build and VERSION shows the stamp", function()
    for _, folder in ipairs({ "Foundry-1.0", "Foundry-1.0_DevBuild" }) do
        local F = loadAs(folder, "dev-abc1234")
        T.eq(F.IS_DEV_BUILD, true, folder .. " dev-stamp is a dev build")
        T.eq(F.VERSION, "dev-abc1234", folder .. " VERSION carries the stamp")
    end
end)

test("stamp: dev- host version on an embedded copy stays a release", function()
    local F = loadAs("Homestead", "dev-abc1234")
    T.eq(F.IS_DEV_BUILD, false, "embedded copy ignores the host's dev- stamp")
    T.eq(F.VERSION, "dev-abc1234", "VERSION is the host version, as for any release")
end)

test("stamp: embedded copy keeps the nil and packager-token dev cases", function()
    T.eq(loadAs("Homestead", nil).IS_DEV_BUILD, true, "nil version is still dev")
    T.eq(loadAs("Homestead", "@project-version@").IS_DEV_BUILD, true, "token is still dev")
end)

test("stamp: a packaged version string still reads as release", function()
    local F = loadAs("Foundry-1.0", "1.0.114")
    T.eq(F.IS_DEV_BUILD, false, "1.0.114 is a release")
    T.eq(F.VERSION, "1.0.114", "VERSION is the packaged version")
end)

test("stamp: stamped dev standalone loading after an embedded release is suppressed with the DevBuild diagnostic", function()
    local current = currentApiVersion()
    T.installMocks("dev-abc1234")
    local fake = injectExisting({ IS_DEV_BUILD = false, API_VERSION = current, VERSION = "1.0.104" })
    assert(loadfile(T.foundryRoot .. "/Foundry.lua"))("Foundry-1.0_DevBuild")
    T.eq(_G.Foundry_1_0, fake, "the release winner stays installed")
    T.eq(#fake.captured, 1, "one DevBuild diagnostic fires")
    local ok, missing = containsAll(fake.captured, "DevBuild", "1.0.104", "loaded nothing")
    T.truthy(ok, "diagnostic matches the unstamped case (missing: " .. tostring(missing) .. ")")
end)

-- Loads Foundry.lua as a second copy while keeping the first copy's winner in
-- place; the mocked TOC version is swapped to what the second copy's addon reads.
local function loadSecond(addonName, tocVersion)
    _G.C_AddOns.GetAddOnMetadata = function(_, key)
        if key == "Version" then return tocVersion end
        return nil
    end
    assert(loadfile(T.foundryRoot .. "/Foundry.lua"))(addonName)
end

local function captureOn(winner)
    local captured = {}
    winner.RaiseDevError = function(_, m) captured[#captured + 1] = m end
    return captured
end

test("stamp: embedded release loading after a stamped dev standalone is silent on the same API version", function()
    local dev = loadAs("Foundry-1.0_DevBuild", "dev-abc1234")
    local captured = captureOn(dev)
    T.eq(dev.IS_DEV_BUILD, true, "setup: stamped dev standalone won")
    loadSecond("Homestead", "1.0.114")
    T.eq(_G.Foundry_1_0, dev, "the stamped dev copy stays installed")
    T.eq(#captured, 0, "same-API embed is silent, as with an unstamped dev winner")
end)

test("stamp: embedded release loading after a stamped dev standalone reports an API version skew", function()
    local dev = loadAs("Foundry-1.0_DevBuild", "dev-abc1234")
    local captured = captureOn(dev)
    dev.API_VERSION = dev.API_VERSION - 1
    loadSecond("Homestead", "1.0.114")
    T.eq(_G.Foundry_1_0, dev, "the stamped dev copy stays installed")
    T.eq(#captured, 1, "exactly one diagnostic fired")
    local ok, missing = containsAll(captured, "redundant embedded", tostring(dev.API_VERSION),
        tostring(dev.API_VERSION + 1))
    T.truthy(ok, "diagnostic names both API versions (missing: " .. tostring(missing) .. ")")
end)

test("stamp: an embedded winner with a dev- host version is a release winner against a stamped standalone", function()
    local embedded = loadAs("Homestead", "dev-abc1234")
    local captured = captureOn(embedded)
    loadSecond("Foundry-1.0_DevBuild", "dev-def5678")
    T.eq(_G.Foundry_1_0, embedded, "the embedded winner stays installed")
    T.eq(#captured, 1, "the suppressed DevBuild is reported once")
    local ok, missing = containsAll(captured, "DevBuild", "loaded nothing")
    T.truthy(ok, "diagnostic is the release-winner DevBuild message (missing: " .. tostring(missing) .. ")")
end)

test("stamp: versions that merely resemble the dev- prefix stay releases in an own folder", function()
    for _, v in ipairs({ "1.0.114-dev", "devbuild", "Dev-abc1234", "xdev-abc1234" }) do
        local F = loadAs("Foundry-1.0", v)
        T.eq(F.IS_DEV_BUILD, false, v .. " is a release")
        T.eq(F.VERSION, v, v .. " VERSION is the TOC string")
    end
end)

-- Red-without-change: case (ii) is the discriminator for the version-aware change,
-- NOT case (i). Case (i) fires with or without the third condition (current-1 ~=
-- current is true either way), so it cannot prove the change. Case (ii) can: with
-- the third condition (existing.API_VERSION ~= F.API_VERSION) deleted from
-- Foundry.lua, the same-version embed fires a spurious diagnostic and this suite
-- reports
--   "no diagnostic on a same-version embed: expected \"0\", got \"1\""
-- (observed by temporarily striking that clause, then restored to green).

return tests

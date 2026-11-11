-- Cost of the hot paths, current code against the 1.0.114 release.
--
-- Primary check, deterministic: the number of Lua VM instructions one
-- operation executes, counted with a debug.sethook count hook. Both builds run
-- in the same process through the same driver loop, so the driver's own
-- instructions cancel out of the difference.
--   * a db.profile read and an event dispatch must cost exactly the same
--   * each path callback relays sit on may cost at most 10 more per call for
--     each relay it crosses
--   * after the current code takes over the layout-1 copy in place, a
--     db.profile read and an event dispatch on objects made before or after
--     the takeover cost exactly what they cost on the current code alone
-- Secondary check, timing: five interleaved rounds per side, the fastest round
-- of each; the current code may be at most 15% slower on DB reads and event
-- dispatch; the measurement is repeated up to three times and fails only if
-- every attempt is over. Set FOUNDRY_TIMING_REPORT_ONLY=1 to print the ratio and not fail
-- on it (shared CI machines are noisy; the instruction counts stay the gate).
--
-- Adding a relay path: append a row to RELAY_PATHS. `setup(F)` runs on a fresh
-- build and returns `call`, a function that performs the path once the way a
-- player's session reaches it, and `relays` is the number of relays the call
-- crosses. The row is measured on both builds and held to relays times
-- RELAY_BUDGET extra instructions per call.
--
-- Set FOUNDRY_PERF_REPORT=1 to print every measured count.

local T = ...

local report = print   -- the real print: the mocks replace _G.print per test
local surfaces = assert(loadfile(T.testsDir .. "/Layout/surfaces.lua"))(T)

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local RELAY_BUDGET = 10
local ITERATIONS = 1000
local TIMING_ITERATIONS = 1000000
local TIMING_ROUNDS = 5
local TIMING_LIMIT = 1.15
local TIMING_ATTEMPTS = 3

local function noop() end

--------------------------------------------------------------------------------
-- measuring
--------------------------------------------------------------------------------

-- Runs `call` n times and returns how many VM instructions that took,
-- including the loop that drives it.
local function instructions(call, n)
    local count = 0
    local function hook() count = count + 1 end
    collectgarbage()
    debug.sethook(hook, "", 1)
    for _ = 1, n do call() end
    debug.sethook()
    return count
end

-- Builds the path on each build and returns instruction counts for both.
local function measure(path, n)
    local counts = {}
    for _, build in ipairs({ "pinned", "current" }) do
        local F = surfaces.load(build)
        local call = path.setup(F)
        T.eq(type(call), "function", path.name .. ": setup returns a callable on the " .. build .. " build")
        call()   -- first call outside the count: lazy setup, caches
        counts[build] = instructions(call, n)
    end
    if os.getenv("FOUNDRY_PERF_REPORT") then
        report(string.format("perf  %-34s pinned %7d  current %7d  per call %+.3f",
            path.name, counts.pinned, counts.current, (counts.current - counts.pinned) / n))
    end
    return counts
end

--------------------------------------------------------------------------------
-- the paths
--------------------------------------------------------------------------------

-- A DB controller whose profile has been read once, so every later read is the
-- cached path through the controller's metatable.
local function dbRead(F)
    T.loadedAddons["PerfAddon"] = true
    local db = F.DB:New({
        name = "PerfAddon", sv = "TestDB", defaultProfile = true,
        defaults = { profile = { size = 3 } },
    })
    local _ = db.profile
    return function() local _ = db.profile end
end

-- A registered event delivered through the controller's native frame.
local function eventDispatch(F)
    local controller = F.Events:New("PerfAddon")
    controller:Register("PERF_EVENT", noop)
    local frame = T.frames[#T.frames]
    return function() T.Fire(frame, "PERF_EVENT", 1) end
end

local HOT_PATHS = {
    { name = "db.profile read", setup = dbRead, unit = "DB" },
    { name = "event dispatch", setup = eventDispatch, unit = "Events" },
}

local RELAY_PATHS = {
    {
        name = "poll timer callback",
        relays = 1,
        setup = function(F)
            -- A region-wide-names client whose surname has not arrived: the
            -- hook is held and the one-second poll timer is scheduled.
            T.SetRegional(true)
            local c = F.Lifecycle:New(nil, "PerfPoll")
            c:OnAddonLoaded(noop)
            local frame = T.frames[1]
            T.Fire(frame, "ADDON_LOADED", "PerfPoll")
            T.Fire(frame, "PLAYER_LOGIN")
            T.Fire(frame, "PLAYER_ENTERING_WORLD")
            T.truthy(T.afters[1], "a poll timer is pending")
            return T.afters[1].cb
        end,
    },
    {
        name = "logout strip",
        relays = 2,  -- the Lifecycle dispatcher, then the DB logout entry
        setup = function(F)
            T.loadedAddons["PerfAddon"] = true
            local db = F.DB:New({
                name = "PerfAddon", sv = "TestDB", defaultProfile = true,
                defaults = { profile = { size = 3 } },
            })
            local _ = db.profile
            local frame = surfaces.dispatcherFrame()
            return function() T.Fire(frame, "PLAYER_LOGOUT") end
        end,
    },
    {
        name = "slash command",
        relays = 1,
        setup = function(F)
            local c = F.Commands:New({ name = "PerfCmd", slashes = { "/perfcmd" } })
            c:Register({ name = "go", handler = noop })
            local slash = SlashCmdList["PERFCMD"]
            return function() slash("go") end
        end,
    },
    {
        name = "tooltip post-call",
        relays = 1,
        setup = function(F)
            local processor = surfaces.installTooltipProcessor()
            F.Tooltip:New({ type = 1, handler = noop })
            local callback = processor.postCalls[1].fn
            local tooltip = surfaces.makeTooltip()
            local data = {}
            return function() callback(tooltip, data) end
        end,
    },
    {
        name = "settings launcher click",
        relays = 1,
        setup = function(F)
            local panel = surfaces.installSettingsLauncher()
            F.Settings:New({ title = "PerfPanel", buttonText = "Open", launch = noop })
            local click = panel.clicks[1]
            return function() click({}, "LeftButton", false) end
        end,
    },
    {
        name = "menu build",
        relays = 1,
        setup = function(F)
            surfaces.installMenuUtil()
            local c = F.Menu:New({ builder = noop })
            local button = surfaces.makeDropdownButton()
            c:SetupDropdown(button)
            local generator = button.setups[1]
            local root = surfaces.makeRootDescription()
            local owner = {}
            return function() generator(owner, root) end
        end,
    },
    {
        name = "list row initialization",
        relays = 1,
        setup = function(F)
            local c = F.List:New({
                name = "PerfList", parent = {}, elementType = "Button",
                extent = 20, initializer = noop,
            })
            local initializer = c:GetNativeHandles().view._initializer
            local frame, data = {}, {}
            return function() initializer(frame, data) end
        end,
    },
    {
        name = "list row extent",
        relays = 1,
        setup = function(F)
            local c = F.List:New({
                name = "PerfList", parent = {}, elementType = "Button",
                extentCalculator = function() return 20 end, initializer = noop,
            })
            local calculator = c:GetNativeHandles().view._calc
            local data = {}
            return function() calculator(1, data) end
        end,
    },
    {
        name = "lifecycle event dispatch",
        relays = 1,
        setup = function(F)
            -- Another addon's ADDON_LOADED: the dispatcher's script runs and
            -- the event handler finds nothing to do for this controller.
            F.Lifecycle:New(nil, "PerfLifecycle")
            local frame = surfaces.dispatcherFrame()
            return function() T.Fire(frame, "ADDON_LOADED", "SomeOtherAddon") end
        end,
    },
    {
        name = "window drag stop",
        relays = 1,
        setup = function(F)
            local win = CreateFrame("Frame", nil, UIParent)
            F.Window:Attach(win, { handle = win, geometry = {}, default = { "CENTER", "CENTER", 0, 0 } })
            local onDragStop = win:GetScript("OnDragStop")
            return function() onDragStop(win) end
        end,
    },
}

--------------------------------------------------------------------------------
-- instruction counts
--------------------------------------------------------------------------------

for _, path in ipairs(HOT_PATHS) do
    test("a " .. path.name .. " costs the same number of instructions as in the 1.0.114 release", function()
        local counts = measure(path, ITERATIONS)
        T.truthy(counts.pinned > ITERATIONS, "the count hook saw the path run")
        T.eq(counts.current, counts.pinned, path.name .. ": instructions over " .. ITERATIONS .. " calls")
    end)
end

for _, path in ipairs(RELAY_PATHS) do
    local budget = path.relays * RELAY_BUDGET
    test("the " .. path.name .. " path costs at most " .. budget
        .. " more instructions per call than the 1.0.114 release", function()
        local counts = measure(path, ITERATIONS)
        T.truthy(counts.pinned > 0, "the count hook saw the path run")
        local extra = (counts.current - counts.pinned) / ITERATIONS
        T.truthy(extra <= budget,
            path.name .. ": " .. extra .. " extra instructions per call, budget " .. budget)
    end)
end

--------------------------------------------------------------------------------
-- instruction counts after a takeover
--------------------------------------------------------------------------------

-- Loaded with T.loadCopy, so the current code alone is never itself a
-- takeover when the suite runs in takeover mode.
local function loadCurrentAlone()
    return T.loadCopy({ root = T.foundryRoot, files = T.FOUNDRY_FILES })
end

-- Instruction counts for one hot path: on the current code alone, and on
-- objects made before and after the current code takes over the layout-1 copy.
local function measureTakeover(path, n)
    local counts = {}
    for _, when in ipairs({ "alone", "before", "after" }) do
        T.installMocks("@project-version@")
        local call
        if when == "alone" then
            call = path.setup(loadCurrentAlone())
        else
            local F = T.loadOldCopy("layout1")
            if when == "before" then call = path.setup(F) end
            loadCurrentAlone()
            T.eq(rawget(F[path.unit], "_build"), T.libraryBuild(), path.name .. ": " .. path.unit .. " upgraded")
            if when == "after" then call = path.setup(F) end
        end
        call()
        counts[when] = instructions(call, n)
    end
    if os.getenv("FOUNDRY_PERF_REPORT") then
        report(string.format("perf  %-34s alone %7d  made before takeover %7d  made after %7d",
            path.name, counts.alone, counts.before, counts.after))
    end
    return counts
end

for _, path in ipairs(HOT_PATHS) do
    test("a " .. path.name .. " on objects made before or after a takeover of the layout-1 copy costs the same number of instructions as on the current code alone", function()
        local counts = measureTakeover(path, ITERATIONS)
        T.truthy(counts.alone > ITERATIONS, "the count hook saw the path run")
        T.eq(counts.before, counts.alone, path.name .. ": object made before the takeover, instructions over "
            .. ITERATIONS .. " calls")
        T.eq(counts.after, counts.alone, path.name .. ": object made after the takeover, instructions over "
            .. ITERATIONS .. " calls")
    end)
end

--------------------------------------------------------------------------------
-- timing
--------------------------------------------------------------------------------

local function timed(call, n)
    local start = os.clock()
    for _ = 1, n do call() end
    return os.clock() - start
end

for _, path in ipairs(HOT_PATHS) do
    test("a " .. path.name .. " is no more than 15% slower than in the 1.0.114 release", function()
        local calls = {}
        for _, build in ipairs({ "pinned", "current" }) do
            calls[build] = path.setup(surfaces.load(build))
            calls[build]()
        end
        -- A slow scheduler slice can land on one side of one measurement, so
        -- the whole interleaved measurement is repeated and only a ratio over
        -- the limit in every attempt fails.
        local ratios = {}
        for attempt = 1, TIMING_ATTEMPTS do
            local best = { pinned = math.huge, current = math.huge }
            for round = 1, TIMING_ROUNDS do
                -- Alternate which side goes first so neither always runs warm.
                local order = round % 2 == 1 and { "pinned", "current" } or { "current", "pinned" }
                for _, build in ipairs(order) do
                    collectgarbage()
                    local seconds = timed(calls[build], TIMING_ITERATIONS)
                    if seconds < best[build] then best[build] = seconds end
                end
            end
            local ratio = best.current / best.pinned
            ratios[attempt] = string.format("%.3f", ratio)
            if os.getenv("FOUNDRY_PERF_REPORT") or os.getenv("FOUNDRY_TIMING_REPORT_ONLY") then
                report(string.format("timing %-32s attempt %d pinned %.3fs  current %.3fs  ratio %.3f",
                    path.name, attempt, best.pinned, best.current, ratio))
            end
            if ratio <= TIMING_LIMIT then break end
        end
        if not os.getenv("FOUNDRY_TIMING_REPORT_ONLY") then
            T.truthy(tonumber(ratios[#ratios]) <= TIMING_LIMIT,
                path.name .. ": current/pinned time ratio over " .. TIMING_LIMIT
                .. " in every attempt (" .. table.concat(ratios, ", ") .. ")")
        end
    end)
end

return tests

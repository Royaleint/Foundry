-- Foundry.Events behavior tests. Loaded by Tests/run.lua, which passes the
-- harness table T. Returns a list of { name, fn } cases covering the public
-- contract (§2/§3 of the Reference and CYCLE-2-EVENTS plan) plus the edge cases
-- the master matrix enumerates: dev-raise vs release-refuse axis, atomic
-- validation, one-handler-per-event across all register methods, the fixed
-- RegisterOnce unregister-before-invoke order, GetNativeHandles snapshot
-- isolation + live-frame escape hatch, the Destroy teardown sequence, and the
-- LFGScanner enable/disable cycle.
--
-- Harness note: T.fresh() installs the additive CreateFrame("Frame") stub
-- (T.frames records every frame; each frame logs RegisterEvent /
-- RegisterUnitEvent / UnregisterEvent / UnregisterAllEvents / SetScript / Hide
-- / Show and captures the OnEvent script) and loads Modules/Events.lua, so each
-- case starts from a clean dev (or release) build with zero frames created.
-- T.Fire(frame, event, ...) synthesizes a native OnEvent delivery.

local T = ...

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

-- The controller's recorded frame (the one and only frame created by :New for
-- the common single-controller case is T.frames[1]).
local function noop() end

--------------------------------------------------------------------------------
-- Harness
--------------------------------------------------------------------------------

-- harness-stub
test("harness: CreateFrame stub records native calls and Events.lua loads", function()
    local F = T.fresh()
    T.eq(type(F.Events), "table", "Events module loaded")
    T.eq(type(F.Events.New), "function", "Events:New present")
    -- loadFoundry creates no frames; only :New does.
    T.eq(#T.frames, 0, "no frames before :New")
    F.Events:New("Stub")
    T.eq(#T.frames, 1, "one frame after :New")
    local fr = T.frames[1]
    -- The stub exposes every native method the controller drives plus Fire.
    for _, m in ipairs({ "RegisterEvent", "RegisterUnitEvent", "UnregisterEvent",
        "UnregisterAllEvents", "SetScript", "Hide", "Show", "IsShown" }) do
        T.eq(type(fr[m]), "function", "frame method " .. m)
    end
    T.eq(type(T.Fire), "function", "Fire helper present")
    -- SetScript("OnEvent", fn) captured the dispatcher.
    T.eq(type(fr._onEvent), "function", "OnEvent captured")
end)

-- bootstrap-detect
test("bootstrap dev/release detection on the Events build", function()
    T.installMocks("@project-version@"); local F1 = T.loadFoundry()
    T.truthy(F1.IS_DEV_BUILD, "literal token -> dev")
    T.eq(F1.VERSION, "dev", "dev placeholder version")
    T.installMocks("2.3.4"); local F2 = T.loadFoundry()
    T.falsy(F2.IS_DEV_BUILD, "real version -> release")
    T.eq(F2.VERSION, "2.3.4", "release version string")
    T.eq(F2.API_VERSION, 2, "library API_VERSION additive (not double-bumped)")
    T.installMocks("2.3.4"); _G.FOUNDRY_DEV_BUILD_OVERRIDE = true; local F3 = T.loadFoundry()
    T.truthy(F3.IS_DEV_BUILD, "override forces dev even on a real version")
end)

-- module-reg
test("HasModule / RequireModule behavior for Events", function()
    local F = T.fresh()
    T.truthy(F:HasModule("Events"), "has Events")
    T.falsy(F:HasModule("Nope"), "does not have Nope")
    T.eq(F:RequireModule("Events"), F.Events, "RequireModule returns the module")
    T.eq(F.Events.API_VERSION, 1, "Events.API_VERSION == 1")
    T.eq(F:RequireModule("Events", 1), F.Events, "RequireModule min=1 returns the module")
    T.raises(function() F:RequireModule("Events", 99) end, "above-max API raises", "API version")
    T.raises(function() F:RequireModule("Nope") end, "missing module raises in dev")
    T.eq(F.API_VERSION, 2, "library API_VERSION == 2")
    -- Missing module raises in a release build too.
    local FR = T.fresh("1.0.0")
    T.falsy(FR.IS_DEV_BUILD, "release build")
    T.raises(function() FR:RequireModule("Nope") end, "missing module raises in release")
end)

--------------------------------------------------------------------------------
-- New
--------------------------------------------------------------------------------

-- new-surface
test("New returns a controller exposing the public methods", function()
    local F = T.fresh()
    local c = F.Events:New("MyAddon")
    T.truthy(c, "controller created")
    for _, m in ipairs({ "Register", "RegisterUnit", "RegisterOnce", "Unregister",
        "UnregisterAll", "IsRegistered", "GetNativeHandles", "Destroy" }) do
        T.eq(type(c[m]), "function", "method " .. m)
    end
end)

-- new-one-frame-no-reg
test("New creates exactly one hidden frame and registers no event", function()
    local F = T.fresh()
    local c = F.Events:New("MyAddon")
    T.eq(#T.frames, 1, "exactly one frame created")
    local fr = T.frames[1]
    T.eq(#fr.calls.Hide, 1, "frame:Hide() recorded")
    T.truthy(not fr:IsShown(), "frame hidden")
    T.eq(type(fr._onEvent), "function", "OnEvent script captured")
    T.eq(#fr.calls.RegisterEvent, 0, "no RegisterEvent yet")
    T.eq(#fr.calls.RegisterUnitEvent, 0, "no RegisterUnitEvent yet")
    T.falsy(c:IsRegistered("PLAYER_LOGIN"), "nothing registered")
    local h = c:GetNativeHandles()
    T.eq(h.frame, fr, "GetNativeHandles().frame is the controller frame")
    T.eq(next(h.handlers), nil, "handlers snapshot empty")
end)

-- new-independent
test("controllers are independent, even for the same owner string", function()
    local F = T.fresh()
    local a = F.Events:New("Same")
    local b = F.Events:New("Same")
    T.truthy(a ~= b, "distinct controllers")
    local fa, fb = T.frames[1], T.frames[2]
    T.truthy(fa ~= fb, "distinct frames")
    T.eq(#T.frames, 2, "two frames")
    local ha, hb = a:GetNativeHandles(), b:GetNativeHandles()
    T.truthy(ha.handlers ~= hb.handlers, "distinct handler snapshots")
    T.truthy(ha.frame ~= hb.frame, "distinct frame identities")

    -- Same event name on both is allowed (dedup is per-controller, not global).
    local hitA, hitB = 0, 0
    a:Register("E", function() hitA = hitA + 1 end)
    b:Register("E", function() hitB = hitB + 1 end)
    T.truthy(a:IsRegistered("E"), "A registered E")
    T.truthy(b:IsRegistered("E"), "B registered E")

    -- Firing A's frame runs only A's handler; B never sees it.
    T.Fire(fa, "E")
    T.eq(hitA, 1, "A handler ran")
    T.eq(hitB, 0, "B handler did not run on A's fire")
    T.Fire(fb, "E")
    T.eq(hitB, 1, "B handler ran on its own fire")
    T.eq(hitA, 1, "A handler unchanged by B's fire")
end)

-- new-owner-invalid-dev
test("New rejects an invalid owner in a dev build", function()
    local F = T.fresh()
    for _, bad in ipairs({ "", 123, {}, true, function() end }) do
        T.raises(function() F.Events:New(bad) end,
            "owner " .. tostring(bad), "owner must be a non-empty string")
    end
    -- nil separately (cannot live in an array with holes).
    T.raises(function() F.Events:New(nil) end, "owner nil", "owner must be a non-empty string")
end)

-- new-owner-invalid-release
test("New refuses an invalid owner in a release build (prints, returns nil)", function()
    local F = T.fresh("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    local c
    local ok = pcall(function() c = F.Events:New("") end)
    T.truthy(ok, "no raise in release build")
    T.outputContains("owner must be a non-empty string", "diagnostic printed in release")
    T.eq(c, nil, "returned controller is nil")
end)

--------------------------------------------------------------------------------
-- Register
--------------------------------------------------------------------------------

-- reg-fire-routes
test("Register routes a fire to the handler exactly once", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local fr = T.frames[1]
    local hits = 0
    c:Register("PLAYER_LOGIN", function() hits = hits + 1 end)
    T.eq(#fr.calls.RegisterEvent, 1, "RegisterEvent recorded once")
    T.eq(fr.calls.RegisterEvent[1][1], "PLAYER_LOGIN", "correct event")
    T.truthy(c:IsRegistered("PLAYER_LOGIN"), "IsRegistered true")
    T.Fire(fr, "PLAYER_LOGIN")
    T.eq(hits, 1, "handler ran once")
end)

-- reg-signature-payload
test("handler signature is (event, ...) with the frame self dropped", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local fr = T.frames[1]
    local got, gotN
    c:Register("E", function(...)
        gotN = select("#", ...)
        got = { ... }  -- may have holes at the embedded nil; index explicitly
    end)
    -- Fire with the native frame as self, an embedded nil, then a trailing value.
    T.Fire(fr, "E", "arg1", 2, true, nil, 5)
    -- arg#1 is the event NAME, not the frame self.
    T.eq(got[1], "E", "arg1 is event name, not frame")
    T.eq(got[2], "arg1", "payload arg 1")
    T.eq(got[3], 2, "payload arg 2")
    T.eq(got[4], true, "payload arg 3")
    T.eq(got[5], nil, "embedded nil preserved")
    T.eq(got[6], 5, "value after the embedded nil preserved")
    -- The count must reach the trailing value (guards against #-length / pack
    -- reconstruction truncating at the embedded nil).
    T.eq(gotN, 6, "select('#') counts through the embedded nil to the trailing value")

    -- Zero-extra-args case: handler sees exactly (event).
    local got2N, got2first
    c:Register("F", function(...)
        got2N = select("#", ...)
        got2first = (select(1, ...))
    end)
    T.Fire(fr, "F")
    T.eq(got2first, "F", "lone arg is the event name")
    T.eq(got2N, 1, "no payload args beyond the event")
end)

-- reg-dup-atomic
test("duplicate Register is rejected atomically (dev raise, first handler intact)", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local fr = T.frames[1]
    local hit1, hit2 = 0, 0
    local fn1 = function() hit1 = hit1 + 1 end
    local fn2 = function() hit2 = hit2 + 1 end
    c:Register("E", fn1)
    T.raises(function() c:Register("E", fn2) end, "duplicate raises", "already registered")
    T.Fire(fr, "E")
    T.eq(hit1, 1, "fn1 still live")
    T.eq(hit2, 0, "fn2 never installed")
    T.eq(#fr.calls.RegisterEvent, 1, "RegisterEvent recorded exactly once")
    T.eq(c:GetNativeHandles().handlers["E"], fn1, "handler slot still fn1")
end)

-- reg-validation-atomic
-- "Atomic" means a rejected call disturbs neither the native frame nor any
-- pre-existing registration. To give the latter clause teeth we seed each fresh
-- controller with a valid "KEEP" handler first, then assert that the rejected
-- bad call left KEEP exactly as it was (still registered, still the lone native
-- RegisterEvent, still the live dispatch target). A rejection that wrongly
-- mutated the handler table or touched the frame would fail one of these.
test("Register validation is atomic for bad event and bad handler", function()
    local F = T.fresh()
    -- Seed a fresh controller with a valid registration; return it + its frame.
    local function seeded()
        local c = F.Events:New("A")
        local fr = T.frames[#T.frames]
        c:Register("KEEP", noop)
        T.eq(#fr.calls.RegisterEvent, 1, "KEEP registered natively once")
        return c, fr
    end
    local function keepIntact(c, fr, label)
        T.truthy(c:IsRegistered("KEEP"), "KEEP still registered (" .. label .. ")")
        T.eq(c:GetNativeHandles().handlers["KEEP"], noop, "KEEP slot unchanged (" .. label .. ")")
        T.eq(#fr.calls.RegisterEvent, 1, "no extra RegisterEvent (" .. label .. ")")
    end
    -- bad event
    for _, bad in ipairs({ 123, "", {}, true }) do
        local c, fr = seeded()
        T.raises(function() c:Register(bad, noop) end,
            "bad event " .. tostring(bad), "event must be a non-empty string")
        keepIntact(c, fr, "bad event " .. tostring(bad))
    end
    -- nil event separately
    do
        local c, fr = seeded()
        T.raises(function() c:Register(nil, noop) end, "nil event", "event must be a non-empty string")
        keepIntact(c, fr, "nil event")
    end
    -- bad handler
    for _, bad in ipairs({ "notfn", 123, {}, true }) do
        local c, fr = seeded()
        T.raises(function() c:Register("E", bad) end,
            "bad handler " .. tostring(bad), "requires a handler function")
        T.falsy(c:IsRegistered("E"), "E not registered (bad handler)")
        keepIntact(c, fr, "bad handler " .. tostring(bad))
    end
    -- nil handler separately
    do
        local c, fr = seeded()
        T.raises(function() c:Register("E", nil) end, "nil handler", "requires a handler function")
        T.falsy(c:IsRegistered("E"), "E not registered (nil handler)")
        keepIntact(c, fr, "nil handler")
    end
end)

-- reg-validation-order
test("Register reports handler-type error before duplicate error", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    c:Register("E", noop)
    -- E already registered, but a bad handler type must surface the type error,
    -- not the duplicate error (type checks precede the duplicate check).
    local err = T.raises(function() c:Register("E", "bad") end,
        "type before dup", "requires a handler function")
    T.falsy(tostring(err):find("already registered", 1, true),
        "must not be the duplicate error")
    -- Original still intact.
    T.truthy(c:IsRegistered("E"), "original registration intact")
end)

-- reg-dup-release
test("duplicate Register in a release build refuses without mutating", function()
    local F = T.fresh("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    local c = F.Events:New("A")
    local fr = T.frames[1]
    local hit1, hit2 = 0, 0
    local fn1 = function() hit1 = hit1 + 1 end
    c:Register("E", fn1)
    local ok = pcall(function() c:Register("E", function() hit2 = hit2 + 1 end) end)
    T.truthy(ok, "no raise in release")
    T.outputContains("already registered", "diagnostic printed")
    T.Fire(fr, "E")
    T.eq(hit1, 1, "fn1 stays live")
    T.eq(hit2, 0, "second handler never installed")
    T.eq(#fr.calls.RegisterEvent, 1, "RegisterEvent recorded once")
end)

--------------------------------------------------------------------------------
-- Dispatch
--------------------------------------------------------------------------------

-- fire-no-live-handler
test("firing an event with no live handler is a silent no-op", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local fr = T.frames[1]
    -- (a) never registered: no error, no call.
    local ok1 = pcall(function() T.Fire(fr, "NEVER_REGISTERED") end)
    T.truthy(ok1, "fire for unregistered event does not error")
    -- (b) mid-teardown window: handler removed but a fire still arrives.
    local hits = 0
    c:Register("E", function() hits = hits + 1 end)
    c:Unregister("E")
    local ok2 = pcall(function() T.Fire(fr, "E") end)
    T.truthy(ok2, "fire after unregister does not error")
    T.eq(hits, 0, "removed handler not invoked")
end)

--------------------------------------------------------------------------------
-- RegisterUnit
--------------------------------------------------------------------------------

-- runit-arity-unit1
test("RegisterUnit with one unit forwards (event, unit1) and no unit2", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local fr = T.frames[1]
    local got
    c:RegisterUnit("UNIT_HEALTH", function(...) got = { n = select("#", ...), select(1, ...) } end, "player")
    T.eq(#fr.calls.RegisterUnitEvent, 1, "RegisterUnitEvent recorded once")
    local rec = fr.calls.RegisterUnitEvent[1]
    T.eq(rec.event, "UNIT_HEALTH", "event")
    T.eq(rec.unit1, "player", "unit1")
    T.eq(rec.unit2, nil, "unit2 absent")
    T.eq(rec.n, 2, "exactly two args passed (no third)")
    T.eq(#fr.calls.RegisterEvent, 0, "plain RegisterEvent not used")
    T.truthy(c:IsRegistered("UNIT_HEALTH"), "registered")
    T.Fire(fr, "UNIT_HEALTH", "player")
    T.eq(got.n, 2, "handler saw event + unit")
    T.eq(got[1], "UNIT_HEALTH", "arg1 is event (self dropped)")
    T.eq(got[2], "player", "arg2 is unit")
end)

-- runit-arity-unit2
test("RegisterUnit with two units forwards (event, unit1, unit2) in order", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local fr = T.frames[1]
    local ran = false
    c:RegisterUnit("UNIT_AURA", function() ran = true end, "player", "target")
    T.eq(#fr.calls.RegisterUnitEvent, 1, "RegisterUnitEvent recorded once")
    local rec = fr.calls.RegisterUnitEvent[1]
    T.eq(rec.event, "UNIT_AURA", "event")
    T.eq(rec.unit1, "player", "unit1")
    T.eq(rec.unit2, "target", "unit2 forwarded")
    T.eq(rec.n, 3, "three args passed in order")
    T.truthy(c:IsRegistered("UNIT_AURA"), "registered")
    T.Fire(fr, "UNIT_AURA", "target")
    T.truthy(ran, "fire routes to handler")
end)

-- runit-unit-validation-atomic
test("RegisterUnit validates unit1/unit2 atomically; optional-absent accepted", function()
    local F = T.fresh()
    -- missing/invalid unit1
    for _, bad in ipairs({ "", 123 }) do
        local c = F.Events:New("A")
        local fr = T.frames[#T.frames]
        T.raises(function() c:RegisterUnit("E", noop, bad) end,
            "bad unit1 " .. tostring(bad), "requires unit1 to be a non-empty string")
        T.falsy(c:IsRegistered("E"), "not registered (bad unit1)")
        T.eq(#fr.calls.RegisterUnitEvent, 0, "no RegisterUnitEvent (bad unit1)")
    end
    do  -- nil unit1
        local c = F.Events:New("A")
        local fr = T.frames[#T.frames]
        T.raises(function() c:RegisterUnit("E", noop) end, "nil unit1",
            "requires unit1 to be a non-empty string")
        T.eq(#fr.calls.RegisterUnitEvent, 0, "no RegisterUnitEvent (nil unit1)")
    end
    -- invalid-when-supplied unit2
    for _, bad in ipairs({ "", 123 }) do
        local c = F.Events:New("A")
        local fr = T.frames[#T.frames]
        T.raises(function() c:RegisterUnit("E", noop, "player", bad) end,
            "bad unit2 " .. tostring(bad), "unit2, when supplied, must be a non-empty string")
        T.falsy(c:IsRegistered("E"), "not registered (bad unit2)")
        T.eq(#fr.calls.RegisterUnitEvent, 0, "no RegisterUnitEvent (bad unit2)")
    end
    -- optional-absent path accepted: unit2 == nil succeeds.
    do
        local c = F.Events:New("A")
        local fr = T.frames[#T.frames]
        c:RegisterUnit("E", noop, "player", nil)
        T.truthy(c:IsRegistered("E"), "unit2 nil accepted")
        T.eq(#fr.calls.RegisterUnitEvent, 1, "RegisterUnitEvent recorded")
        T.eq(fr.calls.RegisterUnitEvent[1].unit2, nil, "unit2 absent")
    end
end)

-- runit-shared-validation
test("RegisterUnit shares Register's event/handler validation (before unit checks)", function()
    local F = T.fresh()
    -- bad event
    for _, bad in ipairs({ 123, "" }) do
        local c = F.Events:New("A")
        local fr = T.frames[#T.frames]
        T.raises(function() c:RegisterUnit(bad, noop, "player") end,
            "bad event " .. tostring(bad), "event must be a non-empty string")
        T.eq(#fr.calls.RegisterUnitEvent, 0, "no RegisterUnitEvent (bad event)")
        T.falsy(c:IsRegistered("E"), "not registered")
    end
    -- bad handler
    for _, bad in ipairs({ "nope" }) do
        local c = F.Events:New("A")
        local fr = T.frames[#T.frames]
        T.raises(function() c:RegisterUnit("E", bad, "player") end,
            "bad handler", "requires a handler function")
        T.eq(#fr.calls.RegisterUnitEvent, 0, "no RegisterUnitEvent (bad handler)")
        T.falsy(c:IsRegistered("E"), "not registered")
    end
    do  -- nil handler
        local c = F.Events:New("A")
        local fr = T.frames[#T.frames]
        T.raises(function() c:RegisterUnit("E", nil, "player") end,
            "nil handler", "requires a handler function")
        T.eq(#fr.calls.RegisterUnitEvent, 0, "no RegisterUnitEvent (nil handler)")
    end
end)

-- runit-dup-cross-method
test("one-handler-per-event spans Register and RegisterUnit", function()
    -- RegisterUnit then RegisterUnit
    do
        local F = T.fresh()
        local c = F.Events:New("A")
        local fr = T.frames[1]
        local h1, h2 = 0, 0
        c:RegisterUnit("E", function() h1 = h1 + 1 end, "player")
        T.raises(function() c:RegisterUnit("E", function() h2 = h2 + 1 end, "target") end,
            "runit dup", "already registered")
        T.eq(#fr.calls.RegisterUnitEvent, 1, "no extra RegisterUnitEvent after rejection")
        T.Fire(fr, "E", "player")
        T.eq(h1, 1, "first handler intact"); T.eq(h2, 0, "second never installed")
    end
    -- Register after RegisterUnit
    do
        local F = T.fresh()
        local c = F.Events:New("A")
        local fr = T.frames[1]
        local h1, h2 = 0, 0
        c:RegisterUnit("E", function() h1 = h1 + 1 end, "player")
        T.raises(function() c:Register("E", function() h2 = h2 + 1 end) end,
            "register after runit dup", "already registered")
        T.eq(#fr.calls.RegisterEvent, 0, "no RegisterEvent after rejection")
        T.Fire(fr, "E", "player")
        T.eq(h1, 1, "first handler intact"); T.eq(h2, 0, "second never installed")
    end
    -- RegisterUnit after Register
    do
        local F = T.fresh()
        local c = F.Events:New("A")
        local fr = T.frames[1]
        local h1, h2 = 0, 0
        c:Register("E", function() h1 = h1 + 1 end)
        T.raises(function() c:RegisterUnit("E", function() h2 = h2 + 1 end, "player") end,
            "runit after register dup", "already registered")
        T.eq(#fr.calls.RegisterUnitEvent, 0, "no RegisterUnitEvent after rejection")
        T.Fire(fr, "E")
        T.eq(h1, 1, "first handler intact"); T.eq(h2, 0, "second never installed")
    end
end)

-- runit-destroyed
test("RegisterUnit on a destroyed controller raises its own message", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    c:Destroy()
    T.raises(function() c:RegisterUnit("E", noop, "player") end,
        "destroyed runit", "Events:RegisterUnit called on a destroyed controller")
end)

--------------------------------------------------------------------------------
-- RegisterOnce
--------------------------------------------------------------------------------

-- ronce-fire-once
test("RegisterOnce fires exactly once then auto-unregisters; slot frees", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local fr = T.frames[1]
    local hits, payload = 0, nil
    c:RegisterOnce("PLAYER_ENTERING_WORLD", function(...)
        hits = hits + 1
        payload = { select(1, ...) }
    end)
    T.eq(#fr.calls.RegisterEvent, 1, "RegisterEvent recorded")
    T.truthy(c:IsRegistered("PLAYER_ENTERING_WORLD"), "registered before fire")
    T.Fire(fr, "PLAYER_ENTERING_WORLD", true, false)
    T.eq(hits, 1, "ran once")
    T.eq(payload[1], "PLAYER_ENTERING_WORLD", "arg1 is event (self dropped)")
    T.eq(payload[2], true, "payload preserved (isInitialLogin)")
    T.eq(payload[3], false, "payload preserved (isReload)")
    T.falsy(c:IsRegistered("PLAYER_ENTERING_WORLD"), "unregistered after fire")
    T.eq(#fr.calls.UnregisterEvent, 1, "UnregisterEvent recorded once")
    T.eq(fr.calls.UnregisterEvent[1][1], "PLAYER_ENTERING_WORLD", "correct event unregistered")
    -- Fire again: does not run again.
    T.Fire(fr, "PLAYER_ENTERING_WORLD", true, false)
    T.eq(hits, 1, "no second run")
    -- Slot freed: Register the same event succeeds and routes to the new handler.
    local h2 = 0
    c:Register("PLAYER_ENTERING_WORLD", function() h2 = h2 + 1 end)
    T.Fire(fr, "PLAYER_ENTERING_WORLD")
    T.eq(h2, 1, "re-registered handler runs")
    T.eq(hits, 1, "once-handler still does not run")
end)

-- ronce-unregister-before-invoke
test("RegisterOnce auto-unregisters BEFORE invoking the consumer handler", function()
    -- (a) IsRegistered is already false at handler entry.
    do
        local F = T.fresh()
        local c = F.Events:New("A")
        local fr = T.frames[1]
        local seenRegisteredAtEntry
        c:RegisterOnce("E", function()
            seenRegisteredAtEntry = c:IsRegistered("E")
        end)
        T.Fire(fr, "E")
        T.eq(seenRegisteredAtEntry, false, "slot already free at handler entry")
    end
    -- (b) re-registering the SAME event in the body succeeds (no dup raise).
    do
        local F = T.fresh()
        local c = F.Events:New("A")
        local fr = T.frames[1]
        local onceHits, h2Hits = 0, 0
        local h2 = function() h2Hits = h2Hits + 1 end
        c:RegisterOnce("E", function()
            onceHits = onceHits + 1
            c:Register("E", h2)  -- must not raise "already registered"
        end)
        local ok = pcall(function() T.Fire(fr, "E") end)
        T.truthy(ok, "re-register inside once-handler does not raise")
        T.eq(onceHits, 1, "once-handler ran once")
        T.truthy(c:IsRegistered("E"), "E registered again after the fire")
        T.eq(c:GetNativeHandles().handlers["E"], h2, "slot holds h2, not the once-wrapper")
        T.Fire(fr, "E")
        T.eq(h2Hits, 1, "second fire calls h2")
        T.eq(onceHits, 1, "original once-handler does not run again")
    end
end)

-- ronce-self-rearm
test("a once-handler can re-arm itself via RegisterOnce in its body", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local fr = T.frames[1]
    local hits = 0
    -- Re-arm exactly once (on the first fire). This proves the free-slot-before-
    -- invoke order supports a RegisterOnce re-arm without an "already registered"
    -- raise; each arming fires exactly once. The first fire re-arms, the second
    -- fire consumes the re-arm and leaves the slot free.
    local function fn()
        hits = hits + 1
        if hits == 1 then c:RegisterOnce("E", fn) end  -- re-arm once
    end
    c:RegisterOnce("E", fn)
    local ok1 = pcall(function() T.Fire(fr, "E") end)
    T.truthy(ok1, "first fire ok (no 'already registered' raise on re-arm)")
    T.eq(hits, 1, "ran once")
    T.truthy(c:IsRegistered("E"), "re-armed after first fire")
    local ok2 = pcall(function() T.Fire(fr, "E") end)
    T.truthy(ok2, "second fire ok")
    T.eq(hits, 2, "ran again from re-arm")
    T.falsy(c:IsRegistered("E"), "the re-arm fired and freed the slot")
end)

-- ronce-wrapper-snapshot
test("a not-yet-fired RegisterOnce occupies the slot with the wrapper", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local raw = function() end
    c:RegisterOnce("E", raw)
    T.truthy(c:IsRegistered("E"), "registered before fire")
    local snap = c:GetNativeHandles().handlers["E"]
    T.eq(type(snap), "function", "slot holds a function (the once-wrapper)")
    T.truthy(snap ~= raw, "slot holds the internal wrapper, not the raw handler")
end)

-- ronce-validation-dup-destroyed
test("RegisterOnce validation, duplicate, and destroyed-guard", function()
    -- bad event / handler are atomic.
    do
        local F = T.fresh()
        local c = F.Events:New("A")
        local fr = T.frames[1]
        T.raises(function() c:RegisterOnce(123, noop) end, "bad event 123", "event must be a non-empty string")
        T.raises(function() c:RegisterOnce("", noop) end, "empty event", "event must be a non-empty string")
        T.raises(function() c:RegisterOnce("E", nil) end, "nil handler", "requires a handler function")
        T.raises(function() c:RegisterOnce("E", 123) end, "num handler", "requires a handler function")
        T.eq(#fr.calls.RegisterEvent, 0, "no RegisterEvent recorded on any rejection")
        T.falsy(c:IsRegistered("E"), "slot untouched")
    end
    -- duplicate against an already-registered (not-yet-fired) slot.
    do
        local F = T.fresh()
        local c = F.Events:New("A")
        c:RegisterOnce("E", noop)
        T.raises(function() c:RegisterOnce("E", noop) end, "ronce dup ronce", "already registered")
    end
    do
        local F = T.fresh()
        local c = F.Events:New("A")
        local fn1 = function() end
        c:Register("E", fn1)
        T.raises(function() c:RegisterOnce("E", noop) end, "register then ronce", "already registered")
        T.eq(c:GetNativeHandles().handlers["E"], fn1, "original intact")
    end
    do
        local F = T.fresh()
        local c = F.Events:New("A")
        c:RegisterOnce("E", noop)
        T.raises(function() c:Register("E", noop) end, "ronce then register", "already registered")
    end
    -- destroyed-controller guard with its own message.
    do
        local F = T.fresh()
        local c = F.Events:New("A")
        c:Destroy()
        T.raises(function() c:RegisterOnce("E", noop) end,
            "destroyed ronce", "Events:RegisterOnce called on a destroyed controller")
    end
end)

--------------------------------------------------------------------------------
-- Unregister
--------------------------------------------------------------------------------

-- unreg-removes-native
test("Unregister removes one event and its native subscription, leaving others", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local fr = T.frames[1]
    local a, b = 0, 0
    c:Register("A", function() a = a + 1 end)
    c:Register("B", function() b = b + 1 end)
    c:Unregister("A")
    T.falsy(c:IsRegistered("A"), "A removed")
    T.truthy(c:IsRegistered("B"), "B remains")
    T.eq(#fr.calls.UnregisterEvent, 1, "UnregisterEvent recorded once")
    T.eq(fr.calls.UnregisterEvent[1][1], "A", "A unregistered")
    T.Fire(fr, "A"); T.eq(a, 0, "A handler gone")
    T.Fire(fr, "B"); T.eq(b, 1, "B handler still fires")
end)

-- unreg-idempotent
test("Unregister of an unregistered event is a silent no-op (dev and release)", function()
    for _, ver in ipairs({ "@project-version@", "1.0.0" }) do
        local F = T.fresh(ver == "@project-version@" and nil or ver)
        local c = F.Events:New("A")
        local fr = T.frames[1]
        c:Register("KEEP", noop)
        -- Never-registered FOO.
        local ok1 = pcall(function() c:Unregister("FOO") end)
        T.truthy(ok1, "no raise for never-registered (" .. ver .. ")")
        T.eq(#fr.calls.UnregisterEvent, 0, "no native UnregisterEvent for never-registered")
        -- Register then Unregister then a second Unregister.
        c:Register("FOO", noop)
        c:Unregister("FOO")
        T.eq(#fr.calls.UnregisterEvent, 1, "one native UnregisterEvent after first removal")
        local ok2 = pcall(function() c:Unregister("FOO") end)
        T.truthy(ok2, "no raise on second Unregister (" .. ver .. ")")
        T.eq(#fr.calls.UnregisterEvent, 1, "no extra native UnregisterEvent (early return)")
        T.truthy(c:IsRegistered("KEEP"), "unrelated registration untouched")
    end
end)

-- unreg-reregister
test("Unregister frees the slot so Register works again", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local fr = T.frames[1]
    local one, two = 0, 0
    c:Register("E", function() one = one + 1 end)
    c:Unregister("E")
    local ok = pcall(function() c:Register("E", function() two = two + 1 end) end)
    T.truthy(ok, "re-register does not raise a duplicate")
    T.Fire(fr, "E")
    T.eq(one, 0, "first handler gone")
    T.eq(two, 1, "second handler fires")
end)

-- unreg-validation
test("Unregister rejects invalid input in dev even though it is idempotent", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    T.raises(function() c:Unregister(123) end, "num", "event must be a non-empty string")
    T.raises(function() c:Unregister("") end, "empty", "event must be a non-empty string")
    T.raises(function() c:Unregister(nil) end, "nil", "event must be a non-empty string")
end)

-- fire-after-unreg
test("a fire arriving after Unregister does not run the handler", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local fr = T.frames[1]
    local hits = 0
    c:Register("E", function() hits = hits + 1 end)
    c:Unregister("E")
    local ok = pcall(function() T.Fire(fr, "E") end)
    T.truthy(ok, "no error")
    T.eq(hits, 0, "handler did not run")
    T.falsy(c:IsRegistered("E"), "not registered")
end)

--------------------------------------------------------------------------------
-- UnregisterAll
--------------------------------------------------------------------------------

-- unregall-clears-native
test("UnregisterAll clears every handler and the native set; controller survives", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local fr = T.frames[1]
    local a, b, d = 0, 0, 0
    c:Register("A", function() a = a + 1 end)
    c:RegisterUnit("B", function() b = b + 1 end, "player")
    c:RegisterOnce("D", function() d = d + 1 end)
    c:UnregisterAll()
    T.falsy(c:IsRegistered("A"), "A cleared")
    T.falsy(c:IsRegistered("B"), "B cleared")
    T.falsy(c:IsRegistered("D"), "D cleared")
    T.eq(next(c:GetNativeHandles().handlers), nil, "handlers snapshot empty")
    T.eq(#fr.calls.UnregisterAllEvents, 1, "UnregisterAllEvents recorded once")
    T.Fire(fr, "A"); T.Fire(fr, "B", "player"); T.Fire(fr, "D")
    T.eq(a, 0, "A gone"); T.eq(b, 0, "B gone"); T.eq(d, 0, "D gone")
    -- Controller not destroyed: Register again works and fires.
    local n = 0
    c:Register("NEW", function() n = n + 1 end)
    T.Fire(fr, "NEW")
    T.eq(n, 1, "fresh registration after UnregisterAll fires")
end)

-- unregall-lfg-cycle
test("LFGScanner SetEnabled cycle: enable/disable repeats cleanly", function()
    local F = T.fresh()
    local c = F.Events:New("LFGScanner")
    local fr = T.frames[1]
    local results, avail = 0, 0
    local function enable()
        c:Register("LFG_LIST_SEARCH_RESULTS_RECEIVED", function() results = results + 1 end)
        c:Register("LFG_LIST_AVAILABILITY_UPDATE", function() avail = avail + 1 end)
    end
    local prevRegCount = 0
    for cycle = 1, 3 do
        local okEnable = pcall(enable)
        T.truthy(okEnable, "enable cycle " .. cycle .. " no duplicate raise")
        -- exactly 2 new RegisterEvent calls this cycle
        T.eq(#fr.calls.RegisterEvent - prevRegCount, 2,
            "two RegisterEvent this cycle (" .. cycle .. ")")
        prevRegCount = #fr.calls.RegisterEvent
        -- fire both: hits accrue
        T.Fire(fr, "LFG_LIST_SEARCH_RESULTS_RECEIVED")
        T.Fire(fr, "LFG_LIST_AVAILABILITY_UPDATE")
        T.eq(results, cycle, "results hit this cycle")
        T.eq(avail, cycle, "avail hit this cycle")
        -- disable
        c:UnregisterAll()
        T.falsy(c:IsRegistered("LFG_LIST_AVAILABILITY_UPDATE"), "B cleared after UnregisterAll")
        -- fire both: no hits while disabled
        T.Fire(fr, "LFG_LIST_SEARCH_RESULTS_RECEIVED")
        T.Fire(fr, "LFG_LIST_AVAILABILITY_UPDATE")
        T.eq(results, cycle, "no extra results while disabled")
        T.eq(avail, cycle, "no extra avail while disabled")
    end
    T.eq(#fr.calls.UnregisterAllEvents, 3, "three disable cycles")
end)

-- unregall-empty-noop
test("UnregisterAll on a controller with no registrations is a safe no-op", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local fr = T.frames[1]
    local ok1 = pcall(function() c:UnregisterAll() end)
    T.truthy(ok1, "no error on empty UnregisterAll")
    T.eq(#fr.calls.UnregisterAllEvents, 1, "native UnregisterAllEvents still called")
    T.eq(next(c:GetNativeHandles().handlers), nil, "handlers empty")
    T.falsy(c:IsRegistered("ANYTHING"), "nothing registered")
    local ok2 = pcall(function() c:UnregisterAll() end)
    T.truthy(ok2, "second UnregisterAll also safe")
    T.eq(#fr.calls.UnregisterAllEvents, 2, "called again (frame live set kept in sync)")
end)

--------------------------------------------------------------------------------
-- IsRegistered
--------------------------------------------------------------------------------

-- isreg-boolean-no-side-effects
test("IsRegistered returns a strict boolean with no side effects", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local fr = T.frames[1]
    T.eq(c:IsRegistered("E"), false, "fresh -> exactly false")
    c:Register("E", noop)
    T.eq(c:IsRegistered("E"), true, "registered -> exactly true")
    -- No side effects: querying recorded no native register/unregister.
    T.eq(#fr.calls.RegisterEvent, 1, "only the explicit Register recorded")
    T.eq(#fr.calls.UnregisterEvent, 0, "no UnregisterEvent from querying")
    -- Dispatch still works after querying.
    local hits = 0
    c:Unregister("E")
    c:Register("E", function() hits = hits + 1 end)
    c:IsRegistered("E")
    T.Fire(fr, "E")
    T.eq(hits, 1, "dispatch unaffected by IsRegistered")
end)

--------------------------------------------------------------------------------
-- GetNativeHandles
--------------------------------------------------------------------------------

-- gnh-shape-snapshot-isolation
test("GetNativeHandles shape, and the handlers snapshot is isolated from dispatch", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local fr = T.frames[1]
    local eHits = 0
    local eFn = function() eHits = eHits + 1 end
    c:Register("E", eFn)
    c:Register("F", noop)
    local h = c:GetNativeHandles()
    T.eq(h.frame, fr, "frame identity")
    T.eq(type(h.handlers), "table", "handlers is a table")
    T.eq(h.handlers["E"], eFn, "handlers[E] is the registered fn")
    T.eq(type(h.handlers["F"]), "function", "handlers[F] present")
    -- Mutate the snapshot: must not affect dispatch.
    h.handlers["E"] = nil
    h.handlers["BOGUS"] = function() error("never") end
    T.Fire(fr, "E")
    T.eq(eHits, 1, "original E handler still dispatches (reads live table)")
    T.truthy(c:IsRegistered("E"), "E still registered after snapshot mutation")
    local okBogus = pcall(function() T.Fire(fr, "BOGUS") end)
    T.truthy(okBogus, "injected BOGUS never runs (no live entry)")
end)

-- gnh-snapshot-point-in-time
test("each GetNativeHandles call is a fresh point-in-time copy; frame identity stable", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local hA = function() end
    local hB = function() end
    c:Register("A", hA)
    local h1 = c:GetNativeHandles()
    c:Register("B", hB)
    T.eq(h1.handlers["A"], hA, "h1 has A")
    T.eq(h1.handlers["B"], nil, "h1 does NOT have B (point-in-time)")
    local h2 = c:GetNativeHandles()
    T.eq(h2.handlers["A"], hA, "h2 has A")
    T.eq(h2.handlers["B"], hB, "h2 has B")
    T.truthy(h1.handlers ~= h2.handlers, "distinct snapshot table identities")
    T.eq(h1.frame, h2.frame, "frame identity stable across calls")
end)

-- gnh-frame-live-escape-hatch
test("GetNativeHandles().frame is the live frame (escape hatch); controller still works", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local fr = T.frames[1]
    local h = c:GetNativeHandles()
    -- Direct call on the live frame records on the stub.
    h.frame:RegisterEvent("X")
    T.eq(#fr.calls.RegisterEvent, 1, "direct frame:RegisterEvent recorded on the live set")
    T.eq(fr.calls.RegisterEvent[1][1], "X", "X recorded")
    -- Reaching for the handles did not detach the controller.
    local hits = 0
    c:Register("E", function() hits = hits + 1 end)
    T.Fire(fr, "E")
    T.eq(hits, 1, "controller methods still work after GetNativeHandles")
end)

--------------------------------------------------------------------------------
-- Destroy
--------------------------------------------------------------------------------

-- destroy-teardown-sequence
test("Destroy runs UnregisterAllEvents, detaches OnEvent, hides, clears handlers", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local fr = T.frames[1]
    c:Register("A", noop)
    c:Register("B", noop)
    c:Destroy()
    T.eq(#fr.calls.UnregisterAllEvents, 1, "UnregisterAllEvents called")
    -- OnEvent detached: last SetScript("OnEvent", ...) recorded with nil fn.
    local lastOnEvent
    for _, rec in ipairs(fr.calls.SetScript) do
        if rec[1] == "OnEvent" then lastOnEvent = rec end
    end
    T.truthy(lastOnEvent, "an OnEvent SetScript was recorded")
    T.eq(lastOnEvent[2], nil, "OnEvent script detached (set to nil)")
    T.eq(fr._onEvent, nil, "captured OnEvent now nil")
    T.eq(#fr.calls.Hide, 2, "Hide called again at destroy (one at New, one at Destroy)")
    T.truthy(not fr:IsShown(), "frame hidden")
end)

-- destroy-teardown-order
-- Matrix MUST: the *relative ordering* of the native teardown calls is the
-- documented contract -- UnregisterAllEvents() FIRST, THEN SetScript("OnEvent",
-- nil), THEN Hide(). The per-method call buckets in run.lua count each call but
-- carry no shared monotonic index, so cross-method order is otherwise
-- unobservable. We instrument the live frame with a single ordered log BEFORE
-- Destroy (wrapping the three native methods so each appends one step), then
-- assert the three steps land in the documented sequence. A regression that
-- reordered Hide() ahead of UnregisterAllEvents(), or detached OnEvent before
-- clearing the native set, would pass every per-method count assertion above but
-- fail here.
test("Destroy teardown happens in the documented order: UnregisterAllEvents, then OnEvent-nil SetScript, then Hide", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local fr = T.frames[1]
    c:Register("A", noop)
    c:Register("B", noop)

    -- Shared ordered log with a monotonic step index. We wrap the live frame's
    -- three teardown methods, recording the step then delegating to the original
    -- recorder so the existing per-method buckets stay accurate.
    local log = {}
    local origUnregAll = fr.UnregisterAllEvents
    local origSetScript = fr.SetScript
    local origHide = fr.Hide
    function fr:UnregisterAllEvents(...)
        log[#log + 1] = "UnregisterAllEvents"
        return origUnregAll(self, ...)
    end
    function fr:SetScript(name, fn, ...)
        -- Only the OnEvent-nil detach is part of the teardown sequence.
        if name == "OnEvent" and fn == nil then
            log[#log + 1] = "SetScript(OnEvent,nil)"
        end
        return origSetScript(self, name, fn, ...)
    end
    function fr:Hide(...)
        log[#log + 1] = "Hide"
        return origHide(self, ...)
    end

    c:Destroy()

    -- Exactly the three teardown steps, in the documented order.
    T.eq(#log, 3, "exactly three ordered teardown steps recorded")
    T.eq(log[1], "UnregisterAllEvents", "step 1: UnregisterAllEvents first")
    T.eq(log[2], "SetScript(OnEvent,nil)", "step 2: OnEvent script detached after the native set is cleared")
    T.eq(log[3], "Hide", "step 3: Hide last (after unregister + detach)")
end)

-- destroy-inert-dispatch
test("after Destroy a stray fire on the detached frame invokes nothing", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local fr = T.frames[1]
    local hits = 0
    c:Register("E", function() hits = hits + 1 end)
    c:Destroy()
    local ok = pcall(function() T.Fire(fr, "E") end)
    T.truthy(ok, "no error from a stray fire")
    T.eq(hits, 0, "handler not invoked (script nil / table cleared)")
    T.eq(#T.output, 0, "no output")
end)

-- destroy-all-methods-fail-dev
test("after Destroy every method fails loudly in dev with its own message", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    c:Destroy()
    T.raises(function() c:Register("E", noop) end,
        "Register", "Events:Register called on a destroyed controller")
    T.raises(function() c:RegisterUnit("E", noop, "player") end,
        "RegisterUnit", "Events:RegisterUnit called on a destroyed controller")
    T.raises(function() c:RegisterOnce("E", noop) end,
        "RegisterOnce", "Events:RegisterOnce called on a destroyed controller")
    T.raises(function() c:Unregister("E") end,
        "Unregister", "Events:Unregister called on a destroyed controller")
    T.raises(function() c:UnregisterAll() end,
        "UnregisterAll", "Events:UnregisterAll called on a destroyed controller")
    T.raises(function() c:IsRegistered("E") end,
        "IsRegistered", "Events:IsRegistered called on a destroyed controller")
    T.raises(function() c:GetNativeHandles() end,
        "GetNativeHandles", "Events:GetNativeHandles called on a destroyed controller")
    T.raises(function() c:Destroy() end,
        "Destroy", "Events:Destroy called on a destroyed controller")
end)

-- destroy-double
test("double Destroy refuses, not a silent second teardown", function()
    local F = T.fresh()
    local c = F.Events:New("A")
    local fr = T.frames[1]
    -- Register handlers so the first Destroy has a non-empty table to clear; this
    -- gives the "not re-applied or corrupted" clause something observable.
    c:Register("A", noop)
    c:Register("B", noop)
    c:Destroy()
    local hideAfterFirst = #fr.calls.Hide
    local unregAllAfterFirst = #fr.calls.UnregisterAllEvents
    -- State established by the first (successful) teardown, before the refusal.
    T.eq(c._destroyed, true, "destroyed flag set after first Destroy")
    T.eq(next(c._handlers), nil, "handler table cleared by first Destroy")

    T.raises(function() c:Destroy() end, "double destroy", "Events:Destroy called on a destroyed controller")

    -- Headline: no second native teardown was issued.
    T.eq(#fr.calls.Hide, hideAfterFirst, "Hide not called a second time")
    T.eq(#fr.calls.UnregisterAllEvents, unregAllAfterFirst, "UnregisterAllEvents not called again")

    -- Matrix MUST sub-clause "the first Destroy's effects are not re-applied or
    -- corrupted": the refused second call short-circuits before any mutation, so
    -- the cleared handler table and the destroyed flag must be exactly as the
    -- first teardown left them.
    T.eq(c._destroyed, true, "destroyed flag unchanged by the refused second Destroy")
    T.eq(next(c._handlers), nil, "handler table still empty after the refused second Destroy")
    -- The native OnEvent script stays detached; the refusal did not re-touch it.
    T.eq(fr._onEvent, nil, "OnEvent stays detached after the refused second Destroy")
    T.truthy(not fr:IsShown(), "frame stays hidden after the refused second Destroy")
end)

-- destroy-independence
test("destroying one controller leaves the other fully functional", function()
    local F = T.fresh()
    local a = F.Events:New("A")
    local b = F.Events:New("B")
    local fb = T.frames[2]
    local bHits = 0
    b:Register("E", function() bHits = bHits + 1 end)
    a:Destroy()
    -- B still works in every way.
    T.truthy(b:IsRegistered("E"), "B:IsRegistered works")
    T.Fire(fb, "E")
    T.eq(bHits, 1, "B dispatch works")
    local ok = pcall(function() b:Register("F", noop) end)
    T.truthy(ok, "B:Register works after A destroyed")
    T.truthy(b:IsRegistered("F"), "B's new registration present")
end)

-- release-destroyed-refuses
test("release build: a method after Destroy refuses without working", function()
    local F = T.fresh("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    local c = F.Events:New("A")
    local fr = T.frames[1]
    c:Destroy()
    local regCountBefore = #fr.calls.RegisterEvent
    local ok = pcall(function() c:Register("E", noop) end)
    T.truthy(ok, "no raise in release after destroy")
    T.outputContains("destroyed controller", "diagnostic printed")
    T.eq(#fr.calls.RegisterEvent, regCountBefore, "no RegisterEvent recorded after destroy")
    -- GetNativeHandles after destroy returns nil (guard early-returns).
    local handles
    local okG = pcall(function() handles = c:GetNativeHandles() end)
    T.truthy(okG, "no raise")
    T.eq(handles, nil, "GetNativeHandles returns nil after destroy in release")
end)

-- release-destroyed-refuses-rest
-- Companion to release-destroyed-refuses (which covers :Register and
-- :GetNativeHandles) and the dev-raise mirror destroy-all-methods-fail-dev.
-- In a RELEASE build, on a destroyed controller, each remaining guarded method
-- must refuse without raising: it prints its own dev-error diagnostic and
-- mutates the native frame for none of them; IsRegistered and GetNativeHandles
-- additionally return nil (the guard early-returns past the boolean/snapshot).
-- The frame-count snapshot gives the "no mutation" clause teeth -- a method that
-- wrongly proceeded would grow one of the native buckets; the no-raise pcall +
-- outputContains catch a method that wrongly raised or stayed silent.
test("release build: the other six methods after Destroy refuse without working", function()
    local F = T.fresh("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    local c = F.Events:New("A")
    local fr = T.frames[1]
    c:Destroy()

    -- Native frame call counts immediately after the (legitimate) Destroy. Each
    -- refused method below must leave every one of these unchanged.
    local function counts()
        return {
            RegisterEvent = #fr.calls.RegisterEvent,
            RegisterUnitEvent = #fr.calls.RegisterUnitEvent,
            UnregisterEvent = #fr.calls.UnregisterEvent,
            UnregisterAllEvents = #fr.calls.UnregisterAllEvents,
            SetScript = #fr.calls.SetScript,
            Hide = #fr.calls.Hide,
            Show = #fr.calls.Show,
        }
    end
    local function assertFrameUntouched(before, label)
        local after = counts()
        for k, v in pairs(before) do
            T.eq(after[k], v, "frame." .. k .. " untouched (" .. label .. ")")
        end
    end

    -- Each entry: method label, the call that should refuse, and the per-method
    -- diagnostic substring the release build is required to print.
    local function refuses(label, call, expectMsg)
        T.output = {}  -- isolate this method's diagnostic
        local before = counts()
        local ok = pcall(call)
        T.truthy(ok, label .. ": no raise in release after destroy")
        T.outputContains(expectMsg, label .. ": diagnostic printed")
        assertFrameUntouched(before, label)
    end

    refuses("RegisterUnit", function() c:RegisterUnit("E", noop, "player") end,
        "Events:RegisterUnit called on a destroyed controller")
    refuses("RegisterOnce", function() c:RegisterOnce("E", noop) end,
        "Events:RegisterOnce called on a destroyed controller")
    refuses("Unregister", function() c:Unregister("E") end,
        "Events:Unregister called on a destroyed controller")
    refuses("UnregisterAll", function() c:UnregisterAll() end,
        "Events:UnregisterAll called on a destroyed controller")
    refuses("Destroy", function() c:Destroy() end,
        "Events:Destroy called on a destroyed controller")

    -- IsRegistered: refuses, prints, and returns nil (not a boolean).
    do
        T.output = {}
        local before = counts()
        local res, captured
        local ok = pcall(function() captured = c:IsRegistered("E"); res = true end)
        T.truthy(ok, "IsRegistered: no raise in release after destroy")
        T.truthy(res, "IsRegistered: returned normally")
        T.outputContains("Events:IsRegistered called on a destroyed controller",
            "IsRegistered: diagnostic printed")
        T.eq(captured, nil, "IsRegistered returns nil after destroy in release")
        assertFrameUntouched(before, "IsRegistered")
    end

    -- GetNativeHandles: refuses, prints, and returns nil.
    do
        T.output = {}
        local before = counts()
        local handles, ran
        local ok = pcall(function() handles = c:GetNativeHandles(); ran = true end)
        T.truthy(ok, "GetNativeHandles: no raise in release after destroy")
        T.truthy(ran, "GetNativeHandles: returned normally")
        T.outputContains("Events:GetNativeHandles called on a destroyed controller",
            "GetNativeHandles: diagnostic printed")
        T.eq(handles, nil, "GetNativeHandles returns nil after destroy in release")
        assertFrameUntouched(before, "GetNativeHandles")
    end
end)

return tests

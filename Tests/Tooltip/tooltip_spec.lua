-- Foundry.Tooltip behavior tests. Loaded by Tests/run.lua, which passes the
-- harness table T. Returns a list of { name, fn } cases covering the v1 public
-- contract: feature detection (Retail-only), atomic :New validation, handler
-- dispatch, tooltip whitelist filter, :Destroy disable-in-place, :GetNativeHandles,
-- duplicate-key refusal, line emitters, and version pins.
--
-- Stub design: installTDP / installNoTDP write (or clear) _G.TooltipDataProcessor
-- after T.fresh(). The stub captures registered callbacks so tests can fire them
-- deterministically via fire(state, n, tooltip, data). makeTooltip() builds a
-- minimal tooltip recorder (AddLine / AddDoubleLine) for line-emitter coverage.

local T = ...

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

--------------------------------------------------------------------------------
-- Per-test surface helpers
--------------------------------------------------------------------------------

-- A stub TooltipDataType number used as the "item" type throughout. Tests that
-- need a distinct second type use SPELL_TYPE. On the real client these are
-- Enum.TooltipDataType.Item / .Spell; the module validates only that type is a
-- number, never that it is a known enum member.
local ITEM_TYPE  = 1
local SPELL_TYPE = 2

-- Present flavor: full TooltipDataProcessor stub. Captures calls to
-- AddTooltipPostCall so tests can fire them via fire().
local function installTDP()
    local state = { postCalls = {} }
    _G.TooltipDataProcessor = {
        _state = state,
        AddTooltipPostCall = function(tooltipType, fn)
            state.postCalls[#state.postCalls + 1] = { type = tooltipType, fn = fn }
        end,
    }
    return state
end

-- Absent flavor: TooltipDataProcessor nil (Classic-family client simulation).
local function installNoTDP()
    _G.TooltipDataProcessor = nil
end

-- Fire the Nth registered post-call callback with (tooltip, data).
local function fire(state, n, tooltip, data)
    local entry = state.postCalls[n]
    if entry then entry.fn(tooltip, data) end
end

-- Stub tooltip frame: records AddLine calls so line-emitter tests can assert
-- text and color args without touching a real WoW tooltip.
local function makeTooltip()
    local t = { calls = {} }
    function t:AddLine(text, r, g, b)
        self.calls[#self.calls + 1] = { "AddLine", text, r, g, b }
    end
    function t:AddDoubleLine(l, r, lr, lg, lb, rr, rg, rb)
        self.calls[#self.calls + 1] = { "AddDoubleLine", l, r, lr, lg, lb, rr, rg, rb }
    end
    return t
end

-- Minimal valid config. Individual tests override fields via 'over'.
local function valid(over)
    local cfg = {
        type    = ITEM_TYPE,
        handler = function() end,
    }
    if over then
        for k, v in pairs(over) do cfg[k] = v end
    end
    return cfg
end

--------------------------------------------------------------------------------
-- Version pins
--------------------------------------------------------------------------------

test("version pins: Tooltip.API_VERSION == 1", function()
    local F = T.fresh()
    installTDP()
    T.eq(F.Tooltip.API_VERSION, 1, "Tooltip per-module API_VERSION == 1")
    T.eq(F:RequireModule("Tooltip", 1), F.Tooltip, "RequireModule min=1 returns the module")
    T.raises(function() F:RequireModule("Tooltip", 99) end, "RequireModule too-high", "version")
end)

test("library API_VERSION does not advance when Tooltip is loaded", function()
    local F = T.fresh()
    installTDP()
    T.eq(F.API_VERSION, 6, "library API_VERSION unchanged after Tooltip load")
end)

--------------------------------------------------------------------------------
-- Construction + method surface
--------------------------------------------------------------------------------

test("New returns a controller exposing GetNativeHandles and Destroy", function()
    local F = T.fresh()
    installTDP()
    local c = F.Tooltip:New(valid())
    T.truthy(c, "controller created")
    for _, m in ipairs({ "GetNativeHandles", "Destroy" }) do
        T.eq(type(c[m]), "function", "method " .. m .. " present")
    end
end)

test("New does not call CreateFrame (module creates no frames)", function()
    local F = T.fresh()
    installTDP()
    F.Tooltip:New(valid())
    T.eq(#T.frames, 0, "Tooltip:New never calls CreateFrame")
end)

test("controller carries _isTooltipController marker", function()
    local F = T.fresh()
    installTDP()
    local c = F.Tooltip:New(valid())
    T.truthy(c._isTooltipController, "_isTooltipController set on controller")
end)

--------------------------------------------------------------------------------
-- Feature detection: Retail-only
--------------------------------------------------------------------------------

test("New: raises when TooltipDataProcessor is absent (Classic-family client)", function()
    local F = T.fresh()
    installNoTDP()
    T.raises(function() F.Tooltip:New(valid()) end,
        "no TDP", "TooltipDataProcessor is not available")
end)

test("New: raises when TooltipDataProcessor exists but AddTooltipPostCall is missing", function()
    local F = T.fresh()
    _G.TooltipDataProcessor = {}  -- table but missing AddTooltipPostCall
    T.raises(function() F.Tooltip:New(valid()) end,
        "partial TDP", "TooltipDataProcessor is not available")
end)

--------------------------------------------------------------------------------
-- Registration: AddTooltipPostCall called correctly
--------------------------------------------------------------------------------

test("New: AddTooltipPostCall called once with the correct type", function()
    local F = T.fresh()
    local state = installTDP()
    F.Tooltip:New(valid())
    T.eq(#state.postCalls, 1, "AddTooltipPostCall called once")
    T.eq(state.postCalls[1].type, ITEM_TYPE, "registered type matches config.type")
end)

test("New: two controllers for different types each register independently", function()
    local F = T.fresh()
    local state = installTDP()
    F.Tooltip:New(valid({ type = ITEM_TYPE,  name = "a" }))
    F.Tooltip:New(valid({ type = SPELL_TYPE, name = "b" }))
    T.eq(#state.postCalls, 2, "two AddTooltipPostCall registrations")
    T.eq(state.postCalls[1].type, ITEM_TYPE,  "first registration is ITEM_TYPE")
    T.eq(state.postCalls[2].type, SPELL_TYPE, "second registration is SPELL_TYPE")
end)

--------------------------------------------------------------------------------
-- Atomic :New validation (a rejected :New registers nothing)
--------------------------------------------------------------------------------

test("New: non-table config refused", function()
    local F = T.fresh()
    local state = installTDP()
    T.raises(function() F.Tooltip:New("nope") end, "non-table config", "config must be a table")
    T.eq(#state.postCalls, 0, "no registration on bad config")
end)

test("New: nil type refused", function()
    local F = T.fresh()
    local state = installTDP()
    local cfg = valid(); cfg.type = nil
    T.raises(function() F.Tooltip:New(cfg) end, "nil type", "config.type must be a number")
    T.eq(#state.postCalls, 0, "no registration on nil type")
end)

test("New: string type refused", function()
    local F = T.fresh()
    installTDP()
    T.raises(function() F.Tooltip:New(valid({ type = "Item" })) end,
        "string type", "config.type must be a number")
end)

test("New: nil handler refused", function()
    local F = T.fresh()
    local state = installTDP()
    local cfg = valid(); cfg.handler = nil
    T.raises(function() F.Tooltip:New(cfg) end, "nil handler", "config.handler must be a function")
    T.eq(#state.postCalls, 0, "no registration on nil handler")
end)

test("New: non-function handler refused", function()
    local F = T.fresh()
    installTDP()
    T.raises(function() F.Tooltip:New(valid({ handler = "notfn" })) end,
        "string handler", "config.handler must be a function")
end)

test("New: non-table tooltips refused", function()
    local F = T.fresh()
    local state = installTDP()
    T.raises(function() F.Tooltip:New(valid({ tooltips = "bad" })) end,
        "string tooltips", "config.tooltips must be an array")
    T.eq(#state.postCalls, 0, "no registration on bad tooltips")
end)

test("New: non-table entry inside tooltips array refused", function()
    local F = T.fresh()
    local state = installTDP()
    T.raises(function() F.Tooltip:New(valid({ tooltips = { makeTooltip(), "bad" } })) end,
        "mixed tooltips", "must be a tooltip frame")
    T.eq(#state.postCalls, 0, "no registration when any entry is invalid")
end)

test("New: empty string name refused when explicitly supplied", function()
    local F = T.fresh()
    installTDP()
    T.raises(function() F.Tooltip:New(valid({ name = "" })) end,
        "empty name", "config.name must be a non-empty string when supplied")
end)

test("New: non-string name refused when explicitly supplied", function()
    local F = T.fresh()
    installTDP()
    T.raises(function() F.Tooltip:New(valid({ name = 7 })) end,
        "numeric name", "config.name must be a non-empty string when supplied")
end)

test("validation is ordered: type checked before handler", function()
    local F = T.fresh()
    installTDP()
    local cfg = valid({ type = "bad" })
    cfg.handler = nil  -- also bad; type error must surface first
    T.raises(function() F.Tooltip:New(cfg) end, "type-before-handler",
        "config.type must be a number")
end)

test("validation is ordered: handler checked before tooltips", function()
    local F = T.fresh()
    installTDP()
    local cfg = valid({ tooltips = "bad" })
    cfg.handler = "notfn"  -- also bad; handler error must surface first
    T.raises(function() F.Tooltip:New(cfg) end, "handler-before-tooltips",
        "config.handler must be a function")
end)

test("validation is ordered: tooltips checked before name", function()
    local F = T.fresh()
    installTDP()
    T.raises(function() F.Tooltip:New(valid({ tooltips = "bad", name = "" })) end,
        "tooltips-before-name", "config.tooltips must be an array")
end)

test("validation is ordered: name checked before feature-detect", function()
    -- name is bad (empty), TDP absent — name error must surface first.
    local F = T.fresh()
    installNoTDP()
    T.raises(function() F.Tooltip:New(valid({ name = "" })) end,
        "name-before-feature", "config.name must be a non-empty string when supplied")
end)

--------------------------------------------------------------------------------
-- Handler dispatch: no filter
--------------------------------------------------------------------------------

test("handler fires for every tooltip when no filter is configured", function()
    local F = T.fresh()
    local state = installTDP()
    local fired = 0
    F.Tooltip:New({ type = ITEM_TYPE, handler = function() fired = fired + 1 end })
    local tt1, tt2 = makeTooltip(), makeTooltip()
    fire(state, 1, tt1, {})
    fire(state, 1, tt2, {})
    T.eq(fired, 2, "handler fired twice (no filter)")
end)

test("handler receives tooltip and data args", function()
    local F = T.fresh()
    local state = installTDP()
    local got = {}
    F.Tooltip:New({ type = ITEM_TYPE, handler = function(tt, d) got.tt = tt; got.d = d end })
    local tt = makeTooltip()
    local data = { id = 42 }
    fire(state, 1, tt, data)
    T.eq(got.tt, tt,   "tooltip arg forwarded")
    T.eq(got.d,  data, "data arg forwarded")
end)

--------------------------------------------------------------------------------
-- Handler dispatch: tooltips whitelist filter
--------------------------------------------------------------------------------

test("handler fires only for listed tooltips when filter configured", function()
    local F = T.fresh()
    local state = installTDP()
    local fired = {}
    local tt1, tt2, tt3 = makeTooltip(), makeTooltip(), makeTooltip()
    F.Tooltip:New({
        type     = ITEM_TYPE,
        handler  = function(tt) fired[#fired + 1] = tt end,
        tooltips = { tt1, tt2 },
    })
    fire(state, 1, tt1, {})  -- in filter → fires
    fire(state, 1, tt3, {})  -- not in filter → skipped
    fire(state, 1, tt2, {})  -- in filter → fires
    T.eq(#fired, 2,   "handler fired exactly twice")
    T.eq(fired[1], tt1, "first fire was tt1")
    T.eq(fired[2], tt2, "second fire was tt2")
end)

test("handler never fires when filter is an empty array", function()
    local F = T.fresh()
    local state = installTDP()
    local fired = 0
    F.Tooltip:New({ type = ITEM_TYPE, handler = function() fired = fired + 1 end, tooltips = {} })
    fire(state, 1, makeTooltip(), {})
    T.eq(fired, 0, "empty filter: handler never fires")
end)

--------------------------------------------------------------------------------
-- Duplicate-key refusal and liveKeys isolation
--------------------------------------------------------------------------------

test("name defaults to tostring(type); second :New with same default key refused", function()
    local F = T.fresh()
    installTDP()
    local c1 = F.Tooltip:New(valid())
    T.truthy(c1, "first registration with default name succeeds")
    T.raises(function() F.Tooltip:New(valid()) end,
        "duplicate default key", "a live controller already owns the name")
end)

test("explicit name= overrides default key; distinct names coexist", function()
    local F = T.fresh()
    installTDP()
    local c1 = F.Tooltip:New(valid({ type = ITEM_TYPE, name = "Homestead" }))
    T.truthy(c1, "first explicit name")
    -- Same type but different explicit name — no conflict.
    local c2 = F.Tooltip:New(valid({ type = ITEM_TYPE, name = "Sift" }))
    T.truthy(c2, "second explicit name coexists")
end)

test("duplicate explicit name refused", function()
    local F = T.fresh()
    installTDP()
    local c1 = F.Tooltip:New(valid({ name = "Homestead" }))
    T.truthy(c1, "first with explicit name")
    T.raises(function() F.Tooltip:New(valid({ name = "Homestead" })) end,
        "duplicate explicit name", "a live controller already owns the name")
end)

test("key freed on :Destroy; re-registration with same name succeeds", function()
    local F = T.fresh()
    installTDP()
    local c1 = F.Tooltip:New(valid({ name = "Homestead" }))
    T.truthy(c1, "first registration")
    c1:Destroy()
    local c2 = F.Tooltip:New(valid({ name = "Homestead" }))
    T.truthy(c2, "re-registration after :Destroy succeeds")
end)

--------------------------------------------------------------------------------
-- :Destroy
--------------------------------------------------------------------------------

test(":Destroy marks controller destroyed and frees the key", function()
    local F = T.fresh()
    installTDP()
    local c = F.Tooltip:New(valid({ name = "Homestead" }))
    T.falsy(c._destroyed, "not destroyed before :Destroy")
    c:Destroy()
    T.truthy(c._destroyed, "_destroyed set to true")
    -- Key freed: re-registration with same name must succeed.
    local c2 = F.Tooltip:New(valid({ name = "Homestead" }))
    T.truthy(c2, "re-registration after :Destroy succeeds")
end)

test(":Destroy releases handler, name, and filter references", function()
    local F = T.fresh()
    installTDP()
    local c = F.Tooltip:New(valid({ tooltips = { makeTooltip() } }))
    c:Destroy()
    T.eq(c._handler, nil, "_handler released")
    T.eq(c._name,    nil, "_name released")
    T.eq(c._filter,  nil, "_filter released")
end)

test(":Destroy is idempotent (second :Destroy is a silent no-op)", function()
    local F = T.fresh()
    installTDP()
    local c = F.Tooltip:New(valid())
    c:Destroy()
    local ok, err = pcall(function() c:Destroy() end)
    T.truthy(ok, "second :Destroy is a no-op (got: " .. tostring(err) .. ")")
end)

test("handler becomes a no-op after :Destroy (callback disabled in-place)", function()
    local F = T.fresh()
    local state = installTDP()
    local fired = 0
    local c = F.Tooltip:New({ type = ITEM_TYPE, handler = function() fired = fired + 1 end })
    c:Destroy()
    fire(state, 1, makeTooltip(), {})
    T.eq(fired, 0, "handler not called after :Destroy")
end)

test(":GetNativeHandles on destroyed controller raises", function()
    local F = T.fresh()
    installTDP()
    local c = F.Tooltip:New(valid())
    c:Destroy()
    T.raises(function() c:GetNativeHandles() end,
        "getNativeHandles after destroy", "Tooltip:GetNativeHandles called on a destroyed controller")
end)

--------------------------------------------------------------------------------
-- :GetNativeHandles
--------------------------------------------------------------------------------

test(":GetNativeHandles returns correct keys", function()
    local F = T.fresh()
    installTDP()
    local c = F.Tooltip:New(valid({ type = ITEM_TYPE }))
    local h = c:GetNativeHandles()
    T.eq(h.type,                 ITEM_TYPE,              "type key matches config.type")
    T.eq(h.tooltipDataProcessor, _G.TooltipDataProcessor, "tooltipDataProcessor is the global")
end)

test(":GetNativeHandles returns a fresh table per call", function()
    local F = T.fresh()
    installTDP()
    local c = F.Tooltip:New(valid())
    local h1 = c:GetNativeHandles()
    local h2 = c:GetNativeHandles()
    T.truthy(h1 ~= h2, "fresh table per call")
end)

test(":GetNativeHandles mutation does not corrupt controller state", function()
    local F = T.fresh()
    local state = installTDP()
    local fired = 0
    local c = F.Tooltip:New({ type = ITEM_TYPE, handler = function() fired = fired + 1 end })
    -- Clobber the returned handle; handler must still fire.
    local h = c:GetNativeHandles()
    h.type = 999
    h.tooltipDataProcessor = nil
    fire(state, 1, makeTooltip(), {})
    T.eq(fired, 1, "handler still fires after handle mutation")
end)

--------------------------------------------------------------------------------
-- Line emitters (module-level helpers)
--------------------------------------------------------------------------------

test("AddLine: calls tooltip:AddLine forwarding text and r,g,b", function()
    local F = T.fresh()
    installTDP()
    local tt = makeTooltip()
    F.Tooltip.AddLine(tt, "Hello", 1, 0.5, 0)
    T.eq(#tt.calls, 1,          "one AddLine call")
    T.eq(tt.calls[1][1], "AddLine", "AddLine method called")
    T.eq(tt.calls[1][2], "Hello",   "text forwarded")
    T.eq(tt.calls[1][3], 1,         "r forwarded")
    T.eq(tt.calls[1][4], 0.5,       "g forwarded")
    T.eq(tt.calls[1][5], 0,         "b forwarded")
end)

test("AddLine: r, g, b default to 1, 1, 1 when omitted", function()
    local F = T.fresh()
    installTDP()
    local tt = makeTooltip()
    F.Tooltip.AddLine(tt, "White text")
    T.eq(tt.calls[1][3], 1, "r defaults to 1")
    T.eq(tt.calls[1][4], 1, "g defaults to 1")
    T.eq(tt.calls[1][5], 1, "b defaults to 1")
end)

test("AddSeparator: calls tooltip:AddLine with a blank string", function()
    local F = T.fresh()
    installTDP()
    local tt = makeTooltip()
    F.Tooltip.AddSeparator(tt)
    T.eq(#tt.calls, 1,          "one AddLine call")
    T.eq(tt.calls[1][1], "AddLine", "AddLine method called")
    T.eq(tt.calls[1][2], " ",       "blank string passed")
end)

test("AddLine and AddSeparator are module-level (not on controller)", function()
    local F = T.fresh()
    installTDP()
    T.eq(type(F.Tooltip.AddLine),      "function", "AddLine is on F.Tooltip")
    T.eq(type(F.Tooltip.AddSeparator), "function", "AddSeparator is on F.Tooltip")
    local c = F.Tooltip:New(valid())
    T.eq(c.AddLine,      nil, "AddLine not on controller")
    T.eq(c.AddSeparator, nil, "AddSeparator not on controller")
end)

--------------------------------------------------------------------------------
-- Release-axis behavior
--------------------------------------------------------------------------------

test("release build: a validation error prints and returns nil, does not raise", function()
    local F = T.fresh("1.0.0")
    installTDP()
    local cfg = valid(); cfg.type = nil
    local c = F.Tooltip:New(cfg)
    T.eq(c, nil, "release :New returns nil on bad config")
    T.outputContains("config.type must be a number", "release printed the diagnostic")
end)

test("release build: absent TDP prints and returns nil, does not raise", function()
    local F = T.fresh("1.0.0")
    installNoTDP()
    local c = F.Tooltip:New(valid())
    T.eq(c, nil, "release :New returns nil when TDP absent")
    T.outputContains("TooltipDataProcessor is not available", "release printed the diagnostic")
end)

return tests

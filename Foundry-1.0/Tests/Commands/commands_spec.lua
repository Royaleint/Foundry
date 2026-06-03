-- Foundry.Commands behavior tests. Loaded by Tests/run.lua, which passes the
-- harness table T. Returns a list of { name, fn } cases covering the public
-- contract plus edge cases (alias atomicity, post-Destroy inertness,
-- literal-space boundary, alias sort order, release-build refusal).

local T = ...

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

-- 1
test("New returns a controller exposing the public methods", function()
    local F = T.fresh()
    local c = F.Commands:New({ name = "TestAddon", slashes = { "/ta" } })
    T.truthy(c, "controller created")
    for _, m in ipairs({ "Register", "Unregister", "Dispatch", "PrintHelp", "GetNativeHandles", "Destroy" }) do
        T.eq(type(c[m]), "function", "method " .. m)
    end
end)

-- 2
test("New twice with different names yields independent controllers", function()
    local F = T.fresh()
    local a = F.Commands:New({ name = "AddonA", slashes = { "/a" } })
    local b = F.Commands:New({ name = "AddonB", slashes = { "/b" } })
    local hitA = false
    a:Register({ name = "go", handler = function() hitA = true end })
    b:Dispatch("go")
    T.falsy(hitA, "A handler not triggered by B dispatch")
    T.outputContains("Unknown command: go", "B reports unknown")
end)

-- 3
test("Register adds, Unregister removes, re-register works", function()
    local F = T.fresh()
    local c = F.Commands:New({ name = "T", slashes = { "/t" } })
    local hits = 0
    c:Register({ name = "go", handler = function() hits = hits + 1 end })
    c:Dispatch("go"); T.eq(hits, 1, "after register")
    c:Unregister("go")
    c:Dispatch("go"); T.eq(hits, 1, "no hit after unregister")
    c:Register({ name = "go", handler = function() hits = hits + 1 end })
    c:Dispatch("go"); T.eq(hits, 2, "re-register works")
end)

-- 4
test("Register name 'help' fails loudly in dev build", function()
    local F = T.fresh()
    local c = F.Commands:New({ name = "T", slashes = { "/t" } })
    T.raises(function() c:Register({ name = "help", handler = function() end }) end,
        "reserved help", "reserved")
end)

-- 5
test("New with a pre-existing SLASH_<NAME>N global fails loudly in dev build", function()
    local F = T.fresh()
    _G.SLASH_DUP1 = "/dup"  -- simulate another addon owning this global
    T.raises(function() F.Commands:New({ name = "dup", slashes = { "/dup" } }) end,
        "slash collision")
end)

-- 6
test("bare slash with no defaultHandler calls help", function()
    local F = T.fresh()
    local c = F.Commands:New({ name = "T", slashes = { "/t" }, description = "Test addon." })
    c:Register({ name = "go", help = "Do it.", handler = function() end })
    c:Dispatch("")
    T.outputContains("Test addon.", "description printed")
    T.outputContains("/t go", "subcommand listed")
end)

-- 7
test("bare slash with a defaultHandler calls the handler, not help", function()
    local F = T.fresh()
    local hit = false
    local c = F.Commands:New({ name = "T", slashes = { "/t" }, description = "Test.",
        defaultHandler = function() hit = true end })
    c:Register({ name = "go", help = "Do it.", handler = function() end })
    c:Dispatch("")
    T.truthy(hit, "defaultHandler called")
    local sawDesc = false
    for _, l in ipairs(T.output) do if l:find("Test.", 1, true) then sawDesc = true end end
    T.falsy(sawDesc, "help not printed")
end)

-- 8
test("'help' calls help even with a defaultHandler set", function()
    local F = T.fresh()
    local hit = false
    local c = F.Commands:New({ name = "T", slashes = { "/t" }, description = "DescX",
        defaultHandler = function() hit = true end })
    c:Dispatch("help")
    T.falsy(hit, "defaultHandler not called for help")
    T.outputContains("DescX", "help printed")
end)

-- 9
test("'help foo' (trailing text) still calls help, not unknown", function()
    local F = T.fresh()
    local c = F.Commands:New({ name = "T", slashes = { "/t" }, description = "DescY" })
    c:Dispatch("help foo")
    T.outputContains("DescY", "help printed")
end)

-- 10
test("known subcommand routes to its handler with the remainder (casing preserved)", function()
    local F = T.fresh()
    local got
    local c = F.Commands:New({ name = "T", slashes = { "/t" } })
    c:Register({ name = "echo", handler = function(rest) got = rest end })
    c:Dispatch("echo Hello World")
    T.eq(got, "Hello World", "remainder preserves original case")
end)

-- 11
test("multi-word name wins over the shorter prefix (longest-prefix)", function()
    local F = T.fresh()
    local hit
    local c = F.Commands:New({ name = "T", slashes = { "/t" } })
    c:Register({ name = "debug", handler = function() hit = "debug" end })
    c:Register({ name = "debug vertical", handler = function() hit = "vertical" end })
    c:Dispatch("debug vertical"); T.eq(hit, "vertical", "longest prefix wins")
    hit = nil
    c:Dispatch("debug"); T.eq(hit, "debug", "bare debug")
end)

-- 12
test("shorter prefix with extra input routes to shorter with the remainder", function()
    local F = T.fresh()
    local got
    local c = F.Commands:New({ name = "T", slashes = { "/t" } })
    c:Register({ name = "debug", handler = function(rest) got = rest end })
    c:Dispatch("debug something else")
    T.eq(got, "something else", "remainder")
end)

-- 13
test("'debugvertical' does not match 'debug' (word boundary required)", function()
    local F = T.fresh()
    local hit = false
    local c = F.Commands:New({ name = "T", slashes = { "/t" } })
    c:Register({ name = "debug", handler = function() hit = true end })
    c:Dispatch("debugvertical")
    T.falsy(hit, "no match")
    T.outputContains("Unknown command: debugvertical", "unknown")
end)

-- 14
test("unknown subcommand prints only the error, not the command list", function()
    local F = T.fresh()
    local c = F.Commands:New({ name = "T", slashes = { "/t" }, description = "D" })
    c:Register({ name = "go", help = "g", handler = function() end })
    c:Dispatch("nope")
    T.outputContains("Unknown command: nope")
    local sawList = false
    for _, l in ipairs(T.output) do if l:find("/t go", 1, true) then sawList = true end end
    T.falsy(sawList, "auto-help command list not printed on unknown")
end)

-- 15
test("aliases route to the same handler as the primary name", function()
    local F = T.fresh()
    local hits = 0
    local c = F.Commands:New({ name = "T", slashes = { "/t" } })
    c:Register({ name = "waypoint", aliases = { "wp" }, handler = function() hits = hits + 1 end })
    c:Dispatch("waypoint"); c:Dispatch("wp")
    T.eq(hits, 2, "both route to the handler")
end)

-- 16
test("guard returning false blocks every dispatch path silently", function()
    local F = T.fresh()
    local hit = false
    local c = F.Commands:New({ name = "T", slashes = { "/t" },
        defaultHandler = function() hit = true end,
        guard = function() return false end })
    c:Register({ name = "go", handler = function() hit = true end })
    c:Dispatch("");     T.falsy(hit, "bare blocked")
    c:Dispatch("help"); T.falsy(hit, "help blocked")
    c:Dispatch("go");   T.falsy(hit, "known blocked")
    c:Dispatch("nope"); T.falsy(hit, "unknown blocked")
    T.eq(#T.output, 0, "no output when guard denies without a reason")
end)

-- 17
test("guard false with a reason prints the reason", function()
    local F = T.fresh()
    local c = F.Commands:New({ name = "T", slashes = { "/t" },
        guard = function() return false, "Nope, denied." end })
    c:Dispatch("go")
    T.outputContains("Nope, denied.", "reason printed")
end)

-- 18
test("guard returning true passes through to normal dispatch", function()
    local F = T.fresh()
    local hit = false
    local c = F.Commands:New({ name = "T", slashes = { "/t" }, guard = function() return true end })
    c:Register({ name = "go", handler = function() hit = true end })
    c:Dispatch("go")
    T.truthy(hit, "passes through")
end)

-- 19
test("GetNativeHandles returns the contracted single-table shape", function()
    local F = T.fresh()
    local c = F.Commands:New({ name = "MyAddon", slashes = { "/ma", "/myaddon" } })
    local h = c:GetNativeHandles()
    T.eq(h.slashListKey, "MYADDON", "key")
    T.eq(type(h.slashGlobals), "table", "globals array")
    T.eq(h.slashGlobals[1], "SLASH_MYADDON1", "first global")
    T.eq(h.slashGlobals[2], "SLASH_MYADDON2", "second global")
    T.eq(type(h.handler), "function", "handler is a function")
end)

-- 20
test("Destroy clears the SlashCmdList entry and SLASH_ globals", function()
    local F = T.fresh()
    local c = F.Commands:New({ name = "MyAddon", slashes = { "/ma" } })
    T.truthy(_G.SlashCmdList["MYADDON"], "registered before destroy")
    T.eq(_G.SLASH_MYADDON1, "/ma", "global before destroy")
    c:Destroy()
    T.eq(_G.SlashCmdList["MYADDON"], nil, "SlashCmdList cleared")
    T.eq(_G.SLASH_MYADDON1, nil, "SLASH_ global cleared")
end)

-- 21
test("after Destroy, Dispatch runs no code path", function()
    local F = T.fresh()
    local hit = false
    local c = F.Commands:New({ name = "T", slashes = { "/t" },
        defaultHandler = function() hit = true end })
    c:Destroy()
    c:Dispatch("")
    T.falsy(hit, "defaultHandler not called post-destroy")
    T.eq(#T.output, 0, "no output post-destroy")
end)

-- 22
test("auto-help: description, blank line, sort, alias, args, multi-word", function()
    local F = T.fresh()
    local c = F.Commands:New({ name = "T", slashes = { "/t" }, description = "My addon." })
    c:Register({ name = "zoom", handler = function() end })
    c:Register({ name = "apple", args = "[n]", help = "Eat.", aliases = { "a" }, handler = function() end })
    c:Register({ name = "debug vertical", handler = function() end })
    c:PrintHelp()
    T.eq(T.output[1], "My addon.", "description first")
    T.eq(T.output[2], "", "blank line")
    T.eq(T.output[3], "/t apple (a) [n]  -- Eat.", "apple line")
    T.eq(T.output[4], "/t debug vertical", "multi-word line in sorted position")
    T.eq(T.output[5], "/t zoom", "zoom line")
end)

-- 23
test("Register is atomic: a bad alias leaves the primary unregistered", function()
    local F = T.fresh()
    local c = F.Commands:New({ name = "T", slashes = { "/t" } })
    T.raises(function()
        c:Register({ name = "foo", aliases = { "ok", "help" }, handler = function() end })
    end, "bad alias raises")
    c:Dispatch("foo")
    T.outputContains("Unknown command: foo", "primary not registered (atomic)")
end)

-- 24
test("slash strings are validated (whitespace, bare, embedded slash)", function()
    local F = T.fresh()
    T.raises(function() F.Commands:New({ name = "A", slashes = { "/my addon" } }) end, "internal space")
    F = T.fresh()
    T.raises(function() F.Commands:New({ name = "B", slashes = { "/" } }) end, "bare slash")
    F = T.fresh()
    T.raises(function() F.Commands:New({ name = "C", slashes = { "a/b" } }) end, "embedded slash")
    F = T.fresh()
    T.truthy(F.Commands:New({ name = "D", slashes = { "hs" } }), "'hs' accepted")
end)

-- 25
test("subcommand names with surrounding or whitespace-only content are rejected", function()
    local F = T.fresh()
    local c = F.Commands:New({ name = "T", slashes = { "/t" } })
    T.raises(function() c:Register({ name = " foo", handler = function() end }) end, "leading ws")
    T.raises(function() c:Register({ name = "foo ", handler = function() end }) end, "trailing ws")
    T.raises(function() c:Register({ name = "   ", handler = function() end }) end, "whitespace only")
end)

-- 26
test("non-string aliases are rejected, not coerced", function()
    local F = T.fresh()
    local c = F.Commands:New({ name = "T", slashes = { "/t" } })
    T.raises(function() c:Register({ name = "foo", aliases = { 123 }, handler = function() end }) end,
        "non-string alias")
end)

-- 27
test("release build refuses (prints) instead of raising", function()
    local F = T.fresh("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    local c = F.Commands:New({ name = "T", slashes = { "/t" } })
    local ok = pcall(function() c:Register({ name = "help", handler = function() end }) end)
    T.truthy(ok, "no raise in release build")
    T.outputContains("reserved", "diagnostic printed in release")
end)

-- 28
test("aliases render sorted in help output", function()
    local F = T.fresh()
    local c = F.Commands:New({ name = "T", slashes = { "/t" } })
    c:Register({ name = "go", aliases = { "z", "a" }, handler = function() end })
    c:PrintHelp()
    local goLine
    for _, l in ipairs(T.output) do if l:find("/t go", 1, true) then goLine = l end end
    T.truthy(goLine, "go line present")
    T.truthy(goLine:find("(a, z)", 1, true),
        "aliases sorted as (a, z), got: " .. tostring(goLine))
end)

-- 29
test("bootstrap dev/release detection and the override global", function()
    T.installMocks("@project-version@"); local F1 = T.loadFoundry()
    T.truthy(F1.IS_DEV_BUILD, "literal token -> dev")
    T.eq(F1.VERSION, "dev", "dev placeholder version")
    T.installMocks("2.3.4"); local F2 = T.loadFoundry()
    T.falsy(F2.IS_DEV_BUILD, "real version -> release")
    T.eq(F2.VERSION, "2.3.4", "release version string")
    T.eq(F2.API_VERSION, 3, "API_VERSION")
    T.installMocks("2.3.4"); _G.FOUNDRY_DEV_BUILD_OVERRIDE = true; local F3 = T.loadFoundry()
    T.truthy(F3.IS_DEV_BUILD, "override forces dev even on a real version")
end)

-- 30
test("HasModule / RequireModule behavior", function()
    local F = T.fresh()
    T.truthy(F:HasModule("Commands"), "has Commands")
    T.falsy(F:HasModule("Nope"), "does not have Nope")
    T.eq(F:RequireModule("Commands"), F.Commands, "RequireModule returns the module")
    T.raises(function() F:RequireModule("Nope") end, "missing module raises in both builds")
    T.raises(function() F:RequireModule("Commands", 99) end, "below-min API raises")
end)

-- 31
test("a 'help '-prefixed name fails loudly (would be unreachable)", function()
    local F = T.fresh()
    local c = F.Commands:New({ name = "T", slashes = { "/t" } })
    T.raises(function() c:Register({ name = "help vertical", handler = function() end }) end,
        "help-prefixed name reserved", "reserved")
    local ok = pcall(function() c:Register({ name = "helpful", handler = function() end }) end)
    T.truthy(ok, "'helpful' is allowed (not help-prefixed at a word boundary)")
end)

-- 32
test("a 'help '-prefixed alias fails loudly", function()
    local F = T.fresh()
    local c = F.Commands:New({ name = "T", slashes = { "/t" } })
    T.raises(function()
        c:Register({ name = "go", aliases = { "help me" }, handler = function() end })
    end, "help-prefixed alias reserved", "reserved")
end)

-- 33
test("registering a duplicate primary name fails loudly", function()
    local F = T.fresh()
    local c = F.Commands:New({ name = "T", slashes = { "/t" } })
    c:Register({ name = "go", handler = function() end })
    T.raises(function() c:Register({ name = "go", handler = function() end }) end,
        "duplicate primary", "already registered")
end)

-- 34
test("help as a function is called and its return renders in auto-help", function()
    local F = T.fresh()
    local c = F.Commands:New({ name = "T", slashes = { "/t" } })
    local calls = 0
    c:Register({ name = "scan",
        help = function() calls = calls + 1; return "Localized help." end,
        handler = function() end })
    c:PrintHelp()
    T.truthy(calls >= 1, "help function called")
    T.outputContains("-- Localized help.", "function help rendered")
end)

-- 35
test("RequireModule raises in a release build too", function()
    local F = T.fresh("1.0.0")
    T.falsy(F.IS_DEV_BUILD, "release build")
    T.raises(function() F:RequireModule("Nope") end, "missing module raises in release")
end)

-- 36
test("unknownMessage as a function localizes the unknown-command text", function()
    local F = T.fresh()
    local c = F.Commands:New({ name = "T", slashes = { "/t" },
        unknownMessage = function(input) return "Befehl unbekannt: " .. input end })
    c:Dispatch("nope")
    T.outputContains("Befehl unbekannt: nope", "localized message rendered")
    local sawEnglish = false
    for _, l in ipairs(T.output) do if l:find("Unknown command:", 1, true) then sawEnglish = true end end
    T.falsy(sawEnglish, "English default not used when overridden")
end)

-- 37
test("unknownMessage as a string overrides the unknown-command text", function()
    local F = T.fresh()
    local c = F.Commands:New({ name = "T", slashes = { "/t" }, unknownMessage = "Type /t help." })
    c:Dispatch("nope")
    T.outputContains("Type /t help.", "string message rendered")
    local sawDefault = false
    for _, l in ipairs(T.output) do if l:find("Unknown command:", 1, true) then sawDefault = true end end
    T.falsy(sawDefault, "English default not used when overridden")
end)

-- 38
test("unknownMessage must be a string or a function", function()
    local F = T.fresh()
    T.raises(function() F.Commands:New({ name = "T", slashes = { "/t" }, unknownMessage = 123 }) end,
        "bad unknownMessage type", "unknownMessage")
end)

-- 39
test("printer and unknownMessage compose: custom message via custom printer", function()
    local F = T.fresh()
    local captured = {}
    local c = F.Commands:New({ name = "T", slashes = { "/t" },
        printer = function(line) captured[#captured + 1] = "[X] " .. line end,
        unknownMessage = function(input) return "nope: " .. input end })
    c:Dispatch("zzz")
    local found = false
    for _, l in ipairs(captured) do if l:find("[X] nope: zzz", 1, true) then found = true end end
    T.truthy(found, "custom message emitted through custom printer (got: "
        .. table.concat(captured, " | ") .. ")")
end)

return tests

# Foundry

A small Blizzard-first library for WoW addon authors who want to build on Blizzard's modern toolkit: the Settings API, the new menu system, ScrollBox, tooltip hooks, and the rest. An alternative to Ace3 for authors who want one.

By BawrLabs.

## What it is

Foundry exists to give addon authors a focused, modular toolkit built on Blizzard's modern API surface.

Foundry is:

- **Bridges where bridges are missing.** Foundry covers modern Blizzard APIs that don't have actively maintained community wrappers (the new menu system, modern tooltip hooks, ScrollBox).
- **Less boilerplate, never less control.** Each module collapses a verbose native pattern into a few readable lines — and `:GetNativeHandles()` always hands back the raw Blizzard objects, so you trade typing, not control.
- **Adopt incrementally.** Start with a single module, keep using Ace3 (or anything else) right alongside it, and add more as they ship — no all-or-nothing commitment.
- **Grows by demand.** Modules ship when a real addon actually needs them, proven against real use before they land — and you can propose the next one.

## Why

Foundry started as a refactor of my own addons (Homestead and BawrSpam) to use more of the in-game toolkit. Since that was happening anyway, making it available to other authors was a no-brainer. The goal isn't to replace Ace3 because it isn't going anywhere. It's just to offer a smaller option for authors who want one.

Ace3 is great, widely used, and still actively maintained. But it was designed against an earlier API surface than what's available today. Blizzard has shipped years of new addon APIs since: the Settings API, the new menu system, ScrollBox, modern tooltip hooks. Foundry is for authors who want a toolkit built on those newer APIs from the start.

## Modules

Foundry-1.0 delivers a focused set of modules covering what most addons reach for:

| Module | What it does | Blizzard surface | Ace3 equivalent | Status |
|---|---|---|---|---|
| **Commands** | Slash command registration with a per-consumer controller, auto-help, guard checks, and longest-prefix dispatch for multi-word names. | `SlashCmdList`, `SLASH_*` globals | AceConsole-3.0 | Available |
| **Events** | Owned event registration with automatic cleanup, scoped to the consuming addon. | `CreateFrame` event frames, `RegisterEvent` | AceEvent-3.0 | Available |
| **Lifecycle** | Honest hooks over the game's load and login signals, with a "saved settings ready" guarantee that fires when data is loaded and migrations have run. | `ADDON_LOADED`, `PLAYER_LOGIN`, `PLAYER_LOGOUT` | AceAddon-3.0 (lifecycle portion) | Available |
| **DB** | SavedVariables management with defaults, profiles, and per-character data. Reads existing AceDB save files unchanged. | `SavedVariables`, `SavedVariablesPerCharacter` | AceDB-3.0 | Available |
| **List** | Bridge over Blizzard's modern scrolling-list system, which is powerful but punishing to use directly. | `ScrollBox`, `ScrollBoxListView`, `DataProvider`, `ScrollUtil` | No direct Ace3 equivalent | Available |
| **Tooltip** | Bridge over Blizzard's modern tooltip-hook system. Current and supported, but under-documented for addon authors. | `TooltipDataProcessor` (added in Patch 10.0.2) | No direct Ace3 equivalent | Planned |
| **Menu** | Bridge over Blizzard's modern menu system, which replaced the deprecated `UIDropDownMenu` in Patch 11.0.0. | `Blizzard_Menu`, `MenuUtil` | LibUIDropDownMenu (community library, now unmaintained for current retail) | Planned |

The last three modules (List, Tooltip, Menu) exist to give authors an easy path away from older community UI libraries. Blizzard has shipped modern native equivalents, but the raw APIs are verbose enough that most authors stuck with the older libraries. Foundry's job here is to make the native path the easy path.

**Available now:** Commands, Events, Lifecycle, DB, and List. **Next up** are the two remaining UI bridges — **Menu** over Blizzard's 11.0 menu system (the successor to the now-unmaintained LibUIDropDownMenu) and **Tooltip** over TooltipDataProcessor.

## Using Foundry

In your addon's TOC:

```
## Dependencies: Foundry-1.0
```

In your Lua:

```lua
local F = _G.Foundry_1_0
if not F then
    error("MyAddon requires Foundry-1.0. Please install or enable it.")
end

local commands = F.Commands:New({
    name = "MyAddon",
    slashes = { "/myaddon", "/ma" },
    defaultHandler = function() MyAddon:OpenOptions() end,
})

commands:Register({
    name = "scan",
    help = "Scan the current zone.",
    handler = function(rest) MyAddon:Scan(rest) end,
})
```

Full API reference: [the Foundry wiki](https://github.com/Royaleint/Foundry/wiki).

## Adding new modules

Foundry's module set isn't fixed at the initial seven. If there's a Blizzard API you'd like to see bridged, here's how new modules get added.

**The path in:** open an issue describing the API you'd like Foundry to cover and how you'd use it in your addon. Concrete is better than abstract — "here's the code I'd write if Foundry had this module" lands faster than "Foundry should support X."

**What gets a yes:** modules that bridge a real Blizzard API where the raw surface is verbose or hard to discover, and where at least one author has a concrete use case ready to exercise it. The use case doesn't have to be your own — if you're proposing a module someone else needs, point to them and we'll work with them on it.

**What gets a "not yet":** modules without a clear consumer to validate them. Foundry's quality bar is tied to real-world use; designing in the abstract risks shipping API surface that doesn't survive contact with actual addons. We'd rather wait for a concrete use case than guess at one.

This isn't a high bar — it's the same bar the initial seven modules cleared. If you have an addon and an API you want bridged, that's enough.

## Installation

**Via CurseForge App** (recommended): Foundry installs automatically as a dependency when you install an addon that requires it. No action needed.

**Manual**: Download the latest release, extract `Foundry-1.0/` into your `Interface/AddOns/` directory.

## License

MIT. See [LICENSE](LICENSE).

## Contributing

Issues and discussion welcome. For larger changes, open an issue first to discuss the direction before opening a PR.

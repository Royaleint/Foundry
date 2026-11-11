# Foundry

Foundry is a modern addon library for WoW authors who want to build on Blizzard's current toolkit: the Settings API, the new menu system, ScrollBox, tooltip hooks, and the rest. It is an Ace3 alternative for authors who want one, and it works alongside Ace3 if you would rather adopt it a piece at a time.

By BawrLabs.

## What it is

Foundry exists to give addon authors a focused, modular toolkit built on Blizzard's modern API surface.

Foundry is:

- **Bridges where bridges are missing.** Foundry covers modern Blizzard APIs that don't have actively maintained community wrappers (the new menu system, modern tooltip hooks, ScrollBox).
- **Less boilerplate, never less control.** Each module collapses a verbose native pattern into a few readable lines, and `:GetNativeHandles()` always hands back the raw Blizzard objects, so you trade typing, not control.
- **Adopt incrementally.** Start with a single module, keep using Ace3 (or anything else) right alongside it, and add more as they ship, with no all-or-nothing commitment.
- **Grows by demand.** Modules ship when a real addon actually needs them, proven against real use before they land, and you can propose the next one.

## Why

Foundry started as a refactor of my own addons (Homestead and BawrSpam) to use more of the in-game toolkit. Since that was happening anyway, making it available to other authors was a no-brainer. The goal isn't to replace Ace3 because it isn't going anywhere. It's just to offer a smaller option for authors who want one.

Ace3 is great, widely used, and still actively maintained. But it was designed against an earlier API surface than what's available today. Blizzard has shipped years of new addon APIs since: the Settings API, the new menu system, ScrollBox, modern tooltip hooks. Foundry is for authors who want a toolkit built on those newer APIs from the start.

## Modules

Foundry-1.0 delivers a focused set of modules covering what most addons reach for:

| Module | What it does | Blizzard surface | Ace3 equivalent | Status |
|---|---|---|---|---|
| **Commands** | Slash command registration with a per-consumer controller, auto-help, guard checks, and longest-prefix dispatch for multi-word names. | `SlashCmdList`, `SLASH_*` globals | AceConsole-3.0 | Available |
| **Events** | Owned event registration with automatic cleanup, scoped to the consuming addon. | `CreateFrame` event frames, `RegisterEvent` | AceEvent-3.0 | Available |
| **Lifecycle** | Honest hooks over the game's load and login signals, including an optional pre-unload hook that distinguishes reload from closing the client. | `ADDON_LOADED`, `PLAYER_LOGIN`, `ADDONS_UNLOADING`, `PLAYER_LOGOUT` | AceAddon-3.0 (lifecycle portion) | Available |
| **DB** | SavedVariables management with defaults, profiles, and per-character data. Reads existing AceDB save files unchanged. | `SavedVariables`, `SavedVariablesPerCharacter` | AceDB-3.0 | Available |
| **List** | Bridge over Blizzard's modern scrolling-list system, which is powerful but punishing to use directly. | `ScrollBox`, `ScrollBoxListView`, `DataProvider`, `ScrollUtil` | No direct Ace3 equivalent | Available |
| **Settings** | Options panel registration through Blizzard's modern Settings API, plus a searchable launcher entry with one button that opens your addon's own options window. | `Settings.RegisterCanvasLayoutCategory`, `RegisterVerticalLayoutCategory`, `RegisterInitializer`, `RegisterAddOnCategory`; `CreateSettingsButtonInitializer` | AceConfig-3.0 / AceConfigDialog-3.0 | Available |
| **Tooltip** | Bridge over Blizzard's modern tooltip-hook system. Current and supported, but under-documented for addon authors. | `TooltipDataProcessor` (added in Patch 10.0.2) | No direct Ace3 equivalent | Available |
| **Menu** | Bridge over Blizzard's modern menu system, which replaced the deprecated `UIDropDownMenu` in Patch 11.0.0. | `Blizzard_Menu`, `MenuUtil` | LibUIDropDownMenu (community library, now unmaintained for current retail) | Available |
| **Window** | Draggable, position-persisting windows on a frame you create and own. | `SetMovable`, `StartMoving`/`StopMovingOrSizing`, `SetUserPlaced`, `SetClampedToScreen` | No direct Ace3 equivalent | Available |

**Tooltip** and **Menu** exist specifically to give authors an easy path away from older community UI libraries. Blizzard shipped modern native equivalents for both, but the raw APIs are verbose enough that most authors have stuck with the older wrappers. Foundry's job here is to make the native path the easy path.

All nine modules are available now. Window is new and ships ahead of its first consuming addon.

### Restriction guard

`Commands.Guards.NotRestricted` is an optional command guard for client restriction states: Combat, Encounter, Challenge Mode, PvP Match, Map, and Chat. It returns a readable refusal reason for the active state and falls back to the normal combat-lockdown check on clients without `C_RestrictedActions`.

Set `restrictionNotice = true` when creating a Commands controller to print one notice as a restriction begins. Controllers without that opt-in do not register the notification event or print anything.

## Using Foundry

If your addon depends on a standalone Foundry install only, your TOC can use:

```
## Dependencies: Foundry-1.0
```

If you ship one shared TOC across CurseForge and embedded-fallback builds, use:

```
## OptionalDeps: Foundry-1.0
```

In that shared-TOC shape, keep the hard CurseForge dependency in packager
metadata (`required-dependencies: foundry`, using the CurseForge project slug)
while your embedded build supplies the fallback files.

In your Lua:

```lua
local F = _G.Foundry_1_0
if not F then
    error("MyAddon failed to load Foundry-1.0.")
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

### SavedVariables size warning

Use `db:OnSavedVariablesTooLarge(handler)` to react if the client refuses to
save the owning addon's SavedVariables because they are too large. The handler
receives `(db, addonName, savedVariablesGlobal)`. It fires only for that
addon's live DB controllers; Foundry also emits a diagnostic naming the addon
and SavedVariables global. This is a report-only hook: Foundry does not
estimate sizes or add work to normal writes.

Full API reference: [the Foundry wiki](https://github.com/Royaleint/Foundry/wiki).

If you embed Foundry inside your own addon package, include
`Foundry-1.0.xml` from your `embeds.xml` rather than hand-listing Foundry's Lua
files. The manifest carries the same runtime load order as the standalone TOC.

### Which copy runs

Several addons can each carry a copy of Foundry. The first copy to load is the
active copy; it owns `_G.Foundry_1_0`. A later copy of 1.0.115 or newer can
upgrade it in place: when the later copy is a newer build, its API version is
not lower than the active copy's, loading is still in progress (the player has
not logged in yet), and the player is not in combat, it replaces the active
copy's core and each module it carries, in place, so addons that use Foundry run
the newer copy's code for everything that copy carries. This works only when the
active copy is itself 1.0.115 or newer. A 1.0.114 or earlier copy that loads
first is never upgraded and keeps serving as before. An addon loaded on demand
after login never triggers an upgrade. Copies that are the same build never
upgrade each other, so the first upgrade happens with the release after
1.0.115.

When an upgrade does not happen, the first copy keeps serving and the later copy
loads nothing, and a release copy does so silently. The per-module fill-in still
applies: for each module the active copy does not have, the later copy supplies
its own, so a newer copy fills in modules an older, trimmed copy lacks. DB joins
when the shared library has the Lifecycle and Events support it needs at the
moment DB loads, whether from the active copy or filled in by a later one;
otherwise DB stays out and says why (that message prints in release builds too).

The upgrade is a safety net, not a replacement for load order. Copies from
1.0.114 and earlier are never upgraded, so keep `## OptionalDeps: Foundry-1.0`
in your TOC to make the standalone addon load first.

Because the active copy may be older than the copy you shipped, call
`F:RequireModule("Name", minVersion)` for anything newer. If the module is
missing, the error names the active copy: its addon folder, version and API
version.

Type `/foundry copies` in game to see what is running. It prints the active
copy, any module that comes from a different copy, and each other copy with its
outcome:

- `upgraded to`: this copy replaced the active copy's core.
- `not used`: the active copy was left alone, either because it is 1.0.114 or
  earlier or because this copy was not a newer build.
- `refused: api version`: this copy's API version is lower than the active
  copy's.
- `after login`: this copy loaded after the player had logged in.
- `combat`: this copy loaded during combat.
- `refused: module list`: the active copy's module list did not match what it
  was serving, so it was left alone.
- `layout`: the active copy has an internal layout this copy does not
  recognize.

After an upgrade, the active copy line still shows the first copy's addon
folder and version, but the API version is the newer copy's. The `upgraded to`
line names the copy that replaced its code. Copies older than this version are not listed. The copy record is never printed
unless you run the command, and any other `/foundry` text prints a one-line
hint. The command comes from the active copy when it is current enough to offer
it, and it is skipped if the `FOUNDRY` slash key or `SLASH_FOUNDRY1` is already
taken.

## Adding new modules

Foundry's module set isn't fixed at the initial eight. If there's a Blizzard API you'd like to see bridged, here's how new modules get added.

**The path in:** open an issue describing the API you'd like Foundry to cover and how you'd use it in your addon. Concrete is better than abstract: "here's the code I'd write if Foundry had this module" lands faster than "Foundry should support X."

**What gets a yes:** modules that bridge a real Blizzard API where the raw surface is verbose or hard to discover, and where at least one author has a concrete use case ready to exercise it. The use case doesn't have to be your own. If you're proposing a module someone else needs, point to them and we'll work with them on it.

**What gets a "not yet":** modules without a clear consumer to validate them. Foundry's quality bar is tied to real-world use; designing in the abstract risks shipping API surface that doesn't survive contact with actual addons. We'd rather wait for a concrete use case than guess at one.

This isn't a high bar. It's the same bar the initial eight modules cleared. If you have an addon and an API you want bridged, that's enough.

## Installation

**Via CurseForge App** (recommended): Foundry installs automatically as a dependency when you install an addon that requires it. No action needed.

**Manual**: Download the latest release, extract `Foundry-1.0/` into your `Interface/AddOns/` directory.

## License

MIT. See [LICENSE](LICENSE).

## Contributing

Issues and discussion welcome. For larger changes, open an issue first to discuss the direction before opening a PR.

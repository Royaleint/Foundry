# Changelog

All notable changes to Foundry-1.0 are recorded here.

## [1.0.6] - 2026-06-20

### Added
- **Foundry.Settings** — options panel registration for Blizzard's modern Settings API. One `F.Settings:New({title, frame})` registers your panel as a top-level category in Interface Options and returns a controller: `:Open()` to open directly to your panel, `:GetCategoryID()` for programmatic navigation, `:GetNativeHandles()` to reach the raw Blizzard category and layout objects, and `:Destroy()` to clean up and free the registration slot. Subcategories are supported via the optional `parent` config key. Duplicate registrations are refused loudly rather than silently clobbering an existing panel. Works on all current supported clients; the legacy `InterfaceOptions_AddCategory` path is retained as a forward-compatibility stub. Assert a minimum version with `F:RequireModule("Settings", 1)`.
- **`Events:RegisterBucket`** — coalesces bursts of the same event (or a set of events) into a single handler call, firing after a quiet period rather than once per event. Useful for events that arrive in rapid bursts where only the final state matters — inventory changes, bag updates, auction results. Returns a handle with `:Cancel()` to suppress a pending fire, `:IsPending()` to check queue state, and `:Destroy()` to remove the registration entirely. Leading and trailing coalescing modes are both supported.

## [1.0.5] - 2026-06-14

### Added
- **Foundry.List** — a thin bridge over Blizzard's built-in ScrollBox system, and the replacement for hand-rolled scrolling lists. One `F.List:New(config)` builds the whole composition a scrolling list needs — the list frame, its scrollbar, the view, and the data provider — wired together in the right order with the ScrollBox ordering traps handled for you. It returns a small controller: `SetData` to swap in new rows, `ForEachFrame` to update the visible rows in place (say, to repaint a selection highlight) without a rebuild, `GetNativeHandles` to reach the raw Blizzard objects when you need them, and `Destroy` to tear it down. Linear lists only, in the insecure domain (not for protected combat frames). Assert a minimum version with `F:RequireModule("List", 1)`.

### Changed
- **Embedded DB stands down instead of crashing against an outdated standalone.** If a newer DB-bearing Foundry loads while an older standalone — one predating the DB module's logout hook — has already claimed the runtime, the embedded DB no longer attaches and then fails cryptically later; it refuses up front with a clear "update the standalone Foundry" message, and leaves saved data untouched.
- **Fewer false developer warnings.** The "redundant embedded copy suppressed" developer message now appears only when the two copies are genuinely different API versions, so a normal setup where several addons ship the same Foundry version stays quiet. (Developer-only — players never saw it.)

## [1.0.4] - 2026-06-13

### Added
- **Foundry.DB** — a saved-data module, and the replacement for AceDB-3.0's `:New`. It loads your addon's SavedVariables, fills in your defaults, runs your version migrations, and hands you live `profile` / `char` / `global` tables to read and write — then strips default-equal values back out at logout so the save file stays small. Where it can't act safely it refuses loudly and changes nothing on disk, rather than starting with half-built data. Assert a minimum version with `F:RequireModule("DB", 1)`.
- **Embedded-copy guard** — Foundry can now be bundled directly inside a consumer addon (for Wago, where dependencies aren't installed automatically) instead of requiring a separate install. When a standalone copy and embedded copies are both present the standalone wins; with only embedded copies, the first one loaded wins and the rest stand down quietly — no duplicate event handlers and no risk to saved data. Addons embedding Foundry should pin v1.0.4 or newer.

## [1.0.3] - 2026-06-09

Packaging only — Foundry now uploads to Wago automatically via CI (the v1.0.2 Wago build didn't land because the repo had no uploader workflow).

## [1.0.2] - 2026-06-09

Distribution only — no library code changes.

### Changed
- Now published on Wago alongside CurseForge.
- Lists under the **Libraries** category in the in-game AddOns list.

## [1.0.0] - 2026-06-04

First public release. Foundry-1.0 ships three modules, each a thin bridge over a
native Blizzard system and usable on its own by declaring
`## Dependencies: Foundry-1.0`.

### Added
- **Foundry.Commands** — slash command registration over `SlashCmdList` / `SLASH_*`, with optional dev-only subcommands hidden from players.
- **Foundry.Events** — a per-addon controller over WoW's frame event system (`RegisterEvent`/`OnEvent`, `RegisterUnitEvent`): one handler per event, dispatch in one place, and one-call teardown.
- **Foundry.Lifecycle** — addon startup: adopts your own addon table (it never writes into it) and runs correctly-timed hooks over `ADDON_LOADED`, `PLAYER_LOGIN`, and `PLAYER_LOGOUT`.
- Multi-flavor support — Retail (12.x), Classic Era (1.15.x), and Burning Crusade Classic (2.5.x).

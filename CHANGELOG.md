# Changelog

All notable changes to Foundry-1.0 are recorded here.

## [Unreleased]

## [1.0.105] - 2026-09-01

### Added
- **Lifecycle: a new `OnUnloading` hook runs before SavedVariables are
  written.** It fires on the client's pre-unload signal, so a consumer can act
  before its data is saved, and the handler is told whether the client is
  closing or the session is only unloading. Handlers run in the order they
  were registered. This hook is available only where the client's pre-unload
  event exists; it makes no promise about firing before or after the existing
  logout hook.
- **Commands: a built-in guard can refuse commands during an addon
  restriction.** `Commands.Guards.NotRestricted` checks the client's own
  addon-restriction state and blocks the command while a restriction is
  active, with a clear message to the player. On older clients without that
  check, it falls back to a plain combat-lockdown check. A consumer opts into
  an additional chat notice, printed just before a restriction activates, by
  passing `restrictionNotice` when creating the controller; without it, the
  guard adds no extra frame and no unsolicited chat output. The notice is
  independent of the guard: a controller that opts in without using
  `NotRestricted` still prints it.
- **DB: a new callback reports when SavedVariables could not be saved.** A
  store can register a handler with `OnSavedVariablesTooLarge` and be told
  when the client refuses to save its owning addon's SavedVariables for being
  too large. Previously this condition was silent to the addon. The report
  arrives at the end of the session, after the client has already declined
  that save, so a handler can record or warn but cannot rescue it.
- **Bootstrap: `Foundry_1_0.SOURCE` reports which addon's copy of the library
  is serving.** It holds the addon folder name that supplied the currently
  active copy, useful for diagnosing which of several embedded copies won.

### Changed
- **Events: event names are checked before registration.** `Register`,
  `RegisterUnit`, `RegisterOnce`, and `RegisterBucket` now validate an event
  name against the client's own event list before attempting to register it,
  on clients that expose that check. An invalid name is refused immediately
  with a clear message, and the registration does not happen, instead of
  surfacing only through the client's own registration throw.
- **Bootstrap: a suppressed development copy is now reported, not silent.**
  When a released copy of the library loads first and an enabled development
  copy would otherwise have served, the library now prints a clear message
  through the serving copy, naming which copy is serving and stating that the
  development copy loaded nothing. This only matters to a developer running a
  development build alongside a release install; a normal player install is
  unaffected.
- A couple of internal code comments were reworded and the packaging ignore
  list was tidied. No behavior change.

Lifecycle, Commands, and DB each move to API_VERSION 2 with this release,
reflecting the additions above. Events was already at 2. The library-level
API_VERSION is unchanged; gate on the module numbers.

## [1.0.104] - 2026-08-14

### Changed
- **Updated for patch 12.1.** Foundry is now flagged compatible with the 12.1
  retail client, so it no longer shows as out of date. Everything in the game's
  toolkit Foundry builds on was re-checked after the patch went live and is
  unchanged, so no code changes were needed.

## [1.0.103] - 2026-08-01

This release fixes a run of quiet problems. One of them could delete settings your
addon had already saved. Another slowly made every tooltip in the game a little
more expensive to draw, for everyone, not just for the addon that caused it.
Neither announces itself, so it is worth updating even if nothing here sounds
familiar.

### Fixed
- **DB: a re-created store can no longer delete saved data at logout.** Calling
  `:New` again on the same SavedVariables table with a changed defaults table
  left the old store registered alongside the new one. At logout the stale store
  still ran its own default-stripping pass and deleted any stored value that
  matched one of its *old* defaults, quietly destroying real user data. Only the
  newest store for a given table strips now.
- **Tooltip: create and destroy cycles no longer slow down every tooltip render.**
  Every `:New` used to install a fresh tooltip post-call that the game never
  removes, so ordinary create and destroy cycles permanently added work to every
  tooltip render for the entire client, not just for the addon that did it. This
  came from documented, correct use of the module, not from misuse. Foundry now
  registers exactly one post-call per tooltip type and routes internally.
- **Commands: destroying a controller twice no longer kills a replacement's
  slash command.** A stale controller's second `:Destroy()` cleared the slash
  handler for a name a fresh `:New` had legitimately reclaimed. The replacement's
  globals survived, so the game still accepted the command and simply did nothing
  for the rest of the session. `:Destroy()` is properly idempotent now, and
  teardown can no longer reach a successor's registration.
- **Events: a rejected event registration no longer leaves a dead subscription.**
  The handler was recorded before the game's own registration call. When that
  call refuses an event name, which Midnight does for events that were removed or
  renamed, the error escaped with the handler already stored: `IsRegistered`
  reported true for a subscription that would never fire, and a corrected retry
  was refused as a duplicate. Registration is now all-or-nothing.
- **Events: `RegisterBucket` rolls back cleanly when one member event fails.**
  A refusal partway through the list used to leave the earlier events live and
  pointed at a handler the caller never received a handle for, so nothing could
  cancel it and a pending flush could still fire. A failed bucket now unwinds
  completely.
- **Settings: re-creating a panel after `:Destroy()` no longer duplicates the
  options category.** The player saw the addon listed twice in Interface Options
  for the rest of the session. The existing category is cached and re-bound
  instead of registered a second time. Note the new refusal that comes with this:
  for a name that already registered a category this session, a re-creation
  supplying a different frame, title, or parent is refused and returns nil,
  because a registered category can neither be reused for different inputs nor
  removed once the game has it.
- **Commands: a bad `help` value is caught at `Register` instead of in chat.**
  A table printed a raw pointer to the player, and a `help` function that threw
  escaped when someone typed the bare slash command. `help` is now validated as a
  string or function up front, and the function form is called defensively at
  render with a fallback line.
- **A development-build path no longer freezes defaults onto disk.** A type
  mismatch raised partway through preparing a section could leave freshly written
  defaults behind as though they were user data. This path exists only in
  development builds and never affected a packaged release.

### Changed
- **Tooltip works on more clients than it claimed, and now says so.** The module
  header and its refusal message both described it as Retail-only, but the
  underlying game system also ships on Classic Era 1.15.x and Pandaria Classic
  5.5.x. The incorrect refusal was steering those consumers back toward the
  hand-rolled global tooltip hooks this library exists to replace. To be precise
  about the boundary, since it moved: the module works on Retail 10.0.2+, Classic
  Era 1.15.x, and Pandaria Classic 5.5.x, and it is genuinely unavailable on TBC
  Classic 2.5.x, where it still refuses.
- **Events: trailing-edge buckets are cheaper under events that fire in bursts.**
  Each member event fired used to allocate, schedule, and cancel a timer. Under
  something like unit auras in a raid that meant hundreds of cycles a second to
  protect a handler running about five times a second. Buckets now track a
  deadline and re-arm a single timer per window.

## [1.0.102] - 2026-07-26

### Changed
- **Updated supported game versions.** The library now declares Classic Era
  1.15.9 and TBC Anniversary 2.5.6, so it no longer shows as out of date on
  those clients. No code changes; every module behaves exactly as in 1.0.101.

## [1.0.101] - 2026-07-08

### Fixed
- **Lifecycle: `OnLogin` now fires for controllers created after login.** If the
  session's first Lifecycle controller was created after the player had already
  logged in (a load-on-demand addon, for example), its `OnLogin` handler was
  silently never called. The dispatcher now checks login state when it is
  created, so late controllers catch up correctly.
- **DB: a schema key of just `"global"` is refused up front.** That key would
  have overwritten the whole global section with the version stamp, losing the
  session's writes and locking the save out of every future load. `DB:New` now
  refuses it loudly before anything touches disk.
- **Commands: a wrong-typed `args` value is caught at `Register`.** A table or
  boolean passed as `args` used to be accepted silently and then produce an
  error in the player's chat when help rendered. It is now validated alongside
  the other fields.
- **Menu: the supported-client list now includes TBC Classic 2.5.x everywhere.**
  The module's own notes disagreed with the documentation. Behavior is
  unchanged; Menu already worked there.

### Changed
- The full test suite now runs automatically on every change to the repository,
  including the AceDB compatibility checks.
- The lint configuration file no longer ships in packaged copies, standalone or
  embedded.

## [1.0.100] - 2026-06-30

### Fixed
- **Load errors right after login.** The packaged addon's manifest referenced developer-only test files that the release build correctly excludes, so the game reported them as missing on every login. Those files no longer ship in the manifest at all — they live in a separate, internal-only tool instead.
- **Embedded copies of Foundry were missing the Menu module.** Addons that bundle Foundry directly (rather than requiring the standalone install) now get `Foundry.Menu` along with everything else.

## [1.0.7] - 2026-06-29

### Added
- **Foundry.Tooltip** — a Retail-only bridge over `TooltipDataProcessor` for appending lines to item tooltips. One `F.Tooltip:Register(config)` sets up your handler to run after Blizzard's own tooltip population, so your lines land below the native ones rather than racing them. Registration is consumer-owned: you hold the handle and call `:Destroy()` to disable in place without a reload. An item whitelist filter lets you narrow which item tooltips receive your additions. Two line emitters — `AddLine` for a plain text line and `AddSeparator` for a visual divider — cover the common cases directly. `:GetNativeHandles()` is the escape hatch when you need to reach the raw processor objects.
- **Foundry.Menu** — a bridge over the modern `Blizzard_Menu` / `MenuUtil` system for context menus and persistent dropdown menus. One `F.Menu:New(config)` creates a named, lifecycle-tracked controller: `:CreateContextMenu(owner)` opens a context menu anchored near any frame, and `:SetupDropdown(button)` installs a persistent generator on a `DropdownButton` so the menu rebuilds fresh each time the button is clicked. Your builder function receives the raw Blizzard `rootDescription` and constructs menu content using Blizzard's own `Create*` API directly — buttons, checkboxes, radios, submenus, dividers, titles. Call `:Destroy()` when you're done; any generator already installed on a `DropdownButton` silently becomes a no-op rather than erroring. `:GetNativeHandles()` reaches `MenuUtil` and the `Menu` module directly. Works on Retail 11.0+, Classic Era 1.15.x, Pandaria Classic 5.5.x, and TBC Classic 2.5.x.

### Changed
- **Pandaria Classic (5.5.x) added to supported clients.** The TOC now declares interface version `50504`, bringing Pandaria Classic into the officially supported set alongside Retail, Classic Era, and TBC Classic.

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

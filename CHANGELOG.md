# Changelog

All notable changes to Foundry-1.0 are recorded here.

## [Unreleased]

### Added
- **Foundry.DB** — the AceDB-3.0 replacement (`F.DB:New({ name, sv, defaults, defaultProfile, schema })`). Loads a consumer's SavedVariables, applies its defaults, runs its registered migrations, exposes the live `profile` / `char` / `global` / `sv` section tables, and strips default-equal values back out at logout — for the two storage shapes the committed consumers have on disk. It changes the machinery behind existing save files, never their shape. `db:OnReady`, `db:GetNativeHandles`, and `db:Destroy` round out the controller; unsupported AceDB surfaces (profiles, namespaces, callbacks, wildcards) fail loudly rather than silently. Library API version bumps to 4.

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

# Release

RELEASE_CONFIG: .claude/commands/release.config.json

Package and publish a new Foundry release. This file lives in the public repo root. Foundry
does have a nested `Foundry_Dev/` repo (it's where `gate2.source_path` reads Gate 2 evidence
from), but release *commands* have never lived there, so `RELEASE_CONFIG` points at the
public repo directly rather than into `Foundry_Dev/`.

Three things are specific to Foundry and worth knowing before running this:

- **No version-bump step.** `version_bump_files` in the config is empty on purpose. Only
  `Foundry-1.0.toc` is git-tracked, and it uses `@project-version@` — the packager substitutes
  the real version from the pushed git tag at build time. There is nothing to hand-edit.
  (`Foundry-1.0_DevBuild.toc` is gitignored, dev-only, and untouched by release.)
- **Commit trailer is `By BawrLabs`, not `Co-Authored-By: ...`.** This is Foundry's own,
  owner-decided public voice — every other project in this studio uses a `Co-Authored-By`
  trailer. Note in the release report that this convention is designed intent for Foundry
  under STU-068, not yet actually exercised in past commits, since this command didn't exist
  before now.
- **`foundry-release-guard.yml` is not part of the release pipeline.** It's a dormant,
  manual-trigger-only dev-token sanity check. The real pipeline is `release.yml`, which
  already publishes to CurseForge, Wago, and GitHub end to end on a `v*` tag push — don't
  confuse the two when checking CI state in Step 11 of the core procedure below.

---

<!-- SYNC: release-skill-core from .claude/skills/wow-release-execution/SKILL.md -->
## Config

The invoking project's `release.md` names `RELEASE_CONFIG` — the path to its
`release.config.json` — outside this synced block. Step 0 below validates it.
Every guard invocation in this procedure passes it through:

```
node ../BawrLabs/scripts/release-guard.mjs <subcommand> --config <RELEASE_CONFIG>
```

That literal command (no shell conditionals, no variable expansion) is valid
verbatim in both bash and PowerShell — run it exactly as written, substituting
only `<subcommand>` and `<RELEASE_CONFIG>`.

**On any guard non-zero exit, read the RESULT line before deciding what it
means** — non-zero is not uniformly "hard stop." `check-gate2` exits non-zero
for two different things, distinguished only by that line's text, never by
the exit code itself:
- `RESULT: STOP — ...` is a hard failure. Report the reason to Rawb verbatim
  and stop the procedure — do not proceed past the failing step, do not retry
  with different flags, and do not hand-verify the condition yourself as a
  substitute for the guard passing. A stop is the guard doing its job.
- `RESULT: MANUAL-CONFIRM REQUIRED — ...` is Triage's expected, designed
  result (`gate2.mode: manual-confirm`) — see step 2. It means *pause and ask
  Rawb directly*, not abort. Do not treat this exit code as a stop.

Every other subcommand's non-zero exit is a plain stop; `check-gate2` is the
one exception, and only for `manual-confirm` projects.

## Procedure

0. **Validate config.** Confirm `RELEASE_CONFIG` is set in the invoking
   `release.md` and that the file it points to parses as JSON. If either
   check fails, stop before running any guard subcommand — nothing below
   runs without a working config.

1. **Branch and cleanliness.**
   Run `check-branch` — current branch must exactly equal the project's
   `release_branch`. Run `check-clean` — every root in the config's
   `clean_roots` (this may include a nested Dev repo, not just the public
   repo) must be clean; the guard names the specific dirty root if one
   exists. Either check failing stops the release before any other step.

2. **Shipping set, ticket mapping, Gate 2, version proposal.**
   - Run `shipping-set --since <last-tag>` to enumerate the commits going
     out. A commit with no resolvable ticket ID stops the run.
   - Run `map-tickets` to resolve each ticket ID against the project's
     configured tracker/completed source. A duplicate entry with conflicting
     type or status stops the run as ambiguous.
   - Run `check-gate2` — **before any file is touched.** For automated
     projects this is authoritative: a missing or non-matching marker stops
     the run. **For Triage** (`gate2.mode: manual-confirm`), the guard does
     not verify anything — it reports `manual-confirm` and defers. In that
     case, stop here and ask Rawb directly, in this conversation, listing
     the exact ticket IDs from the shipping set, and wait for his real
     response before continuing. Record his confirmation verbatim (what he
     said, when) in the eventual report — label it "Rawb's interactive
     confirmation," never as a Gate 2 pass the tooling verified.
   - Run `suggest-version` and present the full evidence table (shipping
     commits, mapped tickets, proposed category and version) to Rawb for
     confirmation before proceeding. A first release with no previous tag,
     an unresolved commit/ticket, or a ticket `Type:` matching none of the
     project's `version_categories` stops the run — none of these fall back
     to a silent default.

3. **Lint.** Run the project's configured `luacheck` command. Errors stop
   the release. Warnings proceed only if they're within the project's
   established baseline.

4. **Version bump.** Update every file in `version_bump_files` (empty list
   for Foundry — skip this step there) plus the TOC `## Interface:` line if
   the game version changed.

5. **Changelogs.** Write the internal changelog entry first, then derive the
   public entry from it per the project's `changelog` config. For a project
   with `confidentiality_mode: "restricted"` (Sift), build the public entry
   from the fixed template and closed outcome vocabulary only — a freeform
   override requires an explicit flag and must be flagged for a human
   confidentiality read during the diff review in step 7, never applied
   silently. Route public-facing text through Everett.

6. **`.pkgmeta` sanity.** Local, deterministic checks only: the file exists
   and parses, and `manual-changelog` resolves to a real file. This is not a
   re-check of ignore-rules-vs-shipped-files — that's covered by CI's
   TOC-vs-zip job, reported in step 11.

7. **Diff review.** Show the full diff (version bump, changelog entries,
   any other touched files) and get Rawb's explicit confirmation before
   committing. Do not commit on an assumed approval.

8. **Commit.** Use the project's configured `commit_trailer`.

9. **Tag.** Create an annotated tag (`git tag -a vX.Y.Z -m "..."`). Then
   re-run `check-gate2` a second time — defense-in-depth against tracker
   state changing mid-run — and run `check-tag <version>`, which requires
   `git rev-parse vX.Y.Z^{commit}` to exactly equal `git rev-parse HEAD`.
   Both must pass before either push in step 10.

10. **Push.** Push the commit, then push the specific tag only:
    `git push origin vX.Y.Z`. Never `git push --tags`.

11. **Publication verification.** `release-guard.mjs publication-targets`
    only classifies which targets are even in scope for this project
    (`configured` vs `not applicable`) — it does **not** perform the live
    GitHub checks itself, and its exit 0 means "the config split is sane,"
    not "publication is verified." Do not stop at that command and report
    success; the live verification is this step's own work, using `gh`:
    1. Locate the run: `gh run list --workflow=release.yml
       --branch=vX.Y.Z` (or equivalent lookup by the pushed tag ref), then
       confirm it's for **this tag's exact commit SHA** — never assume "most
       recent run" if more than one exists. Wait for it to reach a terminal
       state (`gh run watch <id>`, with a sane overall timeout — on timeout,
       report "could not confirm, check manually," never treat timeout as
       success). Report state 1 as `passed` only if `conclusion == success`
       (this includes the TOC-vs-zip check, which runs as a job step) —
       otherwise `failed`, with the failing step named if `gh run view
       --log-failed` can show it.
    2. Report state 2, the CF duplicate check, as `passed` if that job step
       succeeded, or `unarmed/skipped` if it warned-and-skipped because
       `CF_CORE_API_KEY` isn't set — an unarmed check is reported as
       unarmed, never folded into "passed."
    3. For each entry in `config.publication_targets` marked `configured` by
       the guard's classification, report `upload succeeded` (from the same
       CI run) or `not applicable` for a target the project doesn't publish
       to (e.g. Wago for Sift). Then run `gh release view vX.Y.Z` to confirm
       the GitHub Release object exists.
    Report all three states separately in the final report (step 13) —
    never collapse them into one "covered," and never let a bare guard
    PROCEED stand in for having actually run these `gh` checks.

12. **Release notes and community posts.** Write or confirm the GitHub
    release notes; draft any community posts. Route all of this through
    Everett before anything is posted — this skill never posts on its own.

13. **Report.** Summarize the release for Rawb, including any "not
    applicable" targets, any "unarmed" checks, and — for Triage — the
    recorded human confirmation from step 2. Never omit these silently;
    an incomplete or skipped check is part of the record, not noise.
<!-- END SYNC: release-skill-core -->

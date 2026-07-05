#!/usr/bin/env node
// check-toc-vs-zip.mjs — release-safety check (STU-064, canonical copy).
//
// Verifies that every file referenced by every TOC inside the packaged zip(s)
// is actually present in the zip. Closes the FND-012 failure class: a
// `.pkgmeta` `ignore:` entry can strip a file the TOC still lists, which
// ships one "Error loading <path>" per player per login with no CI signal.
//
// Usage:  node check-toc-vs-zip.mjs [releaseDir]     (default: .release)
// Requires: `unzip` on PATH (preinstalled on GitHub ubuntu runners).
//
// Scope: TOC-level references only. XML files can include further files;
// transitive XML resolution is deliberately out of scope — the FND-012
// incident class is TOC-level, and XML include errors surface at packaging
// time far more often than ignore-stripping does.
//
// SYNC-SOURCE: BawrLabs/scripts/release-checks/check-toc-vs-zip.mjs
// Per-repo copies live at .github/scripts/ — edit the canonical copy and
// re-copy; do not let them drift.

import { execFileSync } from "node:child_process";
import { readdirSync, existsSync } from "node:fs";
import path from "node:path";

const releaseDir = process.argv[2] ?? ".release";

function fail(msg) {
  console.error(`::error::${msg}`);
  process.exitCode = 1;
}

if (!existsSync(releaseDir)) {
  fail(`release dir '${releaseDir}' does not exist — run the packager (build-only is fine) before this check`);
  process.exit(1);
}

const zips = readdirSync(releaseDir).filter((f) => f.endsWith(".zip"));
if (!zips.length) {
  fail(`no .zip files found in '${releaseDir}'`);
  process.exit(1);
}

let checkedTocs = 0;
let totalMissing = 0;

for (const zipName of zips) {
  const zipPath = path.join(releaseDir, zipName);
  const entries = execFileSync("unzip", ["-Z1", zipPath], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 })
    .split(/\r?\n/)
    .filter(Boolean);
  // Case-insensitive membership: WoW's loader is case-insensitive on the
  // platforms that matter, and packager output case always matches the repo.
  const entrySet = new Set(entries.map((e) => e.toLowerCase().replace(/\\/g, "/")));

  const tocs = entries.filter((e) => e.toLowerCase().endsWith(".toc"));
  if (!tocs.length) {
    fail(`${zipName}: contains no .toc file at all — not a valid addon package`);
    continue;
  }

  for (const tocEntry of tocs) {
    checkedTocs++;
    const tocDir = tocEntry.includes("/") ? tocEntry.slice(0, tocEntry.lastIndexOf("/") + 1) : "";
    const tocText = execFileSync("unzip", ["-p", zipPath, tocEntry], { encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
    const missing = [];
    for (let rawLine of tocText.split(/\r?\n/)) {
      const line = rawLine.replace(/^﻿/, "").trim();
      if (!line || line.startsWith("#")) continue; // directives + comments
      const ref = line.replace(/\\/g, "/");
      const resolved = (tocDir + ref).toLowerCase();
      if (!entrySet.has(resolved)) missing.push(ref);
    }
    if (missing.length) {
      totalMissing += missing.length;
      fail(`${zipName} :: ${tocEntry} references ${missing.length} file(s) missing from the zip — every player would see "Error loading" at login:`);
      for (const m of missing) console.error(`    MISSING: ${m}`);
    } else {
      console.log(`ok ${zipName} :: ${tocEntry} — all referenced files present`);
    }
  }
}

if (totalMissing) {
  console.error(`check-toc-vs-zip: FAILED — ${totalMissing} missing file reference(s) across ${zips.length} zip(s). A .pkgmeta ignore rule probably strips a file the TOC still lists.`);
  process.exit(1);
}
if (process.exitCode) {
  // A non-missing-file failure (e.g. a zip with no TOC) already set the exit
  // code — do not print a contradictory PASSED line.
  console.error("check-toc-vs-zip: FAILED — see errors above.");
  process.exit(1);
}
console.log(`check-toc-vs-zip: PASSED — ${checkedTocs} TOC(s) across ${zips.length} zip(s), every referenced file ships.`);

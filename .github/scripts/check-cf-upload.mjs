#!/usr/bin/env node
// check-cf-upload.mjs — release-safety check (STU-064, canonical copy).
//
// After the CurseForge upload step, asks CF how many files it now holds for
// the version just released. Anything other than exactly one is a loud
// failure. Bounds the FND-015 risk class: the packager's two-layer retry
// (curl --retry inside upload_curseforge() plus an outer bash retry) makes a
// silent duplicate upload structurally possible, and one unexplained
// duplicate has already appeared on a studio project (Foundry v1.0.100,
// root cause never confirmed).
//
// Auth: CF_CORE_API_KEY env — a free CurseForge Core API key
// (console.curseforge.com), NOT the upload token. If the secret is absent
// the check WARNS AND SKIPS (exit 0) so adoption never blocks a release
// before the key is provisioned; once the key exists, failures are hard.
//
// Project id: CF_PROJECT_ID env, else auto-read from the first
// `## X-Curse-Project-ID:` line found in a repo TOC.
// Version under test: TAG env (e.g. v2.5.3 or v2.5.3-wago).
//
// Test hook: --files-json <path> bypasses the network and reads the API
// response shape from a fixture file.
//
// SYNC-SOURCE: BawrLabs/scripts/release-checks/check-cf-upload.mjs
// Per-repo copies live at .github/scripts/ — edit the canonical copy and
// re-copy; do not let them drift.

import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";

const ATTEMPTS = 4;          // CF file listings can lag the upload slightly
const ATTEMPT_DELAY_MS = 20000;

function warnSkip(msg) {
  console.log(`::warning::check-cf-upload skipped — ${msg}`);
  process.exit(0);
}

function findProjectID() {
  if (process.env.CF_PROJECT_ID) return process.env.CF_PROJECT_ID.trim();
  const stack = ["."];
  while (stack.length) {
    const dir = stack.pop();
    for (const name of readdirSync(dir)) {
      if (name.startsWith(".") || name === "node_modules") continue;
      const p = path.join(dir, name);
      if (statSync(p).isDirectory()) { stack.push(p); continue; }
      if (!name.toLowerCase().endsWith(".toc")) continue;
      const m = readFileSync(p, "utf8").match(/^## X-Curse-Project-ID:\s*(\d+)/im);
      if (m) return m[1];
    }
  }
  return null;
}

async function fetchFiles(projectID, apiKey) {
  const resp = await fetch(`https://api.curseforge.com/v1/mods/${projectID}/files?pageSize=50`, {
    headers: { "x-api-key": apiKey, Accept: "application/json" },
  });
  if (!resp.ok) throw new Error(`CF Core API HTTP ${resp.status}`);
  return (await resp.json()).data ?? [];
}

const tag = process.env.TAG ?? "";
if (!tag) warnSkip("TAG env not set");
const version = tag.replace(/^v/, "").replace(/-wago$/, "");

// Boundary-aware version match, declared BEFORE the retry loop that uses it
// (a const after the loop is a temporal-dead-zone crash on the armed network
// path — caught at Gate 1; the fixture path never enters the loop).
// Rules: "2.5.3" must not match "2.5.30" (leading/trailing digit), must not
// match "2.5.3.1" (dot-digit continuation), must not match "2.5.3-rc1"
// (hyphen suffix = a different release), but MUST match "Addon-2.5.3.zip"
// (dot followed by a non-digit is a file extension, not a version part).
const versionRE = new RegExp(
  `(^|[^0-9.])${version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?![0-9]|\\.[0-9]|-[A-Za-z0-9])`
);
function matchesVersion(f) {
  const hay = `${f.displayName ?? ""} ${f.fileName ?? ""}`;
  return versionRE.test(hay);
}

const fixtureIdx = process.argv.indexOf("--files-json");
let files = [];
let projectID = "(fixture)";
if (fixtureIdx >= 0) {
  files = JSON.parse(readFileSync(process.argv[fixtureIdx + 1], "utf8")).data ?? [];
} else {
  const apiKey = process.env.CF_CORE_API_KEY;
  if (!apiKey) warnSkip("CF_CORE_API_KEY secret not configured (create a free key at console.curseforge.com and add it to repo secrets to arm this check)");
  projectID = findProjectID();
  if (!projectID) warnSkip("no CF_PROJECT_ID env and no X-Curse-Project-ID found in any TOC");
  // Transient API errors count as a retry, never an instant hard-fail: the
  // upload already happened by the time this runs, so a CF blip must not
  // torpedo the rest of the workflow on the first attempt.
  let lastErr = null;
  for (let attempt = 1; attempt <= ATTEMPTS; attempt++) {
    try {
      files = await fetchFiles(projectID, apiKey);
      lastErr = null;
      if (files.some((f) => matchesVersion(f))) break;
    } catch (err) {
      lastErr = err;
      console.log(`CF API error on attempt ${attempt}/${ATTEMPTS}: ${err.message}`);
    }
    if (attempt < ATTEMPTS) {
      console.log(`no confirmed file for ${version} yet (attempt ${attempt}/${ATTEMPTS}) — waiting ${ATTEMPT_DELAY_MS / 1000}s`);
      await new Promise((r) => setTimeout(r, ATTEMPT_DELAY_MS));
    }
  }
  if (lastErr) {
    console.error(`::error::check-cf-upload: CF Core API unreachable after ${ATTEMPTS} attempts (${lastErr.message}) — could not verify the upload. Check the CF file list manually.`);
    process.exit(1);
  }
}

const matches = files.filter(matchesVersion);
console.log(`CF project ${projectID}: ${files.length} recent file(s); ${matches.length} matching ${tag}:`);
for (const f of matches) console.log(`  - id=${f.id} "${f.displayName}" (${f.fileName}) uploaded ${f.fileDate}`);

if (matches.length === 0) {
  console.error(`::error::check-cf-upload: NO file matching ${tag} on CurseForge after ${ATTEMPTS} attempts — the upload may have failed silently or the naming convention changed.`);
  process.exit(1);
}
if (matches.length > 1) {
  console.error(`::error::check-cf-upload: ${matches.length} files match ${tag} — duplicate upload detected (FND-015 class). Delete the extra file on CF's file management page and investigate the run log.`);
  process.exit(1);
}
console.log("check-cf-upload: PASSED — exactly one file for this release.");

#!/usr/bin/env bash
#
# Foundry release guard: fail if a PACKAGED Foundry artifact still contains the
# literal @project-version@ packaging token in a file that ships and loads.
#
# Why this exists: the bootstrap (Foundry.lua) decides IS_DEV_BUILD by comparing
# the TOC's ## Version against the unsubstituted token. If a release is built by
# a pipeline that does NOT run the BigWigs/CurseForge packager, the token
# survives and the addon runs as a development build in players' clients, raising
# dev-only diagnostics in production. A pipeline-level guard is needed to prevent
# this; the runtime
# cannot detect it on its own. This script is that guard, callable by any future
# release pipeline.
#
# Run it against the PACKAGED build directory, NOT the source tree: source
# legitimately carries the token in the TOC before packaging. Files under Tests/
# are excluded because they do not ship or load.
#
# Usage:  check-dev-token.sh <packaged-artifact-dir>
# Exit 0 = clean (token absent).  Exit 1 = token present (packager did not run).
# Exit 2 = usage / target error.

set -uo pipefail

target="${1:-}"
if [ -z "$target" ]; then
    echo "usage: check-dev-token.sh <packaged-artifact-dir>" >&2
    exit 2
fi
if [ ! -e "$target" ]; then
    echo "check-dev-token: target '$target' does not exist" >&2
    exit 2
fi

token='@project-version@'

matches="$(grep -rIlF --include='*.toc' --include='*.lua' --exclude-dir='Tests' -- "$token" "$target" 2>/dev/null || true)"

if [ -n "$matches" ]; then
    echo "FAIL: the packaged artifact still contains the literal $token token:"
    echo "$matches" | sed 's/^/  /'
    echo ""
    echo "The packager did not substitute it. Shipping this would set IS_DEV_BUILD"
    echo "to true in players' clients. Ensure the BigWigs/CurseForge packager ran"
    echo "on the release artifact before publishing."
    exit 1
fi

echo "PASS: no literal $token token in shipped files under '$target'."
exit 0

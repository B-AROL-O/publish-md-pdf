#!/bin/bash
# ==========================================================
# Runs the image .github/workflows/ci.yml built, the way every CI step runs
# it: with the workspace mounted at /workspace, and on the host network so the
# tool can reach the nginx mocks at 127.0.0.1. The arguments are
# publish-md-pdf.sh's own.
#
# Credentials and mock-server settings come from the calling step's
# environment, which is how ci.yml declares them once per job (job-level
# env:) and how a negative test overrides or clears one (step-level env:).
# Each is forwarded by name -- never as -e VAR=value, the same rule as the
# host wrappers under scripts/ -- and only when non-empty, so a variable a
# step sets to "" reaches the container unset, which is exactly what the
# "missing credentials" tests need.
#
# The mock GitHub server's settings arrive as MOCK_GITHUB_* and are renamed
# here rather than set as GITHUB_* in the workflow: the runner itself sets
# GITHUB_SERVER_URL and GITHUB_API_URL (to github.com) on every job, and
# forwarding those would point the tool at the real GitHub, with the real
# server's API, instead of the mock.
#
# Steps that need --entrypoint (the toolchain listing, the v1 shims) still
# call docker run directly.
#
# Usage: .github/scripts/run-ci-image.sh [publish-md-pdf.sh flags] <file|url>...
# ==========================================================

set -e

IMAGE="ghcr.io/b-arol-o/publish-md-pdf:v2"

args=(--rm --network host -v "$PWD:/workspace")

for var in CONFLUENCE_EMAIL CONFLUENCE_API_TOKEN PUBLISH_MD_PDF_ALLOW_INSECURE; do
	if [ -n "${!var:-}" ]; then
		args+=(-e "$var")
	fi
done

for suffix in TOKEN SERVER_URL API_URL; do
	mock="MOCK_GITHUB_$suffix"
	if [ -n "${!mock:-}" ]; then
		export "GITHUB_$suffix=${!mock}"
		args+=(-e "GITHUB_$suffix")
	fi
done

exec docker run "${args[@]}" "$IMAGE" "$@"

# EOF

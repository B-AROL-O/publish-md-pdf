#!/bin/bash
# ==========================================================
# Assertion helpers for the unit tests under tests/.
#
# Sourced by each tests/test_*.sh; not meant to be run directly.
#
# Deliberately tiny and dependency-free: the point of these tests is to cover
# the pure string functions in lib/ without a Docker build, so pulling in a
# framework would defeat the exercise. The repository stays bash-only.
#
# Nothing here calls "set -e": a failing assertion records itself and the file
# keeps going, so one run reports every failure rather than only the first.
# ==========================================================

ASSERTIONS=0
FAILURES=0

# assert_eq <expected> <actual> <description>
assert_eq() {
	local expected="$1" actual="$2" description="$3"
	ASSERTIONS=$((ASSERTIONS + 1))
	if [ "$expected" = "$actual" ]; then
		return 0
	fi
	FAILURES=$((FAILURES + 1))
	printf '  FAIL: %s\n' "$description" >&2
	printf '    expected: [%s]\n' "$expected" >&2
	printf '    actual:   [%s]\n' "$actual" >&2
}

# assert_succeeds <description> <command> [args...]
assert_succeeds() {
	local description="$1" status=0
	shift
	ASSERTIONS=$((ASSERTIONS + 1))
	"$@" >/dev/null 2>&1 || status=$?
	if [ "$status" -eq 0 ]; then
		return 0
	fi
	FAILURES=$((FAILURES + 1))
	printf '  FAIL: %s (expected success, got exit %s)\n' "$description" "$status" >&2
}

# assert_fails <description> <command> [args...]
#
# Used mostly on the guards that refuse hostile input, where "returns non-zero"
# is the security property under test, not an incidental detail.
assert_fails() {
	local description="$1" status=0
	shift
	ASSERTIONS=$((ASSERTIONS + 1))
	"$@" >/dev/null 2>&1 || status=$?
	if [ "$status" -ne 0 ]; then
		return 0
	fi
	FAILURES=$((FAILURES + 1))
	printf '  FAIL: %s (expected failure, got success)\n' "$description" >&2
}

# assert_summary <suite name> -- prints one result line, exits non-zero on any
# failure so tests/run-tests.sh can just read the exit status.
assert_summary() {
	local name="$1"
	if [ "$FAILURES" -eq 0 ]; then
		printf 'ok   %-24s %3d assertions\n' "$name" "$ASSERTIONS"
		return 0
	fi
	printf 'FAIL %-24s %3d of %d assertions failed\n' "$name" "$FAILURES" "$ASSERTIONS" >&2
	return 1
}

# EOF

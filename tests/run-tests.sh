#!/bin/bash
# ==========================================================
# Runs the unit tests under tests/.
#
#   ./tests/run-tests.sh            # every tests/test_*.sh
#   ./tests/run-tests.sh common     # only tests/test_common.sh
#
# These cover the pure string functions in lib/ -- the storage-format
# scanners, the URL and filename guards, the escaping helpers -- which need
# neither Docker nor pandoc nor network, so the whole suite runs in well under
# a second. Anything that shells out to pandoc/WeasyPrint or talks to the REST
# API is covered instead by the integration steps in
# .github/workflows/ci.yml, which need the built image.
#
# Exits non-zero if any suite fails, so CI can call it directly.
# ==========================================================

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The suite asserts this tool's *default* refusal to send credentials over
# plain HTTP, so a value inherited from the caller's shell would quietly
# invert that test.
unset PUBLISH_MD_PDF_ALLOW_INSECURE

files=()
if [ $# -gt 0 ]; then
	for name in "$@"; do
		file="$TESTS_DIR/test_${name#test_}.sh"
		if [ ! -f "$file" ]; then
			echo "ERROR: no such test suite: $file" >&2
			exit 1
		fi
		files+=("$file")
	done
else
	for file in "$TESTS_DIR"/test_*.sh; do
		[ -f "$file" ] && files+=("$file")
	done
fi

if [ "${#files[@]}" -eq 0 ]; then
	echo "ERROR: no test suites found in $TESTS_DIR" >&2
	exit 1
fi

failed=0
for file in "${files[@]}"; do
	# Each suite runs as its own process: one suite's globals (and lib/
	# common.sh's EXIT trap) cannot then leak into the next.
	bash "$file" || failed=$((failed + 1))
done

echo
if [ "$failed" -eq 0 ]; then
	echo "All ${#files[@]} test suite(s) passed."
	exit 0
fi
echo "$failed of ${#files[@]} test suite(s) failed." >&2
exit 1

# EOF

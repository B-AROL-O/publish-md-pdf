#!/bin/bash
# ==========================================================
# Shared helpers for this repo's CLI scripts (publish-md-pdf.sh,
# md-to-confluence.sh, confluence-to-md.sh): common flag parsing and file
# validation. Meant to be sourced, not run directly.
# ==========================================================

require_command() {
	local cmd="$1" hint="$2"
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "ERROR: '$cmd' is not installed. Install it with: $hint"
		exit 1
	fi
}

require_file_with_ext() {
	local file="$1" ext="$2" label="$3"
	if [ ! -f "$file" ]; then
		echo "ERROR: File not found: $file"
		exit 1
	fi
	if [ "${file##*.}" != "$ext" ]; then
		echo "ERROR: Not a $label file: $file"
		exit 1
	fi
}

resolve_output_name() {
	local input="$1" src_ext="$2" dst_ext="$3" requested="$4" name
	if [ -n "$requested" ]; then
		name="$requested"
		case "$name" in
		*."$dst_ext") ;;
		*) name="$name.$dst_ext" ;;
		esac
	else
		name="$(basename "${input%."$src_ext"}").$dst_ext"
	fi
	printf '%s\n' "$name"
}

# Parses the --output-dir/--output-name flags shared by every CLI script in
# this repo, then validates the remaining positional arguments. Requires a
# `usage` function to already be defined by the caller. Sets $output_dir
# (default $PWD), $output_name (default ""), and $remaining_args (the
# positional file arguments, as an array) as a side effect.
# shellcheck disable=SC2034 # output_dir/output_name are used by callers that source this file
parse_common_flags() {
	output_dir="$PWD"
	output_name=""

	while [ $# -gt 0 ]; do
		case "$1" in
		--output-dir)
			[ $# -ge 2 ] || {
				echo "ERROR: --output-dir requires an argument"
				exit 1
			}
			output_dir="$2"
			shift 2
			;;
		--output-name)
			[ $# -ge 2 ] || {
				echo "ERROR: --output-name requires an argument"
				exit 1
			}
			output_name="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		--)
			shift
			break
			;;
		-*)
			echo "ERROR: Unknown option: $1"
			usage
			exit 1
			;;
		*)
			break
			;;
		esac
	done
	remaining_args=("$@")

	if [ ${#remaining_args[@]} -eq 0 ]; then
		usage
		exit 1
	fi
	if [ -n "$output_name" ] && [ ${#remaining_args[@]} -gt 1 ]; then
		echo "ERROR: --output-name can only be used with a single input file"
		exit 1
	fi
}

# EOF

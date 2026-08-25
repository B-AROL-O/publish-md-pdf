#!/bin/bash
# ==========================================================
# Shared helpers for publish-md-pdf.sh and its lib/convert-*.sh modules.
# Meant to be sourced, not run directly.
# ==========================================================

# A script may only install one EXIT trap — a second `trap ... EXIT`
# silently replaces the first rather than adding to it. Every module that
# needs a temp file/dir removed registers it here instead of installing its
# own trap.
_cleanup_paths=()

register_cleanup() {
	_cleanup_paths+=("$1")
}

_run_cleanup() {
	local path
	for path in "${_cleanup_paths[@]}"; do
		rm -rf "$path"
	done
}
trap _run_cleanup EXIT

is_url() {
	case "$1" in
	http://* | https://*) return 0 ;;
	*) return 1 ;;
	esac
}

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

# EOF

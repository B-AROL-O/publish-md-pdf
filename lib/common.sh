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

# Where a fetched page's attachments were written, as a path relative to the
# output file, and the Confluence-title -> local-basename mapping that
# lib/fetch-confluence.sh fills in while downloading them.
#
# Both live here rather than in lib/fetch-confluence.sh because
# lib/convert-md.sh reads them to build each <img src>/<a href>, and a
# .confluence file converted straight off disk never sources the fetch module
# at all -- it just finds them empty and emits bare filenames.
# shellcheck disable=SC2034 # both are read by lib/convert-md.sh and written by
# lib/fetch-confluence.sh; neither is used in this file.
CONFLUENCE_ATTACHMENT_PREFIX=""
# shellcheck disable=SC2034
declare -A CONFLUENCE_ATTACHMENT_MAP=()

# Confluence-account-id -> display-name for the page's user mentions, filled by
# lib/fetch-confluence.sh's confluence_fetch_users and read by lib/convert-md.sh.
#
# Here for the same reason as the attachment map above: storage format records a
# mention as nothing but an opaque account id, so the name has to be looked up
# over the API, yet a .confluence file converted straight off disk never sources
# the fetch module at all -- it finds this empty and falls back to a placeholder.
# shellcheck disable=SC2034 # read by lib/convert-md.sh, written by lib/fetch-confluence.sh
declare -A CONFLUENCE_USER_MAP=()

# Attachment titles are server-controlled text that this tool writes straight
# to disk, so a title like "../../.ssh/authorized_keys" must not be able to
# escape the destination directory. Directory components are dropped, the
# result is reduced to a conservative [A-Za-z0-9._-] set, and a name that
# sanitizes away to nothing (or to bare dots, i.e. "." or "..") falls back to
# $2. Running every name through one function is also what keeps the
# downloader and the storage-format rewriter agreeing on the name a given
# attachment ends up under.
confluence_safe_basename() {
	local name="$1" fallback="$2" safe
	name="${name##*/}"
	name="${name##*\\}"
	safe="$(printf '%s' "$name" | tr -d '[:cntrl:]' |
		sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^[.-]+//; s/-+$//')"
	safe="${safe:0:100}"
	if [ -z "$safe" ]; then
		safe="$fallback"
	fi
	printf '%s\n' "$safe"
}

# Escapes text for use inside a double-quoted HTML attribute. Attachment
# titles and caption text reach the generated HTML from the API response, so
# a title containing a quote or an angle bracket would otherwise break out of
# the attribute it lands in.
html_escape_attr() {
	local text="$1"
	# The backslashes matter: since bash 5.2 an unescaped "&" in a
	# substitution's replacement expands to the text that was matched.
	text="${text//&/\&amp;}"
	text="${text//</\&lt;}"
	text="${text//>/\&gt;}"
	text="${text//\"/\&quot;}"
	printf '%s' "$text"
}

# The inverse, for a value read back out of a storage-format attribute.
# Storage format is XHTML, so its attribute values are already entity-escaped;
# they have to come back to raw text before being compared against an
# attachment title from the JSON API (which is not escaped) or re-escaped on
# the way into generated HTML -- otherwise a file named "a&b.png" is looked up
# as "a&amp;b.png" and emitted as "a&amp;amp;b.png".
#
# "&amp;" is undone last: doing it first would turn "&amp;lt;" -- the escaping
# of a literal "&lt;" -- into a real "<".
xml_unescape_attr() {
	local text="$1"
	text="${text//&lt;/<}"
	text="${text//&gt;/>}"
	text="${text//&quot;/\"}"
	text="${text//&#39;/\'}"
	text="${text//&apos;/\'}"
	text="${text//&amp;/\&}"
	printf '%s' "$text"
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

#!/bin/bash
# ==========================================================
# Convert Markdown files, Confluence Storage Format files, and Confluence
# Cloud pages into each other - A4-sized PDF by default.
#
# Thin wrapper around the ghcr.io/b-arol-o/publish-md-pdf container image, for
# a host that has docker but not pandoc/weasyprint. Every flag maps onto the
# image's own CLI flag of the same name; the only work this script does is
# translating host paths into the container's view of them (and back again, in
# the output it prints).
#
# NOTE: this is the *host-side* wrapper, not the image's entry point - that is
# ../publish-md-pdf.sh, which runs inside the container. This file is meant to
# be copied into a documentation repository as scripts/publish-md-pdf.sh; see
# scripts/publish-md-pdf.ps1 for the PowerShell equivalent.
#
# Usage: scripts/publish-md-pdf.sh [--format FORMAT] [--output-dir DIR] [--output-name NAME] [--css-file FILE] [--no-attachments] <file|url> [file2|url2 ...]
# ==========================================================

set -e

# Overridable so a locally built image can be tested without editing this file.
IMAGE="${PUBLISH_MD_PDF_IMAGE:-ghcr.io/b-arol-o/publish-md-pdf:v2}"

usage() {
	echo "Usage: $0 [--format FORMAT] [--output-dir DIR] [--output-name NAME] [--css-file FILE] [--no-attachments] <file|url> [file2|url2 ...]"
	echo "Converts each input file (or fetched Confluence page) to FORMAT (via $IMAGE)."
	echo
	echo "  --format FORMAT     Conversion to perform (default: pdf; default: md if"
	echo "                      every input is a URL):"
	echo "                        pdf         Markdown (.md) to A4-sized PDF"
	echo "                        confluence  Markdown (.md) to Confluence Storage Format"
	echo "                        md          Confluence Storage Format to Markdown"
	echo "                      --to is accepted as an alias for --format."
	echo "  --output-dir DIR    Directory to write the output file(s) into (default: \$PWD)"
	echo "  --output-name NAME  Filename for the output (default: derived from the input"
	echo "                      filename, or the fetched page's title); only valid when"
	echo "                      converting a single input"
	echo "  --css-file FILE     Stylesheet to use (default: the image's built-in"
	echo "                      publish-md-pdf.css); only valid with --format pdf"
	echo "  --no-attachments    Don't download the attachments of a fetched Confluence page"
	echo
	echo "An input starting with http:// or https:// is fetched as a Confluence Cloud"
	echo "page instead of being read as a file - tiny links, /spaces/KEY/pages/<id>/Title,"
	echo "?pageId=<id> and legacy /display/KEY/Title URLs. That needs credentials in the"
	echo "environment, forwarded to the container:"
	echo "  CONFLUENCE_EMAIL      Atlassian account email (or ATLASSIAN_EMAIL)"
	echo "  CONFLUENCE_API_TOKEN  API token (or ATLASSIAN_API_TOKEN), created at"
	echo "                        https://id.atlassian.com/manage-profile/security/api-tokens"
}

format=""
output_dir=""
output_name=""
css_file=""
no_attachments=0

require_argument() {
	[ "$2" -ge 2 ] || {
		echo "ERROR: $1 requires an argument"
		exit 1
	}
}

while [ $# -gt 0 ]; do
	case "$1" in
	--format | --to)
		require_argument "$1" $#
		format="$2"
		shift 2
		;;
	--output-dir)
		require_argument "$1" $#
		output_dir="$2"
		shift 2
		;;
	--output-name)
		require_argument "$1" $#
		output_name="$2"
		shift 2
		;;
	--css-file)
		require_argument "$1" $#
		css_file="$2"
		shift 2
		;;
	--no-attachments)
		no_attachments=1
		shift
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

if [ $# -eq 0 ]; then
	usage
	exit 1
fi

if [ -n "$output_name" ] && [ $# -gt 1 ]; then
	echo "ERROR: --output-name can only be used with a single input file"
	exit 1
fi

# Which format is in effect decides what the file inputs must look like. The
# image applies the same default - pdf, unless every input is a URL, in which
# case the page's own Markdown - so only an explicit --format is passed on.
effective_format="$format"
if [ -z "$effective_format" ]; then
	effective_format="md"
	for arg in "$@"; do
		case "$arg" in
		http://* | https://*) ;;
		*)
			effective_format="pdf"
			break
			;;
		esac
	done
fi

case "$effective_format" in
pdf | confluence)
	src_ext="md"
	src_label="Markdown (.md)"
	;;
md)
	src_ext="confluence"
	src_label="Confluence Storage Format (.confluence)"
	;;
*)
	echo "ERROR: Unknown --format: '$effective_format' (expected pdf, confluence, or md)"
	usage
	exit 1
	;;
esac

if [ -n "$css_file" ] && [ "$effective_format" != "pdf" ]; then
	echo "ERROR: --css-file is only valid with --format pdf (got --format $effective_format)"
	exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
	echo "ERROR: 'docker' is not installed or not on PATH."
	exit 1
fi

# 'docker' being on PATH doesn't mean the daemon behind it is reachable (Docker
# Desktop not started, the service stopped, ...); without this, that case falls
# through to whatever raw error the eventual 'docker run' happens to print.
if ! docker info >/dev/null 2>&1; then
	echo "ERROR: Docker is installed, but the daemon isn't running (or not reachable). Start Docker Desktop (or the Docker service) and try again."
	exit 1
fi

# The image reads Confluence credentials from the environment only, so they are
# forwarded by name: passing them as -e VAR=value would expose the API token in
# the process list. ATLASSIAN_* is accepted as an alias for either.
if [ -z "${CONFLUENCE_EMAIL:-}" ] && [ -n "${ATLASSIAN_EMAIL:-}" ]; then
	export CONFLUENCE_EMAIL="$ATLASSIAN_EMAIL"
fi
if [ -z "${CONFLUENCE_API_TOKEN:-}" ] && [ -n "${ATLASSIAN_API_TOKEN:-}" ]; then
	export CONFLUENCE_API_TOKEN="$ATLASSIAN_API_TOKEN"
fi

env_args=()
# PUBLISH_MD_PDF_ALLOW_INSECURE lets the image fetch over plain http, for a
# local test server; it is forwarded so it can be set without editing this.
for var in CONFLUENCE_EMAIL CONFLUENCE_API_TOKEN PUBLISH_MD_PDF_ALLOW_INSECURE; do
	[ -n "${!var:-}" ] && env_args+=(-e "$var")
done

# The container only sees paths under bind-mounted directories. $PWD is always
# mounted at /workspace (matching the image's own documented CLI usage); any
# input file, --output-dir, or --css-file that resolves outside $PWD gets its
# own extra bind mount, one per distinct host directory.
mounts=(-v "$PWD:/workspace")
# Host directories outside $PWD, in the order they were first seen: index N is
# bind-mounted at /mnt/extra-N.
extra_hosts=()

# Both helpers set $_container_path rather than echo it: they must run in the
# current shell (not a $(...) subshell) so their mounts/extra_hosts side effects
# aren't silently discarded.
container_dir_for() {
	local host_dir="$1" i
	case "$host_dir" in
	"$PWD")
		_container_path="/workspace"
		return
		;;
	"$PWD"/*)
		_container_path="/workspace${host_dir#"$PWD"}"
		return
		;;
	esac

	for i in "${!extra_hosts[@]}"; do
		if [ "${extra_hosts[$i]}" = "$host_dir" ]; then
			_container_path="/mnt/extra-$i"
			return
		fi
	done
	extra_hosts+=("$host_dir")
	i=$((${#extra_hosts[@]} - 1))
	mounts+=(-v "$host_dir:/mnt/extra-$i")
	_container_path="/mnt/extra-$i"
}

container_path_for() {
	local host_path="$1"
	local host_dir base
	host_dir="$(cd "$(dirname "$host_path")" && pwd)"
	base="$(basename "$host_path")"
	container_dir_for "$host_dir"
	_container_path="$_container_path/$base"
}

args=()

[ -n "$format" ] && args+=(--format "$format")
if [ -n "$output_dir" ]; then
	mkdir -p "$output_dir"
	container_dir_for "$(cd "$output_dir" && pwd)"
	args+=(--output-dir "$_container_path")
fi
[ -n "$output_name" ] && args+=(--output-name "$output_name")
if [ -n "$css_file" ]; then
	if [ ! -f "$css_file" ]; then
		echo "ERROR: CSS file not found: $css_file"
		exit 1
	fi
	container_path_for "$css_file"
	args+=(--css-file "$_container_path")
fi
[ "$no_attachments" -eq 1 ] && args+=(--no-attachments)

for input in "$@"; do
	# URLs are passed through untouched: the image fetches them itself.
	case "$input" in
	http://* | https://*)
		args+=("$input")
		continue
		;;
	esac

	if [ ! -f "$input" ]; then
		echo "ERROR: File not found: $input"
		exit 1
	fi
	if [ "${input##*.}" != "$src_ext" ]; then
		echo "ERROR: Not a $src_label file: $input"
		exit 1
	fi
	container_path_for "$input"
	args+=("$_container_path")
done

# The image's own INFO/ERROR messages report paths as it sees them inside the
# container (e.g. "/workspace/foo.pdf", "/mnt/extra-0/bar.css"), which is
# confusing on the host. Translate them back to host paths before printing.
sed_quote() {
	printf '%s' "$1" | sed -e 's/[\\|&.*^$[]/\\&/g'
}

# Highest index first, so "/mnt/extra-1" can't eat the prefix of "/mnt/extra-10".
sed_script=""
for ((i = ${#extra_hosts[@]} - 1; i >= 0; i--)); do
	sed_script="$sed_script s|$(sed_quote "/mnt/extra-$i")|$(sed_quote "${extra_hosts[$i]}")|g;"
done
sed_script="$sed_script s|$(sed_quote "/workspace")|$(sed_quote "$PWD")|g"

# The image always runs as root (the GitHub Action needs that), which would
# leave root-owned output in the bind mount. HOME=/tmp is what lets Puppeteer
# render Mermaid diagrams under a UID that has no /etc/passwd entry.
set -o pipefail
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
	"${env_args[@]}" "${mounts[@]}" "$IMAGE" "${args[@]}" 2>&1 |
	sed -u -e "$sed_script"
exit "${PIPESTATUS[0]}"

# EOF

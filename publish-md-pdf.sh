#!/bin/bash
# ==========================================================
# Convert Markdown to A4-sized PDF or Confluence Storage Format, and
# Confluence Storage Format back to Markdown. An input may also be a
# Confluence Cloud page URL, fetched via the REST API instead of read
# from disk.
#
# This is the single entry point for every conversion this tool performs;
# --format selects which one. The GitHub Action reaches the same flags via
# entrypoint.sh, which only translates INPUT_* environment variables.
#
# Requires: pandoc (all formats), weasyprint (--format pdf only),
#   curl + jq (only when an input is a URL)
#   sudo apt-get install -y pandoc weasyprint curl jq
# ==========================================================

set -e
# set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/convert-pdf.sh
source "$SCRIPT_DIR/lib/convert-pdf.sh"
# shellcheck source=lib/convert-confluence.sh
source "$SCRIPT_DIR/lib/convert-confluence.sh"
# shellcheck source=lib/convert-md.sh
source "$SCRIPT_DIR/lib/convert-md.sh"
# shellcheck source=lib/fetch-confluence.sh
source "$SCRIPT_DIR/lib/fetch-confluence.sh"

usage() {
	echo "Usage: $0 [--format FORMAT] [--output-dir DIR] [--output-name NAME] [--css-file FILE] <file|url> [file2|url2 ...]"
	echo "Converts each input file (or fetched Confluence page) to the requested FORMAT."
	echo
	echo "  --format FORMAT     Conversion to perform (default: pdf; default: md if every"
	echo "                      input is a URL):"
	echo "                        pdf         Markdown (.md) to A4-sized PDF"
	echo "                        confluence  Markdown (.md) to Confluence Storage Format"
	echo "                        md          Confluence Storage Format to Markdown"
	echo "                      --to is accepted as an alias for --format."
	echo "  --output-dir DIR    Directory to write the output file(s) into (default: \$PWD)"
	echo "  --output-name NAME  Filename for the output (default: derived from the input"
	echo "                      filename, or the fetched page's title); only valid when"
	echo "                      converting a single input"
	echo "  --css-file FILE     Stylesheet to use (default: publish-md-pdf.css); only valid"
	echo "                      with --format pdf. A custom stylesheet should keep the"
	echo "                      .task-checkbox rules from the default one to render task lists"
	echo "  --no-attachments    Don't download the attachments of a fetched Confluence page."
	echo "                      Image and file references are still rewritten, but point at"
	echo "                      files that were never downloaded"
	echo
	echo "An input starting with http:// or https:// is fetched as a Confluence Cloud page"
	echo "(see docs/confluence-authentication.md for the required CONFLUENCE_EMAIL and"
	echo "CONFLUENCE_API_TOKEN environment variables), instead of being read as a file."
}

format="pdf"
format_given=0
output_dir="$PWD"
output_name=""
css_file="$SCRIPT_DIR/publish-md-pdf.css"
css_file_given=0
fetch_attachments=1

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
		format_given=1
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
		css_file_given=1
		shift 2
		;;
	--no-attachments)
		fetch_attachments=0
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

# A fetched Confluence page's native format is Confluence Storage Format, so
# when every remaining input is a URL and --format wasn't given explicitly,
# "md" (fetch and convert to Markdown) is the more useful default than "pdf".
# A mix of files and URLs keeps the "pdf" default, and the URL input(s) get
# bridged through md on their way to pdf (see the conversion loop below).
if [ "$format_given" -eq 0 ] && [ $# -gt 0 ]; then
	all_urls=1
	for arg in "$@"; do
		if ! is_url "$arg"; then
			all_urls=0
			break
		fi
	done
	if [ "$all_urls" -eq 1 ]; then
		format="md"
	fi
fi

# Each format declares what it consumes and what it produces, so the
# conversion loop below stays format-agnostic.
case "$format" in
pdf)
	src_ext="md"
	src_label="Markdown (.md)"
	dst_ext="pdf"
	;;
confluence)
	src_ext="md"
	src_label="Markdown (.md)"
	dst_ext="confluence"
	;;
md)
	src_ext="confluence"
	src_label="Confluence Storage Format (.confluence)"
	dst_ext="md"
	;;
*)
	echo "ERROR: Unknown --format: '$format' (expected pdf, confluence, or md)"
	usage
	exit 1
	;;
esac

if [ $# -eq 0 ]; then
	usage
	exit 1
fi
if [ -n "$output_name" ] && [ $# -gt 1 ]; then
	echo "ERROR: --output-name can only be used with a single input file"
	exit 1
fi
if [ "$css_file_given" -eq 1 ] && [ "$format" != "pdf" ]; then
	echo "ERROR: --css-file is only valid with --format pdf (got --format $format)"
	exit 1
fi

has_url_input=0
for arg in "$@"; do
	if is_url "$arg"; then
		has_url_input=1
		break
	fi
done

mkdir -p "$output_dir"
"convert_${format}_init"
if [ "$has_url_input" -eq 1 ]; then
	confluence_fetch_init
	# pdf/confluence bridge a fetched page through convert_md_file (see below);
	# format "md" already declared convert_md_init above via convert_${format}_init.
	if [ "$format" != "md" ]; then
		convert_md_init
	fi
fi

for input_file in "$@"; do
	if is_url "$input_file"; then
		confluence_tmp="$(mktemp --suffix=.confluence)"
		register_cleanup "$confluence_tmp"

		echo "INFO: Fetching $input_file"
		confluence_fetch_page "$input_file" "$confluence_tmp"
		slug="$(confluence_slug "$CONFLUENCE_FETCH_TITLE" "$CONFLUENCE_FETCH_PAGE_ID")"

		# Reset per input, so a second page's images can't inherit the first
		# page's attachment directory.
		CONFLUENCE_ATTACHMENT_PREFIX=""
		CONFLUENCE_ATTACHMENT_MAP=()

		case "$format" in
		confluence)
			# Already Confluence Storage Format -- write the fetched body as-is
			# rather than round-tripping it through md, which would be lossy.
			# Attachments are deliberately NOT downloaded here: the body still
			# references them as ri:attachment/ri:filename, which is exactly
			# what a real Confluence page looks like, so re-uploading this file
			# elsewhere keeps working the way it always did. Only --format md
			# and --format pdf resolve those references locally.
			out_name="$(resolve_output_name "$slug.confluence" confluence confluence "$output_name")"
			out_file="$output_dir/$out_name"
			# cat > rather than cp, so $out_file gets the umask-based mode every
			# other output in this tool gets, instead of inheriting mktemp's 0600.
			cat "$confluence_tmp" >"$out_file"
			;;
		md)
			out_name="$(resolve_output_name "$slug.confluence" confluence md "$output_name")"
			out_file="$output_dir/$out_name"
			# Attachments land in a directory named after the Markdown file and
			# are referenced relatively, so the two move together.
			if [ "$fetch_attachments" -eq 1 ]; then
				CONFLUENCE_ATTACHMENT_PREFIX="${out_name%.md}-attachments"
				confluence_fetch_attachments "$CONFLUENCE_FETCH_BASE" "$CONFLUENCE_FETCH_PAGE_ID" \
					"$output_dir/$CONFLUENCE_ATTACHMENT_PREFIX"
			fi
			convert_md_file "$confluence_tmp" "$out_file"
			confluence_fetch_prepend_front_matter "$out_file"
			;;
		pdf)
			# WeasyPrint embeds image data into the PDF, so the downloads are
			# only needed while rendering: everything goes in one temp directory
			# that convert_pdf_file resolves relative paths against (via pandoc's
			# --resource-path and WeasyPrint's --base-url, both the bridge file's
			# own directory) and the cleanup trap removes. The result is a
			# self-contained PDF with no stray files left in the output directory.
			bridge_dir="$(mktemp -d)"
			register_cleanup "$bridge_dir"
			md_tmp="$bridge_dir/page.md"
			if [ "$fetch_attachments" -eq 1 ]; then
				CONFLUENCE_ATTACHMENT_PREFIX="assets"
				confluence_fetch_attachments "$CONFLUENCE_FETCH_BASE" "$CONFLUENCE_FETCH_PAGE_ID" \
					"$bridge_dir/assets"
			fi
			convert_md_file "$confluence_tmp" "$md_tmp"
			confluence_fetch_prepend_front_matter "$md_tmp"
			out_name="$(resolve_output_name "$slug.md" md pdf "$output_name")"
			out_file="$output_dir/$out_name"
			convert_pdf_file "$md_tmp" "$out_file"
			;;
		esac

		echo "INFO: Fetched $input_file (\"$CONFLUENCE_FETCH_TITLE\") -> $out_file"
		echo "INFO: Wrote $out_file ($(du -h "$out_file" | cut -f1))"
		continue
	fi

	require_file_with_ext "$input_file" "$src_ext" "$src_label"
	out_name="$(resolve_output_name "$input_file" "$src_ext" "$dst_ext" "$output_name")"
	out_file="$output_dir/$out_name"

	echo "INFO: Converting $input_file -> $out_file"
	"convert_${format}_file" "$input_file" "$out_file"
	echo "INFO: Wrote $out_file ($(du -h "$out_file" | cut -f1))"
done

# EOF

#!/bin/bash
# ==========================================================
# Convert Markdown to A4-sized PDF or Confluence Storage Format, and
# Confluence Storage Format back to Markdown.
#
# This is the single entry point for every conversion this tool performs;
# --format selects which one. The GitHub Action reaches the same flags via
# entrypoint.sh, which only translates INPUT_* environment variables.
#
# Requires: pandoc (all formats), weasyprint (--format pdf only)
#   sudo apt-get install -y pandoc weasyprint
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

usage() {
	echo "Usage: $0 [--format FORMAT] [--output-dir DIR] [--output-name NAME] [--css-file FILE] <file> [file2 ...]"
	echo "Converts each input file to the requested FORMAT."
	echo
	echo "  --format FORMAT     Conversion to perform (default: pdf):"
	echo "                        pdf         Markdown (.md) to A4-sized PDF"
	echo "                        confluence  Markdown (.md) to Confluence Storage Format"
	echo "                        md          Confluence Storage Format to Markdown"
	echo "                      --to is accepted as an alias for --format."
	echo "  --output-dir DIR    Directory to write the output file(s) into (default: \$PWD)"
	echo "  --output-name NAME  Filename for the output (default: derived from the input"
	echo "                      filename); only valid when converting a single input file"
	echo "  --css-file FILE     Stylesheet to use (default: publish-md-pdf.css); only valid"
	echo "                      with --format pdf. A custom stylesheet should keep the"
	echo "                      .task-checkbox rules from the default one to render task lists"
}

format="pdf"
output_dir="$PWD"
output_name=""
css_file="$SCRIPT_DIR/publish-md-pdf.css"
css_file_given=0

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
		css_file_given=1
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

mkdir -p "$output_dir"
"convert_${format}_init"

for input_file in "$@"; do
	require_file_with_ext "$input_file" "$src_ext" "$src_label"
	out_name="$(resolve_output_name "$input_file" "$src_ext" "$dst_ext" "$output_name")"
	out_file="$output_dir/$out_name"

	echo "INFO: Converting $input_file -> $out_file"
	"convert_${format}_file" "$input_file" "$out_file"
	echo "INFO: Wrote $out_file ($(du -h "$out_file" | cut -f1))"
done

# EOF

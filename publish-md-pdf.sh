#!/bin/bash
# ==========================================================
# Publish one or more Markdown files as A4-sized PDF
#
# Requires: pandoc, weasyprint
#   sudo apt-get install -y pandoc weasyprint
#
# Usage: scripts/publish-md-pdf.sh [--output-dir DIR] [--output-name NAME] [--css-file FILE] <file.md> [file2.md ...]
# By default each <file>.md is rendered to <file>.pdf in $PWD; use --output-dir
# and/or --output-name to write elsewhere or under a different name. Use
# --css-file to use a different stylesheet than publish-md-pdf.css.
# ==========================================================

set -e
# set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cli-common.sh
source "$SCRIPT_DIR/cli-common.sh"

usage() {
	echo "Usage: $0 [--output-dir DIR] [--output-name NAME] [--css-file FILE] <file.md> [file2.md ...]"
	echo "Converts each Markdown file to an A4-sized PDF."
	echo
	echo "  --output-dir DIR    Directory to write the PDF(s) into (default: \$PWD)"
	echo "  --output-name NAME  Filename for the PDF (default: <file>.pdf); only"
	echo "                      valid when converting a single input file"
	echo "  --css-file FILE     Stylesheet to use (default: publish-md-pdf.css); a"
	echo "                      custom stylesheet should keep the .task-checkbox"
	echo "                      rules from the default one to render task lists"
}

css_file="$SCRIPT_DIR/publish-md-pdf.css"

# --css-file is only used by this script, so pull it out before handing the
# rest of the flags to the parser shared with md-to-confluence.sh /
# confluence-to-md.sh.
remaining=()
while [ $# -gt 0 ]; do
	if [ "$1" = "--css-file" ]; then
		[ $# -ge 2 ] || {
			echo "ERROR: --css-file requires an argument"
			exit 1
		}
		css_file="$2"
		shift 2
	else
		remaining+=("$1")
		shift
	fi
done

parse_common_flags "${remaining[@]}"

if [ ! -f "$css_file" ]; then
	echo "ERROR: CSS file not found: $css_file"
	exit 1
fi

for cmd in pandoc weasyprint; do
	require_command "$cmd" "sudo apt-get install -y pandoc weasyprint"
done

mkdir -p "$output_dir"

# ```mermaid fenced code blocks are rendered as actual diagrams (via
# mermaid-filter.lua, which shells out to mermaid-cli's `mmdc`) when `mmdc` is
# available; otherwise they fall back to rendering as plain code, unchanged
# from before this feature existed.
pandoc_extra_args=()
if command -v mmdc >/dev/null 2>&1; then
	mermaid_tmp_dir="$(mktemp -d)"
	trap 'rm -rf "$mermaid_tmp_dir"' EXIT
	export PUBLISH_MD_PDF_MERMAID_TMPDIR="$mermaid_tmp_dir"
	export PUBLISH_MD_PDF_MERMAID_PUPPETEER_CONFIG="$SCRIPT_DIR/mermaid-puppeteer-config.json"
	pandoc_extra_args=(--lua-filter="$SCRIPT_DIR/mermaid-filter.lua")
else
	echo "INFO: 'mmdc' not found; \`\`\`mermaid code blocks will render as plain code"
fi

for md_file in "${remaining_args[@]}"; do
	require_file_with_ext "$md_file" md "Markdown (.md)"
	pdf_name="$(resolve_output_name "$md_file" md pdf "$output_name")"
	pdf_file="$output_dir/$pdf_name"
	tmp_html="$(mktemp --suffix=.html)"

	echo "INFO: Converting $md_file -> $pdf_file"

	# pandoc renders GFM task-list checkboxes as native <input type="checkbox">
	# elements, whose checked/unchecked appearance WeasyPrint cannot restyle
	# (it always fills a checked box solid black). Render to HTML first, then
	# swap those inputs for <span> markers styled by publish-md-pdf.css.
	#
	# --no-highlight disables pandoc's syntax highlighting. Its default
	# highlighting CSS gives each code line a hanging indent
	# (text-indent: -5em; padding-left: 5em) that browsers cancel to zero but
	# WeasyPrint does not, leaving every code line shoved ~5em to the right.
	# Disabling it renders plain <pre><code>, matching the VS Code preview.
	if ! pandoc_output=$(pandoc "$md_file" \
		--from=gfm \
		--to=html5 \
		--standalone \
		--wrap=none \
		--no-highlight \
		--css="$css_file" \
		--resource-path="$(dirname "$md_file")" \
		"${pandoc_extra_args[@]}" \
		-o "$tmp_html" 2>&1); then
		echo "$pandoc_output"
		echo "ERROR: pandoc failed to convert $md_file"
		rm -f "$tmp_html"
		exit 1
	fi
	echo "$pandoc_output" | grep -v "Defaulting to .* as the title\|To specify a title," || true

	sed -i \
		-e 's/<input type="checkbox" checked="" \/>/<span class="task-checkbox checked"><\/span>/g' \
		-e 's/<input type="checkbox" \/>/<span class="task-checkbox"><\/span>/g' \
		"$tmp_html"

	if ! weasyprint_output=$(weasyprint "$tmp_html" "$pdf_file" \
		--base-url "$(dirname "$md_file")" 2>&1); then
		echo "$weasyprint_output"
		echo "ERROR: weasyprint failed to render $md_file"
		rm -f "$tmp_html"
		exit 1
	fi

	rm -f "$tmp_html"
	echo "INFO: Wrote $pdf_file ($(du -h "$pdf_file" | cut -f1))"
done

# EOF

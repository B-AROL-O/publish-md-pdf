#!/bin/bash
# ==========================================================
# Conversion module: Markdown -> A4-sized PDF,
# via pandoc + WeasyPrint.
#
# Sourced by publish-md-pdf.sh; not meant to be run directly.
# Reads $css_file and $SCRIPT_DIR from the caller.
# ==========================================================

# One-time setup: verify the tools this format needs, and decide whether
# Mermaid diagrams can be rendered.
convert_pdf_init() {
	local cmd
	for cmd in pandoc weasyprint; do
		require_command "$cmd" "sudo apt-get install -y pandoc weasyprint"
	done

	# shellcheck disable=SC2154 # $css_file is set by the sourcing publish-md-pdf.sh
	if [ ! -f "$css_file" ]; then
		echo "ERROR: CSS file not found: $css_file"
		exit 1
	fi

	# ```mermaid fenced code blocks are rendered as actual diagrams (via
	# mermaid-filter.lua, which shells out to mermaid-cli's `mmdc`) when `mmdc`
	# is available; otherwise they fall back to rendering as plain code.
	pdf_pandoc_extra_args=()
	if command -v mmdc >/dev/null 2>&1; then
		pdf_mermaid_tmp_dir="$(mktemp -d)"
		register_cleanup "$pdf_mermaid_tmp_dir"
		export PUBLISH_MD_PDF_MERMAID_TMPDIR="$pdf_mermaid_tmp_dir"
		export PUBLISH_MD_PDF_MERMAID_PUPPETEER_CONFIG="$SCRIPT_DIR/mermaid-puppeteer-config.json"
		pdf_pandoc_extra_args=(--lua-filter="$SCRIPT_DIR/mermaid-filter.lua")
	else
		echo "INFO: 'mmdc' not found; \`\`\`mermaid code blocks will render as plain code"
	fi
}

convert_pdf_file() {
	local md_file="$1" pdf_file="$2"
	local tmp_html pandoc_output weasyprint_output
	tmp_html="$(mktemp --suffix=.html)"

	# pandoc renders GFM task-list checkboxes as native <input type="checkbox">
	# elements. WeasyPrint doesn't give a form control any default box to
	# begin with, so left alone one renders as nothing visible at all --
	# not even an unstyled checkbox, just the item's text with no marker in
	# front of it. Render to HTML first, then swap those inputs for <span>
	# markers styled by publish-md-pdf.css.
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
		"${pdf_pandoc_extra_args[@]}" \
		-o "$tmp_html" 2>&1); then
		echo "$pandoc_output"
		echo "ERROR: pandoc failed to convert $md_file"
		rm -f "$tmp_html"
		exit 1
	fi
	echo "$pandoc_output" | grep -v "Defaulting to .* as the title\|To specify a title," || true

	# pandoc always marks a task-list checkbox disabled="" (it's never meant to
	# be interactive in rendered output), on both the checked and unchecked
	# shape -- verified directly against pandoc 2.17.1.1, this image's own
	# base. The checked pattern has to run first: it's the more specific of
	# the two, and the unchecked one would otherwise match its leading
	# "disabled=\"\" " and leave a dangling " checked=\"\" />" behind.
	sed -i \
		-e 's/<input type="checkbox" disabled="" checked="" \/>/<span class="task-checkbox checked"><\/span>/g' \
		-e 's/<input type="checkbox" disabled="" \/>/<span class="task-checkbox"><\/span>/g' \
		"$tmp_html"

	if ! weasyprint_output=$(weasyprint "$tmp_html" "$pdf_file" \
		--base-url "$(dirname "$md_file")" 2>&1); then
		echo "$weasyprint_output"
		echo "ERROR: weasyprint failed to render $md_file"
		rm -f "$tmp_html"
		exit 1
	fi

	rm -f "$tmp_html"
}

# EOF

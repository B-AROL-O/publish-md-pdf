#!/bin/bash
# ==========================================================
# Conversion module: Markdown -> Confluence Storage Format (the XHTML-based
# fragment the Confluence REST API expects in its body.storage.value field).
#
# Sourced by publish-md-pdf.sh; not meant to be run directly.
# ==========================================================

convert_confluence_apos="'"

convert_confluence_init() {
	require_command pandoc "sudo apt-get install -y pandoc"
}

# Rewrites the raw text captured from a pandoc <pre><code> block into a
# Confluence "code" structured macro: un-escape the HTML entities pandoc
# used, then re-escape a literal "]]>" so it can't terminate the CDATA
# section early (the standard "split the CDATA" trick).
convert_confluence_emit_macro() {
	local lang="$1" text="$2"
	text="${text//&lt;/<}"
	text="${text//&gt;/>}"
	text="${text//&quot;/\"}"
	text="${text//&#39;/$convert_confluence_apos}"
	text="${text//&amp;/\&}"
	text="${text//]]>/]]]]><![CDATA[>}"

	printf '<ac:structured-macro ac:name="code" ac:schema-version="1">'
	if [ -n "$lang" ]; then
		printf '<ac:parameter ac:name="language">%s</ac:parameter>' "$lang"
	fi
	printf '<ac:plain-text-body><![CDATA[%s]]></ac:plain-text-body></ac:structured-macro>\n' "$text"
}

# Streams a pandoc HTML5 fragment, rewriting each <pre[ class="LANG"]><code>...
# </code></pre> block (pandoc's shape for a fenced code block) into a
# Confluence code macro. pandoc always keeps the opening tag and the first
# content line on one line, and appends the closing tag directly to the last
# content line with no newline in between, so both ends are detected with a
# single line-oriented scan.
convert_confluence_code_blocks() {
	local html_file="$1"
	local in_code=0 lang="" buf="" line rest

	while IFS='' read -r line || [ -n "$line" ]; do
		if [ "$in_code" -eq 0 ]; then
			if [[ "$line" =~ ^\<pre(\ class=\"([^\"]*)\")?\>\<code\>(.*)$ ]]; then
				lang="${BASH_REMATCH[2]}"
				rest="${BASH_REMATCH[3]}"
				if [[ "$rest" == *"</code></pre>" ]]; then
					convert_confluence_emit_macro "$lang" "${rest%</code></pre>}"
				else
					in_code=1
					buf="$rest"
				fi
				continue
			fi
			printf '%s\n' "$line"
			continue
		fi

		if [[ "$line" == *"</code></pre>" ]]; then
			buf+=$'\n'"${line%</code></pre>}"
			convert_confluence_emit_macro "$lang" "$buf"
			in_code=0
			buf=""
		else
			buf+=$'\n'"$line"
		fi
	done <"$html_file"
}

convert_confluence_file() {
	local md_file="$1" out_file="$2"
	local tmp_html pandoc_output
	tmp_html="$(mktemp --suffix=.html)"

	if ! pandoc_output=$(pandoc "$md_file" \
		--from=gfm \
		--to=html5 \
		--wrap=none \
		--no-highlight \
		--resource-path="$(dirname "$md_file")" \
		-o "$tmp_html" 2>&1); then
		echo "$pandoc_output"
		echo "ERROR: pandoc failed to convert $md_file"
		rm -f "$tmp_html"
		exit 1
	fi
	echo "$pandoc_output" | grep -v "Defaulting to .* as the title\|To specify a title," || true

	# Confluence Storage Format has no native checkbox input element; use the
	# same ballot-box characters pandoc's own gfm writer recognizes as GFM
	# task-list markers, so the reverse conversion can turn them straight
	# back into "- [x]" / "- [ ]" syntax. pandoc always marks a task-list
	# checkbox disabled="" (checked or not) -- verified directly against
	# pandoc 2.17.1.1, this image's own base -- so the checked pattern has to
	# match that too, and has to run first: it's the more specific of the two,
	# and the unchecked one would otherwise match its leading
	# "disabled=\"\" " and leave a dangling " checked=\"\" />" as literal text.
	sed -i \
		-e 's/<input type="checkbox" disabled="" checked="" \/>/☒ /g' \
		-e 's/<input type="checkbox" disabled="" \/>/☐ /g' \
		"$tmp_html"

	# pandoc's own html5 output puts the item's text on the line *after* the
	# checkbox input, not the same line; once that input is gone, that leaves
	# a line that's nothing but the ballot-box marker, followed by a separate
	# line holding the item's text. Reading that back (lib/convert-md.sh) is
	# exactly the reverse conversion the comment above promises, but pandoc's
	# marker-recognizing heuristic only fires when the marker and the text
	# it labels share one line -- verified directly: the same input with this
	# join removed comes back as literal "☒ Do the thing" text, not "- [x]
	# Do the thing". Joining them here, once, is simpler than requiring every
	# consumer of this format to tolerate both shapes.
	sed -i -E '/[☒☐] $/{N;s/\n//}' "$tmp_html"

	convert_confluence_code_blocks "$tmp_html" >"$out_file"
	rm -f "$tmp_html"
}

# EOF

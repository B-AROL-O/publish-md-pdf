#!/bin/bash
# ==========================================================
# Conversion module: Confluence Storage Format -> Markdown.
# The reverse of lib/convert-confluence.sh.
#
# Sourced by publish-md-pdf.sh; not meant to be run directly.
# ==========================================================

convert_md_init() {
	require_command pandoc "sudo apt-get install -y pandoc"
}

# Reverses convert_confluence_emit_macro()'s CDATA-split and entity escaping,
# then re-escapes the raw code text as HTML so pandoc's HTML reader turns it
# back into a real fenced code block.
convert_md_emit_code_block() {
	local lang="$1" text="$2"
	text="${text//]]]]><![CDATA[>/]]>}"
	text="${text//&/\&amp;}"
	text="${text//</\&lt;}"
	text="${text//>/\&gt;}"

	if [ -n "$lang" ]; then
		printf '<pre class="%s"><code>%s</code></pre>\n' "$lang" "$text"
	else
		printf '<pre><code>%s</code></pre>\n' "$text"
	fi
}

# Streams a Confluence Storage Format fragment, rewriting each "code"
# structured macro back into a plain <pre><code> block pandoc's HTML reader
# understands. Mirrors convert_confluence_code_blocks(): the opening tag and
# the first content line share a line, and the closing tags are appended
# directly to the last content line.
convert_md_restore_code_blocks() {
	local in_code=0 lang="" buf="" line rest

	while IFS='' read -r line || [ -n "$line" ]; do
		if [ "$in_code" -eq 0 ]; then
			if [[ "$line" =~ ^\<ac:structured-macro\ ac:name=\"code\"\ ac:schema-version=\"1\"\>(\<ac:parameter\ ac:name=\"language\"\>([^\<]*)\</ac:parameter\>)?\<ac:plain-text-body\>\<!\[CDATA\[(.*)$ ]]; then
				lang="${BASH_REMATCH[2]}"
				rest="${BASH_REMATCH[3]}"
				if [[ "$rest" == *"]]></ac:plain-text-body></ac:structured-macro>" ]]; then
					convert_md_emit_code_block "$lang" "${rest%]]></ac:plain-text-body></ac:structured-macro>}"
				else
					in_code=1
					buf="$rest"
				fi
				continue
			fi
			# Images and attachment links are rewritten here, on the non-code
			# lines only, so that a literal <ac:image> quoted inside a code
			# macro survives as the code sample it is.
			if [[ "$line" == *"<ac:image"* || "$line" == *"<ac:link"* ]]; then
				line="$(convert_md_rewrite_objects "$line")"
			fi
			printf '%s\n' "$line"
			continue
		fi

		if [[ "$line" == *"]]></ac:plain-text-body></ac:structured-macro>" ]]; then
			buf+=$'\n'"${line%]]></ac:plain-text-body></ac:structured-macro>}"
			convert_md_emit_code_block "$lang" "$buf"
			in_code=0
			buf=""
		else
			buf+=$'\n'"$line"
		fi
	done <"$1"
}

# Pulls a double-quoted attribute value out of an element's raw text.
# Confluence writes storage-format attributes in a canonical double-quoted
# form, so there's no single-quoted variant to handle.
convert_md_attr() {
	local hay="$1" attr="$2"
	if [[ "$hay" =~ $attr=\"([^\"]*)\" ]]; then
		xml_unescape_attr "${BASH_REMATCH[1]}"
	fi
}

# The raw inner XHTML of the first <NAME ...>...</NAME> child in $1, or
# nothing when the element isn't present.
convert_md_element_body() {
	local hay="$1" name="$2" body
	case "$hay" in
	*"<$name>"* | *"<$name "*) ;;
	*) return 0 ;;
	esac
	case "$hay" in
	*"</$name>"*) ;;
	*) return 0 ;;
	esac
	body="${hay#*<"$name"}"
	body="${body#*>}"
	body="${body%%"</$name>"*}"
	printf '%s' "$body"
}

# The local path an attachment reference resolves to: the sanitized basename
# the downloader stored it under, inside the directory it downloaded into.
# With an empty map and prefix -- a .confluence file converted straight off
# disk, where there was never anything to download -- this degrades to a bare
# filename relative to that file. A reference that doesn't resolve is still
# better than the silently dropped image this replaces.
convert_md_attachment_path() {
	local filename="$1" safe
	safe="${CONFLUENCE_ATTACHMENT_MAP[$filename]:-}"
	if [ -z "$safe" ]; then
		safe="$(confluence_safe_basename "$filename" "attachment")"
	fi
	if [ -n "$CONFLUENCE_ATTACHMENT_PREFIX" ]; then
		printf '%s/%s' "$CONFLUENCE_ATTACHMENT_PREFIX" "$safe"
	else
		printf '%s' "$safe"
	fi
}

# A <ac:caption> body is almost always a single Confluence-authored
# paragraph ("<p>Fig 1: ...</p>"); unwrap that outer <p> so it can be
# re-wrapped in <em> without nesting a block element inside an inline one.
# Left as-is (rare, but simpler and still valid HTML) for anything that
# isn't exactly one paragraph -- multiple paragraphs, or no <p> at all.
convert_md_caption_text() {
	local text="$1" inner
	case "$text" in
	'<p>'*'</p>')
		inner="${text#<p>}"
		inner="${inner%</p>}"
		case "$inner" in
		*'<p>'* | *'</p>'*) printf '%s' "$text" ;;
		*) printf '%s' "$inner" ;;
		esac
		;;
	*) printf '%s' "$text" ;;
	esac
}

# Renders one <ac:image> as HTML. Fails (leaving the original untouched) for
# an image with neither an attachment nor a URL behind it.
convert_md_emit_image() {
	local elem="$1" filename url caption src alt
	filename="$(convert_md_attr "$elem" 'ri:filename')"
	url="$(convert_md_attr "$elem" 'ri:value')"
	caption="$(convert_md_element_body "$elem" 'ac:caption')"

	if [ -n "$filename" ]; then
		src="$(convert_md_attachment_path "$filename")"
		alt="$filename"
	elif [ -n "$url" ]; then
		# An <ri:url> image lives on some other host and needs no credentials,
		# so it's left pointing there rather than downloaded -- the same thing
		# this tool already does with a remote image in a plain .md file.
		src="$url"
		alt=""
	else
		return 1
	fi

	# ac:width/ac:height are deliberately dropped: publish-md-pdf.css caps
	# images at max-width:100% so an oversized screenshot still fits the page,
	# and carrying a width would make pandoc's gfm writer emit a raw <img>
	# tag for every image instead of Markdown image syntax.
	if [ -n "$caption" ]; then
		# An earlier version of this wrapped the image and its caption in
		# <figure>/<figcaption>, betting on pandoc's HTML reader keeping that
		# intact as a raw block through the gfm round trip. It doesn't: on
		# pandoc 2.x (what Debian bookworm -- this project's own base image --
		# actually ships) that shape is read as an Image-with-caption AST node
		# and the gfm writer, which has no Markdown syntax for a captioned
		# image, collapses it straight back down to a plain image with the
		# caption folded into invisible alt text -- silently reintroducing the
		# exact "caption isn't visible" problem this exists to avoid. An <img>
		# immediately followed by its own <em>-wrapped paragraph carries no
		# such special AST meaning to lose: it's just an image, then a plain
		# emphasized paragraph, verified identical across pandoc 2.17 and 3.1.
		# Self-wrapping both in their own <p> keeps this correct whether or
		# not Confluence had already wrapped the source <ac:image> in one. The
		# span's class is publish-md-pdf.css's hook for styling it visually
		# distinct from body text in the rendered PDF -- verified to survive
		# the round trip as plain HTML, unlike <figure>/<figcaption> above.
		printf '<p><img src="%s" alt="%s" /></p><p><span class="image-caption">%s</span></p>' \
			"$(html_escape_attr "$src")" "$(html_escape_attr "$alt")" \
			"$(convert_md_caption_text "$caption")"
	else
		printf '<img src="%s" alt="%s" />' \
			"$(html_escape_attr "$src")" "$(html_escape_attr "$alt")"
	fi
}

# Renders one <ac:link> as an <a>, but only the attachment-backed kind.
# <ac:link> wrapping <ri:page> is a link to another Confluence page, which has
# no local equivalent, so it's left alone exactly as before.
convert_md_emit_link() {
	local elem="$1" filename text
	filename="$(convert_md_attr "$elem" 'ri:filename')"
	[ -n "$filename" ] || return 1

	text="$(convert_md_element_body "$elem" 'ac:plain-text-link-body')"
	if [ -n "$text" ]; then
		# A plain-text link body is CDATA-wrapped literal text, so it has to be
		# escaped on its way into HTML; <ac:link-body> is already XHTML.
		text="${text#<![CDATA[}"
		text="${text%]]>}"
		text="$(html_escape_attr "$text")"
	else
		text="$(convert_md_element_body "$elem" 'ac:link-body')"
	fi
	[ -n "$text" ] || text="$(html_escape_attr "$filename")"

	printf '<a href="%s">%s</a>' "$(html_escape_attr "$(convert_md_attachment_path "$filename")")" "$text"
}

# Rewrites the storage-format elements that carry visible content -- images
# and attachment links -- into the plain HTML pandoc's reader understands.
# Without this pandoc silently discards them, which is why a page imported
# from Confluence used to lose its images entirely.
#
# This is a scanner rather than a sed pattern for two reasons. A storage body
# straight from the REST API puts the whole page on one line, so several
# objects routinely share a line and a single non-global match won't do. And
# an <ac:image> may wrap an <ac:caption> holding arbitrary XHTML, which a
# "[^<]*" pattern cannot cross while a ".*" one would greedily swallow past
# the element's own end tag. Neither element nests inside itself, so the first
# end tag after a start tag is always the matching one.
convert_md_rewrite_objects() {
	local text="$1"
	local out="" cand prefix best_prefix best_kind best_marker
	local end_marker tail elem rest replacement

	while :; do
		best_kind=""
		best_prefix=""
		best_marker=""
		# Both spellings of each start tag, so that <ac:link-body> -- which
		# shares the "<ac:link" stem -- can never be mistaken for a link.
		for cand in "<ac:image>" "<ac:image " "<ac:link>" "<ac:link "; do
			[[ "$text" == *"$cand"* ]] || continue
			prefix="${text%%"$cand"*}"
			if [ -z "$best_kind" ] || [ "${#prefix}" -lt "${#best_prefix}" ]; then
				best_prefix="$prefix"
				best_marker="$cand"
				case "$cand" in
				"<ac:image"*) best_kind="image" ;;
				*) best_kind="link" ;;
				esac
			fi
		done
		[ -n "$best_kind" ] || break

		if [ "$best_kind" = "image" ]; then
			end_marker="</ac:image>"
		else
			end_marker="</ac:link>"
		fi

		tail="${text#"$best_prefix$best_marker"}"
		# An unterminated element (or a self-closing <ac:image/>, which carries
		# no source to point at anyway): stop rewriting and pass the rest through.
		[[ "$tail" == *"$end_marker"* ]] || break
		elem="${tail%%"$end_marker"*}"
		rest="${tail#*"$end_marker"}"

		if [ "$best_kind" = "image" ]; then
			replacement="$(convert_md_emit_image "$elem")" || replacement=""
		else
			replacement="$(convert_md_emit_link "$elem")" || replacement=""
		fi

		if [ -n "$replacement" ]; then
			out+="$best_prefix$replacement"
		else
			out+="$best_prefix$best_marker$elem$end_marker"
		fi
		text="$rest"
	done

	printf '%s' "$out$text"
}

convert_md_file() {
	local confluence_file="$1" out_file="$2"
	local tmp_html pandoc_output
	tmp_html="$(mktemp --suffix=.html)"

	convert_md_restore_code_blocks "$confluence_file" >"$tmp_html"

	if ! pandoc_output=$(pandoc "$tmp_html" \
		--from=html \
		--to=gfm \
		--wrap=none \
		-o "$out_file" 2>&1); then
		echo "$pandoc_output"
		echo "ERROR: pandoc failed to convert $confluence_file"
		rm -f "$tmp_html"
		exit 1
	fi
	echo "$pandoc_output"

	rm -f "$tmp_html"
}

# EOF

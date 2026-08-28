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
# understands, and each ac:task-list into a plain GFM-style checkbox list
# (see convert_md_emit_task_list). Mirrors convert_confluence_code_blocks():
# the opening tag and the first content line share a line, and the closing
# tags are appended directly to the last content line. ac:task-list gets the
# same cross-line buffering as the code macro, rather than the single-line
# scan convert_md_rewrite_objects uses for images/links/mentions/dates/
# emoticons, because unlike those -- always inline content sharing a line
# with surrounding paragraph text -- a task list is block-level, and nothing
# rules out Confluence formatting each of its ac:task children on its own
# line the way it already does for other block constructs.
convert_md_restore_code_blocks() {
	local in_code=0 lang="" buf="" line rest
	local in_tasklist=0 tasklist_buf=""

	while IFS='' read -r line || [ -n "$line" ]; do
		if [ "$in_tasklist" -eq 1 ]; then
			if [[ "$line" == *"</ac:task-list>"* ]]; then
				tasklist_buf+=$'\n'"${line%%"</ac:task-list>"*}</ac:task-list>"
				convert_md_emit_task_list "$tasklist_buf"
				in_tasklist=0
				tasklist_buf=""
				rest="${line#*"</ac:task-list>"}"
				if [ -n "$rest" ]; then
					if [[ "$rest" == *"<ac:image"* || "$rest" == *"<ac:link"* ||
						"$rest" == *"<ac:emoticon"* || "$rest" == *"<time"* ]]; then
						rest="$(convert_md_rewrite_objects "$rest")"
					fi
					printf '%s\n' "$rest"
				fi
			else
				tasklist_buf+=$'\n'"$line"
			fi
			continue
		fi

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
			# Like the code macro above, an ac:task-list is assumed to start
			# at the beginning of its own line -- a block construct, never
			# sharing a line with preceding paragraph text.
			if [[ "$line" =~ ^\<ac:task-list ]]; then
				if [[ "$line" == *"</ac:task-list>"* ]]; then
					convert_md_emit_task_list "${line%%"</ac:task-list>"*}</ac:task-list>"
					rest="${line#*"</ac:task-list>"}"
					if [ -n "$rest" ]; then
						if [[ "$rest" == *"<ac:image"* || "$rest" == *"<ac:link"* ||
							"$rest" == *"<ac:emoticon"* || "$rest" == *"<time"* ]]; then
							rest="$(convert_md_rewrite_objects "$rest")"
						fi
						printf '%s\n' "$rest"
					fi
				else
					in_tasklist=1
					tasklist_buf="$line"
				fi
				continue
			fi
			# Images, attachment links, mentions, dates and emoticons are
			# rewritten here, on the non-code lines only, so that a literal
			# <ac:image> quoted inside a code macro survives as the code
			# sample it is.
			if [[ "$line" == *"<ac:image"* || "$line" == *"<ac:link"* ||
				"$line" == *"<ac:emoticon"* || "$line" == *"<time"* ]]; then
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

# The same, but left exactly as the storage format wrote it, i.e. not run
# through xml_unescape_attr. ac:emoji-fallback is the reason this exists: it
# can hold a raw HTML numeric character reference ("&#9989;"), and unescaping
# that first would turn the "&" into a literal one, breaking the reference
# pandoc's HTML reader would otherwise have resolved on its own.
convert_md_attr_verbatim() {
	local hay="$1" attr="$2"
	if [[ "$hay" =~ $attr=\"([^\"]*)\" ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
	fi
}

# Decodes JavaScript/JSON-style "\uXXXX" unicode escapes -- including a
# surrogate pair, written as two consecutive escapes -- into the UTF-8 text
# they stand for. Any other text, including a real character or an HTML
# numeric reference, passes through untouched.
#
# This exists because ac:emoji-fallback does not reliably hold either of the
# two things its name suggests (a plain character, or an HTML reference
# pandoc would decode) -- verified against a real Confluence Cloud page,
# where an emoji inserted via the emoji picker (not a legacy ac:name
# emoticon) instead put the *literal nine-to-sixteen ASCII characters* of a
# JS escape sequence in that attribute, e.g. "🗓" for a calendar
# emoji outside the Basic Multilingual Plane -- which is most emoji. Neither
# XML unescaping nor pandoc's HTML reader has any idea what to do with a raw
# "\u"; left alone, it survives into the rendered document as exactly those
# literal backslash-u characters, which is what the fallback exists to
# prevent.
convert_md_decode_js_unicode_escapes() {
	local text="$1" out="" unit high low cp

	while [[ "$text" =~ \\u([0-9A-Fa-f]{4}) ]]; do
		out+="${text%%"${BASH_REMATCH[0]}"*}"
		unit="${BASH_REMATCH[1]}"
		text="${text#*"${BASH_REMATCH[0]}"}"

		# A high surrogate (D800-DBFF) only means something paired with an
		# immediately following low surrogate (DC00-DFFF); an unpaired one is
		# malformed input and is passed through as the sentinel U+FFFD rather
		# than decoded into a bogus codepoint.
		if [[ "$unit" =~ ^[Dd][89ABab] ]]; then
			if [[ "$text" =~ ^\\u([Dd][C-Fc-f][0-9A-Fa-f]{2}) ]]; then
				high="0x$unit"
				low="0x${BASH_REMATCH[1]}"
				text="${text#*"${BASH_REMATCH[0]}"}"
				cp=$((0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)))
			else
				cp=0xFFFD
			fi
		else
			cp="0x$unit"
		fi

		out+="$(convert_md_utf8_char "$cp")"
	done

	printf '%s' "$out$text"
}

# Encodes one Unicode codepoint (numeric, e.g. 0x1f5d3) as its UTF-8 byte
# sequence.
#
# Not done via bash's own \u/\U printf escapes: those depend on the
# process's locale to know how to pack a codepoint into multiple bytes, and
# this Docker image (like most minimal ones) runs with no locale configured
# at all -- verified directly against it, where printf '%b' "\\U0001f5d3" in
# the plain POSIX/C locale it defaults to doesn't decode the escape at all,
# it just prints the literal characters "\U0001F5D3" back out, i.e. exactly
# the bug this function exists to fix, one level down. \xHH, by contrast, is
# bash writing a raw byte value with no locale-aware interpretation involved,
# so encoding the UTF-8 bytes by hand and feeding them to printf '%b' as
# literal \xHH escapes works the same regardless of locale.
convert_md_utf8_char() {
	local cp="$1" out
	if ((cp < 0x80)); then
		printf -v out '\\x%02x' "$cp"
	elif ((cp < 0x800)); then
		printf -v out '\\x%02x\\x%02x' \
			$((0xC0 | (cp >> 6))) \
			$((0x80 | (cp & 0x3F)))
	elif ((cp < 0x10000)); then
		printf -v out '\\x%02x\\x%02x\\x%02x' \
			$((0xE0 | (cp >> 12))) \
			$((0x80 | ((cp >> 6) & 0x3F))) \
			$((0x80 | (cp & 0x3F)))
	else
		printf -v out '\\x%02x\\x%02x\\x%02x\\x%02x' \
			$((0xF0 | (cp >> 18))) \
			$((0x80 | ((cp >> 12) & 0x3F))) \
			$((0x80 | ((cp >> 6) & 0x3F))) \
			$((0x80 | (cp & 0x3F)))
	fi
	printf '%b' "$out"
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

# Renders a user mention -- <ac:link><ri:user ri:account-id="..."/></ac:link> --
# as the plain text "@Display Name".
#
# Plain text, not a <span class="...">: nothing here needs styling, and the
# fewer raw HTML elements this puts in front of pandoc's gfm writer the fewer
# ways the round trip can lose them. The "@" is kept because that is how the
# mention reads on the Confluence page it came from.
#
# The name comes from CONFLUENCE_USER_MAP, which only a URL fetch fills in;
# converting a local .confluence file (or a lookup that failed) has nothing to
# resolve and falls back to a visible placeholder. That placeholder is the whole
# point: before this, an unresolved mention was emitted as nothing at all, so a
# seven-person participant list rendered as seven empty bullets with no hint
# that anything had been dropped.
convert_md_emit_mention() {
	local account_id="$1" name
	name="${CONFLUENCE_USER_MAP[$account_id]:-}"
	[ -n "$name" ] || name="unknown-user"
	printf '@%s' "$(html_escape_attr "$name")"
}

# Renders one <ac:link> as an <a> (the attachment-backed kind) or as an
# "@Name" mention (the <ri:user> kind).
# <ac:link> wrapping <ri:page> is a link to another Confluence page, which has
# no local equivalent, so it's left alone exactly as before.
convert_md_emit_link() {
	local elem="$1" filename text account_id
	filename="$(convert_md_attr "$elem" 'ri:filename')"
	if [ -z "$filename" ]; then
		# Cloud identifies a mentioned user by account id; the ri:userkey of a
		# Server/DC page is deliberately not handled, since this tool only ever
		# talks to Confluence Cloud and there is no API to resolve one.
		account_id="$(convert_md_attr "$elem" 'ri:account-id')"
		[ -n "$account_id" ] || return 1
		convert_md_emit_mention "$account_id"
		return 0
	fi

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

# Renders a Confluence date -- <time datetime="2026-08-27" /> -- as its ISO
# date text.
#
# The element carries no text of its own (Confluence formats the lozenge in the
# browser, from the reader's locale), which is exactly why pandoc used to drop
# the whole thing and leave a "Data" heading with nothing under it. ISO 8601 is
# emitted rather than a localized "Aug 27, 2026" because there is no locale to
# render for: the conversion runs in a container, and an unambiguous date beats
# one silently formatted as the image's C locale.
convert_md_emit_time() {
	local elem="$1" value
	convert_md_is_empty_element "$elem" || return 1
	value="$(convert_md_attr "$elem" 'datetime')"
	# Anything that isn't a plain calendar date is left alone rather than
	# pasted into the document sight unseen.
	[[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
	printf '%s' "$value"
}

# Renders an <ac:emoticon> as the character it stands for.
#
# Modern Confluence writes the character in ac:emoji-fallback, in one of
# three shapes seen in practice: the character itself, an HTML numeric
# reference, or (astral-plane emoji especially) a JS-style "\uXXXX" escape --
# see convert_md_decode_js_unicode_escapes for why that third shape needs its
# own decoding. Whichever shape it's in, that attribute is authoritative when
# present. The ac:name table below is the legacy emoticon set, which predates
# emoji in Confluence and has no fallback attribute at all. An emoticon
# matching neither is left untouched -- i.e. dropped by pandoc, as before --
# rather than guessed at.
#
# Note this needs a font with emoji coverage to survive to the rendered PDF:
# the Docker image installs fonts-noto-color-emoji for exactly this reason, and
# without it WeasyPrint lays every one of these out as blank space.
convert_md_emit_emoticon() {
	local elem="$1" fallback name
	convert_md_is_empty_element "$elem" || return 1

	fallback="$(convert_md_attr_verbatim "$elem" 'ac:emoji-fallback')"
	if [ -n "$fallback" ]; then
		convert_md_decode_js_unicode_escapes "$fallback"
		return 0
	fi

	name="$(convert_md_attr "$elem" 'ac:name')"
	case "$name" in
	smile) printf '🙂' ;;
	sad) printf '🙁' ;;
	cheeky) printf '😜' ;;
	laugh) printf '😃' ;;
	wink) printf '😉' ;;
	thumbs-up) printf '👍' ;;
	thumbs-down) printf '👎' ;;
	information) printf 'ℹ' ;;
	tick) printf '✅' ;;
	cross) printf '❌' ;;
	warning) printf '⚠' ;;
	plus) printf '➕' ;;
	minus) printf '➖' ;;
	question) printf '❓' ;;
	light-on) printf '💡' ;;
	light-off) printf '🔅' ;;
	yellow-star | red-star | green-star | blue-star) printf '⭐' ;;
	flag) printf '🚩' ;;
	flag-off) printf '🏳' ;;
	*) return 1 ;;
	esac
}

# True when an element's attribute text is that of a self-closing tag, i.e. it
# ends in the "/" of "<time ... />".
#
# The two elements above are only rewritten in that spelling, the only one
# Confluence writes. The alternative -- "<time ...>some text</time>" -- would
# need its inner text kept rather than replaced by the attribute value, and
# passing it through unchanged is both simpler and exactly the behavior it had
# before this existed.
convert_md_is_empty_element() {
	[[ "$1" =~ /[[:space:]]*$ ]]
}

# An <ac:task-body>'s inner XHTML, ready for pandoc: any nested mention,
# image, or attachment link resolved via convert_md_rewrite_objects, same as
# in surrounding paragraph text.
#
# Confluence wraps the body in a <span class="placeholder-inline-tasks">
# purely for its own editor's styling; it carries no meaning of its own, so
# it's unwrapped rather than carried into the output as inert markup. Not
# every export includes it, so a body without that wrapper is left as-is.
convert_md_task_body_text() {
	local body="$1" wrapper='<span class="placeholder-inline-tasks">'
	case "$body" in
	"$wrapper"*'</span>')
		body="${body#"$wrapper"}"
		body="${body%</span>}"
		;;
	esac
	convert_md_rewrite_objects "$body"
}

# Renders one <ac:task-list>...</ac:task-list> span (the storage format for
# a real Confluence checkbox list) as a plain <ul><li>☐/☒ ...</li></ul>,
# the same convention lib/convert-confluence.sh already uses for this
# tool's own checkboxes in the other direction: pandoc's gfm writer, on
# seeing a list item whose text starts with "☐ " or "☒ ", emits it as
# "- [ ]"/"- [x]" on its own -- verified directly against pandoc 2.17.1.1,
# the version Debian bookworm (this image's own base) actually ships.
#
# This is not what pandoc's docs describe as the task-list mechanism, and
# it is deliberately not <li><input type="checkbox" .../>...</li> (the shape
# a modern pandoc's HTML *reader* turns back into "- [ ]"): that reader
# support doesn't exist yet in 2.17.1.1 -- verified by round-tripping
# pandoc's own generated task-list HTML back through itself and getting a
# plain, unchecked bullet list out, silently losing every checkbox.
#
# Without this function at all, pandoc's HTML reader treats ac:task-list/
# ac:task/ac:task-id/ac:task-uuid/ac:task-status/ac:task-body as meaningless
# unknown elements and keeps only their flattened text content -- which is
# why a real task used to come out as literally "199 c6bc1f902bb2 incomplete
# Attendee name Do the thing", the task's internal id, uuid and status
# leaking into the document as if they were part of it.
convert_md_emit_task_list() {
	local blob="$1" inner tasks_html="" task_elem rest status body marker

	inner="${blob#*<ac:task-list}"
	inner="${inner#*>}"
	inner="${inner%</ac:task-list>*}"

	while [[ "$inner" == *"<ac:task>"* ]]; do
		rest="${inner#*<ac:task>}"
		[[ "$rest" == *"</ac:task>"* ]] || break
		task_elem="${rest%%</ac:task>*}"
		inner="${rest#*</ac:task>}"

		status="$(convert_md_element_body "$task_elem" 'ac:task-status')"
		body="$(convert_md_task_body_text "$(convert_md_element_body "$task_elem" 'ac:task-body')")"
		# A task list buffered across several source lines (see
		# convert_md_restore_code_blocks) carries real newlines here; the task
		# body is inline content, so collapsing them to spaces is whitespace
		# normalization, not data loss.
		body="${body//$'\n'/ }"

		marker="☐"
		[ "$status" = "complete" ] && marker="☒"
		tasks_html+="<li>$marker $body</li>"
	done

	if [ -n "$tasks_html" ]; then
		printf '<ul>%s</ul>\n' "$tasks_html"
	fi
}

# Rewrites the storage-format elements that carry visible content -- images,
# attachment links, user mentions, dates and emoticons -- into the plain HTML
# pandoc's reader understands. Without this pandoc silently discards them,
# which is why a page imported from Confluence used to lose its images
# entirely, and why a real meeting-notes page came back with an empty date
# section, unlabelled emoji-less headings, and one empty bullet per attendee.
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
		# <ac:emoticon> and <time> are attribute-only elements, so only the
		# "<NAME " spelling can carry anything worth rewriting.
		for cand in "<ac:image>" "<ac:image " "<ac:link>" "<ac:link " \
			"<ac:emoticon " "<time "; do
			[[ "$text" == *"$cand"* ]] || continue
			prefix="${text%%"$cand"*}"
			if [ -z "$best_kind" ] || [ "${#prefix}" -lt "${#best_prefix}" ]; then
				best_prefix="$prefix"
				best_marker="$cand"
				case "$cand" in
				"<ac:image"*) best_kind="image" ;;
				"<ac:link"*) best_kind="link" ;;
				"<ac:emoticon"*) best_kind="emoticon" ;;
				*) best_kind="time" ;;
				esac
			fi
		done
		[ -n "$best_kind" ] || break

		case "$best_kind" in
		image) end_marker="</ac:image>" ;;
		link) end_marker="</ac:link>" ;;
		# An attribute-only element ends at its own ">"; there is no separate
		# end tag to look for. convert_md_is_empty_element then rejects the
		# "<time ...>text</time>" spelling, whose ">" this also matches.
		*) end_marker=">" ;;
		esac

		tail="${text#"$best_prefix$best_marker"}"
		# An unterminated element (or a self-closing <ac:image/>, which carries
		# no source to point at anyway): stop rewriting and pass the rest through.
		[[ "$tail" == *"$end_marker"* ]] || break
		elem="${tail%%"$end_marker"*}"
		rest="${tail#*"$end_marker"}"

		case "$best_kind" in
		image) replacement="$(convert_md_emit_image "$elem")" || replacement="" ;;
		link) replacement="$(convert_md_emit_link "$elem")" || replacement="" ;;
		emoticon) replacement="$(convert_md_emit_emoticon "$elem")" || replacement="" ;;
		time) replacement="$(convert_md_emit_time "$elem")" || replacement="" ;;
		esac

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

#!/bin/bash
# ==========================================================
# Unit tests for the storage-format rewriters in lib/convert-md.sh.
#
# Everything here is the pre-pandoc half of the conversion: the scanners that
# turn Confluence's <ac:*> macros into plain HTML. What pandoc then does with
# that HTML is covered by the CI steps, since it depends on the pandoc build
# inside the image. Run via tests/run-tests.sh.
# ==========================================================

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
# shellcheck source=tests/assert.sh
source "$TESTS_DIR/assert.sh"
# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/convert-md.sh
source "$REPO_DIR/lib/convert-md.sh"

# --- convert_md_attr -----------------------------------------------------

assert_eq 'h?a=1&b=2' \
	"$(convert_md_attr '<ri:url ri:value="h?a=1&amp;b=2"/>' 'ri:value')" \
	"attr returns the value XML-unescaped, ready to use as a key or a URL"
assert_eq 'h?a=1&amp;b=2' \
	"$(convert_md_attr_verbatim '<ri:url ri:value="h?a=1&amp;b=2"/>' 'ri:value')" \
	"attr_verbatim returns the value exactly as the storage body wrote it"
assert_eq "" "$(convert_md_attr '<ri:attachment ri:filename="x.png"/>' 'ri:value')" \
	"attr returns nothing for an attribute that isn't there"

# --- convert_md_element_body ---------------------------------------------

assert_eq "<p>Fig 1</p>" \
	"$(convert_md_element_body '<ac:caption><p>Fig 1</p></ac:caption>' 'ac:caption')" \
	"element_body returns the raw inner XHTML"
assert_eq "" "$(convert_md_element_body '<ac:image/>' 'ac:caption')" \
	"element_body returns nothing when the element is absent"

# --- convert_md_caption_text ---------------------------------------------

assert_eq "Fig 1: the <strong>pipeline</strong>" \
	"$(convert_md_caption_text '<p>Fig 1: the <strong>pipeline</strong></p>')" \
	"caption_text unwraps a single wrapping paragraph"
assert_eq "<p>one</p><p>two</p>" \
	"$(convert_md_caption_text '<p>one</p><p>two</p>')" \
	"caption_text leaves a multi-paragraph caption alone"

# --- convert_md_decode_js_unicode_escapes --------------------------------
#
# Confluence's emoji picker puts the literal characters of a JS escape into
# ac:emoji-fallback rather than a character or an HTML reference, and most
# emoji are outside the BMP, so the surrogate-pair case is the common one.

assert_eq "✅ done" "$(convert_md_decode_js_unicode_escapes '\u2705 done')" \
	"decode handles a plain BMP escape"
assert_eq "🗓 x" "$(convert_md_decode_js_unicode_escapes '\uD83D\uDDD3 x')" \
	"decode joins a surrogate pair into one astral-plane character"
assert_eq "� only" "$(convert_md_decode_js_unicode_escapes '\uD83D only')" \
	"decode replaces an unpaired surrogate with U+FFFD rather than a bogus codepoint"
assert_eq "no escapes &#9989;" "$(convert_md_decode_js_unicode_escapes 'no escapes &#9989;')" \
	"decode leaves text with no JS escapes untouched"

# --- convert_md_rewrite_objects ------------------------------------------

CONFLUENCE_ATTACHMENT_PREFIX="page-attachments"
CONFLUENCE_ATTACHMENT_MAP["diagram.png"]="diagram.png"
CONFLUENCE_ATTACHMENT_MAP["B-AROL-O logo.png"]="B-AROL-O-logo.png"
CONFLUENCE_USER_MAP["557058:abc"]="Jane Doe"

assert_eq '<p><img src="page-attachments/diagram.png" alt="diagram.png" /></p>' \
	"$(convert_md_rewrite_objects '<p><ac:image><ri:attachment ri:filename="diagram.png"/></ac:image></p>')" \
	"rewrite turns an attachment-backed ac:image into an img pointing at the download"

# A storage body from the REST API routinely puts a whole page on one line, so
# a scanner that only handled the first object per line would silently drop the
# rest. This is why the rewriter is not a single non-global pattern.
assert_eq '<p>A <img src="page-attachments/diagram.png" alt="diagram.png" /> B <img src="page-attachments/B-AROL-O-logo.png" alt="B-AROL-O logo.png" /> C</p>' \
	"$(convert_md_rewrite_objects '<p>A <ac:image><ri:attachment ri:filename="diagram.png"/></ac:image> B <ac:image><ri:attachment ri:filename="B-AROL-O logo.png"/></ac:image> C</p>')" \
	"rewrite handles several objects sharing one line"

assert_eq '<img src="https://e.com/x.png?a=1&amp;b=2" alt="" />' \
	"$(convert_md_rewrite_objects '<ac:image><ri:url ri:value="https://e.com/x.png?a=1&amp;b=2"/></ac:image>')" \
	"rewrite leaves an ri:url image pointing at its remote host, escaped exactly once"

assert_eq '<a href="page-attachments/spec.pdf">the spec</a>' \
	"$(convert_md_rewrite_objects '<ac:link><ri:attachment ri:filename="spec.pdf"/><ac:plain-text-link-body><![CDATA[the spec]]></ac:plain-text-link-body></ac:link>')" \
	"rewrite turns an attachment-backed ac:link into a local anchor"

# ri:page has no local target, so it is deliberately left for pandoc to reduce
# to its link text rather than pointed somewhere wrong.
LINK_TO_PAGE='<ac:link><ri:page ri:content-title="Other"/><ac:plain-text-link-body><![CDATA[Other]]></ac:plain-text-link-body></ac:link>'
assert_eq "$LINK_TO_PAGE" "$(convert_md_rewrite_objects "$LINK_TO_PAGE")" \
	"rewrite leaves a link to another Confluence page untouched"

assert_eq "@Jane Doe" \
	"$(convert_md_rewrite_objects '<ac:link><ri:user ri:account-id="557058:abc"/></ac:link>')" \
	"rewrite resolves a mention through the user map"
assert_eq "@unknown-user" \
	"$(convert_md_rewrite_objects '<ac:link><ri:user ri:account-id="557058:nobody"/></ac:link>')" \
	"rewrite falls back to a placeholder for an unresolved mention"

assert_eq "2026-08-27" "$(convert_md_rewrite_objects '<time datetime="2026-08-27"/>')" \
	"rewrite reduces a date lozenge to plain ISO 8601 text"

# --- convert_md_attachment_path ------------------------------------------

assert_eq "page-attachments/diagram.png" "$(convert_md_attachment_path "diagram.png")" \
	"attachment_path prefixes the directory the downloader used"
CONFLUENCE_ATTACHMENT_PREFIX=""
assert_eq "diagram.png" "$(convert_md_attachment_path "diagram.png")" \
	"attachment_path emits a bare relative name when nothing was downloaded"
assert_eq "evil.png" "$(convert_md_attachment_path "../../evil.png")" \
	"attachment_path sanitizes a filename that is not in the map"

assert_summary "convert-md.sh"

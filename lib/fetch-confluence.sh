#!/bin/bash
# ==========================================================
# Fetches a Confluence Cloud page's storage-format body via the REST API,
# given the page's URL (a tiny link, a /wiki/spaces/.../pages/<id>/... URL,
# a ?pageId=<id> URL, or a legacy /wiki/display/... URL).
#
# Sourced by publish-md-pdf.sh; not meant to be run directly.
# Requires: curl, jq, and CONFLUENCE_EMAIL + CONFLUENCE_API_TOKEN in the
# environment — see docs/confluence-authentication.md.
# ==========================================================

confluence_fetch_init() {
	require_command curl "sudo apt-get install -y curl ca-certificates"
	require_command jq "sudo apt-get install -y jq"

	if [ -z "${CONFLUENCE_EMAIL:-}" ] || [ -z "${CONFLUENCE_API_TOKEN:-}" ]; then
		echo "ERROR: CONFLUENCE_EMAIL and CONFLUENCE_API_TOKEN must both be set to fetch a" >&2
		echo "       Confluence page by URL. See docs/confluence-authentication.md." >&2
		exit 1
	fi

	# A curl config file keeps the token out of argv (and so out of \`ps\`),
	# unlike curl -u/-H. The subshell umask plus the explicit chmod
	# belt-and-suspenders it against a lenient umask.
	confluence_fetch_curl_cfg="$(mktemp)"
	register_cleanup "$confluence_fetch_curl_cfg"
	(
		umask 077
		: >"$confluence_fetch_curl_cfg"
	)
	chmod 600 "$confluence_fetch_curl_cfg"
	{
		printf 'user = "%s:%s"\n' \
			"${CONFLUENCE_EMAIL//\"/\\\"}" "${CONFLUENCE_API_TOKEN//\"/\\\"}"
		printf 'silent\n'
		printf 'show-error\n'
		printf 'max-time = 30\n'
		printf 'retry = 2\n'
	} >"$confluence_fetch_curl_cfg"
}

# Never trust curl -L -w '%{url_effective}' to report a resolved URL: curl
# folds -u/-K credentials into that report even though they were kept out of
# argv, which is exactly how a Confluence API token got leaked while
# building this feature (see
# .claude/memory/feedback_curl_url_effective_leaks_credentials.md). Refusing
# to send those same credentials over plain HTTP is the same class of
# problem one layer up, so both checks live in this module.
confluence_require_secure_url() {
	local url="$1"
	case "$url" in
	https://*) return 0 ;;
	http://*)
		if [ "${PUBLISH_MD_PDF_ALLOW_INSECURE:-0}" = "1" ]; then
			return 0
		fi
		echo "ERROR: refusing to send Confluence credentials over plain HTTP: $url" >&2
		echo "       Set PUBLISH_MD_PDF_ALLOW_INSECURE=1 to override (e.g. for a local test server)." >&2
		return 1
		;;
	*)
		echo "ERROR: unsupported URL scheme: $url" >&2
		return 1
		;;
	esac
}

# The "https://host/wiki" prefix every Confluence Cloud API/UI path hangs
# off. Also serves as the URL-shape check: anything without a /wiki segment
# isn't a Confluence Cloud URL this module knows how to handle.
confluence_url_base() {
	local url="$1"
	if [[ "$url" =~ ^(https?://[^/]+/wiki)(/|$) ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

# Just the "https://host" origin, for resolving a Location header that's an
# absolute path (starts with "/") rather than an absolute URL -- prepending
# confluence_url_base's "/wiki" suffix there would double it up, since an
# absolute-path Location already includes its own leading /wiki.
confluence_url_origin() {
	[[ "$1" =~ ^(https?://[^/]+) ]] && printf '%s\n' "${BASH_REMATCH[1]}"
}

# Matches a numeric page id out of either the current UI's .../pages/<id>
# path or a legacy ?pageId=<id> query parameter.
confluence_url_page_id() {
	local url="$1"
	if [[ "$url" =~ /pages/([0-9]+) ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	if [[ "$url" =~ [?\&]pageId=([0-9]+) ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

# Resolves a tiny link (/wiki/x/AAAA) or legacy /wiki/display/... URL to its
# canonical .../pages/<id>/... URL, by reading each hop's Location header
# ourselves rather than passing curl -L (see confluence_require_secure_url's
# comment for why -L's usual companion, -w '%{url_effective}', is avoided
# here too).
confluence_resolve_redirect() {
	local url="$1" max_hops=5 hop status headers location
	for ((hop = 0; hop < max_hops; hop++)); do
		confluence_require_secure_url "$url" || return 1

		headers="$(curl -sS -K "$confluence_fetch_curl_cfg" -D - -o /dev/null "$url")" || {
			echo "ERROR: failed to reach $url" >&2
			return 1
		}
		status="$(printf '%s' "$headers" | head -1 | grep -oE '[0-9]{3}' | head -1)"
		location="$(printf '%s' "$headers" | grep -i '^location:' | tail -1 |
			sed -E 's/^[Ll]ocation:[[:space:]]*//' | tr -d '\r\n')"

		case "$status" in
		3??)
			if [ -z "$location" ]; then
				echo "ERROR: got a $status redirect from $url with no Location header" >&2
				return 1
			fi
			case "$location" in
			http://* | https://*) url="$location" ;;
			/*) url="$(confluence_url_origin "$url")${location}" ;;
			*) url="$(dirname "$url")/${location}" ;;
			esac
			;;
		200)
			printf '%s\n' "$url"
			return 0
			;;
		401 | 403)
			echo "ERROR: authentication failed ($status) resolving $url" >&2
			echo "       Check CONFLUENCE_EMAIL/CONFLUENCE_API_TOKEN (see docs/confluence-authentication.md)." >&2
			return 1
			;;
		404)
			echo "ERROR: page not found ($status): $url" >&2
			return 1
			;;
		*)
			echo "ERROR: unexpected HTTP $status resolving $url" >&2
			return 1
			;;
		esac
	done
	echo "ERROR: too many redirects resolving $1" >&2
	return 1
}

# Lower-cases the title, collapses anything outside [a-z0-9._-] to a single
# hyphen, trims leading/trailing hyphens, and caps the length -- the same
# rules a filename derived from user-controlled text needs regardless of
# source. Falls back to "confluence-<id>" for an empty or all-punctuation
# title.
confluence_slug() {
	local title="$1" id="$2" slug
	slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' |
		sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
	slug="${slug:0:80}"
	if [ -z "$slug" ]; then
		slug="confluence-${id}"
	fi
	printf '%s\n' "$slug"
}

# Fetches the page at $1 (any recognized Confluence Cloud page URL) and
# writes its storage-format body to $2. On success, sets
# CONFLUENCE_FETCH_TITLE, CONFLUENCE_FETCH_PAGE_ID, CONFLUENCE_FETCH_VERSION,
# and CONFLUENCE_FETCH_URL for the caller (confluence_fetch_prepend_front_matter
# reads them).
confluence_fetch_page() {
	local input_url="$1" out_file="$2"
	local base page_id resolved api_url http_status response_file

	base="$(confluence_url_base "$input_url")" || {
		echo "ERROR: not a recognized Confluence Cloud page URL: $input_url" >&2
		echo "       Expected a URL containing '/wiki/', e.g. a tiny link" >&2
		echo "       (.../wiki/x/AAAA), a .../wiki/spaces/KEY/pages/<id>/Title URL, a" >&2
		echo "       ?pageId=<id> URL, or a legacy .../wiki/display/KEY/Title URL." >&2
		return 1
	}

	if ! page_id="$(confluence_url_page_id "$input_url")"; then
		resolved="$(confluence_resolve_redirect "$input_url")" || return 1
		base="$(confluence_url_base "$resolved")" || {
			echo "ERROR: resolved URL is not a Confluence Cloud page URL: $resolved" >&2
			return 1
		}
		page_id="$(confluence_url_page_id "$resolved")" || {
			echo "ERROR: could not determine a page id from: $resolved" >&2
			return 1
		}
	fi

	api_url="${base}/api/v2/pages/${page_id}?body-format=storage"
	confluence_require_secure_url "$api_url" || return 1

	response_file="$(mktemp)"
	register_cleanup "$response_file"

	http_status="$(curl -sS -K "$confluence_fetch_curl_cfg" -o "$response_file" -w '%{http_code}' "$api_url")" || {
		echo "ERROR: failed to reach $api_url" >&2
		return 1
	}

	case "$http_status" in
	200) ;;
	401 | 403)
		echo "ERROR: authentication failed ($http_status) fetching $api_url" >&2
		echo "       Check CONFLUENCE_EMAIL/CONFLUENCE_API_TOKEN (see docs/confluence-authentication.md)." >&2
		return 1
		;;
	404)
		echo "ERROR: page not found ($http_status): $api_url" >&2
		return 1
		;;
	429)
		echo "ERROR: rate limited (429) fetching $api_url; try again later" >&2
		return 1
		;;
	*)
		echo "ERROR: unexpected HTTP $http_status fetching $api_url" >&2
		cat "$response_file" >&2
		return 1
		;;
	esac

	if ! jq -e '.body.storage.value != null' "$response_file" >/dev/null 2>&1; then
		echo "ERROR: response has no body.storage.value (unexpected API shape): $api_url" >&2
		return 1
	fi

	jq -r '.body.storage.value' "$response_file" >"$out_file"
	CONFLUENCE_FETCH_TITLE="$(jq -r '.title' "$response_file")"
	CONFLUENCE_FETCH_PAGE_ID="$(jq -r '.id' "$response_file")"
	CONFLUENCE_FETCH_VERSION="$(jq -r '.version.number' "$response_file")"
	CONFLUENCE_FETCH_URL="$input_url"
	# The post-redirect base, so the caller can reach the same site's
	# attachments API without re-resolving a tiny link.
	# shellcheck disable=SC2034 # read by publish-md-pdf.sh
	CONFLUENCE_FETCH_BASE="$base"
}

# Resolves every distinct user mention in the storage body at $2 to a display
# name, filling CONFLUENCE_USER_MAP for lib/convert-md.sh.
#
# A mention is stored as nothing but an opaque account id
# (<ri:user ri:account-id="..."/>), so the name is not in the page body at all
# and has to be fetched separately -- there is no body-format or expand
# parameter on the pages API that adds it. /rest/api/user?accountId=<id> is the
# v1 endpoint for this; the v2 API has no user resource.
#
# One request per *distinct* id, so a page mentioning the same person in ten
# table rows costs one lookup, and max_users bounds a pathological page.
#
# Every failure here is a WARNING that leaves the id unresolved, never an
# error: convert_md_emit_mention then renders its "@unknown-user" placeholder,
# which is still visible in the output. Losing the whole page because one
# attendee's account was since deactivated would be the worse trade.
confluence_fetch_users() {
	local base="$1" storage_file="$2"
	local api_url response_file http_status account_id name
	local count=0 max_users=200

	CONFLUENCE_USER_MAP=()

	# The mention-free page -- most pages -- makes no request at all.
	grep -q 'ri:account-id="' "$storage_file" || return 0

	api_url="${base}/rest/api/user"
	confluence_require_secure_url "$api_url" || return 0

	response_file="$(mktemp)"
	register_cleanup "$response_file"

	# Process substitution, not a pipe: the loop has to run in this shell so
	# that CONFLUENCE_USER_MAP survives it.
	while IFS= read -r account_id; do
		[ -n "$account_id" ] || continue
		# grep pulled this straight out of an XHTML attribute, so it has to
		# come back to raw text before it is used as a query parameter or as a
		# map key -- lib/convert-md.sh looks the id up through convert_md_attr,
		# which unescapes too, and the two sides must agree on the spelling.
		account_id="$(xml_unescape_attr "$account_id")"
		if [ "$count" -ge "$max_users" ]; then
			echo "WARNING: more than $max_users distinct user mentions on this page;" >&2
			echo "         the rest will render as placeholders" >&2
			break
		fi
		count=$((count + 1))

		# -G --data-urlencode rather than building the query by hand: an
		# account id contains a ":" and may contain other characters that need
		# escaping. It goes in argv, which is fine -- unlike the token in the
		# -K config, an account id is not a secret.
		http_status="$(curl -sS -G -K "$confluence_fetch_curl_cfg" \
			--data-urlencode "accountId=$account_id" \
			-o "$response_file" -w '%{http_code}' "$api_url")" || {
			echo "WARNING: could not reach the users API; mentions will render as placeholders" >&2
			return 0
		}

		if [ "$http_status" != "200" ]; then
			echo "WARNING: HTTP $http_status resolving the mention of account $account_id;" >&2
			echo "         it will render as a placeholder" >&2
			continue
		fi

		# publicName is what the Confluence UI shows in a mention lozenge;
		# displayName is the fallback for a site that exposes it instead. The
		# name is server-controlled text on its way into a generated document,
		# so control characters (a newline especially, which would break the
		# single line this element sits on) are stripped here rather than
		# trusted -- the same reasoning as confluence_safe_basename's.
		name="$(jq -r '.publicName // .displayName // empty' "$response_file" 2>/dev/null |
			tr -d '[:cntrl:]')"
		if [ -z "$name" ]; then
			echo "WARNING: no display name for account $account_id;" >&2
			echo "         its mention will render as a placeholder" >&2
			continue
		fi

		# shellcheck disable=SC2034 # read by lib/convert-md.sh
		CONFLUENCE_USER_MAP["$account_id"]="$name"
	done < <(grep -o 'ri:account-id="[^"]*"' "$storage_file" |
		sed -e 's/^ri:account-id="//' -e 's/"$//' | sort -u)
}

# Resolves an attachment's downloadLink against the page's own base (the
# "https://host/wiki" prefix), and refuses anything pointing at another host.
#
# A relative downloadLink is a v1 REST path (e.g.
# "/rest/api/content/<id>/child/attachment/<attId>/download") -- unlike a
# redirect Location header, it does not carry its own "/wiki" segment, so it
# must hang off base, not the bare origin, or every download 404s. Verified
# against a real Confluence Cloud site: joining with the origin alone always
# 404s; joining with base resolves (as a 302, which the download itself now
# follows -- see confluence_fetch_attachments).
#
# The security concern matters more than it looks, regardless of which part
# it's joined to: downloadLink is a value out of the API response, and every
# attachment is fetched with the same -K config that carries the Confluence
# credentials, so a link naming another host would hand the API token
# straight to it. That is the same failure mode as the %{url_effective} leak
# recorded in .claude/memory/ -- credentials following a URL somewhere the
# user never chose -- one layer up. A protocol-relative "//host/path" is
# refused explicitly, since it would otherwise sail past a leading-slash
# check and still change hosts.
confluence_attachment_url() {
	local base="$1" link="$2" origin
	origin="$(confluence_url_origin "$base")"
	case "$link" in
	//*) return 1 ;;
	/*)
		printf '%s%s\n' "$base" "$link"
		;;
	http://* | https://*)
		[ "$(confluence_url_origin "$link")" = "$origin" ] || return 1
		printf '%s\n' "$link"
		;;
	*) return 1 ;;
	esac
}

# Picks the local basename an attachment is stored under: sanitized (see
# confluence_safe_basename), then de-duplicated, since two Confluence
# attachments whose titles differ only in characters the sanitizer folds
# ("a b.png" and "a-b.png") would otherwise overwrite each other.
confluence_attachment_dedupe() {
	local safe="$1" stem ext n=1 candidate
	if [ -z "${confluence_fetch_used_names[$safe]:-}" ]; then
		printf '%s\n' "$safe"
		return 0
	fi
	case "$safe" in
	*.*)
		stem="${safe%.*}"
		ext=".${safe##*.}"
		;;
	*)
		stem="$safe"
		ext=""
		;;
	esac
	# Built into a plain variable, rather than as the array subscript
	# directly, so the "-" here is unambiguously string concatenation: shfmt
	# can't tell this array is associative (declare -A) rather than indexed,
	# and would otherwise reformat "${stem}-${n}${ext}" by adding spaces
	# around the "-" as though it were arithmetic -- which for an
	# associative subscript changes the actual key string, not just its
	# formatting.
	candidate="${stem}-${n}${ext}"
	while [ -n "${confluence_fetch_used_names[$candidate]:-}" ]; do
		n=$((n + 1))
		candidate="${stem}-${n}${ext}"
	done
	printf '%s\n' "$candidate"
}

# Downloads every attachment of page $2 into $3, and records each one in
# CONFLUENCE_ATTACHMENT_MAP so lib/convert-md.sh can point <img>/<a> at the
# file it actually landed in. $1 is the "https://host/wiki" base.
#
# A failure here downgrades to a warning rather than aborting: a page whose
# text converted fine shouldn't be lost over one unreadable attachment. The
# unresolved reference that results is still visible in the output, unlike the
# silently dropped image this whole feature replaces.
confluence_fetch_attachments() {
	local base="$1" page_id="$2" dest_dir="$3"
	local origin api_url response_file http_status title link url safe target next
	local page=0 max_pages=50

	CONFLUENCE_ATTACHMENT_MAP=()
	CONFLUENCE_FETCH_ATTACHMENT_COUNT=0
	declare -gA confluence_fetch_used_names=()

	origin="$(confluence_url_origin "$base")"
	api_url="${base}/api/v2/pages/${page_id}/attachments?limit=100"
	response_file="$(mktemp)"
	register_cleanup "$response_file"

	while [ -n "$api_url" ] && [ "$page" -lt "$max_pages" ]; do
		page=$((page + 1))
		confluence_require_secure_url "$api_url" || return 1

		http_status="$(curl -sS -K "$confluence_fetch_curl_cfg" -o "$response_file" -w '%{http_code}' "$api_url")" || {
			echo "WARNING: could not reach the attachments API; attachment references may not resolve" >&2
			return 0
		}
		case "$http_status" in
		200) ;;
		404)
			# No attachment container on this page -- nothing to download.
			return 0
			;;
		*)
			echo "WARNING: HTTP $http_status listing attachments for page $page_id;" >&2
			echo "         attachment references may not resolve" >&2
			return 0
			;;
		esac

		if ! jq -e '.results != null' "$response_file" >/dev/null 2>&1; then
			echo "ERROR: attachments response has no .results array (unexpected API shape)" >&2
			echo "       $api_url" >&2
			return 1
		fi

		# Process substitution, not a pipe: the loop has to run in this shell so
		# that CONFLUENCE_ATTACHMENT_MAP survives it.
		while IFS=$'\t' read -r title link; do
			if [ -z "$title" ] || [ -z "$link" ]; then
				continue
			fi

			if ! url="$(confluence_attachment_url "$base" "$link")"; then
				echo "WARNING: skipping attachment '$title': its download link points outside $origin" >&2
				continue
			fi

			safe="$(confluence_safe_basename "$title" "attachment-$((CONFLUENCE_FETCH_ATTACHMENT_COUNT + 1))")"
			safe="$(confluence_attachment_dedupe "$safe")"
			confluence_fetch_used_names[$safe]=1

			mkdir -p "$dest_dir"
			target="$dest_dir/$safe"
			# --fail so an HTTP error body is never written out as if it were the
			# attachment, and --max-time to override the 30s in the shared curl
			# config -- ample for a JSON body, far too short for a large file.
			# --location, since a v1 downloadLink (see confluence_attachment_url)
			# resolves to a 302 to the actual content, not the content itself;
			# --max-redirs bounds how far that's followed. curl itself (7.58.0+,
			# and this image ships 7.88.1) drops the -K config's credentials
			# before following a redirect to a different host, so this can't
			# repeat the same-origin bypass confluence_attachment_url already
			# guards against one step earlier.
			if ! curl -sS -f -L --max-redirs 5 -K "$confluence_fetch_curl_cfg" --max-time 300 -o "$target" "$url"; then
				echo "WARNING: failed to download attachment '$title'" >&2
				rm -f "$target"
				continue
			fi

			echo "INFO: Downloaded attachment '$title' -> $target"

			# shellcheck disable=SC2034 # read by lib/convert-md.sh
			CONFLUENCE_ATTACHMENT_MAP["$title"]="$safe"
			CONFLUENCE_FETCH_ATTACHMENT_COUNT=$((CONFLUENCE_FETCH_ATTACHMENT_COUNT + 1))
		done < <(jq -r '.results[] | select(.title != null and .downloadLink != null) |
			[.title, .downloadLink] | @tsv' "$response_file")

		next="$(jq -r '._links.next // empty' "$response_file")"
		case "$next" in
		"") api_url="" ;;
		//*) api_url="" ;;
		/*) api_url="${origin}${next}" ;;
		http://* | https://*)
			if [ "$(confluence_url_origin "$next")" = "$origin" ]; then
				api_url="$next"
			else
				echo "WARNING: attachments pagination link points outside $origin; stopping here" >&2
				api_url=""
			fi
			;;
		*) api_url="" ;;
		esac
	done

	if [ "$CONFLUENCE_FETCH_ATTACHMENT_COUNT" -gt 0 ]; then
		echo "INFO: Downloaded $CONFLUENCE_FETCH_ATTACHMENT_COUNT attachment(s) to $dest_dir"
	fi
}

# Prepends YAML front matter (title, source URL, page id, version) to the
# Markdown at $1, using the CONFLUENCE_FETCH_* globals confluence_fetch_page
# just set. The storage body has no title of its own, so without this a
# fetched page would render as a headless document; it also feeds the
# existing "front matter title: becomes the PDF's document title" behavior.
confluence_fetch_prepend_front_matter() {
	local md_file="$1" tmp
	tmp="$(mktemp)"
	register_cleanup "$tmp"
	{
		printf -- '---\n'
		printf 'title: "%s"\n' "${CONFLUENCE_FETCH_TITLE//\"/\\\"}"
		printf 'source_url: "%s"\n' "${CONFLUENCE_FETCH_URL//\"/\\\"}"
		printf 'confluence_page_id: "%s"\n' "$CONFLUENCE_FETCH_PAGE_ID"
		printf 'confluence_version: %s\n' "$CONFLUENCE_FETCH_VERSION"
		printf -- '---\n\n'
		cat "$md_file"
	} >"$tmp"
	# mktemp's file is 0600; mv would carry that onto $md_file, unlike every
	# other output in this tool (which inherits the writer's default umask).
	chmod --reference="$md_file" "$tmp"
	mv "$tmp" "$md_file"
}

# EOF

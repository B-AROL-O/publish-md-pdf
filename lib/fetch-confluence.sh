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

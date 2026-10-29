#!/bin/bash
# ==========================================================
# Fetches a GitHub issue or pull request via the REST API, given its web URL
# (https://github.com/OWNER/REPO/issues/N or .../pull/N, or the same on a
# GitHub Enterprise Cloud with data residency host, SUBDOMAIN.ghe.com), and
# renders it to one Markdown document via lib/github-md.jq.
#
# Sourced by publish-md-pdf.sh; not meant to be run directly.
# Requires: curl, jq, and (optionally on github.com, required elsewhere) a
# token in GITHUB_TOKEN or GH_TOKEN.
# ==========================================================

GITHUB_FETCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

github_fetch_init() {
	require_command curl "sudo apt-get install -y curl ca-certificates"
	require_command jq "sudo apt-get install -y jq"

	github_fetch_token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

	# The same arrangement as lib/fetch-confluence.sh's: a curl config file
	# keeps the token out of argv (and so out of `ps`). It holds the
	# Authorization header only, so it can go on an image download as well as
	# on an API call -- the API-specific Accept header is passed separately.
	github_fetch_curl_cfg="$(mktemp)"
	register_cleanup "$github_fetch_curl_cfg"
	(
		umask 077
		: >"$github_fetch_curl_cfg"
	)
	chmod 600 "$github_fetch_curl_cfg"
	{
		if [ -n "$github_fetch_token" ]; then
			printf 'header = "Authorization: Bearer %s"\n' "${github_fetch_token//\"/\\\"}"
		fi
		printf 'silent\n'
		printf 'show-error\n'
		printf 'max-time = 30\n'
		printf 'retry = 2\n'
	} >"$github_fetch_curl_cfg"
}

# Whether $1 has the shape of a GitHub issue or pull request URL, on any host.
# Deliberately host-agnostic, so a self-hosted GitHub Enterprise Server URL is
# routed here (and fails with a message about GitHub, see github_api_base)
# rather than falling through to the Confluence importer, whose error would
# only be confusing. A Confluence URL always has a /wiki/ segment, which this
# shape can't match.
is_github_url() {
	[[ "$1" =~ ^https?://[^/]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(issues|pull)/[0-9]+([/?#]|$) ]]
}

# Splits an issue/PR URL into "origin owner repo number", space-separated.
# Owner and repository names are restricted to the characters GitHub itself
# allows in them, which also keeps anything else out of the API paths built
# from them. The host is lower-cased, since github_api_base compares it.
github_url_parts() {
	local url="$1" origin
	if [[ "$url" =~ ^(https?://[^/]+)/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/(issues|pull)/([0-9]+)([/?#]|$) ]]; then
		origin="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
		printf '%s %s %s %s\n' "$origin" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[5]}"
		return 0
	fi
	return 1
}

# Maps a web origin to the REST API base the token is sent to. Only hosts
# whose API location is known are accepted -- the token goes wherever this
# returns, so it must never be derived from an arbitrary URL:
#
#   https://github.com        -> https://api.github.com
#   https://SUB.ghe.com       -> https://api.SUB.ghe.com  (GHE.com data residency)
#   $GITHUB_SERVER_URL        -> $GITHUB_API_URL, when both are set
#
# The last row is how a self-hosted GitHub Enterprise Server works: GitHub
# Actions sets both variables on every runner, so the Action resolves its own
# server's URLs with no configuration, and anywhere else the user opts in by
# setting them. It is checked first, so a runner's own values always win.
github_api_base() {
	local origin="$1" server host
	server="$(printf '%s' "${GITHUB_SERVER_URL:-}" | tr '[:upper:]' '[:lower:]')"
	server="${server%/}"
	if [ -n "$server" ] && [ -n "${GITHUB_API_URL:-}" ] && [ "$server" = "$origin" ]; then
		printf '%s\n' "${GITHUB_API_URL%/}"
		return 0
	fi
	host="${origin#https://}"
	case "$origin" in
	https://github.com)
		printf '%s\n' "https://api.github.com"
		;;
	https://*.ghe.com)
		# One DNS label in front of .ghe.com, nothing else: "a.b.ghe.com" or a
		# "host:port" isn't a GHE.com tenant.
		[[ "$host" =~ ^[a-z0-9-]+\.ghe\.com$ ]] || return 1
		printf '%s\n' "https://api.$host"
		;;
	*)
		return 1
		;;
	esac
}

# The same refusal as confluence_require_secure_url, for the GitHub token.
github_require_secure_url() {
	local url="$1"
	case "$url" in
	https://*) return 0 ;;
	http://*)
		if [ "${PUBLISH_MD_PDF_ALLOW_INSECURE:-0}" = "1" ]; then
			return 0
		fi
		echo "ERROR: refusing to send a GitHub token over plain HTTP: $url" >&2
		echo "       Set PUBLISH_MD_PDF_ALLOW_INSECURE=1 to override (e.g. for a local test server)." >&2
		return 1
		;;
	*)
		echo "ERROR: unsupported URL scheme: $url" >&2
		return 1
		;;
	esac
}

# GETs one API URL ($1) into $2, with the token. Returns non-zero, after
# saying why on stderr, for anything but a 200.
github_api_get() {
	local url="$1" out_file="$2" http_status message
	github_require_secure_url "$url" || return 1

	http_status="$(curl -K "$github_fetch_curl_cfg" \
		-H 'Accept: application/vnd.github.full+json' \
		-H 'X-GitHub-Api-Version: 2022-11-28' \
		-o "$out_file" -w '%{http_code}' "$url")" || {
		echo "ERROR: failed to reach $url" >&2
		return 1
	}

	case "$http_status" in
	200) return 0 ;;
	401)
		echo "ERROR: authentication failed (401) fetching $url" >&2
		echo "       Check GITHUB_TOKEN (or GH_TOKEN)." >&2
		;;
	403 | 429)
		message="$(jq -r '.message // empty' "$out_file" 2>/dev/null)"
		case "$message" in
		*"rate limit"*)
			echo "ERROR: GitHub API rate limit exceeded ($http_status) fetching $url" >&2
			if [ -z "$github_fetch_token" ]; then
				echo "       Unauthenticated requests are limited to 60 per hour; set GITHUB_TOKEN." >&2
			fi
			;;
		*)
			echo "ERROR: access denied ($http_status) fetching $url" >&2
			echo "       Check that GITHUB_TOKEN (or GH_TOKEN) can read this repository." >&2
			;;
		esac
		;;
	404)
		echo "ERROR: not found (404): $url" >&2
		# GitHub answers 404, not 403, for a private repository the caller
		# can't see, so a missing token is the likelier explanation.
		if [ -z "$github_fetch_token" ]; then
			echo "       If the repository is private, set GITHUB_TOKEN (or GH_TOKEN)." >&2
		fi
		;;
	*)
		echo "ERROR: unexpected HTTP $http_status fetching $url" >&2
		;;
	esac
	return 1
}

# GETs every page of a list endpoint ($1, with no query string) into $2 as one
# JSON array. Pages are requested by number rather than by following the
# Link header, so no URL out of a response is ever fetched with the token.
# $3 caps the page count (100 items each).
github_api_get_all() {
	local url="$1" out_file="$2" max_pages="${3:-50}" page_file page=0 count
	page_file="$(mktemp)"
	register_cleanup "$page_file"
	printf '[]' >"$out_file"
	while [ "$page" -lt "$max_pages" ]; do
		page=$((page + 1))
		github_api_get "${url}?per_page=100&page=${page}" "$page_file" || return 1
		if ! count="$(jq -e 'if type == "array" then length else error end' "$page_file" 2>/dev/null)"; then
			echo "ERROR: unexpected API response (not a JSON array): $url" >&2
			return 1
		fi
		jq -s '.[0] + .[1]' "$out_file" "$page_file" >"$out_file.tmp" && mv "$out_file.tmp" "$out_file"
		[ "$count" -ge 100 ] || break
	done
}

# Fetches the issue or pull request at $1 and writes its Markdown to $2.
# Every API response is kept in $3 (a directory), which
# github_fetch_images reads the rendered HTML bodies back out of. On success,
# sets GITHUB_FETCH_TITLE, GITHUB_FETCH_SLUG and GITHUB_FETCH_ORIGIN.
github_fetch_issue() {
	local input_url="$1" out_file="$2" work_dir="$3"
	local parts origin owner repo number api base kind name

	parts="$(github_url_parts "$input_url")" || {
		echo "ERROR: not a recognized GitHub issue or pull request URL: $input_url" >&2
		return 1
	}
	read -r origin owner repo number <<<"$parts"

	api="$(github_api_base "$origin")" || {
		echo "ERROR: don't know where the REST API for $origin is." >&2
		echo "       Supported: github.com and SUBDOMAIN.ghe.com. For GitHub Enterprise Server," >&2
		echo "       set GITHUB_SERVER_URL=$origin and GITHUB_API_URL to its API base" >&2
		echo "       (usually $origin/api/v3)." >&2
		return 1
	}
	if [ -z "$github_fetch_token" ] && [ "$api" != "https://api.github.com" ]; then
		echo "ERROR: GITHUB_TOKEN (or GH_TOKEN) must be set to fetch from $origin." >&2
		return 1
	fi

	base="$api/repos/$owner/$repo"
	github_api_get "$base/issues/$number" "$work_dir/issue.json" || return 1
	github_api_get_all "$base/issues/$number/comments" "$work_dir/comments.json" || return 1

	# /issues/N answers for a pull request too, with a pull_request key --
	# which is what decides the kind, not whether the URL said /issues/ or
	# /pull/ (GitHub's own web UI redirects between the two the same way).
	if jq -e '.pull_request != null' "$work_dir/issue.json" >/dev/null; then
		kind="pr"
		github_api_get "$base/pulls/$number" "$work_dir/pull.json" || return 1
		github_api_get_all "$base/pulls/$number/reviews" "$work_dir/reviews.json" || return 1
		github_api_get_all "$base/pulls/$number/comments" "$work_dir/review_comments.json" || return 1
		# The API itself stops at 250 commits and 3000 files; the page caps
		# just match that.
		github_api_get_all "$base/pulls/$number/commits" "$work_dir/commits.json" 3 || return 1
		github_api_get_all "$base/pulls/$number/files" "$work_dir/files.json" 30 || return 1
	else
		kind="issue"
		printf 'null' >"$work_dir/pull.json"
		for name in reviews review_comments commits files; do
			printf '[]' >"$work_dir/$name.json"
		done
	fi

	jq -n -r -L "$GITHUB_FETCH_LIB_DIR" \
		--arg url "$input_url" \
		--slurpfile issue "$work_dir/issue.json" \
		--slurpfile pull "$work_dir/pull.json" \
		--slurpfile comments "$work_dir/comments.json" \
		--slurpfile reviews "$work_dir/reviews.json" \
		--slurpfile review_comments "$work_dir/review_comments.json" \
		--slurpfile commits "$work_dir/commits.json" \
		--slurpfile files "$work_dir/files.json" \
		'include "github-md";
		github_md($url; $issue[0]; $pull[0]; $comments[0]; $reviews[0];
			$review_comments[0]; $commits[0]; $files[0])' >"$out_file" || {
		echo "ERROR: could not render $input_url (unexpected API response shape)" >&2
		return 1
	}

	# shellcheck disable=SC2034 # read by publish-md-pdf.sh
	GITHUB_FETCH_TITLE="$(jq -r '.title' "$work_dir/issue.json" | tr -d '[:cntrl:]')"
	GITHUB_FETCH_ORIGIN="$origin"
	# Predictable rather than derived from the title, which can change: the
	# same issue always lands in the same file.
	# shellcheck disable=SC2034 # read by publish-md-pdf.sh
	GITHUB_FETCH_SLUG="$(printf '%s-%s-%s' "$repo" "$kind" "$number" | tr '[:upper:]' '[:lower:]')"
}

# Whether $1 is an image GitHub stores for an issue or comment on server
# $2: /user-attachments/assets/<uuid> (current), or the older
# /OWNER/REPO/assets/<id>/<uuid>. Prints the uuid. Anything else -- another
# host above all -- is left alone: it either needs no token (and WeasyPrint
# fetches it itself), or it isn't GitHub's to vouch for.
github_attachment_uuid() {
	local url="$1" origin="$2" uuid_re='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
	case "$url" in
	"$origin"/*) ;;
	*) return 1 ;;
	esac
	if [[ "${url#"$origin"}" =~ ^/user-attachments/assets/($uuid_re)$ ]] ||
		[[ "${url#"$origin"}" =~ ^/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/assets/[0-9]+/($uuid_re)$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

# Image URLs referenced from the Markdown at $1, one per line: the targets of
# ![alt](url) and of <img src="url">, the two ways GitHub's editor inserts an
# uploaded image. A plain link to the same URL isn't collected.
github_markdown_image_urls() {
	{
		grep -oE '!\[[^]]*\]\(https?://[^)[:space:]]+' "$1" | sed -E 's/^.*\]\(//'
		grep -oE '<img[^>]*[[:space:]]src="https?://[^"]+"' "$1" | sed -E 's/^.*src="//; s/"$//'
	} | sort -u
}

# The extension for a downloaded image, from the Content-Type it was served
# with. WeasyPrint sniffs the format anyway; this is for the --format md
# reader opening the attachments directory.
github_image_ext() {
	case "$1" in
	image/png*) printf '.png' ;;
	image/jpeg*) printf '.jpg' ;;
	image/gif*) printf '.gif' ;;
	image/svg+xml*) printf '.svg' ;;
	image/webp*) printf '.webp' ;;
	esac
}

# Downloads the images uploaded to the issue/PR whose Markdown is $1 into
# directory $3, and rewrites the Markdown to reference them as $4/<file>.
# $2 is the work directory github_fetch_issue left its API responses in.
#
# The URL in the Markdown (github.com/user-attachments/assets/<uuid>) needs a
# browser session for a private repository, which a token does not stand in
# for. The rendered body_html that the API returns alongside the Markdown
# body (we ask for application/vnd.github.full+json) instead carries a
# pre-signed URL for the same image -- private-user-images.githubusercontent
# .com/...-<uuid>.png?jwt=..., valid for a few minutes -- which is fetched
# with no credentials at all. Matching the two up by the uuid is what makes
# private repositories work. Only an image with no signed counterpart falls
# back to the original URL, and only that request carries the token: it is on
# $GITHUB_FETCH_ORIGIN by construction (see github_attachment_uuid), and curl
# drops the Authorization header if the server redirects it to another host.
#
# Like the Confluence attachments, a failure is a warning: the image stays a
# remote reference rather than losing the whole document.
github_fetch_images() {
	local md_file="$1" work_dir="$2" dest_dir="$3" prefix="$4"
	local signed_file url uuid signed content_type name target content fetched count=0

	signed_file="$work_dir/signed-urls.txt"
	# Every src="..." in every body_html, attribute-unescaped (&amp; in the
	# query string especially).
	jq -r '.. | objects | .body_html? // empty' "$work_dir"/*.json 2>/dev/null |
		grep -oE 'src="https?://[^"]+"' | sed -E 's/^src="//; s/"$//' |
		while IFS= read -r url; do xml_unescape_attr "$url" && printf '\n'; done >"$signed_file"

	content="$(cat "$md_file")"
	while IFS= read -r url; do
		uuid="$(github_attachment_uuid "$url" "$GITHUB_FETCH_ORIGIN")" || continue
		# The signed URL is the one whose path ends in "-<uuid>.<ext>" -- or
		# just "<uuid>", to match the mock CI serves.
		signed="$(grep -E "[/-]${uuid}(\.[A-Za-z0-9]+)?([?#]|$)" "$signed_file" | grep -v -F "$url" | head -1)"
		mkdir -p "$dest_dir"
		target="$dest_dir/$uuid"
		fetched=0
		# --fail so an HTTP error body is never saved as if it were the image.
		if [ -n "$signed" ] &&
			content_type="$(curl -s -f -L --max-redirs 5 --max-time 300 --proto '=http,https' \
				-o "$target" -w '%{content_type}' "$signed")"; then
			fetched=1
		elif github_require_secure_url "$url" 2>/dev/null &&
			content_type="$(curl -f -L --max-redirs 5 -K "$github_fetch_curl_cfg" --max-time 300 \
				-o "$target" -w '%{content_type}' "$url")"; then
			fetched=1
		fi
		if [ "$fetched" -eq 0 ]; then
			echo "WARNING: failed to download image $url; leaving it as a remote reference" >&2
			rm -f "$target"
			continue
		fi
		name="$uuid$(github_image_ext "$content_type")"
		if [ "$name" != "$uuid" ]; then
			mv "$target" "$dest_dir/$name"
		fi
		# Quoted on both sides, so neither the URL nor the replacement is a
		# pattern -- and so bash 5.2's patsub_replacement can't read an "&"
		# in either as "the matched text".
		content="${content//"]($url"/"]($prefix/$name"}"
		content="${content//"src=\"$url\""/"src=\"$prefix/$name\""}"
		count=$((count + 1))
		echo "INFO: Downloaded image $url -> $dest_dir/$name"
	done < <(github_markdown_image_urls "$md_file")

	printf '%s\n' "$content" >"$md_file"
	if [ "$count" -gt 0 ]; then
		echo "INFO: Downloaded $count image(s) to $dest_dir"
	fi
}

# EOF

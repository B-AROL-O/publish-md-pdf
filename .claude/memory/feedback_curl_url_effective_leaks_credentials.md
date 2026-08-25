---
name: feedback-curl-url-effective-leaks-credentials
description: Never use curl -w '%{url_effective}' (or print any "effective URL") when the request used -u or a -K config with embedded credentials
metadata:
  type: feedback
---

`curl`'s `%{url_effective}` write-out variable embeds the request's userinfo
(`user:pass`) into the reported URL when credentials were supplied via `-u`
or a `-K` config file's `user = "..."` line — even though the credentials
were kept out of argv/`ps` deliberately. Following a redirect and then
printing `%{url_effective}` reprints the full secret in plaintext.

**Why:** while verifying the Confluence Cloud REST API for
[[confluence-authentication]] / issue #10's import-by-URL feature, a
verification script written to resolve a Confluence tiny-link redirect used
`curl -K "$CURL_CFG" -L -o /dev/null -w '%{url_effective}'` to show the
resolved page URL. The user ran it and pasted the output back — which
contained their live Confluence API token in full, because curl folded the
`-K` file's credentials into the reported effective URL. The token had to be
revoked immediately.

**How to apply:** when writing any curl-based script (verification, ad hoc,
or shipped) that authenticates and might report a URL back to the user or a
log — for redirect resolution use `-w '%{http_code}'` plus `-D -` (dump
headers, read `Location:` from the pre-redirect response) instead of
`-L -w '%{url_effective}'`, or strip `://[^@/]*@` from `%{url_effective}`
before printing it. Never trust that keeping credentials out of argv (via
`-K`) is sufficient — curl's own diagnostic output can still leak them.

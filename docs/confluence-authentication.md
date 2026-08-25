# Confluence Cloud authentication

This covers how to obtain the two credentials Confluence Cloud's REST API requires — the account
email and an API token — and how to hand them to this tool safely. It's referenced by:

- [docs/import-to-confluence-cloud.md](import-to-confluence-cloud.md), Method B (pushing a
  `.confluence` file to a real page via the REST API).
- The forthcoming "import a Confluence page by URL" feature
  ([issue #10](https://github.com/B-AROL-O/publish-md-pdf/issues/10)), which will read these same
  two values from the `CONFLUENCE_EMAIL` and `CONFLUENCE_API_TOKEN` environment variables.

## What you need

| Value     | What it is                                                                          |
| --------- | ----------------------------------------------------------------------------------- |
| Email     | The email address of your Atlassian account                                         |
| API token | A secret credential that authenticates as that account, used in place of a password |

Confluence Cloud's REST API authenticates with **Basic auth using your email and an API token**,
not your normal login password — Atlassian Cloud accounts don't accept a password over the REST
API at all.

## 1. Find your account email

The email is whatever you log into Atlassian/Confluence with. To confirm it:

1. Go to <https://id.atlassian.com/manage-profile/profile-and-visibility> while logged in.
2. Your account email is shown under **Contact details**.

This is the same email used across all Atlassian Cloud products (Confluence, Jira, etc.) tied to
that account — it does not need to match the target site's domain (e.g. an `@arol.com` account can
still authenticate against `arol.atlassian.net`).

## 2. Create an API token

1. Go to <https://id.atlassian.com/manage-profile/security/api-tokens>, logged in as the account
   that has access to the Confluence site you want to reach.
2. Click **Create API token**.
3. Give it a descriptive label — e.g. `publish-md-pdf` — so you can identify and revoke it later
   without guessing which token is which.
4. If your organization has scoped tokens enabled, you'll be asked to choose which
   products/permissions the token grants. Pick **Confluence**, with read access (and write access
   too, if you'll also use Method B of
   [docs/import-to-confluence-cloud.md](import-to-confluence-cloud.md) to create/update pages).
   If there's no scoping step, the token is a "classic" token with the same access as your account.
5. If prompted, set an expiry. Newer Atlassian organizations require tokens to expire; note the
   date somewhere so the token doesn't fail unexpectedly later.
6. Click **Create**, then **copy the token immediately**. Atlassian shows it exactly once — closing
   the dialog without copying means creating a new one.

## 3. Handle the token as a secret

- **Never** paste it directly into a command line, a config file, or a chat message — anything
  that ends up in shell history, a committed file, or a log.
- Export it into an environment variable in your current shell instead:

  ```bash
  export CONFLUENCE_EMAIL="you@example.com"
  export CONFLUENCE_API_TOKEN="the token you just copied"
  ```

- In CI (e.g. GitHub Actions), store it as a repository or organization **secret**, and reference
  it via `env:` on the step — never as a plain workflow input:

  ```yaml
  - uses: B-AROL-O/publish-md-pdf@v2
    with:
      files: https://arol.atlassian.net/wiki/x/AYAJ4
    env:
      CONFLUENCE_EMAIL: ${{ vars.CONFLUENCE_EMAIL }}
      CONFLUENCE_API_TOKEN: ${{ secrets.CONFLUENCE_API_TOKEN }}
  ```

- The token carries whatever access your account (or its scoped grant) has. Treat it like a
  password: anyone with it can read, and possibly modify, Confluence content on your behalf.

## 4. Revoking a token

If a token is exposed or no longer needed, revoke it immediately at
<https://id.atlassian.com/manage-profile/security/api-tokens> — click the token's **⋮** menu, then
**Revoke**. Revocation is immediate; anything still using that token starts failing authentication
right away.

## Troubleshooting

- **401 Unauthorized** — the email/token pair is wrong, or the token was revoked/expired. Re-check
  `CONFLUENCE_EMAIL` matches the account the token was created under.
- **403 Forbidden** — the credentials are valid but lack access to the specific space or page (or,
  for a scoped token, the token wasn't granted the needed permission in step 2.4 above).
- **404 Not Found** on a page request that you can otherwise open in a browser — you're
  authenticated as an account without view access to that space.

<!-- EOF -->

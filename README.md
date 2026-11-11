# Webskan website audit – GitHub Action

Audit the **live** site right after a deploy and fail the job when something is broken on the
outside: Lighthouse (mobile and desktop), technical SEO on every crawled page, accessibility
(axe-core, WCAG 2.1 AA), security headers and TLS, publicly exposed `.git` / `.env` / SQL dumps /
backups, broken links, forms and the cookie banner. Every finding has a stable id, so a second
run can tell you exactly what was fixed, what is still open and what is new.

Under the hood it calls the [Webskan MCP server](https://webskan.com/developers/) over plain HTTP
(curl + jq, no SDK, nothing to install on the runner). The same service is what Claude Code,
Cursor or Codex use when they audit a site through MCP – the action is the CI side of that loop.

## Usage

```yaml
name: deploy
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      # ... build and deploy, wait until the new version is live ...
      - name: Audit the live site
        uses: kamilobstawskiagent-ux/webskan-action@v1
        with:
          url: https://example.com
          pages: 10
          key: ${{ secrets.WEBSKAN_KEY }}   # optional, see "Limits"
          fail-on: high                     # high | medium | none
```

The job fails when there is at least one **high** finding (a readable `.env`, a `noindex` on the
home page, a broken checkout, an expired certificate, …). High findings show up as error
annotations and medium ones as warnings, and the job summary lists them with their ids and the pages
they were found on:

| Severity | Id | Finding | Pages |
|---|---|---|---|
| high | `sec.exposed-file@/.env` | Publicly readable .env file | https://example.com/.env |
| medium | `seo.title.missing@/about` | Page without a title | https://example.com/about |

Finding ids are documented at [webskan.com/developers/findings](https://webskan.com/developers/findings/).

### Re-check after a fix

Keep the `audit-id` output (for example in the job summary, an artifact or an issue) and pass it to
a later run as `recheck-of`. The action then runs the same audit again and reports a diff:

```yaml
      - name: Re-check against the audit that failed last time
        uses: kamilobstawskiagent-ux/webskan-action@v1
        with:
          url: https://example.com
          recheck-of: 4a3f9c2b7e1d6a50
          key: ${{ secrets.WEBSKAN_KEY }}
```

Summary: `3 fixed · 1 still open · 0 new · 0 could not verify`, with the lists underneath. Lighthouse
metrics are excluded from the diff (they vary a few points between runs); findings on a page or
link that did not respond this time are reported as "could not verify" rather than "fixed".

### Preview deployments

Point `url` at the preview URL (Vercel, Netlify, Cloudflare Pages, …). The site must be reachable
from the public internet without a password – Webskan audits from the outside, like a visitor.

## Inputs

| Input | Default | Description |
|---|---|---|
| `url` | – | Public URL of the deployed site. Required. |
| `pages` | `10` | Pages to crawl (1-30), following navigation and the sitemap. |
| `key` | – | Webskan Developer license key, as a secret. |
| `fail-on` | `high` | Fail when there is at least one finding of this severity: `high`, `medium` or `none` (report only). |
| `min-performance` | `0` | Fail when the Lighthouse mobile performance score is below this number. |
| `recheck-of` | – | `audit-id` of a previous audit: run it again and report fixed / open / new. |
| `timeout-minutes` | `20` | Give up waiting after this long (a full audit normally takes 1-5 minutes). |
| `fail-on-error` | `true` | Fail when the audit itself could not run (unreachable site, limit reached, timeout). |

## Outputs

`audit-id`, `status` (`done` / `error` / `timeout`), `passed`, `high`, `medium`, `low`, `total`,
`performance-mobile`, `performance-desktop`, `result-file` (path of the full JSON: every finding
with id, area, severity, detail and pages, plus Lighthouse metrics) and, for a re-check, `fixed`,
`open`, `new`.

```yaml
      - name: Comment on the PR
        if: always()
        run: echo "Webskan: ${{ steps.audit.outputs.high }} high, ${{ steps.audit.outputs.medium }} medium, perf ${{ steps.audit.outputs.performance-mobile }}"
```

## Limits

Without a key the **free plan** applies: 2 whole-site audits per IP address per 24 h and 1 audit
per host per 24 h (a repeat run for the same host within 24 h returns the existing audit instead of
running a new one). GitHub-hosted runners share IP addresses with everyone else, so a free-plan
run can hit "limit reached" at any time. For anything that runs on every deploy use the
[Developer plan](https://webskan.com/developers/#teams) ($29 a month): 30 audits per day per key
and no one-audit-per-host-per-day window, so you can re-audit five minutes after the fix. Store the
key as a repository secret (`WEBSKAN_KEY` in the examples).

## What exactly is checked

See [webskan.com/developers](https://webskan.com/developers/) for the full list, the four MCP tools
and client configurations for Claude Code, Cursor, VS Code, Codex and Windsurf. In short: Lighthouse
mobile and desktop with Core Web Vitals; per-page title, description, H1, canonical, indexing,
language, Open Graph, structured data; axe-core on the key pages with selectors; CSP, HSTS and the
other security headers, TLS validity and expiry; exposed `.git`, `.env`, `wp-config` backups, SQL
dumps, archives, `phpinfo`, logs; up to 500 internal and external links; forms (labels, consent,
spam protection); cookie banner; customer journeys on an emulated phone (404 page, menu, search,
product → cart → checkout in shops – nothing is bought and no data is entered).

Deterministic and read-only: no LLM in the audit, no account needed for the free plan, public URLs
only. Terms: [webskan.com/en/terms](https://webskan.com/en/terms/). Questions and false positives:
kontakt@webskan.com.

## Without GitHub Actions

`webskan-audit.sh` runs in any CI that has bash, curl and jq:

```sh
WEBSKAN_URL=https://example.com WEBSKAN_PAGES=10 WEBSKAN_FAIL_ON=high WEBSKAN_KEY=... ./webskan-audit.sh
```

Exit codes: 0 pass, 1 findings above the threshold, 2 the audit could not run.

## License

MIT.

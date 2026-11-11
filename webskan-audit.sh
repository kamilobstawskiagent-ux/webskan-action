#!/usr/bin/env bash
# Webskan audit step for GitHub Actions (also usable in any CI: plain curl + jq against the MCP endpoint).
# Reads WEBSKAN_* environment variables (set by action.yml), writes outputs to $GITHUB_OUTPUT and a job summary.
# Exit codes: 0 = pass, 1 = findings above the fail-on threshold (or performance below min-performance),
#             2 = the audit could not run (unreachable site, limit hit, timeout) unless fail-on-error is false.
set -euo pipefail

URL="${WEBSKAN_URL:?url is required}"
PAGES="${WEBSKAN_PAGES:-10}"
KEY="${WEBSKAN_KEY:-}"
FAIL_ON="${WEBSKAN_FAIL_ON:-high}"            # high | medium | none
MIN_PERF="${WEBSKAN_MIN_PERFORMANCE:-0}"      # 0 = off; otherwise minimum Lighthouse mobile performance score
TIMEOUT_MIN="${WEBSKAN_TIMEOUT_MINUTES:-20}"
RECHECK_OF="${WEBSKAN_RECHECK_OF:-}"          # auditId of a previous audit → diff fixed / open / new
FAIL_ON_ERROR="${WEBSKAN_FAIL_ON_ERROR:-true}"
MCP="${WEBSKAN_MCP:-https://webskan.com/mcp}"
OUT="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
RESULT_FILE="${WEBSKAN_RESULT_FILE:-${RUNNER_TEMP:-/tmp}/webskan-audit.json}"

for bin in curl jq; do command -v "$bin" >/dev/null || { echo "::error::webskan: $bin is required"; exit 2; }; done
case "$FAIL_ON" in high|medium|none) ;; *) echo "::error::webskan: fail-on must be high, medium or none (got '$FAIL_ON')"; exit 2 ;; esac

setout() { echo "$1=$2" >> "$OUT"; }
could_not_run() {  # <message>
  echo "::error title=Webskan::$1"
  { echo "## Webskan audit: could not run"; echo; echo "$1"; } >> "$SUMMARY"
  setout status error
  [ "$FAIL_ON_ERROR" = "false" ] && exit 0 || exit 2
}

call() {  # call <tool> <json-arguments> -> structuredContent of the tool result (JSON-RPC over Streamable HTTP)
  local body
  body=$(curl -sS --max-time 120 "$MCP" ${KEY:+-H "Authorization: Bearer $KEY"} \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H 'User-Agent: webskan-action/1.0 (+https://github.com/kamilobstawskiagent-ux/webskan-action)' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}") || { echo '{"error":"request to webskan.com failed"}'; return 0; }
  printf '%s\n' "$body" | sed -n 's/^data: //p; /^{/p' | jq -cs 'map(select(.result or .error)) | .[0] | (.result.structuredContent // {error: (.error.message // .result.content[0].text // "unexpected response")})'
}

if [ -n "$RECHECK_OF" ]; then
  START=$(call recheck_website "{\"auditId\":\"$RECHECK_OF\"}")
else
  START=$(call audit_website "{\"url\":\"$URL\",\"pages\":$PAGES}")
fi
ERR=$(jq -r '.error // empty' <<<"$START")
[ -n "$ERR" ] && could_not_run "$ERR"
ID=$(jq -r '.auditId // empty' <<<"$START")
[ -n "$ID" ] || could_not_run "no auditId in the response: $START"
setout audit-id "$ID"
echo "webskan: audit $ID queued for $URL ($(jq -r '.pages // "?"' <<<"$START") pages${RECHECK_OF:+, re-check of $RECHECK_OF}; eta ~$(jq -r '.etaSeconds // "?"' <<<"$START") s)"

DEADLINE=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
STATUS=$(jq -r '.status' <<<"$START"); RES="$START"
while [ "$STATUS" != "done" ] && [ "$STATUS" != "error" ]; do
  [ "$(date +%s)" -lt "$DEADLINE" ] || { setout status timeout; could_not_run "audit $ID did not finish within $TIMEOUT_MIN minutes"; }
  sleep 25
  RES=$(call get_audit "{\"auditId\":\"$ID\"}")
  STATUS=$(jq -r '.status // "error"' <<<"$RES")
  [ "$STATUS" = done ] || [ "$STATUS" = error ] || echo "  $STATUS (eta ~$(jq -r '.etaSeconds // "?"' <<<"$RES") s)"
done
[ "$STATUS" = error ] && could_not_run "audit $ID failed: $(jq -r '.error // .message // "unknown"' <<<"$RES")"

printf '%s\n' "$RES" > "$RESULT_FILE"
setout result-file "$RESULT_FILE"
setout status done
HOST=$(sed -E 's#^[a-z]+://([^/]+).*#\1#' <<<"$URL")
read -r HIGH MEDIUM LOW INFO TOTAL PAGESC PERF_M PERF_D A11Y SEO BP < <(jq -r '[.summary.high, .summary.medium, .summary.low, .summary.info, .summary.total, (.pagesCrawled // "?"), (.lighthouse.mobile.scores.performance // "-"), (.lighthouse.desktop.scores.performance // "-"), (.lighthouse.mobile.scores.accessibility // "-"), (.lighthouse.mobile.scores.seo // "-"), (.lighthouse.mobile.scores["best-practices"] // "-")] | map(tostring) | join(" ")' <<<"$RES")
PLATFORM=$(jq -r '.platform // empty' <<<"$RES")
for kv in high:$HIGH medium:$MEDIUM low:$LOW info:$INFO total:$TOTAL pages-crawled:$PAGESC performance-mobile:$PERF_M performance-desktop:$PERF_D; do setout "${kv%%:*}" "${kv#*:}"; done
HAS_DIFF=$(jq -r 'if .diff then "1" else "" end' <<<"$RES")
if [ -n "$HAS_DIFF" ]; then
  read -r FIXED OPEN NEW UNVER < <(jq -r '[.diff.fixed, .diff.open, .diff.new, .diff.unverified] | map(length|tostring) | join(" ")' <<<"$RES")
  setout fixed "$FIXED"; setout open "$OPEN"; setout new "$NEW"; setout unverified "$UNVER"
fi

echo "webskan: $HOST – $PAGESC pages, findings high $HIGH · medium $MEDIUM · low $LOW · info $INFO; Lighthouse mobile perf $PERF_M (desktop $PERF_D)"
jq -r '.findings[] | select(.severity=="high" or .severity=="medium") | "  [\(.severity)] \(.id): \(.title)\(if ((.pages // [])|length)>0 then " (" + ((.pages // [])[0:2]|join(", ")) + (if ((.pages // [])|length)>2 then " +\(((.pages // [])|length)-2)" else "" end) + ")" else "" end)"' <<<"$RES"
# Annotations: GitHub shows at most 10 of each kind per step; high → error, medium → warning.
jq -r '.findings[] | select(.severity=="high") | "::error title=Webskan [high] \(.id)::\(.title)\(if .detail then " — " + (.detail|tostring|.[0:300]) else "" end)\(if ((.pages // [])|length)>0 then " (" + ((.pages // [])[0:2]|join(", ")) + ")" else "" end)"' <<<"$RES" | head -10
jq -r '.findings[] | select(.severity=="medium") | "::warning title=Webskan [medium] \(.id)::\(.title)\(if .detail then " — " + (.detail|tostring|.[0:300]) else "" end)\(if ((.pages // [])|length)>0 then " (" + ((.pages // [])[0:2]|join(", ")) + ")" else "" end)"' <<<"$RES" | head -10

{ # Job summary (Markdown)
  echo "## Webskan audit: $HOST"
  echo
  echo "Audit \`$ID\` · $PAGESC pages crawled${PLATFORM:+ · platform: $PLATFORM} · $(jq -r '.durationSeconds // "?"' <<<"$RES") s · [finding ids explained](https://webskan.com/developers/findings/)"
  echo
  echo "| Severity | High | Medium | Low | Info |"; echo "|---|---:|---:|---:|---:|"; echo "| Findings | $HIGH | $MEDIUM | $LOW | $INFO |"
  echo
  echo "| Lighthouse (mobile) | Performance | Accessibility | Best practices | SEO |"; echo "|---|---:|---:|---:|---:|"; echo "| Score | $PERF_M | $A11Y | $BP | $SEO |"
  if [ -n "$HAS_DIFF" ]; then
    echo; echo "### Re-check vs. audit \`$RECHECK_OF\`: $FIXED fixed · $OPEN still open · $NEW new · $UNVER could not verify"
    jq -r '(.diff.fixed[] | "- ✅ fixed: `\(.id)` \(.title)"), (.diff.new[] | "- 🆕 new [\(.severity)]: `\(.id)` \(.title)"), (.diff.unverified[] | "- ❔ could not verify: `\(.id)` \(.title)")' <<<"$RES" | head -60
  fi
  echo
  if [ "$((HIGH + MEDIUM))" -gt 0 ]; then
    echo "### High and medium findings"; echo; echo "| Severity | Id | Finding | Pages |"; echo "|---|---|---|---|"
    jq -r '.findings[] | select(.severity=="high" or .severity=="medium") | "| \(.severity) | `\(.id)` | \(.title | gsub("\\|";"\\|")) | \((.pages // [])[0:3] | join("<br>") | gsub("\\|";"\\|"))\(if ((.pages // [])|length)>3 then "<br>+\(((.pages // [])|length)-3) more" else "" end) |"' <<<"$RES" | head -80
  else
    echo "No high or medium findings."
  fi
  ERRS=$(jq -r '(.errors // []) | map("\(.step) (\(.error))") | join("; ")' <<<"$RES")
  [ -n "$ERRS" ] && { echo; echo "Checks that could not run: $ERRS"; }
  echo; echo "Full result: \`$RESULT_FILE\` (JSON, every finding with id, area, severity, detail and pages). Re-check after the fix with \`recheck-of: $ID\`."
} >> "$SUMMARY"

FAIL=0
case "$FAIL_ON" in
  high)   [ "$HIGH" -gt 0 ] && FAIL=1 ;;
  medium) [ "$((HIGH + MEDIUM))" -gt 0 ] && FAIL=1 ;;
esac
if [ "$MIN_PERF" != "0" ] && [ "$PERF_M" != "-" ] && [ "$PERF_M" -lt "$MIN_PERF" ]; then
  echo "::error title=Webskan::Lighthouse mobile performance $PERF_M is below min-performance $MIN_PERF"; FAIL=1
fi
if [ "$FAIL" = 1 ]; then
  echo "webskan: failing the job (fail-on: $FAIL_ON$([ "$MIN_PERF" != 0 ] && echo ", min-performance: $MIN_PERF")). Fix the findings by id, deploy and re-check with recheck-of: $ID."
  setout passed false; exit 1
fi
setout passed true
echo "webskan: passed"

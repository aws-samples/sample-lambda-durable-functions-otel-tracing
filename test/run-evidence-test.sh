#!/usr/bin/env bash
#
# run-evidence-test.sh
# =====================
# End-to-end test for the Durable Functions OTel plugin that ALSO collects
# reviewable evidence of trace + log collection.
#
# What it does (runtime test operations only — NO infrastructure mutation):
#   1. Verifies the deployed function + `live` alias exist (read-only).
#   2. Invokes the durable execution asynchronously.
#   3. Reads the callback_id from CloudWatch Logs and resumes the execution.
#   4. Collects evidence into evidence/<timestamp>/:
#        - 00-run-metadata.json     caller identity, region, function, versions
#        - 01-invoke-response.json  the async invoke response (DurableExecutionArn)
#        - 02-callback.json         callback_id used + send result
#        - 03-xray-trace-summary.json   single unified trace summary
#        - 04-xray-trace-full.json      full trace with all segments/subsegments
#        - 05-spans.txt             derived span tree (span-per-operation)
#        - 06-correlated-logs.json  all log records carrying this execution's traceId
#        - EVIDENCE.md              human-readable report tying it all together
#
# Versioning is managed by IaC (AutoPublishAlias in template.yaml). This script
# does NOT run `aws lambda publish-version` or mutate any resource. If the alias
# is missing, run `sam build && sam deploy` first.
#
# Usage:
#   ./test/run-evidence-test.sh [--wait-review SECONDS]
#
# Env overrides:
#   FUNCTION_NAME (default durable-otel-sample)
#   ALIAS         (default live)
#   REGION        (default us-east-1)   # NOTE: stack lives in us-east-1
#   DOC_ID        (default test-doc-001)

set -euo pipefail

FUNCTION_NAME="${FUNCTION_NAME:-durable-otel-sample}"
ALIAS="${ALIAS:-live}"
REGION="${REGION:-us-east-1}"
DOC_ID="${DOC_ID:-test-doc-001}"
LOG_GROUP="/aws/lambda/${FUNCTION_NAME}"
WAIT_REVIEW=5   # seconds to keep the human-review span open (raise for a bigger gap)

while [ $# -gt 0 ]; do
  case "$1" in
    --wait-review) WAIT_REVIEW="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
EVID="${SCRIPT_DIR}/evidence/${STAMP}"
mkdir -p "$EVID"
AWS=(aws --region "$REGION")

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
log "Region=$REGION Function=$FUNCTION_NAME Alias=$ALIAS  ->  evidence/${STAMP}/"

# 0. Preconditions (read-only) --------------------------------------------------
log "Checking caller identity and that the '$ALIAS' alias exists (read-only)..."
"${AWS[@]}" sts get-caller-identity > "${EVID}/00-caller-identity.json" \
  || fail "No valid AWS credentials for region $REGION."

ALIAS_JSON="$("${AWS[@]}" lambda get-alias --function-name "$FUNCTION_NAME" --name "$ALIAS" 2>/dev/null)" \
  || fail "Alias '$ALIAS' not found on '$FUNCTION_NAME'. Deploy first: sam build && sam deploy"
ALIAS_VERSION="$(printf '%s' "$ALIAS_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["FunctionVersion"])')"
log "Alias '$ALIAS' -> version $ALIAS_VERSION"

python3 - "$EVID" "$REGION" "$FUNCTION_NAME" "$ALIAS" "$ALIAS_VERSION" "$STAMP" <<'PY'
import json, sys
evid, region, fn, alias, ver, stamp = sys.argv[1:7]
ident = json.load(open(f"{evid}/00-caller-identity.json"))
json.dump({
    "timestamp": stamp, "region": region, "function": fn,
    "alias": alias, "aliasVersion": ver,
    "account": ident.get("Account"), "callerArn": ident.get("Arn"),
}, open(f"{evid}/00-run-metadata.json", "w"), indent=2)
PY

# 1. Invoke asynchronously ------------------------------------------------------
log "Invoking durable execution asynchronously (doc_id=$DOC_ID)..."
# For async (Event) invokes the CLI prints StatusCode + DurableExecutionArn to
# stdout; the positional output file holds the function payload (empty here).
"${AWS[@]}" lambda invoke \
  --function-name "$FUNCTION_NAME" --qualifier "$ALIAS" \
  --invocation-type Event --cli-binary-format raw-in-base64-out \
  --payload "{\"doc_id\": \"${DOC_ID}\"}" \
  "${EVID}/_fn-output.json" > "${EVID}/01-invoke-response.json"
cat "${EVID}/01-invoke-response.json"

START_MS="$(( $(date +%s) - 60 ))000"

# 2. Wait for the callback_id to appear in the logs -----------------------------
log "Polling logs for callback_id (up to 90s)..."
CBID=""; TRACE_ID=""
for _ in $(seq 1 30); do
  MSG="$("${AWS[@]}" logs filter-log-events --log-group-name "$LOG_GROUP" \
        --filter-pattern "CALLBACK ID" --start-time "$START_MS" \
        --query 'events[*].message' --output text 2>/dev/null || true)"
  CBID="$(printf '%s' "$MSG" | grep -o 'RESUME: [^ ]*' | tail -n1 | sed 's/RESUME: //' || true)"
  if [ -n "$CBID" ]; then
    TRACE_ID="$(printf '%s' "$MSG" | tr '\t' '\n' | grep 'CALLBACK ID FOR MANUAL RESUME' | tail -n1 \
                | python3 -c 'import sys,json;print(json.loads(sys.stdin.read().strip()).get("traceId",""))' 2>/dev/null || true)"
    break
  fi
  sleep 3
done
[ -n "$CBID" ] || fail "callback_id not found in logs after 90s."
log "callback_id captured (${#CBID} chars). traceId=${TRACE_ID:-<pending>}"

# 3. Keep the review span open, then resume -------------------------------------
log "Holding human-review span for ${WAIT_REVIEW}s..."
sleep "$WAIT_REVIEW"
log "Sending success callback (reviewer=alice)..."
SEND_OUT="$("${AWS[@]}" lambda send-durable-execution-callback-success \
  --cli-binary-format raw-in-base64-out \
  --callback-id "$CBID" \
  --result '{"approved": true, "reviewer": "alice"}' 2>&1 || true)"
python3 - "$EVID" "$CBID" "$SEND_OUT" <<'PY'
import json, sys
evid, cbid = sys.argv[1], sys.argv[2]
send = sys.argv[3] if len(sys.argv) > 3 else ""
json.dump({"callbackId": cbid, "sendResult": send or "OK (empty response = success)"},
          open(f"{evid}/02-callback.json", "w"), indent=2)
PY
log "Callback sent. Waiting 25s for the second invocation (publish) to finish..."
sleep 25

# 4. Resolve traceId (fallback: read any app log in window) ---------------------
if [ -z "$TRACE_ID" ]; then
  TRACE_ID="$("${AWS[@]}" logs filter-log-events --log-group-name "$LOG_GROUP" \
      --filter-pattern "Publishing with approval" --start-time "$START_MS" \
      --query 'events[-1].message' --output text 2>/dev/null \
      | python3 -c 'import sys,json;print(json.loads(sys.stdin.read().strip()).get("traceId",""))' 2>/dev/null || true)"
fi
[ -n "$TRACE_ID" ] || fail "Could not resolve traceId from logs."
# OTel traceId (32 hex) -> X-Ray id: 1-<first8>-<remaining24>
XRAY_ID="1-${TRACE_ID:0:8}-${TRACE_ID:8}"
log "traceId=$TRACE_ID  xrayId=$XRAY_ID"

# 5. Collect X-Ray evidence -----------------------------------------------------
NOW="$(date +%s)"; FROM="$(( NOW - 1200 ))"
log "Fetching X-Ray trace summary + full trace (retry up to 60s for propagation)..."
for _ in $(seq 1 12); do
  "${AWS[@]}" xray get-trace-summaries --start-time "$FROM" --end-time "$NOW" \
    --query "TraceSummaries[?Id=='${XRAY_ID}']" --output json > "${EVID}/03-xray-trace-summary.json" 2>/dev/null || echo '[]' > "${EVID}/03-xray-trace-summary.json"
  if [ "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "${EVID}/03-xray-trace-summary.json")" != "0" ]; then break; fi
  sleep 5
done
"${AWS[@]}" xray batch-get-traces --trace-ids "$XRAY_ID" \
  --output json > "${EVID}/04-xray-trace-full.json" 2>/dev/null || echo '{}' > "${EVID}/04-xray-trace-full.json"

# 6. Collect correlated logs ----------------------------------------------------
log "Collecting log records correlated by traceId..."
"${AWS[@]}" logs filter-log-events --log-group-name "$LOG_GROUP" \
  --start-time "$START_MS" --query 'events[*].message' --output json > "${EVID}/_all-logs.json"

# 7. Build spans tree + correlated-logs + EVIDENCE.md ---------------------------
python3 - "$EVID" "$TRACE_ID" "$XRAY_ID" <<'PY'
import json, sys, os
evid, trace_id, xray_id = sys.argv[1], sys.argv[2], sys.argv[3]

meta = json.load(open(f"{evid}/00-run-metadata.json"))
summary = json.load(open(f"{evid}/03-xray-trace-summary.json"))
full = json.load(open(f"{evid}/04-xray-trace-full.json"))

# --- spans tree ---
lines, span_names = [], []
def walk(seg, depth=0):
    n = seg.get("name", "?"); s = seg.get("start_time"); e = seg.get("end_time")
    dur = f"{e-s:.3f}s" if (s and e) else "-"
    lines.append("  " * depth + f"- {n}  ({dur})")
    if depth > 0 and n not in ("Overhead", "Init", "invocation", "Dwell Time") \
       and "attempt" not in n and "create callback id" not in n and "submitter" not in n \
       and "Durable Execution" not in n:
        span_names.append(n)
    for sub in seg.get("subsegments", []) or []:
        walk(sub, depth + 1)
segs = (full.get("Traces") or [{}])[0].get("Segments", []) if full.get("Traces") else []
for sd in segs:
    try: walk(json.loads(sd["Document"]))
    except Exception: pass
open(f"{evid}/05-spans.txt", "w").write("\n".join(lines) + "\n")

# --- correlated logs ---
raw = json.load(open(f"{evid}/_all-logs.json"))
recs = []
for m in raw:
    try:
        j = json.loads(m)
    except Exception:
        continue
    if j.get("traceId") == trace_id:
        recs.append(j)
os.remove(f"{evid}/_all-logs.json")
if os.path.exists(f"{evid}/_fn-output.json"): os.remove(f"{evid}/_fn-output.json")
json.dump(recs, open(f"{evid}/06-correlated-logs.json", "w"), indent=2)

req_ids = sorted({r.get("requestId") for r in recs if r.get("requestId")})
span_ids = sorted({r.get("spanId") for r in recs if r.get("spanId")})
sampled_all = all(r.get("otelTraceSampled") for r in recs if "otelTraceSampled" in r) and bool(recs)

s0 = summary[0] if summary else {}
dur = s0.get("Duration"); rt = s0.get("ResponseTime"); err = s0.get("HasError")

def yn(b): return "✅" if b else "❌"

md = []
md.append(f"# Evidence — Durable Functions OTel plugin\n")
md.append(f"**Run:** {meta['timestamp']}  |  **Account:** {meta['account']}  |  **Region:** {meta['region']}")
md.append(f"**Function:** `{meta['function']}`  alias `{meta['alias']}` → version {meta['aliasVersion']}\n")
md.append("## 1. Single unified trace across invocations\n")
md.append(f"- **OTel traceId:** `{trace_id}`")
md.append(f"- **X-Ray trace Id:** `{xray_id}`  (same value, X-Ray format `1-<8hex>-<24hex>`)")
md.append(f"- Distinct Lambda invocations sharing this trace (by requestId): **{len(req_ids)}** {yn(len(req_ids) >= 2)}")
for r in req_ids:
    md.append(f"  - `{r}`")
if summary:
    md.append(f"- Trace status OK (no error): {yn(err is False)}  (`HasError={err}`)")
    md.append(f"- **Duration** (wall-clock, incl. human-review wait): `{dur}s`")
    md.append(f"- **Response Time** (compute only): `{rt}s`  {yn(rt is not None and dur is not None and rt < dur)} (compute ≪ wall-clock)")
else:
    md.append("- ⚠️ X-Ray summary not yet available (propagation delay). See 04-xray-trace-full.json.")
md.append("\n## 2. Span-per-operation\n")
md.append(f"Named operation spans found: **{', '.join(dict.fromkeys(span_names)) or '(none)'}**")
md.append("\nFull span tree (both invocations, incl. continuation/replay spans):\n")
md.append("```")
md.append(open(f"{evid}/05-spans.txt").read().rstrip())
md.append("```")
md.append("\n## 3. Log correlation (traceId / spanId stamped on every record)\n")
md.append(f"- Correlated log records collected: **{len(recs)}**")
md.append(f"- Distinct spanIds seen in logs: **{len(span_ids)}**")
md.append(f"- `otelTraceSampled=true` on all app records: {yn(sampled_all)}")
md.append("\nSample records:\n")
md.append("```json")
for r in recs[:4]:
    md.append(json.dumps({k: r.get(k) for k in ("level","message","traceId","spanId","otelTraceSampled","requestId")}, ensure_ascii=False))
md.append("```")
md.append("\n## Files\n")
for f in sorted(os.listdir(evid)):
    md.append(f"- `{f}`")
open(f"{evid}/EVIDENCE.md", "w").write("\n".join(md) + "\n")
print("\n".join(md))
PY

log "Done. Evidence written to: ${EVID}"
log "Open the report:  cat '${EVID}/EVIDENCE.md'"

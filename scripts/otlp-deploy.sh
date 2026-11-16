#!/usr/bin/env bash
# Report one deploy to LGTM: one OTLP log record per restarted Deployment (Loki) and one span
# `deploy` per deploy job (Tempo), POSTed as OTLP/HTTP JSON to the node's Alloy.
#
#   otlp-deploy.sh succeeded|failed           send (needs ELVIRA_OTLP_HTTP_ENDPOINT)
#   otlp-deploy.sh --print succeeded|failed   print both payloads to stdout, send nothing
#
# Telemetry never fails a deploy: every path exits 0. curl only, no jq: the runner image has no
# OTel SDK and nothing here may depend on more than bash, coreutils and curl.
#
# Inputs (environment; the GITHUB_* ones are set by Actions):
#   ELVIRA_OTLP_HTTP_ENDPOINT  http://<node>:4318, set on runner pods by knowledge roles/github_runner
#   TARGET_ENVIRONMENT         development | production
#   TARGET_NAMESPACE           evilflowers-dev | evilflowers-prod
#   DEPLOY_DEPLOYMENTS         space-separated app.kubernetes.io/name of the restarted Deployments
#   DIGEST                     sha256:… the digest check ran against
#   IMAGE                      ghcr.io/<owner>/<repo>
#   DEPLOY_START_NS            restart time, ns since epoch (default: now)
#   DEPLOY_END_NS              end of the digest check, ns since epoch (default: now)
#   TRACE_ID / SPAN_ID         hex ids to use (default: random)
#
# Contract: knowledge vault Proposals/CI-Deploy-Unification.md, "What it sends". Changing an
# argument or a variable name is a breaking change of v1.

set -u

print_only=false
if [ "${1:-}" = "--print" ]; then
  print_only=true
  shift
fi
outcome="${1:-}"
case "$outcome" in
  succeeded | failed) ;;
  *)
    echo "::warning::otlp-deploy.sh: outcome must be succeeded or failed, got '${outcome}'; nothing sent"
    exit 0
    ;;
esac

endpoint="${ELVIRA_OTLP_HTTP_ENDPOINT:-}"
endpoint="${endpoint%/}"
if ! $print_only && [ -z "$endpoint" ]; then
  echo "::warning::ELVIRA_OTLP_HTTP_ENDPOINT is not set on this runner; deploy event not sent"
  exit 0
fi

# --- helpers ---------------------------------------------------------------------------------

now_ns() {
  local t
  t=$(date +%s%N)
  case "$t" in
    *[!0-9]*) echo "$(date +%s)000000000" ;; # BSD date has no %N
    *) echo "$t" ;;
  esac
}

hex_id() { # $1 = bytes
  od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'
}

json_str() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '"%s"' "$s"
}

attr() { # key value → OTLP KeyValue with a string value
  printf '{"key":%s,"value":{"stringValue":%s}}' "$(json_str "$1")" "$(json_str "$2")"
}

attr_list() { # key value… → OTLP KeyValue with an array of strings
  local key=$1 sep="" out=""
  shift
  for v in "$@"; do
    out+="${sep}{\"stringValue\":$(json_str "$v")}"
    sep=","
  done
  printf '{"key":%s,"value":{"arrayValue":{"values":[%s]}}}' "$(json_str "$key")" "$out"
}

join() { # items… → comma-joined
  local IFS=,
  printf '%s' "$*"
}

# --- values ----------------------------------------------------------------------------------

server="${GITHUB_SERVER_URL:-https://github.com}"
repository="${GITHUB_REPOSITORY:-}"
run_id="${GITHUB_RUN_ID:-}"
run_url="${server}/${repository}/actions/runs/${run_id}/attempts/${GITHUB_RUN_ATTEMPT:-1}"

start_ns="${DEPLOY_START_NS:-}"
[ -n "$start_ns" ] || start_ns=$(now_ns)
end_ns="${DEPLOY_END_NS:-}"
[ -n "$end_ns" ] || end_ns=$(now_ns)

trace_id="${TRACE_ID:-}"
[ -n "$trace_id" ] || trace_id=$(hex_id 16)
span_id="${SPAN_ID:-}"
[ -n "$span_id" ] || span_id=$(hex_id 8)

read -r -a deployments <<< "${DEPLOY_DEPLOYMENTS:-}"

if [ "$outcome" = succeeded ]; then
  severity_number=9 severity_text=INFO span_status='{}'
else
  severity_number=17 severity_text=ERROR span_status='{"code":2,"message":"rollout or digest check failed"}'
fi

resource=$(join \
  "$(attr service.name github-actions)" \
  "$(attr service.namespace ci)" \
  "$(attr deployment.environment.name "${TARGET_ENVIRONMENT:-}")" \
  "$(attr k8s.namespace.name "${TARGET_NAMESPACE:-}")")

common=$(join \
  "$(attr vcs.repository.url.full "${server}/${repository}")" \
  "$(attr vcs.ref.head.name "${GITHUB_REF_NAME:-}")" \
  "$(attr vcs.ref.head.revision "${GITHUB_SHA:-}")" \
  "$(attr cicd.pipeline.name "${GITHUB_WORKFLOW:-}")" \
  "$(attr cicd.pipeline.run.id "$run_id")" \
  "$(attr cicd.pipeline.run.url.full "$run_url")" \
  "$(attr oci.manifest.digest "${DIGEST:-}")" \
  "$(attr container.image.name "${IMAGE:-}")")

scope='{"name":"evilflowers-actions/deploy"}'

# One record per Deployment; a deploy that failed before it found any still reports, unnamed.
[ "${#deployments[@]}" -gt 0 ] || deployments=("")
records=()
for d in "${deployments[@]}"; do
  body="deployment ${d:-<none>} ${outcome}"
  attrs=$(join \
    "$(attr event.name deployment)" \
    "$(attr k8s.deployment.name "$d")" \
    "$(attr deployment.status "$outcome")" \
    "$common")
  records+=("$(printf '{"timeUnixNano":"%s","observedTimeUnixNano":"%s","severityNumber":%s,"severityText":"%s","body":{"stringValue":%s},"attributes":[%s],"traceId":"%s","spanId":"%s"}' \
    "$end_ns" "$end_ns" "$severity_number" "$severity_text" "$(json_str "$body")" "$attrs" "$trace_id" "$span_id")")
done

logs=$(printf '{"resourceLogs":[{"resource":{"attributes":[%s]},"scopeLogs":[{"scope":%s,"logRecords":[%s]}]}]}' \
  "$resource" "$scope" "$(join "${records[@]}")")

named=()
for d in "${deployments[@]}"; do
  [ -z "$d" ] || named+=("$d")
done
span_attrs=$(join "$common" "$(attr_list evilflowers.deployments "${named[@]+"${named[@]}"}")")
traces=$(printf '{"resourceSpans":[{"resource":{"attributes":[%s]},"scopeSpans":[{"scope":%s,"spans":[{"traceId":"%s","spanId":"%s","name":"deploy","kind":1,"startTimeUnixNano":"%s","endTimeUnixNano":"%s","attributes":[%s],"status":%s}]}]}]}' \
  "$resource" "$scope" "$trace_id" "$span_id" "$start_ns" "$end_ns" "$span_attrs" "$span_status")

# --- output ----------------------------------------------------------------------------------

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "trace_id=${trace_id}" >> "$GITHUB_OUTPUT"
fi

if $print_only; then
  printf '%s\n%s\n' "$logs" "$traces"
  exit 0
fi

sent=0
send() { # path payload
  if printf '%s' "$2" | curl -fsS --max-time 10 -H 'Content-Type: application/json' \
    --data-binary @- -o /dev/null "${endpoint}$1"; then
    sent=$((sent + 1))
  else
    echo "::warning::could not send the deploy event to ${endpoint}$1; the deploy itself is unaffected"
  fi
}
send /v1/logs "$logs"
send /v1/traces "$traces"
echo "deploy event (${outcome}, trace ${trace_id}): ${sent} of 2 payloads accepted by ${endpoint}"
exit 0

#!/usr/bin/env bash
# Starts one gcp_federation run and prints its result. Uses the curl in Conductor's own image,
# so nothing needs a port-forward. Pass --context to name a kube context: ./run-workflow.sh --context prod
set -euo pipefail
api=http://localhost:8080/api
in_server() { kubectl "$@" -n conductor exec deploy/conductor -- "${cmd[@]}"; }
cmd=(curl -fsS --max-time 5 -X POST -H 'Content-Type: application/json' "$api/workflow/gcp_federation" -d '{}')
id="$(in_server "$@")"
echo "started gcp_federation $id"
for _ in $(seq 30); do
  cmd=(curl -fsS --max-time 5 "$api/workflow/$id?includeTasks=true")
  run="$(in_server "$@")"
  state="$(jq -r '.status // ""' <<<"$run")"
  case "$state" in RUNNING|"") sleep 1 ;; *) break ;; esac
done
case "$state" in
  COMPLETED) jq '{status, output}' <<<"$run" ;;
  RUNNING|"") echo "not done in 30s; is the worker polling? kubectl -n conductor logs deploy/conductor-worker -c worker" >&2; exit 1 ;;
  *) jq -r '"\(.status): \(.tasks[0].reasonForIncompletion // .reasonForIncompletion)"' <<<"$run" >&2; exit 1 ;;
esac

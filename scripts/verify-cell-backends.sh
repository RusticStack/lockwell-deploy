#!/usr/bin/env bash
# Verify three private hosted cells for non-serving diagnostic evidence.
set -euo pipefail

readonly connect_timeout_seconds=5
readonly max_time_seconds=15

usage() {
  echo "usage: $0 --ca-file /absolute/path/to/ca.pem --report /absolute/path/to/report.json HTTPS_BACKEND_1 HTTPS_BACKEND_2 HTTPS_BACKEND_3" >&2
  exit 64
}

fail() {
  echo "cell backend verification failed: $*" >&2
  exit 65
}

[[ $# -eq 7 ]] || usage
[[ $1 == "--ca-file" && $3 == "--report" ]] || usage

ca_file=$2
report_file=$4
shift 4
backend_urls=("$@")

for command_name in curl python3; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "missing required command: $command_name" >&2
    exit 69
  }
done

[[ $ca_file == /* ]] || fail "CA file path must be absolute"
[[ $report_file == /* ]] || fail "report path must be absolute"
[[ -f $ca_file && -r $ca_file ]] || fail "CA file must be a readable regular file"

report_dir=$(dirname -- "$report_file")
report_name=$(basename -- "$report_file")
[[ -d $report_dir && -w $report_dir ]] || fail "report directory must exist and be writable"

# Parse URLs once with the standard library so no shell string operation can
# accidentally accept credentials, fragments, or ambiguous host spellings.
url_metadata=$(python3 - "${backend_urls[@]}" <<'PY'
import json
import sys
from urllib.parse import urlsplit

if len(sys.argv) != 4:
    raise SystemExit("exactly three backend URLs are required")

seen = set()
backends = []
for raw in sys.argv[1:]:
    try:
        parsed = urlsplit(raw)
        port = parsed.port
    except ValueError as exc:
        raise SystemExit(f"invalid backend URL: {exc}") from exc
    if parsed.scheme.lower() != "https":
        raise SystemExit("backend URLs must use HTTPS")
    if not parsed.hostname:
        raise SystemExit("backend URL must include a host")
    if parsed.username is not None or parsed.password is not None:
        raise SystemExit("backend URLs must not include credentials")
    if "?" in raw or "#" in raw or parsed.query or parsed.fragment:
        raise SystemExit("backend URLs must not include a query or fragment")
    if parsed.path not in ("", "/"):
        raise SystemExit("backend URL must not include a path")

    host = parsed.hostname.lower()
    host_for_url = f"[{host}]" if ":" in host else host
    authority = host_for_url if port in (None, 443) else f"{host_for_url}:{port}"
    normalized = f"https://{authority}{parsed.path.rstrip('/')}"
    if normalized in seen:
        raise SystemExit("backend URLs must be unique")
    seen.add(normalized)
    backends.append({"url": normalized, "host": host})

print(json.dumps(backends, separators=(",", ":")))
PY
) || fail "invalid backend URL"

readiness_component_digest() {
  python3 -c '
import hashlib
import json
import sys

body = sys.stdin.read()
try:
    document = json.loads(body)
except json.JSONDecodeError as exc:
    raise SystemExit(f"malformed readiness JSON: {exc.msg}") from exc

if not isinstance(document, dict) or document.get("status") != "ok":
    raise SystemExit("readiness status is not ok")
components = document.get("components")
if not isinstance(components, list):
    raise SystemExit("readiness components are missing")

statuses = {}
for component in components:
    if not isinstance(component, dict):
        raise SystemExit("readiness component is malformed")
    name = component.get("name")
    status = component.get("status")
    if not isinstance(name, str) or not isinstance(status, str) or name in statuses:
        raise SystemExit("readiness component is malformed or duplicated")
    statuses[name] = status

for required in ("database", "storage"):
    if statuses.get(required) != "ok":
        raise SystemExit(f"readiness component {required} is not explicitly ok")

print(hashlib.sha256(body.encode("utf-8")).hexdigest())
' "$readiness_body"
}

probe() {
  local endpoint=$1
  local response
  if ! response=$(curl --disable --fail --silent --show-error --request GET \
    --cacert "$ca_file" \
    --connect-timeout "$connect_timeout_seconds" \
    --max-time "$max_time_seconds" \
    --write-out $'\n%{http_code}' \
    "$endpoint"); then
    return 1
  fi

  local http_status=${response##*$'\n'}
  local body=${response%$'\n'*}
  [[ $http_status =~ ^2[0-9]{2}$ ]] || return 1
  printf '%s' "$body"
}

report_backends=()
for backend_index in 0 1 2; do
  backend_url=$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])[int(sys.argv[2])]["url"])' "$url_metadata" "$backend_index")
  backend_host=$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])[int(sys.argv[2])]["host"])' "$url_metadata" "$backend_index")
  base_url=${backend_url%/}

  probe "${base_url}/healthz" >/dev/null || fail "${backend_host} health probe did not succeed"
  readiness_body=$(probe "${base_url}/readyz") || fail "${backend_host} readiness probe did not succeed"
  readiness_digest=$(printf '%s' "$readiness_body" | readiness_component_digest) || fail "${backend_host} readiness response was not acceptable"
  report_backends+=("${backend_host}"$'\t'"${readiness_digest}")
done

checked_at=$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"))')
report_tmp=$(mktemp "${report_dir}/.${report_name}.tmp.XXXXXX")
trap 'rm -f -- "$report_tmp"' EXIT
chmod 600 "$report_tmp"
[[ $(stat -c '%a' "$report_tmp") == 600 ]] || fail "report filesystem cannot enforce 0600 permissions"

python3 - "$checked_at" "${report_backends[@]}" >"$report_tmp" <<'PY'
import json
import sys

checked_at = sys.argv[1]
backends = []
for item in sys.argv[2:]:
    host, digest = item.split("\t", 1)
    backends.append({"host": host, "status": "ok", "readiness_sha256": digest})

print(json.dumps({"checked_at": checked_at, "status": "ok", "backends": backends}, separators=(",", ":")))
PY

mv -f -- "$report_tmp" "$report_file"
trap - EXIT
echo "cell backend verification passed; report written to ${report_file}"

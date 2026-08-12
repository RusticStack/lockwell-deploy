#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/scripts/verify-cell-backends.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fake_bin="$tmp_dir/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url=
seen_ca=0
seen_connect_timeout=0
seen_max_time=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cacert)
      [[ $# -ge 2 && $2 == "$CURL_EXPECTED_CA" ]] || { echo "missing expected CA file" >&2; exit 2; }
      seen_ca=1
      shift 2
      ;;
    --connect-timeout)
      [[ $# -ge 2 && $2 == 5 ]] || { echo "unexpected connect timeout" >&2; exit 2; }
      seen_connect_timeout=1
      shift 2
      ;;
    --max-time)
      [[ $# -ge 2 && $2 == 15 ]] || { echo "unexpected max time" >&2; exit 2; }
      seen_max_time=1
      shift 2
      ;;
    --insecure|-k)
      echo "insecure TLS option is forbidden" >&2
      exit 2
      ;;
    https://*)
      url=$1
      shift
      ;;
    *)
      shift
      ;;
  esac
done

[[ -n $url && $seen_ca == 1 && $seen_connect_timeout == 1 && $seen_max_time == 1 ]] || {
  echo "missing required curl arguments" >&2
  exit 2
}
case "${CURL_SCENARIO:-success}" in
  request-failure)
    exit 22
    ;;
  success)
    readiness='{"status":"ok","components":[{"name":"database","status":"ok"},{"name":"storage","status":"ok"}]}'
    ;;
  unchecked)
    readiness='{"status":"ok","components":[{"name":"database","status":"ok"},{"name":"storage","status":"unchecked"}]}'
    ;;
  malformed-json)
    readiness='not-json'
    ;;
  *)
    echo "unknown fake curl scenario: ${CURL_SCENARIO}" >&2
    exit 2
    ;;
esac

if [[ "$url" == */healthz ]]; then
  printf '\n200'
elif [[ "$url" == */readyz ]]; then
  printf '%s\n200' "$readiness"
else
  echo "unexpected URL: $url" >&2
  exit 2
fi
EOF
chmod +x "$fake_bin/curl"

ca_file="$tmp_dir/test-ca.pem"
printf '%s\n' 'not-a-real-certificate-used-only-by-the-fake-curl-test' >"$ca_file"
report="$tmp_dir/report.json"
backends=(https://cell-a.example.test https://cell-b.example.test https://cell-c.example.test)

run_success() {
  CURL_SCENARIO=success CURL_EXPECTED_CA="$ca_file" PATH="$fake_bin:$PATH" "$script" \
    --ca-file "$ca_file" --report "$report" "${backends[@]}"
}

mode_probe="$tmp_dir/mode-probe"
: >"$mode_probe"
chmod 600 "$mode_probe"
if [[ $(stat -c '%a' "$mode_probe") != 600 ]]; then
  echo "SKIP: filesystem cannot represent POSIX 0600; run this test on Linux" >&2
  exit 0
fi

run_success
[[ $(stat -c '%a' "$report") == 600 ]] || { echo "report permissions are not 0600" >&2; exit 1; }
python3 - "$report" <<'PY'
import hashlib
import json
import sys

with open(sys.argv[1], encoding="utf-8") as report_file:
    report = json.load(report_file)

readiness = b'{"status":"ok","components":[{"name":"database","status":"ok"},{"name":"storage","status":"ok"}]}'
expected_digest = hashlib.sha256(readiness).hexdigest()
assert report["status"] == "ok"
assert report["checked_at"].endswith("Z")
assert [backend["host"] for backend in report["backends"]] == [
    "cell-a.example.test", "cell-b.example.test", "cell-c.example.test"
]
assert all(backend["status"] == "ok" for backend in report["backends"])
assert all(backend["readiness_sha256"] == expected_digest for backend in report["backends"])
assert "components" not in json.dumps(report)
PY

expect_failure() {
  local scenario=$1
  local failure_report="$tmp_dir/${scenario}.json"
  shift
  if CURL_SCENARIO="$scenario" CURL_EXPECTED_CA="$ca_file" PATH="$fake_bin:$PATH" "$script" \
    --ca-file "$ca_file" --report "$failure_report" "$@"; then
    echo "expected ${scenario} verifier run to fail" >&2
    exit 1
  fi
  [[ ! -e "$failure_report" ]] || { echo "failed run wrote a report for ${scenario}" >&2; exit 1; }
}

expect_failure success "${backends[0]}" "${backends[0]}/" "${backends[2]}"
expect_failure success "${backends[0]}" "https://CELL-A.example.test:443" "${backends[2]}"
expect_failure success "https://operator:secret@cell-a.example.test" "${backends[1]}" "${backends[2]}"
expect_failure success "https://cell-a.example.test?unexpected=query" "${backends[1]}" "${backends[2]}"
expect_failure unchecked "${backends[@]}"
expect_failure request-failure "${backends[@]}"
expect_failure malformed-json "${backends[@]}"

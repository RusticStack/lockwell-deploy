#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

want=ffcca38841adb694b6f380647e15f17c446a4d1656fed51a1e2041d064c94cc8
got=$(sha256sum LICENSE | awk '{print $1}')
if [[ "$got" != "$want" ]]; then
  echo "LICENSE does not match canonical PolyForm Noncommercial 1.0.0: $got" >&2
  exit 1
fi

grep -Fx 'Required Notice: Copyright RusticStack.' NOTICE
grep -F 'Commercial use requires a separate written commercial license' NOTICE
grep -F 'does not replace, narrow, or relicense' THIRD_PARTY_NOTICES.md
grep -F 'not OSI' README.md

# The image currently downloads a historical v0.2.1 binary whose release assets
# predate the selected terms. Do not attach a PolyForm OCI label until the pinned
# release archive itself carries verified LICENSE and NOTICE material.
if grep -q 'org.opencontainers.image.licenses="PolyForm-Noncommercial-1.0.0"' Dockerfile; then
  echo 'Dockerfile must not relabel the historical downloaded binary' >&2
  exit 1
fi

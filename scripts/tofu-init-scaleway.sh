#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 /absolute/path/to/backend.s3.tfbackend" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
backend_config=$1
[[ "$backend_config" = /* ]] || {
  echo "backend configuration path must be absolute" >&2
  exit 2
}
[[ -f "$backend_config" ]] || {
  echo "backend configuration file does not exist: $backend_config" >&2
  exit 2
}

if grep -Eiq '^[[:space:]]*(access_key|secret_key|session_token|token|password)[[:space:]]*=' "$backend_config"; then
  echo "backend configuration must not contain credentials; use the standard AWS environment/config chain" >&2
  exit 2
fi

required=(bucket key region use_lockfile encrypt)
for field in "${required[@]}"; do
  grep -Eq "^[[:space:]]*${field}[[:space:]]*=" "$backend_config" || {
    echo "backend configuration is missing required field: $field" >&2
    exit 2
  }
done

grep -Eq '^[[:space:]]*use_lockfile[[:space:]]*=[[:space:]]*true([[:space:]]*#.*)?$' "$backend_config" || {
  echo "backend configuration must set use_lockfile = true" >&2
  exit 2
}
grep -Eq '^[[:space:]]*encrypt[[:space:]]*=[[:space:]]*true([[:space:]]*#.*)?$' "$backend_config" || {
  echo "backend configuration must set encrypt = true" >&2
  exit 2
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
module_dir=$(cd -- "$script_dir/../infra/scaleway" && pwd)

tofu -chdir="$module_dir" init -reconfigure -backend-config="$backend_config"

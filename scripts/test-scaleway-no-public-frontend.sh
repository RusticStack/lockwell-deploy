#!/usr/bin/env bash
# Keep the hosted-cell allocation module incapable of exposing independent
# embedded metadata authorities through a public S3 load balancer.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scaleway_dir="$repo_root/infra/scaleway"

for forbidden_resource in scaleway_lb_ip scaleway_lb scaleway_lb_private_network scaleway_lb_backend scaleway_lb_frontend; do
  if grep -R --line-number --include='*.tf' --fixed-strings "resource \"${forbidden_resource}\"" "$scaleway_dir"; then
    echo "${forbidden_resource} would reintroduce an unsafe public serving path; see infra/scaleway/README.md#public-serving-blocker" >&2
    exit 1
  fi
done

if grep -R --line-number --include='*.tf' --fixed-strings 'cell_backend_ips' "$scaleway_dir"; then
  echo 'cell_backend_ips must not reintroduce a multi-writer serving activation path' >&2
  exit 1
fi

echo 'Scaleway hosted-cell module remains fail closed: no S3 load-balancer serving path exists.'

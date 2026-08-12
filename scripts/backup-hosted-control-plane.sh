#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 OUTPUT_DIRECTORY" >&2
  echo "requires LOCKWELL_SAAS_DATABASE_URL and LOCKWELL_BACKUP_AGE_RECIPIENT" >&2
  exit 64
}

[[ $# -eq 1 ]] || usage
: "${LOCKWELL_SAAS_DATABASE_URL:?LOCKWELL_SAAS_DATABASE_URL is required}"
: "${LOCKWELL_BACKUP_AGE_RECIPIENT:?LOCKWELL_BACKUP_AGE_RECIPIENT is required}"

for command_name in pg_dump age sha256sum stat; do
  command -v "${command_name}" >/dev/null 2>&1 || { echo "missing required command: ${command_name}" >&2; exit 69; }
done

output_dir=$1
[[ -d "${output_dir}" ]] || { echo "output directory does not exist: ${output_dir}" >&2; exit 66; }
[[ ! -L "${output_dir}" ]] || { echo "output directory must not be a symbolic link" >&2; exit 66; }

umask 077
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
archive_name="lockwell-saas-postgres-${timestamp}.dump.age"
archive_path="${output_dir}/${archive_name}"
partial_path="${archive_path}.partial.$$"
checksum_path="${archive_path}.sha256"
manifest_path="${archive_path}.json"
trap 'rm -f -- "${partial_path}" "${checksum_path}.partial" "${manifest_path}.partial"' EXIT

[[ ! -e "${archive_path}" && ! -e "${checksum_path}" && ! -e "${manifest_path}" ]] || {
  echo "refusing to overwrite an existing backup" >&2
  exit 73
}

PGDATABASE="${LOCKWELL_SAAS_DATABASE_URL}" pg_dump --format=custom --compress=6 --no-owner --no-privileges \
  | age --recipient "${LOCKWELL_BACKUP_AGE_RECIPIENT}" --output "${partial_path}"

archive_bytes=$(stat -c '%s' "${partial_path}")
[[ "${archive_bytes}" -gt 0 ]] || { echo "encrypted backup is empty" >&2; exit 74; }
mv -- "${partial_path}" "${archive_path}"
archive_sha256=$(sha256sum --binary "${archive_path}" | awk '{print $1}')
printf '%s  %s\n' "${archive_sha256}" "${archive_name}" > "${checksum_path}.partial"
printf '{"schema_version":1,"created_at":"%s","archive":"%s","bytes":%s,"sha256":"%s","encryption":"age","dump_format":"postgres-custom"}\n' \
  "${timestamp}" "${archive_name}" "${archive_bytes}" "${archive_sha256}" > "${manifest_path}.partial"
mv -- "${checksum_path}.partial" "${checksum_path}"
mv -- "${manifest_path}.partial" "${manifest_path}"

echo "created ${archive_path}"
echo "verify restoration in an isolated database before promoting this backup"

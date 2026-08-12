#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 ARCHIVE CHECKSUM AGE_IDENTITY_FILE VERIFY_DATABASE_URL" >&2
  echo "the target database name must start with lockwell_restore_verify_ and must be empty" >&2
  exit 64
}

[[ $# -eq 4 ]] || usage
archive_path=$1
checksum_path=$2
identity_path=$3
verify_database_url=$4

for command_name in age pg_restore psql sha256sum; do
  command -v "${command_name}" >/dev/null 2>&1 || { echo "missing required command: ${command_name}" >&2; exit 69; }
done
[[ -f "${archive_path}" && ! -L "${archive_path}" ]] || { echo "archive must be a regular non-symlink file" >&2; exit 66; }
[[ -f "${checksum_path}" && ! -L "${checksum_path}" ]] || { echo "checksum must be a regular non-symlink file" >&2; exit 66; }
[[ -f "${identity_path}" && ! -L "${identity_path}" ]] || { echo "identity must be a regular non-symlink file" >&2; exit 66; }

expected_sha256=$(awk 'NR == 1 { print $1 }' "${checksum_path}")
[[ "${expected_sha256}" =~ ^[[:xdigit:]]{64}$ ]] || { echo "invalid checksum file" >&2; exit 65; }
actual_sha256=$(sha256sum --binary "${archive_path}" | awk '{print $1}')
[[ "${actual_sha256,,}" == "${expected_sha256,,}" ]] || { echo "backup checksum mismatch" >&2; exit 65; }

database_name=$(psql "${verify_database_url}" --no-psqlrc --tuples-only --no-align --command='SELECT current_database()')
[[ "${database_name}" == lockwell_restore_verify_* ]] || {
  echo "refusing restore: target database must start with lockwell_restore_verify_" >&2
  exit 77
}
table_count=$(psql "${verify_database_url}" --no-psqlrc --tuples-only --no-align --command="SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema')")
[[ "${table_count}" == "0" ]] || { echo "refusing restore: verification database is not empty" >&2; exit 77; }

age --decrypt --identity "${identity_path}" "${archive_path}" | pg_restore --list >/dev/null
age --decrypt --identity "${identity_path}" "${archive_path}" \
  | pg_restore --single-transaction --exit-on-error --no-owner --no-privileges --dbname="${verify_database_url}"

required_tables=$(psql "${verify_database_url}" --no-psqlrc --tuples-only --no-align --command="SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('customer_accounts','control_plane_outbox','usage_rollups','hosted_invoices')")
[[ "${required_tables}" == "4" ]] || { echo "restore is missing required control-plane tables" >&2; exit 65; }
invalid_constraints=$(psql "${verify_database_url}" --no-psqlrc --tuples-only --no-align --command="SELECT count(*) FROM pg_constraint WHERE NOT convalidated")
[[ "${invalid_constraints}" == "0" ]] || { echo "restore contains unvalidated constraints" >&2; exit 65; }

echo "restore verification passed for ${database_name} (${actual_sha256})"

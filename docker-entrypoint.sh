#!/bin/sh
# Lockwell container entrypoint.
#
# The embedded metadata engine is single-process: the daemon takes an exclusive
# lock, so the first tenant + access key cannot be created via the CLI while
# lockwelld is running. This entrypoint bootstraps them BEFORE starting the
# daemon, the first time the container boots with the bootstrap env vars set:
#
#   LOCKWELL_ROOT_ACCESS_KEY_ID   access key id for the initial admin key
#   LOCKWELL_ROOT_SECRET_KEY      its secret
#   LOCKWELL_ROOT_TENANT          tenant id to create/use (default: root)
#
# Optionally it also creates the first admin WEB-UI user (separate from the S3
# access key above — the UI uses a bcrypt username/password login), when set:
#
#   LOCKWELL_ADMIN_USERNAME       admin UI login (e.g. "admin")
#   LOCKWELL_ADMIN_PASSWORD       its password
#   LOCKWELL_ADMIN_ROLE           owner | operator | viewer (default: owner)
#
# It is idempotent — on every restart the create commands tolerate "already
# exists", so credentials are created exactly once and never clobbered. Omit the
# env vars to skip bootstrap entirely (e.g. you provision keys out of band).
set -e

is_truthy() {
	case "${1:-}" in
		1 | true | TRUE | yes | YES | on | ON)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

# Fail fast on the .env.example sentinels. The compose `:?` guard only catches
# UNSET/empty vars, so a copied-but-unedited .env (CHANGE_ME_* placeholders) would
# otherwise sail through and bootstrap a guessable root credential. Reject any
# bootstrap value that still carries the CHANGE_ME sentinel before it is used.
for _sentinel_var in LOCKWELL_ROOT_ACCESS_KEY_ID LOCKWELL_ROOT_SECRET_KEY LOCKWELL_ADMIN_PASSWORD; do
	eval "_sentinel_val=\${$_sentinel_var:-}"
	case "$_sentinel_val" in
		CHANGE_ME*)
			echo "lockwell: $_sentinel_var still has its CHANGE_ME placeholder value." >&2
			echo "lockwell: edit your .env with real, randomly-generated credentials (see .env.example) before starting." >&2
			exit 1
			;;
	esac
done

# Only bootstrap when actually launching the daemon (not for one-off CLI runs).
if [ "$1" = "lockwelld" ] && is_truthy "${LOCKWELL_BOOTSTRAP_REQUIRED:-false}"; then
	if [ -z "${LOCKWELL_ROOT_ACCESS_KEY_ID:-}" ] || [ -z "${LOCKWELL_ROOT_SECRET_KEY:-}" ]; then
		echo "lockwell: LOCKWELL_BOOTSTRAP_REQUIRED is true, but LOCKWELL_ROOT_ACCESS_KEY_ID / LOCKWELL_ROOT_SECRET_KEY are not both set." >&2
		echo "lockwell: set them as deployment secrets, or set LOCKWELL_BOOTSTRAP_REQUIRED=false if you provision credentials out of band." >&2
		exit 1
	fi
fi

if [ "$1" = "lockwelld" ] && [ -n "$LOCKWELL_ROOT_ACCESS_KEY_ID" ] && [ -n "$LOCKWELL_ROOT_SECRET_KEY" ]; then
	tenant="${LOCKWELL_ROOT_TENANT:-root}"
	echo "lockwell: first-boot bootstrap for tenant '${tenant}' (idempotent)..."
	# These run offline against the embedded store and generate the at-rest
	# master key (if encryption is on) that the daemon then loads — same config,
	# same data dir, so the keys agree. '|| true' makes a restart a no-op.
	lockwell tenant-create "${tenant}" --yes >/dev/null 2>&1 || true
	lockwell key-create root --tenant "${tenant}" \
		--read --write --delete --admin \
		--access-key-id "${LOCKWELL_ROOT_ACCESS_KEY_ID}" \
		--secret-key "${LOCKWELL_ROOT_SECRET_KEY}" >/dev/null 2>&1 || true

	# Optional: first admin web-UI user, so port 9001's /admin is usable at once.
	if [ -n "$LOCKWELL_ADMIN_USERNAME" ] && [ -n "$LOCKWELL_ADMIN_PASSWORD" ]; then
		lockwell admin-create "${LOCKWELL_ADMIN_USERNAME}" \
			--password "${LOCKWELL_ADMIN_PASSWORD}" \
			--role "${LOCKWELL_ADMIN_ROLE:-owner}" >/dev/null 2>&1 || true
	fi
	echo "lockwell: bootstrap done; starting daemon."
fi

exec "$@"

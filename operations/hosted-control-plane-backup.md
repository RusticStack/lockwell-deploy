# Hosted control-plane backup and restore drill

This runbook covers the PostgreSQL authority used by `RusticStack/lockwell-saas`. It does not back up Lockwell object
cells; each cell requires its own encrypted metadata, blob, master-key, and restore drill.

## Contract

- Target RPO: 24 hours until a shorter owner-approved value is adopted.
- Target restore drill: at least monthly and before every hosted production release.
- Keep at least one encrypted copy in a separate approved EU account or provider with immutability/retention enabled.
- The backup runner receives the database read credential and an age **recipient only**. Keep the age identity in a
  separate recovery trust boundary so compromise of the backup job cannot decrypt historical customer/account data.
- PostgreSQL provider snapshots are useful, but they do not replace a portable logical backup and isolated restore.
- Never put a database URL, age identity, metrics token, Stripe secret, or generated backup in Git, CI logs, URLs, or
  pull-request artifacts.

## Create an encrypted portable backup

Install PostgreSQL client tools matching or newer than the managed database major version and
[age](https://github.com/FiloSottile/age). Inject secrets from the deployment secret manager:

```bash
export LOCKWELL_SAAS_DATABASE_URL='postgresql://...'
export LOCKWELL_BACKUP_AGE_RECIPIENT='age1...'
mkdir -m 700 /var/lib/lockwell-backups/outgoing
./scripts/backup-hosted-control-plane.sh /var/lib/lockwell-backups/outgoing
```

The command streams a PostgreSQL custom-format dump directly into age, uses restrictive permissions, refuses
overwrites and symlink output directories, and publishes the encrypted archive only after both sides of the pipeline
succeed. It emits a SHA-256 sidecar and a non-secret JSON manifest. Upload all three files to the immutable backup
destination, verify the uploaded checksum by provider readback, then remove the local outgoing copy according to the
approved retention policy.

## Verify restore without touching production

Create a new empty database whose name starts with `lockwell_restore_verify_`. Use a different server/project when
testing disaster recovery. The verification script refuses any other database name and any non-empty target:

```bash
export LOCKWELL_RESTORE_VERIFY_DATABASE_URL='postgresql://.../lockwell_restore_verify_20260812'
./scripts/verify-hosted-control-plane-restore.sh \
  /recovery/lockwell-saas-postgres-YYYYMMDDTHHMMSSZ.dump.age \
  /recovery/lockwell-saas-postgres-YYYYMMDDTHHMMSSZ.dump.age.sha256 \
  /run/secrets/lockwell-backup-age-identity
```

The drill verifies the ciphertext checksum, decrypts only through pipes, checks archive readability, restores with
`--exit-on-error`, and proves the core account/outbox/meter/invoice tables and constraint validation exist. Then run the
SaaS binary against the restored database with outbound Stripe, email, and cell networking blocked; require `/readyz`,
authenticated customer readback, aggregate counts, and worker dry inspection to match the recorded manifest/runbook.
Destroy the verification database and plaintext-capable recovery environment after recording redacted evidence.

## Evidence record

Record the source database environment, backup manifest SHA-256, immutable object version, age recipient fingerprint,
PostgreSQL client/server versions, restore database identifier, start/end timestamps, table/count comparison, `/readyz`
result, operator/reviewer, and cleanup confirmation. Do not record credentials, decrypted rows, customer emails, Stripe
identifiers, or access-key material.

Escalate immediately if the backup job fails, the immutable upload/readback differs, a scheduled restore is missed, the
archive cannot be decrypted/listed, required tables are absent, constraints are invalid, or the achieved RPO/RTO
exceeds the approved service commitment. A green provider snapshot dashboard alone does not clear the drill.

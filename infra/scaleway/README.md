# Scaleway hosted-cell pilot

This OpenTofu/Terraform module allocates the first reproducible EU hosted topology:

- three Elastic Metal nodes on one private network;
- an HA managed PostgreSQL control-plane database with backups enabled;
- a public load balancer attached to the private network;
- no public S3 frontend until exactly three read-back private cell addresses are supplied.

It does not claim a completed production deployment. Provider credentials, account/project approval, an approved
remote-state bucket, DNS/TLS, node disk layout, Lockwell bootstrap, off-site backup, monitoring, and a node-loss/rebuild
drill are required before apply can become launch evidence.

## Safe workflow

1. Create a dedicated, access-controlled, versioned Object Storage bucket for state. Copy
   `backend.s3.tfbackend.example` outside source control, select a unique key per environment, and keep all credentials
   in the standard AWS environment/config chain. The backend enables encryption and native S3 lockfiles.
2. Copy `terraform.tfvars.example` outside source control and inject the database password from the deployment secret
   manager. Never place credentials in either configuration file.
3. Run `scripts/tofu-init-scaleway.sh /absolute/path/to/backend.s3.tfbackend`, then `tofu fmt -check -recursive`,
   `tofu validate`, and save a reviewed `tofu plan -out` artifact. The wrapper refuses relative paths, credential-bearing
   backend files, disabled encryption, and disabled locking; do not replace it with a bare `tofu init` for an apply.
4. Apply with `cell_backend_ips = []`. This allocates nodes, network, database, and load balancer but no public frontend.
5. On each node, obtain a freshly attached, whole, blank data disk and stage a root-owned `0600` LUKS key file through
   the approved secret-manager handoff. The handoff, provider identity, key generation, escrow, and recovery are
   external operational controls: this repository neither generates nor accepts a raw key on the command line. Run the
   destructive bootstrap only after independently confirming the resolved disk identity:

   ```bash
   device=/dev/sdb
   identity="$(readlink -f -- "$device"):$(lsblk -dnro MAJ:MIN "$device")"
   sudo scripts/bootstrap-encrypted-data-volume.sh --execute \
     --device "$device" --mapper /dev/mapper/lockwell-data --mount /var/lib/lockwell \
     --key-file /etc/lockwell/volume.key \
     --evidence-report /var/lib/lockwell/bootstrap-evidence.json \
     --confirm-device "$identity"
   ```

   The bootstrap refuses anything it cannot prove is safe before mutation: non-root execution; relative or symlinked
   paths; anything other than a whole block disk; a mismatched exact device confirmation; mounted, in-use, root/boot,
   partitioned, filesystem, or recognized-signature devices; non-root-owned/non-`0600` key files; existing mapper or
   configuration conflicts. It creates LUKS2, formats only its newly opened mapper, mounts the filesystem by UUID with
   `nodev,nosuid,noexec`, atomically adds non-conflicting `crypttab` and `fstab` entries, verifies dm-crypt ancestry,
   and writes a root-only report containing digests only. It is not a live recovery or node-loss drill.

   After that gate, stage checksum-pinned
   `lockwell` and `lockwelld` binaries, a validated production config that refers to `/etc/lockwell/tls.crt` and
   `/etc/lockwell/tls.key`, an environment file populated from the secret manager, and the node TLS material. Then run:

   ```bash
   sudo scripts/install-cell-node.sh \
     --lockwelld-bin /absolute/staging/lockwelld --lockwelld-sha256 LOCKWELLD_SHA256 \
     --lockwell-bin /absolute/staging/lockwell --lockwell-sha256 LOCKWELL_SHA256 \
     --config /absolute/staging/lockwell.toml --env-file /absolute/staging/lockwelld.env \
     --tls-cert /absolute/staging/tls.crt --tls-key /absolute/staging/tls.key \
     --data-mount /var/lib/lockwell \
     --unit-template /absolute/checkout/operations/systemd/lockwelld.service
   ```

   The installer refuses non-root execution, relative or symlinked inputs, checksum mismatches, an ordinary directory
   or unencrypted data mount, and configuration validation failures. It installs a dedicated service account and a
   hardened systemd unit, and activates the daemon only after every preflight succeeds. It never partitions, formats,
   opens, or mounts a disk and it does not prove provider identity, secrets provenance, cluster membership, or
   replication, encrypted-volume secret-manager provenance, key escrow/recovery, or a live storage drill. Those remain
   configuration-management and live read-back gates. Read back every node identity and private address before continuing.
6. Run the three-backend gate with the CA that terminates each private backend connection:

   ```bash
   scripts/verify-cell-backends.sh \
     --ca-file /absolute/path/to/private-backend-ca.pem \
     --report /absolute/path/to/cell-backends-readiness.json \
     https://10.0.0.11:9000 https://10.0.0.12:9000 https://10.0.0.13:9000
   ```

   It refuses relative paths, unsafe URLs, duplicate backends, TLS verification bypasses, failed HTTP probes, invalid
   readiness JSON, and database or storage checks that are absent, failed, or `unchecked`. The `0600` JSON report records
   the UTC check time, each backend host, and only a SHA-256 digest of its readiness body; it is pre-load-balancer
   activation evidence, not proof that the provider apply succeeded, that those URLs identify the intended nodes, or that
   replication is healthy.
7. Run the remaining storage, replication, retention, backup, restore, scrub, repair, and node-loss tests. Keep their
   evidence with the readiness report.
8. Supply exactly the three validated private addresses to activate the frontend. Add provider-managed TLS or reviewed
   TLS passthrough before public DNS points to it.

Offer and OS variables are provider lookups because availability varies by zone. A failed lookup is an honest capacity
blocker; do not silently substitute smaller hardware. Reconcile the offer with a current provider quote and the core
`COSTS.md` before apply.

References: [OpenTofu S3 backend](https://opentofu.org/docs/language/settings/backends/s3/),
[Scaleway Object Storage endpoint](https://www.scaleway.com/en/docs/object-storage/api-cli/object-storage-api/),
[bare-metal server](https://registry.terraform.io/providers/scaleway/scaleway/latest/docs/resources/baremetal_server),
[RDB instance](https://registry.terraform.io/providers/scaleway/scaleway/latest/docs/resources/rdb_instance), and
[load balancer](https://registry.terraform.io/providers/scaleway/scaleway/latest/docs/resources/lb).

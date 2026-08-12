# Scaleway hosted-cell pilot

This OpenTofu/Terraform module allocates the first reproducible EU hosted topology:

- three Elastic Metal nodes on one private network;
- an HA managed PostgreSQL control-plane database with backups enabled;
- no public load balancer, public IP, or S3 frontend.

This module is deliberately allocation-only. Lockwell's current cluster-membership and replica runtime does **not**
provide multi-node metadata consistency: each node has an independent embedded metadata authority. Routing S3 writes
across the three cells would therefore create a split-brain, multi-writer deployment. Health and readiness checks cannot
make that safe, so there is no input or hidden override that activates a frontend.

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
4. Apply the allocation-only module. It allocates the cells, private network, and control-plane database; it creates no
   public S3 address, listener, load balancer, backend pool, or frontend.
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
6. If the cells are used for non-serving validation, run the three-node readiness check with the CA that terminates each
   private node connection:

   ```bash
   scripts/verify-cell-backends.sh \
     --ca-file /absolute/path/to/private-backend-ca.pem \
     --report /absolute/path/to/cell-backends-readiness.json \
     https://10.0.0.11:9000 https://10.0.0.12:9000 https://10.0.0.13:9000
   ```

   It refuses relative paths, unsafe URLs, duplicate endpoints, TLS verification bypasses, failed HTTP probes, invalid
   readiness JSON, and database or storage checks that are absent, failed, or `unchecked`. The `0600` JSON report records
   the UTC check time, each node host, and only a SHA-256 digest of its readiness body; it is diagnostic evidence, not
   proof that the provider apply succeeded, that those URLs identify the intended nodes, or that replication is healthy.
7. Run the remaining storage, replication, retention, backup, restore, scrub, repair, and node-loss tests. Keep their
   evidence with the readiness report.

## Public-serving blocker

Do not add a Scaleway load-balancer backend or frontend to this module until an authoritative metadata and routing design
has been implemented and independently verified. A public listener must use one of these safe designs:

- **Single authoritative writer:** route all writes, metadata mutations, and their reads to one metadata authority, with
  documented fencing and failover; any replica/read routing must preserve that authority's consistency guarantees.
- **Real shared or consensus metadata:** replace the independent embedded authorities with metadata replication that has
  an explicit consistency model, quorum/fencing behavior, failure recovery, and end-to-end multi-node tests.

Provider-managed TLS, backend health checks, three successful `/readyz` responses, and a replica-membership report do
not satisfy this blocker. They may become parts of a reviewed serving design, but must not be used as a proxy for
metadata consistency. The static `scripts/test-scaleway-no-public-frontend.sh` contract prevents accidental reintroduction of
the forbidden `scaleway_lb_backend` and `scaleway_lb_frontend` serving resources.

Offer and OS variables are provider lookups because availability varies by zone. A failed lookup is an honest capacity
blocker; do not silently substitute smaller hardware. Reconcile the offer with a current provider quote and the core
`COSTS.md` before apply.

References: [OpenTofu S3 backend](https://opentofu.org/docs/language/settings/backends/s3/),
[Scaleway Object Storage endpoint](https://www.scaleway.com/en/docs/object-storage/api-cli/object-storage-api/),
[bare-metal server](https://registry.terraform.io/providers/scaleway/scaleway/latest/docs/resources/baremetal_server),
[RDB instance](https://registry.terraform.io/providers/scaleway/scaleway/latest/docs/resources/rdb_instance), and
[the Scaleway provider documentation](https://registry.terraform.io/providers/scaleway/scaleway/latest/docs).

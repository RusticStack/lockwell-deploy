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
5. Bootstrap disks, encryption keys, TLS, Lockwell configuration, and three-replica cluster membership through the
   reviewed configuration-management path. Read back every node identity and private address.
6. Run health, storage, replication, retention, backup, restore, scrub, repair, and node-loss tests.
7. Supply exactly the three validated private addresses to activate the frontend. Add provider-managed TLS or reviewed
   TLS passthrough before public DNS points to it.

Offer and OS variables are provider lookups because availability varies by zone. A failed lookup is an honest capacity
blocker; do not silently substitute smaller hardware. Reconcile the offer with a current provider quote and the core
`COSTS.md` before apply.

References: [OpenTofu S3 backend](https://opentofu.org/docs/language/settings/backends/s3/),
[Scaleway Object Storage endpoint](https://www.scaleway.com/en/docs/object-storage/api-cli/object-storage-api/),
[bare-metal server](https://registry.terraform.io/providers/scaleway/scaleway/latest/docs/resources/baremetal_server),
[RDB instance](https://registry.terraform.io/providers/scaleway/scaleway/latest/docs/resources/rdb_instance), and
[load balancer](https://registry.terraform.io/providers/scaleway/scaleway/latest/docs/resources/lb).

# Hosted control-plane monitoring and response

The SaaS process exposes `/healthz`, database-backed `/readyz`, and bearer-protected `/metrics`. Keep the metrics route
on a private monitoring network or reverse-proxy allowlist and store its token in the deployment secret manager. The
Prometheus rules in `operations/prometheus` have fixed labels and are validated with `promtool`; do not add tenant,
account, bucket, access-key, Stripe-customer, event, or job identifiers as metric labels or alert annotations.

Route `critical` alerts to the primary and secondary on-call contacts and `warning` alerts to the operations queue.
Production activation requires a receiver test proving both routes deliver, acknowledge, and escalate. Record the
Prometheus rule revision, Alertmanager configuration revision, receiver test ID, delivery timestamp, acknowledgement,
and redacted incident link. A passing `promtool` test is not evidence of notification delivery.

## LockwellSaaSControlPlaneDown

1. Check the load balancer and process `/healthz`; then check `/readyz` directly over the private path.
2. If health is down, inspect deployment events and resource exhaustion. If only readiness is down, inspect PostgreSQL
   connectivity, pool exhaustion, failover, and TLS/credential expiry.
3. Stop public signup/checkout traffic if the service cannot durably record webhooks or enforce entitlement.
4. Never bypass readiness by serving customer mutations from an instance disconnected from PostgreSQL.

## LockwellSaaSDeadLetterPresent

1. Query the dead-lettered outbox or meter-export row through an approved operator read path; do not paste payloads or
   customer/provider identifiers into chat or alert labels.
2. Classify Stripe API, customer binding, price/meter catalog, cell, vault, or code failure.
3. Correct the external state or deploy a reviewed fix, then use a separately approved replay operation. Direct SQL
   edits are not a replay mechanism.
4. Reconcile the authoritative Stripe object/cell state and customer status after replay.

## LockwellSaaSStripeEventBacklog

1. Confirm Stripe delivery health and compare verified inbox age with worker logs and outbox claims.
2. Preserve the raw verified inbox record; do not ask Stripe to resend until deduplication identity and payload digest
   are confirmed.
3. Suspend provisioning or access changes if entitlement/accounting projections cannot converge safely.
4. Require the backlog to drain and invoice/subscription/customer bindings to reconcile before closure.

## LockwellSaaSOutboxBacklog

1. Determine which fixed worker class is not draining from database/operator diagnostics, not from new metric labels.
2. Check claim lease age, provider availability, PostgreSQL contention, and worker process health.
3. Escalate to critical if the oldest item exceeds the approved entitlement, billing, or provisioning objective, even
   if the aggregate count is small.

## LockwellSaaSProvisionFailure

1. Disable further customer activation for the affected capacity pool.
2. Verify whether tenant, quota, private bucket, scoped key, vault write, or readback failed and whether compensating key
   revocation completed.
3. Never expose a credential or mark a provision ready without authoritative readback of every invariant.
4. After remediation, run the complete provisioning/readback/redemption flow and confirm the customer projection.

## Required dashboard and drill

Dashboard the five alerts plus all exported gauges, `/readyz` status, process restarts, PostgreSQL availability/backup
age, webhook delivery failures, and immutable backup age. Before launch, force each alert in non-production, prove the
expected receiver and escalation path, capture acknowledgement time, and confirm recovery clears the alert. Repeat
after routing changes and at least quarterly under the approved incident programme.

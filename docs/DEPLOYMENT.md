# Production gate

Keep local verification on Wrangler’s local emulator and use only bundle dry runs. Live migrations, deployments, service setup changes and publication require owner approval.

1. Authenticate Wrangler interactively or use an approved least-privilege token without printing it. Use read-only queries to verify the Worker, both D1 databases, schema and migration history, and the existing Tunnel. Review named Worker bindings without exposing values.
2. Review any tables that already exist and agree how existing account, OTP, profile and audit data will be handled. Plan compatible additive migration, an approved backup/restore point, schema roll-forward and Worker rollback. Retain the current Worker deployment/version reference and secret configuration.
3. Confirm profile count, discovery field visibility, consent, regional age policy, data retention, legal review, verified sender identity and production admin bootstrap. Confirm SMS, temporary storage, authenticated Tunnel routing and FCM as separate decisions if desired.
4. With approval, apply reviewed migrations to the existing databases and deploy the Worker under its existing name. Validate readiness, configured Brevo sender, OTP and session protections, customer/admin role separation and anonymized QA records. Keep all fixture flags disabled.
5. Build the Windows x64 QA bundle through the authorized GitHub Actions workflow. Production distribution and signing remain a separate release decision. Approve file routing and transfer separately.

Rollback should use the existing Worker’s deploy history and retain compatible additive schema. Restore or data-changing reconciliation requires a separate reviewed plan. Never assume a fresh replacement of live D1 data is safe.


Read-only inventory after cloud authentication is restored

```powershell
Set-Location E:\J1\worker
npx.cmd wrangler whoami
npx.cmd wrangler deployments list
npx.cmd wrangler secret list
npx.cmd wrangler d1 execute DB_MAIN --remote --command "SELECT name,sql FROM sqlite_schema WHERE name LIKE 'jm_%' ORDER BY name"
npx.cmd wrangler d1 execute DB_OPERATIONS --remote --command "SELECT name,sql FROM sqlite_schema WHERE name LIKE 'jm_%' ORDER BY name"
cloudflared tunnel info 5ce2883f-933e-49c8-ab01-014841037d0e
```

If `jm_migrations` exists, run `SELECT name,applied_at FROM jm_migrations ORDER BY id` on that database through `d1 execute --remote`. Wrangler 4.164.0 initializes the migrations table during `d1 migrations list`. Use the SELECT-only inventory above before any production change is approved.

## Before requesting production approval

1. Record the currently deployed Worker version and inspect the existing D1 schemas and migration history using authenticated read-only access. Review compatibility of existing records with the jm_ tables and take a protected backup through the approved process.
2. Confirm the Worker secret and verified email sender configuration through the Cloudflare dashboard. Keep QA fixtures disabled and keep file transfer and push disabled.
3. Attach the native QA build run, local Worker verification and rollback notes to the release decision. Check the public health route both before and after the approved rollout, then use a separate synthetic test account for end-to-end verification.
4. Apply remote migrations and deploy only on approval, in an agreed change window. If an application rollback is needed, restore the previously recorded Worker version. Review migration compatibility before any data restoration.

Public probes of `/health`, `/admin/dashboard`, and `/readiness` returned HTTP 200 with `Hello World!` during the Admin integration audit. The project expects a JSON health envelope and authentication on both Admin endpoints. Wrangler authentication expired. This blocks verification of the live Worker version, bindings, schemas, migrations, secrets and Brevo delivery. File metadata reuses the existing local migrations. Compare the remote schema and backup coverage before approving either database’s migration list. See STORAGE.md for the separate VPC and origin proposal.

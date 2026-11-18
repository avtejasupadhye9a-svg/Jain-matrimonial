# Production gate

Keep local verification on Wrangler’s local emulator and use only bundle dry runs. Live migrations, deployments, service setup changes and publication require owner approval.

1. Authenticate Wrangler interactively or use an approved least-privilege token without printing it. Use read-only queries to verify the Worker, both D1 databases, schema and migration history, and the existing Tunnel. Review named Worker bindings without exposing values.
2. Review any tables that already exist and agree how existing account, OTP, profile and audit data will be handled. Plan compatible additive migration, an approved backup/restore point, schema roll-forward and Worker rollback. Retain the current Worker deployment/version reference and secret configuration.
3. Confirm profile count, discovery field visibility, consent, regional age policy, data retention, legal review, verified sender identity and production admin bootstrap. Confirm SMS, temporary storage, authenticated Tunnel routing and FCM as separate decisions if desired.
4. With approval, apply reviewed migrations to the existing databases and deploy the Worker under its existing name. Validate readiness, configured Brevo sender, OTP and session protections, customer/admin role separation and anonymized QA records. Keep all fixture flags disabled.
5. Build, sign and distribute Android/Windows packages only after native integration and release verification and explicit publication approval. Approve file routing and transfer separately.

Rollback should use the existing Worker’s deploy history and retain compatible additive schema. Restore or data-changing reconciliation requires a separate reviewed plan. Never assume a fresh replacement of live D1 data is safe.


Read-only inventory after cloud authentication is restored

```powershell
Set-Location E:\J1\worker
npx.cmd wrangler whoami
npx.cmd wrangler d1 execute DB_MAIN --remote --command "SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name"
npx.cmd wrangler d1 execute DB_OPERATIONS --remote --command "SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name"
cloudflared tunnel info jain-matrimonial-storage
```

## Before requesting production approval

1. Record the currently deployed Worker version and inspect the existing D1 schemas and migration history using authenticated read-only access. Review compatibility of existing records with the jm_ tables and take a protected backup through the approved process.
2. Confirm the Worker secret and verified email sender configuration through the Cloudflare dashboard. Keep QA fixtures disabled and keep file transfer and push disabled.
3. Attach the native QA build run, local Worker verification and rollback notes to the release decision. Check the public health route both before and after the approved rollout, then use a separate synthetic test account for end-to-end verification.
4. Apply remote migrations and deploy only on approval, in an agreed change window. If an application rollback is needed, restore the previously recorded Worker version. Review migration compatibility before any data restoration.

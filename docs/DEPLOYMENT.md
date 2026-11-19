# Production gate

Keep local verification on Wrangler’s local emulator and use only bundle dry runs. Live migrations, deployments, service setup changes and publication require owner approval.

1. Authenticate Wrangler interactively or use an approved least-privilege token without printing it. Use read-only queries to verify the Worker, both D1 databases, schema and migration history, and the existing Tunnel. Review named Worker bindings without exposing values.
2. Review any tables that already exist and agree how existing account, OTP, profile and audit data will be handled. Plan compatible additive migration, an approved backup/restore point, schema roll-forward and Worker rollback. Retain the current Worker deployment/version reference and secret configuration.
3. Confirm profile count, discovery field visibility, consent, regional age policy, data retention, legal review, verified sender identity and production admin bootstrap. Confirm SMS, temporary storage, authenticated Tunnel routing and FCM as separate decisions if desired.
4. With approval, apply reviewed migrations to the existing databases and deploy the Worker under its existing name. Validate readiness, configured Brevo sender, OTP and session protections, customer/admin role separation and anonymized QA records. Keep all fixture flags disabled.
5. Build the Windows x64 QA bundle through the authorized GitHub Actions workflow. Production distribution and signing remain a separate release decision. Approve file routing and transfer separately.

Rollback should use the existing Worker’s deploy history and retain compatible additive schema. Restore or data-changing reconciliation requires a separate reviewed plan. Never assume a fresh replacement of live D1 data is safe.

## Admin password cutover

Read-only inspection on 2026-11-19 verified DB_MAIN migrations `0001`–`0004`, the expected Accounts, Sessions and Outbox columns, and one active Admin account. The existing operations database has its baseline migration. The active Worker binds the operations database under `jain-matrimonial-operations`. The project expects `DB_OPERATIONS`, which is already set in the local Wrangler configuration. The existing API returned JSON health and HTTP 401 for an unauthenticated Admin request. D1 Time Travel reported an available bookmark. The Worker has an auth secret and Brevo key, has test auth disabled, and still needs the Admin password pepper. This inventory used metadata and aggregate queries.

1. Confirm the active Admin remains the approved owner identity. Record a fresh recoverable Time Travel bookmark and the active Worker version in the deployment record. Review backup coverage and obtain approval for the remaining production actions.
2. Apply the additive migration through `npx.cmd wrangler d1 migrations apply DB_MAIN --remote` from `worker` after confirming that `0005_admin_password.sql` is the only pending DB_MAIN migration. DB_OPERATIONS needs no migration. Existing account, profile and audit references remain.
3. Generate a random 32-byte `ADMIN_PASSWORD_PEPPER` as 64 lowercase hex characters in the owner's secret manager. Upload the approved Worker code and secret together with `npx.cmd wrangler versions upload --secrets-file <protected-file-outside-the-repo>`. Before routing traffic, confirm the uploaded version binds the existing databases as `DB_MAIN` and `DB_OPERATIONS`, and that test auth stays disabled. Preserve the other configured secrets. Delete the protected staging input after uploading. A standalone `wrangler secret put` deploys immediately. [Cloudflare secret and version behavior](https://developers.cloudflare.com/workers/configuration/secrets/)
4. Run `pwsh -File .\scripts\bootstrap-admin.ps1 -Remote` from the repository root on the owner’s Windows terminal. Enter a scoped Cloudflare D1 Write API token, the requested approval phrase, the password twice, and the matching pepper through the script's prompts. The production path binds only the derived verifier through the Cloudflare D1 management API. The script keeps the known active Admin identity, or requires `-ExistingAdminId` if multiple historical accounts exist. Initialization and revocation of legacy Admin sessions occur together.
5. Deploy the approved uploaded version at 100% using `npx.cmd wrangler versions deploy` and its interactive version selector. Keep the transition in one change window because the old Admin login stops working as the migration and initialization take effect. Confirm hosted KDF execution fits the account's Worker CPU limits. Test Admin sign-in, Change Password, old-session rejection, and an independent customer email OTP. Release the matching Windows EXE afterward. A rollback version must retain password-only Admin access and be compatible with the additive schema.


Repeat the read-only inventory before cutover

```powershell
Set-Location E:\J1\worker
npx.cmd wrangler whoami
npx.cmd wrangler deployments list
npx.cmd wrangler secret list
npx.cmd wrangler d1 execute DB_MAIN --remote --command "SELECT name,sql FROM sqlite_schema WHERE name GLOB 'jm_*' ORDER BY name"
npx.cmd wrangler d1 execute DB_OPERATIONS --remote --command "SELECT name,sql FROM sqlite_schema WHERE name GLOB 'jm_*' ORDER BY name"
cloudflared tunnel info 5ce2883f-933e-49c8-ab01-014841037d0e
```

If `jm_migrations` exists, run `SELECT name,applied_at FROM jm_migrations ORDER BY id` on that database through `d1 execute --remote`. Wrangler 4.164.0 initializes the migrations table during `d1 migrations list`. Use the SELECT-only inventory above before any production change is approved.

## Before requesting production approval

1. Record the currently deployed Worker version and inspect the existing D1 schemas and migration history using authenticated read-only access. Review compatibility of existing records with the jm_ tables and take a protected backup through the approved process.
2. Confirm the Worker secret and verified email sender configuration through the Cloudflare dashboard. Keep QA fixtures disabled and keep file transfer and push disabled.
3. Attach the native QA build run, local Worker verification and rollback notes to the release decision. Check the public health route both before and after the approved rollout, then use a separate synthetic test account for end-to-end verification.
4. Apply remote migrations and deploy only on approval, in an agreed change window. If an application rollback is needed, restore the previously recorded Worker version. Review migration compatibility before any data restoration.

The production verification above covers authentication metadata, both D1 schemas, migration history, and the public/auth-gated API response contract. Hosted password verification and Brevo delivery still require the approved post-cutover checks. See STORAGE.md for the separate VPC and origin proposal.

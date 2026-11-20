# Production gate

Keep local verification on Wrangler’s local emulator and use only bundle dry runs. Live migrations, deployments, service setup changes and publication require owner approval.

1. Authenticate Wrangler interactively or use an approved least-privilege token without printing it. Use read-only queries to verify the Worker, both D1 databases, schema and migration history, and the existing Tunnel. Review named Worker bindings without exposing values.
2. Review any tables that already exist and agree how existing account, OTP, profile and audit data will be handled. Plan compatible additive migration, an approved backup/restore point, schema roll-forward and Worker rollback. Retain the current Worker deployment/version reference and secret configuration.
3. Confirm profile count, discovery field visibility, consent, regional age policy, data retention, legal review, verified sender identity and production admin bootstrap. Confirm SMS, temporary storage, authenticated Tunnel routing and FCM as separate decisions if desired.
4. With approval, apply reviewed migrations to the existing databases and deploy the Worker under its existing name. Validate readiness, configured Brevo sender, OTP and session protections, customer/admin role separation and anonymized QA records. Keep all fixture flags disabled.
5. Build the Windows x64 QA bundle through the authorized GitHub Actions workflow. Production distribution and signing remain a separate release decision. Approve file routing and transfer separately.

Rollback should use the existing Worker’s deploy history and retain compatible additive schema. Restore or data-changing reconciliation requires a separate reviewed plan. Never assume a fresh replacement of live D1 data is safe.

## Admin password cutover

Read-only inventory on 2026-11-20 found the active Worker version 28d7dc58-7e4c-4179-9290-e0c96d005eb9 with DB_MAIN and DB_OPERATIONS. DB_MAIN had migrations 0001 through 0004. The existing VPC service points through the existing tunnel to the loopback origin. The deployed version did not have the STORAGE_ORIGIN VPC binding. Recheck current metadata and migration history before cutover.

1. Confirm the active Admin remains the approved owner identity. Record a fresh recoverable Time Travel bookmark and the active Worker version in the deployment record. Review backup coverage and obtain approval for the remaining production actions.
2. Obtain approval for all pending main migrations. Review 0005_admin_password.sql, 0006_storage_sync.sql and 0007_managed_origin.sql against the live schema and backup. Wrangler applies every pending migration in the configured directory. Only after approval run the DB_MAIN migration command. Reconcile the list if it differs. The current release adds no operations migration.
3. After confirming the pepper is absent, generate a random 32-byte `ADMIN_PASSWORD_PEPPER` as 64 lowercase hex characters in the owner's secret manager. Upload the approved Worker code and secret together with `npx.cmd wrangler versions upload --secrets-file <protected-file-outside-the-repo>`. Before routing traffic, confirm the uploaded version binds the existing databases as `DB_MAIN` and `DB_OPERATIONS`, and that test auth stays disabled. Preserve the other configured secrets. Delete the protected staging input after uploading. A standalone `wrangler secret put` deploys immediately. [Cloudflare secret and version behavior](https://developers.cloudflare.com/workers/configuration/secrets/)
4. Run `pwsh -File .\scripts\bootstrap-admin.ps1 -Remote` from the repository root on the owner’s Windows terminal. Enter a scoped Cloudflare D1 Write API token, the requested approval phrase, the chosen nonempty production password twice, and the matching pepper through the script's prompts. The production path binds only the derived verifier through the Cloudflare D1 management API. The script keeps the known active Admin identity, or requires `-ExistingAdminId` if multiple historical accounts exist. Initialization and revocation of legacy Admin sessions occur together.
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


## Managed storage rollout

1. Complete Windows acceptance on disposable machines. Confirm recovery points for both existing databases, inventory any pre-existing permanent objects and match them to D1 before transferring a role.
2. With owner approval deploy the reviewed Worker and bind STORAGE_ORIGIN to existing Workers VPC service 01a1f73c-fcc5-7432-99dc-b88112da7257. It uses tunnel 5ce2883f-933e-49c8-ab01-014841037d0e and HTTP loopback port 8765. Keep FILE_TRANSFER_ENABLED and B2_STAGING_ENABLED off. Keep customer test authentication disabled.
3. Approve MANAGED_STORAGE_ENABLED for gated admin enrollment. Verify AUTH_SECRET, Admin pepper, private bucket and scoped B2 secret bindings by name and authorized health checks. An existing correctly configured connector can be reused. For automatic provisioning on a fresh machine, separately authorize a tunnel-specific STORAGE_CONNECTOR_TOKEN secret. Preserve the legacy origin credential. No account-level API token belongs on the Admin client. Inspect the existing private B2 bucket's version IDs and lifecycle rules. Pending objects and noncurrent versions must survive a prolonged offline interval until the application's receipt-gated cleanup. Confirm the application key is limited to the intended bucket and prefix, and verify the required version-specific read/write/delete capabilities with approved synthetic files. Review storage budget and expected charges before enabling staging.
4. Use the GUI procedure in STORAGE.md. Verify the designated origin over the signed private route. After separate approval for staging, transfers and cleanup of synthetic test objects, enable B2_STAGING_ENABLED and FILE_TRANSFER_ENABLED for the agreed window. Test an offline upload, reconnect, scanner rejection, complete local readback, the D1 receipt and exact-version cleanup. Verify ownership and private document restrictions on a second Admin PC. Record results before general release.
5. For an incident pause the managed role and gate transfers. Keep receipts, quarantine, B2 objects and permanent files for reconciliation. Roll back using a schema-compatible Worker. Obtain a separate decision for any deletion, credential replacement or data restoration.

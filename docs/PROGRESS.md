# Continuation progress

## Windows release candidate 1.2.0, 2026-11-20

The unsigned x64 installer is E:\J1\dist\JainMatrimonialAdmin-Setup.exe, 37,908,992 bytes. SHA-256 is f4ac08c0aab2899ec962f672d6a53d015e2910e3d1ac1f9e0f4b9a21311af91b. Follow STORAGE.md for GUI installation, backup and migration.

| Area | Verification |
| --- | --- |
| Worker | 12 tests passed including local D1 acceptance, single Admin and customer access, enrollment expiry/replay, primary fencing, signed backup export and manifest registration, inventory-verified migration between two local Python origins, offline retry and receipt-gated version cleanup. TypeScript, formatting and Wrangler dry-run bundling passed. Tests substituted the B2 API and Cloudflare network. |
| Windows storage | Nine Python tests passed including DPAPI designation, service startup/shutdown logic, backup integrity, conflicting restore, ownership, NTFS ACL and hard-link rejection, access controls and retry. The frozen service passed a separate Windows DPAPI and loopback HTTP self-test. |
| Flutter | Admin and customer static analysis passed. Five Admin and three customer widget tests passed. Two client integration tests and the environment-gated Admin UI test ran against local Worker/D1 fixtures. Changing the password invalidated the second Admin session. |
| Installer | Verified the release hash, embedded MSI, all 1,034 extracted payload files, embedded SCM helper, shortcuts, SCM actions and drive/space preflight. The packaged Flutter executable opened a responsive Windows window. |
| Release blockers | Windows canceled elevation for the disposable SCM test. Clean machine-wide install, repair, upgrade, uninstall, Defender under the service account, reboot, crash recovery and a two-PC transfer still need acceptance. The current Worker lacks the private VPC binding and has pending migrations. No production enrollment, B2 upload, cleanup or recovery was performed. |

### Source inventory

- The Windows Admin changes are in admin_app/lib/storage_infrastructure.dart and admin_password.dart. scripts/windows contains the launcher, installer, packaging and acceptance scripts. scripts/storage/Build.ps1 freezes the service.
- local_storage_service/managed.py, windows_host.py and service.py implement machine enrollment, DPAPI, SCM, scanning, backup and restore. The disposable SCM workflow is .github/workflows/storage-server.yml.
- worker/src/index.ts, core.ts, infrastructure.ts, origin.ts, storage.ts and b2.ts implement routing, private transport, staging and cleanup. The additive main migrations 0005, 0006 and 0007 cover Admin passwords, transfer receipts and storage origin management. Feature gates and bindings are in worker/wrangler.toml.
- Worker integration coverage is in worker/test/enrollment.test.mjs and storage-sync.test.mjs. Windows regression coverage includes local_storage_service/test_managed_backup.py and test_windows_host.py. Customer upload and private photo retrieval use customer_app/lib/upload.dart and customer_home.dart.
- STORAGE.md covers GUI operation, DEPLOYMENT.md covers production approvals, API.md lists the routes and NATIVE_BUILDS.md records the build inputs.

## Historical verification

### Admin password-only login

- Verified the local two-character bootstrap and the production 15-character minimum. The loopback UI test kept two clients signed in to the same account, changed the password in Settings, and confirmed the other client lost access. Worker tests also verified separate sessions from the same IP, from different IPs, and customer OTP.

- Added a single Windows Admin password field and Dashboard → Settings → Change Password. Customer email OTP remains in place.
- Added a singleton verifier and versioned Admin sessions through an additive DB_MAIN migration. The private operator script provisioned an isolated local Admin account and refused a second setup.
- Local Worker, Admin and customer widget tests, and both desktop Dart-to-Worker integration checks passed. Cloudflare cutover and a refreshed Windows distribution build are pending.
- Follow-up verification passed on PowerShell 7.6.9 with one-time local bootstrap, a simulated production bootstrap request, and the complete Flutter Admin UI flow against the loopback Worker and D1. The UI signed in, changed the password, rejected the old password, invalidated a second session, and signed out. The Worker tests also exercised malformed verifiers, replacement and deletion protection, throttling, concurrent changes, logout and customer OTP.
- Read-only production inspection confirmed one active Admin and DB_MAIN at migration `0004`. The deployed Worker uses the wrong operations binding name and lacks the Admin pepper. The cutover guide records the approved sequence and the refreshed Windows build steps.

## Admin and Cloudflare integration

- Verified `origin/main` matches the existing implementation in `avtejasupadhye9a-svg/Jain-matrimonial`. Prepared the Windows-only `ci/admin-cloudflare` trigger and runtime package checks.
- Implemented Admin document upload, download and retry over a private Worker-to-PC transport. File metadata and audit use the existing databases and migrations. Added Operations notifications for review queues and removed open Admin screens when the session is cleared.
- The Worker–D1–Python origin integration suite passed locally for permissions, consent revocation, audit, storage corruption, PC interruption and recovery. The Flutter Admin API client also passed local sign-in, profile publication, session restore, logout and rejected reuse of the revoked session. The live API probe and expired credentials are recorded in DEPLOYMENT.md.
- The PC's cloudflared service reported ready with four connections. The proposed origin port had no listener. Production deployment, backup-reviewed migrations, the existing Tunnel’s private VPC binding, actual Defender validation and transfer enablement remain pending.
- The Windows hosted runner passed analysis, widget tests, native build, runtime packaging, and startup checks. The artifact link is in NATIVE_BUILDS.md.

- Customer app. Browse detail reads the saved favorite state from the Worker. Discovery filters validate ranges and profile IDs before applying. Top-level navigation preserves filters and paging. Customers can view and remove their own blocked profiles, and an interest notification opens the relevant record. Draft, pending, correction, approved and suspended states are shown distinctly.
- Profile forms. Required fields and server validation errors appear in the relevant step, including candidate consent and claim email fields in the admin flow.
- Admin app. Authorization is offered only when the server confirms eligibility and current mutual consent. Report and claim records link to profile review. The moderation dialog includes available action history.
- Worker. Scoped block listing, exact interest lookup, contact eligibility and favorite state are backward-compatible additions. Existing D1 migrations and data are intact.
- Native packaging. Separate GitHub Actions jobs are configured for an Android QA APK and a complete Windows x64 bundle. Build status and artifact downloads are available from the workflow runs.
- Production. The authorized deployment gate remains in DEPLOYMENT.md. File transfers, push and temporary cloud storage remain disabled.

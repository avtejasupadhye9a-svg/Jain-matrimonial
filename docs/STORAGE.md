# Windows Admin and permanent storage

## Install an Admin PC

1. Use Windows x64 with a ready, fixed NTFS **E:** drive and at least 700 MiB free for installation. Allow additional space for uploads and backups on the designated server. Keep the drive under administrator control. Enrollment checks existing permanent files for SYSTEM or Administrators ownership, private NTFS ACLs and unexpected links. An insecure existing directory must be reviewed before adoption. Setup checks the existing drive and stops if it is unsuitable.
2. Obtain the unified **JainMatrimonialAdmin-Setup.exe** and **SHA256SUMS.txt** from the release owner. Compare the SHA-256 using a trusted checksum viewer before opening this unsigned build.
3. Double-click the installer, confirm the Windows elevation prompt and select **OK** to install on E:. Open **Jain Matrimonial Admin** from Start or the desktop. Enter the shared Admin password. All installations use the same Worker. For routine Admin work, installation ends here.
4. After the owner approves and completes the cloud rollout, on the selected **main PC** open **Dashboard → Settings → Storage Infrastructure → Enable Main Storage Server**. Confirm the action and approve the local Windows prompts. Leave Defender enabled. The elevated helper creates the enrollment material and configures the service. The app verifies the enrolled PC through the private Worker route.
5. Refresh **Storage Infrastructure**. Check the designated PC, **Private Worker route**, local service, B2 connectivity and pending transfers. Closing the Admin app leaves the installed service running. Production activation remains pending for this release candidate.

Program binaries, configuration, encrypted credentials, logs, state, installer cache and default backups live under E:\JainMatrimonialAdmin. The permanent store defaults to E:\JainMatrimonialStorage. The desktop and Start menu shortcuts, Windows Installer's system-managed cache, service registry and Windows event log use standard Windows locations. Ordinary Admin machines have the packaged service binaries. Only explicit enrollment starts the storage role.

## Synchronization and privacy

Approved uploads enter the private B2 staging bucket when transfer and staging flags are enabled. The Worker retries eligible files on its five-minute schedule. The origin verifies file type, size and SHA-256, requires a successful malware scan, and commits files locally. The Worker journals durable receipts in D1. Cleanup requires the immutable cloud receipt, a fresh hash of the permanent bytes and the correct B2 version. An interrupted operation can be retried. A pending or quarantined file is unavailable for private reads. Access to an identity document requires Admin authorization. The cloud connector has no public file route.

The dashboard displays D1 transfer counts and recorded bytes, the application's staging budget if configured, and free space reported by the signed origin. The bucket probe checks connectivity. Account-wide provider quota, files outside the transfer ledger and disk space on an unreachable PC cannot be measured by these counters. The local tunnel service field refers to the Windows cloudflared service. The private route check also works with the bundled supervised connector.

## Backup, restore and migration

1. On the active PC select **Begin transfer** to pause permanent transfers during a migration. Use **Create backup** for an on-disk snapshot, or **Back up to another drive** and select a protected external NTFS volume. Use encrypted external media for private documents. A same-drive snapshot cannot recover a failed disk.
2. Wait for completion. The service copies files, verifies checksums, exports metadata and receipts, and registers a manifest digest with the Worker. An interrupted backup can reuse the pending copy. Preserve the completed Backup folder. Protect the existing D1 databases separately using the approved cloud backup procedure.
3. On the replacement PC install the same Admin package and sign in. While the role is paused, select **Restore verified backup**, choose the recorded timestamp, then select its matching backup folder. Mismatched manifests, damaged content and conflicting destination files stop restoration. Enrollment material is provisioned separately on the new machine.
4. Retire the old connector through the existing tunnel's approved operator procedure and make the private route reach the replacement PC. On the new PC select **Enable Main Storage Server**. Leave verification running until the Worker confirms the signed challenge and every confirmed file. An interrupted verification can continue using **Verify enrollment**. Refresh the dashboard and check the designated PC before returning the machine to service.
5. If replacement verification fails before promotion, restore the old connector path and use **Resume previous origin** on the previous PC. If the previous PC and its backups are both unavailable, first recover the missing permanent files. B2 objects already cleaned up cannot reconstruct them.

Use **Begin transfer** before **Configure storage location** or **Rotate origin credential**. Location changes copy to a new folder under E:\JainMatrimonialStorage\Locations and verify the copy. Use **Disable main storage** only after checking the designated PC and understanding that this revokes its cloud authorization.

## Repair, upgrade and uninstall

- If the service is unavailable, use **View logs**, verify Defender readiness and free space, then **Repair storage service** or **Restart storage service**. A successful Worker route test confirms the path to the selected identity. **Retry failed transfers** reschedules failed items after the cause has been corrected.
- If management is unavailable on all PCs, check the approved Worker version, migration level, feature flags and VPC binding. If sign-in fails after a password change, use the new password. Changing the shared password revokes Admin sessions on every PC.
- Close the Admin app and rerun the trusted installer to repair. Use the replacement installer to upgrade. Before servicing the main PC, take a verified external backup, pause transfers and schedule an outage. Windows Installer handles binary replacement. Verify local service state, private connectivity and a test transfer afterward.
- Use **Windows Settings → Apps → Installed apps → Jain Matrimonial Admin → Uninstall**. Migrate or revoke the role first. Permanent files, backups and protected state remain with the owner. Retire the machine using your data retention procedure.

## Security and release acceptance

The owner initializes the sole production Admin privately. Client enrollment uses a five-minute, single-use ticket bound to the Admin session and a machine-generated secret. The service protects credentials with machine DPAPI and restrictive ACLs. It runs as LocalSystem for Defender access. Treat local administrators as trusted. The Worker authenticates origin requests and responses and serializes primary changes in D1. The replacement connector needs either its preconfigured Windows service or approved tunnel-specific provisioning at the Worker.

The Windows package has passed local non-elevated checks described in PROGRESS.md. Production distribution requires a disposable E: Windows install, repair, upgrade, uninstall, boot and crash-recovery run, plus a two-PC migration rehearsal. Live B2 and VPC transfer acceptance requires separate owner approval. No production credential belongs in this package.

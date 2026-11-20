# Native build and QA artifacts

## Unified Windows release

Release 1.2.0 is a standalone x64 setup executable in E:\J1\dist. The package uses Flutter 3.50.0 release AOT and freshly built assets from this checkout. The native runner and plugins came from the verified Windows CI bundle from run 44584677746. The packager pins its archive digest and compares the embedded Flutter engine DLL with the AOT compiler SDK. Service builds use Python 3.12, pywin32 311, PyInstaller 6.16.0, Windows cloudflared, WiX 3.14.1 and the x64 .NET Framework C# compiler. End users need no development toolchain.

On the build machine stage a compatible Flutter SDK and reviewed tools on E:. Build release_bundle_windows-x64_assets with the Windows release engine and current lib/main.dart. Build the service with scripts/storage/Build.ps1 into a new E: folder. Run scripts/windows/package.py with --wix, --baseline, --aot, --server and --connector paths. It embeds the MSI in the setup executable and emits its SHA-256 in dist. Feeding a different native bundle requires review of its provenance, ABI and pinned digest.

To validate a candidate, use WiX dark.exe to extract the staged admin.msi into the build's inspect directory and write inspect.wxs. Run scripts/windows/Test-Package.ps1 with -PackageDirectory and -ReleaseExe. It independently compares every extracted file to its build input and checks the embedded payload, shortcuts, SCM actions and preflight.

Privileged acceptance needs a disposable interactive Windows x64 VM, an existing E: NTFS volume, Defender and a recoverable VM snapshot. Never select the production storage PC. Test-InstallerLifecycle.ps1 checks a clean GUI installation, repair, a genuinely different major-upgrade package and safe uninstall with a retained data fixture. Supply reviewed binaries and checksums and set JAIN_DISPOSABLE_WINDOWS_VM=1 only on the test VM. Test-Scm.ps1 exercises real automatic startup configuration and crash recovery with an isolated service and random loopback port. The manual storage-server workflow requires a pre-provisioned isolated runner labelled jain-disposable-e. Physical reboot and two-PC acceptance remain separate tests.

## Native CI bundles

Use the [Native builds workflow](https://github.com/avtejasupadhye9a-svg/Jain-matrimonial/actions/workflows/native-builds.yml) in the existing `avtejasupadhye9a-svg/Jain-matrimonial` repository. The `ci/admin-cloudflare` branch triggers the Windows job. After the update reaches the default branch, manual dispatch there also runs Windows. The `ci/jain-matrimonial-native` branch remains the Android QA build entry point.

- The Android job uses Flutter 3.50.0, JDK 21 and selected Android SDK packages on GitHub’s Linux runner. The job builds an installable debug-signed QA APK. It requires no Android Studio, emulator, release signing key, or Cloudflare credential.
- The Windows job builds a release-mode x64 bundle on the GitHub-hosted Visual Studio runner. It verifies the Flutter engine, native plugins, AOT library, ICU data and assets, includes the app-local Visual C++ runtime, and smoke-tests process startup. Extract the Windows ZIP before opening `jain_admin.exe`. Keep the companion DLLs and data folder together. The QA bundle is unsigned.
- Each job runs static analysis and its own widget tests before building, then uploads its artifact and SHA-256 checksum. The exact download URL appears in the job summary after upload. GitHub may require sign-in for artifact downloads.
- Windows release packages all use the same production HTTPS Worker endpoint and its existing D1 bindings. Android uses its configured endpoint. A build proves packaging. Production features depend on the deployed Worker, migrated databases, and authorized mail configuration.

Artifact names

- jain-matrimonial-customer-apk contains jain-matrimonial-customer.apk
- jain-matrimonial-admin-windows-x64 contains jain-matrimonial-admin-windows-x64.zip

The Admin and Cloudflare integration build passed on branch `ci/admin-cloudflare` at commit `23e8171`. Extract the inner Windows ZIP before launching the app. [Windows x64 QA artifact](https://github.com/avtejasupadhye9a-svg/Jain-matrimonial/actions/runs/44537658362/artifacts/14536003565)

For the password-only release, review and commit the authentication files, then publish the approved commit to `ci/admin-cloudflare` in the same repository. The Windows job builds the updated EXE and publishes a new `jain-matrimonial-admin-windows-x64` artifact. Check the run's commit, verify `SHA256SUMS.txt`, and confirm the EXE opens with one password field. The artifact above predates password-only sign-in. The UI-to-Worker integration test runs separately on an isolated loopback database with synthetic credentials.

Use QA artifacts for testing. Android production release signing, a production distribution identifier, and any public store release require separate approval and configuration. See DEPLOYMENT.md for the Cloudflare migration, rollback and storage gates.

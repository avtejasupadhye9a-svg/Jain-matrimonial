# Native build and QA artifacts

Use the Native builds workflow in .github/workflows/native-builds.yml. It runs on the ci/jain-matrimonial-native branch and can also be dispatched manually once the workflow is on the default branch. The existing GitHub repository is Lasthope027/jain-matrimonial.

- The Android job uses Flutter 3.50.0, JDK 21 and selected Android SDK packages on GitHub’s Linux runner. The job builds an installable debug-signed QA APK. It requires no Android Studio, emulator, release signing key, or Cloudflare credential.
- The Windows job builds a release-mode x64 bundle on the Visual Studio runner. Extract the Windows ZIP before opening jain_admin.exe. Keep the companion DLLs and data folder together. The QA bundle is unsigned.
- Each job runs static analysis and its own widget tests before building, then uploads its artifact and SHA-256 checksum. The exact download URL appears in the job summary after upload. GitHub may require sign-in for artifact downloads.
- Both packages use the configured HTTPS Worker endpoint. A build proves packaging. The corresponding production features depend on the deployed Worker, migrated databases, and authorized mail configuration.

Artifact names

- jain-matrimonial-customer-apk contains jain-matrimonial-customer.apk
- jain-matrimonial-admin-windows-x64 contains jain-matrimonial-admin-windows-x64.zip

Use QA artifacts for testing. Android production release signing, a production distribution identifier, and any public store release require separate approval and configuration. See DEPLOYMENT.md for the Cloudflare migration, rollback and storage gates.

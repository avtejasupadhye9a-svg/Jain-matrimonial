# Native build and QA artifacts

Use the [Native builds workflow](https://github.com/avtejasupadhye9a-svg/Jain-matrimonial/actions/workflows/native-builds.yml) in the existing `avtejasupadhye9a-svg/Jain-matrimonial` repository. The `ci/admin-cloudflare` branch triggers the Windows job. After the update reaches the default branch, manual dispatch there also runs Windows. The `ci/jain-matrimonial-native` branch remains the Android QA build entry point.

- The Android job uses Flutter 3.50.0, JDK 21 and selected Android SDK packages on GitHub’s Linux runner. The job builds an installable debug-signed QA APK. It requires no Android Studio, emulator, release signing key, or Cloudflare credential.
- The Windows job builds a release-mode x64 bundle on the GitHub-hosted Visual Studio runner. It verifies the Flutter engine, native plugins, AOT library, ICU data and assets, includes the app-local Visual C++ runtime, and smoke-tests process startup. Extract the Windows ZIP before opening `jain_admin.exe`. Keep the companion DLLs and data folder together. The QA bundle is unsigned.
- Each job runs static analysis and its own widget tests before building, then uploads its artifact and SHA-256 checksum. The exact download URL appears in the job summary after upload. GitHub may require sign-in for artifact downloads.
- Both packages use the configured HTTPS Worker endpoint. A build proves packaging. The corresponding production features depend on the deployed Worker, migrated databases, and authorized mail configuration.

Artifact names

- jain-matrimonial-customer-apk contains jain-matrimonial-customer.apk
- jain-matrimonial-admin-windows-x64 contains jain-matrimonial-admin-windows-x64.zip

The Admin and Cloudflare integration build passed on branch `ci/admin-cloudflare` at commit `23e8171`. Extract the inner Windows ZIP before launching the app. [Windows x64 QA artifact](https://github.com/avtejasupadhye9a-svg/Jain-matrimonial/actions/runs/44537658362/artifacts/14536003565)

Use QA artifacts for testing. Android production release signing, a production distribution identifier, and any public store release require separate approval and configuration. See DEPLOYMENT.md for the Cloudflare migration, rollback and storage gates.

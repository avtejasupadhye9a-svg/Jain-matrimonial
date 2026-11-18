# Windows setup

Install Git, Node.js 24, npm and Python 3.12 or newer. The project was checked with Flutter 3.50.0 and Dart 3.14.0. Install [Flutter stable](https://docs.flutter.dev/install/manual), Android SDK tooling and a supported JDK via the [Android setup guide](https://docs.flutter.dev/platform-integration/android/setup), and Visual Studio with Desktop development with C++ for [Windows builds](https://docs.flutter.dev/platform-integration/windows/setup).

```powershell
Set-Location E:\J1
flutter doctor -v
flutter config --enable-windows-desktop
.\scripts\setup-local.ps1
.\scripts\test-local.ps1
```

From worker, copy .dev.vars.example to .dev.vars and set a generated local AUTH_SECRET. For synthetic loopback testing only, set JAIN_LOCAL_TEST=true and a separate generated LOCAL_FIXTURE_KEY (at least 32 characters). Use no real identities in fixtures. Start npm.cmd run dev. The script below prompts for the fixture key using concealed terminal input.

```powershell
.\scripts\bootstrap-local-admin.ps1 -Email admin@example.test
```

Run the Windows app from admin_app with flutter run -d windows --dart-define=API_BASE_URL=http://127.0.0.1:8787. For Android, use adb reverse tcp:8787 tcp:8787 and the same loopback API_BASE_URL in flutter run. Use the debug-only sign-in field for the fixture key. Release clients require HTTPS and default to the Worker’s production hostname.

Windows development requires symlink support for plugin registration. Enable Developer Mode or use a machine configured to allow developer symlinks, then use flutter doctor -v to verify Visual Studio. For Android, use flutter doctor --android-licenses after installing the SDK and accept applicable licenses in your own terminal.

Run flutter build apk --debug from customer_app and flutter build windows --debug from admin_app after the native prerequisites are installed. Use flutter analyze and flutter test from each application.

The fresh Git history is in E:\J1\.jain-git because the previous hidden .git could not be moved. Use git --git-dir=E:\J1\.jain-git --work-tree=E:\J1 status and the equivalent arguments for commits. A plain git status in the root still opens the old history.



To exercise both Dart API clients against the real loopback Worker, start an isolated fixture Worker with an empty local test database. Open a separate PowerShell terminal, enter the same fixture key, and run:

```powershell
Set-Location E:\J1\client_shared
$env:JAIN_TEST_API_URL = 'http://127.0.0.1:8787'
$env:JAIN_TEST_FIXTURE_KEY = Read-Host -MaskInput 'Local fixture key'
flutter pub get
flutter test test/local_worker_test.dart
Remove-Item Env:JAIN_TEST_FIXTURE_KEY
```

The integration test uses synthetic identities and creates a profile in the local fixture database. It uses the same API client as the native apps and substitutes test secure storage.

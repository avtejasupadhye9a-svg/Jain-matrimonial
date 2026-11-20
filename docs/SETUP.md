# Windows setup

For installing the Windows application or enabling the permanent storage PC, follow the [installer guide](STORAGE.md). Development toolchains are for contributors.

## Contributor environment

Install Git, Node.js 24, npm and Python 3.12 or newer. The project was checked with Flutter 3.50.0 and Dart 3.14.0. Install [Flutter stable](https://docs.flutter.dev/install/manual), Android SDK tooling and a supported JDK via the [Android setup guide](https://docs.flutter.dev/platform-integration/android/setup), and Visual Studio with Desktop development with C++ for [Windows builds](https://docs.flutter.dev/platform-integration/windows/setup).

```powershell
Set-Location E:\J1
flutter doctor -v
flutter config --enable-windows-desktop
.\scripts\setup-local.ps1
.\scripts\test-local.ps1
```

From `worker`, copy `.dev.vars.example` to `.dev.vars` and set a generated local `AUTH_SECRET`. Generate a separate random 32-byte `ADMIN_PASSWORD_PEPPER` as 64 lowercase hex characters and keep it in the ignored `.dev.vars` file. For short Admin fixture passwords or synthetic customer OTP tests, set `JAIN_LOCAL_TEST=true` and a separate generated `LOCAL_FIXTURE_KEY` of at least 32 characters. Run the local D1 migrations before initial Admin password setup.

```powershell
.\scripts\bootstrap-admin.ps1
```

Use PowerShell 7.4 or later. The script prompts privately for the initial password, confirmation, and matching Worker pepper. Enter the desired nonempty password twice. Both local and production use the same password policy. The script refuses to overwrite an initialized administrator. When multiple historical Admin records exist, select the approved active ID with `-ExistingAdminId`. To change an existing local password, use Dashboard → Settings → Change Password. That ends all Admin sessions, including those on other PCs.

Start `npm.cmd run dev` in `worker`. For a local Windows debug app using local fixtures, run this from `admin_app`. The key is read from the debug process environment, leaving the sign-in screen password-only.

```powershell
$env:JAIN_ADMIN_LOCAL_FIXTURE_KEY = Read-Host -MaskInput 'Matching local fixture key'
flutter run -d windows --dart-define=API_BASE_URL=http://127.0.0.1:8787
Remove-Item Env:JAIN_ADMIN_LOCAL_FIXTURE_KEY
```

For Android, use `adb reverse tcp:8787 tcp:8787` and the same loopback API base. The customer debug-only fixture key field applies to OTP testing. All Windows release EXEs use the same production Cloudflare Worker and its existing D1 bindings.

Windows development requires symlink support for plugin registration. Enable Developer Mode or use a machine configured to allow developer symlinks, then use flutter doctor -v to verify Visual Studio. For Android, use flutter doctor --android-licenses after installing the SDK and accept applicable licenses in your own terminal.

Run flutter build apk --debug from customer_app and flutter build windows --debug from admin_app after the native prerequisites are installed. Use flutter analyze and flutter test from each application.

To exercise both Dart API clients against a real loopback Worker, start an isolated fixture Worker, apply the local migrations, and provision the synthetic Admin password using the script above. Open a separate PowerShell terminal and run:

```powershell
Set-Location E:\J1\client_shared
$env:JAIN_TEST_API_URL = 'http://127.0.0.1:8787'
$env:JAIN_TEST_FIXTURE_KEY = Read-Host -MaskInput 'Local fixture key'
$env:JAIN_TEST_ADMIN_PASSWORD = Read-Host -MaskInput 'Synthetic local Admin password'
flutter pub get
flutter test test/local_worker_test.dart test/local_admin_worker_test.dart
Set-Location E:\J1\admin_app
flutter test test/admin_password_loopback_test.dart
Remove-Item Env:JAIN_TEST_FIXTURE_KEY, Env:JAIN_TEST_ADMIN_PASSWORD
```

These tests use synthetic identities and the same API client as the native apps. The Admin UI test runs last because it changes the isolated Admin password. Use a disposable local database for the test instead of a database with credentials you want to retain.

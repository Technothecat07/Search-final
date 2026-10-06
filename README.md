# SIGNAL Student Search

Flutter mobile Student Search application.

## GitHub APK build

The repository contains the Flutter source and assets. The Android platform
files are generated automatically by GitHub Actions so the repository does
not need to contain a pre-generated `android/` directory.

Go to **Actions → Build SIGNAL APK → Run workflow**.

The workflow:
1. Checks out the repository.
2. Installs stable Flutter.
3. Generates the Android platform files.
4. Verifies `pubspec.yaml`, `lib/main.dart`, and `android/app/build.gradle`.
5. Installs Dart/Flutter dependencies.
6. Builds a release APK.
7. Uploads the APK as a workflow artifact.

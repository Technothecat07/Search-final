flutter create --project-name signal_student_search --org com.signalstudentsearch --platforms android .
flutter pub get
flutter build apk --release
Write-Host "APK: build\app\outputs\flutter-apk\app-release.apk"

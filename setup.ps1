# Putko mobile – one-time platform setup (Windows PowerShell).
# Run from this folder:  powershell -ExecutionPolicy Bypass -File .\setup.ps1
# Generates the android/ and ios/ folders around the existing lib/ and adds the
# permissions the app needs. Safe to run again: it never overwrites lib/ or
# pubspec.yaml, and the patches skip themselves when already applied.

$ErrorActionPreference = "Stop"

Write-Host "1/4  flutter create (adds android/ and ios/ only)..." -ForegroundColor Green
flutter create --org sk.putko --project-name putko --platforms=android,ios .
if ($LASTEXITCODE -ne 0) { throw "flutter create failed" }

# flutter create drops a sample test that references a counter app.
if (Test-Path "test\widget_test.dart") { Remove-Item "test\widget_test.dart" }

Write-Host "2/4  Android manifest: INTERNET + url_launcher queries + app name..." -ForegroundColor Green
$manifest = "android\app\src\main\AndroidManifest.xml"
$xml = Get-Content $manifest -Raw
if ($xml -notmatch "android.permission.INTERNET") {
  $xml = $xml -replace '(<manifest[^>]*>)', "`$1`n    <uses-permission android:name=`"android.permission.INTERNET`"/>"
}
if ($xml -notmatch "android.intent.action.DIAL") {
  $queries = @"
    <queries>
        <intent><action android:name="android.intent.action.VIEW" /><data android:scheme="https" /></intent>
        <intent><action android:name="android.intent.action.SENDTO" /><data android:scheme="mailto" /></intent>
        <intent><action android:name="android.intent.action.DIAL" /><data android:scheme="tel" /></intent>
    </queries>
"@
  $xml = $xml -replace '</manifest>', "$queries`n</manifest>"
}
$xml = $xml -replace 'android:label="putko"', 'android:label="Putko"'
Set-Content $manifest $xml -Encoding UTF8

Write-Host "3/4  iOS Info.plist: photo library / camera texts, URL schemes..." -ForegroundColor Green
$plist = "ios\Runner\Info.plist"
$p = Get-Content $plist -Raw
if ($p -notmatch "NSPhotoLibraryUsageDescription") {
  $add = @"
	<key>NSPhotoLibraryUsageDescription</key>
	<string>Putko needs access to your photos to add pictures of your listing and your host profile.</string>
	<key>NSCameraUsageDescription</key>
	<string>Putko uses the camera to take photos of your listing.</string>
	<key>LSApplicationQueriesSchemes</key>
	<array><string>https</string><string>mailto</string><string>tel</string></array>
"@
  $p = $p -replace '(<dict>)', "`$1`n$add"
}
$p = $p -replace '<string>putko</string>', '<string>Putko</string>'
Set-Content $plist $p -Encoding UTF8

Write-Host "4/4  flutter pub get..." -ForegroundColor Green
flutter pub get

Write-Host ""
Write-Host "Done. Run the app:" -ForegroundColor Green
Write-Host "  flutter run                                   (production API)"
Write-Host "  flutter run --dart-define=API_BASE_URL=http://10.0.2.2:5000/api   (local backend, Android emulator)"

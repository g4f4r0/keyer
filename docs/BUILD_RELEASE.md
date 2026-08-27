# Build, Signing, and Notarization

## Local build

```sh
swift test
xcodebuild -project Keyer.xcodeproj -scheme Keyer \
  -configuration Release -derivedDataPath DerivedData \
  ARCHS=arm64 EXCLUDED_ARCHS=x86_64 \
  CODE_SIGNING_ALLOWED=NO build
```

The Xcode project has no third-party runtime dependency and builds the Apple Silicon Release target with Swift 6 strict concurrency.

## Developer ID archive

Set your own team in Xcode; never commit team credentials or notarization secrets. Then:

```sh
xcodebuild archive \
  -project Keyer.xcodeproj \
  -scheme Keyer \
  -configuration Release \
  -archivePath build/Keyer.xcarchive \
  ARCHS=arm64 EXCLUDED_ARCHS=x86_64 \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  CODE_SIGN_IDENTITY="Developer ID Application"
```

Verify Hardened Runtime, entitlements, and signature before packaging:

```sh
codesign --verify --deep --strict --verbose=2 "build/Keyer.xcarchive/Products/Applications/Keyer.app"
codesign -d --entitlements :- "build/Keyer.xcarchive/Products/Applications/Keyer.app"
spctl --assess --type execute --verbose=2 "build/Keyer.xcarchive/Products/Applications/Keyer.app"
```

Verify that the signed app keeps the expected microphone access and can write and reopen a local Keyer history document before testing settings and Keychain storage.

## Notarization

Create a ZIP or DMG without altering the signed app, submit with a Keychain-backed `notarytool` profile, wait, then staple and validate. Do not publish on any failure.

```sh
ditto -c -k --keepParent "Keyer.app" Keyer.zip
xcrun notarytool submit Keyer.zip --keychain-profile PROJECT_WAVE_NOTARY --wait
xcrun stapler staple "Keyer.app"
xcrun stapler validate "Keyer.app"
spctl --assess --type execute --verbose=2 "Keyer.app"
```

Production release requires zero warnings, a clean archive, permission/device/insertion suites, privacy verification, stress testing, and measured Release performance.

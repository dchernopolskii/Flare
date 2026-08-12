# Mac App Store Release

Flare has two distribution targets in the same Xcode project:

- `FlareJobMonitor` builds the direct GitHub/Homebrew edition with Sparkle.
- `FlareAppStore` builds the Mac App Store edition without Sparkle.

The Store target defines `APP_STORE`, uses `Flare/Info-AppStore.plist` and `Flare/Flare-AppStore.entitlements`, and currently uses the bundle identifier `com.hcf0xf9d.FlareAppStore`.

The Store build supports both Apple Silicon and Intel Macs. SwiftLlama uses optimized ARM kernels on Apple Silicon and generic CPU implementations on Intel.

## One-time App Store Connect setup

1. Register `com.hcf0xf9d.FlareAppStore` as an explicit App ID in the Apple Developer portal.
2. Create the macOS app in App Store Connect and select that bundle ID.
3. Confirm the app name `Flare` is available and set the primary category to Utilities.
4. Use `https://github.com/dchernopolskii/Flare` as the support URL.
5. Publish `PRIVACY.md` on the default branch and use its GitHub page as the privacy policy URL.
6. Complete App Privacy with no data collected. Revisit this answer before adding analytics, crash reporting, accounts, or any developer-operated service.
7. Add the description, keywords, screenshots, copyright, age rating, and review contact.

## Review notes

Include these points with the first submission:

- Flare monitors publicly accessible company career pages and applicant tracking system endpoints selected by the user.
- No account or demo credentials are required.
- The optional AI parser downloads a GGUF model from Hugging Face only after the user enables the feature. The model is a data resource, does not contain executable code, and inference runs entirely on the Mac.
- A reviewer can test the core flow by opening Job Boards, adding a public Greenhouse or Lever careers URL, testing it, and saving it.
- Notifications are optional and are used only for newly discovered jobs.

## Archive and validation

1. Select the `FlareAppStore` scheme and the generic `Any Mac` destination so the archive contains both `arm64` and `x86_64` slices.
2. Set a monotonically increasing integer build number in `CURRENT_PROJECT_VERSION`. Keep `MARKETING_VERSION` aligned with the public release.
3. Choose Product > Archive.
4. In Organizer, run Validate App before uploading to App Store Connect.
5. Confirm the archived app has no Sparkle framework, `SU*` Info.plist keys, or temporary Mach lookup exceptions.
6. Upload the build, add it to an internal TestFlight group, and exercise first launch, notifications, board import/export, cache cleanup, ATS detection, and the optional model download.

Useful archive checks:

```sh
APP="/path/to/Flare.xcarchive/Products/Applications/Flare.app"
plutil -p "$APP/Contents/Info.plist" | grep 'SU' || true
find "$APP/Contents/Frameworks" -maxdepth 1 -iname '*Sparkle*'
codesign -d --entitlements :- "$APP"
```

## Release discipline

The Homebrew/GitHub and Mac App Store editions can share a marketing version, but their build numbers and publication timing are independent. Existing direct-install users remain on Sparkle; the Store edition has a separate sandbox container and does not automatically import their local data.

# Erosion v21 — Airlift / App Decrypt / Passcode preview fixes

## Airlift delete flow
- Moved Delete File / Delete Directory above the read-result output in Actions.
- Replaced the bottom confirmation dialog with the same centered `Alertinator` destructive alert style used by Layouts → Reset (Cancel + red Confirm).
- Successful deletion now reports a complete sentence naming the object type and path. Paths outside `/var/mobile/…` and `/var/tmp/…` receive the requested ` (?)` suffix.

## App Decrypt
- Restored the existing native SwiftUI `.searchable` search field (removed the custom inline TextField).
- Added the existing `info.circle` affordance to every app row.
- The Info action presents the same `InfoViewer` used by the former Bundles metadata rows, populated with the selected app's display name, path, epoch timestamps, and `root:wheel` metadata. The Bundles browser section itself remains removed.

## Passcode artwork preview
- Passcode preview artwork is now rendered with `scaledToFit()` inside a stable 70×70 preview frame.
- No custom width/height clamping or changes to the source bytes, theme processing, or apply pipeline were introduced; configured dimensions still apply to the files written by Apply.

## Validation
- All Swift source files pass `swiftc -frontend -parse`.
- ZIP archive integrity checked after packaging.
- Full Xcode/iOS build not run in this Linux environment.

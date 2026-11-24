# Erosion v25 — Airlift / Browser / Passcode fixes

## PluginKitPlugin
- Removed the Airlift-only AFC listing path from File Browser.
- PluginKitPlugin is enumerated through the same `fsHandlers.getDirPaths` / `bad_query_list` path as the default browser.
- In Airlift mode, the scan supplements InstallationProxy metadata and filters to immediate UUID children.
- Restored the InstallationProxy app-container scan on entry; its completion continues to refresh the PluginKitPlugin listing.
- Removed AFC calls for PluginKitPlugin from its special-container screen and global Rescan. AFC remains available for InternalDaemon and Shared/AppGroup, which are separate roots.

## Inode limits
- All Airlift BadQuery scans now read the persisted `maxInode` File Browser preference.
- The fallback value is the same UI default: 7,500,000.
- Removed hard-coded 500,000 / 100,000 inode ceilings from automatic BadQuery scan call sites.

## Search
- Kept SwiftUI's native `.searchable`; no custom TextField/search implementation was introduced.
- Made its navigation-bar drawer placement explicit and automatic in App Decrypt and File Browser so it collapses with scrolling.

## Custom Passcode navigation rows
- Removed `.buttonStyle(.plain)` only from the Explore and Library navigation rows.
- This restores the standard NavigationLink pressed/highlight feedback. Keypad artwork buttons and Library theme-card buttons were not changed.

## Verification limits
- Changed Swift files pass the Swift frontend parser (`swiftc -frontend -parse`).
- ZIP integrity is checked.
- A full Xcode/iOS build is not available in this Linux workspace; the device build remains the definitive type-check/runtime validation.

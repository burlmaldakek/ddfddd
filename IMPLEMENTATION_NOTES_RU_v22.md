# Erosion v22 — file browser, App Decrypt and permissions fixes

## Changes

- Custom Passcode preview was reverted to the exact v20 implementation; the later `scaledToFit` / fixed 70×70 preview change is removed.
- App Decrypt now uses the same native SwiftUI `.searchable(text:)`, shared list-style preference, and adaptive top margin as FileBrowserView.
- `FileItem.id` is now the standardized filesystem path rather than a newly generated UUID. Re-created metadata rows therefore preserve identity across refreshes and filtering.
- FileBrowserView keeps the last successful directory snapshot visible while a refresh is in progress, instead of replacing every row with a loading row.
- Airlift PluginKitPlugin listing prefers the existing direct AFC `list_dir` probe and filters UUID children from its names-only result. The much broader InstallationProxy scan is now a fallback for this specific directory; a local filesystem / high-inode BadQuery fallback is not used on this plugin-root path.
- `/usr/libexec` POSIX mode and owner/group continue to come from CoreMedia metadata. Its separate `Writable` flag is forced false when the URL is in the app's read-only system-path allowlist; this does not alter the displayed POSIX mode.
- Folder context-menu Delete now uses `.destructive`, consistent with file Delete.
- Airlift remote-delete confirmation includes the target path inline in the warning sentence rather than in a detached paragraph.

## Validation

- All Swift source files passed `swiftc -parse` in this environment.
- ZIP integrity checked after packaging.
- No full Xcode/iOS build was run; runtime behavior on device remains to be confirmed.

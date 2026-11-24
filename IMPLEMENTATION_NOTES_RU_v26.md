# Erosion v26 — UI sections, App Decrypt search, container scan boundaries

## Changes

### Custom Passcode
- Replaced the hand-built `VStack`/rounded-card navigation rows for Explore and Library with native `List` `Section` + `NavigationLink` rows.
- The rows now use the same Settings-style navigation construction as Custom Wallpapers and Dialer Themer.
- Existing Explore and Library destination views and their contents were not changed.
- Key Size and keypad preview controls remain the same views and callbacks; they are hosted in their own List section.

### App Decrypt search
- Extracted the root `List` into `appList`, matching the File Browser's `browserContent` architecture.
- Kept the native SwiftUI `.searchable` modifier, with `.navigationBarDrawer(displayMode: .automatic)`, attached directly to the root `List`.
- No custom search TextField, ScrollView, or nested List was introduced.

### InstallationProxy scope
- Removed the published InstallationProxy InternalDaemon and PluginKitPlugin path arrays from Swift state and stopped parsing those extra path collections from the app-scan payload.
- Removed Rust's recursive `collect_additional_container_paths` walk over every installed app plist, along with the related JSON output. The required `get_apps(all)` call and App Group metadata parsing remain intact for Data/Application and App Groups.
- Added a GitHub Actions regression check that asserts the extra recursive traversal and JSON field stay absent.
- Removed InstallationProxy fallback labels from the dedicated InternalDaemon / PluginKitPlugin screen.
- Removed the per-screen `scanInstalledAppContainers()` call from `AirliftSpecialContainerView`.
- File Browser no longer starts or waits for the shared app scan when entering InternalDaemon, PluginKitPlugin, or SystemGroup roots.
- File Browser still uses InstallationProxy metadata for Data/Application and App Groups.
- The dedicated App Group screen retains its explicit InstallationProxy scan; Data/Application retains its scan path.
- BadQuery/Airlift enumeration remains for InternalDaemon and PluginKitPlugin; SystemGroup continues its existing local/BadQuery enumeration.

## Validation
- 78 Swift source files passed `swiftc -frontend -parse` with Swift 6.2.1.
- Static Rust-source checks confirm `get_apps(all)` and App Group extraction remain, while the special-root recursive plist traversal and output field are absent.
- Grep check confirms no remaining references to the removed special-container InstallationProxy properties/types or lifecycle events.
- ZIP archive integrity checked after packaging.
- Cargo/Rust toolchain and Xcode are unavailable in this environment, so the XCFramework was not rebuilt locally. The workflow rebuilds AirliftFFI from the changed `AirCard-iOS-main/rust-core/` source before the Xcode build; GitHub Actions must be run to produce a new IPA.

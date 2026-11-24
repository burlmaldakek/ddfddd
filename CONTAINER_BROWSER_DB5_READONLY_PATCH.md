# Container browser DB5+ visibility and bad_query log labels

- Restored the six File Browser root entries (Data Containers, Plugin Containers, App Groups, Daemon Containers, System Containers, SystemGroup Containers) in Airlift compatibility mode.
- On compatibility-mode builds, these destinations are opened read-only. File creation/import, rename, compression, and deletion actions are hidden. Existing path-enumeration and permission mechanisms are retained; this patch does not modify container contents.
- For InternalDaemon and PluginKitPlugin result rows, the display label prefers the direct InstallationProxy `sourceApps` mapping, then attempts to resolve `MCMMetadataIdentifier` from the container metadata. If no identifier is available, it displays `Bundle identifier unavailable` instead of showing the UUID as though it were a Bundle ID.
- Renamed visible BadQuery scan/log labels to `bad_query` and removed the `no Airlift Read invoked` line from that scan's output.
- AirLift Read primitives were not changed.

Validation: the modified Swift files passed `swiftc -frontend -parse`. Full Xcode/IPA build and device-side behavior were not tested in this environment.

# App Group Containers / Airlift directory-listing probe

This patch fixes a UI data-flow issue and adds a strictly directory-entry-only AFC probe.

## Existing InstallationProxy result now displayed

`exploit_list_app_containers` already recursively finds values shaped like
`/var/mobile/Containers/Shared/AppGroup/<UUID>` in the InstallationProxy metadata and
returns them as `appGroups`. `AirliftBridge` stored those values in
`installedAppGroups`, but the App Group screen only displayed the separate BadQuery
`appGroupContainerPaths` array. The screen now shows the InstallationProxy-returned
paths directly, including source application bundle IDs, and the parent menu count
includes all discovered path sources.

These UUID path names are physical container identifiers; they are not assumed to
match `group.*` entitlement identifiers.

## Optional Airlift AFC probe

Added `al_list_app_group_container_paths`, which connects over the existing Airlift
pairing/tunnel and calls only `AfcClient::list_dir` on these candidate directory paths:

- `/var/mobile/Containers/Shared/AppGroup`
- `/private/var/mobile/Containers/Shared/AppGroup`

It parses only immediate UUID-shaped entry names. It does not call
`al_exploit_read_file`, `al_exploit_read_folder`, AirTraffic staging, or any write,
rename, move, or delete primitive. If AFC cannot see the absolute path, the returned
log records the exact failure and does not fall back to Airlift Read.

The UI has a separate “Probe with Airlift AFC (listing only)” button. The previous
BadQuery/fsgetpath scans remain manual legacy actions and no longer run automatically
when the App Group screen opens, so they are not a dependency for iOS 27 DB5+.

## Validation

Source, C header declarations, and Swift call sites were checked for matching names.
A local compile could not be run in this environment because Cargo/Xcode are not
installed. The repository's macOS CI runs `build-airlift-ffi.sh` before linking, which
rebuilds the static library from the updated Rust source.

# App Group labels and additional container probes

## App Group Containers
- The list no longer displays identifiers for which no physical container path was returned.
- Where InstallationProxy returns a `GroupContainers`-style mapping, the row title uses that App Group identifier instead of the container UUID.
- The physical UUID remains visible in the full path. When metadata does not establish a safe mapping, the UI says `Group identifier unavailable` rather than guessing.
- The existing BadQuery implementation was not changed. Its existing enumerator is still used only when the user presses the corresponding probe button.

## InternalDaemon and PluginKitPlugin
For each root, the screen can show paths reported by InstallationProxy metadata and run two explicit probes:
- Airlift AFC `list_dir` on allowlisted roots and common path aliases. This lists immediate names only, does not invoke Airlift Read, and performs no device-side writes.
- The existing BadQuery path enumerator, with a bounded 500,000 inode ceiling. The BadQuery implementation itself is unchanged.

The InstallationProxy scan only inspects metadata returned by `get_apps`; it does not enumerate the filesystem. Results depend on the exact metadata returned by the device. AFC may deny these absolute paths, in which case the diagnostic log records the result instead of falling back to Airlift Read.

## Validation
- Swift syntax parse passed for `AirliftBridge.swift` and `AirliftAppGroupContainersView.swift` using `swiftc -frontend -parse`.
- Rust build could not be run in this environment because `cargo`/`rustc` are unavailable. Build the IPA with the project's normal Rust/Swift build workflow before installing.

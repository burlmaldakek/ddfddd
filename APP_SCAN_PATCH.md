# Airlift Installed App / App Group Metadata Scanner

The Home Actions `Scan Apps` / App Containers view still builds the Data/Application list with:

`InstallationProxy -> get_apps(Any, None) -> Bundle ID + Container`

The scanner now also passively inspects the full returned app metadata for values that explicitly identify a path under `/var/mobile/Containers/Shared/AppGroup/`, and for group identifiers in group-related metadata/entitlement fields. It logs the metadata keys returned by the device and displays any direct paths or IDs it finds.

Important limitation: InstallationProxy may not return App Group container paths or entitlements on this iOS build. In that case the UI reports that the path list was not exposed. It does not guess UUIDs, derive them from Data/Application UUIDs, enumerate AppGroup by moving a directory, or read/write device files.

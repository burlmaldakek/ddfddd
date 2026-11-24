# Erosion follow-up changes — 2026-10-18 v4

- File Browser search now remains filtered after dismissing the keyboard or returning from a result; sorting/reloading reapplies the active query.
- Renamed `Other Paths` to `Read-only`, removed its footer, added `/Developer` as a separate read-only path (not `/System/Developer`), and renamed `Experimental` to `Other`.
- Added a virtual `Workspace` folder backed by persistent Application Support storage so files remain after the app exits.
- Airlift Containers segmented picker is visually scaled 5% taller around its center (about 2.5% outward at each edge); row insets/layout position stay unchanged.
- Added `Clear /tmp/` to Airlift's ellipsis menu. It confirms before deleting the contents of Erosion's app temporary directory and is disabled during Airlift exploit/read/passcode-write/container-scan work; the confirmation also warns against clearing during other theme/write tasks.
- Dialer Themer no longer hardcodes the `en` asset prefix. Airlift writes both `en` and `other` filename variants and Airlift key import checks both. Added clearer Airlift logging and a warning that `TelephonyUI-10` is a cache which iOS can regenerate; that OS-level cache eviction cannot be guaranteed against by this app-only patch.

Validation: `swiftc -frontend -parse` succeeded for every Swift file in the project. Full Xcode build and on-device runtime testing were not performed.

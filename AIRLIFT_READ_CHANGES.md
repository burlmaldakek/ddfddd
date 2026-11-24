# Airlift read changes

This build changes the experimental Airlift read path in two ways:

1. File reads now stage the Airlock link before the target FileComplete, matching the working AirCard read sequence. The returned bytes are then written back through the existing two-asset file writer before staging cleanup, so subsequent reads start from a restored target.
2. Folder mode attempts to move a directory into the AFC-visible recovered area, recursively enumerate files through AFC, build a ZIP locally, and recreate the folder through the existing folder writer before restoring Books state.

No timeout multiplier was introduced. The UI exposes File/Folder modes and a Share action for the resulting local file/ZIP.

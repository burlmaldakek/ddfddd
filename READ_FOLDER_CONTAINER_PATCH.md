# Airlift folder-read routing merge

This revision combines the established folder reader from
`Erosion_UI_v4_v6_MediaRead_Merged_PathViewer_Fixes` with the newer
container-safe reader from `Erosion_UI_v4_v6_Containers_ContinueRead_SafeRestore`.

## Routing

- `/var/mobile/Media/...` keeps the existing Media-specific routes: `PhotoData`
  uses its per-file path, and other Media paths use the direct Media reader.
- `/var/mobile/Containers/...` keeps the newer safety-oriented folder reader.
- Exactly `/var/mobile/Containers/Data/Application/<UUID>/` uses the newer
  four-subdirectory aggregation (`tmp/`, `Documents/`, `Library/`, `SystemData/`),
  with every child processed through the newer safety-oriented reader.
- Every other non-Media, non-Containers folder path uses the original folder
  reader from the first source archive. Its established export-and-folder-writer
  return behavior is isolated in `exploit_read_folder_legacy`.

The two ordinary readers are kept as separate functions to avoid globally
applying the newer return/fallback behavior to unrelated paths. The public
`read_folder` dispatcher chooses the reader by path; it does not alter the
file-read, write, scan-apps, or UI path selection APIs. The current Airlift
bridge from the second archive is retained so container safety/partial status
is displayed instead of being presented as a confirmed successful read.

## Restore verification fix

The logs showed two distinct ambiguous outcomes: a recovery key sometimes never
became AFC-visible, and, for another directory, ATC accepted the return but the
new restore alias was still not visible after the first verification window.
The safe restore path now:

- Checks the original target through the existing parent alias before issuing a
  second best-effort handoff from a recovery key that AFC never exposed. If the
  original directory is already present, it does not send another move.
- Verifies the returned object through both the newly-created restore alias and
  the original target-parent alias, requiring a real directory rather than an
  arbitrary AFC entry.
- When both aliases are still invisible after the first verification window,
  reconnects through a fresh tunnel/AFC session and checks the aliases again.
  This is verification-only; it does not send another `FileComplete`. If the
  destination remains unobservable, it retains recovery aliases and preserves
  the unresolved/partial status instead of claiming a confirmed restore.

## Safety notes

The legacy reader is intentionally retained only for paths outside the Media and
Containers namespaces. It has the older behavior from the first source and does
not gain the second reader's newer restoration safeguards. The safer reader
still cannot always independently verify protected paths through AFC, so
`RESTORE UNVERIFIED` must not be interpreted as proof of a failed restore or a
proof of a successful restore.

This merge was statically inspected and the archive contents will be checked.
The current environment has no Rust toolchain or Xcode available, so this is
not a Rust build or an on-device safety validation.

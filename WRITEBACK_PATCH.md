# Airlift writeback verification patch

This patch fixes the false-positive write success condition.

Previously, `al_exploit_write_file` returned success after sending the two `FileComplete` messages and waiting briefly. That only confirmed the AirTraffic session reached that point; it did not prove the exact destination file was committed.

The patched `write_file()` now:
1. completes the existing exact-path write;
2. closes the old AFC/tunnel session;
3. performs a fresh Airlift read of the exact same remote path;
4. compares the read-back bytes with the bytes that were requested to be written;
5. returns success only when the bytes match exactly, logging both SHA-256 hashes.

If the remote file remains unchanged, the write operation now reports a verification failure instead of falsely reporting success.

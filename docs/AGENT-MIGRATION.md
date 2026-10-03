# Agent history migration and rollback

The Linux host now stores task summaries and ordered events in SQLite at `${NEXUSLINK_DATA_DIR:-~/.local/share/nexuslink}/agents.sqlite`. On first start, a worker reads the legacy `~/.cache/nexuslink/agent_sessions.json` (or `NEXUSLINK_LEGACY_AGENT_STORE`), copies it to `.pre-sqlite.bak`, and imports all entries that the old file still contains. Migration is marked in SQLite and will not repeat on restart. The old file is left in place. History previously truncated by the old 100-event save path cannot be reconstructed.

The worker writes in bounded batches, up to 128 events or about 50 ms. Task metadata and events share a transaction. On restart, tasks recorded as running or waiting become interrupted; pending approvals expire. An interrupted task's history stays available, and no agent command runs merely because its metadata was restored.

Before replacing the host, stop the service and back up the entire `~/.local/share/nexuslink` directory plus the legacy `.json` and `.pre-sqlite.bak` files. To roll back to an older host, stop the new service and restore the older executable and its original JSON store. Older versions cannot read events created only in SQLite. Preserve the new SQLite directory until those events are exported or the rollback is abandoned. Never copy only the main `.sqlite` file while the WAL database is running.

If migration fails, read `journalctl --user -u nexuslink-host.service -e`, verify free disk space and read/write permissions, and leave the old JSON file untouched. The host does not delete it automatically.

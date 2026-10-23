--!strict
--[[
	Strings — every piece of text the plugin shows, in one place.
	Format strings take their arguments in the order written in each comment.
	To translate the plugin, translate this file.

	[ @Claude | 23.10.2026 ]
	edited [ @Claude | 23.10.2026 ]
]]

return {
	-- Toolbar & widget
	ToolbarTooltip = "Collaborate in this place through your own server",
	WidgetTitle = "Uncreate",
	FieldServer = "Server",
	FieldServerHint = "1.2.3.4:7878",
	FieldKey = "Key",
	FieldKeyHint = "server password",
	FieldName = "Your name",
	FieldNameHint = "shown to your teammates",
	Connect = "Connect",
	Disconnect = "Disconnect",
	SaveSnapshot = "Save snapshot to server",
	Log = "Log",
	Yes = "Yes",
	Cancel = "Cancel",
	NotConnected = "Not connected",
	OnlineNone = "Online: —",
	OnlineList = "Online (%d): %s", -- count, names
	You = "you",

	-- Status line
	StatusDisconnected = "Disconnected",
	StatusConnecting = "Connecting to %s…", -- address
	StatusLive = "Live · %s · rev %d · %d objects", -- project, rev, objects
	StatusUploadingPlace = "Uploading this place…",
	StatusDownloading = "Downloading project…",
	StatusDownloadingPart = "Downloading project… %d/%d", -- chunk, chunks
	StatusPacking = "Snapshot: packing %d/%d", -- group, groups
	StatusUploading = "Snapshot: uploading %d/%d", -- part, parts
	StatusReconnecting = "Connection lost, reconnecting…",

	-- Questions
	ConfirmHost = "This server is empty. Make the CURRENT place the project on the server?",
	ConfirmJoin = "Everything in this place will be REPLACED by the project from the server. Continue?",

	-- Errors (raised, shown in the status line)
	ErrNoAnswer = "server %s did not answer: %s", -- address, reason
	ErrProtocol = "this server speaks a different protocol version; update Uncreate",
	ErrManifest = "could not get the snapshot: %s", -- reason
	ErrChunk = "snapshot part %d failed to download (HTTP %d)", -- index, status
	ErrSnapshotRefused = "the server refused the snapshot: %s", -- reason
	ErrPartUpload = "snapshot part %d failed to upload (HTTP %d)", -- index, status
	ErrCommit = "the server did not accept the snapshot: %s", -- reason

	-- Log
	LogConnectFirst = "Connect first to save a snapshot",
	LogSnapshotRestarted = "The snapshot changed during download; starting over",
	LogLoaded = "Project loaded: %d objects in %.1f s", -- objects, seconds
	LogSkipped = "Skipped %s: %s", -- name, reason
	LogSendError = "Could not send changes: %s", -- reason
	LogSendRetry = "Could not send changes (HTTP %d); retrying…", -- status
	LogBatchDropped = "Dropped a batch of changes (JSON error): %s", -- reason
	LogUnsyncable = "%s.%s (%s) can't be synced; skipping it", -- class, property, type
	LogSerializeFailed = "Could not serialize %s: %s", -- path, reason
	LogResync = "Full resync: %s", -- reason
	LogResyncHistoryLost = "the server lost part of its history",
	LogResyncCompacted = "the server's history was compacted past our revision",
	LogApplyFailed = "Could not apply a change: %s", -- reason
	LogRestored = "Connection restored",
	LogSnapshotFailed = "Snapshot not uploaded: %s", -- reason
	LogSnapshotDone = "Snapshot @%d uploaded: %d objects, %.1f MB, %.1f s", -- rev, objects, MB, seconds
	LogSnapshotSkipped = "Left out of the snapshot: %s (%s)", -- path, reason
	LogSnapshotCurrent = "The server's snapshot is already up to date",
}

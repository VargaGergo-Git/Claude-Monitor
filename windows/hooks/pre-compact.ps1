# Pre-Compact — remind to preserve key context before compression
# Hook type: PreCompact
# PowerShell version for native Windows Claude Code

@{ systemMessage = "Context is about to be compressed. Make sure any key decisions, file paths, or progress from this session are noted in your response so they survive compaction." } | ConvertTo-Json -Compress

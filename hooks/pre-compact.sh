#!/bin/bash
# Pre-Compact — remind to preserve key context before compression
# Hook type: PreCompact
set -uo pipefail

jq -n '{"systemMessage": "Context is about to be compressed. Make sure any key decisions, file paths, or progress from this session are noted in your response so they survive compaction."}'

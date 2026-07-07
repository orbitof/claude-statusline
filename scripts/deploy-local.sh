#!/usr/bin/env bash
# Deploy this fork's statusline into the local Claude Code config.
# Copies bin/statusline.sh -> $CLAUDE_CONFIG_DIR/statusline.sh (default ~/.claude).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$repo_root/bin/statusline.sh"
dest="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline.sh"

bash -n "$src"                     # fail fast on syntax errors
cp "$src" "$dest"
chmod +x "$dest"
echo "deployed: $src -> $dest"

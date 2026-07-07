# claude-statusline

Configure your Claude Code statusline to show limits, directory and git info

![demo](./.github/demo.png)

> **Personal fork** of [nilbuild/claude-statusline](https://github.com/nilbuild/claude-statusline),
> based on upstream `v1.0.6` with two additions:
>
> - **Session cost** — a `$x.xx` segment on line 1, read from `cost.total_cost_usd`.
> - **Live session effort** — reads `effort.level` from the statusline payload, so
>   per-session `/effort` / `--effort` (including the session-only `max` level, which
>   is never written to `settings.json`) is reflected, not just the persisted default.
>
> This fork is **not published to npm**. Install it from source (below). The upstream
> `npx` command installs the original version *without* these changes.

## Install

Clone the repo and run the deploy script. It runs a syntax check, then copies
`bin/statusline.sh` to `$CLAUDE_CONFIG_DIR/statusline.sh` (default `~/.claude/statusline.sh`):

```bash
git clone https://github.com/orbitof/claude-statusline.git
cd claude-statusline
./scripts/deploy-local.sh
```

Then point Claude Code at the script in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash \"$HOME/.claude/statusline.sh\""
  }
}
```

To pull in later upstream changes and redeploy:

```bash
git fetch upstream && git rebase upstream/main
git push --force-with-lease origin main
./scripts/deploy-local.sh
```

> Prefer the **original** version instead? Install it via npm from
> [nilbuild/claude-statusline](https://github.com/nilbuild/claude-statusline):
> `npx @kamranahmedse/claude-statusline`.

## Requirements

- [jq](https://jqlang.github.io/jq/) — for parsing JSON
- curl — fallback fetch of rate-limit data (recent Claude Code passes rate limits on stdin)
- git — for branch info

On macOS:

```bash
brew install jq
```

## Uninstall

Remove the `statusLine` entry from `~/.claude/settings.json`, and restore your
previous `statusline.sh` if you kept a backup.

## Credits

Fork of [nilbuild/claude-statusline](https://github.com/nilbuild/claude-statusline)
by Kamran Ahmed.

## License

MIT

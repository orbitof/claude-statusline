# claude-statusline

Configure your Claude Code statusline to show limits, directory and git info

English | [日本語](./README.ja.md)

![demo](./.github/demo.png)

> **Personal fork** of [nilbuild/claude-statusline](https://github.com/nilbuild/claude-statusline),
> based on upstream `v1.0.6`. Everything the statusline renders is listed below,
> keyed to the screenshot; **fork** marks what this fork adds or changes
> (origins in [Credits](#credits)).

## What you see

### Line 1 — session

| In the shot | Meaning | Origin |
|---|---|---|
| `Fable 5.1` | Model display name | upstream |
| `✍️ 52%` | Context window used. Green below 50%, orange from 50 — as here — yellow from 70, red from 90 | upstream |
| `⏳ 41m` | Prompt cache: time left before the cached prefix expires and the next turn has to rewrite it. Green, yellow under 15 minutes, red under 5. Read from `prompt_cache.expires_at`; the TTL (`5m` or `1h`) is whatever the last request used | **fork** |
| `⌛ ~85k` *(not in this shot)* | Prompt cache is cold: the next request rewrites about this many tokens (`recache_tokens_if_cold`). The number is dropped when Claude Code already expects a different prefix, e.g. right after a compaction | **fork** |
| `⚠ 2` *(not in this shot)* | Unexpected cache misses this session (`prompt_cache.misses`) — the prefix broke mid-session, usually because the tool set, system prompt, model or effort changed. Shown after either cache state, only when non-zero | **fork** |
| `⚡` | Session runs with `--dangerously-skip-permissions`. The bare bolt sits just before the directory — not to be confused with the `⚡ fast` badge further right | upstream |
| `claude-statusline` | Working directory | upstream |
| `(main)` | Branch, then working-tree counts — `±` modified/renamed/copied/unmerged/typechange, `+` added, `-` deleted, `?` untracked, e.g. `(main 3±,2+,2-,3?)`. Kinds with nothing in them are dropped, which is why this clean tree shows the branch alone | **fork** |
| `⏱ 1h44m` | Session wall clock from `cost.total_duration_ms` — measured time, so it survives resumes. Renders `Ns` under a minute and `Nm` under an hour | **fork** |
| `$12.75` | Session cost from `cost.total_cost_usd`. Hidden on Z.ai-backed sessions, where it would only be an Anthropic-pricing estimate | **fork** |
| `⚡ fast` *(not in this shot)* | Fast mode is on (`fast_mode`) — the labelled bolt, distinct from the skip-permissions one | **fork** |
| `🧠 off` *(not in this shot)* | Thinking is disabled (`thinking.enabled == false`) | **fork** |
| `1M` | Context exceeds the 200k default (`exceeds_200k_tokens`) | **fork** |
| `● high` | Effort level — `◉ max`, `● xhigh`, `● high`, `◑ medium`, `◔ low`. Read live from `effort.level`, so `/effort` and the session-only `max` show up; falls back to the persisted default when the model reports none | **fork** |

### Lines 2-4 — rate limits

| In the shot | Meaning | Origin |
|---|---|---|
| `current` / `weekly` | The 5-hour and weekly windows | upstream |
| `●○○○○○○○○○  10%` / `18%` | Ten-cell bar and utilization, on the same color ramp as the context percentage — green at these levels, yellow from 70, red from 90 | upstream |
| `→  51%` / `→  77%` | Where the window ends up if the pace so far holds. Green below 80, orange from 80, yellow from 90, red from 100 | **fork** |
| `⟳ 5:30am` / `⟳ sep 8, 10:00am` | When the window resets | upstream |
| `(4h1m)` / `(5d8h)` | Time left until that reset — `NdNh` past a day, `NhNm` past an hour, `Nm` below | **fork** |
| `extra   ○○○○○○○○○○ $0.00/$0.00 ⟳ oct 1` | Flex-rate usage and its monthly limit, shown only while `extra_usage` is enabled on the account — here enabled with nothing spent yet | upstream |

On a Z.ai-backed session each bar also carries the raw credit count
(`5.4k/12k`) between the projection and the reset time — **fork**.

The projection is deliberately absent early in a window: it needs three
minutes of the 5-hour window and two hours of the weekly one before the
extrapolation means anything, and it is dropped entirely if the reset time
implies an elapsed time longer than the window itself (a stale cache) rather
than rendered from dead data.

## Behavior under the hood

- Rate limits come from the statusline payload when Claude Code supplies them,
  otherwise from the Anthropic OAuth usage API, refreshed at most once a
  minute; if a refresh fails the last cached response is reused. Upstream
  behavior, with this fork publishing cache writes atomically so a concurrent
  reader never sees a half-written file
- **Z.ai (GLM) sessions** — when `ANTHROPIC_BASE_URL`'s host is `z.ai` or a
  subdomain, both windows are read from Z.ai's monitor API using the same
  token the session itself uses, on the same one-minute cache. Here the stale
  fallback is capped at 10 minutes: past that the quota lines are dropped
  rather than shown as if current. The USD cost and the Anthropic-only
  `extra` line are hidden, and a session without a token shows no quota at
  all rather than another account's cached numbers — **fork**
- Credential resolution runs env token → `$CLAUDE_CONFIG_DIR/.credentials.json`
  → macOS Keychain → secret-tool, so an explicitly selected profile is never
  preempted by the default account's keychain entry — **fork**
- Caches live under `XDG_CACHE_HOME` (default `~/.cache/claude-statusline`) at
  `0700`, namespaced per profile **and** per account. Concurrent windows on
  different profiles or tokens therefore never read each other's quota —
  **fork**
- Auth headers reach curl through stdin (`-H @-`) instead of argv, so a token
  never appears in `ps` output — **fork**

## Install

Clone the repo and run the deploy script. It runs a syntax check, then copies
`bin/statusline.sh` to `$CLAUDE_CONFIG_DIR/statusline.sh` (default `~/.claude/statusline.sh`):

```bash
git clone https://github.com/orbitof/claude-statusline.git
cd claude-statusline
./scripts/deploy-local.sh
```

Then point Claude Code at the script in your settings file (`~/.claude/settings.json`,
or `$CLAUDE_CONFIG_DIR/settings.json` for a custom profile). The command below
resolves either location, so the same snippet works for multi-profile setups:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline.sh\"",
    "refreshInterval": 60
  }
}
```

`refreshInterval` (seconds) makes Claude Code re-run the script on a timer.
Without it the statusline only re-renders when the conversation changes and
once when the prompt cache expires, so the `⏳` countdown and the reset
timers would sit at whatever the last turn reported.

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

Several features were ported from other forks of the upstream (re-implemented
here; design credit belongs to them):

- **Pace projection** — design from [peterdrier](https://github.com/peterdrier/claude-statusline)'s
  fork (projection math, `→NNN%` format, 999 cap, pace color thresholds)
- **Payload badges / measured session timer** — from [noah4520](https://github.com/noah4520/claude-statusline)'s
  fork (`fast_mode`, `thinking.enabled`, `exceeds_200k_tokens`, `cost.total_duration_ms`)
- **Git change counts** — from [camkeith](https://github.com/camkeith/claude-statusline)'s
  fork (per-kind counts; the `±/+/-/?` symbol set is this fork's variation)
- **`CLAUDE_CONFIG_DIR` support** — from [mhmzdev](https://github.com/mhmzdev/claude-statusline)'s
  fork (see their upstream PR #34)
- **Token-via-stdin and private cache dir** — from [kay404](https://github.com/kay404/claude-statusline)'s
  fork (see their upstream PR #30)

## License

MIT

#!/bin/bash
set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ── Colors ──────────────────────────────────────────────
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;175;80m'
cyan='\033[38;2;86;182;194m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
magenta='\033[38;2;180;140;255m'
dim='\033[2m'
reset='\033[0m'

sep=" ${dim}│${reset} "

# ── Helpers ─────────────────────────────────────────────
color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then printf "$red"
    elif [ "$pct" -ge 70 ]; then printf "$yellow"
    elif [ "$pct" -ge 50 ]; then printf "$orange"
    else printf "$green"
    fi
}

build_bar() {
    local pct=$1
    local width=$2
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar_color
    bar_color=$(color_for_pct "$pct")

    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="●"; done
    for ((i=0; i<empty; i++)); do empty_str+="○"; done

    printf "${bar_color}${filled_str}${dim}${empty_str}${reset}"
}

format_epoch_time() {
    local epoch=$1
    local style=$2
    [ -z "$epoch" ] || [ "$epoch" = "null" ] || [ "$epoch" = "0" ] && return

    local result=""
    case "$style" in
        time)
            result=$(date -j -r "$epoch" +"%l:%M%p" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%l:%M%P" 2>/dev/null)
            result=$(echo "$result" | sed 's/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            ;;
        datetime)
            result=$(date -j -r "$epoch" +"%b %-d, %l:%M%p" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d, %l:%M%P" 2>/dev/null)
            result=$(echo "$result" | sed 's/  / /g; s/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            ;;
        *)
            result=$(date -j -r "$epoch" +"%b %-d" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d" 2>/dev/null)
            result=$(echo "$result" | tr '[:upper:]' '[:lower:]')
            ;;
    esac
    printf "%s" "$result"
}

iso_to_epoch() {
    local iso_str="$1"

    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    local stripped="${iso_str%%.*}"
    stripped="${stripped%%Z}"
    stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"

    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        [ -z "$epoch" ] && epoch=$(env TZ=UTC date -d "${stripped/T/ }" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        [ -z "$epoch" ] && epoch=$(date -d "${stripped/T/ }" +%s 2>/dev/null)
    fi

    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    return 1
}

format_credits() {
    # Humanize a credit count: 416 -> "416", 12000 -> "12k", 29561 -> "29.6k"
    local v=$1
    if [ "$v" -ge 1000000 ]; then
        awk "BEGIN {printf \"%.1fm\", $v/1000000}" | sed 's/\.0m$/m/'
    elif [ "$v" -ge 1000 ]; then
        awk "BEGIN {printf \"%.1fk\", $v/1000}" | sed 's/\.0k$/k/'
    else
        printf "%s" "$v"
    fi
}

# ── Backend detection ───────────────────────────────────
# A session pointed at Z.ai's Anthropic-compatible endpoint (GLM Coding Plan)
# inherits ANTHROPIC_BASE_URL from the claude process, and that URL is the only
# portable signal for the backend. Match on the host (z.ai or a subdomain), not
# a substring of the whole URL: in GLM mode the env token is sent to api.z.ai,
# so a URL that merely contains "z.ai" elsewhere must never enable it. An
# unparseable URL matches nothing. In GLM mode the rate-limit lines come from
# Z.ai's monitor API and the Anthropic OAuth fallback is skipped entirely —
# otherwise it would display the wrong vendor's quotas.
base_host=$(printf '%s' "${ANTHROPIC_BASE_URL:-}" \
    | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#^[^/@]+@##; s#[/?].*##; s#:[0-9]+$##' \
    | tr '[:upper:]' '[:lower:]')
glm_mode=false
case "$base_host" in
    z.ai|*.z.ai) glm_mode=true ;;
esac

# ── Extract JSON data ───────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')

size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$size" -eq 0 ] 2>/dev/null && size=200000

input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
current=$(( input_tokens + cache_create + cache_read ))

if [ "$size" -gt 0 ]; then
    pct_used=$(( current * 100 / size ))
else
    pct_used=0
fi

# Prefer the live session effort from stdin (.effort.level) so per-session /effort
# and --effort changes (including session-only `max`, which is never persisted to
# settings.json) are reflected. Fall back to the persisted user default when the
# current model doesn't report an effort level.
effort=$(echo "$input" | jq -r '.effort.level // empty')
if [ -z "$effort" ]; then
    settings_path="$HOME/.claude/settings.json"
    if [ -f "$settings_path" ]; then
        effort=$(jq -r '.effortLevel // "default"' "$settings_path" 2>/dev/null)
    fi
fi
[ -z "$effort" ] && effort="default"

# ── LINE 1: Model │ Context % │ Directory (branch) │ Session │ Cost │ Effort ──
pct_color=$(color_for_pct "$pct_used")
cwd=$(echo "$input" | jq -r '.cwd // ""')
[ -z "$cwd" ] || [ "$cwd" = "null" ] && cwd=$(pwd)
dirname=$(basename "$cwd")

git_branch=""
git_dirty=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
        git_dirty="*"
    fi
fi

session_duration=""
session_start=$(echo "$input" | jq -r '.session.start_time // empty')
if [ -n "$session_start" ] && [ "$session_start" != "null" ]; then
    start_epoch=$(iso_to_epoch "$session_start")
    if [ -n "$start_epoch" ]; then
        now_epoch=$(date +%s)
        elapsed=$(( now_epoch - start_epoch ))
        if [ "$elapsed" -ge 3600 ]; then
            session_duration="$(( elapsed / 3600 ))h$(( (elapsed % 3600) / 60 ))m"
        elif [ "$elapsed" -ge 60 ]; then
            session_duration="$(( elapsed / 60 ))m"
        else
            session_duration="${elapsed}s"
        fi
    fi
fi

# Session cost (USD) from stdin — accumulates over the current session.
# Not shown in GLM mode: there the figure is a client-side estimate computed
# against Anthropic pricing, which says nothing about a subscription plan's
# actual quota consumption.
session_cost=""
if ! $glm_mode; then
    session_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
fi
cost_fmt=""
if [ -n "$session_cost" ] && [ "$session_cost" != "null" ]; then
    cost_fmt=$(awk "BEGIN {printf \"%.2f\", $session_cost}")
fi

skip_perms=""
parent_cmd=$(ps -o args= -p "$PPID" 2>/dev/null)
if [[ "$parent_cmd" == *"--dangerously-skip-permissions"* ]]; then
    skip_perms="⚡  "
fi

line1="${blue}${model_name}${reset}"
line1+="${sep}"
line1+="✍️ ${pct_color}${pct_used}%${reset}"
line1+="${sep}"
line1+="${skip_perms}${cyan}${dirname}${reset}"
if [ -n "$git_branch" ]; then
    line1+=" ${green}(${git_branch}${red}${git_dirty}${green})${reset}"
fi
if [ -n "$session_duration" ]; then
    line1+="${sep}"
    line1+="${dim}⏱ ${reset}${white}${session_duration}${reset}"
fi
if [ -n "$cost_fmt" ]; then
    line1+="${sep}"
    line1+="${green}\$${cost_fmt}${reset}"
fi
line1+="${sep}"
case "$effort" in
    max)    line1+="${magenta}◉ ${effort}${reset}" ;;
    xhigh)  line1+="${magenta}● ${effort}${reset}" ;;
    high)   line1+="${magenta}● ${effort}${reset}" ;;
    medium) line1+="${dim}◑ ${effort}${reset}" ;;
    low)    line1+="${dim}◔ ${effort}${reset}" ;;
    *)      line1+="${dim}◑ ${effort}${reset}" ;;
esac

# ── Rate limits from stdin (primary) ───────────────────
has_stdin_rates=false
five_hour_pct=""
five_hour_reset_epoch=""
seven_day_pct=""
seven_day_reset_epoch=""
five_hour_credits=""
seven_day_credits=""

if ! $glm_mode; then
    stdin_five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
    if [ -n "$stdin_five_pct" ]; then
        has_stdin_rates=true
        five_hour_pct=$(printf "%.0f" "$stdin_five_pct")
        five_hour_reset_epoch=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
        seven_day_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' | awk '{printf "%.0f", $1}')
        seven_day_reset_epoch=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
    fi
fi

# ── Fallback: API call (cached) ────────────────────────
cache_file="/tmp/claude/statusline-usage-cache.json"
cache_max_age=60
mkdir -p /tmp/claude

usage_data=""
extra_enabled="false"

if $glm_mode; then
    # ── GLM (Z.ai Coding Plan): monitor API (cached) ──
    # Same env token the session itself uses. Windows are identified by their
    # unit/number pair (unit=3/number=5 → 5-hour, unit=6/number=1 → weekly;
    # observed on CREDIT_LIMIT responses), not by reset-time ordering — near
    # the weekly reset the two orderings swap. An unrecognized response shape
    # omits the quota lines rather than guessing a mapping.
    zai_cache="/tmp/claude/statusline-zai-cache.json"
    zai_cache_max_age=60
    zai_cache_max_stale=600
    zai_data=""

    if [ -f "$zai_cache" ]; then
        zai_mtime=$(stat -c %Y "$zai_cache" 2>/dev/null || stat -f %m "$zai_cache" 2>/dev/null)
        zai_age=$(( $(date +%s) - zai_mtime ))
        if [ "$zai_age" -lt "$zai_cache_max_age" ]; then
            zai_data=$(cat "$zai_cache" 2>/dev/null)
        fi
    fi

    if [ -z "$zai_data" ]; then
        zai_token="${ANTHROPIC_AUTH_TOKEN:-${ANTHROPIC_API_KEY:-}}"
        if [ -n "$zai_token" ] && [ "$zai_token" != "null" ]; then
            response=$(curl -s --max-time 5 \
                -H "Authorization: Bearer $zai_token" \
                "https://api.z.ai/api/monitor/usage/quota/limit" 2>/dev/null)
            # Cache only a structurally valid response — one containing at
            # least one renderable entry (a KNOWN window with renderable
            # fields) — so an endpoint shape change can never overwrite the
            # last good cache. Rendering feeds usage/currentValue/nextResetTime
            # into bash integer arithmetic, so those must be integers; and
            # percentage must be a number or absent/null (`// ` would also
            # rewrite false, so test it explicitly).
            if [ -n "$response" ] && echo "$response" | jq -e '
                def oknum: type == "number" and floor == .;
                def rbl($u; $n): .unit == $u and .number == $n
                    and (.usage | oknum) and (.currentValue | oknum) and (.nextResetTime | oknum)
                    and (.percentage | (. == null or type == "number"));
                (.data.limits | type) == "array"
                and ([.data.limits[] | select(rbl(3; 5) or rbl(6; 1))] | length) > 0
            ' >/dev/null 2>&1; then
                zai_data="$response"
                # Atomic replace, so concurrent statusline instances never
                # read a partially written cache.
                zai_tmp="$(mktemp "${zai_cache}.XXXXXX")" \
                    && printf '%s' "$response" > "$zai_tmp" \
                    && mv -f "$zai_tmp" "$zai_cache" \
                    || rm -f "$zai_tmp"
            fi
        fi
        # Refresh failed: fall back to the stale cache for a bounded window
        # only; past it the quota lines are omitted rather than displayed as
        # if current.
        if [ -z "$zai_data" ] && [ -f "$zai_cache" ]; then
            zai_mtime=$(stat -c %Y "$zai_cache" 2>/dev/null || stat -f %m "$zai_cache" 2>/dev/null)
            zai_age=$(( $(date +%s) - zai_mtime ))
            [ "$zai_age" -lt "$zai_cache_max_stale" ] && zai_data=$(cat "$zai_cache" 2>/dev/null)
        fi
    fi

    if [ -n "$zai_data" ] && echo "$zai_data" | jq -e '(.data.limits | type) == "array"' >/dev/null 2>&1; then
        # rbl($u; $n) is the renderable-entry predicate — identical to the
        # cache-write gate, so what gets cached is exactly what can render.
        # 5-hour window: unit=3 / number=5
        zai_entry=$(echo "$zai_data" | jq -c '
            def oknum: type == "number" and floor == .;
            def rbl($u; $n): .unit == $u and .number == $n
                and (.usage | oknum) and (.currentValue | oknum) and (.nextResetTime | oknum)
                and (.percentage | (. == null or type == "number"));
            .data.limits | map(select(rbl(3; 5))) | .[0] // empty' 2>/dev/null)
        if [ -n "$zai_entry" ]; then
            five_hour_pct=$(echo "$zai_entry" | jq -r '.percentage // (if .usage > 0 then (.currentValue / .usage * 100) else 0 end)' | awk '{printf "%.0f", $1}')
            five_hour_reset_epoch=$(( $(echo "$zai_entry" | jq -r '.nextResetTime') / 1000 ))
            five_hour_credits="$(format_credits "$(echo "$zai_entry" | jq -r '.currentValue')")/$(format_credits "$(echo "$zai_entry" | jq -r '.usage')")"
        fi

        # Weekly window: unit=6 / number=1
        zai_entry=$(echo "$zai_data" | jq -c '
            def oknum: type == "number" and floor == .;
            def rbl($u; $n): .unit == $u and .number == $n
                and (.usage | oknum) and (.currentValue | oknum) and (.nextResetTime | oknum)
                and (.percentage | (. == null or type == "number"));
            .data.limits | map(select(rbl(6; 1))) | .[0] // empty' 2>/dev/null)
        if [ -n "$zai_entry" ]; then
            seven_day_pct=$(echo "$zai_entry" | jq -r '.percentage // (if .usage > 0 then (.currentValue / .usage * 100) else 0 end)' | awk '{printf "%.0f", $1}')
            seven_day_reset_epoch=$(( $(echo "$zai_entry" | jq -r '.nextResetTime') / 1000 ))
            seven_day_credits="$(format_credits "$(echo "$zai_entry" | jq -r '.currentValue')")/$(format_credits "$(echo "$zai_entry" | jq -r '.usage')")"
        fi
    fi
elif ! $has_stdin_rates; then
    needs_refresh=true

    if [ -f "$cache_file" ]; then
        cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
        now=$(date +%s)
        cache_age=$(( now - cache_mtime ))
        if [ "$cache_age" -lt "$cache_max_age" ]; then
            needs_refresh=false
            usage_data=$(cat "$cache_file" 2>/dev/null)
        fi
    fi

    if $needs_refresh; then
        token=""
        if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
            token="$CLAUDE_CODE_OAUTH_TOKEN"
        elif command -v security >/dev/null 2>&1; then
            blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
            if [ -n "$blob" ]; then
                token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            fi
        fi
        if [ -z "$token" ] || [ "$token" = "null" ]; then
            creds_file="${HOME}/.claude/.credentials.json"
            if [ -f "$creds_file" ]; then
                token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
            fi
        fi
        if [ -z "$token" ] || [ "$token" = "null" ]; then
            if command -v secret-tool >/dev/null 2>&1; then
                blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
                if [ -n "$blob" ]; then
                    token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
                fi
            fi
        fi

        if [ -n "$token" ] && [ "$token" != "null" ]; then
            response=$(curl -s --max-time 5 \
                -H "Accept: application/json" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $token" \
                -H "anthropic-beta: oauth-2025-04-20" \
                -H "User-Agent: claude-code/2.1.34" \
                "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
            if [ -n "$response" ] && echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
                usage_data="$response"
                echo "$response" > "$cache_file"
            fi
        fi
        if [ -z "$usage_data" ] && [ -f "$cache_file" ]; then
            usage_data=$(cat "$cache_file" 2>/dev/null)
        fi
    fi

    if [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; then
        five_hour_pct=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0' | awk '{printf "%.0f", $1}')
        five_hour_reset_iso=$(echo "$usage_data" | jq -r '.five_hour.resets_at // empty')
        five_hour_reset_epoch=$(iso_to_epoch "$five_hour_reset_iso")
        seven_day_pct=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0' | awk '{printf "%.0f", $1}')
        seven_day_reset_iso=$(echo "$usage_data" | jq -r '.seven_day.resets_at // empty')
        seven_day_reset_epoch=$(iso_to_epoch "$seven_day_reset_iso")

        extra_enabled=$(echo "$usage_data" | jq -r '.extra_usage.is_enabled // false')
    fi
else
    if [ -f "$cache_file" ]; then
        usage_data=$(cat "$cache_file" 2>/dev/null)
        if [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; then
            extra_enabled=$(echo "$usage_data" | jq -r '.extra_usage.is_enabled // false')
        fi
    fi
fi

# ── Rate limit lines ────────────────────────────────────
rate_lines=""
bar_width=10

if [ -n "$five_hour_pct" ]; then
    five_hour_reset=$(format_epoch_time "$five_hour_reset_epoch" "time")
    five_hour_bar=$(build_bar "$five_hour_pct" "$bar_width")
    five_hour_pct_color=$(color_for_pct "$five_hour_pct")
    five_hour_pct_fmt=$(printf "%3d" "$five_hour_pct")

    rate_lines+="${white}current${reset} ${five_hour_bar} ${five_hour_pct_color}${five_hour_pct_fmt}%${reset}"
    [ -n "$five_hour_credits" ] && rate_lines+=" ${dim}${five_hour_credits}${reset}"
    [ -n "$five_hour_reset" ] && rate_lines+=" ${dim}⟳${reset} ${white}${five_hour_reset}${reset}"
fi

if [ -n "$seven_day_pct" ]; then
    seven_day_reset=$(format_epoch_time "$seven_day_reset_epoch" "datetime")
    seven_day_bar=$(build_bar "$seven_day_pct" "$bar_width")
    seven_day_pct_color=$(color_for_pct "$seven_day_pct")
    seven_day_pct_fmt=$(printf "%3d" "$seven_day_pct")

    [ -n "$rate_lines" ] && rate_lines+="\n"
    rate_lines+="${white}weekly${reset}  ${seven_day_bar} ${seven_day_pct_color}${seven_day_pct_fmt}%${reset}"
    [ -n "$seven_day_credits" ] && rate_lines+=" ${dim}${seven_day_credits}${reset}"
    [ -n "$seven_day_reset" ] && rate_lines+=" ${dim}⟳${reset} ${white}${seven_day_reset}${reset}"
fi

if [ "$extra_enabled" = "true" ] && [ -n "$usage_data" ]; then
    extra_pct=$(echo "$usage_data" | jq -r '.extra_usage.utilization // 0' | awk '{printf "%.0f", $1}')
    extra_used=$(echo "$usage_data" | jq -r '.extra_usage.used_credits // 0' | awk '{printf "%.2f", $1/100}')
    extra_limit=$(echo "$usage_data" | jq -r '.extra_usage.monthly_limit // 0' | awk '{printf "%.2f", $1/100}')
    extra_bar=$(build_bar "$extra_pct" "$bar_width")
    extra_pct_color=$(color_for_pct "$extra_pct")

    extra_reset=$(date -v+1m -v1d +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if [ -z "$extra_reset" ]; then
        extra_reset=$(date -d "$(date +%Y-%m-01) +1 month" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    fi

    [ -n "$rate_lines" ] && rate_lines+="\n"
    rate_lines+="${white}extra${reset}   ${extra_bar} ${extra_pct_color}\$${extra_used}${dim}/${reset}${white}\$${extra_limit}${reset} ${dim}⟳${reset} ${white}${extra_reset}${reset}"
fi

# ── Output ──────────────────────────────────────────────
printf "%b" "$line1"
[ -n "$rate_lines" ] && printf "\n\n%b" "$rate_lines"

exit 0

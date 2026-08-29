#!/usr/bin/env bash
# Check configured HTTP feeds for availability and stale Last-Modified headers.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FEEDS_FILE="${1:-$ROOT/configs/feeds.yaml}"
MAX_AGE_HOURS="${MAX_FEED_AGE_HOURS:-168}"
FAIL_ON_STALE="${FAIL_ON_STALE_FEEDS:-false}"

if ! command -v curl >/dev/null; then
  echo "curl is required" >&2
  exit 2
fi

urls="$(
  awk '
    /^[[:space:]]*-[[:space:]]*https?:\/\// {
      url=$2
      gsub(/"/, "", url)
      print url
    }
  ' "$FEEDS_FILE" | sort -u
)"

if [[ -z "$urls" ]]; then
  echo "No HTTP feeds found in $FEEDS_FILE" >&2
  exit 2
fi

failures=0
stale=0
now="$(date +%s)"

printf 'Blackroute feed monitor\n'
printf 'Config: %s\n' "$FEEDS_FILE"
printf 'Max age: %s hours\n\n' "$MAX_AGE_HOURS"
printf 'Fail on stale: %s\n\n' "$FAIL_ON_STALE"

while IFS= read -r url; do
  [[ -z "$url" ]] && continue

  headers="$(mktemp)"
  code="$(
    curl -fsSIL \
      --connect-timeout 10 \
      --max-time 30 \
      --retry 4 \
      --retry-delay 5 \
      -A "blackroute-feed-monitor/1.0" \
      -o "$headers" \
      -w '%{http_code}' \
      "$url" 2>/dev/null || true
  )"

  if [[ "$code" -lt 200 || "$code" -ge 400 ]]; then
    code="$(
      curl -fsSL \
        --connect-timeout 10 \
        --max-time 30 \
        --retry 4 \
        --retry-delay 5 \
        -A "blackroute-feed-monitor/1.0" \
        -o /dev/null \
        -w '%{http_code}' \
        "$url" 2>/dev/null || true
    )"
  fi

  if [[ "$code" -lt 200 || "$code" -ge 400 ]]; then
    printf 'FAIL  %-3s %s\n' "${code:-000}" "$url"
    failures=$((failures + 1))
    rm -f "$headers"
    continue
  fi

  last_modified="$(awk 'BEGIN{IGNORECASE=1} /^last-modified:/ {sub(/^[^:]+:[[:space:]]*/, ""); value=$0} END{print value}' "$headers" | tr -d '\r')"
  if [[ -n "$last_modified" ]]; then
    if modified_ts="$(date -d "$last_modified" +%s 2>/dev/null)"; then
      age_hours=$(( (now - modified_ts) / 3600 ))
      if [[ "$age_hours" -gt "$MAX_AGE_HOURS" ]]; then
        printf 'WARN  %-3s stale_%sh %s\n' "$code" "$age_hours" "$url"
        stale=$((stale + 1))
      else
        printf 'OK    %-3s %sh %s\n' "$code" "$age_hours" "$url"
      fi
    else
      printf 'OK    %-3s age_unknown %s\n' "$code" "$url"
    fi
  else
    printf 'OK    %-3s no_last_modified %s\n' "$code" "$url"
  fi
  rm -f "$headers"
done <<< "$urls"

unavailable="$failures"
if [[ "$FAIL_ON_STALE" == "true" && "$stale" -gt 0 ]]; then
  failures=$((unavailable + stale))
fi

printf '\nSummary: %d unavailable, %d stale\n' "$unavailable" "$stale"
exit "$failures"

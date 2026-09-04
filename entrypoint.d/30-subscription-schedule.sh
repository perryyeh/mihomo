#!/bin/sh
# Optional subscription scheduler. It is a no-op without subscription.conf.
set -u

APP_DIR=/root/.config/mihomo
CONF="$APP_DIR/subscription.conf"
UPDATER="$APP_DIR/subscription.sh"
STATE="$APP_DIR/.subscription.next-run"

interval_seconds() {
  hours="$(sed -n 's/^INTERVAL_HOURS=//p' "$CONF" | sed -n '1p')"
  case "$hours" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$hours" -ge 1 ] || return 1
  printf '%s\n' "$((hours * 3600))"
}

configured() {
  [ -r "$CONF" ] && [ -x "$UPDATER" ]
}

case "${1:-}" in
  pre-start)
    configured || exit 0
    MIHOMO_SUPERVISOR_BOOT=1 "$UPDATER" --internal || \
      printf '%s\n' '⚠️ Mihomo 初始订阅更新失败；保留当前 config.yaml。' >&2
    exit 0
    ;;
  tick)
    configured || { rm -f "$STATE"; exit 0; }
    interval="$(interval_seconds)" || { rm -f "$STATE"; exit 0; }
    now="$(date +%s)"
    next="$(cat "$STATE" 2>/dev/null || true)"
    case "$next" in ''|*[!0-9]*) next=0 ;; esac
    [ "$now" -lt "$next" ] && exit 0
    "$UPDATER" --internal || printf '%s\n' '⚠️ Mihomo 订阅更新失败；保留当前 config.yaml。' >&2
    printf '%s\n' "$((now + interval))" >"$STATE"
    chmod 0600 "$STATE"
    exit 0
    ;;
  stop) exit 0 ;;
  *) exit 0 ;;
esac

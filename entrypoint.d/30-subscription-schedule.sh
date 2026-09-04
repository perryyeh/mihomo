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
    # The core must never wait for network I/O or apk installs.
    exit 0
    ;;
  post-start)
    configured || { rm -f "$STATE"; exit 0; }
    interval="$(interval_seconds)" || { rm -f "$STATE"; exit 0; }
    now="$(date +%s)"
    # Advance the deadline before the asynchronous initial update so tick
    # cannot start a duplicate while that update owns the subscription lock.
    printf '%s\n' "$((now + interval))" >"$STATE"
    chmod 0600 "$STATE"
    # Alpine's setsid detaches the updater from this hook. Wait until the
    # template's external-controller (:9090) is listening, so network I/O and
    # apk installs cannot delay PID 1 or Mihomo's initial configuration.
    setsid sh -c '
      updater="$1"
      port="$(printf "%04X" 9090)"
      i=0
      while [ "$i" -lt 30 ]; do
        if grep -qi ":$port" /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
          exec "$updater" --internal
        fi
        sleep 1
        i=$((i + 1))
      done
    ' sh "$UPDATER" >/dev/null 2>&1 &
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

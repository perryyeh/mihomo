#!/bin/sh
# Container PID 1 for YehBP Mihomo. It owns the core process and the optional
# full-configuration subscription schedule; no host timer is required.
set -u

APP_DIR=/root/.config/mihomo
UPDATE_SCRIPT="$APP_DIR/config.subscription.update.sh"
SUBSCRIPTION_CONF="$APP_DIR/config.subscription.conf"
RELOAD_REQUEST="$APP_DIR/.config.subscription.reload.request"
RELOAD_DONE="$APP_DIR/.config.subscription.reload.done"
CORE_PID=""

log() {
  printf '%s\n' "$*"
}

interval_seconds() {
  local hours
  [ -r "$SUBSCRIPTION_CONF" ] || return 1
  hours="$(sed -n 's/^INTERVAL_HOURS=//p' "$SUBSCRIPTION_CONF" | sed -n '1p')"
  case "$hours" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$hours" -ge 1 ] && [ "$hours" -le 23 ] || return 1
  printf '%s\n' "$((hours * 3600))"
}

has_subscription() {
  [ -r "$SUBSCRIPTION_CONF" ] && [ -x "$UPDATE_SCRIPT" ]
}

run_update() {
  has_subscription || return 0
  "$UPDATE_SCRIPT" --internal || log "⚠️ Mihomo 订阅更新失败；保留当前 config.yaml。"
}

stop_core() {
  [ -n "$CORE_PID" ] || return 0
  kill -TERM "$CORE_PID" 2>/dev/null || true
  wait "$CORE_PID" 2>/dev/null || true
  CORE_PID=""
}

start_core() {
  /mihomo -d "$APP_DIR" &
  CORE_PID=$!
}

restart_core() {
  stop_core
  start_core
  : >"$RELOAD_DONE"
}

shutdown() {
  stop_core
  exit 0
}
trap shutdown INT TERM

# A configured subscription is refreshed before the initial core process is
# started. No reload signal is needed in that case.
if has_subscription; then
  MIHOMO_SUPERVISOR_BOOT=1 run_update
fi
rm -f "$RELOAD_REQUEST"
start_core
: >"$RELOAD_DONE"
next_update=0

while :; do
  if ! kill -0 "$CORE_PID" 2>/dev/null; then
    wait "$CORE_PID" 2>/dev/null || true
    exit 1
  fi

  if [ -f "$RELOAD_REQUEST" ]; then
    rm -f "$RELOAD_REQUEST"
    restart_core
  fi

  now="$(date +%s)"
  if interval="$(interval_seconds)"; then
    if [ "$next_update" -eq 0 ]; then
      next_update=$((now + interval))
    elif [ "$now" -ge "$next_update" ]; then
      run_update
      next_update=$((now + interval))
    fi
  else
    next_update=0
  fi
  sleep 1
done

#!/bin/sh
# Generic PID 1 for YehBP Mihomo. Optional behavior lives in entrypoint.d/.
set -u

APP_DIR=/root/.config/mihomo
HOOK_DIR="$APP_DIR/entrypoint.d"
ARGS_FILE="$APP_DIR/mihomo.args"
RELOAD_REQUEST="$APP_DIR/.subscription.reload.request"
RELOAD_DONE="$APP_DIR/.subscription.reload.done"
CORE_PID=""

log() {
  printf '%s\n' "$*"
}

run_hooks() {
  phase="$1"
  status=0
  for hook in "$HOOK_DIR"/*.sh; do
    [ -x "$hook" ] || continue
    if ! "$hook" "$phase"; then
      log "⚠️ Mihomo hook 失败：$(basename "$hook")（阶段：$phase）"
      status=1
    fi
  done
  return "$status"
}

start_core() {
  set -- /mihomo -d "$APP_DIR"
  if [ -r "$ARGS_FILE" ]; then
    while IFS= read -r arg || [ -n "$arg" ]; do
      case "$arg" in
        ''|\#*) continue ;;
      esac
      set -- "$@" "$arg"
    done <"$ARGS_FILE"
  fi
  "$@" &
  CORE_PID=$!
}

stop_core() {
  [ -n "$CORE_PID" ] || return 0
  kill -TERM "$CORE_PID" 2>/dev/null || true
  wait "$CORE_PID" 2>/dev/null || true
  CORE_PID=""
}

restart_core() {
  stop_core
  start_core
  : >"$RELOAD_DONE"
}

shutdown() {
  run_hooks stop || true
  stop_core
  exit 0
}
trap shutdown INT TERM

# Routing and other pre-start hooks run before the first core process starts.
run_hooks pre-start || exit 1
rm -f "$RELOAD_REQUEST"
start_core
: >"$RELOAD_DONE"
run_hooks post-start || true

last_tick=0
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
  if [ $((now - last_tick)) -ge 60 ]; then
    run_hooks tick || true
    last_tick="$now"
  fi
  sleep 1
done

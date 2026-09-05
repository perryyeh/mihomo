#!/bin/sh
# YehBP Mihomo full-configuration subscription updater.
# Runs inside the Mihomo container; its supervisor owns schedule and core restart.
set -eu
umask 077

APP_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CONFIG="$APP_DIR/config.yaml"
BACKUP="$APP_DIR/config.macvlan.backup.yaml"
REPLACE="$APP_DIR/subscription.macvlan.yaml"
SUBSCRIPTION_CONF="$APP_DIR/subscription.conf"
LOG_FILE="$APP_DIR/subscription.log"
LOCK_DIR="$APP_DIR/.subscription.lock"
RELOAD_REQUEST="$APP_DIR/.subscription.reload.request"
RELOAD_DONE="$APP_DIR/.subscription.reload.done"
MODE="${1:---once}"
TLS_CONFIGURED=0
TLS_ASSETS_READY=0
TLS_STAGE_DIR=""
TLS_CHANGED=0

ensure_dependencies() {
  missing=""
  command -v curl >/dev/null 2>&1 || missing="$missing curl"
  command -v python3 >/dev/null 2>&1 || missing="$missing python3"
  python3 -c 'import yaml' >/dev/null 2>&1 || missing="$missing py3-yaml"
  [ -z "$missing" ] && return 0

  if ! command -v apk >/dev/null 2>&1; then
    printf '%s\n' "❌ 订阅更新缺少工具：$missing；当前容器不支持 apk 安装。" >&2
    return 1
  fi

  # Do not persistently replace Alpine repositories in the official image.
  # A macvlan source network can reset one CDN while other mirrors work, so
  # use an ephemeral repository file and try a small, known mirror set.
  apk_repositories="$(mktemp)" || {
    printf '%s\n' "❌ 订阅更新依赖安装失败：$missing" >&2
    return 1
  }
  printf '%s\n' "ℹ️ 订阅更新正在安装缺少的容器工具：$missing" >&2
  for apk_mirror in \
    https://dl-cdn.alpinelinux.org/alpine \
    https://mirrors.aliyun.com/alpine \
    https://mirrors.tencent.com/alpine \
    https://mirror.nju.edu.cn/alpine; do
    printf '%s/v3.24/main\n%s/v3.24/community\n' "$apk_mirror" "$apk_mirror" >"$apk_repositories"
    if apk --repositories-file "$apk_repositories" add --no-cache curl python3 py3-yaml >/dev/null 2>&1; then
      rm -f "$apk_repositories"
      return 0
    fi
  done
  rm -f "$apk_repositories"
  printf '%s\n' "❌ 订阅更新依赖安装失败：$missing" >&2
  return 1
}

ensure_dependencies || exit 1

log_event() {
  message="$1"
  body="$(mktemp "$APP_DIR/.subscription-log.XXXXXX")"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$message" >"$body"

  existing="$(mktemp "$APP_DIR/.subscription-log-existing.XXXXXX")"
  if [ -f "$LOG_FILE" ]; then
    python3 - "$LOG_FILE" "$existing" <<'PY'
from datetime import date, timedelta
from pathlib import Path
import re, sys
src, dst = map(Path, sys.argv[1:])
cutoff = date.today() - timedelta(days=6)
blocks = re.split(r'\n{2,}', src.read_text(encoding='utf-8', errors='replace').strip())
kept = []
for block in blocks:
    m = re.match(r'^\[(\d{4}-\d{2}-\d{2}) ', block)
    if not m:
        continue
    try:
        if date.fromisoformat(m.group(1)) >= cutoff:
            kept.append(block.strip())
    except ValueError:
        pass
Path(dst).write_text('\n\n'.join(kept) + ('\n' if kept else ''), encoding='utf-8')
PY
  else
    : >"$existing"
  fi

  tmp="$(mktemp "$APP_DIR/.subscription-log-new.XXXXXX")"
  cat "$body" >"$tmp"
  if [ -s "$existing" ]; then
    printf '\n' >>"$tmp"
    cat "$existing" >>"$tmp"
  fi
  python3 - "$tmp" "$LOG_FILE" <<'PY'
from pathlib import Path
import re, sys
src, dst = map(Path, sys.argv[1:])
text = src.read_text(encoding='utf-8', errors='replace').strip()
text = re.sub(r'\n{3,}', '\n\n', text)
Path(dst).write_text((text + '\n') if text else '', encoding='utf-8')
PY
  chmod 0600 "$LOG_FILE"
  rm -f "$body" "$existing" "$tmp"
}

cleanup() {
  status="${1:-$?}"
  rm -rf "${TLS_STAGE_DIR:-}" 2>/dev/null || true
  rm -rf "$LOCK_DIR" 2>/dev/null || true
  return "$status"
}
trap 'status=$?; cleanup "$status"' 0 1 2 15

request_reload() {
  [ "${MIHOMO_SUPERVISOR_BOOT:-0}" = 1 ] && return 0
  rm -f "$RELOAD_DONE"
  : >"$RELOAD_REQUEST"
  [ "${MIHOMO_WAIT_RELOAD:-0}" = 1 ] || return 0
  i=0
  while [ "$i" -lt 30 ]; do
    [ -f "$RELOAD_DONE" ] && return 0
    sleep 1
    i=$((i + 1))
  done
  log_event "警告：新 config.yaml 已通过校验并已替换，但容器内 Mihomo 未在 30 秒内确认重载。"
  return 1
}

CONFIG_CHANGED=0

# A subscription may point TLS listener paths at arbitrary local locations.
# For portable subscriptions, ignore those directories: retain each basename,
# download it from the subscription URL directory, and keep it beside config.
prepare_tls_assets() {
  candidate="$1"
  assets="$(python3 - "$candidate" "$URL" <<'PY'
from pathlib import Path, PurePosixPath
from urllib.parse import quote, urljoin
import sys, yaml
path = Path(sys.argv[1])
base = sys.argv[2]
value = yaml.safe_load(path.read_text(encoding='utf-8'))
if not isinstance(value, dict):
    raise SystemExit('订阅根节点必须是 YAML mapping。')
assets = []
seen = set()
for listener in value.get('listeners') or []:
    if not isinstance(listener, dict):
        continue
    for field in ('certificate', 'private-key'):
        if field not in listener:
            continue
        original = listener[field]
        if not isinstance(original, str):
            raise SystemExit(f'listeners.{field} 必须是字符串路径。')
        name = PurePosixPath(original).name
        if name in ('', '.', '..'):
            raise SystemExit(f'listeners.{field} 缺少有效文件名。')
        listener[field] = f'./{name}'
        if name not in seen:
            seen.add(name)
            assets.append((name, urljoin(base, quote(name, safe=''))))
if assets:
    path.write_text(yaml.safe_dump(value, allow_unicode=True, sort_keys=False, default_flow_style=False), encoding='utf-8')
for name, url in assets:
    print(f'{name}\t{url}')
PY
)" || {
    log_event "失败：订阅 TLS 字段解析失败，运行中的 config.yaml 未修改。"
    return 1
  }
  [ -n "$assets" ] || return 0
  TLS_CONFIGURED=1
  TLS_STAGE_DIR="$(mktemp -d "$APP_DIR/.subscription-tls.XXXXXX")" || return 1

  while IFS="$(printf '\t')" read -r name asset_url; do
    [ -n "$name" ] || continue
    if ! curl --connect-timeout 15 --max-time 120 --fail --location --silent --show-error "$asset_url" -o "$TLS_STAGE_DIR/$name" || \
       [ ! -s "$TLS_STAGE_DIR/$name" ]; then
      rm -rf "$TLS_STAGE_DIR"
      TLS_STAGE_DIR=""
      log_event "警告：订阅声明了 TLS 文件，但下载失败；已跳过 TLS 文件下载。"
      return 0
    fi
  done <<EOF
$assets
EOF

  # Validate every certificate/key pair after their paths were normalized.
  if ! python3 - "$candidate" "$TLS_STAGE_DIR" <<'PY'
from pathlib import Path
import ssl, sys, yaml
config, directory = map(Path, sys.argv[1:])
value = yaml.safe_load(config.read_text(encoding='utf-8'))
for listener in value.get('listeners') or []:
    if not isinstance(listener, dict):
        continue
    cert, key = listener.get('certificate'), listener.get('private-key')
    if cert is not None and key is not None:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(directory / Path(cert).name, directory / Path(key).name)
PY
  then
    rm -rf "$TLS_STAGE_DIR"
    TLS_STAGE_DIR=""
    log_event "警告：下载的 TLS 文件无效或证书私钥不匹配；已跳过 TLS 文件下载。"
    return 0
  fi
  TLS_ASSETS_READY=1
}

validate_and_publish() {
  candidate="$1"
  if ! /mihomo -t -f "$candidate" >/dev/null 2>&1; then
    log_event "失败：Mihomo 校验未通过，运行中的 config.yaml 未修改。"
    return 1
  fi

  if [ "$TLS_ASSETS_READY" = 1 ]; then
    for staged in "$TLS_STAGE_DIR"/*; do
      [ -f "$staged" ] || continue
      cmp -s "$staged" "$APP_DIR/$(basename "$staged")" || TLS_CHANGED=1
    done
  fi
  if cmp -s "$candidate" "$CONFIG" && [ "$TLS_CHANGED" -eq 0 ]; then
    log_event "完成：订阅有效，但生成配置和 TLS 文件均未变化，无需重载 Mihomo。"
    return 0
  fi

  if [ "$TLS_CHANGED" -eq 1 ]; then
    for staged in "$TLS_STAGE_DIR"/*; do
      [ -f "$staged" ] || continue
      target="$APP_DIR/$(basename "$staged")"
      if ! cmp -s "$staged" "$target"; then
        mv "$staged" "$target"
        chmod 0600 "$target"
      fi
    done
  fi
  if ! cmp -s "$candidate" "$CONFIG"; then
    mv "$candidate" "$CONFIG"
    chmod 0600 "$CONFIG"
    CONFIG_CHANGED=1
  fi

  if [ "$TLS_CHANGED" -eq 1 ]; then
    log_event "完成：订阅有效，已更新同目录 TLS 文件并请求重启 Mihomo 核心。"
  else
    log_event "完成：订阅有效，已替换 config.yaml 并请求重载 Mihomo。"
  fi
  request_reload
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log_event "跳过：已有订阅更新任务正在执行。"
  exit 0
fi

case "$MODE" in
  --restore)
    if [ ! -r "$BACKUP" ]; then
      log_event "失败：未找到 config.macvlan.backup.yaml，拒绝恢复。"
      exit 1
    fi
    candidate="$(mktemp "$APP_DIR/.subscription-restore.XXXXXX")"
    cp "$BACKUP" "$candidate"
    if validate_and_publish "$candidate"; then
      if [ "$CONFIG_CHANGED" -eq 1 ]; then
        log_event "完成：已恢复本地 macvlan 配置并请求重载 Mihomo。"
      fi
      exit 0
    fi
    rm -f "$candidate"
    exit 1
    ;;
  --once|--scheduled|--internal|"")
    ;;
  *)
    log_event "失败：未知更新参数：$MODE"
    exit 2
    ;;
esac

if [ ! -r "$SUBSCRIPTION_CONF" ]; then
  log_event "失败：未找到 subscription.conf。"
  exit 1
fi
URL="$(sed -n 's/^URL=//p' "$SUBSCRIPTION_CONF" | sed -n '1p')"
APPLY_TEMPLATE="$(sed -n 's/^APPLY_TEMPLATE=//p' "$SUBSCRIPTION_CONF" | sed -n '1p')"
TEMPLATE_MODE="$(sed -n 's/^TEMPLATE_MODE=//p' "$SUBSCRIPTION_CONF" | sed -n '1p')"
# Configurations from releases before the mode/template switch keep the former
# macvlan-overlay behavior.
APPLY_TEMPLATE="${APPLY_TEMPLATE:-1}"
TEMPLATE_MODE="${TEMPLATE_MODE:-macvlan}"
case "$URL" in
  http://*|https://*) ;;
  *) log_event "失败：subscription.conf 中的 URL 无效。"; exit 1 ;;
esac
case "$APPLY_TEMPLATE" in
  0|1) ;;
  *) log_event "失败：APPLY_TEMPLATE 必须为 0 或 1。"; exit 1 ;;
esac
case "$TEMPLATE_MODE" in
  macvlan|host) ;;
  *) log_event "失败：TEMPLATE_MODE 必须为 macvlan 或 host。"; exit 1 ;;
esac
if [ "$APPLY_TEMPLATE" = 1 ]; then
  if [ "$TEMPLATE_MODE" = host ]; then
    REPLACE="$APP_DIR/subscription.host.yaml"
  fi
  if [ ! -r "$REPLACE" ]; then
    log_event "失败：未找到 $REPLACE，拒绝覆盖当前配置。"
    exit 1
  fi
fi
if [ ! -r "$BACKUP" ]; then
  log_event "失败：未找到 config.macvlan.backup.yaml，拒绝覆盖当前配置。"
  exit 1
fi

raw="$(mktemp "$APP_DIR/.subscription-download.XXXXXX")"
candidate="$(mktemp "$APP_DIR/.subscription-candidate.XXXXXX")"
trap 'status=$?; rm -f "$raw" "$candidate"; cleanup "$status"' 0 1 2 15

if ! curl --connect-timeout 15 --max-time 120 --fail --location --silent --show-error "$URL" -o "$raw"; then
  log_event "失败：订阅下载失败，运行中的 config.yaml 未修改。"
  exit 1
fi
if [ ! -s "$raw" ]; then
  log_event "失败：订阅下载为空，运行中的 config.yaml 未修改。"
  exit 1
fi

if [ "$APPLY_TEMPLATE" = 0 ]; then
  # Raw mode deliberately preserves the subscription bytes; Mihomo itself is
  # still required to validate the candidate before it replaces config.yaml.
  if ! cp "$raw" "$candidate"; then
    log_event "失败：无法准备原样订阅配置，运行中的 config.yaml 未修改。"
    exit 1
  fi
else
  if ! python3 - "$raw" "$REPLACE" "$candidate" <<'PY'
from pathlib import Path
import copy
import sys
try:
    import yaml
except ImportError:
    raise SystemExit('缺少 PyYAML。')

source_path, replace_path, candidate_path = map(Path, sys.argv[1:])
try:
    source = yaml.safe_load(source_path.read_text(encoding='utf-8'))
    replace = yaml.safe_load(replace_path.read_text(encoding='utf-8'))
except Exception as e:
    raise SystemExit(f'YAML 解析失败：{e}')
if not isinstance(source, dict):
    raise SystemExit('订阅根节点必须是 YAML mapping。')
if not isinstance(replace, dict):
    raise SystemExit('订阅覆盖模板根节点必须是 YAML mapping。')

conditional_paths = {
    ('dns', 'fake-ip-range6'),
}

def merge(target, overlay, path=()):
    for key, value in overlay.items():
        child_path = path + (key,)
        # IPv6 fake-IP is optional: do not add it when upstream lacks the key.
        if child_path in conditional_paths and key not in target:
            continue
        if isinstance(value, dict):
            current = target.get(key)
            if not isinstance(current, dict):
                current = {}
                target[key] = current
            merge(current, value, child_path)
        else:
            target[key] = copy.deepcopy(value)

merge(source, replace)

candidate_path.write_text(
    yaml.safe_dump(source, allow_unicode=True, sort_keys=False, default_flow_style=False),
    encoding='utf-8',
)
PY
  then
    log_event "失败：订阅 YAML 修补失败，运行中的 config.yaml 未修改。"
    exit 1
  fi
fi

prepare_tls_assets "$candidate" || {
  rm -f "$candidate"
  exit 1
}

if validate_and_publish "$candidate"; then
  exit 0
fi
rm -f "$candidate"
exit 1

#!/bin/sh
# Configure source-policy routing for 2+ manually declared macvlan networks.
# .env uses ipv4/gateway for the first network and ipv42/gateway2, ipv43/gateway3…
set -u

APP_DIR=/root/.config/mihomo
ENV_FILE="$APP_DIR/.env"
[ "${1:-}" = pre-start ] || exit 0
[ -r "$ENV_FILE" ] || exit 0

records="$(awk -F= '
  function trim(value) { sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value); return value }
  /^[[:space:]]*ipv4[0-9]*=/ {
    key = $1; sub(/^[[:space:]]*/, "", key)
    suffix = substr(key, 5); if (suffix == "") suffix = 1
    ip[suffix] = trim(substr($0, index($0, "=") + 1))
  }
  /^[[:space:]]*gateway[0-9]*=/ {
    key = $1; sub(/^[[:space:]]*/, "", key)
    suffix = substr(key, 8); if (suffix == "") suffix = 1
    gateway[suffix] = trim(substr($0, index($0, "=") + 1))
  }
  END {
    count = 0
    for (i = 1; i <= 99; i++) if (i in ip) count++
    if (count < 2) exit
    for (i = 1; i <= 99; i++) if (i in ip) {
      if (!(i in gateway) || gateway[i] == "") {
        print "ERROR missing gateway for ipv4" i
        exit 2
      }
      print ip[i], gateway[i]
    }
  }
' "$ENV_FILE")" || exit $?
[ -n "$records" ] || exit 0

index=0
primary_source=""
primary_gateway=""
primary_dev=""
printf '%s\n' "$records" | while IFS=' ' read -r source gateway; do
  case "$source" in ERROR*) printf '%s\n' "$source" >&2; exit 1 ;; esac
  dev="$(ip -o -4 addr show to "$source" 2>/dev/null | awk 'NR == 1 {print $2}')"
  [ -n "$dev" ] || { printf '%s\n' "No interface has configured IPv4 address: $source" >&2; exit 1; }
  cidr="$(ip -4 route show dev "$dev" scope link 2>/dev/null | awk 'NR == 1 {print $1}')"
  [ -n "$cidr" ] || { printf '%s\n' "No connected IPv4 route found on $dev" >&2; exit 1; }
  table=$((101 + index))

  sysctl -w "net.ipv4.conf.$dev.rp_filter=2" >/dev/null 2>&1 || true
  ip rule add from "$source" table "$table" 2>/dev/null || true
  ip route replace "$cidr" dev "$dev" src "$source" table "$table"
  ip route replace default via "$gateway" dev "$dev" table "$table"

  ipv6_source="$(ip -6 -o addr show dev "$dev" scope global 2>/dev/null | awk '$4 !~ /^(fc|fd)/ {sub(/\/.*/, "", $4); print $4; exit}')"
  ipv6_gateway="$(ip -6 route show default dev "$dev" proto ra 2>/dev/null | awk '/^default via / {print $3; exit}')"
  if [ -n "$ipv6_source" ] && [ -n "$ipv6_gateway" ]; then
    ip -6 rule add from "$ipv6_source" table "$table" 2>/dev/null || true
    ip -6 rule add oif "$dev" table "$table" 2>/dev/null || true
    ip -6 route replace default via "$ipv6_gateway" dev "$dev" table "$table"
  fi

  if [ "$index" -eq 0 ]; then
    ip route replace default via "$gateway" dev "$dev"
    [ -n "$ipv6_gateway" ] && ip -6 route replace default via "$ipv6_gateway" dev "$dev"
  fi
  index=$((index + 1))
done || exit $?

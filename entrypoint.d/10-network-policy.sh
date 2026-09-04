#!/bin/sh
# Optional source-policy routing hook. It is a no-op without network-policy.conf.
# Each enabled line has: IPv4-source IPv4-gateway routing-table
set -u

APP_DIR=/root/.config/mihomo
POLICY_FILE="$APP_DIR/network-policy.conf"
[ "${1:-}" = pre-start ] || exit 0
[ -r "$POLICY_FILE" ] || exit 0

while IFS=' ' read -r source gateway table extra; do
  case "${source:-}" in
    ''|\#*) continue ;;
  esac
  [ -n "${gateway:-}" ] && [ -n "${table:-}" ] && [ -z "${extra:-}" ] || {
    printf '%s\n' "Invalid network-policy.conf line for source: $source" >&2
    exit 1
  }
  dev="$(ip -o -4 addr show to "$source" 2>/dev/null | awk 'NR == 1 {print $2}')"
  [ -n "$dev" ] || {
    printf '%s\n' "No interface has policy source address: $source" >&2
    exit 1
  }
  cidr="$(ip -4 route show dev "$dev" scope link 2>/dev/null | awk 'NR == 1 {print $1}')"
  [ -n "$cidr" ] || {
    printf '%s\n' "No connected IPv4 route found on $dev" >&2
    exit 1
  }

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
  elif [ -n "$ipv6_source$ipv6_gateway" ]; then
    printf '%s\n' "Skipping incomplete IPv6 policy on $dev (source/gateway unavailable)" >&2
  fi
done <"$POLICY_FILE"

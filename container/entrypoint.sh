#!/usr/bin/env sh
set -eu

if [ "${DEBUG:-0}" = "1" ]; then
  set -x
fi

echo "entrypoint: start" >&2

CONF_FILE="/etc/wireguard/wg0.conf"
TMP_CONF=""
CLEAN_EXIT=0
KILLSWITCH_CHAIN="WG_KILLSWITCH"

lockdown() {
  echo "Activating network lockdown" >&2

  iptables -P INPUT   DROP || true
  iptables -P OUTPUT  DROP || true
  iptables -P FORWARD DROP || true
  iptables -F              || true

  ip route add prohibit default 2>/dev/null \
  || ip route replace prohibit default 2>/dev/null \
  || ip route add blackhole default 2>/dev/null \
  || ip route replace blackhole default 2>/dev/null \
  || ip route add unreachable default 2>/dev/null \
  || ip route replace unreachable default 2>/dev/null \
  || true

  ip -6 route add prohibit default 2>/dev/null \
  || ip -6 route replace prohibit default 2>/dev/null \
  || true
}

apply_killswitch() {
  endpoint_ip="$1"
  fwmark="$2"

  iptables -N "$KILLSWITCH_CHAIN" 2>/dev/null || true
  iptables -F "$KILLSWITCH_CHAIN" || true
  iptables -C OUTPUT -j "$KILLSWITCH_CHAIN" 2>/dev/null || iptables -I OUTPUT 1 -j "$KILLSWITCH_CHAIN"

  iptables -A "$KILLSWITCH_CHAIN" -o lo -j ACCEPT
  iptables -A "$KILLSWITCH_CHAIN" -o wg0 -j ACCEPT
  iptables -A "$KILLSWITCH_CHAIN" -m mark --mark "$fwmark" -j ACCEPT
  iptables -A "$KILLSWITCH_CHAIN" -m addrtype --dst-type LOCAL -j ACCEPT
  iptables -A "$KILLSWITCH_CHAIN" -j REJECT
}

cleanup() {
  rc=$?

  if [ -n "$TMP_CONF" ] && [ -f "$TMP_CONF" ]; then
    rm -f "$TMP_CONF" || true
  fi

  if [ "$rc" -ne 0 ] && [ "${CLEAN_EXIT:-0}" -ne 1 ]; then
    echo "Script failed with exit code $rc, locking down network" >&2
    lockdown
  fi

  exit "$rc"
}

shutdown_wg() {
  CLEAN_EXIT=1
  lockdown
  ip link del wg0 || true
  exit 0
}

trap cleanup EXIT
trap shutdown_wg TERM INT QUIT

if [ ! -f "$CONF_FILE" ]; then
  echo "Missing WireGuard config: $CONF_FILE" >&2
  exit 1
fi

TMP_CONF="$(mktemp)"
awk '
  /^[ \t]*($|[#;])/ { print; next }
  /^[ \t]*\[/ { print; next }
  /^[ \t]*(PrivateKey|ListenPort|FwMark)[ \t]*=/ { print; next }
  /^[ \t]*(PublicKey|PresharedKey|AllowedIPs|Endpoint|PersistentKeepalive)[ \t]*=/ { print; next }
  { next }
' "$CONF_FILE" > "$TMP_CONF"

addresses="$(awk -F'[ =,]+' '/^[ 	]*Address[ 	]*=/ {for(i=2;i<=NF;i++) print $i}' "$CONF_FILE" || true)"
dns_entries="$(awk -F'[ =,]+' '/^[ 	]*DNS[ 	]*=/ {for(i=2;i<=NF;i++) print $i}' "$CONF_FILE" || true)"
mtu="$(awk -F'[ =]+' '/^[ 	]*MTU[ 	]*=/ {print $2}' "$CONF_FILE" | head -n1 || true)"

endpoint_raw="$(awk -F'[ =]+' '/^[ 	]*Endpoint[ 	]*=/ {print $2; exit}' "$CONF_FILE")"
if [ -z "$endpoint_raw" ] || [ "$endpoint_raw" = "(none)" ]; then
  echo "Exiting... No valid endpoint found in wg0.conf" >&2
  exit 1
fi

if printf '%s' "$endpoint_raw" | grep -q '^\['; then
  echo "Exiting... Endpoint host must be a literal IPv4 address" >&2
  exit 1
else
  endpoint_host="${endpoint_raw%:*}"
  endpoint_port="${endpoint_raw##*:}"
fi

case "$endpoint_port" in
  ''|*[!0-9]*)
    echo "Exiting... Invalid endpoint port in wg0.conf" >&2
    exit 1
    ;;
esac

if [ "$endpoint_port" -lt 1 ] || [ "$endpoint_port" -gt 65535 ]; then
  echo "Exiting... Invalid endpoint port in wg0.conf" >&2
  exit 1
fi

if ! awk -v ip="$endpoint_host" 'BEGIN {
  n = split(ip, o, ".")
  if (n != 4) exit 1
  for (i = 1; i <= 4; i++) {
    if (o[i] !~ /^[0-9]+$/) exit 1
    if (o[i] < 0 || o[i] > 255) exit 1
  }
  exit 0
}'; then
  echo "Exiting... Endpoint host must be a literal IPv4 address" >&2
  exit 1
fi
endpoint="$endpoint_host"

if ip link show dev wg0 >/dev/null 2>&1; then
  ip link del wg0 || true
fi
ip link add dev wg0 type wireguard
wg setconf wg0 "$TMP_CONF"

if [ -n "$addresses" ]; then
  for address in $addresses; do
    if ! ip -o addr show dev wg0 | awk '{print $4}' | grep -Fxq "$address"; then
      ip addr add "$address" dev wg0
    fi
  done
fi

if [ -z "$mtu" ]; then
  mtu=1420
fi
ip link set dev wg0 mtu "$mtu" up

default_route="$(ip route show default 2>/dev/null | awk 'NR==1 {print; exit}')"
default_via="$(printf '%s\n' "$default_route" | awk '{for(i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')"
default_dev="$(printf '%s\n' "$default_route" | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
if [ -n "$default_via" ] && [ -n "$default_dev" ]; then
  ip route replace "$endpoint"/32 via "$default_via" dev "$default_dev" || {
    echo "Exiting... Could not install endpoint route" >&2
    exit 1
  }
else
  echo "Exiting... Could not determine default gateway for endpoint route" >&2
  exit 1
fi

ip -6 route del default 2>/dev/null || true
ip route replace 0.0.0.0/0 dev wg0

if [ "${SKIP_DNS:-0}" != "1" ] && [ "${SKIP_DNS:-FALSE}" != "TRUE" ] && [ -n "$dns_entries" ]; then
  if ! {
    for dns in $dns_entries; do
      printf 'nameserver %s\n' "$dns"
    done
  } | tee /etc/resolv.conf >/dev/null 2>&1; then
    echo "Could not set up DNS: /etc/resolv.conf is not writable" >&2
  fi
fi

fwmark="$(wg show wg0 fwmark)"
if [ "$fwmark" = "off" ] || [ -z "$fwmark" ]; then
  wg set wg0 fwmark 51820 || true
  fwmark="$(wg show wg0 fwmark)"
fi
if [ "$fwmark" = "off" ] || [ -z "$fwmark" ]; then
  echo "Exiting... Killswitch cannot be set because no valid fwmark is configured" >&2
  exit 1
fi

apply_killswitch "$endpoint" "$fwmark"

echo "WireGuard up, killswitch active, endpoint $endpoint whitelisted"

while :; do
  if ! ip link show dev wg0 >/dev/null 2>&1; then
    echo "wg0 is down, enforcing lockdown" >&2
    lockdown
  fi
  sleep 3600 &
  wait $! || true
done

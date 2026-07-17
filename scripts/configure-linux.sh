#!/usr/bin/env bash
set -Eeuo pipefail

APPLY=0
PERSIST=0
IFACE=""
GATEWAY=""
METRIC=512
TEST_URL="http://ipv6.test-ipv6.com/"
FALLBACK_GATEWAY="fe80::200:5eff:fe00:101"

usage() {
  printf '%s\n' "Usage: $0 [--apply] [--persist] [--interface IFACE] [--gateway FE80::ADDR] [--metric N]"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --apply) APPLY=1 ;;
    --persist) PERSIST=1 ;;
    --interface) shift; (($#)) || fail '--interface requires a value'; IFACE=$1 ;;
    --gateway) shift; (($#)) || fail '--gateway requires a value'; GATEWAY=$1 ;;
    --metric) shift; (($#)) || fail '--metric requires a value'; METRIC=$1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
  shift
done

command -v ip >/dev/null 2>&1 || fail 'iproute2 is required.'
command -v curl >/dev/null 2>&1 || fail 'curl is required.'
command -v getent >/dev/null 2>&1 || fail 'getent is required for route attribution.'

mapfile -t CAMPUS_ADDRS < <(ip -6 -o addr show scope global | awk '$4 ~ /^2001:da8:/ {print $2 " " $4}')
if [[ -n "$IFACE" ]]; then
  mapfile -t CAMPUS_ADDRS < <(printf '%s\n' "${CAMPUS_ADDRS[@]}" | awk -v dev="$IFACE" '$1 == dev')
fi
(( ${#CAMPUS_ADDRS[@]} > 0 )) || fail 'Prerequisite not met: no usable 2001:da8:... DHCPv6 address was found.'

mapfile -t CAMPUS_IFACES < <(printf '%s\n' "${CAMPUS_ADDRS[@]}" | awk '{print $1}' | sort -u)
(( ${#CAMPUS_IFACES[@]} == 1 )) || fail "multiple campus IPv6 interfaces found: ${CAMPUS_IFACES[*]}; use --interface"
IFACE=${CAMPUS_IFACES[0]}
ADDRESSES=$(printf '%s\n' "${CAMPUS_ADDRS[@]}" | awk -v dev="$IFACE" '$1 == dev {print $2}' | paste -sd ', ' -)

mapfile -t DEFAULT_ROUTES < <(ip -6 route show default | awk -v dev="$IFACE" '$0 ~ ("dev " dev "( |$)")')

run_acceptance() {
  local host bypass old_no_proxy old_no_proxy_lower destination effective_route
  host=${TEST_URL#*://}
  host=${host%%/*}
  destination=$(getent ahostsv6 "$host" | awk 'NR == 1 {print $1}')
  [[ -n "$destination" ]] || { printf 'ERROR: no AAAA record was found for %s\n' "$host" >&2; return 125; }
  effective_route=$(ip -6 route get "$destination" 2>&1) || return 125
  if [[ ! "$effective_route" =~ dev[[:space:]]$IFACE([[:space:]]|$) ]]; then
    printf 'WARNING: effective route does not use %s: %s\n' "$IFACE" "$effective_route" >&2
    return 125
  fi
  old_no_proxy=${NO_PROXY-}
  old_no_proxy_lower=${no_proxy-}
  bypass=$host
  [[ -n "$old_no_proxy" ]] && bypass="$old_no_proxy,$host"
  printf 'Effective IPv6 route: %s\n' "$effective_route"
  printf 'Acceptance: curl -6 %s\n' "$TEST_URL"
  NO_PROXY=$bypass no_proxy=${old_no_proxy_lower:+$old_no_proxy_lower,}$host curl -6 "$TEST_URL" >/dev/null
}

printf 'Interface: %s\n' "$IFACE"
printf 'Campus IPv6 address(es): %s\n' "$ADDRESSES"

if run_acceptance; then
  if (( ${#DEFAULT_ROUTES[@]} > 0 )); then
    printf 'IPv6 default route: %s\n' "${DEFAULT_ROUTES[0]}"
  fi
  printf '%s\n' 'Result: IPv6 is usable; no route change was needed.'
  exit 0
fi

if (( ${#DEFAULT_ROUTES[@]} > 0 )); then
  fail "IPv6 test failed even though a default route exists: ${DEFAULT_ROUTES[*]}. Check upstream access, DNS, or firewall; no route was changed."
fi

if [[ -z "$GATEWAY" ]]; then
  mapfile -t ROUTERS < <(ip -6 neigh show dev "$IFACE" | awk '$1 ~ /^fe80:/ && / router( |$)/ && $0 !~ /FAILED|INCOMPLETE/ {print $1}' | sort -u)
  (( ${#ROUTERS[@]} == 1 )) && GATEWAY=${ROUTERS[0]}
fi

gateway_resolves() {
  local candidate=$1 state
  ping -6 -c 1 -W 1 -I "$IFACE" "$candidate" >/dev/null 2>&1 || true
  state=$(ip -6 neigh show to "$candidate" dev "$IFACE")
  [[ -n "$state" && ! "$state" =~ (FAILED|INCOMPLETE) ]]
}

if [[ -z "$GATEWAY" ]] && gateway_resolves "$FALLBACK_GATEWAY"; then
  GATEWAY=$FALLBACK_GATEWAY
fi
[[ -n "$GATEWAY" ]] || fail 'no unique link-local router was discovered; use --gateway only after verifying it on this interface'
[[ "$GATEWAY" == fe80::* ]] || fail "refusing non-link-local gateway: $GATEWAY"

printf 'Missing route: ::/0 via %s on interface %s\n' "$GATEWAY" "$IFACE"
if (( ! APPLY )); then
  printf '%s\n' 'Rerun as root with --apply to add an active route.'
  exit 2
fi
(( EUID == 0 )) || fail '--apply requires root privileges (use sudo).'

CREATED_ROUTE=0
cleanup_failed_route() {
  if (( CREATED_ROUTE )); then
    ip -6 route del default via "$GATEWAY" dev "$IFACE" metric "$METRIC" >/dev/null 2>&1 || true
    printf '%s\n' 'WARNING: The newly added route was rolled back because validation failed.' >&2
  fi
}
trap cleanup_failed_route ERR

ip -6 route add default via "$GATEWAY" dev "$IFACE" metric "$METRIC"
CREATED_ROUTE=1

if ! run_acceptance; then
  cleanup_failed_route
  CREATED_ROUTE=0
  fail 'curl validation failed after adding the route.'
fi

SCOPE='active (until disconnect/reboot)'
if (( PERSIST )); then
  command -v nmcli >/dev/null 2>&1 || fail 'active route works, but persistence requires NetworkManager/nmcli.'
  CONNECTION=$(nmcli -g GENERAL.CONNECTION device show "$IFACE" | head -n 1)
  [[ -n "$CONNECTION" && "$CONNECTION" != '--' ]] || fail 'active route works, but the interface has no NetworkManager connection.'
  nmcli connection modify "$CONNECTION" +ipv6.routes "::/0 $GATEWAY $METRIC"
  SCOPE="persistent in NetworkManager connection $CONNECTION"
fi

trap - ERR
CREATED_ROUTE=0
printf 'Result: IPv6 is usable; added %s route ::/0 via %s.\n' "$SCOPE" "$GATEWAY"

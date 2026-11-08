#!/usr/bin/env bash
# Install the One-KVM Wi-Fi AP + captive-portal configuration into a mounted
# target root filesystem.  Packages are installed separately by
# scripts/features/apt-install.sh.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
    cat <<'EOF'
Usage: wifi-ap.sh --root DIR [options]

Options:
  --ssid-prefix PREFIX      Default: OneKVM-
  --hash-length N           Default: 6 (characters appended to the prefix)
  --security open|wpa2      Default: open
  --password PASS           Required for wpa2 unless generated at first boot
  --country CC              Default: CN
  --channel N               Default: 6
  --ip ADDRESS              Default: 192.168.4.1
  --dhcp-start ADDRESS      Default: 192.168.4.10
  --dhcp-end ADDRESS        Default: 192.168.4.100
  --portal-port PORT        Default: 8080
  --interface NAME          Empty = auto-detect at first boot
EOF
}

ROOT=""
SSID_PREFIX="OneKVM-"
HASH_LENGTH="6"
SECURITY="open"
PASSWORD=""
COUNTRY="CN"
CHANNEL="6"
AP_IP="192.168.4.1"
DHCP_START="192.168.4.10"
DHCP_END="192.168.4.100"
PORTAL_PORT="8080"
INTERFACE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --root) ROOT="${2:-}"; shift 2 ;;
        --ssid-prefix) SSID_PREFIX="${2:-}"; shift 2 ;;
        --hash-length) HASH_LENGTH="${2:-}"; shift 2 ;;
        --security) SECURITY="${2:-}"; shift 2 ;;
        --password) PASSWORD="${2:-}"; shift 2 ;;
        --country) COUNTRY="${2:-}"; shift 2 ;;
        --channel) CHANNEL="${2:-}"; shift 2 ;;
        --ip) AP_IP="${2:-}"; shift 2 ;;
        --dhcp-start) DHCP_START="${2:-}"; shift 2 ;;
        --dhcp-end) DHCP_END="${2:-}"; shift 2 ;;
        --portal-port) PORTAL_PORT="${2:-}"; shift 2 ;;
        --interface) INTERFACE="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[ -n "$ROOT" ] || die "--root is required"
[ -d "$ROOT" ] || die "Root filesystem not found: $ROOT"
ROOT="$(cd "$ROOT" && pwd)"

case "$SECURITY" in
    open|wpa2) ;;
    *) die "--security must be open or wpa2" ;;
esac
[[ "$HASH_LENGTH" =~ ^[0-9]+$ ]] || die "--hash-length must be an integer"
[ "$HASH_LENGTH" -ge 4 ] && [ "$HASH_LENGTH" -le 12 ] \
    || die "--hash-length must be between 4 and 12"
[[ "$CHANNEL" =~ ^[0-9]+$ ]] || die "--channel must be an integer"
[[ "$PORTAL_PORT" =~ ^[0-9]+$ ]] || die "--portal-port must be an integer"
[[ "$AP_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--ip must be an IPv4 address"
[[ "$DHCP_START" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--dhcp-start must be an IPv4 address"
[[ "$DHCP_END" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--dhcp-end must be an IPv4 address"
[[ "$INTERFACE" =~ ^[a-zA-Z0-9_.:-]*$ ]] || die "--interface contains invalid characters"
[[ "$SSID_PREFIX" =~ ^[A-Za-z0-9_-]+$ ]] || die "--ssid-prefix contains invalid characters"
if [ "$SECURITY" = "wpa2" ] && [ -n "$PASSWORD" ]; then
    [[ "$PASSWORD" =~ ^[A-Za-z0-9]{8,63}$ ]] \
        || die "WPA2 password must be 8-63 alphanumeric characters"
fi

STATE_DIR="${ROOT}/etc/one-kvm-wifi"
mkdir -p "$STATE_DIR" "${ROOT}/etc/systemd/system/multi-user.target.wants"
: >"$STATE_DIR/ap.env"

{
    write_env_var "$STATE_DIR/ap.env" WIFI_AP_INTERFACE "$INTERFACE"
    write_env_var "$STATE_DIR/ap.env" WIFI_AP_SSID_PREFIX "$SSID_PREFIX"
    write_env_var "$STATE_DIR/ap.env" WIFI_AP_HASH_LENGTH "$HASH_LENGTH"
    write_env_var "$STATE_DIR/ap.env" WIFI_AP_SECURITY "$SECURITY"
    write_env_var "$STATE_DIR/ap.env" WIFI_AP_PASSWORD "$PASSWORD"
    write_env_var "$STATE_DIR/ap.env" WIFI_AP_COUNTRY "$COUNTRY"
    write_env_var "$STATE_DIR/ap.env" WIFI_AP_CHANNEL "$CHANNEL"
    write_env_var "$STATE_DIR/ap.env" WIFI_AP_IP "$AP_IP"
    write_env_var "$STATE_DIR/ap.env" WIFI_AP_DHCP_START "$DHCP_START"
    write_env_var "$STATE_DIR/ap.env" WIFI_AP_DHCP_END "$DHCP_END"
    write_env_var "$STATE_DIR/ap.env" WIFI_AP_PORTAL_PORT "$PORTAL_PORT"
}
chmod 600 "$STATE_DIR/ap.env"

install -D -m 755 \
    "${REPO_ROOT}/files/wifi-ap/onekvm-ap-init.sh" \
    "${ROOT}/usr/local/sbin/onekvm-ap-init"
install -D -m 644 \
    "${REPO_ROOT}/files/wifi-ap/onekvm-wifi-ap.service" \
    "${ROOT}/etc/systemd/system/onekvm-wifi-ap.service"
ln -sfn /etc/systemd/system/onekvm-wifi-ap.service \
    "${ROOT}/etc/systemd/system/multi-user.target.wants/onekvm-wifi-ap.service"

# Start hostapd/dnsmasq/lighttpd only after the AP configuration exists.
for unit in hostapd dnsmasq lighttpd; do
    install -D -m 644 \
        "${REPO_ROOT}/files/wifi-ap/unit-after.conf" \
        "${ROOT}/etc/systemd/system/${unit}.service.d/onekvm-ap.conf"
done

# Keep the network managers away from the Wi-Fi interface.
install -D -m 644 \
    "${REPO_ROOT}/files/wifi-ap/networkmanager-unmanaged.conf" \
    "${ROOT}/etc/NetworkManager/conf.d/99-onekvm-ap.conf"
install -D -m 644 \
    "${REPO_ROOT}/files/wifi-ap/networkd-unmanaged.network" \
    "${ROOT}/etc/systemd/network/99-onekvm-ap.network"

# The standalone wpa_supplicant is not used while the AP is configured.
install -D -m 644 \
    "${REPO_ROOT}/files/wifi-ap/wpa-supplicant-condition.conf" \
    "${ROOT}/etc/systemd/system/wpa_supplicant.service.d/onekvm-ap.conf"

mkdir -p "${ROOT}/etc/hostapd" "${ROOT}/etc/dnsmasq.d" "${ROOT}/etc/lighttpd" \
         "${ROOT}/var/log/lighttpd" "${ROOT}/var/www/html"

info "Wi-Fi AP configuration installed (prefix=${SSID_PREFIX}, ip=${AP_IP}, portal=:${PORTAL_PORT})"

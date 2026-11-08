#!/usr/bin/env bash
# Configure the One-KVM Wi-Fi access point and captive portal.
#
# Runs once per boot from onekvm-wifi-ap.service, before hostapd, dnsmasq and
# lighttpd.  The SSID is OneKVM-<6 hex chars> derived from the device machine-id
# and the Wi-Fi MAC address, and is persisted in /etc/one-kvm-wifi/ssid.
set -Eeuo pipefail

ENV_FILE="/etc/one-kvm-wifi/ap.env"
STATE_DIR="/etc/one-kvm-wifi"
LOG_TAG="onekvm-ap"

log() {
    logger -t "$LOG_TAG" "$*" 2>/dev/null || printf '%s\n' "$*" >&2
}

soft_exit() {
    log "$*"
    exit 0
}

[ -r "$ENV_FILE" ] || soft_exit "missing ${ENV_FILE}; Wi-Fi AP not configured"
# shellcheck disable=SC1090,SC1091
source "$ENV_FILE"

WIFI_AP_INTERFACE="${WIFI_AP_INTERFACE:-}"
WIFI_AP_SSID_PREFIX="${WIFI_AP_SSID_PREFIX:-OneKVM-}"
WIFI_AP_HASH_LENGTH="${WIFI_AP_HASH_LENGTH:-6}"
WIFI_AP_SECURITY="${WIFI_AP_SECURITY:-open}"
WIFI_AP_PASSWORD="${WIFI_AP_PASSWORD:-}"
WIFI_AP_COUNTRY="${WIFI_AP_COUNTRY:-CN}"
WIFI_AP_CHANNEL="${WIFI_AP_CHANNEL:-6}"
WIFI_AP_IP="${WIFI_AP_IP:-192.168.4.1}"
WIFI_AP_DHCP_START="${WIFI_AP_DHCP_START:-192.168.4.10}"
WIFI_AP_DHCP_END="${WIFI_AP_DHCP_END:-192.168.4.100}"
WIFI_AP_PORTAL_PORT="${WIFI_AP_PORTAL_PORT:-8080}"

detect_iface() {
    local dev
    if [ -n "$WIFI_AP_INTERFACE" ]; then
        printf '%s' "$WIFI_AP_INTERFACE"
        return 0
    fi
    for dev in /sys/class/net/*; do
        [ -e "${dev}/phy80211" ] || continue
        basename "$dev"
        return 0
    done
    return 1
}

IFACE="$(detect_iface || true)"
if [ -z "$IFACE" ]; then
    mkdir -p "$STATE_DIR"
    touch "${STATE_DIR}/no-wifi"
    soft_exit "no wireless interface found; Wi-Fi AP disabled"
fi
rm -f "${STATE_DIR}/no-wifi"

# Make sure the wireless driver is loaded (brcmfmac on the FMX1).
modprobe brcmfmac 2>/dev/null || true

for _ in $(seq 1 30); do
    [ -e "/sys/class/net/${IFACE}" ] && break
    sleep 1
done
[ -e "/sys/class/net/${IFACE}" ] || soft_exit "wireless interface ${IFACE} did not appear"

# Stable per-device SSID: hash(machine-id + MAC), six uppercase hex characters.
if [ ! -s "${STATE_DIR}/ssid" ]; then
    seed="$(cat /etc/machine-id 2>/dev/null || true)"
    seed="${seed}$(cat "/sys/class/net/${IFACE}/address" 2>/dev/null || true)"
    [ -n "$seed" ] || seed="$(hostname)"
    hash="$(printf '%s' "$seed" | sha256sum \
        | cut -c1-"${WIFI_AP_HASH_LENGTH}" | tr 'a-f' 'A-F')"
    printf '%s%s\n' "$WIFI_AP_SSID_PREFIX" "$hash" >"${STATE_DIR}/ssid"
    chmod 644 "${STATE_DIR}/ssid"
fi
SSID="$(cat "${STATE_DIR}/ssid")"

PASSWORD=""
if [ "$WIFI_AP_SECURITY" = "wpa2" ]; then
    if [ ! -s "${STATE_DIR}/password" ]; then
        if [ -n "$WIFI_AP_PASSWORD" ]; then
            printf '%s\n' "$WIFI_AP_PASSWORD" >"${STATE_DIR}/password"
        else
            generated="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 12 || true)"
            [ -n "$generated" ] || generated="$(date +%s%N | sha256sum | cut -c1-12)"
            printf '%s\n' "$generated" >"${STATE_DIR}/password"
        fi
        chmod 600 "${STATE_DIR}/password"
    fi
    PASSWORD="$(cat "${STATE_DIR}/password")"
fi

# Configure the interface.  hostapd takes over the AP mode after us.
ip link set "$IFACE" down 2>/dev/null || true
ip addr flush dev "$IFACE" 2>/dev/null || true
if ! ip addr replace "${WIFI_AP_IP}/24" dev "$IFACE"; then
    soft_exit "cannot assign ${WIFI_AP_IP} to ${IFACE}"
fi
if ! ip link set "$IFACE" up; then
    soft_exit "cannot bring ${IFACE} up"
fi
if command -v iw >/dev/null 2>&1; then
    iw reg set "$WIFI_AP_COUNTRY" 2>/dev/null || true
fi

# hostapd: open or WPA2 AP on the configured channel.
{
    echo "interface=${IFACE}"
    echo "driver=nl80211"
    echo "ssid=${SSID}"
    echo "hw_mode=g"
    echo "channel=${WIFI_AP_CHANNEL}"
    echo "country_code=${WIFI_AP_COUNTRY}"
    echo "ieee80211d=1"
    echo "auth_algs=1"
    echo "wmm_enabled=1"
    echo "macaddr_acl=0"
    if [ "$WIFI_AP_SECURITY" = "wpa2" ]; then
        echo "wpa=2"
        echo "wpa_passphrase=${PASSWORD}"
        echo "wpa_key_mgmt=WPA-PSK"
        echo "rsn_pairwise=CCMP"
    fi
} >/etc/hostapd/hostapd.conf
chmod 600 /etc/hostapd/hostapd.conf

if [ -f /etc/default/hostapd ]; then
    if grep -q '^DAEMON_CONF=' /etc/default/hostapd; then
        sed -i 's|^DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
    else
        echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >>/etc/default/hostapd
    fi
else
    echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >/etc/default/hostapd
fi

# dnsmasq: DHCP for AP clients, and every DNS name resolves to the AP so
# HTTP requests land on the portal.
{
    echo "interface=${IFACE}"
    echo "bind-interfaces"
    echo "dhcp-range=${WIFI_AP_DHCP_START},${WIFI_AP_DHCP_END},255.255.255.0,12h"
    echo "dhcp-option=3,${WIFI_AP_IP}"
    echo "dhcp-option=6,${WIFI_AP_IP}"
    echo "dhcp-option=114,http://${WIFI_AP_IP}/"
    echo "dhcp-option=160,http://${WIFI_AP_IP}/"
    echo "address=/#/${WIFI_AP_IP}"
    echo "no-resolv"
    echo "domain-needed"
    echo "bogus-priv"
    echo "dhcp-authoritative"
} >/etc/dnsmasq.d/onekvm-ap.conf

# lighttpd: redirect every HTTP request to the One-KVM web UI.
{
    echo "server.bind = \"${WIFI_AP_IP}\""
    echo 'server.port = 80'
    echo 'server.modules = ("mod_redirect")'
    echo 'server.document-root = "/var/www/html"'
    echo 'server.errorlog = "/var/log/lighttpd/onekvm-error.log"'
    echo 'server.pid-file = "/run/lighttpd.pid"'
    echo "url.redirect = ( \"^/.*\" => \"http://${WIFI_AP_IP}:${WIFI_AP_PORTAL_PORT}/\" )"
} >/etc/lighttpd/lighttpd.conf
mkdir -p /var/log/lighttpd /var/www/html
chown -R www-data:www-data /var/log/lighttpd /var/www/html 2>/dev/null || true

{
    echo "SSID=${SSID}"
    echo "INTERFACE=${IFACE}"
    echo "IP=${WIFI_AP_IP}"
    echo "PORTAL=http://${WIFI_AP_IP}:${WIFI_AP_PORTAL_PORT}/"
} >"${STATE_DIR}/runtime.env"
chmod 644 "${STATE_DIR}/runtime.env"

# Convenience copy on the boot partition for headless setup.
{
    echo "SSID: ${SSID}"
    echo "Portal: http://${WIFI_AP_IP}:${WIFI_AP_PORTAL_PORT}/"
    if [ "$WIFI_AP_SECURITY" = "wpa2" ]; then
        echo "Password: ${PASSWORD}"
    fi
} >/boot/one-kvm-wifi.txt 2>/dev/null || true

log "Wi-Fi AP configured: SSID=${SSID} interface=${IFACE} ip=${WIFI_AP_IP} portal=http://${WIFI_AP_IP}:${WIFI_AP_PORTAL_PORT}/"
exit 0

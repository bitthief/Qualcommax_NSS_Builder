#!/bin/sh
# 99-recovery-layer.sh
#
# PASS ONE. Goes in the image at files/etc/uci-defaults/99-recovery-layer.sh
#
# Purpose: guarantee the box is reachable after `sysupgrade -n`, over Wi-Fi,
# without knowing anything about the new build's device-tree paths.
#
# Because it ships inside the squashfs, it re-runs after every `firstboot`
# as well as after the initial flash — so a factory reset always lands here.
#
# Deliberately boring: WPA2-PSK (not sae-mixed), HT20, fixed non-DFS channels,
# no FT, no PMF, no isolation, one flat bridge, NSS off. One thing at a time.

exec >>/tmp/recovery-layer.log 2>&1
echo "=== $(date) recovery layer starting ==="

. /lib/functions.sh

#############################################################################
# EDIT THESE THREE BEFORE BUILDING
#############################################################################
RECOVERY_SSID='OpenWRT-Recovery'
RECOVERY_KEY='w1f1p4ssw0rd'
RECOVERY_IP='192.168.99.1'
AUTHORIZED_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHfXXoEQORAY7p3bHK5Doe3Zvh/G3yjHM5KTEH7PxQAy bitthief'
COUNTRY='RO'
#############################################################################

## ---------------------------------------------------------------- network
# Flat br-lan across every wired port; stock image already builds it.
# Only the address and the NSS-hostile globals change.
uci -q batch <<EOF
set network.lan.proto='static'
set network.lan.ipaddr='${RECOVERY_IP}'
set network.lan.netmask='255.255.255.0'
delete network.lan.ip6assign
set network.globals.packet_steering='0'
EOF
uci commit network

## -------------------------------------------------------------------- NSS
# Boot as plain host-path OpenWrt. Survives sysupgrade by design.
# Verify the port with the real config first, THEN turn offload on separately.
[ -f /etc/config/nss ] || : > /etc/config/nss
uci -q get nss.general >/dev/null 2>&1 || uci -q set nss.general='general'
uci -q set nss.general.enabled='0'
uci commit nss

## ------------------------------------------------------------------- dhcp
uci -q batch <<EOF
set dhcp.lan.start='100'
set dhcp.lan.limit='100'
set dhcp.lan.leasetime='2h'
delete dhcp.lan.dhcpv6
delete dhcp.lan.ra
EOF
uci commit dhcp

## --------------------------------------------------------------- ssh keys
# Julius's image is openssh-server, dropbear=n. Write both locations so this
# works regardless of which sshd the build actually ships.
mkdir -p /root/.ssh /etc/dropbear
printf '%s\n' "$AUTHORIZED_KEY" > /root/.ssh/authorized_keys
printf '%s\n' "$AUTHORIZED_KEY" > /etc/dropbear/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys /etc/dropbear/authorized_keys

## ------------------------------------------------------------------- wifi
# Let the image detect its own radios. Never hardcode `path` — it is the one
# thing most likely to differ on a new kernel, and if it is wrong here there
# is no way back in without a cable.
rm -f /etc/config/wireless
wifi config

# Drop whatever VAPs the image generated (they ship disabled and keyless).
config_load wireless
drop_iface() { uci -q delete "wireless.$1"; }
config_foreach drop_iface wifi-iface

# Attach one recovery AP to EVERY detected radio, keyed on band. Same SSID on
# all of them, so a single radio failing to come up is not a lockout.
add_recovery_ap() {
	local dev="$1" band
	config_get band "$dev" band

	uci -q delete "wireless.${dev}.disabled"
	uci -q set "wireless.${dev}.country=${COUNTRY}"
	uci -q set "wireless.${dev}.cell_density=0"

	case "$band" in
		2g) uci -q set "wireless.${dev}.channel=1"
		    uci -q set "wireless.${dev}.htmode=HT20" ;;
		# 36 is non-DFS: a DFS channel means 60s CAC before it beacons,
		# which looks exactly like a failed flash.
		5g) uci -q set "wireless.${dev}.channel=36"
		    uci -q set "wireless.${dev}.htmode=HT20" ;;
		6g) uci -q set "wireless.${dev}.disabled=1"; return ;;
		*)  uci -q set "wireless.${dev}.htmode=HT20" ;;
	esac

	uci -q batch <<-EOF
		set wireless.rec_${dev}='wifi-iface'
		set wireless.rec_${dev}.device='${dev}'
		set wireless.rec_${dev}.network='lan'
		set wireless.rec_${dev}.mode='ap'
		set wireless.rec_${dev}.ssid='${RECOVERY_SSID}'
		set wireless.rec_${dev}.encryption='psk2'
		set wireless.rec_${dev}.key='${RECOVERY_KEY}'
	EOF
	echo "recovery AP attached to ${dev} (band=${band})"
}
config_load wireless
config_foreach add_recovery_ap wifi-device
uci commit wireless

## ---------------------------------------------------------------- marker
echo "recovery-layer applied $(date)" > /etc/recovery-layer.stamp
echo "=== radios seen ==="
uci show wireless | grep -E '\.(path|band|channel)='

exit 0

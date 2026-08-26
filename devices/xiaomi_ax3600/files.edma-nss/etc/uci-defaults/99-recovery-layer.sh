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
# Do NOT regenerate: 98-wireless-ath10k.sh and 98-wireless-ath11k.sh have
# already run and built the real config. Only add the recovery AP on top.
[ -s /etc/config/wireless ] || wifi config

# Drop whatever VAPs the image generated (they ship disabled and keyless).
# Attach one recovery AP to EVERY detected radio, keyed on band. Same SSID on
# all of them, so a single radio failing to come up is not a lockout.
add_recovery_ap() {
	local dev="$1" band
	config_get band "$dev" band

	uci -q delete "wireless.${dev}.disabled"
	uci -q set "wireless.${dev}.country=${COUNTRY}"
	uci -q set "wireless.${dev}.cell_density=0"

	# PCI-attached = the ath10k IoT radio. The recovery AP never depends on it:
	# it is the radio most likely to be the reason you need recovery.
	local path; config_get path "$dev" path
	case "$path" in *pci*) echo "skipping PCI radio $dev for recovery"; return ;; esac

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

## ------------------------------------------------- sshd on the recovery IP
## sshd_config binds to the PRIVATE gateway only. If you land here, PRIVATE
## may not exist yet — so add the recovery address, in BOTH families. The v6
## one is not decoration: a working v6 path is what saved you the serial cable
## last time, and v4 DHCP is exactly what tends to be broken when you need it.
##
## These lines are marked and are removed again by inject-secrets.sh when you
## set KEEP_RECOVERY_AP=0, alongside the recovery AP itself. Same flag, same
## moment, so there is one thing to remember rather than two.
SSHD=/etc/ssh/sshd_config
if [ -f "$SSHD" ] && ! grep -q 'RECOVERY-LAYER' "$SSHD"; then
	{
		echo ""
		echo "# --- RECOVERY-LAYER BEGIN (removed by inject-secrets.sh) ---"
		echo "ListenAddress ${RECOVERY_IP}"
		echo "ListenAddress fe80::%br-lan"
		echo "# --- RECOVERY-LAYER END ---"
	} >> "$SSHD"
	echo "recovery ListenAddress added to sshd_config"
	/etc/init.d/sshd restart 2>/dev/null || /etc/init.d/openssh restart 2>/dev/null || true
fi

## ---------------------------------------------------------------- marker
echo "recovery-layer applied $(date)" > /etc/recovery-layer.stamp
echo "=== radios seen ==="
uci show wireless | grep -E '\.(path|band|channel)='

exit 0

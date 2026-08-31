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
## network.lan does not exist in the production image (svc/iot/guest/private),
## so this is guarded. In a stock-image recovery it does, and gives the flat
## fallback network.
if uci -q get network.lan >/dev/null 2>&1; then
	uci -q batch <<-EOF
		set network.lan.proto='static'
		set network.lan.ipaddr='${RECOVERY_IP}'
		set network.lan.netmask='255.255.255.0'
		delete network.lan.ip6assign
	EOF
else
	RECOVERY_NET=private
fi
uci -q set network.globals.packet_steering='0'
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
	## DELIBERATELY DOES NOT SET A CHANNEL.
	##
	## It used to force 5 GHz to 36 and 2.4 GHz to 1 so the recovery AP would
	## come up without waiting out a DFS CAC. That clobbered the production
	## channels permanently — 129 became 36 and 9 became 1, on every boot,
	## after 98-wireless-ath11k.sh had just set them correctly.
	##
	## The recovery AP now shares whatever channel the radio is already on. On
	## a DFS channel that means ~60 s of no beacon at boot before it appears,
	## which is the correct trade: a slow recovery AP beats a production radio
	## silently moved to a congested channel.
	local path; config_get path "$dev" path
	case "$path" in *pci*) echo "skipping PCI radio $dev for recovery"; return ;; esac


	uci -q batch <<-EOF
		set wireless.rec_${dev}='wifi-iface'
		set wireless.rec_${dev}.device='${dev}'
		set wireless.rec_${dev}.network='${RECOVERY_NET:-lan}'
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

## Deliberately does NOT touch sshd.
##
## This block used to append ListenAddress lines for the recovery IP. Both were
## broken: `fe80::%br-lan` is not a valid sshd address (a scope needs a real
## address, not a bare prefix) and that is a fatal parse error, and
## 192.168.99.1 never exists in this image because the production network has
## no `lan` interface. sshd exited at parse time and respawned forever.
##
## sshd_config now carries no ListenAddress at all, so sshd binds every
## address including anything this script brings up. Nothing to patch.

## ---------------------------------------------------------------- marker
echo "recovery-layer applied $(date)" > /etc/recovery-layer.stamp
echo "=== radios seen ==="
uci show wireless | grep -E '\.(path|band|channel)='

exit 0

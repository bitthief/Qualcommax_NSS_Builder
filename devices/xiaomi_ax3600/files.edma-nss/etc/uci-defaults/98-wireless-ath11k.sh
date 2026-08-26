#!/bin/sh
# 98-wireless-ath11k.sh — the two on-SoC ath11k radios.
#
# Deliberately independent of the ath10k script: if the PCIe IoT radio is
# absent or its firmware is missing, GUEST and PRIVATE still come up. That
# separation is the whole point — last time a single script handled both and
# an ath10k failure took all wireless down with it.
#
# Classifies by band from whatever `wifi config` detected. Never hardcodes
# `path`: on 6.18 the node is platform/soc@0/c000000.wifi (note soc@0), which
# is not what 6.1 used.

exec >>/tmp/wireless-ath11k.log 2>&1
echo "=== $(date) ath11k setup ==="
. /lib/functions.sh

COUNTRY='RO'

## SINGLE SSID PER NETWORK, BOTH BANDS — this is what usteer steers.
## Band steering only works if the two radios advertise the same SSID; with
## _5G suffixes a client sees two separate networks and there is nothing to
## steer between.
##
## COST: guest devices saved against 'TP-Link_0337D_5G' will not find it and
## must forget/rejoin. PRIVATE gains a 2.4 GHz VAP it did not have, so nothing
## there breaks — existing 5 GHz clients keep working.
SSID_GUEST='TP-Link_0337D'
SSID_PRIVATE='TP-Link_1337D'

# Generate only if absent — the ath10k script may have run first.
[ -s /etc/config/wireless ] || wifi config

R5G=''; R24=''
classify() {
	local dev="$1" band path
	config_get band "$dev" band
	config_get path "$dev" path
	# PCI-attached radios belong to the ath10k script.
	case "$path" in *pci*) return ;; esac
	case "$band" in
		5g) R5G="$dev" ;;
		2g) R24="$dev" ;;
		6g) uci -q set "wireless.${dev}.disabled=1" ;;
	esac
}
config_load wireless
config_foreach classify wifi-device
echo "ath11k: 5G=${R5G:-none} 2.4G=${R24:-none}"

if [ -z "$R5G" ] && [ -z "$R24" ]; then
	echo "!! no ath11k radios found — leaving wireless alone"
	exit 0
fi

# Drop only the placeholder VAPs on the radios we own.
config_load wireless
drop_ours() {
	local dev; config_get dev "$1" device
	[ "$dev" = "$R5G" ] || [ "$dev" = "$R24" ] || return 0
	case "$1" in iot_ap|rec_*) return 0 ;; esac
	uci -q delete "wireless.$1"
}
config_foreach drop_ours wifi-iface

common_vap() {  # common_vap <section>
	uci -q batch <<-EOF
		set wireless.$1.mode='ap'
		set wireless.$1.encryption='sae-mixed'
		set wireless.$1.doth='1'
		set wireless.$1.ieee80211w='2'
		set wireless.$1.ieee80211r='1'
		set wireless.$1.ieee80211k='1'
		set wireless.$1.ft_over_ds='1'
		set wireless.$1.ft_psk_generate_local='1'
		set wireless.$1.pmk_r1_push='1'
		set wireless.$1.wpa_disable_eapol_key_retries='1'
		set wireless.$1.time_advertisement='2'
		set wireless.$1.wnm_sleep_mode='1'
		set wireless.$1.wnm_sleep_mode_no_keys='1'
		set wireless.$1.bss_transition='1'
		set wireless.$1.multicast_to_unicast_all='1'
		set wireless.$1.disabled='1'
	EOF
}

if [ -n "$R5G" ]; then
	uci -q batch <<-EOF
		delete wireless.${R5G}.disabled
		set wireless.${R5G}.country='${COUNTRY}'
		set wireless.${R5G}.channel='auto'
		set wireless.${R5G}.htmode='HE160'
		set wireless.${R5G}.txpower='23'
		set wireless.${R5G}.distance='15'
		set wireless.${R5G}.beacon_int='100'
		set wireless.${R5G}.cell_density='0'
		set wireless.${R5G}.he_bss_color='16'
		set wireless.${R5G}.he_su_beamformer='1'
		set wireless.${R5G}.he_su_beamformee='0'
		set wireless.${R5G}.he_mu_beamformer='1'
		set wireless.guest_5g='wifi-iface'
		set wireless.guest_5g.device='${R5G}'
		set wireless.guest_5g.network='guest'
		set wireless.guest_5g.ssid='${SSID_GUEST}'
		set wireless.guest_5g.isolate='0'
		set wireless.guest_5g.proxy_arp='1'
		set wireless.private_5g='wifi-iface'
		set wireless.private_5g.device='${R5G}'
		set wireless.private_5g.network='private'
		set wireless.private_5g.ssid='${SSID_PRIVATE}'
		## hidden REMOVED. A hidden SSID cannot be found by passive scan, so
		## 802.11k neighbour reports and usteer's steering both degrade — the
		## client has to probe for it on every band change. It was never real
		## security either. Set hidden='1' again if you would rather keep it
		## and accept worse roaming.
		set wireless.private_5g.isolate='1'
	EOF
	common_vap guest_5g
	common_vap private_5g
fi

if [ -n "$R24" ]; then
	# Channel 11, 20 MHz: non-overlapping with the IoT radio on channel 1.
	uci -q batch <<-EOF
		delete wireless.${R24}.disabled
		set wireless.${R24}.country='${COUNTRY}'
		set wireless.${R24}.channel='11'
		set wireless.${R24}.htmode='HE20'
		set wireless.${R24}.txpower='20'
		set wireless.${R24}.distance='15'
		set wireless.${R24}.beacon_int='100'
		set wireless.${R24}.cell_density='0'
		set wireless.${R24}.he_bss_color='16'
		set wireless.${R24}.he_su_beamformer='1'
		set wireless.${R24}.he_su_beamformee='0'
		set wireless.${R24}.he_mu_beamformer='1'
		delete wireless.${R24}.acs_chan_bias
		set wireless.guest_24='wifi-iface'
		set wireless.guest_24.device='${R24}'
		set wireless.guest_24.network='guest'
		set wireless.guest_24.ssid='${SSID_GUEST}'
		set wireless.guest_24.isolate='0'
		set wireless.guest_24.proxy_arp='1'
		set wireless.private_24='wifi-iface'
		set wireless.private_24.device='${R24}'
		set wireless.private_24.network='private'
		set wireless.private_24.ssid='${SSID_PRIVATE}'
		set wireless.private_24.isolate='1'
	EOF
	common_vap guest_24
	common_vap private_24
fi

uci commit wireless
echo "ath11k done"; uci show wireless | grep -E '\.(path|band|channel)='
exit 0

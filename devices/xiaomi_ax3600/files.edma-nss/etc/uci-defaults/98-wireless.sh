#!/bin/sh
# 98-wireless.sh
#
# PASS THREE, but path-independent — so it can ship in the first image.
#
# Your old config selected radios by `option path`:
#   radio0  soc/20000000.pci/pci0000:00/0000:00:00.0/0000:01:00.0   (ath10k)
#   radio1  platform/soc/c000000.wifi                               (ath11k 5G)
#   radio2  platform/soc/c000000.wifi+1                             (ath11k 2.4G)
#
# Those strings are not guaranteed across a kernel jump from 6.1 to 6.18.
# This script instead classifies whatever `wifi config` detected, by band plus
# whether the radio hangs off PCI. On the AX3600 the only PCI-attached radio is
# the QCA9887/9889 IoT radio, so the mapping is unambiguous:
#
#   2.4 GHz + PCI      -> IOT      (ath10k, 1x1 802.11n, NOT NSS-offloaded)
#   5   GHz            -> GUEST-5G + PRIVATE-5G (ath11k, wifili offload)
#   2.4 GHz + non-PCI  -> GUEST-2.4 (ath11k, wifili offload)
#
# CHANNEL FIX: both 2.4 GHz radios were running on channel 9 — radio0 at HT40
# with centre channel 11 (so ~ch 9-13) and radio2 at HE20 on 9, directly on
# top of it. Their acs_chan_bias strings were near-identical, so ACS converged
# them onto the same channel every time. Fixed channels 1 and 11, both 20 MHz.
#
# Run order: 98 (this) before 99 (recovery layer), so the recovery AP is
# added on top of correctly configured radios. Delete 99-recovery-layer.sh
# from the image once you are happy with the deployment.

exec >>/tmp/wireless-setup.log 2>&1
echo "=== $(date) wireless setup ==="

. /lib/functions.sh

#############################################################################
# NO PSKs HERE. Production VAPs are created with encryption configured but
# no key, and shipped `disabled '1'`. inject-secrets.sh sets the keys and
# enables them. Until then the recovery AP from 99-recovery-layer.sh is your
# way in — which is exactly what it is for.
#############################################################################
COUNTRY='RO'

SSID_IOT='TP-Link_1OT'
SSID_GUEST_5G='TP-Link_0337D_5G'
SSID_GUEST_24='TP-Link_0337D'
SSID_PRIVATE_5G='TP-Link_1337D_5G'
#############################################################################

rm -f /etc/config/wireless
wifi config

# Drop the generated placeholder VAPs
config_load wireless
drop_iface() { uci -q delete "wireless.$1"; }
config_foreach drop_iface wifi-iface

RADIO_IOT=''; RADIO_5G=''; RADIO_24=''

classify() {
	local dev="$1" band path
	config_get band "$dev" band
	config_get path "$dev" path

	case "$band" in
		5g) RADIO_5G="$dev" ;;
		2g)
			case "$path" in
				*pci*) RADIO_IOT="$dev" ;;
				*)     RADIO_24="$dev" ;;
			esac ;;
		6g) uci -q set "wireless.${dev}.disabled=1" ;;
	esac
}
config_load wireless
config_foreach classify wifi-device

echo "classified: IOT=${RADIO_IOT:-none} 5G=${RADIO_5G:-none} 24=${RADIO_24:-none}"

if [ -z "$RADIO_IOT" ] || [ -z "$RADIO_5G" ] || [ -z "$RADIO_24" ]; then
	echo "!! classification incomplete — leaving wireless alone."
	echo "!! The recovery layer (99) will still bring up an AP on every radio."
	uci -q commit wireless
	exit 0
fi

## ------------------------------------------------------ IOT radio (ath10k)
# legacy_rates and noscan retained from your config: appliance firmware often
# needs the low OFDM/CCK rates advertised. noscan is now safe *because* the
# channel is fixed and 20 MHz — it was harmful at HT40 on a shared channel.
uci -q batch <<EOF
delete wireless.${RADIO_IOT}.disabled
set wireless.${RADIO_IOT}.country='${COUNTRY}'
set wireless.${RADIO_IOT}.channel='1'
set wireless.${RADIO_IOT}.htmode='HT20'
set wireless.${RADIO_IOT}.txpower='20'
set wireless.${RADIO_IOT}.distance='15'
set wireless.${RADIO_IOT}.beacon_int='200'
set wireless.${RADIO_IOT}.cell_density='0'
set wireless.${RADIO_IOT}.legacy_rates='1'
set wireless.${RADIO_IOT}.noscan='1'
delete wireless.${RADIO_IOT}.acs_chan_bias

set wireless.iot_ap='wifi-iface'
set wireless.iot_ap.device='${RADIO_IOT}'
set wireless.iot_ap.network='iot'
set wireless.iot_ap.mode='ap'
set wireless.iot_ap.ssid='${SSID_IOT}'
set wireless.iot_ap.encryption='sae-mixed'
set wireless.iot_ap.disabled='1'
set wireless.iot_ap.doth='1'
set wireless.iot_ap.ieee80211v='1'
set wireless.iot_ap.wpa_disable_eapol_key_retries='1'
set wireless.iot_ap.multicast_to_unicast_all='1'
set wireless.iot_ap.disassoc_low_ack='0'
set wireless.iot_ap.dtim_period='3'
set wireless.iot_ap.max_inactivity='1800'
EOF

## ------------------------------------------------------- 5 GHz (ath11k)
uci -q batch <<EOF
delete wireless.${RADIO_5G}.disabled
set wireless.${RADIO_5G}.country='${COUNTRY}'
set wireless.${RADIO_5G}.htmode='HE160'
set wireless.${RADIO_5G}.channel='auto'
set wireless.${RADIO_5G}.txpower='23'
set wireless.${RADIO_5G}.distance='15'
set wireless.${RADIO_5G}.beacon_int='100'
set wireless.${RADIO_5G}.cell_density='0'
set wireless.${RADIO_5G}.he_bss_color='16'
set wireless.${RADIO_5G}.he_su_beamformer='1'
set wireless.${RADIO_5G}.he_su_beamformee='0'
set wireless.${RADIO_5G}.he_mu_beamformer='1'
set wireless.${RADIO_5G}.acs_chan_bias='100:0.4 104:0.5 108:0.5 112:0.6 114:0.6 116:0.7 120:0.7 124:0.7 128:0.7 132:0.7 140:0.7'

set wireless.guest_5g='wifi-iface'
set wireless.guest_5g.device='${RADIO_5G}'
set wireless.guest_5g.network='guest'
set wireless.guest_5g.mode='ap'
set wireless.guest_5g.ssid='${SSID_GUEST_5G}'
set wireless.guest_5g.encryption='sae-mixed'
set wireless.guest_5g.disabled='1'
set wireless.guest_5g.isolate='1'
set wireless.guest_5g.doth='1'
set wireless.guest_5g.ieee80211w='2'
set wireless.guest_5g.ieee80211r='1'
set wireless.guest_5g.ieee80211k='1'
set wireless.guest_5g.ft_over_ds='1'
set wireless.guest_5g.ft_psk_generate_local='1'
set wireless.guest_5g.pmk_r1_push='1'
set wireless.guest_5g.wpa_disable_eapol_key_retries='1'
set wireless.guest_5g.time_advertisement='2'
set wireless.guest_5g.wnm_sleep_mode='1'
set wireless.guest_5g.wnm_sleep_mode_no_keys='1'
set wireless.guest_5g.bss_transition='1'
set wireless.guest_5g.multicast_to_unicast_all='1'
set wireless.guest_5g.proxy_arp='1'

set wireless.private_5g='wifi-iface'
set wireless.private_5g.device='${RADIO_5G}'
set wireless.private_5g.network='private'
set wireless.private_5g.mode='ap'
set wireless.private_5g.ssid='${SSID_PRIVATE_5G}'
set wireless.private_5g.encryption='sae-mixed'
set wireless.private_5g.disabled='1'
set wireless.private_5g.hidden='1'
set wireless.private_5g.isolate='1'
set wireless.private_5g.doth='1'
set wireless.private_5g.ieee80211w='2'
set wireless.private_5g.ieee80211r='1'
set wireless.private_5g.ieee80211k='1'
set wireless.private_5g.ft_over_ds='1'
set wireless.private_5g.ft_psk_generate_local='1'
set wireless.private_5g.pmk_r1_push='1'
set wireless.private_5g.wpa_disable_eapol_key_retries='1'
set wireless.private_5g.time_advertisement='2'
set wireless.private_5g.wnm_sleep_mode='1'
set wireless.private_5g.wnm_sleep_mode_no_keys='1'
set wireless.private_5g.bss_transition='1'
set wireless.private_5g.multicast_to_unicast_all='1'
EOF

## ------------------------------------------------- 2.4 GHz guest (ath11k)
# Channel 11, 20 MHz. Non-overlapping with the IoT radio on channel 1.
uci -q batch <<EOF
delete wireless.${RADIO_24}.disabled
set wireless.${RADIO_24}.country='${COUNTRY}'
set wireless.${RADIO_24}.channel='11'
set wireless.${RADIO_24}.htmode='HE20'
set wireless.${RADIO_24}.txpower='20'
set wireless.${RADIO_24}.distance='15'
set wireless.${RADIO_24}.beacon_int='100'
set wireless.${RADIO_24}.cell_density='0'
set wireless.${RADIO_24}.he_bss_color='16'
set wireless.${RADIO_24}.he_su_beamformer='1'
set wireless.${RADIO_24}.he_su_beamformee='0'
set wireless.${RADIO_24}.he_mu_beamformer='1'
delete wireless.${RADIO_24}.acs_chan_bias

set wireless.guest_24='wifi-iface'
set wireless.guest_24.device='${RADIO_24}'
set wireless.guest_24.network='guest'
set wireless.guest_24.mode='ap'
set wireless.guest_24.ssid='${SSID_GUEST_24}'
set wireless.guest_24.encryption='sae-mixed'
set wireless.guest_24.disabled='1'
set wireless.guest_24.isolate='1'
set wireless.guest_24.doth='1'
set wireless.guest_24.ieee80211w='2'
set wireless.guest_24.ieee80211r='1'
set wireless.guest_24.ieee80211k='1'
set wireless.guest_24.ft_over_ds='1'
set wireless.guest_24.ft_psk_generate_local='1'
set wireless.guest_24.pmk_r1_push='1'
set wireless.guest_24.wpa_disable_eapol_key_retries='1'
set wireless.guest_24.time_advertisement='2'
set wireless.guest_24.wnm_sleep_mode='1'
set wireless.guest_24.wnm_sleep_mode_no_keys='1'
set wireless.guest_24.bss_transition='1'
set wireless.guest_24.multicast_to_unicast_all='1'
set wireless.guest_24.proxy_arp='1'
EOF

uci commit wireless

echo "=== resulting radio map ==="
uci show wireless | grep -E '\.(path|band|channel|htmode)='
exit 0

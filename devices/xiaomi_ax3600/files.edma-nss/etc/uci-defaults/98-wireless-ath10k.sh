#!/bin/sh
# 98-wireless-ath10k.sh — the PCIe QCA9887/9889 IoT radio, and only that.
#
# Runs BEFORE the ath11k script (98- prefix, alphabetically ath10k < ath11k)
# but is fully independent: every failure path here exits 0 without touching
# the ath11k radios or the recovery AP.
#
# Validates the whole chain before configuring anything, and says which link
# broke — the previous version just reported "classification incomplete".

exec >>/tmp/wireless-ath10k.log 2>&1
echo "=== $(date) ath10k / IoT radio setup ==="
. /lib/functions.sh

COUNTRY='RO'
SSID_IOT='TP-Link_1OT'

fail() { echo "!! $*"; echo "!! IoT radio NOT configured; ath11k radios unaffected."; exit 0; }

## ---- 1. PCIe bus ----
if [ ! -d /sys/bus/pci/devices ] || [ -z "$(ls -A /sys/bus/pci/devices 2>/dev/null)" ]; then
	echo "--- dmesg pcie ---"; dmesg | grep -iE 'pcie|qmp' | tail -20
	fail "no PCIe devices enumerated. This is a bus/PHY problem, not a driver one."
fi
echo "PCIe devices: $(ls /sys/bus/pci/devices)"

## ---- 2. driver module ----
if ! grep -qE '^ath10k_(pci|core)' /proc/modules 2>/dev/null; then
	modprobe ath10k_pci 2>/dev/null
	sleep 1
fi
grep -qE '^ath10k_pci' /proc/modules 2>/dev/null || \
	fail "ath10k_pci not loaded. Missing kmod-ath10k-ct-smallbuffers in the image."

## ---- 3. firmware ----
FWDIR=/lib/firmware/ath10k/QCA9887/hw1.0
if [ ! -d "$FWDIR" ] || [ -z "$(ls -A "$FWDIR" 2>/dev/null)" ]; then
	echo "--- dmesg ath10k ---"; dmesg | grep -i ath10k | tail -20
	fail "$FWDIR missing or empty. Need ath10k-firmware-qca9887-ct-full-htt AND ath10k-board-qca9887."
fi
echo "firmware present: $(ls "$FWDIR" | tr '\n' ' ')"

## ---- 4. did a phy actually register? ----
RADIO=''
[ -s /etc/config/wireless ] || wifi config
find_pci_radio() {
	local dev="$1" path
	config_get path "$dev" path
	case "$path" in *pci*) RADIO="$dev" ;; esac
}
config_load wireless
config_foreach find_pci_radio wifi-device

if [ -z "$RADIO" ]; then
	echo "--- dmesg ath10k ---"; dmesg | grep -i ath10k | tail -20
	echo "--- phys present ---"; ls /sys/class/ieee80211/ 2>/dev/null
	fail "driver and firmware present but no PCI-attached wifi-device was detected. Check dmesg above for a firmware-load or PCIe-link error."
fi
echo "IoT radio: $RADIO"

## ---- 5. configure ----
# legacy_rates and noscan are retained from the 6.1 config: appliance firmware
# frequently needs the low CCK/OFDM rates advertised. noscan is safe here
# because the channel is fixed at 1 and the width is 20 MHz.
uci -q batch <<EOF
delete wireless.${RADIO}.disabled
set wireless.${RADIO}.country='${COUNTRY}'
set wireless.${RADIO}.channel='1'
set wireless.${RADIO}.htmode='HT20'
set wireless.${RADIO}.txpower='20'
set wireless.${RADIO}.distance='15'
set wireless.${RADIO}.beacon_int='200'
set wireless.${RADIO}.cell_density='0'
set wireless.${RADIO}.legacy_rates='1'
set wireless.${RADIO}.noscan='1'
delete wireless.${RADIO}.acs_chan_bias

set wireless.iot_ap='wifi-iface'
set wireless.iot_ap.device='${RADIO}'
set wireless.iot_ap.network='iot'
set wireless.iot_ap.mode='ap'
set wireless.iot_ap.ssid='${SSID_IOT}'
set wireless.iot_ap.encryption='sae-mixed'
set wireless.iot_ap.doth='1'
set wireless.iot_ap.ieee80211v='1'
set wireless.iot_ap.wpa_disable_eapol_key_retries='1'
set wireless.iot_ap.multicast_to_unicast_all='1'
set wireless.iot_ap.disassoc_low_ack='0'
set wireless.iot_ap.dtim_period='3'
set wireless.iot_ap.max_inactivity='1800'
set wireless.iot_ap.disabled='1'
EOF
uci commit wireless
echo "IoT radio configured on $RADIO (keyless + disabled until inject-secrets.sh runs)"
exit 0

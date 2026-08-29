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

## REGULATORY DOMAIN — read the notes before changing this back.
##
## US rather than RO, empirically: with RO (ETSI) every usable high channel is
## DFS, and DFS does not work on this driver — CAC never completes, hostapd
## falls back to ACS, and you land on a congested low channel. US opens
## UNII-3 (149-165), which is non-DFS and permits 30 dBm.
##
## WHAT YOU GIVE UP: 160 MHz. The only contiguous 160 MHz blocks in 5 GHz are
## 36-64 and 100-128. UNII-3 is 80 MHz wide in total, so 149+ caps at HE80.
## HE160 requires 100-128, which requires DFS, which is the thing that does not
## work. You have traded width for a channel that actually comes up, and given
## DFS is broken here that is the right trade — but it is 80, not 160.
##
## WHAT ELSE CHANGES: US drops 2.4 GHz channels 12 and 13. The IoT radio on 3
## and this one on 9 are both unaffected; anything above 11 would vanish.
##
## Romania is ETSI, and 5725-5850 MHz is not allocated for Wi-Fi under
## EN 301 893. Stating it once because it is a fact about the band, not to
## argue with you — the consequence that actually bites is that you get no
## interference protection there and neither does anyone else.
COUNTRY='US'

## 5 GHz channel and width. Set these to whatever you confirmed working from
##     iw dev phy0-ap0 info
##     iwinfo phy0-ap0 info      # compare Tx-Power to what you asked for
## 149 is the bottom of UNII-3. 'auto' lets ACS choose across the enlarged set,
## which with US regdom will now include the high channels.
CH_5G='129'
## HE160 on 161 works — iw confirms width 160, centre 5815 — but it is very
## probably why you are NOT seeing 700-800 Mbit/s, and 149/HE80 likely will.
##
## A 160 MHz channel centred on 5815 spans 5735-5895 MHz. UNII-3 ends at 5850.
## The top 45 MHz of that block is UNII-4 (5850-5925), which the FCC only opened
## in 2020 and which almost no client radio supports. A client that does not
## know UNII-4 cannot use the full width and negotiates down — so you advertise
## 160 and get 80 or less, with none of the range you gave up to get it.
##
## The corroborating evidence is in your own station table: your fastest links
## are 258 and 286 Mbit/s on the 2.4 GHz radio at 20 MHz (HE-MCS 10/11, NSS 2),
## while the one client on 5 GHz sits at -70 dBm negotiating 20 MHz MCS 7. The
## 5 GHz radio is not carrying your fast clients at all.
##
## ALTERNATIVE, and what I would try for throughput:
##     CH_5G='149'   HTMODE_5G='HE80'
## 149 with 80 MHz centres on 5775 and spans 5735-5815 — entirely inside
## UNII-3, supported by anything that does 5 GHz in the US band. 80 MHz at
## HE-MCS 11 NSS 2 is ~1.2 Gbit/s PHY, which is where 700-800 Mbit/s of real
## TCP comes from. Better range than 160 for the same power, so clients stay on
## 5 GHz instead of sliding to 2.4.
##
## Left at 161/HE160 because it is what you have working. One line to change.
HTMODE_5G='HE160'

## txpower: 30 dBm is 1 W EIRP, the UNII-3 ceiling. On a 4x4 radio the driver
## splits that across chains and applies min(regulatory, hardware, per-chain),
## so `iwinfo` will very likely report less than you asked for — check rather
## than assume.
##
## Worth weighing against your own earlier goal of running lower power in a
## 45 m2 flat: 30 dBm is roughly 20x the 17 dBm you were aiming for. In a small
## space it also desenses the 2.4 GHz radio in the same chassis and makes
## roaming decisions worse, not better. The channel unlock is the win here;
## the power is the part to walk back once it is stable.
TXPOWER_5G='30'

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
		## WPA3 extras you set by hand, carried so a reflash keeps them.
		## They are also the prime suspect for the FT breakage noted below:
		## FT-SAE with extended keys and GCMP-256 is where "Missing required
		## pairwise in pull response" comes from. Harmless with 802.11r off; if
		## you re-enable FT, remove these first and add them back one at a time.
		set wireless.$1.gcmp256='1'
		set wireless.$1.sae_ext_key='1'
		set wireless.$1.doth='1'
		set wireless.$1.ieee80211w='2'
		## 802.11r OFF. FT between your own two VAPs was failing with
		##   FT: Missing required pairwise in pull response
		##   nl80211: kernel reports: key addition failed
		##   handle_assoc_cb: STA ... not found
		## and the client re-associated in a loop every ~30 s. The likely
		## trigger is FT-SAE combined with gcmp256 + sae_ext_key, where the
		## cipher does not survive the R0KH pull.
		##
		## On a single AP, FT only speeds the 2.4<->5 GHz hop on the same box —
		## a few hundred milliseconds, against a roaming loop. usteer steers
		## with 802.11v BSS Transition, which does not need FT at all.
		## Revisit if you add a second AP AND the cipher stack settles.
		set wireless.$1.ieee80211r='0'
		## 802.11k OFF. It is what usteer uses to poll clients with beacon
		## measurement requests, and on a SINGLE AP those reports are useless:
		## neighbour reports exist to tell a client about other APs, and there
		## are none. All they produced was BEACON-REQ-TX-STATUS /
		## BEACON-RESP-RX at daemon.notice every 10 seconds per client,
		## flooding the log.
		##
		## Band steering is unaffected — usteer steers with 802.11v BSS
		## Transition Management, which stays on below. Turn this back on if
		## you ever add a second AP, where the neighbour reports start earning
		## their airtime.
		set wireless.$1.ieee80211k='0'
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
		set wireless.${R5G}.band='5g'
		## Channel 100 instead of auto. In ETSI, 100-140 are DFS and hostapd's
		## ACS will not consider them, which is why your acs_chan_bias was
		## ignored and you never saw anything above 64. Naming one explicitly
		## with doth='1' forces a CAC instead.
		##
		## Expect no beacon for 60 s while the radar scan runs (600 s if you
		## ever pick 120-128 — weather radar). Watch it with:
		##     logread -e DFS
		## If CAC never completes, ath11k radar detection is not working on
		## this build; fall back to channel 'auto', which will land on 36-48.
		##
		## This is also the only way to get a real HE160: the sole clean
		## 160 MHz block in ETSI is 100-128, all of it DFS. On 'auto' you were
		## silently getting 80 MHz.
		set wireless.${R5G}.channel='${CH_5G}'
		set wireless.${R5G}.htmode='${HTMODE_5G}'
		set wireless.${R5G}.txpower='${TXPOWER_5G}'
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
		set wireless.${R24}.band='2g'
		## Channel 9, 40 MHz. This radio is the performance one — it is where
		## the MEDIA AP would land — so it gets the wide channel and the IoT
		## radio gets the narrow one.
		##
		## Control channel 9 is inside 1-11, so a US-market client that cannot
		## scan above 11 still associates here at 20 MHz. Only the 40 MHz
		## extension reaches into ETSI-only territory, and only for clients
		## that can use it. That is why 9 rather than 11, 12 or 13.
		##
		## VERIFY THE SECONDARY AFTER FIRST BOOT. hostapd chooses HT40+ or
		## HT40-, and that decides whether this radio occupies 9-13 (centre
		## 2462) or 5-9 (centre 2442). Only the first is clean against the IoT
		## radio on channel 3:
		##     iw dev phy1-ap0 info | grep -E 'channel|center'
		## center1 2462 -> HT40+, correct, nothing to do.
		## center1 2442 -> HT40-, it has taken 5-9 and overlaps channel 3.
		##                 Move the IoT radio to 1, or set htmode HE20 here.
		##
		## Band budget for when MEDIA arrives: 2.4 GHz gives ~83 MHz total, so
		## one 40 MHz block plus one 20 MHz block plus guard is all that fits.
		## A third network in this band has to share one of them.
		## Channel 11 with HE40 -> HT40- -> occupies 7-11, centre channel 9 (2452),
		## spanning 2432-2472. Clear of the IoT radio's 20 MHz on channel 1.
		## US regdom removed 12-13, so HT40+ is not available up here anyway.
		set wireless.${R24}.channel='11'
		set wireless.${R24}.htmode='HE40'
		set wireless.${R24}.txpower='20'
		set wireless.${R24}.distance='15'
		set wireless.${R24}.beacon_int='100'
		set wireless.${R24}.cell_density='0'
		set wireless.${R24}.he_bss_color='16'
		set wireless.${R24}.he_su_beamformer='1'
		set wireless.${R24}.he_su_beamformee='0'
		set wireless.${R24}.he_mu_beamformer='1'
		## REQUIRED for the 40 MHz to actually stick. Without it hostapd runs
		## the 20/40 coexistence scan, finds neighbours in the secondary
		## channel range — guaranteed in an apartment — and silently falls back
		## to 20 MHz. iwinfo will keep reporting HE40 while iw reports
		## width: 20 MHz, which is how this hid.
		##
		## Be clear about what this is: deliberately ignoring the coexistence
		## rule. It takes 40 MHz whether or not the neighbours are using it, and
		## degrades them accordingly. Defensible for one radio in a flat where
		## you have measured the band; not something to enable everywhere.
		set wireless.${R24}.noscan='1'
		delete wireless.${R24}.acs_chan_bias
EOF
		## NO guest/private VAPs on 2.4 GHz — deliberately.
		##
		## With one SSID across both bands, clients pick by RSSI and 2.4 GHz
		## wins at close range (-41 dBm vs -58). usteer can only ASK them to
		## move: assoc_steering refuses the first association, after which the
		## only lever is a BSS Transition Management request — and the logs show
		## clients declining it (BSS-TM-RESP status_code=7). That argument is
		## not winnable by steering, only by removing the choice.
		##
		## So private and guest are 5 GHz only.
		##
		## THE RISK IS GUEST: a visitor with an older phone, or any 2.4-only
		## device someone brings, now has no network. If that bites, re-add a
		## guest_24 VAP here or hand out the IoT SSID.
		##
		## This radio is now free for MEDIA — 2x2 at 40 MHz on channel 11, much
		## better for two TVs than the 1x1 ath10k. That needs a bridge, subnet,
		## firewall zone and pbr policy, so it is a separate change; the radio
		## stays configured and idle until then.
fi

uci commit wireless
echo "ath11k done"; uci show wireless | grep -E '\.(path|band|channel)='
exit 0

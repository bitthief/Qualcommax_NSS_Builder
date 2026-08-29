# AX3600 — NSS/EDMA rebuild

Working notes for the Xiaomi AX3600 (IPQ8071A) running OpenWrt with NSS
acceleration, rebuilt from a 2023-era kernel 6.1 tree onto the current
`openwrt-nss-edma` / `Qualcommax_NSS_Builder` stack.

Written mid-project. Some of it is settled, some is open, and a few entries
exist specifically because the same bug has bitten more than once.

---

## Layout

```
Qualcommax_Build/            working directory, disposable
├── openwrt/                 upstream tree, RESET on every build
├── builder/                 your Qualcommax_NSS_Builder fork  <- source of truth
├── build-local.sh           the only entry point
├── extract-secrets.sh       backup  -> secrets.env
├── inject-secrets.sh        secrets.env -> running router
└── secrets.env              NEVER commit; belongs on the BitLocker stick
```

Config lives in `builder/devices/xiaomi_ax3600/files.edma-nss/`. Everything
else is generated.

```sh
./build-local.sh              # no env vars needed
CLEAN=1 ./build-local.sh      # only when the toolchain is suspect
```

---

## Base

| | |
|---|---|
| Upstream | `JuliusBairaktaris/openwrt-nss-edma`, branch `nss-edma-rework` |
| Builder | fork of `JuliusBairaktaris/Qualcommax_NSS_Builder` |
| Kernel | 6.18.x |
| Datapath | upstream `qca_edma` / `qca_ppe` + NSS firmware 12.5 |
| Variant | `edma-nss` |

**Why this base rather than qosmio's.** Both descend from the same NSS
lineage. qosmio's uses the vendor `qca-nss-dp` + `qca-ssdk` pair and is pinned
to a release branch; the EDMA fork attaches the NSS firmware data plane to
*mainline* ethernet drivers, which collapses the maintenance surface. The
decisive difference was VLAN: the vendor stack cannot combine bridge VLAN
filtering with NSS Wi-Fi offload, the EDMA stack can. That turned out not to
matter — the topology uses one physical port per zone — but the smaller
out-of-tree surface still justifies it.

**Cost of that choice:** a narrower tunnel-offload matrix. L2TPv2, PPTP,
bonding-in-bridge and OVS are compiled out. Plain PPPoE offload works.

---

## Network

Four zones, one physical port each, guest wireless-only:

| Zone | Subnet | IPv6 | Port | Tunnel |
|---|---|---|---|---|
| PRIVATE | 192.168.37.0/24 | `fdb6:747a:d337:2::/64` | lan2 | wg0 |
| SVC | 192.168.137.0/24 | `…:3::/64` | lan1 | wg1 |
| IOT | 192.168.32.0/24 | `…:1::/64` | lan3 | wg3 |
| GUEST | 192.168.33.0/24 | `…:0::/64` | wifi | wg2 |

**Fail-closed is structural, not a routing accident.** No LAN zone forwards to
`wan`; only `wireguard → wan` does, carrying encapsulated traffic. A tunnel
dropping cannot leak even if pbr misfires — the firewall stops it regardless.
Three layers, innermost first: `force_link '1'` keeps the wg interface and its
route present when the tunnel drops; pbr `strict_enforcement '1'`; and the
absent forwarding.

`ip6hint` pins the /64s to 0/1/2/3. Without it netifd assigns them in
allocation order and a clean flash can shuffle them, silently breaking every
IPv6 pbr rule while IPv4 keeps working.

### WireGuard

MTU 1320. **Endpoints must be UDP 443** — Digi/RCS-RDS filters 51820. Nothing
offloads WireGuard: the NSS crypto engine does AES/3DES/SHA, not
ChaCha20-Poly1305, so all tunnel traffic is CPU-bound. Measured ~350 Mbit/s per
tunnel, which is roughly 2× the pre-rebuild figure.

`wg-failover` (cron, `*/2`) rotates the peer when a handshake goes stale and
ranks candidates by RTT hourly. Multiple peers on one interface does *not*
fail over — with `0.0.0.0/0` allowed-ips the last loaded wins — so the peer is
rewritten in place. Candidates in `/etc/wg-failover/<iface>.peers` as
`pubkey|host|port|desc`; each Proton server has its own key, so a candidate is
a (key, endpoint) pair.

---

## Services

- **DNS** hijacked to Pi-hole at 192.168.137.2 / `…:3:ba27:ebff:fe6e:5aeb`
  (SLAAC, stable while the NIC is). DoT/DoQ dropped, DoH blocked via an nft set
  that dnsmasq populates from `nftset=` directives, refreshed from
  dibdot/DoH-IP-blocklists on `ifup wan`.
- **NTP** hijacked to chrony on the router, NTS to three operators
  (Cloudflare, Netnod, PTB), `minsources 2`. **See open issues.**
- **mDNS** reflected by avahi across svc/iot/guest/private; never wan or the
  tunnels. avahi's reflector is load-bearing — every `Allow-mDNS-*` firewall
  rule depends on it.
- **SQM** on `wan` only via `nss-edma.qos` (`nsstbl` + `nssfq_codel` +
  `nssifb`). Shaping the physical bottleneck covers all four tunnels; shaping
  per-tunnel would shape plaintext and leave the real queue unmanaged.
- **Hardening**: odhcpd (uid 455) and pppd jailed via procd-ujail; uhttpd
  optionally. `procd-ujail` must be installed or every jail is silently inert.

---

## Open issues

### 1. `dhcpv4 'server'` is load-bearing and unexplained

Without `option dhcpv4 'server'` on the zone sections, **no DHCPv4 on any
bridge** — Wi-Fi clients associate and stall forever without a lease. With it,
immediate and reliable. Reproduced across builds and across years.

What makes it strange: `logread` shows every DHCPACK coming from **dnsmasq**
and nothing from odhcpd. So the flag changes something that makes dnsmasq work,
and the mechanism is unknown.

Bisection, one variable at a time:

1. **force_link** — add `option force_link '1'` to the four bridge
   *interfaces*, remove `dhcpv4`, retest. Leading hypothesis: these bridges
   have no carrier until a client associates, and dnsmasq with `bind-dynamic`
   (`nonwildcard '1'`) will not bind DHCP to an interface in that state.
2. **bind-dynamic** — remove `nonwildcard '1'` and the four `list interface`
   lines, retest.
3. **drop_invalid** — set to `'0'` and retest. A DHCP DISCOVER from 0.0.0.0 is
   exactly what conntrack calls INVALID.
4. **Observe directly**: `ss -ulpn | grep :67` and
   `logread -e dnsmasq | grep -i 'DHCP.*range'`, with and without the flag.
   That comparison settles it.

If dnsmasq is not holding a socket on the bridges without the flag, that is a
genuine OpenWrt bug and worth reporting.

### 2. air-Q clocks jumping to 2063 after the NTP hijack

Both air-Q sensors report 26.11.2063 and fail MQTT to AWS. The hijack points
them at chrony instead of their own server and something in that exchange
breaks their SNTP client.

Immediate mitigation:

```sh
nft insert rule inet fw4 ntphijack ip saddr { 192.168.32.210, <second> } return
```

Diagnose with `chronyc tracking` (leap status), `chronyc clients`, and
`tcpdump -ni br-iot -vv 'udp port 123 and host <air-q>'`. Most likely chrony
replying while unsynchronised — no RTC on this board, and NTS-KE needs working
TLS which needs roughly-correct time.

**Broader point:** hijacking NTP is riskier than hijacking DNS. A DNS client
that gets a bad answer retries or fails visibly; an SNTP client that mishandles
a reply sets its clock and carries on. Consider scoping the hijack to
PRIVATE/SVC/GUEST and leaving IOT alone.

### 3. DFS does not work; high channels reached via regdom US instead — RESOLVED

Under RO (ETSI) every usable high 5 GHz channel is DFS, CAC never completes on
this driver, and hostapd falls back to ACS on a congested low channel.

Workaround in use: `country US`, which opens UNII-3 (149-165) — non-DFS and
30 dBm. The cost is width: the only contiguous 160 MHz blocks are 36-64 and
100-128, so UNII-3 caps at HE80. HE160 needs 100-128, needs DFS, which is the
broken thing.

Note 5725-5850 MHz is not an ETSI Wi-Fi allocation, so there is no interference
protection in either direction. US regdom also removes 2.4 GHz channels 12-13;
the radios sit on 3 and 9, so nothing breaks.

Underlying DFS bug is unfixed. Worth revisiting if ath11k's radar detection on
IPQ8074 improves, since 100-128 at HE160 is the actual prize.

### 4. Channels not honouring explicit settings

Both 2.4 GHz radios pick their own. Related to the above — when hostapd rejects
a channel on regulatory grounds it falls back to ACS rather than failing.

### 5. High noise floor

Router sits on a wardrobe by the entrance. Placement, not config.

---

## Traps worth remembering

**`prepare-build.sh` rsyncs without `--delete`.** A file removed from the
builder overlay is never removed from `openwrt/files/` and ships forever.
`98-wireless.sh` survived being split into `-ath10k`/`-ath11k`, sorted *after*
both (`98-wireless.` > `98-wireless-`), ran last, and wiped everything they
built. `build-local.sh` now clears the directory first.

**UCI aborts an entire file on one malformed line.** It does not skip the bad
section. A mangled comment in `/etc/config/dhcp` made the whole file
unreadable — dnsmasq started with no config, LuCI hid the DHCP menu because it
could not read it, and the error surfaced in an unrelated log. One bad
character disables every service that reads that file.

**`ListenAddress` in sshd is fatal if unbindable.** Using it to emulate
dropbear's `Interface 'private'` made every boot a race: if br-private was not
up when sshd started, sshd exited and procd respawned it forever. Access is
restricted by zone input policy instead, which cannot crash-loop.

**Two patch directories, one source tree.** `mac80211` applies
`patches/ath11k/` always and `patches/nss/ath11k/` additionally when
`ATH11K_NSS_SUPPORT` is set. Distinct file paths are not evidence of safety —
`fa5c4dd` added a patch the NSS tree already carried under a different name,
and mac80211 failed to build.

**The device config wins.** `devices/<device>/config` is concatenated after
`devices/common/config` and kconfig takes the last value. ath10k was disabled
upstream in the device file; enabling it in the common file did nothing. And
`prepare-build.sh`'s verification filters `=n` lines, so an explicitly disabled
symbol can never be reported as dropped.

**Toggling ccache rewrites `CC` for every package**, and any autoconf
`config.cache` from the previous run refuses to continue. `make clean` (not
`distclean`). `build-local.sh` detects the toggle and does it automatically.

**Emergency shell without SSH:** LuCI → System → Scheduled Tasks is an editable
root crontab. Remember to remove the entry afterwards — `/etc/crontabs` is in
the default `keep.d` and survives sysupgrade.

---

## Hardware facts

- **IPQ8071A is the 1.4 GHz SKU.** `1017600 1382400` is the whole OPP list for
  this die. The 1651–2208 MHz operating points are gated behind
  `opp-supported-hw = <0x1>` and belong to IPQ8074/8072A parts. There is no
  unlock. The performance governor pins 1382400 instead of idling at 1017600.
- **Three radios**: two ath11k (5 GHz, 2.4 GHz) which get wifili offload, and a
  PCIe QCA9887/9889 1×1 IoT radio which does not. The QCA9887 is dual-band and
  `wifi config` detects it as `5g` — `band='2g'` must be set explicitly or
  channel 1 lands on a 5 GHz radio and hostapd never starts.
- No RTC. Cold-boot time comes from `sysfixtime` reading the newest mtime in
  `/etc`, which is why NTS bootstrap needs `nocerttimecheck`.
- Single partition, 220 MB rootfs, 36 MB kernel. `platform_do_upgrade` sets
  `flag_try_sys{1,2}_failed 8`, so there is **no A/B fallback**. Rollback is a
  sysupgrade to stock OpenWrt 25.12, never the bootloader.

---

## Deferred

- AmneziaWG (needs an extra feed)
- sysctl review — wants `sysctl -a` from the running box, not the files
- Pi-hole optimisation / UDOO BOLT swap
- End-to-end benchmarking
- Seccomp profiles — `umdns` is the only package in the tree that ships one,
  and it is not installed. `procd-seccomp` is on for `utrace`/`seccomp-trace`
  so profiles can be generated; none are enforced today.

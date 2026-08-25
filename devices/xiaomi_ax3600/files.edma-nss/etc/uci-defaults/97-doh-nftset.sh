#!/bin/sh
# Generate dnsmasq nftset= lines from /etc/doh-domains.txt.
# Runs at first boot and re-runs after any firstboot, since it ships in the
# squashfs. To add domains later: edit /etc/doh-domains.txt then run
#   sh /rom/etc/uci-defaults/97-doh-nftset.sh && /etc/init.d/dnsmasq restart

SRC=/etc/doh-domains.txt
OUT=/etc/dnsmasq.d/10-doh-nftset.conf

[ -f "$SRC" ] || exit 0

# Keep the header, regenerate the block below it
sed -i '/## (generated block starts)/,$d' "$OUT" 2>/dev/null
echo '## (generated block starts)' >> "$OUT"

grep -vE '^\s*#|^\s*$' "$SRC" | while read -r d; do
	printf 'nftset=/%s/4#inet#fw4#doh\n' "$d"
	printf 'nftset=/%s/6#inet#fw4#doh6\n' "$d"
done >> "$OUT"

exit 0

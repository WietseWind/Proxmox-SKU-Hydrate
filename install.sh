#!/bin/sh
# Install pve-sku-hydrate on ONE Proxmox VE node (it covers the whole cluster through pvesh).
#   sh install.sh              install / update (keeps an existing /etc/default/pve-sku-hydrate)
#   MINUTE=42 sh install.sh    run at minute 42 of every hour (default 17)
#   EXCLUDE_TAGS='billing-* internal-*' sh install.sh
#                              leave tags matching these glob patterns out (written into the cron line)
#   sh install.sh --uninstall  remove the script, cron job and logrotate entry
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
command -v pvesh >/dev/null 2>&1 || { echo "pvesh not found: run this on a Proxmox VE node"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found"; exit 1; }
DIR=$(cd "$(dirname "$0")" && pwd)
MINUTE=${MINUTE:-17}
EXCLUDE_TAGS=${EXCLUDE_TAGS:-}
case "$EXCLUDE_TAGS" in *\'*|*%*) echo "EXCLUDE_TAGS may not contain ' or %"; exit 1;; esac
ARGS=""; [ -n "$EXCLUDE_TAGS" ] && ARGS=" --exclude-tags '$EXCLUDE_TAGS'"

if [ "${1:-}" = "--uninstall" ]; then
  rm -f /usr/local/sbin/pve-sku-hydrate /etc/cron.d/pve-sku-hydrate /etc/logrotate.d/pve-sku-hydrate
  echo "Removed. Kept: /etc/default/pve-sku-hydrate, /var/lib/pve-sku-hydrate, the SMBIOS values in the VM configs"
  echo "and the files inside guests (see the README to remove those)."
  exit 0
fi

install -m 755 "$DIR/pve-sku-hydrate" /usr/local/sbin/pve-sku-hydrate
[ -f /etc/default/pve-sku-hydrate ] || install -m 644 "$DIR/pve-sku-hydrate.conf.example" /etc/default/pve-sku-hydrate

cat > /etc/cron.d/pve-sku-hydrate <<CRON
# pve-sku-hydrate: Proxmox VM name / ID / tags -> SMBIOS type1 of every VM (+ guest copy). Hourly; writes only changes.
# Install on ONE node of the cluster only.
$MINUTE * * * * root /usr/local/sbin/pve-sku-hydrate$ARGS >> /var/log/pve-sku-hydrate.log 2>&1
CRON

cat > /etc/logrotate.d/pve-sku-hydrate <<'ROT'
/var/log/pve-sku-hydrate.log {
    monthly
    rotate 12
    compress
    missingok
    notifempty
}
ROT

echo "Installed: /usr/local/sbin/pve-sku-hydrate, cron at minute $MINUTE of every hour${ARGS:+ with$ARGS}, config /etc/default/pve-sku-hydrate"
echo
echo "Dry run (nothing is changed):"
eval "/usr/local/sbin/pve-sku-hydrate --dry$ARGS" | tail -n 15
echo
echo "Next steps:"
echo "  1. Back up the VM configs:   cp -a /etc/pve/nodes /root/pve-nodes-backup-\$(date +%F)"
echo "  2. Try one VM:               /usr/local/sbin/pve-sku-hydrate --vmid <id>"
echo "  3. Check in that guest:      cat /sys/class/dmi/id/product_sku /sys/class/dmi/id/product_family"
echo "  4. The hourly cron job does the rest (or run /usr/local/sbin/pve-sku-hydrate now)."

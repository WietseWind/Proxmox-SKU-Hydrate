# Proxmox-SKU-Hydrate

Give every Proxmox VM its own Proxmox identity — **VM name, VM ID and tags** — so the guest operating system (and every
tool running in it) can tell which Proxmox VM it is.

`pve-sku-hydrate` runs hourly on **one** Proxmox VE node and writes, for every VM in the cluster, the VM's name, ID and
tags into the VM's **SMBIOS type1** fields (the same fields you see in *VM → Options → SMBIOS settings (type1)*):

| SMBIOS type1 field | Value                    | Inside a Linux guest                                  |
|--------------------|--------------------------|-------------------------------------------------------|
| `sku`              | VM name                  | `/sys/class/dmi/id/product_sku`                       |
| `serial`           | VM ID                    | `/sys/class/dmi/id/product_serial` (readable by root) |
| `family`           | tags, comma separated    | `/sys/class/dmi/id/product_family`                    |

Example, for VM `101` named `web-01` with the tags `prod;web`:

```console
$ cat /sys/class/dmi/id/product_sku /sys/class/dmi/id/product_family
web-01
prod,web
$ sudo cat /sys/class/dmi/id/product_serial
101
```

## Why

Inside a VM there is normally no way to know the Proxmox side of things: the guest agent only lets the host talk to the
guest, not the other way around, and handing out Proxmox API credentials to guests is a bad idea. SMBIOS is the
classic, read-only way for a hypervisor to tell a guest what it is — and Proxmox already lets you set the fields. This
project simply keeps those fields filled in, automatically, for the whole cluster.

The guest can **read** these values but **not change** them (they come from the virtual firmware). That makes them a
trustworthy label, unlike a file inside the guest.

## What you can use it for

- **Monitoring, alerting and SIEM** — attach the Proxmox VM name, ID and tags to every alert from an agent in the guest
  (Wazuh, Zabbix, Datadog, ...), so an alert says *which* VM it is and *what kind* of VM it is (e.g. "customer",
  "prod", "lab"), and rules can treat VM groups differently based on their tags.
- **Prometheus** — `node_exporter`'s DMI collector exports `product_sku` / `product_family` as labels of
  `node_dmi_info`, so you can join metrics to Proxmox VM names and tags.
- **Configuration management** — Ansible facts (`ansible_product_serial`, ...), Puppet/Salt facts and cloud-init can read
  DMI: target playbooks by Proxmox tag, or verify that a host is the VM you think it is.
- **Inventory / CMDB** — collect VM ID + name + tags from inside guests without access to the Proxmox API.
- **Ownership and support** — a quick `cat /sys/class/dmi/id/product_*` on a box tells an operator which Proxmox VM
  (and so which backups, firewall rules and host) it is.

## How it works

1. Lists all VMs of the cluster with `pvesh` (so a new node or a new VM is picked up automatically).
2. For every VM it builds the wanted SMBIOS values and compares them with the VM's config (including pending changes).
   Only a VM whose values differ is written.
3. **Running VMs:** SMBIOS changes are *pending* until Proxmox starts the VM again (stop/start, or *Reboot* from
   Proxmox). A reboot from inside the guest does not apply them.
4. To make the values usable right away, **Linux VMs with a running QEMU guest agent** also get, through the agent and
   only when the values change:
   - `META_FILE` (`/etc/pve-sku/meta`): `PVE_VMID=`, `PVE_NAME=`, `PVE_TAGS=` lines — easy to source or to ship with a
     log/agent collector;
   - `DMI_SCRIPT_FILE` (`/etc/pve-sku/dmi.sh`): bind-mounts small files with the new values over
     `/sys/class/dmi/id/product_{sku,serial,family}` (sysfs itself is read-only). It does nothing once the real DMI
     values match, so after the next start from Proxmox nothing is mounted any more;
   - `CRON_FILE` (`/etc/cron.d/pve-sku-dmi`): runs the script `@reboot`, which covers a reboot from inside the guest.

   `dmidecode` reads the raw firmware table and shows the new values only after the next VM start.

Other details:

- **base64:** Proxmox only accepts base64 characters in *plain* smbios1 values (a `.` `-` space or comma is rejected),
  so the values are written with `base64=1`. The guest — and the Proxmox UI — show the decoded text.
- **Kept as is:** the VM's `uuid` (its hardware ID; licences and some software depend on it) and any other smbios1 field.
- **Not touched:** Windows VMs (changing SMBIOS can trigger Windows re-activation), templates, and containers (LXC has
  no SMBIOS).
- **Tags you don't want in guests** (pricing, internal notes, ...) can be left out with `--exclude-tags` (cron line) or
  `EXCLUDE_TAGS` (config file).
- 8 VMs are handled in parallel; a cluster of ~100 VMs takes a few minutes the first time and much less afterwards.

## Requirements

- Proxmox VE 7 or 8 (uses `pvesh` and the guest agent API), `python3` (present on Proxmox VE).
- For the in-guest part: the `qemu-guest-agent` package installed and running in the guest, and *VM → Options → QEMU
  Guest Agent* enabled. Without it the VM still gets the SMBIOS values (from its next start).

## Install

On **one** node of the cluster, as root:

```sh
git clone https://github.com/WietseWind/Proxmox-SKU-Hydrate.git
cd Proxmox-SKU-Hydrate
sh install.sh                 # or: MINUTE=42 EXCLUDE_TAGS='billing-* internal-*' sh install.sh
```

The installer copies the script to `/usr/local/sbin/pve-sku-hydrate`, creates `/etc/default/pve-sku-hydrate` (only if
it does not exist), installs an hourly cron job (`/etc/cron.d/pve-sku-hydrate`, minute 17 by default) and a logrotate
entry, and shows a dry run. `EXCLUDE_TAGS` given to the installer is written into the cron line as
`--exclude-tags '...'`. Then:

```sh
cp -a /etc/pve/nodes /root/pve-nodes-backup-$(date +%F)   # back up the VM configs first
pve-sku-hydrate --vmid 101                                   # try one VM
pve-sku-hydrate                                              # or wait for the cron job
```

Install it on one node only: every node sees the whole cluster. If that node is down, the job simply resumes when it
is back.

## Usage

```text
pve-sku-hydrate [--dry] [--vmid N] [--exclude-tags 'PATTERN ...'] [--config FILE]
  --dry                 show what would change; change nothing
  --vmid N              only this VM
  --exclude-tags '...'  leave tags matching these glob patterns out, e.g. 'billing-* internal-*'
                        (overrides EXCLUDE_TAGS from the config file)
  --config FILE         another config file (default /etc/default/pve-sku-hydrate)
```

Log: `/var/log/pve-sku-hydrate.log`. State (what was last written into each guest): `/var/lib/pve-sku-hydrate/`.

## Configuration

`/etc/default/pve-sku-hydrate`, all keys optional (see `pve-sku-hydrate.conf.example`):

| Key                 | Default                       | Meaning                                                      |
|---------------------|-------------------------------|--------------------------------------------------------------|
| `META_FILE`         | `/etc/pve-sku/meta`           | identity file inside the guest                               |
| `DMI_SCRIPT_FILE`   | `/etc/pve-sku/dmi.sh`         | script that shows the values in `/sys/class/dmi/id` now     |
| `CRON_FILE`         | `/etc/cron.d/pve-sku-dmi`     | runs that script `@reboot`                                   |
| `EXCLUDE_TAGS`      | *(empty)*                     | space separated glob patterns of tags to leave out           |
| `SKIP_OSTYPE_REGEX` | `^(win\|w2k\|wxp\|wvista)`    | VMs with a matching ostype are not touched                   |
| `IN_GUEST`          | `1`                           | `0` = only set SMBIOS, never write inside guests             |
| `WORKERS`           | `8`                           | VMs handled in parallel                                      |
| `STATE_FILE`        | `/var/lib/pve-sku-hydrate/state.json` | last written guest content per VM                    |

## Security notes

- Everything you put in a VM's name or tags becomes visible to root inside that VM. Use `EXCLUDE_TAGS` for internal
  tags.
- The in-guest files can be changed by root in the guest; the DMI values cannot. Trust DMI for anything that matters.
- The script runs as root on the Proxmox node and writes into guests through the guest agent (`file-write` / `exec`),
  like `qm guest exec` does.
- If a security tool (file integrity monitoring) watches `/etc` in your guests, exclude `META_FILE`,
  `DMI_SCRIPT_FILE` and `CRON_FILE`, or expect one "file changed" event per guest when values change.

## FAQ

**Does it change the VM's UUID?** No. The UUID is kept exactly as it is.

**Does a VM need to be restarted?** Not for the guest view (Linux guests with the guest agent get it right away). The
real SMBIOS values become active at the next start from Proxmox; until then they show as pending (orange) in the UI.

**Windows guests?** Skipped completely. You can still set the SMBIOS fields by hand in the UI if you want.

**How do I remove it?** `sh install.sh --uninstall` removes the script, cron job and logrotate entry. The SMBIOS values
stay in the VM configs (clear them in *Options → SMBIOS settings*), and the guest files stay in the guests (remove
`META_FILE`, `DMI_SCRIPT_FILE` and `CRON_FILE`; the bind mounts disappear at the next guest reboot).

## License

MIT, see [LICENSE](LICENSE).

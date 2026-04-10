# Arch Linux — UEFI / GRUB / BTRFS / Snapper

Scripted Arch Linux installation with BTRFS snapshots and manual rollback capability.
Designed for a laptop with hibernation support, and structured so LUKS encryption
can be added later with minimal changes.

## Stack

```
UEFI → GRUB → BTRFS (flat subvolume layout)
               swap partition (hibernation-capable)
```

## Scripts

| Script | Run from | Purpose |
|--------|----------|---------|
| `1-install.sh` | Live ISO | Partition, format, create subvolumes, pacstrap, generate fstab |
| `2-configure.sh` | `arch-chroot` | Locale, users, mkinitcpio, GRUB, services |
| `3-post_boot_config.sh` | First boot | Snapper configuration, timers *(planned)* |

### Usage

```bash
# From the Arch live ISO:
bash 1-install.sh

# Then:
arch-chroot /mnt
bash /root/2-configure.sh

# Exit chroot, unmount, reboot:
exit
umount -R /mnt
swapoff -a
reboot
```

## Disk Layout

```
/dev/nvme0n1
├── p1  ESP       512 MiB   FAT32    /boot/efi
├── p2  swap       48 GiB   swap     (hibernation — must be >= RAM)
└── p3  root      remainder BTRFS    /
```

## BTRFS Subvolume Layout

Flat layout — all subvolumes are direct children of the BTRFS top-level (ID 5).
None are nested inside each other.

```
top-level (ID 5)          mounted at /btrfs (for rollback access)
├── @                  →  /
├── @home              →  /home
├── @snapshots         →  /.snapshots
├── @log               →  /var/log
├── @cache             →  /var/cache
└── @tmp               →  /var/tmp
```

**Why this layout?**

- `@` is the root filesystem. Snapper snapshots target this subvolume.
- `@home`, `@log`, `@cache`, `@tmp` are separate so they are **not** included
  in root snapshots. A rollback restores the OS state without touching user data,
  logs, or caches.
- `@snapshots` holds snapper's snapshot data at `/.snapshots`.
- The top-level (ID 5) is mounted at `/btrfs` to enable the rollback workflow
  described below. This is not a BTRFS requirement — it is a deliberate design
  choice for administration convenience.

**Mount options:** `rw,noatime,compress-force=zstd:1,space_cache=v2`

- `noatime` — skip access-time updates; on BTRFS with CoW, every read would
  otherwise trigger a write
- `compress-force=zstd:1` — compress all data; level 1 is fast with good ratio
- `space_cache=v2` — modern free-space tracking

## Boot Chain

```
UEFI reads ESP (FAT32)
  → loads grubx64.efi
GRUB reads grub.cfg from BTRFS (GRUB has its own BTRFS driver)
  → loads kernel + initramfs from /boot (inside subvol @)
Kernel mounts BTRFS subvol=@ as /
  → systemd takes over, mounts remaining subvolumes per fstab
```

The kernel command line includes `rootflags=subvol=@`, so the kernel always
mounts whatever subvolume is named `@` as root. This is the foundation of the
rollback strategy.

## Initramfs (mkinitcpio)

Systemd-based hooks, chosen for clean compatibility with `sd-encrypt` when
LUKS is added later.

```
MODULES=(btrfs)
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck)
```

Hook-by-hook:

| Hook | Purpose |
|------|---------|
| `base` | Directory skeleton (`/dev`, `/proc`, `/sys`), minimal utilities |
| `systemd` | systemd as PID 1 in initramfs, enables `sd-*` hooks |
| `autodetect` | Filters module list to only what this hardware needs |
| `microcode` | Intel CPU microcode, applied as early as possible |
| `modconf` | Includes `/etc/modprobe.d/` options |
| `kms` | Early kernel mode setting for GPU |
| `keyboard` | USB/HID input drivers |
| `sd-vconsole` | Applies keymap in initramfs |
| `block` | NVMe/SATA block device drivers |
| `filesystems` | BTRFS module and others |
| `fsck` | Filesystem check tools |

**LUKS extension:** insert `sd-encrypt` between `block` and `filesystems`.

## Snapshots and Rollback

### How Snapshots Work

[Snapper](https://wiki.archlinux.org/title/Snapper) creates read-only snapshots
of the `@` subvolume. With `snap-pac` installed, snapper automatically creates
pre/post snapshot pairs around every `pacman` transaction.

Snapshots live under `@snapshots/` (mounted at `/.snapshots/`):

```
@snapshots/
├── 1/
│   ├── info.xml        ← snapper metadata (timestamp, description, type)
│   └── snapshot/       ← read-only BTRFS snapshot of @
├── 2/
│   ├── info.xml
│   └── snapshot/
└── ...
```

`grub-btrfs` detects these snapshots and adds boot entries to the GRUB menu.
The `grub-btrfsd` service watches `/.snapshots` and regenerates `grub.cfg`
automatically whenever snapshots are created or deleted.

### What a Rollback Does (and Does Not Do)

A rollback **restores `@`** — the root filesystem. This includes installed
packages, system configuration in `/etc`, binaries in `/usr`, and everything
else that lives on `/`.

A rollback **does not touch:**

- `/home` (`@home`) — user data, dotfiles, application state
- `/var/log` (`@log`) — system logs
- `/var/cache` (`@cache`) — package cache
- `/var/tmp` (`@tmp`) — temporary files

This is usually exactly what you want: you're reverting a bad package update
or broken config, not your documents or browser history.

### Rollback Design

The rollback strategy is **rename-based with snapshot copy**:

- `fstab` hardcodes `subvol=@` for the root entry.
- The kernel command line includes `rootflags=subvol=@`.
- The name `@` always points to the active root subvolume.
- Rolling back means making a chosen snapshot the new `@`.

The top-level BTRFS volume (ID 5) is mounted at `/btrfs`, giving access to
all subvolumes as siblings. This is where the rename operations happen.

**Important:** snapshots are *copied* (via `btrfs subvolume snapshot`), never
*moved*. Moving a snapshot out of `@snapshots/` would break snapper's metadata.
Copying creates a new read-write subvolume while leaving the original snapshot
untouched.

### Primary Rollback — From the Running (Broken) System

This covers the common case: a `pacman -Syu` broke something, but the system
still boots and you can log in (even if the desktop environment is broken,
a TTY is enough).

```bash
# 1. Identify which snapshot to restore
snapper list

# Example output:
#  # | Type   | Pre # | Date                     | Description
# ---+--------+-------+--------------------------+---------------------------
#  1 | single |       | Fri 10 Apr 2026 10:00:00 | timeline
#  2 | pre    |       | Fri 10 Apr 2026 14:00:00 | pacman -Syu
#  3 | post   |     2 | Fri 10 Apr 2026 14:01:00 | pacman -Syu

# 2. Copy the chosen snapshot to a new subvolume
#    (this preserves the original snapshot in @snapshots/)
sudo btrfs subvolume snapshot /btrfs/@snapshots/2/snapshot /btrfs/@new

# 3. Replace the current root
sudo btrfs subvolume delete /btrfs/@
sudo mv /btrfs/@new /btrfs/@

# 4. Reboot into the restored system
sudo reboot
```

After rebooting, the system is running from the restored `@`. The old root
is gone (deleted in step 3). All snapshots remain intact in `@snapshots/`.

**Note on step 3:** `btrfs subvolume delete` is used instead of `mv @ @.broken`
to avoid accumulating old broken roots. If you want to keep the broken root
for inspection, use `mv /btrfs/@ /btrfs/@.broken` instead and delete it later
with `btrfs subvolume delete /btrfs/@.broken`.

### Emergency Rollback — System Won't Boot

If `@` is so broken the system won't boot at all (corrupted kernel, broken
initramfs, etc.), use the initramfs emergency shell.

**Using `rd.break`:**

1. At the GRUB menu, select your normal boot entry
2. Press `e` to edit the entry
3. Append `rd.break` to the `linux` line
4. Press `Ctrl+X` to boot

This drops you into a minimal shell **before** root is mounted. From here:

```bash
# Mount the top-level BTRFS volume
mount -o subvolid=5 /dev/nvme0n1p3 /mnt

# Figure out which snapshot to use
ls /mnt/@snapshots/
cat /mnt/@snapshots/2/info.xml    # check timestamp and description

# Copy the snapshot, replace root
btrfs subvolume snapshot /mnt/@snapshots/2/snapshot /mnt/@new
btrfs subvolume delete /mnt/@
mv /mnt/@new /mnt/@

# Reboot
reboot -f
```

**What is `rd.break`?** It tells the systemd-based initramfs to pause and drop
to an emergency shell before mounting the root filesystem. At this point you
have a working shell and access to block devices, but no root filesystem mounted
yet. This works with both busybox and systemd initramfs styles.

### Why Not `btrfs subvolume set-default`?

An alternative rollback approach used by some setups is `btrfs subvolume set-default`,
which changes which subvolume BTRFS mounts when no `subvol=` option is specified.
This setup deliberately does **not** use that approach because:

- It requires `fstab` to have **no** `subvol=` on the root entry, and no
  `rootflags=subvol=@` in the kernel command line.
- You need to track subvolume IDs (numbers), which is less transparent than
  the name `@` always being root.
- The rename-based approach makes it immediately obvious what the current root
  is: whatever is named `@`.

## LUKS Encryption Extension

Both scripts are structured so LUKS2 encryption can be added with minimal changes.
Sections marked `[LUKS]` in the scripts show exactly where encryption steps
would be inserted.

**Summary of changes needed:**

| Area | Change |
|------|--------|
| Partition type codes | `8200`/`8300` → `8309` (Linux LUKS) |
| After partitioning | Add `cryptsetup luksFormat` + `cryptsetup open` for both partitions |
| Device references | `ROOT_DEV` → `/dev/mapper/cryptroot`, `SWP_DEV` → `/dev/mapper/cryptswap` |
| mkinitcpio hooks | Insert `sd-encrypt` between `block` and `filesystems` |
| Kernel cmdline | Add `rd.luks.name=<UUID>=cryptroot` and `rd.luks.name=<UUID>=cryptswap` |
| GRUB | Set `GRUB_ENABLE_CRYPTODISK=y` |
| pacstrap | Add `cryptsetup` to the package list |

The systemd initramfs hooks (`systemd`, `sd-vconsole`, `sd-encrypt`) were chosen
specifically to make this extension straightforward. `sd-encrypt` handles multiple
LUKS partitions natively via `rd.luks.name=` parameters, which is important for
the encrypted-swap-with-hibernation use case.

## Post-Installation Verification

After first boot, verify the setup:

```bash
# Check mount layout — all subvolumes mounted correctly
findmnt --tree

# Check swap is active (needed for hibernation)
swapon --show

# List subvolumes
sudo btrfs subvolume list /

# Verify snapper is working (after 3-post_boot_config.sh)
snapper list
```

## Key Design Decisions

**Why GRUB over systemd-boot?**
GRUB has a native BTRFS driver and can read kernels directly from a BTRFS
subvolume. This means `/boot` lives inside `@` on BTRFS, so kernel and initramfs
are included in snapshots. With systemd-boot, `/boot` must be on the ESP (FAT32)
and is not snapshotted.

**Why `subvol=@` everywhere instead of relying on the default subvolume?**
Transparency. The name `@` always means "the active root." There is no hidden
state (a subvolume ID) that you need to query to understand what the system
will boot.

**Why systemd initramfs hooks?**
Clean path to LUKS2 encryption with `sd-encrypt`, which handles multiple
encrypted partitions (root + swap for hibernation) natively. Busybox `encrypt`
only supports a single partition.

**Why mount the top-level (ID 5) at `/btrfs`?**
The rollback workflow requires access to all subvolumes as siblings — to rename
and copy them. Mounting ID 5 provides this view. It is not required for normal
BTRFS operation and is purely an administration convenience.

**Why copy snapshots instead of moving them?**
Snapper tracks snapshots by their path under `@snapshots/`. Moving a snapshot
out of that directory breaks snapper's metadata in `info.xml`. Copying (via
`btrfs subvolume snapshot`) creates a new subvolume while leaving the original
untouched, so snapper continues to work correctly.

#!/usr/bin/env bash
# =============================================================================
# 1-install.sh — Arch Linux Installation (run from live ISO, before chroot)
# =============================================================================
#
# Stack:
#   UEFI → GRUB → BTRFS (@, @home, @snapshots, ...)
#          swap partition (hibernation capable)
#
# Boot chain:
#   UEFI reads ESP (FAT32) → loads grubx64.efi
#   GRUB reads grub.cfg from BTRFS (has own BTRFS driver)
#   GRUB loads kernel + initramfs from /boot (on BTRFS @)
#   kernel mounts BTRFS subvol=@ as /
#   rollback strategy → manually renaming desired snapshot to '@'
# 	  all snapshots and @ live as siblings under top-level (ID 5)
# 	  fstab hardcodes subvol=@ for root
#  	  mount subvolid=5 at /btrfs (fstab takes care of that)
#   	  mv @ @.broken
#   	  mv @working_snapshot @
#   	  reboot
#
# NOTE — encryption extension:
#   This script is deliberately structured so LUKS can be added later
#   with minimal changes. Sections marked [LUKS] show exactly where
#   encryption steps would be inserted. Everything else stays identical.
#
# Prerequisites:
#   - Booted into Arch ISO (UEFI mode)
#   - Internet connection active
#   - Target disk identified (lsblk)
#
# Usage:
#   1. Adjust variables below
#   2. Run: bash 1-install.sh
#   3. Then: arch-chroot /mnt bash /root/2-configure.sh
#
# !! WARNING: Destroys all data on target disk !!
# =============================================================================

set -euo pipefail

# =============================================================================
# VARIABLES — review and adjust before running
# =============================================================================

# -- Disk ---------------------------------------------------------------------
DISK="/dev/nvme0n1"           # Target disk — confirm with: lsblk

# Partition numbers
ESP_PART="1"                  # EFI System Partition
SWP_PART="2"                  # Swap partition
ROOT_PART="3"                 # Root (BTRFS) partition

# Derived partition paths (NVMe uses 'p' separator)
ESP_DEV="${DISK}p${ESP_PART}"
SWP_DEV="${DISK}p${SWP_PART}"
ROOT_DEV="${DISK}p${ROOT_PART}"

# -- [LUKS] When adding encryption: ------------------------------------------
# LUKS_ROOT_NAME="cryptroot"
# LUKS_SWP_NAME="cryptswap"
# ROOT_MAPPER="/dev/mapper/${LUKS_ROOT_NAME}"  # replaces ROOT_DEV for BTRFS
# SWP_MAPPER="/dev/mapper/${LUKS_SWP_NAME}"    # replaces SWP_DEV for swap

# -- Sizes --------------------------------------------------------------------
ESP_SIZE="512MiB"            # EFI System Partition
SWP_SIZE="48GiB"             # Swap — must be >= RAM for hibernation
                             # ROOT gets remainder automatically

# -- BTRFS --------------------------------------------------------------------
BTRFS_LABEL="archlinux"
BTRFS_MOUNT_OPTS="rw,noatime,compress-force=zstd:1,space_cache=v2"
# noatime               — skip access time updates on reads
#                         on BTRFS with CoW every read would trigger a write
# compress-force=zstd:1 — compress all data, level 1 (fast, good ratio)
# space_cache=v2        — modern free space tracking, always use v2

# -- System -------------------------------------------------------------------
REFLECTOR_COUNTRY="Germany"

# =============================================================================
# SANITY CHECKS
# =============================================================================

echo "=== Pre-flight checks ==="

if [[ ! -d /sys/firmware/efi/efivars ]]; then
    echo "ERROR: Not booted in UEFI mode. Aborting."
    exit 1
fi
echo "UEFI mode: OK"

if ! ping -c 1 -W 3 archlinux.org &>/dev/null; then
    echo "ERROR: No network connectivity. Aborting."
    exit 1
fi
echo "Network: OK"

if [[ ! -b "${DISK}" ]]; then
    echo "ERROR: Disk ${DISK} not found. Check DISK variable. Aborting."
    exit 1
fi
echo "Target disk: ${DISK}"
echo ""
lsblk "${DISK}"
echo ""

timedatectl set-ntp true

read -rp "!! This will DESTROY all data on ${DISK} !! Type 'yes' to continue: " confirm
[[ "${confirm}" == "yes" ]] || { echo "Aborted."; exit 1; }

# =============================================================================
# PARTITIONING
# =============================================================================
# Layout:
#   p1  ESP       512 MiB  ef00  FAT32
#   p2  swap      48 GiB   8200  plain swap
#   p3  root      rest     8300  BTRFS
#
# [LUKS] To add encryption, change p2 and p3 type codes to 8309
# (Linux LUKS) and add LUKS format + open steps after partprobe.
# All subsequent references to ROOT_DEV/SWP_DEV become ROOT_MAPPER/SWP_MAPPER.
# =============================================================================

echo ""
echo "=== Partitioning ${DISK} ==="

sgdisk --zap-all --clear "${DISK}"
partprobe "${DISK}"
wipefs -af "${DISK}"
partprobe "${DISK}"

sgdisk --new=0:0:+${ESP_SIZE}  --typecode=0:ef00 --change-name=0:esp  "${DISK}"
sgdisk --new=0:0:+${SWP_SIZE}  --typecode=0:8200 --change-name=0:swap "${DISK}"
sgdisk --new=0:0:0              --typecode=0:8300 --change-name=0:root "${DISK}"
partprobe "${DISK}"

wipefs -af "${ESP_DEV}"
wipefs -af "${SWP_DEV}"
wipefs -af "${ROOT_DEV}"
partprobe "${DISK}"

echo "Partitioning complete:"
lsblk "${DISK}"
sleep 5

# =============================================================================
# [LUKS] ENCRYPTION WOULD BE INSERTED HERE
# =============================================================================
# cryptsetup --type luks2 -v -y luksFormat "${ROOT_DEV}"
# cryptsetup open "${ROOT_DEV}" "${LUKS_ROOT_NAME}"
#
# cryptsetup --type luks2 -v -y lukFormat "${SWP_DEV}"
# cryptsetup open "${SWP_DEV}" "${LUKS_SWP_NAME}"
#
# Then replace ROOT_DEV → ROOT_MAPPER and SWP_DEV → SWP_MAPPER
# in everything below this point.
# =============================================================================

# =============================================================================
# FILESYSTEMS
# =============================================================================

echo ""
echo "=== Creating filesystems ==="

mkfs.fat -F32 -n ESP "${ESP_DEV}"
mkfs.btrfs -L "${BTRFS_LABEL}" "${ROOT_DEV}"
mkswap -L swap "${SWP_DEV}"

echo "Filesystems created."
sleep 5

# =============================================================================
# BTRFS SUBVOLUMES
# =============================================================================
# Flat layout — all subvolumes are direct children of the top-level (ID 5).
# None are nested inside each other.
#
# @              →  /              root, snapshotted by snapper
# @home          →  /home          separate snapshot schedule
# @snapshots     →  /.snapshots    snapper stores snapshots here
# @log           →  /var/log       excluded from snapshots
# @cache         →  /var/cache     excluded from snapshots
# @tmp           →  /var/tmp       excluded from snapshots
#
# [LUKS] Subvolume layout is identical with encryption.
# =============================================================================

echo ""
echo "=== Creating BTRFS subvolumes ==="

mount "${ROOT_DEV}" /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@tmp

echo "Subvolumes created:"
btrfs subvolume list /mnt
sleep 5

umount /mnt

# =============================================================================
# MOUNT SUBVOLUMES
# =============================================================================

echo ""
echo "=== Mounting subvolumes ==="

# mount root subvolume
mount -o "${BTRFS_MOUNT_OPTS},subvol=@" "${ROOT_DEV}" /mnt

# Create mountpoints
mkdir -p /mnt/{home,.snapshots,var/log,var/cache,var/tmp,boot,btrfs}
mkdir -p /mnt/boot/efi

# All other subvolumes — explicit subvol=
mount -o "${BTRFS_MOUNT_OPTS},subvol=@home"      "${ROOT_DEV}" /mnt/home
mount -o "${BTRFS_MOUNT_OPTS},subvol=@snapshots" "${ROOT_DEV}" /mnt/.snapshots
mount -o "${BTRFS_MOUNT_OPTS},subvol=@log"       "${ROOT_DEV}" /mnt/var/log
mount -o "${BTRFS_MOUNT_OPTS},subvol=@cache"     "${ROOT_DEV}" /mnt/var/cache
mount -o "${BTRFS_MOUNT_OPTS},subvol=@tmp"       "${ROOT_DEV}" /mnt/var/tmp
# Top level BTRFS (ID 5) needed for rollback. fstab auto-mounts that
mount -o "${BTRFS_MOUNT_OPTS},subvolid=5"        "${ROOT_DEV}" /mnt/btrfs

# ESP — FAT32 mounted over /boot/efi
mount "${ESP_DEV}" /mnt/boot/efi

# Activate swap
swapon "${SWP_DEV}"

echo "Mount layout:"
findmnt --tree
sleep 5

# =============================================================================
# MIRRORLIST
# =============================================================================

echo ""
echo "=== Updating mirrorlist ==="
cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak
reflector --verbose --protocol https --latest 5 --sort rate \
    --country "${REFLECTOR_COUNTRY}" --save /etc/pacman.d/mirrorlist
pacman -Syy

# =============================================================================
# PACSTRAP
# =============================================================================
# [LUKS] When adding encryption, add cryptsetup to this list.
# =============================================================================

echo ""
echo "=== Installing base system ==="

pacstrap -K /mnt \
    base base-devel \
    linux linux-firmware linux-headers \
    intel-ucode \
    btrfs-progs \
    grub efibootmgr \
    grub-btrfs inotify-tools \
    snapper snap-pac \
    networkmanager \
    vim \
    man-db man-pages \
    reflector \
    sudo \
    git

# =============================================================================
# FSTAB
# =============================================================================
# genfstab reads current mounts and writes fstab.
#
# Root mounted with subvol=@ → genfstab hardcodes root subvolume
# [LUKS] Output is identical. The UUID in the root entry will reflect
# the block device actually mounted — no special handling needed.
# =============================================================================

echo ""
echo "=== Generating fstab ==="
genfstab -U /mnt >> /mnt/etc/fstab

echo "Generated fstab — root entry should have NO subvol= option:"
cat /mnt/etc/fstab

# =============================================================================
# DONE
# =============================================================================

echo ""
echo "============================================="
echo "  1-install.sh complete."
echo ""
echo "  Verify fstab above — root entry must"
echo "  have NO subvol= option."
echo ""
echo "  Next:"
echo "    arch-chroot /mnt"
echo "    bash /root/2-configure.sh"
echo "============================================="

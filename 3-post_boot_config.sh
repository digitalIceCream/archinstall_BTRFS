#!/usr/bin/env bash

# =============================================================================
# SNAPPER
# =============================================================================
# Setup sequence for / — order matters, explanation inline:
#
#   /.snapshots already exists as our mounted @snapshots subvolume.
#   snapper create-config / tries to create /.snapshots itself — conflict.
#   Workaround:
#     1. Unmount /.snapshots 
#     2. Delete /.snapshots directory 
#     3. Run snapper create-config / (it creates /.snapshots as new subvol)
#     4. Delete subvolume that snapper created
#     5. Restore /.snapshots directory
#     6. Remount — fstab mounts @snapshots back onto it
#
#   Result: snapper uses our @snapshots subvolume, not one it created.
#
# /home setup is straightforward — no existing mount conflict there.
#
# [LUKS] Snapper setup is identical with encryption.
# =============================================================================

set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then
    echo "ERROR: This script must be run as root. Aborting."
    exit 1
fi

echo ""
echo "=== Configuring snapper ==="

# Root config
umount /.snapshots
rm -d /.snapshots
snapper -c root create-config /
btrfs subvolume delete /.snapshots
mkdir /.snapshots
mount -a
chmod 750 /.snapshots

# Home config
snapper -c home create-config /home

# Root retention — aggressive enough to be useful, conservative on space
snapper -c root set-config \
    "TIMELINE_CREATE=yes" \
    "TIMELINE_CLEANUP=yes" \
    "TIMELINE_LIMIT_HOURLY=5" \
    "TIMELINE_LIMIT_DAILY=7" \
    "TIMELINE_LIMIT_WEEKLY=0" \
    "TIMELINE_LIMIT_MONTHLY=0" \
    "TIMELINE_LIMIT_YEARLY=0" \
    "NUMBER_CLEANUP=yes" \
    "NUMBER_LIMIT=10"

# Home retention — daily snapshots, keep two weeks
snapper -c home set-config \
    "TIMELINE_CREATE=yes" \
    "TIMELINE_CLEANUP=yes" \
    "TIMELINE_LIMIT_HOURLY=0" \
    "TIMELINE_LIMIT_DAILY=14" \
    "TIMELINE_LIMIT_WEEKLY=2" \
    "TIMELINE_LIMIT_MONTHLY=0" \
    "TIMELINE_LIMIT_YEARLY=0" \
    "NUMBER_CLEANUP=yes" \
    "NUMBER_LIMIT=10"

echo "Snapper configs:"
snapper list-configs

# =============================================================================
# SERVICES
# =============================================================================

echo ""
echo "=== Enabling services ==="

systemctl enable --now snapper-timeline.timer  # creates scheduled snapshots
systemctl enable --now snapper-cleanup.timer   # prunes old snapshots per config

# =============================================================================
# MINIMAL GRAPHICAL ENV
# =============================================================================

sudo pacman -S sway swaybar swaybg swayidle swaylock \
    foot \
    xorg-xwayland \
    pipewire pipewire-pulse wireplumber \
    mesa vulkan-intel \
    ttf-dejavu \
    brightnessctl


# =============================================================================
# DONE
# =============================================================================


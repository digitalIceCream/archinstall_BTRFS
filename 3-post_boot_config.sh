#!/bin/sh


# =============================================================================
# SNAPPER
# =============================================================================
# Setup sequence for / — order matters, explanation inline:
#
#   /.snapshots already exists as our mounted @snapshots subvolume.
#   snapper create-config / tries to create /.snapshots itself — conflict.
#   Workaround:
#     1. Unmount /.snapshots temporarily
#     2. Run snapper create-config / (it creates /.snapshots as new subvol)
#     3. Delete what snapper created
#     4. Recreate /.snapshots as plain directory
#     5. Remount — fstab mounts @snapshots back onto it
#
#   Result: snapper uses our @snapshots subvolume, not one it created.
#
# /home setup is straightforward — no existing mount conflict there.
#
# [LUKS] Snapper setup is identical with encryption.
# =============================================================================

echo ""
echo "=== Configuring snapper ==="

# Root config
umount /.snapshots
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

systemctl enable NetworkManager          # networking
systemctl enable reflector.timer         # mirrorlist auto-update
systemctl enable snapper-timeline.timer  # creates scheduled snapshots
systemctl enable snapper-cleanup.timer   # prunes old snapshots per config

# grub-btrfsd watches /.snapshots for changes and automatically
# regenerates /boot/grub/grub.cfg so snapshots appear in GRUB menu
systemctl enable grub-btrfsd

# =============================================================================
# VERIFY BTRFS DEFAULT SUBVOLUME
# =============================================================================

echo ""
echo "=== Verifying BTRFS default subvolume ==="
DEFAULT=$(btrfs subvolume get-default /)
echo "Current default: ${DEFAULT}"
if ! echo "${DEFAULT}" | grep -q "path @$"; then
    echo ""
    echo "WARNING: Default subvolume is not @"
    echo "Fix with:"
    echo "  ID=\$(btrfs subvolume list / | awk '/ path @\$/ {print \$2}')"
    echo "  btrfs subvolume set-default \$ID /"
else
    echo "OK — default subvolume is @"
fi

# =============================================================================
# DONE
# =============================================================================


#!/usr/bin/env bash
# =============================================================================
# 2-configure.sh — Arch Linux configuration (run inside arch-chroot)
# =============================================================================
#
# Picks up where 1-install.sh left off. At this point:
#   - BTRFS subvolumes are mounted (now / in chroot)
#   - Base system is installed via pacstrap
#   - fstab generated with no subvol= on root entry
#
# This script handles:
#   - Interactive prompts for hostname and username
#   - Locale, timezone, console keymap
#   - User account creation
#   - mkinitcpio configuration and rebuild
#   - GRUB installation and configuration
#   - Snapper configuration for / and /home
#   - Service enablement
#
# NOTE — encryption extension:
#   Sections marked [LUKS] show exactly what would be added or changed
#   when layering LUKS on top of this setup. The structure is identical.
# =============================================================================

set -euo pipefail

# =============================================================================
# VARIABLES — must match 1-install.sh
# =============================================================================

export DISK="/dev/nvme0n1"
export ROOT_PART="${DISK}p3"
export SWP_PART="${DISK}p2"
export ESP_DEV="${DISK}p1"

# [LUKS] When adding encryption:
# LUKS_ROOT_NAME="cryptroot"
# LUKS_SWP_NAME="cryptswap"
# ROOT_UUID stays the same (LUKS partition UUID, not mapper UUID)
# SWP_UUID stays the same

export TIMEZONE="Europe/Berlin"
export LOCALE="en_GB.UTF-8"
export KEYMAP="de-latin1-nodeadkeys"

export BTRFS_MOUNT_OPTS="rw,noatime,compress-force=zstd:1,space_cache=v2"

# UUIDs — read from actual partitions at runtime
export ROOT_UUID="$(blkid -s UUID -o value "${ROOT_PART}")"
export SWP_UUID="$(blkid -s UUID -o value "${SWP_PART}")"

# =============================================================================
# INTERACTIVE PROMPTS
# =============================================================================

echo ""
echo "=== Installation parameters ==="
echo ""

read -rp "Hostname: " HOSTNAME
while [[ -z "${HOSTNAME}" ]]; do
    echo "Hostname cannot be empty."
    read -rp "Hostname: " HOSTNAME
done

read -rp "Username: " USERNAME
while [[ -z "${USERNAME}" ]]; do
    echo "Username cannot be empty."
    read -rp "Username: " USERNAME
done

echo ""
echo "  Hostname : ${HOSTNAME}"
echo "  Username : ${USERNAME}"
echo "  Timezone : ${TIMEZONE}"
echo "  Locale   : ${LOCALE}"
echo "  Keymap   : ${KEYMAP}"
echo ""
read -rp "Confirm (yes/no): " confirm
[[ "${confirm}" == "yes" ]] || { echo "Aborted."; exit 1; }

# =============================================================================
# TIMEZONE
# =============================================================================

echo ""
echo "=== Timezone ==="
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

# =============================================================================
# LOCALE
# =============================================================================

echo "=== Locale ==="
sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# =============================================================================
# HOSTNAME
# =============================================================================

echo "=== Hostname ==="
echo "${HOSTNAME}" > /etc/hostname

# =============================================================================
# ROOT PASSWORD
# =============================================================================

echo ""
echo "=== Set root password ==="
passwd

# =============================================================================
# USER ACCOUNT
# =============================================================================

echo ""
echo "=== Creating user: ${USERNAME} ==="
useradd -m -G wheel -s /bin/bash "${USERNAME}"
echo "Set password for ${USERNAME}:"
passwd "${USERNAME}"

# Enable sudo for wheel group
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
echo "sudo enabled for wheel group."

# =============================================================================
# MKINITCPIO
# =============================================================================
# Hook order — left to right, each hook can only use what came before it:
#
#   base        — directory skeleton (/dev, /proc, /sys), minimal utils
#   systemd     — systemd as PID 1 in initramfs, enables sd-* hooks
#   autodetect  — filters module list to only what this hardware needs
#                 must come after base+systemd, before module hooks
#   microcode   — Intel CPU microcode, applied as early as possible
#   modconf     — includes /etc/modprobe.d/ options
#   kms         — early kernel mode setting for GPU
#   keyboard    — USB/HID input drivers
#   sd-vconsole — applies KEYMAP in initramfs (de-latin1-nodeadkeys)
#   block       — NVMe/SATA block device drivers
#   filesystems — BTRFS module and others
#   fsck        — filesystem check tools
#
# MODULES: btrfs listed explicitly as belt-and-suspenders for root FS.
#          autodetect should catch it, but this guarantees it.
#
# [LUKS] When adding encryption:
#   Add sd-encrypt hook between block and filesystems
#   Add FILES=(/crypto_keyfile.bin)
#   Hook order becomes: ... block sd-encrypt filesystems fsck
# =============================================================================

echo ""
echo "=== Configuring mkinitcpio ==="
cat > /etc/mkinitcpio.conf.d/arch.conf << EOF
MODULES=(btrfs)
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck)
EOF

mkinitcpio -P

# =============================================================================
# GRUB
# =============================================================================
# Kernel cmdline parameters:
#
#   root=UUID=<uuid>
#       Points kernel at the BTRFS partition.
#       No subvol= here — BTRFS default subvolume handles that.
#       This is what allows snapper rollback to work.
#
#   resume=UUID=<uuid>
#       Points kernel at swap partition for hibernation resume.
#       On resume, kernel reads the hibernation image from here
#       before mounting root properly.
#
#   rw          — mount root read-write
#   quiet       — suppress most boot messages
#   loglevel=3  — only errors shown during boot
#
# [LUKS] When adding encryption, cmdline changes to:
#   rd.luks.name=<ROOT_UUID>=cryptroot
#   rd.luks.name=<SWP_UUID>=cryptswap
#   root=/dev/mapper/cryptroot
#   resume=/dev/mapper/cryptswap
#   Also set GRUB_ENABLE_CRYPTODISK=y in /etc/default/grub
# =============================================================================

echo ""
echo "=== Configuring GRUB ==="

GRUB_CMDLINE="root=UUID=${ROOT_UUID} resume=UUID=${SWP_UUID} rw quiet loglevel=3"

sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"${GRUB_CMDLINE}\"|" \
    /etc/default/grub

echo "GRUB_CMDLINE_LINUX set to:"
grep GRUB_CMDLINE_LINUX /etc/default/grub

# Install GRUB EFI stub to ESP
grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=GRUB \
    --recheck

# Generate grub.cfg
# Once grub-btrfsd is running it regenerates this automatically
# whenever snapshots are created or deleted
grub-mkconfig -o /boot/grub/grub.cfg

echo "GRUB installed and configured."

# =============================================================================
# SERVICES
# =============================================================================
# Only core services here. Snapper timers are enabled in 3-post_boot_config.sh
# after snapper configs exist.
# =============================================================================
 
echo ""
echo "=== Enabling services ==="
 
systemctl enable NetworkManager   # networking
systemctl enable reflector.timer  # mirrorlist auto-update
 
# grub-btrfsd watches /.snapshots and regenerates grub.cfg when
# snapshots are added or removed — idle until snapper is configured
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

echo ""
echo "============================================="
echo "  2-configure.sh complete."
echo ""
echo "  First boot checklist:"
echo "    GRUB menu appears"
echo "    System boots to login prompt"
echo "    Login as ${USERNAME}"
echo ""
echo "  Post-boot verification:"
echo "    findmnt --tree"
echo "    btrfs subvolume get-default /"
echo "    swapon --show"
echo ""
echo "  When ready to reboot:"
echo "    exit"
echo "    umount -R /mnt"
echo "    swapoff -a"
echo "    reboot"
echo "============================================="

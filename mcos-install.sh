#!/usr/bin/env bash
# McOS terminal installer: copies the live McOS onto a disk of your choice.
# Run it from the live McOS session:   bash mcos-install.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
trap 'echo; echo "!! Something failed near line $LINENO. Scroll up for the error and send it to Claude. Other disks were not touched."; exit 1' ERR

MNT=/mnt/mcos-target
SRC=/run/archiso/airootfs
B=$'\e[1m'; N=$'\e[0m'

echo "${B}=== McOS installer ===${N}"
[ -d "$SRC" ] || { echo "Run this from the McOS live session (can't find $SRC)."; exit 1; }
[ -d /sys/firmware/efi ] && UEFI=1 || UEFI=0
echo "Boot mode: $([ $UEFI = 1 ] && echo UEFI || echo BIOS/legacy)"

# ---- pick a disk (never the one we booted from) ----
BOOTSRC=$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null || true)
BOOTDISK=""; [ -n "$BOOTSRC" ] && BOOTDISK=$(lsblk -no pkname "$BOOTSRC" 2>/dev/null | head -1 || true)
mapfile -t DISKS < <(lsblk -dpno NAME,SIZE,TYPE | awk '$3=="disk"{print $1" "$2}' | { [ -n "$BOOTDISK" ] && grep -v "/dev/$BOOTDISK " || cat; })
[ ${#DISKS[@]} -gt 0 ] || { echo "No disks found. Add a virtual hard disk (25 GB+) to the VM and try again."; exit 1; }
echo; echo "Disks:"
for i in "${!DISKS[@]}"; do echo "  $((i+1))) ${DISKS[$i]}"; done
read -rp "Install McOS on which disk number? " n
DISK=$(echo "${DISKS[$((n-1))]}" | awk '{print $1}')
[ -b "$DISK" ] || { echo "Invalid choice."; exit 1; }
echo; echo "${B}This will ERASE EVERYTHING on $DISK.${N}"
read -rp "Type ERASE to continue: " c; [ "$c" = "ERASE" ] || { echo "Cancelled."; exit 0; }

# ---- account + settings ----
read -rp "Your username: " USERNAME
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "Username must be lowercase letters/numbers."; exit 1; }
while true; do
  read -rsp "Password: " PASS; echo; read -rsp "Password again: " PASS2; echo
  [ -n "$PASS" ] && [ "$PASS" = "$PASS2" ] && break; echo "Passwords didn't match, try again."
done
read -rp "Computer name [mcos]: " HOSTN; HOSTN=${HOSTN:-mcos}
read -rp "Timezone (e.g. America/New_York) [UTC]: " TZ; TZ=${TZ:-UTC}
[ -e "/usr/share/zoneinfo/$TZ" ] || { echo "Unknown timezone, using UTC."; TZ=UTC; }

# ---- partition + format ----
echo; echo "${B}Partitioning $DISK...${N}"
umount -R "$MNT" 2>/dev/null || true
wipefs -af "$DISK" >/dev/null
P=""; [[ "$DISK" =~ [0-9]$ ]] && P="p"
if [ $UEFI = 1 ]; then
  parted -s "$DISK" mklabel gpt mkpart ESP fat32 1MiB 513MiB set 1 esp on mkpart root ext4 513MiB 100%
  ESPP="${DISK}${P}1"; ROOTP="${DISK}${P}2"
else
  parted -s "$DISK" mklabel gpt mkpart bios 1MiB 3MiB set 1 bios_grub on mkpart root ext4 3MiB 100%
  ROOTP="${DISK}${P}2"
fi
partprobe "$DISK" || true; udevadm settle; sleep 2
[ $UEFI = 1 ] && mkfs.fat -F32 "$ESPP"
mkfs.ext4 -F "$ROOTP"
mkdir -p "$MNT"; mount "$ROOTP" "$MNT"
[ $UEFI = 1 ] && { mkdir -p "$MNT/boot/efi"; mount "$ESPP" "$MNT/boot/efi"; }

# ---- copy McOS ----
echo; echo "${B}Copying McOS (a few minutes)...${N}"
if command -v rsync >/dev/null; then rsync -aHAX --info=progress2 "$SRC"/ "$MNT"/
else cp -a "$SRC"/. "$MNT"/; fi

ROOT_UUID=$(blkid -s UUID -o value "$ROOTP")
{ echo "UUID=$ROOT_UUID / ext4 defaults,noatime 0 1"
  [ $UEFI = 1 ] && echo "UUID=$(blkid -s UUID -o value "$ESPP") /boot/efi vfat umask=0077 0 2" || true; } > "$MNT/etc/fstab"

# ---- configure inside the new system ----
echo; echo "${B}Setting up the new system...${N}"
for d in dev proc sys run; do mount --rbind "/$d" "$MNT/$d"; mount --make-rslave "$MNT/$d"; done
cp -L /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true
echo "$USERNAME:$PASS" > "$MNT/root/.mcos-cred"; chmod 600 "$MNT/root/.mcos-cred"

chroot "$MNT" /usr/bin/env UEFI="$UEFI" DISK="$DISK" USERNAME="$USERNAME" HOSTN="$HOSTN" TZ="$TZ" bash -s <<'CHROOT'
set -e
ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen; locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTN" > /etc/hostname

# normal (non-live) initramfs
rm -f /etc/mkinitcpio.conf.d/archiso.conf
cat > /etc/mkinitcpio.d/linux-zen.preset <<'P'
PRESETS=('default')
ALL_kver='/boot/vmlinuz-linux-zen'
default_image='/boot/initramfs-linux-zen.img'
P
echo "HOOKS=(base udev plymouth autodetect modconf kms keyboard keymap consolefont block filesystems fsck)" > /etc/mkinitcpio.conf.d/mcos.conf
[ -f /boot/vmlinuz-linux-zen ] || pacman -Sy --noconfirm linux-zen
mkinitcpio -P

# bootloader
if [ "$UEFI" = 1 ]; then
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=McOS --removable
else
  grub-install --target=i386-pc "$DISK"
fi
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# your account; remove the live one
useradd -m -G wheel,audio,video,input -s /bin/bash "$USERNAME"
chpasswd < /root/.mcos-cred
rm -f /root/.mcos-cred
passwd -l root
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
printf '[General]\nDisplayServer=wayland\n\n[Theme]\nCursorTheme=McOS-Cursors\n' > /etc/sddm.conf.d/mcos.conf
rm -f /etc/systemd/system/mcos-fix-home.service /etc/systemd/system/multi-user.target.wants/mcos-fix-home.service
rm -f /usr/share/applications/install-mcos.desktop
userdel -r mcos 2>/dev/null || true
rm -rf /home/mcos
CHROOT

# ---- done ----
sync
for d in run sys proc dev; do umount -R "$MNT/$d" 2>/dev/null || umount -l "$MNT/$d" 2>/dev/null || true; done
umount -R "$MNT"
echo; echo "${B}Done! McOS is installed on $DISK.${N}"
echo "Shut down, remove the ISO from the virtual drive, then start the VM again."
read -rp "Press Enter to power off... " _; poweroff

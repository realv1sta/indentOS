#!/bin/bash
set -u

USER_=""
PASSWORD=""
HOST=""
ROOT=""
DE=""
BOOTMODE_CHOICE=""
LOGFILE="/tmp/indentos_install.log"

check_mount() {
    mountpoint -q /mnt
}

show_error_log() {
    dialog --title "Installation Failed - Error Log" --textbox "$LOGFILE" 20 75; clear
}

fix_keyrings_and_time() {
    echo "=== Synchronizing System Time & Fixing Keyrings ===" >> "$LOGFILE"
    timedatectl set-ntp true 2>/dev/null || true
    pacman-key --init >> "$LOGFILE" 2>&1 || true
    pacman-key --populate archlinux >> "$LOGFILE" 2>&1 || true
}

network_preflight_check() {
    local ok=true
    local msg=""

    if ! curl -s --max-time 5 -o /dev/null https://1.1.1.1; then
        msg="${msg}\n - No raw network connectivity (couldn't reach 1.1.1.1). Connect Wi-Fi (iwctl) or ethernet (dhcpcd) first."
        ok=false
    elif ! curl -s --max-time 5 -o /dev/null https://archlinux.org; then
        msg="${msg}\n - Network is up but DNS resolution is failing. Check /etc/resolv.conf on this live session."
        ok=false
    fi

    local now_year
    now_year=$(date +%Y)
    if [ "$now_year" -lt 2024 ]; then
        msg="${msg}\n - System clock looks wrong (year $now_year). This breaks HTTPS certificate validation and can look exactly like a network failure. Run: timedatectl set-ntp true (or set-time manually)."
        ok=false
    fi

    if [ "$ok" == "false" ]; then
        dialog --title "Network Check Failed" --msgbox "Before installing, fix the following on THIS live session (not the target disk):$msg\n\nThen relaunch the installer." 0 0; clear
        return 1
    fi
    return 0
}

setup_chroot_dns() {
    rm -f /mnt/etc/resolv.conf
    cat <<EOF > /mnt/etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
}

refresh_mirrors() {
    cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup || true
    LOCATION=$(curl -s --max-time 5 https://ipinfo.io/country | tr -d '[:space:]')

    REFLECTOR_OK=true
    if [ -n "$LOCATION" ]; then
        reflector --country "$LOCATION" --latest 10 --protocol https --sort rate --download-timeout 5 --save /etc/pacman.d/mirrorlist >> "$LOGFILE" 2>&1 || REFLECTOR_OK=false
    else
        REFLECTOR_OK=false
    fi

    if [ "$REFLECTOR_OK" = false ] || [ ! -s /etc/pacman.d/mirrorlist ]; then
        reflector --latest 10 --protocol https --sort rate --download-timeout 5 --save /etc/pacman.d/mirrorlist >> "$LOGFILE" 2>&1 || true
    fi

    if [ ! -s /etc/pacman.d/mirrorlist ]; then
        [ -f /etc/pacman.d/mirrorlist.backup ] && cp /etc/pacman.d/mirrorlist.backup /etc/pacman.d/mirrorlist
    fi

    pacman -Syy --noconfirm archlinux-keyring >> "$LOGFILE" 2>&1 || true
}

> "$LOGFILE"

if ! network_preflight_check; then
    exit 1
fi

while true; do
    MENU=$(dialog --title "Installation Menu" --menu "Choose an option" 20 55 6 \
        1 "User Account" \
        2 "Hostname" \
        3 "Root Password" \
        4 "DE selection" \
        5 "Boot Mode" \
        6 "Install" 3>&1 1>&2 2>&3 3>&-)

    STATUS=$?
    clear

    if [ $STATUS -ne 0 ]; then
        break
    fi

    if [ "$MENU" == "1" ]; then
        while true; do
            USER_=$(dialog --title "User Creation" --inputbox "Please write a name for your user: " 0 0 3>&1 1>&2 2>&3 3>&-); clear
            [ -n "$USER_" ] && break
        done

        while true; do
            PASSWORD=$(dialog --title "Password" --insecure --passwordbox "Please make a password for: $USER_" 0 0 3>&1 1>&2 2>&3 3>&-); clear
            PASSWORD2=$(dialog --title "Password" --insecure --passwordbox "Please retype the password for: $USER_" 0 0 3>&1 1>&2 2>&3 3>&-); clear

            if [ -n "$PASSWORD" ] && [ "$PASSWORD" == "$PASSWORD2" ]; then
                dialog --title "Password Set!" --msgbox "Password has been set!" 0 0; clear
                break
            else
                dialog --title "Error" --msgbox "Passwords not match or were left empty. Try again." 0 0; clear
            fi
        done
    fi

    if [ "$MENU" == "2" ]; then
        while true; do
            HOST=$(dialog --title "Hostname" --inputbox "Create your hostname: " 0 0 3>&1 1>&2 2>&3 3>&-); clear
            [ -n "$HOST" ] && break
        done
        dialog --title "Success!" --msgbox "Your host name will be: $HOST." 0 0; clear
    fi

    if [ "$MENU" == "3" ]; then
        while true; do
            ROOT=$(dialog --title "Root password" --insecure --passwordbox "Please type in your root password: " 0 0 3>&1 1>&2 2>&3 3>&-); clear
            ROOT2=$(dialog --title "Root password" --insecure --passwordbox "Please retype your root password: " 0 0 3>&1 1>&2 2>&3 3>&-); clear

            if [ -n "$ROOT" ] && [ "$ROOT" == "$ROOT2" ]; then
                dialog --title "Root Password Set!" --msgbox "Your root password has been set!" 0 0; clear
                break
            else
                dialog --title "Error" --msgbox "Passwords not match or left empty. Try Again!" 0 0; clear
            fi
        done
    fi

    if [ "$MENU" == "4" ]; then
        DE=$(dialog --title "DE Selection" --menu "Choose your preferred DE: " 10 40 2 \
            1 "KDE Plasma" \
            2 "XFCE4" 3>&1 1>&2 2>&3 3>&-); clear
    fi

    if [ "$MENU" == "5" ]; then
        CHOICE=$(dialog --title "Boot Mode" --menu "Choose your bios down below:" 11 55 3 \
            1 "Auto-detect (recommended)" \
            2 "Force UEFI" \
            3 "Force BIOS / Legacy" 3>&1 1>&2 2>&3 3>&-); clear

        case "$CHOICE" in
            1) BOOTMODE_CHOICE="" ;;
            2) BOOTMODE_CHOICE="uefi" ;;
            3) BOOTMODE_CHOICE="bios" ;;
        esac

        if [ -n "$CHOICE" ]; then
            LABEL="Auto-detect"
            [ "$BOOTMODE_CHOICE" == "uefi" ] && LABEL="Force UEFI"
            [ "$BOOTMODE_CHOICE" == "bios" ] && LABEL="Force BIOS/Legacy"
            dialog --title "Boot Mode Set" --msgbox "Boot mode set to: $LABEL" 0 0; clear
        fi
    fi

    if [ "$MENU" == "6" ]; then

        MISSING=""
        [ -z "$USER_" ] && MISSING="${MISSING}\n - User Account"
        [ -z "$HOST" ] && MISSING="${MISSING}\n - Hostname"
        [ -z "$ROOT" ] && MISSING="${MISSING}\n - Root Password"
        [ -z "$DE" ] && MISSING="${MISSING}\n - DE Selection"

        if [ -n "$MISSING" ]; then
            dialog --title "Missing Fields" --msgbox "Please configure the following options first:\n$MISSING" 0 0; clear
            continue
        fi

        if ! check_mount; then
            dialog --title "Mount Error" --msgbox "Nothing is mounted at /mnt! Please partition and mount your target drive before installing." 0 0; clear
            continue
        fi

        EFIVARS_PRESENT=false
        if [ -d /sys/firmware/efi/efivars ] && [ -n "$(ls -A /sys/firmware/efi/efivars 2>/dev/null)" ]; then
            EFIVARS_PRESENT=true
        fi

        case "$BOOTMODE_CHOICE" in
            uefi) BOOT_MODE="uefi" ;;
            bios) BOOT_MODE="bios" ;;
            *)
                if [ "$EFIVARS_PRESENT" == "true" ]; then
                    BOOT_MODE="uefi"
                else
                    BOOT_MODE="bios"
                fi
                ;;
        esac

        EFI_DIR=""
        if mountpoint -q /mnt/boot/efi 2>/dev/null; then
            EFI_DIR="/boot/efi"
        elif mountpoint -q /mnt/boot 2>/dev/null; then
            EFI_DIR="/boot"
        fi

        if [ "$BOOT_MODE" == "uefi" ] && [ -z "$EFI_DIR" ]; then
            dialog --title "EFI Partition Not Found" --msgbox "You're installing for UEFI, but no EFI System Partition is mounted at /mnt/boot or /mnt/boot/efi.\n\nMount your FAT32 ESP at one of those paths (e.g. mount /dev/sda1 /mnt/boot/efi) and try again." 0 0; clear
            continue
        fi

        if [ "$BOOT_MODE" == "uefi" ] && [ -n "$EFI_DIR" ]; then
            ESP_FSTYPE=$(findmnt -no FSTYPE "/mnt${EFI_DIR}" 2>/dev/null)
            if [ "$ESP_FSTYPE" != "vfat" ]; then
                dialog --title "EFI Partition Warning" --yesno "The partition mounted at $EFI_DIR doesn't look like FAT32/vfat (detected: ${ESP_FSTYPE:-unknown}).\n\nA UEFI ESP must be formatted FAT32 or grub-install will fail. This is also required so an existing Windows/other-OS bootloader on the same ESP stays intact for dual-booting.\n\nContinue anyway?" 0 0
                if [ $? -ne 0 ]; then
                    clear
                    continue
                fi
                clear
            fi
        fi

        UEFI_NVRAM_OK=false
        if [ "$BOOT_MODE" == "uefi" ] && [ "$EFIVARS_PRESENT" == "true" ]; then
            UEFI_NVRAM_OK=true
        fi

        if [ "$BOOT_MODE" == "uefi" ] && [ "$EFIVARS_PRESENT" != "true" ]; then
            dialog --title "Warning: No EFI Variables" --yesno "You're installing for UEFI, but this live session doesn't have EFI variables available.\n\nGrub can still be installed, but no dedicated 'indentOS' entry can be registered in your firmware's boot menu - most firmwares will still boot it as the fallback, but not all.\n\nFor a proper boot entry, reboot the install media in UEFI mode instead.\n\nContinue anyway?" 0 0
            if [ $? -ne 0 ]; then
                clear
                continue
            fi
            clear
        fi

        dialog --title "Warning!" --yesno "If you click confirm, indentOS will install on your disk/partition at /mnt. THIS ACTION CANNOT BE REVERSED!\n\nSO do it at your own risk!!" 0 0

        STATUS=$?
        clear

        if [ $STATUS -ne 0 ]; then
            break
        else
            dialog --title "Mirrors" --infobox "Finding fast mirrors for your location, hang on..." 0 0
            refresh_mirrors
            clear

            TIMEZONE=$(curl -s --max-time 5 https://ipinfo.io/timezone)
            if [ -z "$TIMEZONE" ] || [ ! -e "/usr/share/zoneinfo/$TIMEZONE" ]; then
                TIMEZONE="UTC"
            fi

            ROOT_PART=$(findmnt -no SOURCE /mnt 2>/dev/null)
            GRUB_DISK=""
            if [ -n "$ROOT_PART" ]; then
                PKNAME=$(lsblk -no pkname "$ROOT_PART" 2>/dev/null)
                [ -n "$PKNAME" ] && GRUB_DISK="/dev/$PKNAME"
            fi
            if [ "$BOOT_MODE" == "bios" ] && [ -z "$GRUB_DISK" ]; then
                echo "WARNING: could not auto-detect the target disk from /mnt (findmnt/lsblk gave nothing usable)." >> "$LOGFILE"
            fi

            INSTALL_OK=true
            fix_keyrings_and_time

            sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 12/' /etc/pacman.conf

            pacstrap -K /mnt base base-devel linux linux-firmware sof-firmware grub efibootmgr os-prober sudo --overwrite="*" >> "$LOGFILE" 2>&1 || INSTALL_OK=false

            if [ "$INSTALL_OK" == "true" ]; then
                genfstab -U /mnt > /mnt/etc/fstab
                setup_chroot_dns

                sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 12/' /mnt/etc/pacman.conf
                sed -i '/^ParallelDownloads = 12/a Color\nILoveCandy' /mnt/etc/pacman.conf

                mkdir -p /mnt/usr/local/bin
                cp /usr/local/bin/tree /mnt/usr/local/bin
                chmod +x /mnt/usr/local/bin/tree

                arch-chroot /mnt /bin/bash >> "$LOGFILE" 2>&1 <<EOF
pacman -Sy --noconfirm archlinux-keyring || true


echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf
echo "$HOST" > /etc/hostname

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

cat <<HOSTSEOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOST.localdomain $HOST
HOSTSEOF

mkinitcpio -P

cat <<OSSEOF > /etc/os-release
NAME="indentOS"
PRETTY_NAME="indentOS"
ID=indentos
BUILD_ID=rolling
ANSI_COLOR="38;2;85;255;85"
HOME_URL="https://github.com/realv1sta/indentOS"
DOCUMENTATION_URL="https://github.com/realv1sta/indentOS"
OSSEOF

mkdir -p /etc/skel/.config

pacman -S --noconfirm --overwrite="*" git || true

if git clone https://github.com/beamyyl/fastfetch /tmp/fastfetch-skel; then
    cp -r /tmp/fastfetch-skel/* /etc/skel/.config/ 2>/dev/null || true
    rm -rf /tmp/fastfetch-skel
else
    echo "WARNING: could not clone beamyyl/fastfetch, /etc/skel/.config/fastfetch not seeded" >&2
fi
mkdir -p /etc/skel/.config/fastfetch

if git clone https://github.com/beamyyl/kitty /tmp/kitty-skel; then
    cp -r /tmp/kitty-skel/* /etc/skel/.config/ 2>/dev/null || true
    rm -rf /tmp/kitty-skel
else
    echo "WARNING: could not clone beamyyl/kitty, /etc/skel/.config/kitty not seeded" >&2
fi

if git clone https://github.com/realv1sta/indentOS /tmp/indentos-assets; then
    if [ -f /tmp/indentos-assets/colorlogo.sh ]; then
        chmod +x /tmp/indentos-assets/colorlogo.sh
        (cd /tmp/indentos-assets && ./colorlogo.sh > /etc/skel/.config/fastfetch/logo.txt) || echo "WARNING: colorlogo.sh failed, keeping empty logo.txt" >&2
    else
        echo "WARNING: colorlogo.sh not found in indentOS repo, keeping logo.txt empty" >&2
    fi
    rm -rf /tmp/indentos-assets
else
    echo "WARNING: could not clone indentOS repo, logo not installed" >&2
fi

echo "root:$ROOT" | chpasswd
useradd -m -G wheel "$USER_"
echo "$USER_:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

if [ "$BOOT_MODE" = "uefi" ]; then
    pacman -S --noconfirm --overwrite="*" grub efibootmgr os-prober
    if [ "$UEFI_NVRAM_OK" = "true" ]; then
        grub-install --target=x86_64-efi --efi-directory="$EFI_DIR" --bootloader-id=indentOS
        if [ \$? -ne 0 ]; then
            echo "WARNING: grub-install with NVRAM registration failed, retrying with --removable (no firmware boot entry will be created)." >&2
            grub-install --target=x86_64-efi --efi-directory="$EFI_DIR" --bootloader-id=indentOS --removable
            if [ \$? -ne 0 ]; then
                echo "FATAL: UEFI grub-install failed even with --removable. Check that $EFI_DIR is your mounted ESP (vfat filesystem, esp/boot partition flag set)." >&2
                exit 1
            fi
        fi
    else
        grub-install --target=x86_64-efi --efi-directory="$EFI_DIR" --bootloader-id=indentOS --removable
        if [ \$? -ne 0 ]; then
            echo "FATAL: UEFI grub-install failed. Check that $EFI_DIR is your mounted ESP (vfat filesystem, esp/boot partition flag set)." >&2
            exit 1
        fi
    fi

    mkdir -p "$EFI_DIR/EFI/BOOT"
    if [ -f "$EFI_DIR/EFI/indentOS/grubx64.efi" ]; then
        cp -f "$EFI_DIR/EFI/indentOS/grubx64.efi" "$EFI_DIR/EFI/BOOT/BOOTX64.EFI" || true
    fi
else
    if [ -z "$GRUB_DISK" ]; then
        echo "FATAL: could not determine the target disk for BIOS grub-install (findmnt/lsblk gave nothing usable - no /dev/sda assumption made). See log for details." >&2
        exit 1
    fi
    pacman -S --noconfirm --overwrite="*" grub os-prober
    grub-install --recheck "$GRUB_DISK"
    if [ \$? -ne 0 ]; then
        echo "FATAL: BIOS grub-install to $GRUB_DISK failed." >&2
        exit 1
    fi
fi

sed -i 's/^#*GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="indentOS"/' /etc/default/grub || echo 'GRUB_DISTRIBUTOR="indentOS"' >> /etc/default/grub
sed -i 's/^#*GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub || echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

if [ "$DE" == "1" ]; then
    pacman -S plasma konsole dolphin wl-clipboard kitty fastfetch sddm networkmanager nano sudo power-profiles-daemon --overwrite="*" --noconfirm
elif [ "$DE" == "2" ]; then
    pacman -S xorg-server xfce4 xfce4-whiskermenu-plugin xclip maim xfce4-pulseaudio-plugin kitty fastfetch sddm networkmanager nano sudo power-profiles-daemon --overwrite="*" --noconfirm
fi

systemctl enable NetworkManager
systemctl enable sddm --force
EOF
                [ $? -ne 0 ] && INSTALL_OK=false
            fi

            if [ "$INSTALL_OK" == "true" ]; then
                dialog --title "All done!" --msgbox "Installation complete! Reboot into indentOS." 0 0; clear
                break
            else
                show_error_log
            fi
        fi
    fi

done

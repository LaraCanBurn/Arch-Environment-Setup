#!/bin/bash

# ==================================================
# INSTALADOR AUTOMÁTICO DE ARCH LINUX CON ZFS/LUKS
# ==================================================
# Características:
# - Soporte para cifrado LUKS (solo partición raíz)
# - Configuración ZFS opcional
# - Detección automática de entorno (VM/físico)
# - Continuación ante fallos de paquetes
# - Notificación post-reinicio de paquetes faltantes
# - Interfaz colorida y amigable
# - Manejo de errores mejorado
# ==================================================

# --- Configuración inicial ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Variables personalizadas
ZPOOL_NAME="raidz"
USERNAME="LaraCanBurn"
ROOT_PASSWORD="root"
USER_PASSWORD="laracanburn"
TIMEZONE="Europe/Madrid"
LANG="en_US.UTF-8"
KEYMAP="es"
HOSTNAME="ArchLinux"
INSTALL_ROOT="/mnt"
LOG_FILE="/var/log/installation.log"
FAILED_PKGS_FILE="/var/log/failed_packages.log"

# Lista de paquetes base
BASE_PACKAGES=(
    "base" "linux" "linux-firmware" "sof-firmware"
    "base-devel" "grub" "efibootmgr" "nano" "vim"
    "networkmanager" "lvm2" "cryptsetup" "zfs-dkms"
)

# Paquetes de audio
AUDIO_PACKAGES=(
    # Drivers ALSA
    "alsa-utils" "alsa-firmware" "alsa-plugins" "alsa-lib"
    "alsa-tools" "alsa-firmware-loaders"
    
    # Herramientas gráficas ALSA
    "alsamixergui" "volumeicon-alsa"
    
    # PulseAudio (servidor de sonido)
    "pulseaudio" "pulseaudio-alsa" "pulseaudio-bluetooth"
    "pavucontrol" "paprefs"
    
    # Opcional: JACK para producción audio
    "jack2" "qjackctl"
    
    # Codecs y soporte adicional
    "pulseaudio-equalizer" "lib32-alsa-plugins" 
    "lib32-alsa-lib" "lib32-jack"
)

# --- Funciones principales ---

init_logs() {
    exec > >(tee -a "$LOG_FILE") 2>&1
    touch "$FAILED_PKGS_FILE"
}

print_msg() {
    case $1 in
        red)    printf "\033[1;31m%s\033[0m\n" "$2" ;;
        green)  printf "\033[1;32m%s\033[0m\n" "$2" ;;
        yellow) printf "\033[1;33m%s\033[0m\n" "$2" ;;
        blue)   printf "\033[1;34m%s\033[0m\n" "$2" ;;
        *)      printf "%s\n" "$2" ;;
    esac
}

check_root() {
    [ "$(id -u)" -ne 0 ] && print_msg "red" "ERROR: Ejecuta como root. Usa 'sudo -i' en el live USB." && exit 1
}

verify_luks() {
    local device=$1
    print_msg "blue" "Verificando configuración LUKS en $device..."
    
    if ! cryptsetup isLuks "$device"; then
        print_msg "red" "$device no es un dispositivo LUKS válido"
        return 1
    fi
    
    cryptsetup luksDump "$device" || {
        print_msg "red" "Fallo al verificar $device"
        return 1
    }
    
    print_msg "green" "Verificación LUKS completada para $device"
    return 0
}

configure_pacman() {
    print_msg "blue" "[*] Configurando pacman.conf..."
    
    sed -i -e '/^#Color$/s/^#//' \
           -e '/^#ParallelDownloads = 5/s/^#//' \
           -e '/^ParallelDownloads/a ILoveCandy' \
           -e '/^\[multilib\]/,/Include/ s/^#//' \
           -e '/^\[multilib-testing\]/,/Include/ s/^Include/#Include/' /etc/pacman.conf
    
    # Actualizar mirrorlist con los mirrors más rápidos
    print_msg "blue" "[*] Actualizando mirrorlist..."
    reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
    
    if ! pacman -Sy; then
        print_msg "red" "[ERROR] Falló al sincronizar bases de datos"
        return 1
    fi
    
    print_msg "green" "[✓] Configuración de pacman completada"
    return 0
}

setup_disks() {
    print_msg "yellow" "[*] Configurando discos..."
    lsblk -d -o NAME,SIZE,MODEL | grep -v "loop"
    
    read -p "Disco para sistema (ej: sda): " DISK_SYSTEM
    read -p "Discos para ZFS (ej: sdb sdc): " -a DISK_ZFS

    for disk in "$DISK_SYSTEM" "${DISK_ZFS[@]}"; do
        [ ! -b "/dev/$disk" ] && print_msg "red" "[ERROR] Disco $disk no válido" && return 1
    done

    print_msg "yellow" "[*] Limpiando tablas de particiones..."
    for disk in "$DISK_SYSTEM" "${DISK_ZFS[@]}"; do
        wipefs -a "/dev/$disk"
        dd if=/dev/zero of="/dev/$disk" bs=1M count=100
    done

    print_msg "yellow" "[*] Creando particiones..."
    parted -s "/dev/$DISK_SYSTEM" mklabel gpt
    parted -s "/dev/$DISK_SYSTEM" mkpart primary fat32 1MiB 513MiB
    parted -s "/dev/$DISK_SYSTEM" set 1 esp on
    parted -s "/dev/$DISK_SYSTEM" mkpart primary ext4 513MiB 100%

    print_msg "yellow" "[*] Configurando cifrado LUKS en partición raíz..."
    until cryptsetup luksFormat --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha512 \
        --iter-time 5000 \
        --pbkdf argon2id \
        "/dev/${DISK_SYSTEM}2"; do
        print_msg "red" "[ERROR] Falló el cifrado, reintentando..."
        sleep 2
    done
    
    verify_luks "/dev/${DISK_SYSTEM}2" || return 1
    
    print_msg "yellow" "[*] Abriendo partición cifrada..."
    cryptsetup open "/dev/${DISK_SYSTEM}2" crypt-root || {
        print_msg "red" "[ERROR] No se pudo abrir el dispositivo cifrado"
        return 1
    }

    print_msg "yellow" "[*] Configurando LVM..."
    pvcreate "/dev/mapper/crypt-root" || {
        print_msg "red" "[ERROR] Falló pvcreate"
        return 1
    }
    vgcreate vg_arch "/dev/mapper/crypt-root" || {
        print_msg "red" "[ERROR] Falló vgcreate"
        return 1
    }
    lvcreate -L 8G vg_arch -n swap || {
        print_msg "red" "[ERROR] Falló lvcreate para swap"
        return 1
    }
    lvcreate -l +100%FREE vg_arch -n root || {
        print_msg "red" "[ERROR] Falló lvcreate para root"
        return 1
    }

    print_msg "yellow" "[*] Formateando particiones..."
    mkfs.vfat -F32 "/dev/${DISK_SYSTEM}1" || {
        print_msg "red" "[ERROR] Falló al formatear EFI"
        return 1
    }
    mkswap "/dev/mapper/vg_arch-swap" || {
        print_msg "red" "[ERROR] Falló al crear swap"
        return 1
    }
    mkfs.ext4 "/dev/mapper/vg_arch-root" || {
        print_msg "red" "[ERROR] Falló al formatear root"
        return 1
    }

    return 0
}

setup_zfs() {
    [ ${#DISK_ZFS[@]} -eq 0 ] && return 0

    print_msg "blue" "[*] Configurando ZFS en discos: ${DISK_ZFS[*]}..."
    
    for disk in "${DISK_ZFS[@]}"; do
        print_msg "blue" "[*] Configurando cifrado LUKS en $disk..."
        cryptsetup luksFormat --type luks2 \
            --cipher aes-xts-plain64 \
            --key-size 512 \
            --hash sha512 \
            --iter-time 5000 \
            --pbkdf argon2id \
            "/dev/$disk" || {
            print_msg "red" "[ERROR] Falló al configurar cifrado LUKS en $disk"
            return 1
        }
        
        verify_luks "/dev/$disk" || return 1
        
        cryptsetup open "/dev/$disk" "zfs_${disk}" || {
            print_msg "red" "[ERROR] Falló al abrir dispositivo cifrado $disk"
            return 1
        }
    done

    modprobe zfs || {
        print_msg "red" "[ERROR] Falló al cargar módulo ZFS"
        return 1
    }

    zpool create -f -o ashift=12 \
        -O compression=lz4 \
        -O acltype=posixacl \
        -O xattr=sa \
        -O relatime=on \
        -O normalization=formD \
        -O mountpoint=none \
        -O canmount=off \
        -O devices=off \
        -R "$INSTALL_ROOT" \
        "$ZPOOL_NAME" "${DISK_ZFS[@]/#/\/dev\/mapper\/zfs_}" || {
        print_msg "red" "[ERROR] Falló al crear pool ZFS"
        return 1
    }

    zfs create -o mountpoint=none "$ZPOOL_NAME/ROOT" || return 1
    zfs create -o mountpoint=/ -o canmount=noauto "$ZPOOL_NAME/ROOT/default" || return 1
    zfs create -o mountpoint=/home "$ZPOOL_NAME/home" || return 1
    zfs create -o mountpoint=/var "$ZPOOL_NAME/var" || return 1

    zfs set devices=off "$ZPOOL_NAME"
    zpool set bootfs="$ZPOOL_NAME/ROOT/default" "$ZPOOL_NAME"

    print_msg "green" "[✓] Configuración ZFS completada"
    return 0
}

create_mount_structure() {
    print_msg "blue" "[*] Creando estructura de directorios..."
    
    mkdir -p "$INSTALL_ROOT" || {
        print_msg "red" "[ERROR] No se pudo crear $INSTALL_ROOT"
        return 1
    }
    
    local mount_dirs=(
        "boot/efi" 
        "proc" 
        "sys" 
        "dev" 
        "dev/pts" 
        "run"
        "tmp"
        "etc/profile.d"
    )
    
    for dir in "${mount_dirs[@]}"; do
        mkdir -p "${INSTALL_ROOT}/${dir}" || {
            print_msg "red" "[ERROR] No se pudo crear ${INSTALL_ROOT}/${dir}"
            return 1
        }
        print_msg "green" "[✓] Directorio ${INSTALL_ROOT}/${dir} creado"
    done
    
    return 0
}

mount_filesystems() {
    print_msg "yellow" "[*] Montando sistemas de archivos..."
    
    if [ ${#DISK_ZFS[@]} -gt 0 ]; then
        zpool import -a -N -R "$INSTALL_ROOT" "$ZPOOL_NAME" || {
            print_msg "red" "[ERROR] Falló al importar pool ZFS"
            return 1
        }
        zfs mount "$ZPOOL_NAME/ROOT/default" || {
            print_msg "red" "[ERROR] Falló al montar ZFS root"
            return 1
        }
        zfs mount -a || {
            print_msg "yellow" "[ADVERTENCIA] Falló al montar todos los sistemas de archivos ZFS"
        }
    else
        mount "/dev/mapper/vg_arch-root" "$INSTALL_ROOT" || {
            print_msg "red" "[ERROR] Falló el montaje de la raíz en $INSTALL_ROOT"
            return 1
        }
    fi
    
    mkdir -p "${INSTALL_ROOT}/boot/efi" || {
        print_msg "red" "[ERROR] No se pudo crear ${INSTALL_ROOT}/boot/efi"
        return 1
    }
    
    if ! mount "/dev/${DISK_SYSTEM}1" "${INSTALL_ROOT}/boot/efi"; then
        print_msg "red" "[ERROR] Falló el montaje de EFI"
        return 1
    fi
    
    if ! swapon "/dev/mapper/vg_arch-swap"; then
        print_msg "red" "[ERROR] Falló al activar swap"
        return 1
    fi
    
    local virtual_mounts=(
        "proc:proc:proc,nosuid,nodev,noexec"
        "sys:sysfs:sysfs,nosuid,nodev,noexec,ro"
        "dev:devtmpfs:devtmpfs,mode=0755,nosuid"
        "dev/pts:devpts:devpts,nosuid,noexec,mode=0620,gid=5"
        "run:tmpfs:tmpfs,nosuid,nodev,mode=0755"
        "tmp:tmpfs:tmpfs,nosuid,nodev"
    )
    
    for mount_point in "${virtual_mounts[@]}"; do
        IFS=':' read -r target type options <<< "$mount_point"
        mkdir -p "${INSTALL_ROOT}/${target}" || {
            print_msg "yellow" "[ADVERTENCIA] No se pudo crear ${INSTALL_ROOT}/${target}"
            continue
        }
        
        if ! mount -t "$type" -o "$options" "$type" "${INSTALL_ROOT}/${target}"; then
            print_msg "yellow" "[ADVERTENCIA] Falló montaje de ${target} (tipo: ${type}, opciones: ${options})"
        else
            print_msg "green" "[✓] ${target} montado correctamente"
        fi
    done
    
    return 0
}

install_packages() {
    print_msg "blue" "[*] Instalando paquetes base..."
    
    if ! pacstrap "$INSTALL_ROOT" "${BASE_PACKAGES[@]}" --noconfirm --needed; then
        print_msg "red" "[ERROR] Falló la instalación de paquetes base"
        return 1
    fi

    # Configurar pacman en el sistema instalado
    arch-chroot "$INSTALL_ROOT" bash <<'CHROOT_PACMAN'
        sed -i -e '/^#Color$/s/^#//' \
               -e '/^#ParallelDownloads = 5/s/^#//' \
               -e '/^ParallelDownloads/a ILoveCandy' \
               -e '/^\[multilib\]/,/Include/ s/^#//' \
               -e '/^\[multilib-testing\]/,/Include/ s/^Include/#Include/' /etc/pacman.conf
        
        pacman -Sy || exit 1
CHROOT_PACMAN

    print_msg "blue" "[*] Instalando paquetes de audio..."
    arch-chroot "$INSTALL_ROOT" pacman -Sy --needed --noconfirm "${AUDIO_PACKAGES[@]}" || {
        print_msg "yellow" "[ADVERTENCIA] Algunos paquetes de audio no se instalaron correctamente"
        echo "Paquetes de audio fallidos:" >> "$FAILED_PKGS_FILE"
        for pkg in "${AUDIO_PACKAGES[@]}"; do
            arch-chroot "$INSTALL_ROOT" pacman -Q "$pkg" || echo "$pkg" >> "$FAILED_PKGS_FILE"
        done
    }

    # Configuración adicional para audio
    arch-chroot "$INSTALL_ROOT" bash <<'AUDIO_CONFIG'
        # Habilitar servicios de audio
        systemctl enable --now alsa-restore.service
        systemctl enable --now pulseaudio.socket
        
        # Agregar usuario al grupo audio
        usermod -aG audio "$USERNAME"
        
        # Configurar VolumeIcon para iniciar con el sistema
        mkdir -p /home/$USERNAME/.config/autostart
        cat > /home/$USERNAME/.config/autostart/volumeicon.desktop <<'EOL'
[Desktop Entry]
Name=Volume Icon
Comment=Volume control
Exec=volumeicon
Icon=multimedia-volume-control
Terminal=false
Type=Application
Categories=AudioVideo;Audio;Mixer;
StartupNotify=false
EOL
        chown -R $USERNAME:$USERNAME /home/$USERNAME/.config
AUDIO_CONFIG

    print_msg "green" "[✓] Paquetes instalados correctamente"
    return 0
}

configure_system() {
    print_msg "yellow" "[*] Configurando sistema..."
    
    if ! genfstab -U "$INSTALL_ROOT" >> "${INSTALL_ROOT}/etc/fstab"; then
        print_msg "red" "[ERROR] Falló al generar fstab"
        return 1
    fi
    
    # Obtener UUIDs para configuración de arranque
    local root_uuid=$(blkid -s UUID -o value "/dev/${DISK_SYSTEM}2")
    local crypt_root_uuid=$(blkid -s UUID -o value "/dev/mapper/vg_arch-root")

    # Configuración básica del sistema
    arch-chroot "$INSTALL_ROOT" bash <<EOF
        ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime || exit 1
        hwclock --systohc || exit 1
        echo "LANG=$LANG" > /etc/locale.conf || exit 1
        echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf || exit 1
        echo "$HOSTNAME" > /etc/hostname || exit 1
        sed -i '/en_US.UTF-8/s/^#//g' /etc/locale.gen || exit 1
        locale-gen || exit 1
EOF

    # Configuración de mkinitcpio
    arch-chroot "$INSTALL_ROOT" bash <<EOF
        if pacman -Q zfs-dkms &>/dev/null; then
            sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt lvm2 zfs filesystems fsck)/' /etc/mkinitcpio.conf
        else
            sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
        fi
        
        mkinitcpio -P || exit 1
EOF

    # Configuración de GRUB
    arch-chroot "$INSTALL_ROOT" bash <<EOF
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB || exit 1
        echo "GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=${root_uuid}:crypt-root root=UUID=${crypt_root_uuid}\"" >> /etc/default/grub || exit 1
        grub-mkconfig -o /boot/grub/grub.cfg || exit 1

        echo "root:$ROOT_PASSWORD" | chpasswd || exit 1
        useradd -m -G wheel,audio "$USERNAME" || exit 1
        echo "$USERNAME:$USER_PASSWORD" | chpasswd || exit 1
        echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers || exit 1
        
        systemctl enable NetworkManager || exit 1
EOF

    # Configuración para mostrar paquetes faltantes
    mkdir -p "${INSTALL_ROOT}/etc/profile.d"
    cat <<'FAILED_PKGS_NOTIFY' > "${INSTALL_ROOT}/etc/profile.d/show_failed_pkgs.sh"
#!/bin/sh
if [ -s "/var/log/failed_packages.log" ]; then
    echo -e "\n\033[1;31m■ PAQUETES FALTANTES ■\033[0m"
    echo "----------------------------"
    grep -v '^===' /var/log/failed_packages.log | sort | uniq
    
    if grep -q "zfs" /var/log/failed_packages.log; then
        echo -e "\n\033[1;33mPara instalar ZFS manualmente:\033[0m"
        echo "1. Instalar dependencias:"
        echo "   pacman -S --needed git base-devel linux-headers dkms"
        echo "2. Instalar desde AUR:"
        echo "   git clone https://aur.archlinux.org/zfs-dkms.git"
        echo "   cd zfs-dkms"
        echo "   makepkg -si"
        echo "3. Repetir para zfs-utils si es necesario"
        echo "4. Configurar hooks:"
        echo "   sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems fsck zfs)/' /etc/mkinitcpio.conf"
        echo "   mkinitcpio -P"
    fi
fi
FAILED_PKGS_NOTIFY

    chmod +x "${INSTALL_ROOT}/etc/profile.d/show_failed_pkgs.sh" || {
        print_msg "red" "[ERROR] No se pudo hacer ejecutable show_failed_pkgs.sh"
        return 1
    }
    
    print_msg "green" "[✓] Configuración del sistema completada"
    return 0
}

cleanup() {
    print_msg "yellow" "[*] Desmontando sistemas de archivos..."
    
    local mount_points=(
        "${INSTALL_ROOT}/proc"
        "${INSTALL_ROOT}/sys"
        "${INSTALL_ROOT}/dev/pts"
        "${INSTALL_ROOT}/dev"
        "${INSTALL_ROOT}/run"
        "${INSTALL_ROOT}/tmp"
        "${INSTALL_ROOT}/boot/efi"
        "$INSTALL_ROOT"
    )
    
    for point in "${mount_points[@]}"; do
        if mountpoint -q "$point"; then
            umount -R "$point" 2>/dev/null && print_msg "green" "[✓] $point desmontado" || 
            print_msg "yellow" "[ADVERTENCIA] No se pudo desmontar $point"
        fi
    done
    
    swapoff -a 2>/dev/null
    cryptsetup close crypt-root 2>/dev/null
    
    if [ ${#DISK_ZFS[@]} -gt 0 ]; then
        zpool export "$ZPOOL_NAME" 2>/dev/null
        for disk in "${DISK_ZFS[@]}"; do
            cryptsetup close "zfs_${disk}" 2>/dev/null
        done
    fi
    
    if [ -s "$FAILED_PKGS_FILE" ]; then
        print_msg "yellow" "Paquetes no instalados:"
        grep -v '^===' "$FAILED_PKGS_FILE" | sort | uniq
        print_msg "yellow" "Puedes instalarlos manualmente después del reinicio"
    fi
    
    print_msg "green" "[✓] ¡Instalación completada! Reiniciando en 10s..."
    sleep 10
    reboot
}

main() {
    clear
    print_msg "green" "================================================"
    print_msg "green" "  INSTALADOR DE ARCH LINUX CON LUKS + ZFS"
    print_msg "green" "  CONFIGURACIÓN PERSONALIZADA PARA $USERNAME"
    print_msg "green" "================================================"
    
    init_logs
    check_root
    
    # Flujo principal de instalación
    if configure_pacman && \
       setup_disks && \
       setup_zfs && \
       create_mount_structure && \
       mount_filesystems && \
       install_packages && \
       configure_system; then
        cleanup
    else
        print_msg "red" "[ERROR] La instalación ha fallado. Verifica $LOG_FILE para más detalles."
        exit 1
    fi
}

main "$@"
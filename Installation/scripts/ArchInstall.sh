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

# Lista de paquetes base (sin ZFS inicialmente)
BASE_PACKAGES=(
    "base" "linux" "linux-firmware" "sof-firmware"
    "base-devel" "grub" "efibootmgr" "nano" "vim"
    "networkmanager" "lvm2" "cryptsetup"
)

# Paquetes ZFS (se instalarán después si es necesario)
ZFS_PACKAGES=(
    "zfs-dkms"
    "zfs-utils"
)

# Paquetes de audio
AUDIO_PACKAGES=(
    "alsa-utils" "alsa-firmware" "alsa-plugins" "alsa-lib"
    "alsa-tools" "alsa-firmware-loaders"
    "alsamixergui" "volumeicon-alsa"
    "pulseaudio" "pulseaudio-alsa" "pulseaudio-bluetooth"
    "pavucontrol" "paprefs"
    "jack2" "qjackctl"
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
        error)   printf "${RED}[ERROR] %s${NC}\n" "$2" ;;
        success) printf "${GREEN}[✓] %s${NC}\n" "$2" ;;
        warn)    printf "${YELLOW}[!] %s${NC}\n" "$2" ;;
        info)    printf "${BLUE}[*] %s${NC}\n" "$2" ;;
        *)       printf "%s\n" "$2" ;;
    esac
}

check_root() {
    [ "$(id -u)" -ne 0 ] && print_msg "error" "Debes ejecutar como root. Usa 'sudo -i'" && exit 1
}

verify_luks() {
    local device=$1
    print_msg "info" "Verificando configuración LUKS en $device..."
    
    if ! cryptsetup isLuks "$device"; then
        print_msg "error" "$device no es un dispositivo LUKS válido"
        return 1
    fi
    
    cryptsetup luksDump "$device" || {
        print_msg "error" "Fallo al verificar $device"
        return 1
    }
    
    print_msg "success" "Verificación LUKS completada para $device"
    return 0
}

install_zfs_modules() {
    print_msg "info" "Instalando módulos ZFS en el sistema live..."
    
    # Primero intentar con archzfs-dkms que es más compatible
    if ! pacman -Sy --needed --noconfirm archzfs-dkms; then
        print_msg "warn" "No se pudo instalar archzfs-dkms desde repositorios, intentando desde AUR"
        
        # Instalar yay si no está disponible
        if ! command -v yay >/dev/null; then
            pacman -Sy --needed --noconfirm git base-devel
            sudo -u nobody git clone https://aur.archlinux.org/yay.git /tmp/yay
            (cd /tmp/yay && sudo -u nobody makepkg -si --noconfirm) || {
                print_msg "error" "Fallo al instalar yay"
                return 1
            }
        fi
        
        sudo -u nobody yay -Sy --noconfirm archzfs-dkms || {
            print_msg "error" "Fallo al instalar archzfs-dkms desde AUR"
            return 1
        }
    fi
    
    # Cargar módulo ZFS
    modprobe zfs || {
        print_msg "error" "Fallo al cargar módulo ZFS"
        return 1
    }
    
    print_msg "success" "Módulos ZFS instalados y cargados correctamente"
    return 0
}

configure_pacman() {
    print_msg "info" "Configurando pacman..."
    
    sed -i -e '/^#Color$/s/^#//' \
           -e '/^#ParallelDownloads = 5/s/^#//' \
           -e '/^ParallelDownloads/a ILoveCandy' \
           -e '/^\[multilib\]/,/Include/ s/^#//' \
           -e '/^\[multilib-testing\]/,/Include/ s/^Include/#Include/' /etc/pacman.conf

    reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
    pacman -Sy || {
        print_msg "error" "Fallo al sincronizar bases de datos"
        return 1
    }
    
    print_msg "success" "Configuración de pacman completada"
    return 0
}

setup_disks() {
    print_msg "info" "Configurando discos..."
    lsblk -d -o NAME,SIZE,MODEL
    
    read -p "Selecciona disco para sistema (ej: sda): " DISK_SYSTEM
    read -p "Selecciona discos para ZFS (separados por espacios, dejar vacío para omitir): " -a DISK_ZFS

    # Validar discos
    [ ! -b "/dev/$DISK_SYSTEM" ] && print_msg "error" "Disco $DISK_SYSTEM no válido" && return 1
    for disk in "${DISK_ZFS[@]}"; do
        [ ! -b "/dev/$disk" ] && print_msg "error" "Disco $disk no válido" && return 1
    done

    # Limpiar discos
    print_msg "info" "Limpiando discos..."
    for disk in "$DISK_SYSTEM" "${DISK_ZFS[@]}"; do
        wipefs -a "/dev/$disk"
        dd if=/dev/zero of="/dev/$disk" bs=1M count=100
    done

    # Particionar disco principal
    print_msg "info" "Creando particiones en $DISK_SYSTEM..."
    parted -s "/dev/$DISK_SYSTEM" mklabel gpt
    parted -s "/dev/$DISK_SYSTEM" mkpart primary fat32 1MiB 513MiB
    parted -s "/dev/$DISK_SYSTEM" set 1 esp on
    parted -s "/dev/$DISK_SYSTEM" mkpart primary ext4 513MiB 100%

    # Configurar cifrado LUKS
    print_msg "info" "Configurando cifrado LUKS en ${DISK_SYSTEM}2..."
    cryptsetup luksFormat --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha512 \
        --iter-time 5000 \
        --pbkdf argon2id \
        "/dev/${DISK_SYSTEM}2" || {
        print_msg "error" "Fallo al configurar cifrado LUKS"
        return 1
    }

    # Verificar configuración LUKS
    verify_luks "/dev/${DISK_SYSTEM}2" || return 1

    # Abrir dispositivo cifrado
    print_msg "info" "Abriendo dispositivo cifrado..."
    cryptsetup open "/dev/${DISK_SYSTEM}2" cryptroot || {
        print_msg "error" "Fallo al abrir dispositivo cifrado"
        return 1
    }

    # Configurar LVM
    print_msg "info" "Configurando LVM..."
    pvcreate "/dev/mapper/cryptroot" || return 1
    vgcreate vg0 "/dev/mapper/cryptroot" || return 1
    lvcreate -L 8G vg0 -n swap || return 1
    lvcreate -l +100%FREE vg0 -n root || return 1

    # Formatear particiones
    print_msg "info" "Formateando particiones..."
    mkfs.vfat -F32 "/dev/${DISK_SYSTEM}1" || return 1
    mkswap "/dev/mapper/vg0-swap" || return 1
    mkfs.ext4 "/dev/mapper/vg0-root" || return 1

    return 0
}

setup_zfs() {
    [ ${#DISK_ZFS[@]} -eq 0 ] && return 0

    # Instalar módulos ZFS primero
    install_zfs_modules || return 1

    print_msg "info" "Configurando ZFS en discos: ${DISK_ZFS[*]}..."
    
    # Configurar cifrado para discos ZFS
    for disk in "${DISK_ZFS[@]}"; do
        print_msg "info" "Configurando cifrado LUKS en $disk..."
        cryptsetup luksFormat --type luks2 \
            --cipher aes-xts-plain64 \
            --key-size 512 \
            --hash sha512 \
            --iter-time 5000 \
            --pbkdf argon2id \
            "/dev/$disk" || {
            print_msg "error" "Fallo al configurar cifrado LUKS en $disk"
            return 1
        }
        
        verify_luks "/dev/$disk" || return 1
        
        cryptsetup open "/dev/$disk" "zfs_${disk}" || {
            print_msg "error" "Fallo al abrir dispositivo cifrado $disk"
            return 1
        }
    done

    # Crear pool ZFS
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
        print_msg "error" "Fallo al crear pool ZFS"
        return 1
    }

    # Crear sistemas de archivos ZFS
    zfs create -o mountpoint=none "$ZPOOL_NAME/ROOT" || return 1
    zfs create -o mountpoint=/ -o canmount=noauto "$ZPOOL_NAME/ROOT/default" || return 1
    zfs create -o mountpoint=/home "$ZPOOL_NAME/home" || return 1
    zfs create -o mountpoint=/var "$ZPOOL_NAME/var" || return 1

    # Configurar propiedades
    zfs set devices=off "$ZPOOL_NAME"
    zpool set bootfs="$ZPOOL_NAME/ROOT/default" "$ZPOOL_NAME"

    print_msg "success" "Configuración ZFS completada"
    return 0
}

create_mount_structure() {
    print_msg "info" "Creando estructura de directorios..."
    
    mkdir -p "$INSTALL_ROOT" || {
        print_msg "error" "No se pudo crear $INSTALL_ROOT"
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
            print_msg "error" "No se pudo crear ${INSTALL_ROOT}/${dir}"
            return 1
        }
    done
    
    return 0
}

mount_filesystems() {
    print_msg "info" "Montando sistemas de archivos..."
    
    # Montar partición raíz
    if [ ${#DISK_ZFS[@]} -gt 0 ]; then
        # Para ZFS
        zpool import -a -N -R "$INSTALL_ROOT" "$ZPOOL_NAME" || {
            print_msg "error" "Fallo al importar pool ZFS"
            return 1
        }
        zfs mount "$ZPOOL_NAME/ROOT/default" || {
            print_msg "error" "Fallo al montar ZFS root"
            return 1
        }
        zfs mount -a || {
            print_msg "warn" "Fallo al montar todos los sistemas de archivos ZFS"
        }
    else
        # Para LVM estándar
        mount "/dev/mapper/vg0-root" "$INSTALL_ROOT" || {
            print_msg "error" "Fallo el montaje de la raíz en $INSTALL_ROOT"
            return 1
        }
    fi

    # Montar partición EFI
    mkdir -p "${INSTALL_ROOT}/boot/efi"
    mount "/dev/${DISK_SYSTEM}1" "${INSTALL_ROOT}/boot/efi" || {
        print_msg "error" "Fallo el montaje de EFI"
        return 1
    }

    # Activar swap
    swapon "/dev/mapper/vg0-swap" || {
        print_msg "error" "Fallo al activar swap"
        return 1
    }

    # Montar sistemas de archivos virtuales
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
        mkdir -p "${INSTALL_ROOT}/${target}"
        mount -t "$type" -o "$options" "$type" "${INSTALL_ROOT}/${target}" || 
            print_msg "warn" "Fallo al montar ${target}"
    done

    print_msg "success" "Montaje completado"
    return 0
}

install_packages() {
    print_msg "info" "Instalando sistema base..."
    
    # Instalar paquetes base (sin ZFS inicialmente)
    pacstrap "$INSTALL_ROOT" "${BASE_PACKAGES[@]}" --noconfirm --needed || {
        print_msg "error" "Fallo al instalar paquetes base"
        return 1
    }

    # Si hay discos ZFS, instalar paquetes ZFS
    if [ ${#DISK_ZFS[@]} -gt 0 ]; then
        print_msg "info" "Instalando paquetes ZFS..."
        arch-chroot "$INSTALL_ROOT" pacman -Sy --needed --noconfirm "${ZFS_PACKAGES[@]}" || {
            print_msg "warn" "Algunos paquetes ZFS no se instalaron correctamente"
            echo "Paquetes ZFS fallidos:" >> "$FAILED_PKGS_FILE"
            for pkg in "${ZFS_PACKAGES[@]}"; do
                arch-chroot "$INSTALL_ROOT" pacman -Q "$pkg" || echo "$pkg" >> "$FAILED_PKGS_FILE"
            done
        }
    fi

    # Instalar paquetes de audio
    print_msg "info" "Instalando paquetes de audio..."
    arch-chroot "$INSTALL_ROOT" pacman -Sy --needed --noconfirm "${AUDIO_PACKAGES[@]}" || {
        print_msg "warn" "Algunos paquetes de audio no se instalaron correctamente"
        echo "Paquetes de audio fallidos:" >> "$FAILED_PKGS_FILE"
        for pkg in "${AUDIO_PACKAGES[@]}"; do
            arch-chroot "$INSTALL_ROOT" pacman -Q "$pkg" || echo "$pkg" >> "$FAILED_PKGS_FILE"
        done
    }

    print_msg "success" "Instalación de paquetes completada"
    return 0
}

configure_system() {
    print_msg "info" "Configurando sistema..."
    
    # Generar fstab
    genfstab -U "$INSTALL_ROOT" >> "${INSTALL_ROOT}/etc/fstab" || {
        print_msg "error" "Fallo al generar fstab"
        return 1
    }

    # Configurar sistema
    arch-chroot "$INSTALL_ROOT" bash <<EOF
        # Configuración básica
        ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
        hwclock --systohc
        echo "LANG=$LANG" > /etc/locale.conf
        echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
        echo "$HOSTNAME" > /etc/hostname
        sed -i '/en_US.UTF-8/s/^#//g' /etc/locale.gen
        locale-gen

        # Configurar mkinitcpio
        HOOKS="base udev autodetect modconf kms keyboard keymap consolefont block encrypt lvm2 filesystems fsck"
        [ ${#DISK_ZFS[@]} -gt 0 ] && HOOKS="\$HOOKS zfs"
        sed -i "s/^HOOKS=.*/HOOKS=(\$HOOKS)/" /etc/mkinitcpio.conf
        mkinitcpio -P

        # Configurar GRUB
        UUID=\$(blkid -s UUID -o value /dev/${DISK_SYSTEM}2)
        ROOT_UUID=\$(blkid -s UUID -o value /dev/mapper/vg0-root)
        echo "GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=\$UUID:cryptroot root=UUID=\$ROOT_UUID\"" >> /etc/default/grub
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
        grub-mkconfig -o /boot/grub/grub.cfg

        # Configurar usuarios
        echo "root:$ROOT_PASSWORD" | chpasswd
        useradd -m -G wheel,audio "$USERNAME"
        echo "$USERNAME:$USER_PASSWORD" | chpasswd
        echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

        # Habilitar servicios
        systemctl enable NetworkManager
        
        # Configurar audio
        systemctl enable --now alsa-restore.service
        systemctl enable --now pulseaudio.socket
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
        print_msg "error" "No se pudo hacer ejecutable show_failed_pkgs.sh"
        return 1
    }
    
    print_msg "success" "Configuración completada"
    return 0
}

cleanup() {
    print_msg "info" "Limpiando..."
    
    # Desmontar todo
    umount -R "$INSTALL_ROOT" 2>/dev/null
    swapoff -a 2>/dev/null
    [ ${#DISK_ZFS[@]} -gt 0 ] && zpool export "$ZPOOL_NAME"
    cryptsetup close cryptroot 2>/dev/null
    
    # Cerrar dispositivos ZFS cifrados
    for disk in "${DISK_ZFS[@]}"; do
        cryptsetup close "zfs_${disk}" 2>/dev/null
    done
    
    print_msg "success" "¡Instalación completada! Reiniciando en 10s..."
    sleep 10
    reboot
}

main() {
    clear
    print_msg "info" "================================================"
    print_msg "info" "  INSTALADOR COMPLETO DE ARCH LINUX"
    print_msg "info" "  CON SOPORTE PARA LUKS, ZFS Y AUDIO"
    print_msg "info" "================================================"
    
    init_logs
    check_root
    
    # Flujo de instalación
    if configure_pacman && \
       setup_disks && \
       setup_zfs && \
       create_mount_structure && \
       mount_filesystems && \
       install_packages && \
       configure_system; then
        cleanup
    else
        print_msg "error" "La instalación ha fallado. Verifica $LOG_FILE para más detalles."
        exit 1
    fi
}

main "$@"
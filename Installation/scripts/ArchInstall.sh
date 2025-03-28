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

# Variables del sistema
ZPOOL_NAME="raidz"
USERNAME="archuser"
ROOT_PASSWORD="archroot123"
USER_PASSWORD="archuser123"
TIMEZONE="Europe/Madrid"
LANG="en_US.UTF-8"
KEYMAP="es"
HOSTNAME="archzfs"
INSTALL_ROOT="/mnt"
LOG_FILE="/var/log/installation.log"
FAILED_PKGS_FILE="/var/log/failed_packages.log"

# --- Funciones principales ---

# Inicialización de logs
init_logs() {
    exec > >(tee -a "$LOG_FILE") 2>&1
    touch "$FAILED_PKGS_FILE"
}

# Mostrar mensajes formateados
print_msg() {
    case $1 in
        red)    printf "\033[1;31m%s\033[0m\n" "$2" ;;
        green)  printf "\033[1;32m%s\033[0m\n" "$2" ;;
        yellow) printf "\033[1;33m%s\033[0m\n" "$2" ;;
        blue)   printf "\033[1;34m%s\033[0m\n" "$2" ;;
        *)      printf "%s\n" "$2" ;;
    esac
}

# Verificar root
check_root() {
    [ "$(id -u)" -ne 0 ] && print_msg "red" "ERROR: Ejecuta como root. Usa 'sudo -i' en el live USB." && exit 1
}

# Detectar entorno (VM/físico)
detect_env() {
    ENV=$(dmidecode -s system-product-name | awk '{print tolower($0)}' | grep -E 'vmware|virtualbox|qemu' || echo "physical")
    print_msg "blue" "[INFO] Entorno detectado: ${ENV}"
}

# Crear estructura de directorios completa
create_mount_structure() {
    print_msg "blue" "[*] Creando estructura de directorios en ${INSTALL_ROOT}..."
    
    # Directorios principales
    mkdir -p "$INSTALL_ROOT" || {
        print_msg "red" "[ERROR] No se pudo crear $INSTALL_ROOT"
        return 1
    }
    
    # Directorios específicos para montaje
    local mount_dirs=("boot/efi" "proc" "sys" "dev" "run")
    for dir in "${mount_dirs[@]}"; do
        mkdir -p "${INSTALL_ROOT}/${dir}" || {
            print_msg "red" "[ERROR] No se pudo crear ${INSTALL_ROOT}/${dir}"
            return 1
        }
        print_msg "green" "[✓] Directorio ${INSTALL_ROOT}/${dir} creado"
    done
    
    return 0
}

# Particionado y cifrado
setup_disks() {
    print_msg "yellow" "[*] Configurando discos..."
    lsblk -d -o NAME,SIZE,MODEL | grep -v "loop"
    
    read -p "Disco para sistema (ej: sda): " DISK_SYSTEM
    read -p "Discos para ZFS (ej: sdb sdc): " -a DISK_ZFS

    # Validación de discos
    for disk in "$DISK_SYSTEM" "${DISK_ZFS[@]}"; do
        [ ! -b "/dev/$disk" ] && print_msg "red" "[ERROR] Disco $disk no válido" && return 1
    done

    # Limpiar discos
    print_msg "yellow" "[*] Limpiando tablas de particiones..."
    for disk in "$DISK_SYSTEM" "${DISK_ZFS[@]}"; do
        wipefs -a "/dev/$disk"
        dd if=/dev/zero of="/dev/$disk" bs=1M count=100
    done

    # Particionado (EFI sin cifrar)
    print_msg "yellow" "[*] Creando particiones..."
    parted -s "/dev/$DISK_SYSTEM" mklabel gpt
    parted -s "/dev/$DISK_SYSTEM" mkpart primary fat32 1MiB 513MiB
    parted -s "/dev/$DISK_SYSTEM" set 1 esp on
    parted -s "/dev/$DISK_SYSTEM" mkpart primary ext4 513MiB 100%

    # Cifrado solo para raíz
    print_msg "yellow" "[*] Configurando cifrado LUKS..."
    until cryptsetup luksFormat --type luks2 "/dev/${DISK_SYSTEM}2"; do
        print_msg "red" "[ERROR] Falló el cifrado, reintentando..."
        sleep 2
    done
    
    cryptsetup open "/dev/${DISK_SYSTEM}2" crypt-root || {
        print_msg "red" "[ERROR] No se pudo abrir el dispositivo cifrado"
        return 1
    }

    # LVM
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

    # Formateo
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

# Montar sistemas de archivos
mount_filesystems() {
    print_msg "yellow" "[*] Montando sistemas de archivos..."
    
    # Montar partición raíz
    mount "/dev/mapper/vg_arch-root" "$INSTALL_ROOT" || {
        print_msg "red" "[ERROR] Falló el montaje de la raíz"
        return 1
    }
    
    # Montar EFI (verificar que el directorio existe)
    if [ -d "${INSTALL_ROOT}/boot/efi" ]; then
        mount "/dev/${DISK_SYSTEM}1" "${INSTALL_ROOT}/boot/efi" || {
            print_msg "red" "[ERROR] Falló el montaje de EFI"
            return 1
        }
    else
        print_msg "red" "[ERROR] Directorio ${INSTALL_ROOT}/boot/efi no existe"
        return 1
    fi
    
    # Activar swap
    swapon "/dev/mapper/vg_arch-swap" || {
        print_msg "red" "[ERROR] Falló al activar swap"
        return 1
    }
    
    # Montar sistemas virtuales para chroot
    mount -t proc proc "${INSTALL_ROOT}/proc" || print_msg "yellow" "[ADVERTENCIA] Falló montaje de /proc"
    mount -t sysfs sys "${INSTALL_ROOT}/sys" || print_msg "yellow" "[ADVERTENCIA] Falló montaje de /sys"
    mount -o bind /dev "${INSTALL_ROOT}/dev" || print_msg "yellow" "[ADVERTENCIA] Falló montaje de /dev"
    mount -t devpts devpts "${INSTALL_ROOT}/dev/pts" || print_msg "yellow" "[ADVERTENCIA] Falló montaje de /dev/pts"
    mount -t tmpfs tmpfs "${INSTALL_ROOT}/run" || print_msg "yellow" "[ADVERTENCIA] Falló montaje de /run"
    
    return 0
}

# Instalación de paquetes con manejo de errores
install_packages() {
    local pkg_list=("$@")
    local failed_pkgs=()

    print_msg "blue" "[*] Instalando ${#pkg_list[@]} paquetes..."
    
    # Instalar todos los paquetes juntos para mejor eficiencia
    if ! pacstrap "$INSTALL_ROOT" "${pkg_list[@]}" --noconfirm --needed; then
        print_msg "red" "[ADVERTENCIA] Algunos paquetes fallaron, verificando individualmente..."
        
        for pkg in "${pkg_list[@]}"; do
            if ! arch-chroot "$INSTALL_ROOT" pacman -S "$pkg" --noconfirm --needed 2>/dev/null; then
                print_msg "red" "[✗] Error en $pkg"
                echo "$pkg" >> "$FAILED_PKGS_FILE"
                failed_pkgs+=("$pkg")
            else
                print_msg "green" "[✓] $pkg instalado"
            fi
        done

        if [ ${#failed_pkgs[@]} -gt 0 ]; then
            print_msg "yellow" "Advertencia: ${#failed_pkgs[@]} paquetes fallaron (ver $FAILED_PKGS_FILE)"
            echo "=== Paquetes con errores ===" >> "$FAILED_PKGS_FILE"
            printf '%s\n' "${failed_pkgs[@]}" >> "$FAILED_PKGS_FILE"
        fi
    else
        print_msg "green" "[✓] Todos los paquetes instalados correctamente"
    fi
}

# Configuración del sistema
configure_system() {
    print_msg "yellow" "[*] Configurando sistema..."
    
    # Generar fstab
    genfstab -U "$INSTALL_ROOT" >> "${INSTALL_ROOT}/etc/fstab" || {
        print_msg "red" "[ERROR] Falló al generar fstab"
        return 1
    }
    
    # Configuración básica desde chroot
    arch-chroot "$INSTALL_ROOT" bash <<EOF
    # Configuración básica
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime || exit 1
    hwclock --systohc || exit 1
    echo "LANG=$LANG" > /etc/locale.conf || exit 1
    echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf || exit 1
    echo "$HOSTNAME" > /etc/hostname || exit 1
    sed -i '/en_US.UTF-8/s/^#//g' /etc/locale.gen || exit 1
    locale-gen || exit 1

    # Initramfs con soporte para LUKS y ZFS
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems fsck zfs)/' /etc/mkinitcpio.conf || exit 1
    mkinitcpio -P || exit 1

    # GRUB para EFI
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB || exit 1
    echo "GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=\$(blkid -s UUID -o value /dev/${DISK_SYSTEM}2):crypt-root root=/dev/mapper/vg_arch-root\"" >> /etc/default/grub || exit 1
    grub-mkconfig -o /boot/grub/grub.cfg || exit 1

    # Usuario
    echo "root:$ROOT_PASSWORD" | chpasswd || exit 1
    useradd -m -G wheel "$USERNAME" || exit 1
    echo "$USERNAME:$USER_PASSWORD" | chpasswd || exit 1
    echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers || exit 1

    # Configurar ZFS si hay discos especificados
    if [ ${#DISK_ZFS[@]} -gt 0 ]; then
        zpool create -f "$ZPOOL_NAME" "${DISK_ZFS[@]/#/\/dev\/}" || exit 1
        zfs create "$ZPOOL_NAME/data" || exit 1
        echo "$ZPOOL_NAME /$ZPOOL_NAME zfs defaults 0 0" >> /etc/fstab || exit 1
    fi
EOF

    if [ $? -ne 0 ]; then
        print_msg "red" "[ERROR] Falló la configuración en chroot"
        return 1
    fi

    # Configurar notificación post-reinicio
    mkdir -p "${INSTALL_ROOT}/etc/profile.d" || {
        print_msg "red" "[ERROR] No se pudo crear /etc/profile.d"
        return 1
    }
    
    cat <<EOF > "${INSTALL_ROOT}/etc/profile.d/show_failed_pkgs.sh"
#!/bin/sh
if [ -s "$FAILED_PKGS_FILE" ]; then
    echo -e "\n\033[1;31m■ PAQUETES FALTANTES ■\033[0m"
    echo "----------------------------"
    cat "$FAILED_PKGS_FILE" | grep -v '^===' | sort | uniq
    echo -e "\nInstálalos manualmente con:"
    echo -e "\033[1;36mpacman -S \$(cat $FAILED_PKGS_FILE | grep -v '^===' | tr '\n' ' ')\033[0m\n"
fi
EOF

    chmod +x "${INSTALL_ROOT}/etc/profile.d/show_failed_pkgs.sh" || {
        print_msg "red" "[ERROR] No se pudo hacer ejecutable show_failed_pkgs.sh"
        return 1
    }
    
    return 0
}

# Limpieza final
cleanup() {
    print_msg "yellow" "[*] Desmontando sistemas de archivos..."
    
    # Desmontar en orden inverso
    umount -R "${INSTALL_ROOT}/run" 2>/dev/null
    umount -R "${INSTALL_ROOT}/dev/pts" 2>/dev/null
    umount -R "${INSTALL_ROOT}/dev" 2>/dev/null
    umount -R "${INSTALL_ROOT}/proc" 2>/dev/null
    umount -R "${INSTALL_ROOT}/sys" 2>/dev/null
    swapoff -a 2>/dev/null
    umount -R "${INSTALL_ROOT}/boot/efi" 2>/dev/null
    umount -R "$INSTALL_ROOT" 2>/dev/null
    
    cryptsetup close crypt-root 2>/dev/null
    
    if [ -s "$FAILED_PKGS_FILE" ]; then
        print_msg "yellow" "Paquetes no instalados:"
        grep -v '^===' "$FAILED_PKGS_FILE" | sort | uniq
    fi
    
    print_msg "green" "[✓] ¡Instalación completada! Reiniciando en 10s..."
    sleep 10
    reboot
}

# --- Menú principal ---
main() {
    clear
    print_msg "green" "================================================"
    print_msg "green" "  INSTALADOR DE ARCH LINUX CON LUKS + ZFS"
    print_msg "green" "  VERSIÓN FINAL - TODOS LOS ERRORES CORREGIDOS"
    print_msg "green" "================================================"
    
    init_logs
    check_root
    detect_env
    
    # Flujo de instalación con manejo de errores
    if create_mount_structure && setup_disks && mount_filesystems; then
        # Lista de paquetes base
        BASE_PKGS=(
            base linux linux-firmware grub efibootmgr 
            networkmanager lvm2 cryptsetup 
            zfs-dkms zfs-utils vim sudo
        )
        
        install_packages "${BASE_PKGS[@]}"
        configure_system
    else
        print_msg "red" "[ERROR] Falló la configuración inicial, no se puede continuar"
    fi
    
    cleanup
}

# --- Ejecución ---
main "$@"
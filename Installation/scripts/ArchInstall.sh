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
# ==================================================

# --- Configuración inicial ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Variables del sistema
ZPOOL_NAME="raidz"
USERNAME="LaraCanBurn"
ROOT_PASSWORD="archroot"
USER_PASSWORD="laracanburn"
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

    # Particionado (EFI sin cifrar)
    parted -s /dev/$DISK_SYSTEM mklabel gpt
    parted -s /dev/$DISK_SYSTEM mkpart primary fat32 1MiB 513MiB
    parted -s /dev/$DISK_SYSTEM set 1 esp on
    parted -s /dev/$DISK_SYSTEM mkpart primary ext4 513MiB 100%

    # Cifrado solo para raíz
    print_msg "yellow" "[*] Configurando cifrado LUKS..."
    cryptsetup luksFormat --type luks2 /dev/${DISK_SYSTEM}2
    cryptsetup open /dev/${DISK_SYSTEM}2 crypt-root

    # LVM
    pvcreate /dev/mapper/crypt-root
    vgcreate vg_arch /dev/mapper/crypt-root
    lvcreate -L 8G vg_arch -n swap
    lvcreate -l +100%FREE vg_arch -n root

    # Formateo
    mkfs.vfat -F32 /dev/${DISK_SYSTEM}1  # EFI sin cifrar
    mkswap /dev/mapper/vg_arch-swap
    mkfs.ext4 /dev/mapper/vg_arch-root

    # Montaje
    mount /dev/mapper/vg_arch-root "$INSTALL_ROOT"
    mkdir -p "$INSTALL_ROOT/boot/efi"
    mount /dev/${DISK_SYSTEM}1 "$INSTALL_ROOT/boot/efi"
    swapon /dev/mapper/vg_arch-swap
}

# Instalación de paquetes con manejo de errores
install_packages() {
    local pkg_list=("$@")
    local failed_pkgs=()

    print_msg "blue" "[*] Instalando ${#pkg_list[@]} paquetes..."
    
    for pkg in "${pkg_list[@]}"; do
        print_msg "blue" "Instalando $pkg..."
        if pacman -S --noconfirm --needed "$pkg" 2>/dev/null; then
            print_msg "green" "[✓] $pkg instalado"
        else
            print_msg "red" "[✗] Error en $pkg"
            echo "$pkg" >> "$FAILED_PKGS_FILE"
            failed_pkgs+=("$pkg")
        fi
    done

    if [ ${#failed_pkgs[@]} -gt 0 ]; then
        print_msg "yellow" "Advertencia: ${#failed_pkgs[@]} paquetes fallaron (ver $FAILED_PKGS_FILE)"
        echo "=== Paquetes con errores ===" >> "$FAILED_PKGS_FILE"
        printf '%s\n' "${failed_pkgs[@]}" >> "$FAILED_PKGS_FILE"
    fi
}

# Configuración del sistema
configure_system() {
    print_msg "yellow" "[*] Configurando sistema..."
    
    # Paquetes base + ZFS
    BASE_PKGS=(
        "base" "base-devel" "linux" "linux-firmware"
        "grub" "efibootmgr" "networkmanager" "lvm2"
        "cryptsetup" "zfs-dkms" "zfs-utils" "vim" "sudo"
    )
    
    arch-chroot "$INSTALL_ROOT" bash <<EOF
    # Configuración básica
    ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
    hwclock --systohc
    echo "LANG=$LANG" > /etc/locale.conf
    echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
    echo "$HOSTNAME" > /etc/hostname
    sed -i '/en_US.UTF-8/s/^#//g' /etc/locale.gen
    locale-gen

    # Initramfs con soporte para LUKS y ZFS
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems fsck zfs)/' /etc/mkinitcpio.conf
    mkinitcpio -P

    # GRUB para EFI
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    echo "GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=\$(blkid -s UUID -o value /dev/${DISK_SYSTEM}2):crypt-root root=/dev/mapper/vg_arch-root\"" >> /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg

    # Usuario
    echo "root:$ROOT_PASSWORD" | chpasswd
    useradd -m -G wheel $USERNAME
    echo "$USERNAME:$USER_PASSWORD" | chpasswd
    echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

    # Configurar ZFS si hay discos especificados
    if [ ${#DISK_ZFS[@]} -gt 0 ]; then
        zpool create -f $ZPOOL_NAME ${DISK_ZFS[@]/#/\/dev\/}
        zfs create $ZPOOL_NAME/data
        echo "$ZPOOL_NAME /$ZPOOL_NAME zfs defaults 0 0" >> /etc/fstab
    fi
EOF

    # Configurar notificación post-reinicio
    cat <<EOF > "$INSTALL_ROOT/etc/profile.d/show_failed_pkgs.sh"
#!/bin/sh
if [ -s "$FAILED_PKGS_FILE" ]; then
    echo -e "\n\033[1;31m■ PAQUETES FALTANTES ■\033[0m"
    echo "----------------------------"
    cat "$FAILED_PKGS_FILE" | grep -v '^===' | sort | uniq
    echo -e "\nInstálalos manualmente con:"
    echo -e "\033[1;36mpacman -S \$(cat $FAILED_PKGS_FILE | grep -v '^===' | tr '\n' ' ')\033[0m\n"
fi
EOF

    chmod +x "$INSTALL_ROOT/etc/profile.d/show_failed_pkgs.sh"
}

# Backup de cabeceras LUKS
backup_luks() {
    read -p "¿Hacer backup de cabeceras LUKS? [s/N]: " choice
    [[ "$choice" =~ [sS] ]] || return 0

    print_msg "yellow" "[*] Buscando dispositivos USB..."
    USB=$(lsblk -d -o NAME,TRAN | grep usb | awk '{print "/dev/"$1}')
    [ -z "$USB" ] && print_msg "red" "[ERROR] No hay USBs detectados" && return 1

    mkdir -p /mnt/usb_backup
    mount ${USB}1 /mnt/usb_backup || mount $USB /mnt/usb_backup || return 1

    BACKUP_DIR="/mnt/usb_backup/luks_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"

    print_msg "yellow" "[*] Creando backup en $BACKUP_DIR..."
    cryptsetup luksHeaderBackup "/dev/${DISK_SYSTEM}2" --header-backup-file "$BACKUP_DIR/luks_header.img"
    dd if=/dev/urandom bs=1 count=256 of="$BACKUP_DIR/luks_keyfile.bin"
    chmod 600 "$BACKUP_DIR/luks_keyfile.bin"
    cryptsetup luksAddKey "/dev/${DISK_SYSTEM}2" "$BACKUP_DIR/luks_keyfile.bin"

    umount /mnt/usb_backup
    print_msg "green" "[✓] Backup completado en USB"
}

# Limpieza final
cleanup() {
    print_msg "yellow" "[*] Limpiando..."
    umount -R "$INSTALL_ROOT"
    swapoff -a
    cryptsetup close crypt-root
    
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
    print_msg "green" "================================================"
    
    init_logs
    check_root
    detect_env
    
    # Flujo de instalación
    setup_disks && \
    install_packages "${BASE_PKGS[@]}" && \
    configure_system && \
    backup_luks && \
    cleanup
}

# --- Ejecución ---
main "$@"
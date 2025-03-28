#!/bin/bash

# ==============================================
# INSTALADOR AUTOMÁTICO DE ARCH LINUX CON LUKS + ZFS
# Versión 2.3 - Soporte para VMware, VirtualBox y Hardware Físico
# Basado en la documentación original del usuario
# Con reinicios controlados y continuación automática
# Mejorado el desmontaje pre-reinicio
# EFI sin cifrado + Unico reinicio tras finalizar

# ==============================================
#!/bin/bash

# --- Configuración ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ZPOOL_NAME="raidz"
USERNAME="ArchLinux"
ROOT_PASSWORD="archroot123"
USER_PASSWORD="archuser123"
TIMEZONE="Europe/Madrid"
LANG="en_US.UTF-8"
KEYMAP="es"
HOSTNAME="archzfs"

# --- Funciones principales ---
check_root() { [ "$(id -u)" -ne 0 ] && echo -e "${RED}ERROR: Ejecuta como root. Usa 'sudo -i' en el live USB.${NC}" && exit 1; }

detect_env() {
    ENV=$(dmidecode -s system-product-name | awk '{print tolower($0)}' | grep -E 'vmware|virtualbox|qemu' || echo "physical")
    echo -e "${BLUE}[INFO] Entorno detectado: ${ENV}${NC}"
}

setup_disks() {
    echo -e "${YELLOW}[*] Configurando discos...${NC}"
    lsblk -d -o NAME,SIZE,MODEL | grep -v "loop"
    
    read -p "Disco para sistema (ej: sda): " DISK_SYSTEM
    read -p "Discos para ZFS (ej: sdb sdc): " DISK_ZFS1 DISK_ZFS2

    # Validación
    for disk in "$DISK_SYSTEM" "$DISK_ZFS1" "$DISK_ZFS2"; do
        [ ! -b "/dev/$disk" ] && echo -e "${RED}[ERROR] Disco $disk no válido${NC}" && return 1
    done

    # Particionado (EFI sin cifrar)
    parted -s /dev/$DISK_SYSTEM mklabel gpt
    parted -s /dev/$DISK_SYSTEM mkpart primary fat32 1MiB 513MiB
    parted -s /dev/$DISK_SYSTEM set 1 esp on
    parted -s /dev/$DISK_SYSTEM mkpart primary ext4 513MiB 100%

    # Cifrado solo para raíz
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
    mount /dev/mapper/vg_arch-root /mnt
    mkdir -p /mnt/boot/efi
    mount /dev/${DISK_SYSTEM}1 /mnt/boot/efi
    swapon /dev/mapper/vg_arch-swap
}

install_system() {
    echo -e "${YELLOW}[*] Instalando sistema...${NC}"
    BASE_PKGS="base linux linux-firmware grub efibootmgr networkmanager lvm2 cryptsetup zfs-dkms zfs-utils"
    pacstrap /mnt $BASE_PKGS --noconfirm || return 1
    
    genfstab -U /mnt >> /mnt/etc/fstab
    arch-chroot /mnt reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist
}

configure_system() {
    echo -e "${YELLOW}[*] Configurando sistema...${NC}"
    arch-chroot /mnt bash <<EOF
    # Configuración básica
    ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
    hwclock --systohc
    echo "LANG=$LANG" > /etc/locale.conf
    echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
    echo "$HOSTNAME" > /etc/hostname
    sed -i '/en_US.UTF-8/s/^#//g' /etc/locale.gen
    locale-gen

    # Initramfs
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems fsck zfs)/' /etc/mkinitcpio.conf
    mkinitcpio -P

    # GRUB para EFI no cifrado
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    echo "GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=\$(blkid -s UUID -o value /dev/${DISK_SYSTEM}2):crypt-root root=/dev/mapper/vg_arch-root\"" >> /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg

    # Usuario
    echo "root:$ROOT_PASSWORD" | chpasswd
    useradd -m -G wheel $USERNAME
    echo "$USERNAME:$USER_PASSWORD" | chpasswd
    echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

    # Paquetes adicionales
    pacman -Sy --noconfirm xfce4 lightdm firefox docker
    systemctl enable lightdm docker NetworkManager
EOF
}

# --- Funciones adicionales ---
backup_luks() {
    echo -e "${YELLOW}[*] Backup de LUKS (opcional)...${NC}"
    read -p "¿Hacer backup de cabeceras LUKS? [s/N]: " choice
    [[ "$choice" =~ [sS] ]] || return 0

    USB=$(lsblk -d -o NAME,TRAN | grep usb | awk '{print "/dev/"$1}')
    [ -z "$USB" ] && echo -e "${RED}[ERROR] No hay USBs detectados${NC}" && return 1

    mkdir -p /mnt/usb_backup
    mount ${USB}1 /mnt/usb_backup || mount $USB /mnt/usb_backup || return 1

    BACKUP_DIR="/mnt/usb_backup/luks_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p $BACKUP_DIR

    cryptsetup luksHeaderBackup /dev/${DISK_SYSTEM}2 --header-backup-file $BACKUP_DIR/luks_header.img
    dd if=/dev/urandom bs=1 count=256 of=$BACKUP_DIR/luks_keyfile.bin
    chmod 600 $BACKUP_DIR/luks_keyfile.bin
    cryptsetup luksAddKey /dev/${DISK_SYSTEM}2 $BACKUP_DIR/luks_keyfile.bin

    umount /mnt/usb_backup
    echo -e "${GREEN}[+] Backup completado en USB${NC}"
}

cleanup() {
    echo -e "${YELLOW}[*] Limpiando...${NC}"
    umount -R /mnt
    swapoff -a
    cryptsetup close crypt-root
    echo -e "${GREEN}[+] ¡Instalación completada! Reiniciando en 5s...${NC}"
    sleep 5
    reboot
}

# --- Menú principal ---
main() {
    clear
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${GREEN}       INSTALADOR AUTOMÁTICO DE ARCH LINUX        ${NC}"
    echo -e "${GREEN}       con LUKS + ZFS (By @LaraCanBurn)           ${NC}"
    echo -e "${GREEN}==================================================${NC}"

    check_root
    detect_env

    # Flujo de instalación
    setup_disks && \
    install_system && \
    configure_system && \
    backup_luks && \
    cleanup
}

# --- Ejecución ---
main
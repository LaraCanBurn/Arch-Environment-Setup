#!/bin/bash

# ==============================================
# INSTALADOR AUTOMÁTICO DE ARCH LINUX CON LUKS + ZFS
# Versión 2.2 - Soporte para VMware, VirtualBox y Hardware Físico
# Basado en la documentación original del usuario
# Con reinicios controlados y continuación automática
# Mejorado el desmontaje pre-reinicio
# Unico reinicio tras finalizar
# ==============================================

# --- Configuración de colores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Variables globales ---
ZPOOL_NAME="raidz"
USERNAME="ArchLinux"
ROOT_PASSWORD="archroot123"
USER_PASSWORD="archuser123"
TIMEZONE="Europe/Madrid"
LANG="en_US.UTF-8"
KEYMAP="es"
HOSTNAME="archzfs"
ENV=""
DISK_SYSTEM=""
DISK_ZFS1=""
DISK_ZFS2=""

# ==============================================
# FUNCIONES PRINCIPALES
# ==============================================

function check_root() {
    [ "$(id -u)" -ne 0 ] && echo -e "${RED}ERROR: Ejecuta como root. Usa 'sudo -i' en el live USB.${NC}" && exit 1
}

function detect_env() {
    if dmidecode -s system-product-name | grep -qi "vmware"; then
        ENV="vmware"
    elif dmidecode -s system-product-name | grep -qi "virtualbox"; then
        ENV="virtualbox"
    elif dmidecode -s system-product-name | grep -qi "qemu"; then
        ENV="qemu"
    else
        ENV="physical"
    fi
    echo -e "${BLUE}[INFO] Entorno detectado: ${ENV}${NC}"
}

function detect_usb_devices() {
    echo -e "${YELLOW}[*] Detectando dispositivos USB...${NC}"
    local usb_devices=()
    local counter=1
    
    for device in $(lsblk -d -o NAME,TRAN | grep "usb" | awk '{print $1}'); do
        device_info=$(lsblk -d -o NAME,SIZE,MODEL,VENDOR /dev/$device)
        usb_devices+=("$device")
        echo -e "${BLUE}[$counter] ${device_info}${NC}"
        ((counter++))
    done
    
    if [ ${#usb_devices[@]} -eq 0 ]; then
        echo -e "${RED}[ERROR] No se detectaron dispositivos USB${NC}"
        return 1
    fi
    
    return 0
}

function select_usb_device() {
    detect_usb_devices || return 1
    
    read -p "Selecciona el número del USB para backup: " usb_choice
    local usb_devices=($(lsblk -d -o NAME,TRAN | grep "usb" | awk '{print $1}'))
    
    if [ -z "$usb_choice" ] || [ "$usb_choice" -lt 1 ] || [ "$usb_choice" -gt ${#usb_devices[@]} ]; then
        echo -e "${RED}[ERROR] Selección inválida${NC}"
        return 1
    fi
    
    selected_usb="/dev/${usb_devices[$((usb_choice-1))]}"
    echo -e "${GREEN}[+] USB seleccionado: ${selected_usb}${NC}"
    
    if ! mount | grep -q "$selected_usb"; then
        mkdir -p /mnt/usb_backup
        mount ${selected_usb}1 /mnt/usb_backup 2>/dev/null || \
        mount $selected_usb /mnt/usb_backup 2>/dev/null || \
        {
            echo -e "${RED}[ERROR] No se pudo montar el USB${NC}"
            return 1
        }
    fi
    
    return 0
}

function backup_luks_headers() {
    echo -e "${YELLOW}[*] Preparando backup de cabeceras LUKS...${NC}"
    
    select_usb_device || return 1
    
    local backup_dir="/mnt/usb_backup/luks_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    cryptsetup luksHeaderBackup /dev/${DISK_SYSTEM}2 --header-backup-file "$backup_dir/luks_header_system.img"
    [ -b "/dev/${DISK_ZFS1}1" ] && cryptsetup luksHeaderBackup /dev/${DISK_ZFS1}1 --header-backup-file "$backup_dir/luks_header_zfs1.img"
    [ -b "/dev/${DISK_ZFS2}1" ] && cryptsetup luksHeaderBackup /dev/${DISK_ZFS2}1 --header-backup-file "$backup_dir/luks_header_zfs2.img"
    
    dd if=/dev/urandom bs=1 count=256 of="$backup_dir/luks_keyfile.bin"
    chmod 600 "$backup_dir/luks_keyfile.bin"
    
    cryptsetup luksAddKey /dev/${DISK_SYSTEM}2 "$backup_dir/luks_keyfile.bin"
    [ -b "/dev/${DISK_ZFS1}1" ] && cryptsetup luksAddKey /dev/${DISK_ZFS1}1 "$backup_dir/luks_keyfile.bin"
    [ -b "/dev/${DISK_ZFS2}1" ] && cryptsetup luksAddKey /dev/${DISK_ZFS2}1 "$backup_dir/luks_keyfile.bin"
    
    cat > "$backup_dir/README.txt" <<EOF
# Backup de seguridad LUKS/ZFS
Dispositivos originales:
- Sistema: /dev/${DISK_SYSTEM}2
- ZFS 1: /dev/${DISK_ZFS1}1
- ZFS 2: /dev/${DISK_ZFS2}1
EOF
    
    echo -e "${GREEN}[+] Backup completado en: ${backup_dir}${NC}"
    umount /mnt/usb_backup
    rmdir /mnt/usb_backup
}

function setup_disks() {
    echo -e "${YELLOW}[*] Configurando discos...${NC}"
    
    echo -e "\n${BLUE}Discos disponibles:${NC}"
    lsblk -d -o NAME,SIZE,MODEL | grep -v "loop"
    echo ""

    read -p "Disco para sistema (ej: sda/nvme0n1): " DISK_SYSTEM
    read -p "Primer disco para ZFS (ej: sdb): " DISK_ZFS1
    read -p "Segundo disco para ZFS (ej: sdc): " DISK_ZFS2

    [ ! -b "/dev/$DISK_SYSTEM" ] && echo -e "${RED}[ERROR] Disco del sistema no válido${NC}" && return 1
    [ ! -b "/dev/$DISK_ZFS1" ] && echo -e "${RED}[ERROR] Primer disco ZFS no válido${NC}" && return 1
    [ ! -b "/dev/$DISK_ZFS2" ] && echo -e "${RED}[ERROR] Segundo disco ZFS no válido${NC}" && return 1

    # Particionado y cifrado
    echo -e "\n${GREEN}[+] Particionando ${DISK_SYSTEM}...${NC}"
    parted -s /dev/${DISK_SYSTEM} mklabel gpt
    parted -s /dev/${DISK_SYSTEM} mkpart primary fat32 1MiB 513MiB
    parted -s /dev/${DISK_SYSTEM} set 1 esp on
    parted -s /dev/${DISK_SYSTEM} mkpart primary ext4 513MiB 100%

    echo -e "\n${GREEN}[+] Configurando LUKS...${NC}"
    cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 \
      --hash sha512 --iter-time 5000 --pbkdf argon2id /dev/${DISK_SYSTEM}2 || return 1

    cryptsetup open /dev/${DISK_SYSTEM}2 crypt-root || return 1

    # LVM
    echo -e "\n${GREEN}[+] Configurando LVM...${NC}"
    pvcreate /dev/mapper/crypt-root || return 1
    vgcreate vg_arch /dev/mapper/crypt-root || return 1
    lvcreate -L 8G vg_arch -n swap || return 1
    lvcreate -l +100%FREE vg_arch -n root || return 1

    # Formateo
    echo -e "\n${GREEN}[+] Formateando particiones...${NC}"
    mkfs.vfat -F32 /dev/${DISK_SYSTEM}1 || return 1
    mkswap /dev/mapper/vg_arch-swap || return 1
    mkfs.ext4 /dev/mapper/vg_arch-root || return 1

    # Montaje
    echo -e "\n${GREEN}[+] Montando particiones...${NC}"
    mount /dev/mapper/vg_arch-root /mnt || return 1
    mkdir -p /mnt/boot/efi || return 1
    mount /dev/${DISK_SYSTEM}1 /mnt/boot/efi || return 1
    swapon /dev/mapper/vg_arch-swap || return 1
}

function install_base_system() {
    echo -e "${YELLOW}[*] Instalando sistema base...${NC}"
    
    BASE_PKGS="base linux linux-firmware grub efibootmgr networkmanager lvm2 cryptsetup nano vim reflector sof-firmware"
    ZFS_PKGS="zfs-dkms zfs-utils"
    
    if ! pacstrap /mnt ${BASE_PKGS} ${ZFS_PKGS}; then
        echo -e "${RED}[ERROR] Fallo al instalar paquetes base${NC}"
        return 1
    fi
    
    echo -e "${GREEN}[+] Optimizando mirrors...${NC}"
    arch-chroot /mnt reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist || return 1
    
    echo -e "${GREEN}[+] Generando fstab...${NC}"
    genfstab -U /mnt >> /mnt/etc/fstab || return 1
}

function configure_system() {
    echo -e "${YELLOW}[*] Configurando sistema...${NC}"
    
    arch-chroot /mnt <<EOF || return 1
    # Configuración básica
    ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
    hwclock --systohc
    echo "LANG=${LANG}" > /etc/locale.conf
    echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
    echo "${HOSTNAME}" > /etc/hostname
    
    # Locales
    sed -i '/en_US.UTF-8/s/^#//g' /etc/locale.gen
    sed -i '/es_ES.UTF-8/s/^#//g' /etc/locale.gen
    locale-gen
    
    # Initramfs
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems fsck zfs)/' /etc/mkinitcpio.conf
    mkinitcpio -P
    
    # GRUB
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    echo "GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$(blkid -s UUID -o value /dev/${DISK_SYSTEM}2):crypt-root root=/dev/mapper/vg_arch-root\"" >> /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg
    
    # Red
    systemctl enable NetworkManager
EOF
}

function setup_zfs() {
    echo -e "${YELLOW}[*] Configurando ZFS...${NC}"
    
    # Cifrado discos ZFS
    [ -b "/dev/${DISK_ZFS1}1" ] && cryptsetup luksFormat --type luks2 /dev/${DISK_ZFS1}1
    [ -b "/dev/${DISK_ZFS2}1" ] && cryptsetup luksFormat --type luks2 /dev/${DISK_ZFS2}1
    
    cryptsetup open /dev/${DISK_ZFS1}1 crypt-zfs1
    cryptsetup open /dev/${DISK_ZFS2}1 crypt-zfs2

    arch-chroot /mnt <<EOF || return 1
    zpool create -f -o ashift=12 ${ZPOOL_NAME} raidz /dev/mapper/crypt-zfs1 /dev/mapper/crypt-zfs2
    zfs create ${ZPOOL_NAME}/data
    zfs set compression=lz4 ${ZPOOL_NAME}
    zfs set atime=off ${ZPOOL_NAME}
    zfs set dedup=on ${ZPOOL_NAME}
    
    # Optimización memoria ZFS
    echo "options zfs zfs_arc_max=8589934592" > /etc/modprobe.d/zfs.conf
    echo "options zfs zfs_arc_min=2147483648" >> /etc/modprobe.d/zfs.conf
EOF
}

function setup_user() {
    echo -e "${YELLOW}[*] Configurando usuario...${NC}"
    
    arch-chroot /mnt <<EOF || return 1
    # Usuario y contraseñas
    echo "root:${ROOT_PASSWORD}" | chpasswd
    useradd -m -G wheel -s /bin/bash ${USERNAME}
    echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
    echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers
    
    # Paquetes adicionales
    pacman -Sy --noconfirm \
      neofetch brave-bin wget htop git docker \
      xfce4 xorg lightdm lightdm-gtk-greeter \
      firefox noto-fonts-cjk
    
    # Servicios
    systemctl enable lightdm docker
    systemctl enable fstrim.timer
EOF
}

function install_vm_tools() {
    case $ENV in
        "vmware")
            echo -e "${GREEN}[+] Instalando open-vm-tools...${NC}"
            pacstrap /mnt open-vm-tools
            arch-chroot /mnt systemctl enable vmtoolsd.service
            ;;
        "virtualbox")
            echo -e "${GREEN}[+] Instalando virtualbox-guest-utils...${NC}"
            pacstrap /mnt virtualbox-guest-utils
            arch-chroot /mnt systemctl enable vboxservice.service
            ;;
        "qemu")
            echo -e "${GREEN}[+] Instalando qemu-guest-agent...${NC}"
            pacstrap /mnt qemu-guest-agent
            arch-chroot /mnt systemctl enable qemu-guest-agent.service
            ;;
    esac
}

function cleanup_and_reboot() {
    echo -e "${YELLOW}[*] Limpiando antes del reinicio...${NC}"
    
    # Desmontar todo
    umount -R /mnt/boot/efi
    umount -R /mnt
    swapoff -a
    
    # Cerrar dispositivos
    cryptsetup close crypt-root
    [ -b "/dev/mapper/crypt-zfs1" ] && cryptsetup close crypt-zfs1
    [ -b "/dev/mapper/crypt-zfs2" ] && cryptsetup close crypt-zfs2
    
    echo -e "\n${GREEN}==================================================${NC}"
    echo -e "${GREEN}       ¡INSTALACIÓN COMPLETADA CON ÉXITO!         ${NC}"
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${YELLOW}[!] El sistema se reiniciará en 10 segundos...${NC}"
    echo -e "${YELLOW}[!] Presiona Ctrl+C para cancelar el reinicio${NC}"
    
    sleep 10
    reboot
}

# ==============================================
# FLUJO PRINCIPAL DE INSTALACIÓN
# ==============================================

function main_installation() {
    echo -e "${GREEN}[*] Iniciando instalación completa...${NC}"
    
    # Ejecutar todos los pasos secuencialmente
    setup_disks && \
    install_base_system && \
    configure_system && \
    setup_zfs && \
    setup_user && \
    install_vm_tools && \
    {
        read -p "¿Deseas hacer backup de cabeceras LUKS? [s/N]: " backup_choice
        [[ "$backup_choice" =~ [sSyY] ]] && backup_luks_headers
        return 0
    }
}

function main() {
    clear
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${GREEN}       INSTALADOR AUTOMÁTICO DE ARCH LINUX        ${NC}"
    echo -e "${GREEN}       con LUKS + ZFS (By @LaraCanBurn)           ${NC}"
    echo -e "${GREEN}==================================================${NC}"
    
    check_root
    detect_env
    
    if main_installation; then
        cleanup_and_reboot
    else
        echo -e "${RED}[ERROR] La instalación ha fallado. Revisa los mensajes anteriores.${NC}"
        exit 1
    fi
}

main
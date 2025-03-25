#!/bin/bash

# ==============================================
# INSTALADOR AUTOMÁTICO DE ARCH LINUX CON LUKS + ZFS
# Versión 2.0 - Soporte para VMware, VirtualBox y Hardware Físico
# Basado en la documentación original del usuario
# Con reinicios controlados y continuación automática
# ==============================================

# --- Configuración de colores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Verificar root ---
[ "$(id -u)" -ne 0 ] && echo -e "${RED}ERROR: Ejecuta como root. Usa 'sudo -i' en el live USB.${NC}" && exit 1

# --- Variables configurables ---
ZPOOL_NAME="raidz"
USERNAME="ArchLinux"
ROOT_PASSWORD="archroot123"
USER_PASSWORD="archuser123"
TIMEZONE="Europe/Madrid"
LANG="en_US.UTF-8"
KEYMAP="es"
HOSTNAME="archzfs"
PHASE_FILE="/tmp/install_phase"
SCRIPT_PHASE2="/mnt/root/arch_install_phase2.sh"

# --- Detectar fase de instalación ---
if [ -f "$PHASE_FILE" ]; then
    CURRENT_PHASE=$(cat "$PHASE_FILE")
else
    CURRENT_PHASE="1"
    echo "1" > "$PHASE_FILE"
fi

# --- Detección de entorno ---
function detect_env() {
    if dmidecode -s system-product-name | grep -qi "vmware"; then
        echo -e "${BLUE}[INFO] Entorno detectado: VMware${NC}"
        ENV="vmware"
    elif dmidecode -s system-product-name | grep -qi "virtualbox"; then
        echo -e "${BLUE}[INFO] Entorno detectado: VirtualBox${NC}"
        ENV="virtualbox"
    elif dmidecode -s system-product-name | grep -qi "qemu"; then
        echo -e "${BLUE}[INFO] Entorno detectado: QEMU/KVM${NC}"
        ENV="qemu"
    else
        echo -e "${BLUE}[INFO] Entorno detectado: Hardware Físico${NC}"
        ENV="physical"
    fi
}

# --- Instalar herramientas de virtualización ---
function install_vm_tools() {
    case $ENV in
        "vmware")
            echo -e "${GREEN}[+] Instalando open-vm-tools...${NC}"
            pacstrap /mnt open-vm-tools >/dev/null
            arch-chroot /mnt systemctl enable vmtoolsd.service >/dev/null
            ;;
        "virtualbox")
            echo -e "${GREEN}[+] Instalando virtualbox-guest-utils...${NC}"
            pacstrap /mnt virtualbox-guest-utils >/dev/null
            arch-chroot /mnt systemctl enable vboxservice.service >/dev/null
            ;;
        "qemu")
            echo -e "${GREEN}[+] Instalando qemu-guest-agent...${NC}"
            pacstrap /mnt qemu-guest-agent >/dev/null
            arch-chroot /mnt systemctl enable qemu-guest-agent.service >/dev/null
            ;;
    esac
}

# --- Particionado y cifrado ---
function setup_disks() {
    echo -e "${YELLOW}[*] Configurando discos y cifrado LUKS...${NC}"
    
    # Listar discos
    echo -e "\n${BLUE}Discos disponibles:${NC}"
    lsblk -d -o NAME,SIZE,MODEL | grep -v "loop"
    echo ""

    # Selección de discos
    read -p "Disco para sistema (ej: sda/nvme0n1): " DISK_SYSTEM
    read -p "Primer disco para ZFS (ej: sdb): " DISK_ZFS1
    read -p "Segundo disco para ZFS (ej: sdc): " DISK_ZFS2

    # Particionado
    echo -e "\n${GREEN}[+] Particionando ${DISK_SYSTEM}...${NC}"
    parted -s /dev/${DISK_SYSTEM} mklabel gpt
    parted -s /dev/${DISK_SYSTEM} mkpart primary fat32 1MiB 513MiB
    parted -s /dev/${DISK_SYSTEM} set 1 esp on
    parted -s /dev/${DISK_SYSTEM} mkpart primary ext4 513MiB 100%

    # Cifrado LUKS (configuración avanzada)
    echo -e "\n${GREEN}[+] Configurando LUKS en ${DISK_SYSTEM}2...${NC}"
    cryptsetup luksFormat --type luks2 \
      --cipher aes-xts-plain64 \
      --key-size 512 \
      --hash sha512 \
      --iter-time 5000 \
      --pbkdf argon2id \
      /dev/${DISK_SYSTEM}2

    cryptsetup open /dev/${DISK_SYSTEM}2 crypt-root

    # LVM
    echo -e "\n${GREEN}[+] Creando volúmenes LVM...${NC}"
    pvcreate /dev/mapper/crypt-root
    vgcreate vg_arch /dev/mapper/crypt-root
    lvcreate -L 8G vg_arch -n swap
    lvcreate -l +100%FREE vg_arch -n root

    # Formateo
    mkfs.vfat -F32 /dev/${DISK_SYSTEM}1
    mkswap /dev/mapper/vg_arch-swap
    mkfs.ext4 /dev/mapper/vg_arch-root

    # Montaje
    mount /dev/mapper/vg_arch-root /mnt
    mkdir -p /mnt/boot/efi
    mount /dev/${DISK_SYSTEM}1 /mnt/boot/efi
    swapon /dev/mapper/vg_arch-swap
}

# --- Instalación del sistema base ---
function install_base_system() {
    echo -e "${YELLOW}[*] Instalando sistema base...${NC}"
    
    # Paquetes esenciales
    BASE_PKGS="base linux linux-firmware grub efibootmgr networkmanager lvm2 cryptsetup nano vim reflector sof-firmware"
    ZFS_PKGS="zfs-dkms zfs-utils"
    
    # Instalación
    pacstrap /mnt ${BASE_PKGS} ${ZFS_PKGS}
    
    # Optimizar mirrors
    echo -e "${GREEN}[+] Optimizando mirrors con reflector...${NC}"
    arch-chroot /mnt reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist
    
    # Generar fstab
    genfstab -U /mnt >> /mnt/etc/fstab
}

# --- Configuración del sistema ---
function configure_system() {
    echo -e "${YELLOW}[*] Configurando sistema...${NC}"
    
    arch-chroot /mnt <<EOF
    # Configuración básica
    ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
    hwclock --systohc
    echo "LANG=${LANG}" > /etc/locale.conf
    echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
    echo "${HOSTNAME}" > /etc/hostname
    sed -i '/en_US.UTF-8/s/^#//g' /etc/locale.gen
    sed -i '/es_ES.UTF-8/s/^#//g' /etc/locale.gen
    locale-gen
    
    # Configurar mkinitcpio
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems fsck zfs)/' /etc/mkinitcpio.conf
    mkinitcpio -P
    
    # Configurar GRUB
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    echo "GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$(blkid -s UUID -o value /dev/${DISK_SYSTEM}2):crypt-root root=/dev/mapper/vg_arch-root\"" >> /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg
    
    # Configurar red
    systemctl enable NetworkManager
EOF
}

# --- Configuración de ZFS ---
function setup_zfs() {
    echo -e "${YELLOW}[*] Configurando ZFS...${NC}"
    
    # Cifrar discos ZFS
    cryptsetup luksFormat --type luks2 /dev/${DISK_ZFS1}1
    cryptsetup luksFormat --type luks2 /dev/${DISK_ZFS2}1
    cryptsetup open /dev/${DISK_ZFS1}1 crypt-zfs1
    cryptsetup open /dev/${DISK_ZFS2}1 crypt-zfs2

    # Configurar pool ZFS
    arch-chroot /mnt <<EOF
    zpool create -f -o ashift=12 ${ZPOOL_NAME} raidz /dev/mapper/crypt-zfs1 /dev/mapper/crypt-zfs2
    zfs create ${ZPOOL_NAME}/data
    zfs set compression=lz4 ${ZPOOL_NAME}
    zfs set atime=off ${ZPOOL_NAME}
    zfs set dedup=on ${ZPOOL_NAME}
    echo "options zfs zfs_arc_max=8589934592" > /etc/modprobe.d/zfs.conf
    echo "options zfs zfs_arc_min=2147483648" >> /etc/modprobe.d/zfs.conf
EOF
}

# --- Creación de usuario y paquetes adicionales ---
function setup_user() {
    echo -e "${YELLOW}[*] Configurando usuario y paquetes...${NC}"
    
    arch-chroot /mnt <<EOF
    # Usuario y contraseñas
    echo "root:${ROOT_PASSWORD}" | chpasswd
    useradd -m -G wheel -s /bin/bash ${USERNAME}
    echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
    echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers
    
    # Paquetes adicionales
    pacman -Sy --noconfirm \
      neofetch brave-bin libreoffice-still wget htop ncdu tree \
      git docker kubernetes-cli python python-pip nodejs npm \
      ufw gufw fail2ban vlc p7zip zip unzip tar \
      code minikube kubectl \
      xfce4 xorg xorg-server lightdm lightdm-gtk-greeter
    
    # Servicios
    systemctl enable lightdm docker ufw
    ufw enable
    sudo -u ${USERNAME} xdg-user-dirs-update
EOF
}

# --- Preparar fase 2 (post-reinicio) ---
function prepare_phase2() {
    cat > /mnt/root/phase2.sh <<EOF
#!/bin/bash
# Script de continuación post-reinicio

# Montar particiones
mount /dev/mapper/vg_arch-root /mnt
mount /dev/${DISK_SYSTEM}1 /mnt/boot/efi
swapon /dev/mapper/vg_arch-swap

# Configuraciones finales
echo -e "${GREEN}[+] Ejecutando fase post-reinicio...${NC}"
source /mnt/root/phase2_functions.sh

# Limpieza final
rm -f /root/phase2.sh
rm -f /root/phase2_functions.sh
rm -f ${PHASE_FILE}
echo -e "${GREEN}[+] ¡Instalación completada!${NC}"
echo -e "${YELLOW}[!] Ejecuta 'reboot' para reiniciar al sistema instalado.${NC}"
EOF

    cat > /mnt/root/phase2_functions.sh <<EOF
#!/bin/bash
# Funciones para la fase 2

$(declare -f configure_system)
$(declare -f setup_zfs)
$(declare -f setup_user)
$(declare -f install_vm_tools)

# Ejecutar configuraciones finales
configure_system
setup_zfs
setup_user
install_vm_tools
EOF

    chmod +x /mnt/root/phase2.sh
    chmod +x /mnt/root/phase2_functions.sh
    
    # Configurar auto-ejecución
    echo "[ -f /root/phase2.sh ] && /root/phase2.sh" >> /mnt/root/.bashrc
}

# --- Manejar reinicio ---
function handle_reboot() {
    echo -e "${YELLOW}[!] Preparando reinicio...${NC}"
    prepare_phase2
    echo -e "${GREEN}[+] El sistema se reiniciará en 5 segundos...${NC}"
    sleep 5
    umount -R /mnt
    reboot
}

# --- Función principal ---
function main() {
    clear
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${GREEN}       INSTALADOR AUTOMÁTICO DE ARCH LINUX        ${NC}"
    echo -e "${GREEN}       con LUKS + ZFS (By @LaraCanBurn)           ${NC}"
    echo -e "${GREEN}==================================================${NC}"
    
    detect_env
    
    case $CURRENT_PHASE in
        "1")
            echo -e "${BLUE}[*] Fase 1: Configuración inicial${NC}"
            setup_disks
            install_base_system
            echo "2" > "$PHASE_FILE"
            handle_reboot
            ;;
        "2")
            echo -e "${BLUE}[*] Fase 2: Configuración post-reinicio${NC}"
            configure_system
            setup_zfs
            setup_user
            install_vm_tools
            rm -f "$PHASE_FILE"
            echo -e "${GREEN}[+] ¡Instalación completada con éxito!${NC}"
            ;;
        *)
            echo -e "${RED}[ERROR] Fase de instalación desconocida${NC}"
            exit 1
            ;;
    esac
}

# --- Ejecutar instalador ---
main
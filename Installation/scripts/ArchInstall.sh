#!/bin/bash

# ==============================================
# INSTALADOR AUTOMÁTICO DE ARCH LINUX CON LUKS + ZFS
# Versión 2.1 - Soporte para VMware, VirtualBox y Hardware Físico
# Basado en la documentación original del usuario
# Con reinicios controlados y continuación automática
# Mejorado el desmontaje pre-reinicio
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
PHASE_FILE="/tmp/install_phase"
SCRIPT_PHASE2="/mnt/root/arch_install_phase2.sh"
ENV=""
DISK_SYSTEM=""
DISK_ZFS1=""
DISK_ZFS2=""

# ==============================================
# FUNCIONES PRINCIPALES
# ==============================================

# --- Verificar root ---
function check_root() {
    [ "$(id -u)" -ne 0 ] && echo -e "${RED}ERROR: Ejecuta como root. Usa 'sudo -i' en el live USB.${NC}" && exit 1
    return 0
}

# --- Detectar entorno ---
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
    return 0
}

# --- Detectar USBs conectados ---
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

# --- Seleccionar USB para backup ---
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
    
    # Verificar si el USB está montado
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

# --- Guardar cabeceras y claves LUKS ---
function backup_luks_headers() {
    echo -e "${YELLOW}[*] Preparando backup de cabeceras LUKS y claves...${NC}"
    
    select_usb_device || return 1
    
    local backup_dir="/mnt/usb_backup/luks_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    # Guardar cabeceras LUKS
    echo -e "${GREEN}[+] Guardando cabeceras LUKS...${NC}"
    cryptsetup luksHeaderBackup /dev/${DISK_SYSTEM}2 --header-backup-file "$backup_dir/luks_header_system.img"
    cryptsetup luksHeaderBackup /dev/${DISK_ZFS1}1 --header-backup-file "$backup_dir/luks_header_zfs1.img"
    cryptsetup luksHeaderBackup /dev/${DISK_ZFS2}1 --header-backup-file "$backup_dir/luks_header_zfs2.img"
    
    # Generar claves de respaldo
    echo -e "${GREEN}[+] Generando claves de respaldo...${NC}"
    dd if=/dev/urandom bs=1 count=256 of="$backup_dir/luks_keyfile.bin"
    chmod 600 "$backup_dir/luks_keyfile.bin"
    
    # Añadir clave a los dispositivos LUKS
    cryptsetup luksAddKey /dev/${DISK_SYSTEM}2 "$backup_dir/luks_keyfile.bin"
    cryptsetup luksAddKey /dev/${DISK_ZFS1}1 "$backup_dir/luks_keyfile.bin"
    cryptsetup luksAddKey /dev/${DISK_ZFS2}1 "$backup_dir/luks_keyfile.bin"
    
    # Crear archivo README
    cat > "$backup_dir/README.txt" <<EOF
# Backup de seguridad LUKS/ZFS

Este directorio contiene:
1. Cabeceras LUKS de los dispositivos cifrados
2. Archivo de claves para desbloquear los dispositivos

## Cómo usar las cabeceras:
cryptsetup luksHeaderRestore /dev/dispositivo --header-backup-file /ruta/al/header.img

## Cómo usar el archivo de claves:
cryptsetup open /dev/dispositivo nombre_dispositivo --key-file /ruta/al/luks_keyfile.bin

## Dispositivos originales:
- Sistema: /dev/${DISK_SYSTEM}2
- ZFS 1: /dev/${DISK_ZFS1}1
- ZFS 2: /dev/${DISK_ZFS2}1
EOF
    
    echo -e "${GREEN}[+] Backup completado en: ${backup_dir}${NC}"
    echo -e "${YELLOW}[!] Desmontando USB...${NC}"
    umount /mnt/usb_backup
    rmdir /mnt/usb_backup
    
    return 0
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

    # Validar discos seleccionados
    [ ! -b "/dev/$DISK_SYSTEM" ] && echo -e "${RED}[ERROR] Disco del sistema no válido${NC}" && return 1
    [ ! -b "/dev/$DISK_ZFS1" ] && echo -e "${RED}[ERROR] Primer disco ZFS no válido${NC}" && return 1
    [ ! -b "/dev/$DISK_ZFS2" ] && echo -e "${RED}[ERROR] Segundo disco ZFS no válido${NC}" && return 1

    # Particionado
    echo -e "\n${GREEN}[+] Particionando ${DISK_SYSTEM}...${NC}"
    parted -s /dev/${DISK_SYSTEM} mklabel gpt
    parted -s /dev/${DISK_SYSTEM} mkpart primary fat32 1MiB 513MiB
    parted -s /dev/${DISK_SYSTEM} set 1 esp on
    parted -s /dev/${DISK_SYSTEM} mkpart primary ext4 513MiB 100%

    # Cifrado LUKS
    echo -e "\n${GREEN}[+] Configurando LUKS en ${DISK_SYSTEM}2...${NC}"
    cryptsetup luksFormat --type luks2 \
      --cipher aes-xts-plain64 \
      --key-size 512 \
      --hash sha512 \
      --iter-time 5000 \
      --pbkdf argon2id \
      /dev/${DISK_SYSTEM}2 || return 1

    cryptsetup open /dev/${DISK_SYSTEM}2 crypt-root || return 1

    # LVM
    echo -e "\n${GREEN}[+] Creando volúmenes LVM...${NC}"
    pvcreate /dev/mapper/crypt-root || return 1
    vgcreate vg_arch /dev/mapper/crypt-root || return 1
    lvcreate -L 8G vg_arch -n swap || return 1
    lvcreate -l +100%FREE vg_arch -n root || return 1

    # Formateo
    mkfs.vfat -F32 /dev/${DISK_SYSTEM}1 || return 1
    mkswap /dev/mapper/vg_arch-swap || return 1
    mkfs.ext4 /dev/mapper/vg_arch-root || return 1

    # Montaje
    mount /dev/mapper/vg_arch-root /mnt || return 1
    mkdir -p /mnt/boot/efi || return 1
    mount /dev/${DISK_SYSTEM}1 /mnt/boot/efi || return 1
    swapon /dev/mapper/vg_arch-swap || return 1
    
    return 0
}

# --- Instalación del sistema base ---
function install_base_system() {
    echo -e "${YELLOW}[*] Instalando sistema base...${NC}"
    
    BASE_PKGS="base linux linux-firmware grub efibootmgr networkmanager lvm2 cryptsetup nano vim reflector sof-firmware"
    ZFS_PKGS="zfs-dkms zfs-utils"
    
    pacstrap /mnt ${BASE_PKGS} ${ZFS_PKGS} || return 1
    
    echo -e "${GREEN}[+] Optimizando mirrors...${NC}"
    arch-chroot /mnt reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist || return 1
    
    genfstab -U /mnt >> /mnt/etc/fstab || return 1
    
    return 0
}

# --- Configuración del sistema ---
function configure_system() {
    echo -e "${YELLOW}[*] Configurando sistema...${NC}"
    
    arch-chroot /mnt <<EOF || return 1
    ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
    hwclock --systohc
    echo "LANG=${LANG}" > /etc/locale.conf
    echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
    echo "${HOSTNAME}" > /etc/hostname
    sed -i '/en_US.UTF-8/s/^#//g' /etc/locale.gen
    sed -i '/es_ES.UTF-8/s/^#//g' /etc/locale.gen
    locale-gen
    
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems fsck zfs)/' /etc/mkinitcpio.conf
    mkinitcpio -P
    
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    echo "GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$(blkid -s UUID -o value /dev/${DISK_SYSTEM}2):crypt-root root=/dev/mapper/vg_arch-root\"" >> /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg
    
    systemctl enable NetworkManager
EOF
    
    return 0
}

# --- Configuración de ZFS ---
function setup_zfs() {
    echo -e "${YELLOW}[*] Configurando ZFS...${NC}"
    
    cryptsetup luksFormat --type luks2 /dev/${DISK_ZFS1}1 || return 1
    cryptsetup luksFormat --type luks2 /dev/${DISK_ZFS2}1 || return 1
    cryptsetup open /dev/${DISK_ZFS1}1 crypt-zfs1 || return 1
    cryptsetup open /dev/${DISK_ZFS2}1 crypt-zfs2 || return 1

    arch-chroot /mnt <<EOF || return 1
    zpool create -f -o ashift=12 ${ZPOOL_NAME} raidz /dev/mapper/crypt-zfs1 /dev/mapper/crypt-zfs2
    zfs create ${ZPOOL_NAME}/data
    zfs set compression=lz4 ${ZPOOL_NAME}
    zfs set atime=off ${ZPOOL_NAME}
    zfs set dedup=on ${ZPOOL_NAME}
    echo "options zfs zfs_arc_max=8589934592" > /etc/modprobe.d/zfs.conf
    echo "options zfs zfs_arc_min=2147483648" >> /etc/modprobe.d/zfs.conf
EOF
    
    return 0
}

# --- Creación de usuario y paquetes adicionales ---
function setup_user() {
    echo -e "${YELLOW}[*] Configurando usuario y paquetes...${NC}"
    
    arch-chroot /mnt <<EOF || return 1
    echo "root:${ROOT_PASSWORD}" | chpasswd
    useradd -m -G wheel -s /bin/bash ${USERNAME}
    echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
    echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers
    
    pacman -Sy --noconfirm \
      neofetch brave-bin libreoffice-still wget htop ncdu tree \
      git docker kubernetes-cli python python-pip nodejs npm \
      ufw gufw fail2ban vlc p7zip zip unzip tar \
      code minikube kubectl \
      xfce4 xorg xorg-server lightdm lightdm-gtk-greeter
    
    systemctl enable lightdm docker ufw
    ufw enable
    sudo -u ${USERNAME} xdg-user-dirs-update
EOF
    
    return 0
}

# --- Instalar herramientas de virtualización ---
function install_vm_tools() {
    case $ENV in
        "vmware")
            echo -e "${GREEN}[+] Instalando open-vm-tools...${NC}"
            pacstrap /mnt open-vm-tools >/dev/null || return 1
            arch-chroot /mnt systemctl enable vmtoolsd.service >/dev/null || return 1
            ;;
        "virtualbox")
            echo -e "${GREEN}[+] Instalando virtualbox-guest-utils...${NC}"
            pacstrap /mnt virtualbox-guest-utils >/dev/null || return 1
            arch-chroot /mnt systemctl enable vboxservice.service >/dev/null || return 1
            ;;
        "qemu")
            echo -e "${GREEN}[+] Instalando qemu-guest-agent...${NC}"
            pacstrap /mnt qemu-guest-agent >/dev/null || return 1
            arch-chroot /mnt systemctl enable qemu-guest-agent.service >/dev/null || return 1
            ;;
    esac
    return 0
}

# --- Preparar fase 2 (post-reinicio) ---
function prepare_phase2() {
    cat > /mnt/root/phase2.sh <<EOF
#!/bin/bash
# Script de continuación post-reinicio

mount /dev/mapper/vg_arch-root /mnt
mount /dev/${DISK_SYSTEM}1 /mnt/boot/efi
swapon /dev/mapper/vg_arch-swap

source /mnt/root/phase2_functions.sh

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

configure_system
setup_zfs
setup_user
install_vm_tools
EOF

    chmod +x /mnt/root/phase2.sh
    chmod +x /mnt/root/phase2_functions.sh
    
    echo "[ -f /root/phase2.sh ] && /root/phase2.sh" >> /mnt/root/.bashrc
    
    return 0
}

# --- Manejar reinicio (CORREGIDO) ---
function handle_reboot() {
    echo -e "${YELLOW}[!] Preparando reinicio...${NC}"
    prepare_phase2 || return 1
    
    read -p "¿Deseas hacer un backup de las cabeceras LUKS en un USB antes de reiniciar? [s/N]: " backup_choice
    if [[ "$backup_choice" =~ [sSyY] ]]; then
        backup_luks_headers
    fi

    echo -e "${GREEN}[+] Desmontando particiones...${NC}"
    
    # 1. Desmontar en orden inverso
    umount -R /mnt/boot/efi 2>/dev/null
    umount -R /mnt/boot 2>/dev/null
    
    # 2. Exportar pool ZFS si existe
    if command -v zpool >/dev/null && zpool list ${ZPOOL_NAME} >/dev/null 2>&1; then
        echo -e "${YELLOW}[*] Exportando pool ZFS...${NC}"
        zpool export ${ZPOOL_NAME}
    fi
    
    # 3. Desmontar raíz
    umount -R /mnt
    
    # 4. Desactivar swap
    swapoff -a
    
    # 5. Cerrar LUKS
    echo -e "${YELLOW}[*] Cerrando dispositivos cifrados...${NC}"
    cryptsetup close crypt-root 2>/dev/null
    cryptsetup close crypt-zfs1 2>/dev/null
    cryptsetup close crypt-zfs2 2>/dev/null
    
    # 6. Desactivar LVM
    if command -v vgchange >/dev/null; then
        echo -e "${YELLOW}[*] Desactivando volúmenes LVM...${NC}"
        vgchange -an vg_arch
    fi
    
    echo -e "${GREEN}[+] El sistema se reiniciará en 5 segundos...${NC}"
    sleep 5
    reboot
}

# --- Función principal ---
function main() {
    clear
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${GREEN}       INSTALADOR AUTOMÁTICO DE ARCH LINUX        ${NC}"
    echo -e "${GREEN}       con LUKS + ZFS (By @LaraCanBurn)           ${NC}"
    echo -e "${GREEN}==================================================${NC}"
    
    check_root
    detect_env
            
    if [ -f "$PHASE_FILE" ]; then
        CURRENT_PHASE=$(cat "$PHASE_FILE")
    else
        CURRENT_PHASE="1"
        echo "1" > "$PHASE_FILE"
    fi
            
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
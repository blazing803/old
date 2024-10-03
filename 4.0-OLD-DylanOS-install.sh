#!/bin/bash

# ASCII Art for DylanOS 4.0
cat << "EOF"
  _____        _              ____   _____   _  _    ___  
 |  __ \      | |            / __ \ / ____| | || |  / _ \ 
 | |  | |_   _| | __ _ _ __ | |  | | (___   | || |_| | | |
 | |  | | | | | |/ _` | '_ \| |  | |\___ \  |__   _| | | |
 | |__| | |_| | | (_| | | | | |__| |____) |    | |_| |_| |
 |_____/ \__, |_|\__,_|_| |_|\____/|_____/     |_(_)\___/ 
          __/ |                                           
         |___/                                            

                2023-2024
EOF

# Wait for 3 seconds
echo "Starting installation in 3 seconds..."
sleep 3

# User Input Variables
read -p "Enter the disk (e.g., /dev/nvme0n1 or /dev/sda): " DISK
read -p "Is this an NVMe disk? (yes/no): " NVME_RESPONSE
USE_NVME=${NVME_RESPONSE,,} # Lowercase the response

# Define partition variables based on NVMe detection
if [[ "$USE_NVME" == "yes" || "$USE_NVME" == "y" ]]; then
    EFI_PART="${DISK}p1"
    SWAP_PART="${DISK}p2"
    ROOT_PART="${DISK}p3"
else
    EFI_PART="${DISK}1"
    SWAP_PART="${DISK}2"
    ROOT_PART="${DISK}3"
fi

# Set partition sizes
EFI_SIZE="1G"
SWAP_SIZE="4G"

# Prompt for root password
read -sp "Enter root password: " ROOT_PASSWORD
echo  # For a new line after password input

# Prompt for username and password
read -p "Enter username: " USERNAME
read -sp "Enter user password: " USER_PASSWORD
echo  # For a new line after password input

# Prompt for timezone with a default value
read -p "Enter your timezone (default: America/New_York): " TIMEZONE
TIMEZONE=${TIMEZONE:-America/New_York}  # Use default if no input is given

LOCALE="en_US.UTF-8"  # Change to your preferred locale
KEYMAP="us"  # Change to your preferred keymap

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" 
    exit 1
fi

# Update system clock
timedatectl set-ntp true

# Partition the disk using fdisk
echo "Partitioning the disk with fdisk..."
if ! fdisk "$DISK" <<< $'g\nn\n\n\n+'"$EFI_SIZE"'\nt\n1\nn\n\n+'"$SWAP_SIZE"'\nt\n2\nn\n\n\n\nw'; then
    echo "fdisk failed. Attempting to partition with parted..."
    parted "$DISK" mklabel gpt
    parted "$DISK" mkpart primary fat32 1MiB "$EFI_SIZE"
    parted "$DISK" mkpart primary linux-swap "$EFI_SIZE" "$SWAP_SIZE"
    parted "$DISK" mkpart primary ext4 "$SWAP_SIZE" 100% || { echo "Parted partitioning failed."; exit 1; }
fi

# Format partitions
echo "Formatting partitions..."
mkfs.fat -F32 $EFI_PART  # EFI partition
mkswap $SWAP_PART         # Swap partition
mkfs.ext4 $ROOT_PART      # Root partition (the rest of the disk)

# Mount filesystem
echo "Mounting filesystem..."
mount $ROOT_PART /mnt
mkdir -p /mnt/boot
mount $EFI_PART /mnt/boot  # Mount EFI partition
swapon $SWAP_PART           # Enable swap

# Install essential packages
echo "Installing essential packages..."
pacstrap -K /mnt base linux linux-firmware base-devel sof-firmware \
    i3-wm i3blocks i3status i3lock lightdm lightdm-gtk-greeter \
    pavucontrol wireless_tools gvfs wget git nano vim \
    htop xfce4-panel xfce4-appfinder xfce4-power-manager \
    xfce4-screenshooter xfce4-cpufreq-plugin xfce4-diskperf-plugin \
    xfce4-fsguard-plugin xfce4-mount-plugin xfce4-netload-plugin \
    xfce4-places-plugin xfce4-sensors-plugin xfce4-weather-plugin \
    xfce4-clipman-plugin xfce4-notes-plugin firefox \
    openssh alacritty iwd wpa_supplicant plank picom \
    pulseaudio NetworkManager dmidecode grub nitrogen unzip efibootmgr pcmanfm || { echo "Package installation failed."; exit 1; }

# Generate fstab
echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot into the new system
echo "Entering new system..."
arch-chroot /mnt /bin/bash <<EOF

# Set root password
echo "Setting root password..."
echo "root:$ROOT_PASSWORD" | chpasswd

# Create a new user
useradd -m -G wheel "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd

# Set hostname
HOSTNAME=\$(dmidecode -s system-product-name)
echo "\$HOSTNAME" > /etc/hostname

# Enable and start services
systemctl enable lightdm
systemctl enable wpa_supplicant
systemctl enable iwd
systemctl --user enable pulseaudio
systemctl enable NetworkManager
systemctl enable sshd

# Set timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Localization
sed -i 's/^#\\(en_US\\.UTF-8\\)/\\1/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Keymap configuration
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Update /etc/os-release
echo "NAME=\"DylanOS\"" > /etc/os-release
echo "VERSION=\"4.0\"" >> /etc/os-release
echo "ID=dylanos" >> /etc/os-release
echo "ID_LIKE=arch" >> /etc/os-release

# Download wallpapers from GitHub
echo "Downloading wallpapers..."
mkdir -p /etc/wallpapers
wget https://github.com/blazing803/wallpapers/archive/refs/heads/main.zip -O /tmp/wallpapers.zip || { echo "Failed to download wallpapers."; exit 1; }

# Extract wallpapers
unzip /tmp/wallpapers.zip -d /tmp || { echo "Failed to unzip wallpapers."; exit 1; }
cp -r /tmp/wallpapers-main/* /etc/wallpapers/ || { echo "Failed to copy wallpapers."; exit 1; }

# Clean up
rm -rf /tmp/wallpapers.zip /tmp/wallpapers-main

# Configure nitrogen to use wallpaper4.png
mkdir -p /home/$USERNAME/.config/nitrogen
cat << EOF4 > /home/$USERNAME/.config/nitrogen/bg-saved.cfg
[xin_-1]
file=/etc/wallpapers/wallpaper4.png
mode=0
bgcolor=#000000
EOF4

# Change ownership of nitrogen config
chown -R $USERNAME:$USERNAME /home/$USERNAME/.config/nitrogen

# Download i3 config from GitHub
echo "Downloading i3 config..."
mkdir -p /home/$USERNAME/.config/i3
wget https://github.com/blazing803/configs/raw/main/i3-config -O /home/$USERNAME/.config/i3/i3-config || { echo "Failed to download i3 config."; exit 1; }

# Rename i3-config to config
mv /home/$USERNAME/.config/i3/i3-config /home/$USERNAME/.config/i3/config || { echo "Failed to rename i3-config to config."; exit 1; }

# Set ownership for the i3 config
chown -R $USERNAME:$USERNAME /home/$USERNAME/.config/i3

# Install GRUB
echo "Installing GRUB..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=DylanOS || { echo "GRUB installation failed."; exit 1; }

# Generate GRUB configuration file
echo "Generating GRUB configuration..."
grub-mkconfig -o /boot/grub/grub.cfg || { echo "GRUB configuration generation failed."; exit 1; }

# Change "Arch Linux" to "DylanOS 4.0" in grub.cfg
sed -i 's/Arch Linux/DylanOS 4.0/g' /boot/grub/grub.cfg || { echo "Failed to update grub.cfg"; exit 1; }

EOF

# Unmount and reboot
echo "Unmounting and rebooting..."
umount -R /mnt
reboot

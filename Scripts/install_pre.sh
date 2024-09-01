#!/usr/bin/env bash
#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| Script to apply pre install configs |--/ /-|#
#|-/ /--| Prasanth Rangan                     |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#
shopt -s nullglob extglob

if [[ $EUID != 0 ]]; then
    echo "[ERROR] This script must be run as root."
    exit 1
fi

# Locking mechanism
lock() {
    local LOCK=/tmp/hibernator.lock
    if ! mkdir "$LOCK" 2> /dev/null; then
        echo "Working... $LOCK"
        exit
    fi
    trap "rm -rf $LOCK" EXIT
}

# Function to remove kernel parameters
remove_kernel_parameters() {
    if [ -e /etc/default/grub ]; then
        cp /etc/default/grub /etc/default/grub.old
        sed -i '/resume=/d' /etc/default/grub
        update-grub
    fi
    if [ -e /boot/refind_linux.conf ]; then
        cp /boot/refind_linux.conf /boot/refind_linux.conf.old
        sed -i '/resume=/d' /boot/refind_linux.conf
    fi
}

# Function to remove resume hook
remove_resume_hook() {
    if grep -qs -e resume -e systemd /etc/mkinitcpio.conf; then
        cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.old
        sed -i '/resume/d' /etc/mkinitcpio.conf
        mkinitcpio -P
    fi
}

# Function to remove swap file
remove_swap_file() {
    if grep -qs '/swapfile' /etc/fstab; then
        sed -i '/\/swapfile/d' /etc/fstab
        swapoff /swapfile
        rm -f /swapfile
    fi
}

# Function to create a new swap file
create_swap_file() {
    # Ask user for the size of the new swap file in GB
    read -p "Enter the size of the swap file in GB (default is 2GB): " swap_size
    swap_size=${swap_size:-2}  # Default to 2GB if no input is provided

    # Create a new swap file
    echo "Creating a new swap file of size ${swap_size}GB..."
    fallocate -l "${swap_size}G" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    # Add the new swap file to /etc/fstab
    echo "/swapfile none swap sw 0 0" | tee -a /etc/fstab
}

# Function to check if a package is installed
pkg_installed() {
    pacman -Qq "$1" &> /dev/null
}

# Function to detect NVIDIA
nvidia_detect() {
    lspci | grep -i nvidia &> /dev/null
}

# Function to apply GRUB configurations
configure_grub() {
    if pkg_installed grub && [ -f /boot/grub/grub.cfg ]; then
        echo -e "\033[0;32m[BOOTLOADER]\033[0m detected // grub"

        if [ ! -f /etc/default/grub.t2.bkp ] && [ ! -f /boot/grub/grub.t2.bkp ]; then
            echo -e "\033[0;32m[BOOTLOADER]\033[0m configuring grub..."
            sudo cp /etc/default/grub /etc/default/grub.t2.bkp
            sudo cp /boot/grub/grub.cfg /boot/grub/grub.t2.bkp

            if nvidia_detect; then
                echo -e "\033[0;32m[BOOTLOADER]\033[0m nvidia detected, adding nvidia_drm.modeset=1 to boot option..."
                gcld=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "/etc/default/grub" | cut -d'"' -f2 | sed 's/\b nvidia_drm.modeset=.\b//g')
                sudo sed -i "/^GRUB_CMDLINE_LINUX_DEFAULT=/c\GRUB_CMDLINE_LINUX_DEFAULT=\"${gcld} nvidia_drm.modeset=1\"" /etc/default/grub
            fi

            echo -e "Select grub theme:\n[1] Retroboot (dark)\n[2] Pochita (light)"
            read -p " :: Press enter to skip grub theme <or> Enter option number : " grubopt
            case ${grubopt} in
                1) grubtheme="Retroboot" ;;
                2) grubtheme="Pochita" ;;
                *) grubtheme="None" ;;
            esac

            if [ "${grubtheme}" == "None" ]; then
                echo -e "\033[0;32m[BOOTLOADER]\033[0m Skipping grub theme..."
                sudo sed -i "s/^GRUB_THEME=/#GRUB_THEME=/g" /etc/default/grub
            else
                echo -e "\033[0;32m[BOOTLOADER]\033[0m Setting grub theme // ${grubtheme}"
                sudo tar -xzf ${scrDir}/Source/arcs/Grub_${grubtheme}.tar.gz -C /usr/share/grub/themes/
                sudo sed -i "/^GRUB_DEFAULT=/c\GRUB_DEFAULT=saved
                /^GRUB_GFXMODE=/c\GRUB_GFXMODE=1280x1024x32,auto
                /^GRUB_THEME=/c\GRUB_THEME=\"/usr/share/grub/themes/${grubtheme}/theme.txt\"
                /^#GRUB_THEME=/c\GRUB_THEME=\"/usr/share/grub/themes/${grubtheme}/theme.txt\"
                /^#GRUB_SAVEDEFAULT=true/c\GRUB_SAVEDEFAULT=true" /etc/default/grub
            fi

            sudo grub-mkconfig -o /boot/grub/grub.cfg
        else
            echo -e "\033[0;33m[SKIP]\033[0m grub is already configured..."
        fi
    fi
}

# Function to apply systemd-boot configurations
configure_systemd_boot() {
    if pkg_installed systemd && nvidia_detect && [ "$(bootctl status 2> /dev/null | awk '{if ($1 == "Product:") print $2}')" == "systemd-boot" ]; then
        echo -e "\033[0;32m[BOOTLOADER]\033[0m detected // systemd-boot"

        if [ "$(ls -l /boot/loader/entries/*.conf.t2.bkp 2> /dev/null | wc -l)" -ne "$(ls -l /boot/loader/entries/*.conf 2> /dev/null | wc -l)" ]; then
            echo "nvidia detected, adding nvidia_drm.modeset=1 to boot option..."
            find /boot/loader/entries/ -type f -name "*.conf" | while read imgconf; do
                sudo cp ${imgconf} ${imgconf}.t2.bkp
                sdopt=$(grep -w "^options" ${imgconf} | sed 's/\b quiet\b//g' | sed 's/\b splash\b//g' | sed 's/\b nvidia_drm.modeset=.\b//g')
                sudo sed -i "/^options/c${sdopt} quiet splash nvidia_drm.modeset=1" ${imgconf}
            done
        else
            echo -e "\033[0;33m[SKIP]\033[0m systemd-boot is already configured..."
        fi
    fi
}

# Function to configure pacman
configure_pacman() {
    if [ -f /etc/pacman.conf ] && [ ! -f /etc/pacman.conf.t2.bkp ]; then
        echo -e "\033[0;32m[PACMAN]\033[0m adding extra spice to pacman..."

        sudo cp /etc/pacman.conf /etc/pacman.conf.t2.bkp
        sudo sed -i "/^#Color/c\Color\nILoveCandy
        /^#VerbosePkgLists/c\VerbosePkgLists
        /^#ParallelDownloads/c\ParallelDownloads = 5" /etc/pacman.conf
        sudo sed -i '/^#\[multilib\]/,+1 s/^#//' /etc/pacman.conf

        sudo pacman -Syyu
        sudo pacman -Fy
    else
        echo -e "\033[0;33m[SKIP]\033[0m pacman is already configured..."
    fi
}

# Main function
main() {
    lock

    echo "Removing kernel parameters from bootloaders..." && remove_kernel_parameters
    echo "Removing resume hook from initramfs..." && remove_resume_hook
    echo "Removing swapfile..." && remove_swap_file
    echo "Hibernation setup has been undone."

    # Ask user if they want to set up hibernation
    read -p "Do you want to set up hibernation? (y/n): " setup_hibernate
    if [[ "$setup_hibernate" =~ ^[Yy]$ ]]; then
        create_swap_file
    else
        echo "Hibernation setup has been skipped."
    fi

    echo "Applying GRUB configurations..." && configure_grub
    echo "Applying systemd-boot configurations..." && configure_systemd_boot
    echo "Configuring pacman..." && configure_pacman
}

# Execute main function
main

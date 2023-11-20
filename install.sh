#!/usr/bin/env bash
#################################################
###### AUTOMATED INSTALL AND UPDATE SCRIPT ######
#################################################
# Written by yomgui1 & FRIX_x
# Revised by mrstone14
# @version: 1.4

# CHANGELOG:
#   v1.3: - added a warning on first install to be sure the user wants to install voronCFG and fixed a bug
#           where some artefacts of the old user config where still present after the install (harmless bug but not clean)
#         - automated the install of the Gcode shell commands plugin
#   v1.2: fixed some bugs and adding small new features:
#          - now it's ok to use the install script with the user config folder absent
#          - avoid copying all the existing MCU templates to the user config directory during install to keep it clean
#          - updated the logic to keep the user custom files and folders structure during a backup (it was previously flattened)
#   v1.1: added an MCU template automatic installation system
#   v1.0: first version of the script to allow a peaceful install and update ;)


# Where the user Klipper config is located (ie. the one used by Klipper to work)
USER_CONFIG_PATH="${HOME}/printer_data/config"
# Where to clone MRSTONE-x repository config files (read-only and keep untouched)
MRSTONE_CONFIG_PATH="${HOME}/voronCFG_config"
# Path used to store backups when updating (backups are automatically dated when saved inside)
BACKUP_PATH="${HOME}/voronCFG_config_backups"
# Where the Klipper folder is located (ie. the internal Klipper firmware machinery)
KLIPPER_PATH="${HOME}/klipper"


set -eu
export LC_ALL=C

# Step 1: Verify that the script is not run as root and Klipper is installed.
#         Then if it's a first install, warn and ask the user if he is sure to proceed
function preflight_checks {
    if [ "$EUID" -eq 0 ]; then
        echo "[PRE-CHECK] This script must not be run as root!"
        exit -1
    fi

    if [ "$(sudo systemctl list-units --full -all -t service --no-legend | grep -F 'klipper.service')" ]; then
        printf "[PRE-CHECK] Klipper service found! Continuing...\n\n"
    else
        echo "[ERROR] Klipper service not found, please install Klipper first!"
        exit -1
    fi

    local install_voronCFG_answer
    if [ ! -f "${USER_CONFIG_PATH}/.VERSION" ]; then
        echo "[PRE-CHECK] New installation of voronCFG detected!"
        echo "[PRE-CHECK] This install script will WIPE AND REPLACE your current Klipper config with the full voronCFG system (a backup will be kept)"
        echo "[PRE-CHECK] Be sure that the printer is idle before continuing!"
        
        read < /dev/tty -rp "[PRE-CHECK] Are you sure want to proceed and install voronCFG? (y/N) " install_voronCFG_answer
        if [[ -z "$install_voronCFG_answer" ]]; then
            install_voronCFG_answer="n"
        fi
        install_voronCFG_answer="${install_voronCFG_answer,,}"

        if [[ "$install_voronCFG_answer" =~ ^(yes|y)$ ]]; then
            printf "[PRE-CHECK] Installation confirmed! Continuing...\n\n"
        else
            echo "[PRE-CHECK] Installation was canceled!"
            exit -1
        fi
    fi
}


# Step 2: Check if the git config folder exist (or download it)
function check_download {
    local MRSTONEtemppath MRSTONEreponame
    MRSTONEtemppath="$(dirname ${MRSTONE_CONFIG_PATH})"
    MRSTONEreponame="$(basename ${MRSTONE_CONFIG_PATH})"

    if [ ! -d "${MRSTONE_CONFIG_PATH}" ]; then
        echo "[DOWNLOAD] Downloading voronCFG repository..."
        if git -C $MRSTONEtemppath clone https://github.com/mrstone14/voronCFG.git $MRSTONEreponame; then
            chmod +x ${MRSTONE_CONFIG_PATH}/install.sh
            printf "[DOWNLOAD] Download complete!\n\n"
        else
            echo "[ERROR] Download of voronCFG git repository failed!"
            exit -1
        fi
    else
        printf "[DOWNLOAD] voronCFG repository already found locally. Continuing...\n\n"
    fi
}


# Step 3: Backup the old Klipper configuration
function backup_config {
    mkdir -p ${BACKUP_DIR}

    # Copy every files from the user config ("2>/dev/null || :" allow it to fail silentely in case the config dir doesn't exist)
    cp -fa ${USER_CONFIG_PATH}/. ${BACKUP_DIR} 2>/dev/null || :
    # Then delete the symlinks inside the backup folder as they are not needed here...
    find ${BACKUP_DIR} -type l -exec rm -f {} \;

    # If voronCFG is not already installed (we check for .VERSION in the backup to detect it),
    # we need to remove, wipe and clean the current user config folder...
    if [ ! -f "${BACKUP_DIR}/.VERSION" ]; then
        rm -R ${USER_CONFIG_PATH}
    fi

    printf "[BACKUP] Backup of current user config files done in: ${BACKUP_DIR}\n\n"
}


# Step 4: Put the new configuration files in place to be ready to start
function install_config {
    echo "[INSTALL] Installation of the last voronCFG config files"
    mkdir -p ${USER_CONFIG_PATH}

    # Symlink MRSTONE-x config folders (read-only git repository) to the user's config directory
    for dir in config macros scripts moonraker; do
        ln -fsn ${MRSTONE_CONFIG_PATH}/$dir ${USER_CONFIG_PATH}/$dir
    done

    # Detect if it's a first install by looking at the .VERSION file to ask for the config
    # template install. If the config is already installed, nothing need to be done here
    # as moonraker is already pulling the changes and custom user config files are already here
    if [ ! -f "${BACKUP_DIR}/.VERSION" ]; then
        printf "[INSTALL] New installation detected: config templates will be set in place!\n\n"
        find ${MRSTONE_CONFIG_PATH}/user_templates/ -type d -name 'mcu_defaults' -prune -o -type f -print | xargs cp -ft ${USER_CONFIG_PATH}/
        install_mcu_templates
    fi

    # CHMOD the scripts to be sure they are all executables (Git should keep the modes on files but it's to be sure)
    chmod +x ${MRSTONE_CONFIG_PATH}/install.sh
    for file in graph_vibrations.py plot_graphs.sh; do
        chmod +x ${MRSTONE_CONFIG_PATH}/scripts/is_workflow/$file
    done

    # Symlink the gcode_shell_command.py file in the correct Klipper folder (erased to always get the last version)
    ln -fsn ${MRSTONE_CONFIG_PATH}/scripts/gcode_shell_command.py ${KLIPPER_PATH}/klippy/extras

    # Create or update the config version tracking file in the user config directory
    git -C ${MRSTONE_CONFIG_PATH} rev-parse HEAD > ${USER_CONFIG_PATH}/.VERSION
}


# Helper function to ask and install the MCU templates if needed
function install_mcu_templates {
    local install_template file_list main_template install_toolhead_template toolhead_template install_ercf_template

    read < /dev/tty -rp "[CONFIG] Would you like to select and install MCU wiring templates files? (Y/n) " install_template
    if [[ -z "$install_template" ]]; then
        install_template="y"
    fi
    install_template="${install_template,,}"

    # Check and exit if the user do not wants to install an MCU template file
    if [[ "$install_template" =~ ^(no|n)$ ]]; then
        printf "[CONFIG] Skipping installation of MCU templates. You will need to manually populate your own mcu.cfg file!\n\n"
        return
    fi

    # Finally see if the user use an ERCF board
    read < /dev/tty -rp "[CONFIG] Do you have an ERCF MCU and want to install a template? (y/N) " install_ercf_template
    if [[ -z "$install_ercf_template" ]]; then
        install_ercf_template="n"
    fi
    install_ercf_template="${install_ercf_template,,}"

    # Check if the user wants to install an ERCF MCU template
    if [[ "$install_ercf_template" =~ ^(yes|y)$ ]]; then
        file_list=()
        while IFS= read -r -d '' file; do
            file_list+=("$file")
        done < <(find "${MRSTONE_CONFIG_PATH}/user_templates/mcu_defaults/ercf" -maxdepth 1 -type f -print0)
        echo "[CONFIG] Please select your ERCF MCU in the following list:"
        for i in "${!file_list[@]}"; do
            echo "  $((i+1))) $(basename "${file_list[i]}")"
        done

        read < /dev/tty -p "[CONFIG] Template to install (or 0 to skip): " ercf_template
        if [[ "$ercf_template" -gt 0 ]]; then
            # If the user selected a file, copy its content into the mcu.cfg file
            filename=$(basename "${file_list[$((ercf_template-1))]}")
            cat "${MRSTONE_CONFIG_PATH}/user_templates/mcu_defaults/ercf/$filename" >> ${USER_CONFIG_PATH}/mcu.cfg
            echo "[CONFIG] Template '$filename' inserted into your mcu.cfg user file"
            printf "[CONFIG] You must install ERCF Happy Hare from https://github.com/moggieuk/ERCF-Software-V3 to use ERCF with voronCFG\n\n"
        else
            printf "[CONFIG] No ERCF template selected. Skip and continuing...\n\n"
        fi
    fi
}


# Step 5: restarting Klipper
function restart_klipper {
    echo "[POST-INSTALL] Restarting Klipper..."
    sudo systemctl restart klipper
}


BACKUP_DIR="${BACKUP_PATH}/$(date +'%Y_%m_%d-%H%M%S')"

printf "\n======================================\n"
echo "- voronCFG install and update script -"
printf "======================================\n\n"

# Run steps
preflight_checks
check_download
backup_config
install_config
restart_klipper

echo "[POST-INSTALL] Everything is ok, voronCFG installed and up to date!"
echo "[POST-INSTALL] Be sure to check the breaking changes on the release page: https://github.com/mrstone14/voronCFG/releases"

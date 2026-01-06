#!/bin/bash

# Color Palette
G='\033[1;32m'
R='\033[0;31m'
B='\033[0;34m'
Y='\033[0;33m'
N='\033[0m'

# --- Helper Functions ---

# Display a message with a color
msg() {
    local text="$1"
    local color="$2"
    echo -e "${color}${text}${N}"
}

# Install necessary packages if they are not installed
install_package() {
    if ! dpkg -s "$1" &>/dev/null;
    then
        msg "Installing $1..." "$Y"
        apt-get update >/dev/null
        apt-get install -y "$1" >/dev/null
    fi
}

# Install jq if not available
install_package "jq"
JQ_CMD=$(which jq)

# --- Proxmox API Functions using whiptail ---

# Get available storages and let the user choose
select_storage() {
    local prompt_text=$1
    local content_type=$2
    local whiptail_options=()

    # ENHANCEMENT: Filter out storages with 0 available space
    while IFS=$'\t' read -r name desc; do
        whiptail_options+=("$name" "$desc")
    done < <(pvesh get /nodes/$(hostname)/storage --output-format json | "$JQ_CMD" -r '
        .[] |
        select(
            (has("disable") | not) and
            (.content | contains("'"$content_type"'")) and
            .type != "nfs" and .type != "cifs" and
            has("total") and has("avail") and .avail > 0
        ) |
        .storage + "\t" + "[" + .type + "] " + ((.avail / 1073741824) | tostring | .[0:5]) + "G / " + ((.total / 1073741824) | tostring | .[0:5]) + "G"
    ')

    if [ ${#whiptail_options[@]} -eq 0 ]; then
        whiptail --msgbox "No suitable storage with available space found for content type '$content_type'." 10 70
        exit 1
    fi

    selected_storage=$(whiptail --title "Storage Selection" --menu "$prompt_text" 20 78 10 "${whiptail_options[@]}" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then msg "Canceled." "$R"; exit 1; fi

    echo "$selected_storage"
}

# Get available network bridges and let the user choose
select_bridge() {
    local prompt_text=$1
    local whiptail_options=()

    while IFS=$'\t' read -r name desc; do
        whiptail_options+=("$name" "$desc")
    done < <(pvesh get /nodes/$(hostname)/network --output-format json | "$JQ_CMD" -r '.[] | select(.type == "bridge" and (has("disable") | not)) | .iface + "\t" + (.cidr // "no CIDR")')

    if [ ${#whiptail_options[@]} -eq 0 ]; then
        whiptail --msgbox "No active network bridge found." 10 60
        exit 1
    fi

    selected_bridge=$(whiptail --title "Network Selection" --menu "$prompt_text" 20 78 10 "${whiptail_options[@]}" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then msg "Canceled." "$R"; exit 1; fi

    echo "$selected_bridge"
}


# --- Main Logic ---

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    msg "This script must be run as root." "$R"
    exit 1
fi

# Install dependencies
install_package "unzip"
install_package "whiptail"


# --- Script Flow Step 1: Core VM Config ---
whiptail --title "Step 1: Core VM Configuration" --msgbox "This step configures the basic information for the virtual machine.\n\nYou will enter the ID, Name, number of CPU cores, and Memory (RAM) in sequence." 10 70
if [ $? -ne 0 ]; then msg "Canceled." "$R"; exit 1; fi

VMID=$(whiptail --inputbox "Enter VM ID" 10 60 "$(pvesh get /cluster/nextid)" 3>&1 1>&2 2>&3)
if [ $? -ne 0 ] || [ -z "$VMID" ]; then msg "Canceled or VM ID empty." "$R"; exit 1; fi

VMNAME=$(whiptail --inputbox "Enter VM Name" 10 60 "Xpenology" 3>&1 1>&2 2>&3)
if [ $? -ne 0 ] || [ -z "$VMNAME" ]; then msg "Canceled or VM Name empty." "$R"; exit 1; fi

CORES=$(whiptail --inputbox "Enter CPU Cores" 10 60 "4" 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then msg "Canceled." "$R"; exit 1; fi
if ! [[ "$CORES" =~ ^[0-9]+$ ]]; then msg "Invalid number of cores." "$R"; exit 1; fi

RAM=$(whiptail --inputbox "Enter RAM in MB" 10 60 "4096" 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then msg "Canceled." "$R"; exit 1; fi
if ! [[ "$RAM" =~ ^[0-9]+$ ]]; then msg "Invalid RAM size." "$R"; exit 1; fi


# --- Script Flow Step 2: Storage Config ---
whiptail --title "Step 2: Data Disk Configuration" --msgbox "This step configures the VM's main data disk.\n\nYou will select the disk bus type, disk capacity, and the storage where the disk will be created." 10 70
if [ $? -ne 0 ]; then msg "Canceled." "$R"; exit 1; fi

BUS_CHOICE=$(whiptail --title "Disk Bus Type" --menu "Select the disk bus type for the VM." 15 60 2 \
"1" "VirtIO SCSI (DS3622xs+)" \
"2" "SATA (SA6400, DS920+, etc)" 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then msg "Canceled." "$R"; exit 1; fi

case $BUS_CHOICE in
    1) BUS_TYPE_PARAM="scsi";;
    2) BUS_TYPE_PARAM="sata";;
    *) msg "Invalid choice. Exiting." "$R"; exit 1;;
esac

DISK_SIZE=$(whiptail --inputbox "Enter Data Disk Size in GB" 10 60 "32" 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then msg "Canceled." "$R"; exit 1; fi
if ! [[ "$DISK_SIZE" =~ ^[0-9]+$ ]]; then msg "Invalid disk size." "$R"; exit 1; fi

DATA_STORAGE=$(select_storage "Please select the storage for the DATA disk (${DISK_SIZE}G)." "images")


# --- Script Flow Step 3: Network Config ---
whiptail --title "Step 3: Network Configuration" --msgbox "This step selects the network bridge for the virtual machine.\n\nThis is typically 'vmbr0'." 10 70
if [ $? -ne 0 ]; then msg "Canceled." "$R"; exit 1; fi
BRIDGE=$(select_bridge "Please select the network bridge for the VM.")


# --- Script Flow Step 4: Bootloader Configuration (Local Image) ---
whiptail --title "Step 4: Bootloader Configuration" --msgbox "This step configures the bootloader for Xpenology.\n\nThe script will use the local image file:\ntinycore-redpill.v1.2.6.9.m-shell-4GB.img\n\nThis bootloader will be attached as a bootable disk (8GB)." 12 70
if [ $? -ne 0 ]; then msg "Canceled." "$R"; exit 1; fi

# Use local bootloader image from Proxmox ISO directory
BOOTLOADER_DIR="/var/lib/vz/template/iso"
LOCAL_IMAGE="tinycore-redpill.v1.2.6.9.m-shell-4GB.img"
IMG_PATH="${BOOTLOADER_DIR}/${LOCAL_IMAGE}"

# Check if the local image exists
if [ ! -f "$IMG_PATH" ]; then
    msg "ERROR: Local bootloader image not found at ${IMG_PATH}" "$R"
    msg "Please ensure '${LOCAL_IMAGE}' is placed in ${BOOTLOADER_DIR}" "$R"
    exit 1
fi

msg "Found local bootloader image: ${IMG_PATH}" "$G"

# Select storage for bootloader disk (8GB)
BOOTLOADER_STORAGE=$(select_storage "Please select the storage for the BOOTLOADER disk (8G)." "images")


# --- Script Flow Step 5: Final VM Creation and Configuration ---
msg "Step 5: Creating and configuring VM ${VMID}..." "$Y"
qm create "$VMID" --name "$VMNAME" --memory "$RAM" --cores "$CORES" --bios seabios --ostype l26
if [ $? -ne 0 ]; then msg "Failed to create VM." "$R"; exit 1; fi

if [ "$BUS_TYPE_PARAM" == "scsi" ]; then
    qm set "$VMID" --scsihw virtio-scsi-pci
fi

# Create data disk
qm set "$VMID" --"${BUS_TYPE_PARAM}0" "${DATA_STORAGE}:${DISK_SIZE},discard=on,ssd=1"

# Add network after VM creation
qm set "$VMID" --net0 virtio,bridge="$BRIDGE"

# Create 8GB bootloader disk and import the local image
msg "Creating 8GB bootloader disk and importing local image..." "$Y"

# Create a new disk on the selected storage
qm disk import "$VMID" "$IMG_PATH" "$BOOTLOADER_STORAGE" --format raw
if [ $? -ne 0 ]; then msg "Failed to import bootloader disk." "$R"; exit 1; fi

# The imported disk will be unused0, so we need to attach it
# Find the unused disk (usually unused0)
UNUSED_DISK=$(qm config "$VMID" | grep "^unused" | head -n 1 | cut -d: -f1)
if [ -z "$UNUSED_DISK" ]; then
    msg "ERROR: Could not find imported disk." "$R"
    exit 1
fi

# Attach the imported disk as bootable disk
# Using SATA for bootloader to ensure compatibility
qm set "$VMID" --sata1 "${BOOTLOADER_STORAGE}:vm-${VMID}-disk-1,size=8G"
qm set "$VMID" --boot order=sata1

msg "Bootloader disk attached and set as boot device." "$G"

msg "VM configuration complete!" "$G"

# --- Ask to start VM ---
if (whiptail --title "Start VM?" --yesno "Would you like to start the new virtual machine now?" 10 60) then
    msg "Starting VM ${VMID}..." "$Y"
    qm start "$VMID"
    VM_STATUS="Started"
else
    VM_STATUS="Created (Not Started)"
fi

# --- Final Summary ---
whiptail --title "All Done!" --msgbox "Virtual machine creation process is complete.\n\nPlease check the summary information printed in the terminal below." 10 70

msg "--- VM Summary ---" "$B"
msg "VM ID: $VMID" "$G"
msg "VM Name: $VMNAME" "$G"
msg "Status: $VM_STATUS" "$G"
msg "CPU Cores: $CORES" "$G"
msg "RAM: $RAM MB" "$G"
msg "Disk Bus: $BUS_TYPE_PARAM" "$G"
msg "Network: $BRIDGE" "$G"
msg "Bootloader: 8GB disk imported from ${IMG_PATH}" "$G"
msg "Bootloader Storage: $BOOTLOADER_STORAGE" "$G"
msg "Data Disk: ${DISK_SIZE}G on $DATA_STORAGE" "$G"
msg "------------------" "$B"
msg "You can now manage the VM from the Proxmox web interface." "$Y"

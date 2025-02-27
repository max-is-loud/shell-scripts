#!/usr/bin/env bash

# NVIDIA GPU Passthrough Setup Script for Proxmox
# Based on the "Ultimate Beginner's Guide to GPU Passthrough"

# Ensure the script is run as root
if [[ $(id -u) -ne 0 ]]; then
  echo "ERROR: This script must be run as root."
  exit 1
fi

# Check if Gum is installed
if ! command -v gum &>/dev/null; then
  echo "Gum is not installed. Would you like to install it now? (yes/no)"
  read -r INSTALL_GUM
  if [[ "$INSTALL_GUM" == "yes" ]]; then
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
    sudo apt update && sudo apt install gum
  else
    echo "Continuing without Gum..."
    USE_GUM=false
  fi
else
  USE_GUM=true
fi

# Check for required commands
for cmd in lspci grep sed awk modprobe; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not installed. Please install it and rerun the script."
    exit 1
  fi
done

# Function to use gum if available
gum_echo() {
  if [ "$USE_GUM" == "true" ]; then
    gum style --bold "$1"
  else
    echo "$1"
  fi
}

# Function to use gum spin if available
gum_spin() {
  if [ "$USE_GUM" == "true" ]; then
    gum spin --spinner dot --title "$1" -- sleep 1
  else
    echo "$1..."
    sleep 1
  fi
}

# 1. Enable IOMMU
gum_spin "Enabling IOMMU"

# Determine CPU vendor
CPU_VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')

if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
  IOMMU_PARAM="intel_iommu=on"
elif [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
  IOMMU_PARAM="amd_iommu=on"
else
  gum_echo "ERROR: Unsupported CPU vendor: $CPU_VENDOR"
  exit 1
fi

# Update GRUB configuration
GRUB_FILE="/etc/default/grub"
if ! grep -q "$IOMMU_PARAM" "$GRUB_FILE"; then
  gum_echo "Adding IOMMU parameter to GRUB..."
  sed -i.bak "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"$IOMMU_PARAM /" "$GRUB_FILE"
  update-grub
fi

# 2. Load necessary kernel modules
gum_spin "Loading necessary kernel modules"

MODULES_FILE="/etc/modules"
MODULES=("vfio" "vfio_iommu_type1" "vfio_pci" "vfio_virqfd")

for module in "${MODULES[@]}"; do
  if ! grep -q "^$module" "$MODULES_FILE"; then
    echo "$module" >> "$MODULES_FILE"
  fi
done

# 3. Identify GPU and associated devices
gum_spin "Identifying NVIDIA GPU"

GPU_INFO=$(lspci -nn | grep -i "NVIDIA" | grep -E "VGA|3D")
if [[ -z "$GPU_INFO" ]]; then
  gum_echo "ERROR: No NVIDIA GPU found."
  exit 1
fi

gum_echo "Detected GPU(s):"
echo "$GPU_INFO"
echo

GPU_SELECTION=$(echo "$GPU_INFO" | head -n 1)
GPU_BUS=$(echo "$GPU_SELECTION" | awk '{print $1}')
GPU_ID=$(echo "$GPU_SELECTION" | awk -F'[][]' '{print $2}')

AUDIO_INFO=$(lspci -nn | grep -i "Audio" | grep "${GPU_BUS%.*}.")
if [[ -n "$AUDIO_INFO" ]]; then
  AUDIO_ID=$(echo "$AUDIO_INFO" | awk -F'[][]' '{print $2}')
  VFIO_IDS="$GPU_ID,$AUDIO_ID"
else
  VFIO_IDS="$GPU_ID"
fi

gum_echo "Selected GPU: $GPU_BUS with ID(s): $VFIO_IDS"

# 4. Configure vfio-pci to bind to the GPU
gum_spin "Configuring vfio-pci"
VFIO_CONF="/etc/modprobe.d/vfio.conf"
echo "options vfio-pci ids=$VFIO_IDS" > "$VFIO_CONF"

# 5. Blacklist NVIDIA drivers
gum_spin "Blacklisting NVIDIA drivers"
BLACKLIST_CONF="/etc/modprobe.d/blacklist-nvidia.conf"
cat <<EOF > "$BLACKLIST_CONF"
blacklist nouveau
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
blacklist nvidiafb
EOF

echo "install nvidia /bin/false" > /etc/modprobe.d/nvidia-block.conf
echo "install nouveau /bin/false" >> /etc/modprobe.d/nvidia-block.conf

# 6. Unload NVIDIA drivers before rebuilding
gum_spin "Unloading NVIDIA drivers"
for drv in nvidia_drm nvidia_modeset nvidia_uvm nvidia nouveau nvidiafb; do
  if lsmod | grep -q "$drv"; then
    gum_echo "Removing $drv..."
    modprobe -r "$drv" || gum_echo "Failed to remove $drv!"
  fi
done

gum_echo "All NVIDIA drivers unloaded."

# 7. Update initramfs
gum_spin "Updating initramfs"
update-initramfs -u

gum_echo "Setup complete. Please reboot your system to apply the changes."

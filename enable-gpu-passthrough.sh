#!/usr/bin/env bash
#
# auto_vfio_setup.sh
#
# Purpose:
#   - Detect and enable IOMMU (Intel or AMD) if not already done
#   - Let user pick an NVIDIA GPU from a list (via gum)
#   - Automatically retrieve vendor:device IDs for GPU and audio function
#   - Configure /etc/modprobe.d/vfio.conf and /etc/default/grub
#   - Rebuild initramfs and update-grub if changed
#   - (Optional) Attach GPU to a chosen VM
#
# Requirements:
#   - Proxmox 7.x or 8.x
#   - gum
#   - lspci (from pciutils)
#   - root privileges
#
# Test thoroughly before production use!

# -------------------------
# 0. Pre-flight Checks
# -------------------------
for cmd in gum lspci; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' not found. Please install it. (e.g., apt install gum pciutils)"
    exit 1
  fi
done

if [[ $(id -u) -ne 0 ]]; then
  echo "ERROR: Script must be run as root (sudo)."
  exit 1
fi

GRUB_FILE="/etc/default/grub"
VFIO_CONF="/etc/modprobe.d/vfio.conf"
CPU_VENDOR="$(awk -F': ' '/vendor_id/{print $2; exit}' /proc/cpuinfo | tr -d ' \t')"

gum style --bold --border normal --margin "1" --padding "1" --align center \
  "Automated NVIDIA GPU Passthrough Setup for Proxmox"

# -------------------------
# 1. Detect or Enable IOMMU in GRUB
# -------------------------
# We'll figure out if the user is on Intel or AMD,
# then see if the correct params are already in /proc/cmdline
# or in /etc/default/grub. If missing, we can add them.

if echo "$CPU_VENDOR" | grep -iq 'amd'; then
  IOMMU_PARAM="amd_iommu=on"
else
  IOMMU_PARAM="intel_iommu=on"
fi

gum style --bold "Checking if IOMMU is enabled for $CPU_VENDOR..."

PROC_CMDLINE=$(cat /proc/cmdline)
if echo "$PROC_CMDLINE" | grep -q "$IOMMU_PARAM"; then
  gum style --foreground 2 "IOMMU already appears active ($IOMMU_PARAM) in /proc/cmdline."
else
  gum style --foreground 214 "IOMMU parameter ($IOMMU_PARAM) not detected in /proc/cmdline."
  gum confirm "Add $IOMMU_PARAM and 'iommu=pt' to GRUB?" && {
    # We'll read the current line from /etc/default/grub
    CURRENT_CMDLINE=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" \
      | sed -E 's/GRUB_CMDLINE_LINUX_DEFAULT="(.*)"/\1/')

    # We'll append the needed parameters if not present
    for param in "$IOMMU_PARAM" "iommu=pt"; do
      if ! grep -q "$param" <<< "$CURRENT_CMDLINE"; then
        CURRENT_CMDLINE="$CURRENT_CMDLINE $param"
      fi
    done

    sed -i.bak "/^GRUB_CMDLINE_LINUX_DEFAULT=/c\\GRUB_CMDLINE_LINUX_DEFAULT=\"${CURRENT_CMDLINE}\"" "$GRUB_FILE"
    gum style --foreground 2 "Updated $GRUB_FILE (backup at ${GRUB_FILE}.bak)."
  }
fi

# -------------------------
# 2. Prompt user for GPU selection
# -------------------------
gum style --bold "Scanning for NVIDIA GPUs via lspci..."

# We'll gather lines containing 'NVIDIA' for VGA or 3D devices
# Then parse them with gum. Show both the bus address & vendor:device code.
GPU_LINES=$(
  lspci -nn | grep -i "NVIDIA" | grep -E "VGA|3D" \
  || true
)

if [[ -z "$GPU_LINES" ]]; then
  gum style --foreground 196 "No NVIDIA GPU found in lspci output. Exiting."
  exit 0
fi

# Let the user pick from the discovered GPUs
gum style "Select your primary NVIDIA GPU (VGA/3D device):"
SELECTED_GPU_LINE=$(echo "$GPU_LINES" | gum choose --no-limit=false)
if [[ -z "$SELECTED_GPU_LINE" ]]; then
  gum style --foreground 214 "No GPU selected. Exiting."
  exit 0
fi

# Example line looks like:
# "09:00.0 VGA compatible controller [0300]: NVIDIA Corporation GA102 [GeForce RTX 3080 Ti] [10de:2208] (rev a1)"
# We want "09:00.0" as the bus, "10de:2208" as the vendor:device, etc.
GPU_BUSID=$(echo "$SELECTED_GPU_LINE" | awk '{print $1}')
GPU_VEND_DEV=$(echo "$SELECTED_GPU_LINE" | sed -E 's/.*\[(....:....)\].*/\1/')

gum style --bold "Selected GPU -> Bus: $GPU_BUSID, IDs: $GPU_VEND_DEV"

# Next, let's see if there's a matching 'Audio device' with the same leading bus portion (e.g. '09:00.1')
# We'll do lspci -nn again, looking for that bus minus the last digit -> "09:00."
BUS_PREFIX="${GPU_BUSID%.*}."
AUDIO_LINE=$(
  lspci -nn | grep -i "Audio device" | grep "$BUS_PREFIX" || true
)
AUDIO_VEND_DEV=""
if [[ -n "$AUDIO_LINE" ]]; then
  # e.g. "09:00.1 Audio device [0403]: NVIDIA Corporation GA102 High Definition Audio Controller [10de:1aef] (rev a1)"
  AUDIO_VEND_DEV=$(echo "$AUDIO_LINE" | sed -E 's/.*\[(....:....)\].*/\1/')
  gum style "Detected audio function for GPU at $BUS_PREFIX -> $AUDIO_VEND_DEV"
fi

# Combine them (if we have audio device)
if [[ -n "$AUDIO_VEND_DEV" ]]; then
  VFIO_IDS="$GPU_VEND_DEV,$AUDIO_VEND_DEV"
else
  VFIO_IDS="$GPU_VEND_DEV"
fi

gum style --bold "Will use vfio-pci.ids=$VFIO_IDS"

# -------------------------
# 3. Update /etc/modprobe.d/vfio.conf if needed
# -------------------------
# We'll see if there's an existing line with 'vfio-pci.ids=' in it. If not, we create or update.

if [[ -f "$VFIO_CONF" ]]; then
  CURRENT_VFIO_IDS=$(grep "^options vfio-pci ids=" "$VFIO_CONF" | sed -E 's/options vfio-pci ids=(.*)/\1/' || true)
  if echo "$CURRENT_VFIO_IDS" | grep -q "$VFIO_IDS"; then
    gum style --foreground 2 "vfio.conf already lists $VFIO_IDS. No changes needed."
  else
    gum confirm "Append/Replace VFIO IDs in $VFIO_CONF? (Currently: '$CURRENT_VFIO_IDS')" && {
      sed -i.bak "/^options vfio-pci ids=/c\options vfio-pci ids=$VFIO_IDS" "$VFIO_CONF"
      gum style --foreground 2 "Updated $VFIO_CONF (backup at $VFIO_CONF.bak)."
    }
  fi
else
  gum style --bold "Creating $VFIO_CONF with vfio-pci.ids=$VFIO_IDS"
  cat <<EOF > "$VFIO_CONF"
# Automatically generated by auto_vfio_setup.sh
options vfio-pci ids=$VFIO_IDS
options vfio-pci disable_vga=1
EOF
fi

# -------------------------
# 4. Check for blacklisting nouveau/nvidia if needed
# -------------------------
# We'll create or update a blacklist file if we see that the modules are not blacklisted.

BLACKLIST_FILE="/etc/modprobe.d/blacklist-nouveau.conf"
if [[ ! -f "$BLACKLIST_FILE" ]]; then
  gum confirm "Would you like to blacklist 'nouveau' and 'nvidia' modules? (Recommended for passthrough)" && {
    cat <<EOF > "$BLACKLIST_FILE"
# Blacklist nouveau or nvidia so host does NOT load them
blacklist nouveau
blacklist nvidia
blacklist nvidiafb
options nouveau modeset=0
EOF
    gum style --foreground 2 "Created $BLACKLIST_FILE."
  }
else
  gum style "File $BLACKLIST_FILE already exists. Review it if you still see nouveau/nvidia loading on host."
fi

# -------------------------
# 5. Insert 'vfio-pci.ids=...' into GRUB_CMDLINE_LINUX_DEFAULT if missing
# -------------------------
CURRENT_CMDLINE=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" \
  | sed -E 's/GRUB_CMDLINE_LINUX_DEFAULT="(.*)"/\1/')

if ! echo "$CURRENT_CMDLINE" | grep -q "vfio-pci.ids="; then
  gum confirm "Add 'vfio-pci.ids=$VFIO_IDS' to GRUB_CMDLINE_LINUX_DEFAULT?" && {
    NEW_CMDLINE="$CURRENT_CMDLINE vfio-pci.ids=$VFIO_IDS"
    sed -i.bak "/^GRUB_CMDLINE_LINUX_DEFAULT=/c\\GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW_CMDLINE}\"" "$GRUB_FILE"
    gum style --foreground 2 "Updated $GRUB_FILE (backup at ${GRUB_FILE}.bak)."
  }
else
  gum style --foreground 2 "vfio-pci.ids already present in GRUB_CMDLINE_LINUX_DEFAULT. No changes made."
fi

# -------------------------
# 6. Update initramfs / GRUB if we changed anything
# -------------------------
# We'll guess that if the user changed any of the above config, they'd want to rebuild. Let's just prompt.

gum confirm "Rebuild initramfs and run update-grub now (recommended)?" && {
  gum spin --spinner dot --title "update-initramfs -u -k all" -- \
    update-initramfs -u -k all
  gum spin --spinner dot --title "update-grub" -- \
    update-grub
  gum style --foreground 2 "Initramfs & GRUB updated. Reboot required to apply changes."
}

# -------------------------
# 7. (Optional) Attach GPU to a VM
# -------------------------
gum confirm "Attach the selected GPU to a Proxmox VM now?" && {
  gum style --bold "Listing available VMs..."
  qm list
  VM_ID=$(gum input --placeholder "Enter VM ID (e.g. 100)")
  if [[ -z "$VM_ID" ]]; then
    gum style --foreground 214 "No VM ID provided. Skipping."
  else
    # We'll guess we use hostpci0. If the user is passing multiple devices, they'd do hostpci1, etc.
    gum style --bold "Which hostpci index do you want to use? (Default: 0)"
    HOSTPCI_IDX=$(gum input --placeholder "0")
    [ -z "$HOSTPCI_IDX" ] && HOSTPCI_IDX=0

    VM_CONF="/etc/pve/qemu-server/${VM_ID}.conf"
    if [[ ! -f "$VM_CONF" ]]; then
      gum style --foreground 196 "ERROR: $VM_CONF not found. VM ID invalid?"
    else
      # We'll add a line. If we have GPU + audio, we do e.g.:
      # hostpci0: 09:00.0,pcie=1,multifunction=on;09:00.1
      # But we only know the bus addresses. We had GPU_BUSID for the main device, let's see if we have audio at .1
      # If the user used an audio device, we have AUDIO_VEND_DEV, but let's see if we discovered a bus line for it.
      # We'll guess that if $AUDIO_VEND_DEV is not empty, the audio bus is GPU_BUSID but .1
      GPU_AUDIO_BUS="${BUS_PREFIX}1"

      if [[ -n "$AUDIO_VEND_DEV" ]]; then
        echo "hostpci${HOSTPCI_IDX}: ${GPU_BUSID},pcie=1,multifunction=on;${GPU_AUDIO_BUS}" >> "$VM_CONF"
        gum style --foreground 2 "Added passthrough line to $VM_CONF: hostpci${HOSTPCI_IDX}: ${GPU_BUSID},...,${GPU_AUDIO_BUS}"
      else
        echo "hostpci${HOSTPCI_IDX}: ${GPU_BUSID},pcie=1" >> "$VM_CONF"
        gum style --foreground 2 "Added passthrough line to $VM_CONF: hostpci${HOSTPCI_IDX}: ${GPU_BUSID}"
      fi
    fi
  fi
}

gum style --bold --border normal --margin "1" --padding "1" --align center --foreground 2 \
  "All Done!" \
  "If changes were made, reboot your Proxmox host for them to take effect."
exit 0

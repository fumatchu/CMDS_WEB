#!/bin/bash
# CMDS-GO Bootstrap Installer
# Fetches repo and launches the main install script

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
TEXTRESET="\033[0m"
CYAN="\e[36m"
RESET="\e[0m"

FORCE_PLATFORM="${FORCE_PLATFORM:-}"
USER=$(whoami)

clear
echo -e "${CYAN}CMDS-GO${TEXTRESET} ${YELLOW}Bootstrap${TEXTRESET}"
echo ""

# =============================================================
# PLATFORM DETECTION
# =============================================================
detect_platform() {
  if [[ -n "$FORCE_PLATFORM" ]]; then
    case "$FORCE_PLATFORM" in
      rpi4)
        echo -e "[${GREEN}SUCCESS${TEXTRESET}] Platform: Raspberry Pi 4 [FORCED]"
        DETECTED_PLATFORM="rpi"; DETECTED_PLATFORM_DETAIL="Raspberry Pi 4 [FORCED]"; return 0 ;;
      rpi5)
        echo -e "[${GREEN}SUCCESS${TEXTRESET}] Platform: Raspberry Pi 5 [FORCED]"
        DETECTED_PLATFORM="rpi"; DETECTED_PLATFORM_DETAIL="Raspberry Pi 5 [FORCED]"; return 0 ;;
      rpi2|rpi3|rpi)
        echo -e "[${RED}ERROR${TEXTRESET}] Unsupported Raspberry Pi: ${FORCE_PLATFORM}"
        echo "Rocky Linux 10.1 requires Raspberry Pi 4 or newer. Exiting."; exit 1 ;;
      esxi)
        echo -e "[${GREEN}SUCCESS${TEXTRESET}] Platform: ESXi/VMware [FORCED]"
        DETECTED_PLATFORM="vmware"; DETECTED_PLATFORM_DETAIL="VMware [FORCED]"; return 0 ;;
      kvm)
        echo -e "[${GREEN}SUCCESS${TEXTRESET}] Platform: KVM/QEMU [FORCED]"
        DETECTED_PLATFORM="kvm"; DETECTED_PLATFORM_DETAIL="KVM [FORCED]"; return 0 ;;
      *)
        echo -e "[${RED}ERROR${TEXTRESET}] Unknown FORCE_PLATFORM: ${FORCE_PLATFORM}"
        echo "Valid: rpi4, rpi5, esxi, kvm"; exit 1 ;;
    esac
  fi

  DETECTED_PLATFORM="physical"
  DETECTED_PLATFORM_DETAIL="Unknown/Physical"

  if [[ -f /proc/device-tree/model ]]; then
    local model; model=$(tr -d '\0' </proc/device-tree/model)
    case "$model" in
      *"Raspberry Pi 4"*)
        echo -e "[${GREEN}SUCCESS${TEXTRESET}] Platform: Raspberry Pi 4"
        DETECTED_PLATFORM="rpi"; DETECTED_PLATFORM_DETAIL="Raspberry Pi 4"; return 0 ;;
      *"Raspberry Pi 5"*)
        echo -e "[${GREEN}SUCCESS${TEXTRESET}] Platform: Raspberry Pi 5"
        DETECTED_PLATFORM="rpi"; DETECTED_PLATFORM_DETAIL="Raspberry Pi 5"; return 0 ;;
      *"Raspberry Pi"*)
        echo -e "[${RED}ERROR${TEXTRESET}] Unsupported Raspberry Pi: ${model}"
        echo "Rocky Linux 10.1 requires Raspberry Pi 4 or newer. Exiting."; exit 1 ;;
    esac
  fi

  local virt=""
  command -v systemd-detect-virt >/dev/null 2>&1 && virt=$(systemd-detect-virt 2>/dev/null || true)

  local dmi_product="" dmi_vendor=""
  [[ -r /sys/class/dmi/id/product_name ]] && dmi_product=$(tr -d '\0' </sys/class/dmi/id/product_name)
  [[ -r /sys/class/dmi/id/sys_vendor   ]] && dmi_vendor=$(tr -d '\0' </sys/class/dmi/id/sys_vendor)

  if [[ "$virt" == "vmware" ]] || [[ "$dmi_vendor" =~ VMware ]] || [[ "$dmi_product" =~ VMware ]]; then
    echo -e "[${GREEN}SUCCESS${TEXTRESET}] Platform: ESXi/VMware (${dmi_product:-vmware})"
    DETECTED_PLATFORM="vmware"; DETECTED_PLATFORM_DETAIL="${dmi_product:-vmware}"; return 0
  fi

  if [[ "$virt" == "kvm" || "$virt" == "qemu" ]] || [[ "$dmi_product" =~ KVM|QEMU ]] || [[ "$dmi_vendor" =~ QEMU|Red\ Hat|oVirt ]]; then
    echo -e "[${GREEN}SUCCESS${TEXTRESET}] Platform: KVM/QEMU (${dmi_product:-$virt})"
    DETECTED_PLATFORM="kvm"; DETECTED_PLATFORM_DETAIL="${dmi_product:-$virt}"; return 0
  fi

  if [[ -n "$virt" && "$virt" != "none" ]]; then
    echo -e "[${YELLOW}INFO${TEXTRESET}] Platform: Virtual Machine (${virt})"
    DETECTED_PLATFORM="vm"; DETECTED_PLATFORM_DETAIL="$virt"; return 0
  fi

  echo -e "[${YELLOW}INFO${TEXTRESET}] Platform: Unknown/Physical"
}

# =============================================================
# DISK SPACE CHECK
# =============================================================
get_root_free_gb() {
  local gb; gb=$(df -BG / | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
  [[ "$gb" =~ ^[0-9]+$ ]] && echo "$gb" || echo ""
}

# =============================================================
# ROOT CHECK
# =============================================================
detect_platform

if [[ "$USER" != "root" ]]; then
  echo -e "[${RED}ERROR${TEXTRESET}] This installer must be run as root."
  exit 1
fi
echo -e "[${GREEN}SUCCESS${TEXTRESET}] Running as root."
sleep 1

# =============================================================
# OS VERSION CHECK (Rocky 10.1+)
# =============================================================
OSVER_RAW=""
[[ -f /etc/os-release ]] && OSVER_RAW=$(grep -oP '(?<=^VERSION_ID=")[^"]+' /etc/os-release 2>/dev/null)
[[ -z "$OSVER_RAW" && -f /etc/redhat-release ]] && OSVER_RAW=$(grep -oE '[0-9]+(\.[0-9]+)?' /etc/redhat-release | head -1)

if [[ -z "$OSVER_RAW" ]]; then
  echo -e "[${RED}ERROR${TEXTRESET}] Cannot detect OS version. Exiting."; exit 1
fi

OSVER_MAJOR=$(echo "$OSVER_RAW" | awk -F. '{print $1}')
OSVER_MINOR=$(echo "$OSVER_RAW" | awk -F. '{print ($2==""?0:$2)}')

if (( OSVER_MAJOR > 10 || (OSVER_MAJOR == 10 && OSVER_MINOR >= 1) )); then
  echo -e "[${GREEN}SUCCESS${TEXTRESET}] Rocky Linux ${OSVER_MAJOR}.${OSVER_MINOR} — compatible."
  sleep 1
else
  echo -e "[${RED}ERROR${TEXTRESET}] Rocky Linux 10.1+ required. Detected: ${OSVER_MAJOR}.${OSVER_MINOR}"
  exit 1
fi

# =============================================================
# DISK SPACE CHECK
# =============================================================
ROOT_FREE_GB="$(get_root_free_gb)"
if [[ -z "$ROOT_FREE_GB" ]]; then
  echo -e "[${RED}ERROR${TEXTRESET}] Cannot determine disk space. Exiting."; exit 1
fi
if (( ROOT_FREE_GB >= 8 )); then
  echo -e "[${GREEN}SUCCESS${TEXTRESET}] Disk space: ${ROOT_FREE_GB}GB available (8GB required)."
  sleep 1
else
  echo -e "[${RED}ERROR${TEXTRESET}] Insufficient disk: ${ROOT_FREE_GB}GB available, 8GB required."
  exit 1
fi

# =============================================================
# INSTALL BOOTSTRAP DEPENDENCIES
# =============================================================
echo ""
echo -e "${CYAN}==> Installing bootstrap dependencies...${TEXTRESET}"

spinner() {
  local pid=$1 delay=0.1 spinstr='|/-\\'
  while ps -p "$pid" >/dev/null 2>&1; do
    for i in $(seq 0 3); do
      printf "\r[${YELLOW}INFO${TEXTRESET}] Working... ${spinstr:$i:1}"
      sleep $delay
    done
  done
  printf "\r[${GREEN}SUCCESS${TEXTRESET}] Done.                \n"
}

dnf -y install wget git ipcalc dialog >/dev/null 2>&1 &
spinner $!

# =============================================================
# CLONE REPO
# =============================================================
echo ""
echo -e "${CYAN}==> Fetching CMDS-GO from GitHub...${TEXTRESET}"
sleep 1

rm -rf /root/CMDS_WEBInstaller
mkdir -p /root/CMDS_WEBInstaller
git clone https://github.com/fumatchu/CMDS_WEB.git /root/CMDS_WEBInstaller

chmod 700 /root/CMDS_WEBInstaller/*.sh 2>/dev/null || true

echo -e "[${YELLOW}INFO${TEXTRESET}] Removing git..."
dnf -y remove git >/dev/null 2>&1

clear
echo -e "${CYAN}CMDS-GO${RESET} ${YELLOW}Installer${TEXTRESET}"
sleep 2
echo ""

# =============================================================
# LAUNCH MAIN INSTALLER
# =============================================================
items=(1 "Install CMDS-GO Server")

while choice=$(dialog --title "CMDS-GO" \
  --backtitle "Server Installer" \
  --menu "Select install type" 15 65 3 "${items[@]}" \
  2>&1 >/dev/tty); do
  case $choice in
    1) /root/CMDS_WEBInstaller/CMDS_WEBInstall.sh ;;
  esac
done

clear

#!/usr/bin/env bash
# CMDS-GO Main Installer
# Requires: Rocky Linux 10.1+, run as root

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
TEXTRESET="\033[0m"
CYAN="\e[36m"
RESET="\e[0m"

SRC_BASE="/root/CMDS_WEBInstaller"
INSTALL_BASE="/opt/cmds-go"
LOGDIR="/var/log/cmds-installer"
mkdir -p "$LOGDIR"

clear
echo -e "${CYAN}CMDS-GO${TEXTRESET} ${YELLOW}Installation${TEXTRESET}"

# =============================================================
# STATUS OUTPUT HELPERS
# step_ok "message"   -> [✓] message  (green)
# step_fail "message" -> [✗] message  (red)
# step_info "message" -> [→] message  (yellow)
# =============================================================
step_ok()   { echo -e "  [${GREEN}✓${TEXTRESET}] $*"; }
step_fail() { echo -e "  [${RED}✗${TEXTRESET}] $*"; }
step_info() { echo -e "  [${YELLOW}→${TEXTRESET}] $*"; }
section()   { echo ""; echo -e "${CYAN}── $* ──${TEXTRESET}"; }

# =============================================================
# VALIDATION HELPERS
# =============================================================
validate_cidr() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]; }
validate_ip()   { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
validate_fqdn() { [[ "$1" =~ ^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$ ]]; }

check_hostname_in_domain() {
  local fqdn="$1" hostname="${1%%.*}" domain="${1#*.}"
  [[ ! "$domain" =~ (^|\.)"$hostname"(\.|$) ]]
}

ip_to_int() { local IFS=.; read -r a b c d <<<"$1"; echo $(( (a<<24)+(b<<16)+(c<<8)+d )); }
int_to_ip() { local i=$1; printf "%d.%d.%d.%d" $(( (i>>24)&255 )) $(( (i>>16)&255 )) $(( (i>>8)&255 )) $(( i&255 )); }
cidr_to_netmask() { local c=$1 m=$(( 0xFFFFFFFF << (32-$1) & 0xFFFFFFFF )); int_to_ip "$m"; }
network_from_ip_cidr() { int_to_ip $(( $(ip_to_int "$1") & $(( 0xFFFFFFFF << (32-$2) & 0xFFFFFFFF )) )); }
broadcast_from_ip_cidr() { int_to_ip $(( $(ip_to_int "$1") | (~$(( 0xFFFFFFFF << (32-$2) & 0xFFFFFFFF )) & 0xFFFFFFFF) )); }
ip_in_cidr() {
  local m=$(( 0xFFFFFFFF << (32-$3) & 0xFFFFFFFF ))
  (( ( $(ip_to_int "$1") & m ) == ( $(ip_to_int "$2") & m ) ))
}
is_valid_ip() {
  [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=.; local o; for o in $1; do [[ $o -ge 0 && $o -le 255 ]] || return 1; done
}
is_valid_domain() {
  [[ -n "$1" ]] || return 1
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

# =============================================================
# STEP 1 — ROOT + OS CHECK
# =============================================================
check_root_and_os() {
  section "System Checks"

  if [[ $EUID -eq 0 ]]; then
    step_ok "Running as root"
  else
    step_fail "Must be run as root"
    exit 1
  fi

  if [[ -f /etc/redhat-release ]]; then
    MAJOROS=$(grep -oP '\d+' /etc/redhat-release | head -1)
  else
    step_fail "/etc/redhat-release not found — cannot detect OS"
    exit 1
  fi

  if [[ "$MAJOROS" -ge 10 ]]; then
    step_ok "OS check passed (Rocky Linux ${MAJOROS}.x)"
  else
    step_fail "Rocky Linux 10+ required (detected: ${MAJOROS})"
    exit 1
  fi
  sleep 1
}

# =============================================================
# STEP 2 — SELINUX
# =============================================================
check_and_enable_selinux() {
  section "SELinux"
  local status; status=$(getenforce 2>/dev/null || echo "Unknown")

  if [[ "$status" == "Enforcing" ]]; then
    step_ok "SELinux is Enforcing"
  else
    step_info "SELinux is ${status} — enabling..."
    sed -i 's/SELINUX=disabled/SELINUX=enforcing/' /etc/selinux/config
    sed -i 's/SELINUX=permissive/SELINUX=enforcing/' /etc/selinux/config
    setenforce 1 2>/dev/null || true
    if [[ "$(getenforce)" == "Enforcing" ]]; then
      step_ok "SELinux enabled (Enforcing)"
    else
      step_fail "SELinux could not be set to Enforcing — check config manually"
    fi
  fi
  sleep 1
}

# =============================================================
# STEP 3 — NETWORK INTERFACE DETECTION
# =============================================================
detect_active_interface() {
  section "Network Interface"
  dialog --backtitle "Network Setup" --title "Interface Check" \
    --infobox "Detecting active network interface..." 5 50; sleep 2

  INTERFACE=$(nmcli -t -f DEVICE,TYPE,STATE device | grep "ethernet:connected" | cut -d: -f1 | head -n1)
  [[ -z "$INTERFACE" ]] && INTERFACE=$(ip -o -4 addr show up | grep -v ' lo ' | awk '{print $2}' | head -n1)

  if [[ -n "$INTERFACE" ]]; then
    CONNECTION=$(nmcli -t -f NAME,DEVICE connection show | grep ":$INTERFACE" | cut -d: -f1)
  fi

  echo "INTERFACE=$INTERFACE CONNECTION=$CONNECTION" >> /tmp/cmds_install_debug.log

  if [[ -z "$INTERFACE" || -z "$CONNECTION" ]]; then
    dialog --title "Interface Error" --msgbox "No active network interface found." 6 50
    exit 1
  fi

  step_ok "Interface: ${INTERFACE} (${CONNECTION})"
  export INTERFACE CONNECTION
  sleep 1
}

# =============================================================
# STEP 4 — STATIC IP (if DHCP detected)
# =============================================================
prompt_static_ip_if_dhcp() {
  section "IP Configuration"
  IP_METHOD=$(nmcli -g ipv4.method connection show "$CONNECTION" | tr -d '' | xargs)

  if [[ "$IP_METHOD" == "manual" ]]; then
    step_ok "Static IP already configured on ${INTERFACE}"
    return
  fi

  if [[ "$IP_METHOD" == "auto" ]]; then
    step_info "DHCP detected on ${INTERFACE} — static IP required"
    while true; do
      while true; do
        IPADDR=$(dialog --backtitle "Network Setup" --title "Static IP Required" \
          --inputbox "DHCP detected on '${INTERFACE}'\n\nEnter static IP in CIDR format (e.g., 192.168.1.100/24):" \
          9 75 3>&1 1>&2 2>&3)
        validate_cidr "$IPADDR" && break || dialog --msgbox "Invalid CIDR format. Try again." 6 40
      done
      while true; do
        GW=$(dialog --backtitle "Network Setup" --title "Gateway" \
          --inputbox "Enter default gateway:" 8 60 3>&1 1>&2 2>&3)
        validate_ip "$GW" && break || dialog --msgbox "Invalid IP. Try again." 6 40
      done
      while true; do
        DNSSERVER=$(dialog --backtitle "Network Setup" --title "DNS Server" \
          --inputbox "Enter upstream DNS server IP:" 8 60 3>&1 1>&2 2>&3)
        validate_ip "$DNSSERVER" && break || dialog --msgbox "Invalid IP. Try again." 6 40
      done
      while true; do
        HOSTNAME=$(dialog --backtitle "Network Setup" --title "FQDN" \
          --inputbox "Enter FQDN (e.g., cmds.domain.com):" 8 60 3>&1 1>&2 2>&3)
        if validate_fqdn "$HOSTNAME" && check_hostname_in_domain "$HOSTNAME"; then break
        else dialog --msgbox "Invalid FQDN. Try again." 6 50; fi
      done
      while true; do
        DNSSEARCH=$(dialog --backtitle "Network Setup" --title "DNS Search Domain" \
          --inputbox "Enter DNS search domain (e.g., domain.com):" 8 60 3>&1 1>&2 2>&3)
        [[ -n "$DNSSEARCH" ]] && break || dialog --msgbox "Search domain cannot be blank." 6 40
      done

      dialog --backtitle "Network Setup" --title "Confirm Settings" \
        --yesno "Apply these settings?\n\nInterface: ${INTERFACE}\nIP: ${IPADDR}\nGateway: ${GW}\nFQDN: ${HOSTNAME}\nDNS: ${DNSSERVER}\nSearch: ${DNSSEARCH}" \
        13 60

      if [[ $? -eq 0 ]]; then
        nmcli con mod "$CONNECTION" ipv4.address "$IPADDR"
        nmcli con mod "$CONNECTION" ipv4.gateway "$GW"
        nmcli con mod "$CONNECTION" ipv4.method manual
        nmcli con mod "$CONNECTION" ipv4.dns "$DNSSERVER"
        nmcli con mod "$CONNECTION" ipv4.dns-search "$DNSSEARCH"
        hostnamectl set-hostname "$HOSTNAME"

        # Write resume marker with the expected IP so it can be validated
        # after reboot before continuing the install.
        echo "ip=${IPADDR%%/*}" > /root/.cmds_install_resume

        # Hook /root/.bashrc so logging in as root after the reboot
        # automatically re-launches the installer to continue where it left off.
        if ! grep -q "# BEGIN CMDS-GO-AUTORESUME" /root/.bashrc 2>/dev/null; then
          cat >> /root/.bashrc << 'BASHRC_EOF'

# BEGIN CMDS-GO-AUTORESUME
# Added by CMDS-GO installer — removed automatically on first login after reboot.
if [[ -f /root/.cmds_install_resume ]]; then
    exec bash /root/CMDS_WEBInstaller/CMDS_WEBInstall.sh
fi
# END CMDS-GO-AUTORESUME
BASHRC_EOF
        fi

        dialog --title "Reboot Required" \
          --msgbox "Network configured. System will reboot.\n\nLog in as root at: ${IPADDR%%/*}\nThe installer will resume automatically." 9 62
        reboot
      fi
    done
  fi
}

# =============================================================
# STEP 5 — INTERNET CONNECTIVITY
# =============================================================
check_internet_connectivity() {
  section "Internet Connectivity"
  local dns_ok=0 ip_ok=0

  ping -c 1 -W 2 8.8.8.8 &>/dev/null && ip_ok=1
  ping -c 1 -W 2 google.com &>/dev/null && dns_ok=1

  [[ $ip_ok -eq 1 ]] && step_ok "Direct IP reachable (8.8.8.8)" || step_fail "Cannot reach 8.8.8.8"
  [[ $dns_ok -eq 1 ]] && step_ok "DNS resolution working" || step_fail "DNS resolution failed"

  if [[ $ip_ok -eq 0 || $dns_ok -eq 0 ]]; then
    dialog --title "Network Warning" \
      --yesno "Internet connectivity issues detected.\n\nContinue anyway?" 8 55
    [[ $? -ne 0 ]] && exit 1
  fi
  sleep 1
}

# =============================================================
# STEP 6 — HOSTNAME
# =============================================================
validate_and_set_hostname() {
  section "Hostname"
  local current; current=$(hostname)

  if [[ "$current" == "localhost.localdomain" ]]; then
    while true; do
      NEW_HOSTNAME=$(dialog --backtitle "Hostname Setup" --title "Set FQDN" \
        --inputbox "Current hostname is '${current}'.\nEnter FQDN (e.g., cmds.example.com):" \
        8 60 3>&1 1>&2 2>&3)
      if validate_fqdn "$NEW_HOSTNAME" && check_hostname_in_domain "$NEW_HOSTNAME"; then
        hostnamectl set-hostname "$NEW_HOSTNAME"
        step_ok "Hostname set to: ${NEW_HOSTNAME}"
        break
      else
        dialog --msgbox "Invalid FQDN. Try again." 6 50
      fi
    done
  else
    step_ok "Hostname: ${current}"
  fi
  sleep 1
}

# =============================================================
# STEP 7 — PRE-INSTALL CHECKLIST
# =============================================================
show_server_checklist() {
  dialog --backtitle "CMDS-GO Installer" \
    --title "Pre-Installation Checklist" \
    --msgbox "\
*********************************************
  CMDS-GO Server Installation
*********************************************

This installer will set up:
  • Base system packages + security (fail2ban, SELinux)
  • NTP time sync (optional)
  • DHCP server via Kea (optional)
  • TFTP + HTTP image server for IOS-XE firmware
  • FastAPI backend (cmds-go service)
  • Apache reverse proxy for the web UI
  • Cockpit web management console

Have ready (if enabling optional services):
  1. NTP server IPs or FQDNs (up to 3)
  2. NTP allow subnet in CIDR (e.g., 192.168.1.0/24)
  3. DHCP range start/end IPs
  4. DHCP default gateway IP
  5. DHCP domain suffix

*********************************************" 26 65
}

# =============================================================
# STEP 8 — EPEL + CRB REPOS
# =============================================================
enable_repos() {
  section "Repository Setup"
  local log="$LOGDIR/repo-setup.log"
  : > "$log"

  step_info "Enabling EPEL and CRB repositories..."
  {
    dnf -y install epel-release --setopt=install_weak_deps=False --color=never >>"$log" 2>&1
    dnf -y install dnf-plugins-core --setopt=install_weak_deps=False --color=never >>"$log" 2>&1 || true
    dnf config-manager --set-enabled crb --color=never >>"$log" 2>&1 || true
    dnf -y makecache --refresh --color=never >>"$log" 2>&1
  }

  if [[ $? -eq 0 ]]; then
    step_ok "EPEL + CRB enabled"
  else
    step_fail "Repo setup had errors — see ${log}"
  fi
  sleep 1
}

# =============================================================
# STEP 9 — FULL SYSTEM UPGRADE
# =============================================================
run_system_upgrade() {
  section "System Upgrade"
  local log="$LOGDIR/system-upgrade.log"
  : > "$log"

  step_info "Running dnf upgrade (this may take a while)..."

  local PIPE; PIPE=$(mktemp -u); mkfifo "$PIPE"
  mapfile -t PACKAGE_LIST < <(dnf -q repoquery --upgrades --qf '%{name}' 2>/dev/null | sort -u)
  local TOTAL=${#PACKAGE_LIST[@]}

  if [[ $TOTAL -eq 0 ]]; then
    step_ok "System already up to date"
    rm -f "$PIPE"; return
  fi

  dialog --backtitle "System Upgrade" --title "Upgrading Packages" \
    --gauge "Starting system upgrade..." 10 70 0 < "$PIPE" &

  local COUNT=0
  {
    for PKG in "${PACKAGE_LIST[@]}"; do
      ((COUNT++))
      local PCT=$(( COUNT * 100 / TOTAL ))
      echo "$PCT"; echo "XXX"; echo "Upgrading: $PKG"; echo "XXX"
      dnf -y -q upgrade --color=never --best --allowerasing "$PKG" >>"$log" 2>&1
    done
    echo "100"; echo "XXX"; echo "Upgrade complete."; echo "XXX"
  } > "$PIPE"
  wait; rm -f "$PIPE"

  step_ok "System packages upgraded (${TOTAL} packages)"
  sleep 1
}

# =============================================================
# STEP 10 — REQUIRED PACKAGE INSTALL
# =============================================================
update_and_install_packages() {
  section "Required Packages"
  local log="$LOGDIR/packages.log"
  : > "$log"

  local REQUIRED_PKGS=(
    ntsysv gcc tar nmap openssl-devel make at bc bzip2-devel
    libffi-devel zlib-devel nano rsync sshpass openldap-clients
    fail2ban tuned cockpit cockpit-storaged cockpit-files
    net-tools dmidecode ipcalc bind-utils iotop zip
    yum-utils curl wget dnf-automatic dnf-plugins-core
    util-linux htop expect iptraf-ng mc
    httpd
    python3 python3-pip pam-devel
    tftp-server acl
    policycoreutils-python-utils
    chrony
  )

  local TOTAL=${#REQUIRED_PKGS[@]} COUNT=0
  local PIPE; PIPE=$(mktemp -u); mkfifo "$PIPE"

  dialog --backtitle "Package Install" --title "Installing Required Packages" \
    --gauge "Preparing..." 10 70 0 < "$PIPE" &

  {
    for PKG in "${REQUIRED_PKGS[@]}"; do
      ((COUNT++))
      local PCT=$(( COUNT * 100 / TOTAL ))
      echo "$PCT"; echo "XXX"; echo "Installing: $PKG"; echo "XXX"
      dnf -y -q install --color=never --setopt=tsflags=nodocs "$PKG" >>"$log" 2>&1
    done
    echo "100"; echo "XXX"; echo "Packages installed."; echo "XXX"
  } > "$PIPE"
  wait; rm -f "$PIPE"

  step_ok "Required packages installed"
  sleep 1
}

# =============================================================
# STEP 11 — VM GUEST TOOLS
# =============================================================
vm_detection() {
  section "VM Guest Tools"

  local kvm_hw vmware_hw
  kvm_hw=$(dmidecode 2>/dev/null | grep -i -e manufacturer -e product -e vendor | grep KVM | cut -c16- || true)
  vmware_hw=$(dmidecode 2>/dev/null | grep -i "VMware, Inc." | head -1 || true)

  if [[ "$kvm_hw" == "KVM" ]]; then
    step_info "KVM detected — installing qemu-guest-agent..."
    dnf -y install qemu-guest-agent >/dev/null 2>&1
    systemctl enable --now qemu-guest-agent >/dev/null 2>&1 || true
    step_ok "qemu-guest-agent installed"
  elif [[ -n "$vmware_hw" ]]; then
    step_info "VMware detected — installing open-vm-tools..."
    dnf -y install open-vm-tools >/dev/null 2>&1
    systemctl enable --now vmtoolsd >/dev/null 2>&1 || true
    step_ok "open-vm-tools installed"
  else
    step_ok "No hypervisor guest tools needed (physical or unsupported platform)"
  fi
  sleep 1
}

# =============================================================
# STEP 12 — NTP / CHRONY (optional)
# =============================================================
declare -a NTP_ADDR
LOG_NTP="$LOGDIR/chrony.log"
touch "$LOG_NTP"

_ntp_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG_NTP"; }

_prompt_ntp_servers() {
  while true; do
    NTP_SERVERS=$(dialog --title "NTP Configuration" --backtitle "Configure NTP" \
      --inputbox "Enter up to 3 NTP server IPs or FQDNs (comma-separated):" \
      8 65 3>&1 1>&2 2>&3)
    [[ $? -ne 0 ]] && return 1
    if [[ -n "$NTP_SERVERS" ]]; then
      IFS=',' read -ra NTP_ADDR <<< "$NTP_SERVERS"
      (( ${#NTP_ADDR[@]} > 3 )) && { dialog --msgbox "Maximum 3 NTP servers." 6 40; continue; }
      return 0
    fi
    dialog --msgbox "NTP server field cannot be blank." 6 50
  done
}

_prompt_ntp_allow() {
  while true; do
    ALLOW_NET=$(dialog --title "NTP Allow Network" --backtitle "Configure NTP" \
      --inputbox "Enter CIDR range to allow NTP access (e.g., 192.168.1.0/24):" \
      8 75 3>&1 1>&2 2>&3)
    [[ $? -ne 0 ]] && return 1
    validate_cidr "$ALLOW_NET" && return 0
    dialog --msgbox "Invalid CIDR format. Try again." 6 40
  done
}

_update_chrony_config() {
  cp /etc/chrony.conf /etc/chrony.conf.bak 2>/dev/null || true
  sed -i '/^\(server\|pool\|allow\)[[:space:]]/d' /etc/chrony.conf
  for srv in "${NTP_ADDR[@]}"; do
    echo "server ${srv} iburst" >> /etc/chrony.conf
    _ntp_log "Added server ${srv}"
  done
  [[ -n "$ALLOW_NET" ]] && echo "allow $ALLOW_NET" >> /etc/chrony.conf
  systemctl restart chronyd; sleep 2
}

_validate_time_sync() {
  local attempt=1 success=0
  while (( attempt <= 3 )); do
    step_info "Validating time sync (attempt ${attempt}/3)..."
    sleep 5
    local tracking; tracking=$(chronyc tracking 2>&1)
    echo "$tracking" >> "$LOG_NTP"
    echo "$tracking" | grep -q "Leap status.*Normal" && { success=1; break; }
    ((attempt++))
  done
  if [[ $success -eq 1 ]]; then
    step_ok "Time synchronized"
  else
    step_fail "NTP sync failed after 3 attempts"
    dialog --title "NTP Warning" \
      --yesno "Time sync failed after 3 attempts.\nContinue anyway?" 8 55
    [[ $? -ne 0 ]] && return 1
  fi
  return 0
}

configure_ntp() {
  section "NTP / Chrony"
  dialog --backtitle "Configure NTP" --title "NTP Setup" \
    --yesno "Configure Chrony NTP server on this system?" 7 55
  [[ $? -ne 0 ]] && { step_info "NTP configuration skipped"; return 0; }

  _prompt_ntp_servers || { step_info "NTP configuration cancelled"; return 0; }
  _prompt_ntp_allow   || { step_info "NTP allow-network cancelled"; return 0; }
  _update_chrony_config
  _validate_time_sync
  sleep 1
}

# =============================================================
# STEP 13 — KEA DHCP SERVER (optional)
# =============================================================
configure_dhcp_kea() {
  section "DHCP Server (Kea)"

  dialog --backtitle "DHCP Server" --title "Kea DHCP" \
    --yesno "Install and configure Kea DHCP on this server?" 7 55
  [[ $? -ne 0 ]] && { step_info "DHCP installation skipped"; return 0; }

  local log="$LOGDIR/kea-install.log"
  : > "$log"

  step_info "Installing Kea DHCP..."
  # Rocky 10: upgrade openssl-libs first to avoid symbol errors
  dnf -y upgrade --best --allowerasing openssl-libs >>"$log" 2>&1 || true
  dnf -y install kea >>"$log" 2>&1
  if [[ $? -ne 0 ]]; then
    step_fail "Kea install failed — see ${log}"
    return 1
  fi
  step_ok "Kea DHCP installed"

  # --- Gather scope settings ---
  local iface inet4_line INET4 CIDR NETWORK NETMASK
  iface=$(nmcli -t -f DEVICE,STATE device status | awk -F: '$2=="connected"{print $1; exit}')
  inet4_line=$(nmcli -g IP4.ADDRESS device show "$iface" | head -n1)
  INET4=${inet4_line%/*}; CIDR=${inet4_line#*/}
  NETWORK=$(network_from_ip_cidr "$INET4" "$CIDR")
  NETMASK=$(cidr_to_netmask "$CIDR")

  local POOL_START POOL_END ROUTER DOM_SUFFIX SEARCH_DOMAIN DNS_SERVERS SUBNET_DESC
  local DEF_SUFFIX; DEF_SUFFIX="$(hostname -d 2>/dev/null || true)"

  while true; do
    while true; do
      POOL_START=$(dialog --backtitle "Kea DHCP" --stdout \
        --inputbox "DHCP range START IP (in ${NETWORK}/${CIDR}):" 8 70)
      is_valid_ip "$POOL_START" && ip_in_cidr "$POOL_START" "$NETWORK" "$CIDR" && break
      dialog --msgbox "Invalid or out-of-range IP." 6 40
    done
    while true; do
      POOL_END=$(dialog --backtitle "Kea DHCP" --stdout \
        --inputbox "DHCP range END IP (in ${NETWORK}/${CIDR}):" 8 70)
      is_valid_ip "$POOL_END" && ip_in_cidr "$POOL_END" "$NETWORK" "$CIDR" && \
        (( $(ip_to_int "$POOL_START") <= $(ip_to_int "$POOL_END") )) && break
      dialog --msgbox "Invalid, out-of-range, or less than start IP." 6 50
    done
    while true; do
      ROUTER=$(dialog --backtitle "Kea DHCP" --stdout \
        --inputbox "Default gateway for clients (in ${NETWORK}/${CIDR}):" 8 70)
      is_valid_ip "$ROUTER" && ip_in_cidr "$ROUTER" "$NETWORK" "$CIDR" && break
      dialog --msgbox "Invalid or out-of-range gateway." 6 40
    done
    while true; do
      DOM_SUFFIX=$(dialog --backtitle "Kea DHCP" --stdout \
        --inputbox "Domain suffix for clients:" 8 70 "${DEF_SUFFIX}")
      is_valid_domain "$DOM_SUFFIX" && break
      dialog --msgbox "Invalid domain suffix." 6 40
    done
    DNS_SERVERS=$(dialog --backtitle "Kea DHCP" --stdout \
      --inputbox "DNS servers (comma-separated, default: ${INET4}):" 8 70 "$INET4")
    [[ -z "$DNS_SERVERS" ]] && DNS_SERVERS="$INET4"
    SUBNET_DESC=$(dialog --backtitle "Kea DHCP" --stdout \
      --inputbox "Friendly description for this scope:" 8 70)

    dialog --backtitle "Kea DHCP" --title "Confirm Kea DHCP Settings" --yesno \
"Interface:  ${iface}
Server IP:  ${INET4}/${CIDR}
Subnet:     ${NETWORK}/${CIDR}
Range:      ${POOL_START}  →  ${POOL_END}
Gateway:    ${ROUTER}
DNS:        ${DNS_SERVERS}
Domain:     ${DOM_SUFFIX}
Desc:       ${SUBNET_DESC}

Apply these settings?" 18 65 && break
  done

  local KEA_CONF="/etc/kea/kea-dhcp4.conf"
  mkdir -p /etc/kea
  cat > "$KEA_CONF" <<EOF
{
  "Dhcp4": {
    "interfaces-config": {
      "interfaces": [ "${iface}" ]
    },
    "lease-database": {
      "type": "memfile",
      "persist": true,
      "name": "/var/lib/kea/kea-leases4.csv"
    },
    "subnet4": [
      {
        "id": 1,
        "subnet": "${NETWORK}/${CIDR}",
        "interface": "${iface}",
        "comment": "${SUBNET_DESC}",
        "pools": [ { "pool": "${POOL_START} - ${POOL_END}" } ],
        "option-data": [
          { "name": "routers",             "data": "${ROUTER}" },
          { "name": "domain-name-servers", "data": "${DNS_SERVERS}" },
          { "name": "ntp-servers",         "data": "${INET4}" },
          { "name": "domain-name",         "data": "${DOM_SUFFIX}" }
        ]
      }
    ],
    "authoritative": true
  }
}
EOF
  chown root:kea "$KEA_CONF"; chmod 640 "$KEA_CONF"
  restorecon "$KEA_CONF" 2>/dev/null || true

  systemctl enable --now kea-dhcp4 >/dev/null 2>&1
  firewall-cmd --zone=public --add-service=dhcp --permanent >/dev/null 2>&1
  firewall-cmd --reload >/dev/null 2>&1

  if systemctl is-active --quiet kea-dhcp4; then
    step_ok "Kea DHCP running"
  else
    step_fail "Kea DHCP failed to start — check ${KEA_CONF}"
  fi
  sleep 1
}

# =============================================================
# STEP 14 — FIREWALL
# =============================================================
configure_firewall() {
  section "Firewall"

  firewall-cmd --permanent --add-service=tftp    >/dev/null 2>&1
  firewall-cmd --permanent --add-service=ntp     >/dev/null 2>&1
  firewall-cmd --permanent --add-service=http    >/dev/null 2>&1
  firewall-cmd --permanent --add-service=https   >/dev/null 2>&1
  firewall-cmd --permanent --add-service=cockpit >/dev/null 2>&1
  firewall-cmd --reload >/dev/null 2>&1
  systemctl restart firewalld >/dev/null 2>&1

  local svcs; svcs=$(firewall-cmd --list-services 2>/dev/null)
  step_ok "Firewall rules applied: ${svcs}"
  sleep 1
}

# =============================================================
# STEP 15 — FAIL2BAN
# =============================================================
configure_fail2ban() {
  section "Fail2ban"
  local log="$LOGDIR/fail2ban.log"
  : > "$log"

  local orig="/etc/fail2ban/jail.conf"
  local local_f="/etc/fail2ban/jail.local"
  local sshd_f="/etc/fail2ban/jail.d/sshd.local"

  cp "$orig" "$local_f" >>"$log" 2>&1 || { step_fail "Cannot copy jail.conf"; return 1; }
  sed -i '/^\[sshd\]/,/^$/ s/#mode.*normal/&\nenabled = true/' "$local_f" >>"$log" 2>&1

  cat > "$sshd_f" <<'EOF'
[sshd]
enabled = true
maxretry = 5
findtime = 300
bantime = 3600
bantime.increment = true
bantime.factor = 2
EOF

  systemctl enable --now fail2ban >>"$log" 2>&1
  sleep 2

  if systemctl is-active --quiet fail2ban; then
    step_ok "Fail2ban running (SSH jail active)"
  else
    # Try SELinux recovery
    restorecon -v /etc/fail2ban/jail.local >>"$log" 2>&1 || true
    systemctl restart fail2ban >>"$log" 2>&1
    if systemctl is-active --quiet fail2ban; then
      step_ok "Fail2ban running (after SELinux fix)"
    else
      step_fail "Fail2ban failed to start — see ${log}"
    fi
  fi
  sleep 1
}

# =============================================================
# STEP 16 — /etc/issue LOGIN BANNER
# =============================================================
update_issue_file() {
  section "Login Banner"
  cat > /etc/issue <<'EOF'
\S
Kernel \r on an \m
Hostname: \n
IP Address: \4
EOF
  step_ok "/etc/issue updated (shows hostname + IP at login)"
  sleep 1
}

# =============================================================
# STEP 17 — BRACKETED PASTE
# =============================================================
disable_bracketed_paste() {
  section "Terminal Settings"
  if grep -q 'enable-bracketed-paste' /etc/inputrc 2>/dev/null; then
    step_ok "Bracketed paste already disabled"
  else
    sed -i '8i set enable-bracketed-paste off' /etc/inputrc
    step_ok "Bracketed paste disabled in /etc/inputrc"
  fi
  sleep 1
}

# =============================================================
# STEP 18 — TFTP SERVER
# =============================================================
tftp_setup_module() {
  section "TFTP Server"
  local log="$LOGDIR/tftp.log"
  local TFTP_ROOT="/var/lib/tftpboot"
  local SVC="/etc/systemd/system/tftp-server.service"
  local SOCK="/etc/systemd/system/tftp-server.socket"
  : > "$log"

  step_info "Configuring TFTP server..."

  cp -f /usr/lib/systemd/system/tftp.service "$SVC"  >>"$log" 2>&1
  cp -f /usr/lib/systemd/system/tftp.socket  "$SOCK" >>"$log" 2>&1

  grep -q '^Service=' "$SOCK" \
    && sed -i 's/^Service=.*/Service=tftp-server.service/' "$SOCK" \
    || echo 'Service=tftp-server.service' >> "$SOCK"

  sed -i '/^Requires=/c\Requires=tftp-server.socket' "$SVC" >>"$log" 2>&1 || true
  sed -i '/^ExecStart=/c\ExecStart=/usr/sbin/in.tftpd -c -p -s /var/lib/tftpboot' "$SVC" >>"$log" 2>&1

  mkdir -p "${TFTP_ROOT}/images" "${TFTP_ROOT}/hybrid" "${TFTP_ROOT}/wlc" \
           "${TFTP_ROOT}/mig"    "${TFTP_ROOT}/cat"
  chmod -R 777 "$TFTP_ROOT" >>"$log" 2>&1
  restorecon -RFv "$TFTP_ROOT" >>"$log" 2>&1 || true
  command -v setsebool >/dev/null 2>&1 && setsebool -P tftp_anon_write on >>"$log" 2>&1 || true

  systemctl daemon-reload >>"$log" 2>&1
  systemctl disable --now tftp.socket >>"$log" 2>&1 || true
  systemctl enable --now tftp-server.socket >>"$log" 2>&1

  if systemctl is-active --quiet tftp-server.socket; then
    step_ok "TFTP server active (root: ${TFTP_ROOT})"
  else
    step_fail "TFTP server failed to start — see ${log}"
  fi
  sleep 1
}

# =============================================================
# STEP 19 — HTTP IMAGE REPO
# =============================================================
http_repo_setup_module() {
  section "HTTP Image Repository"
  local log="$LOGDIR/http-repo.log"
  local TFTP_ROOT="/var/lib/tftpboot"
  local SITE_CONF="/etc/httpd/conf.d/tftp-images.conf"
  local SEND_FILE_CONF="/etc/httpd/conf.d/00-sendfile.conf"
  : > "$log"

  mkdir -p "${TFTP_ROOT}/images" "${TFTP_ROOT}/hybrid" "${TFTP_ROOT}/wlc" "${TFTP_ROOT}/mig" >>"$log" 2>&1

  cat > "$SITE_CONF" <<CONF
# Serve firmware images over HTTP
Alias /images ${TFTP_ROOT}/images
<Directory "${TFTP_ROOT}/images">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>

Alias /hybrid ${TFTP_ROOT}/hybrid
<Directory "${TFTP_ROOT}/hybrid">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>

Alias /wlc ${TFTP_ROOT}/wlc
<Directory "${TFTP_ROOT}/wlc">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>

Alias /mig ${TFTP_ROOT}/mig
<Directory "${TFTP_ROOT}/mig">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
CONF

  echo "EnableSendfile Off" > "$SEND_FILE_CONF"

  # SELinux for images dir
  if command -v semanage >/dev/null 2>&1; then
    semanage fcontext -a -t public_content_rw_t "${TFTP_ROOT}/images(/.*)?" >>"$log" 2>&1 \
      || semanage fcontext -m -t public_content_rw_t "${TFTP_ROOT}/images(/.*)?" >>"$log" 2>&1 || true
    restorecon -RFv "${TFTP_ROOT}/images" >>"$log" 2>&1 || true
  fi
  setsebool -P tftp_anon_write on >>"$log" 2>&1 || true

  step_ok "HTTP image aliases configured (${SITE_CONF})"
  sleep 1
}

# =============================================================
# STEP 20 — IOS-XE IMAGES SYMLINK
# =============================================================
create_iosxe_symlink_module() {
  section "IOS-XE Images Symlink"
  local LINK="/root/IOS-XE_images"
  local TARGET="/var/lib/tftpboot/images"

  mkdir -p "$TARGET"; chmod 755 "$TARGET"

  if [[ -L "$LINK" && "$(readlink -f "$LINK")" == "$(readlink -f "$TARGET")" ]]; then
    step_ok "Symlink already correct: ${LINK} → ${TARGET}"
  else
    rm -rf -- "$LINK" 2>/dev/null || true
    ln -sfn "$TARGET" "$LINK"
    step_ok "Symlink created: ${LINK} → ${TARGET}"
  fi
  sleep 1
}

# =============================================================
# STEP 21 — IMAGES AUTO-FIX DAEMON
# =============================================================
images_autofix_module() {
  section "Images Auto-Fix Daemon"
  local IMAGES_DIR="/var/lib/tftpboot/images"
  local FIX_SCRIPT="/usr/local/sbin/tftp-images-autofix.sh"
  local SVC="/etc/systemd/system/tftp-images-autofix.service"
  local PATHU="/etc/systemd/system/tftp-images-autofix.path"
  local TIMER="/etc/systemd/system/tftp-images-autofix.timer"
  local log="$LOGDIR/images-autofix.log"
  : > "$log"

  mkdir -p "$IMAGES_DIR" >>"$log" 2>&1

  cat > "$FIX_SCRIPT" <<'SH'
#!/usr/bin/env bash
IMAGES_DIR="/var/lib/tftpboot/images"
[[ -d "$IMAGES_DIR" ]] || exit 0
exec 9>/run/tftp-images-autofix.lock
flock -n 9 || exit 0
export LANG=C LC_ALL=C
STATE="/run/tftp-images-autofix.state"
now=$(date +%s); last=0
[[ -f "$STATE" ]] && last=$(<"$STATE" || echo 0)
(( last > 0 && now - last < 2 )) && exit 0
[[ -f "$STATE" ]] && ! find "$IMAGES_DIR" -type f -newer "$STATE" -print -quit | grep -q . && exit 0
command -v semanage >/dev/null 2>&1 && {
  semanage fcontext -m -t public_content_rw_t "$IMAGES_DIR(/.*)?" >/dev/null 2>&1 \
    || semanage fcontext -a -t public_content_rw_t "$IMAGES_DIR(/.*)?" >/dev/null 2>&1
}
restorecon -RF "$IMAGES_DIR" >/dev/null 2>&1 || true
chmod -R a+rX "$IMAGES_DIR" >/dev/null 2>&1 || true
echo "$now" > "$STATE"
logger -t tftp-images-autofix "Repaired labels/perms under $IMAGES_DIR" 2>/dev/null || true
exit 0
SH
  chmod 755 "$FIX_SCRIPT"

  cat > "$SVC" <<SERVICE
[Unit]
Description=Auto-fix SELinux labels/perms under ${IMAGES_DIR}
ConditionPathExists=${IMAGES_DIR}
StartLimitIntervalSec=0
[Service]
Type=oneshot
ExecStart=${FIX_SCRIPT}
Nice=10
SERVICE

  cat > "$PATHU" <<PATHUNIT
[Unit]
Description=Watch ${IMAGES_DIR} for changes
[Path]
Unit=tftp-images-autofix.service
MakeDirectory=true
PathModified=${IMAGES_DIR}
[Install]
WantedBy=paths.target
PATHUNIT

  cat > "$TIMER" <<TIMERUNIT
[Unit]
Description=Periodic auto-fix for ${IMAGES_DIR}
[Timer]
OnBootSec=15s
OnUnitActiveSec=30s
AccuracySec=1s
RandomizedDelaySec=0
Unit=tftp-images-autofix.service
[Install]
WantedBy=timers.target
TIMERUNIT

  systemctl daemon-reload >>"$log" 2>&1
  systemctl reset-failed tftp-images-autofix.service 2>/dev/null || true
  systemctl enable --now tftp-images-autofix.path  >>"$log" 2>&1
  systemctl enable --now tftp-images-autofix.timer >>"$log" 2>&1
  systemctl start tftp-images-autofix.service >>"$log" 2>&1 || true

  step_ok "Images auto-fix daemon active (path watcher + 30s timer)"
  sleep 1
}

# =============================================================
# STEP 22 — PYTHON + PIP PACKAGES
# =============================================================
install_python_packages() {
  section "Python / FastAPI"
  local log="$LOGDIR/python.log"
  : > "$log"

  step_info "Upgrading pip..."
  python3 -m pip install --upgrade pip setuptools wheel >>"$log" 2>&1

  local PACKAGES=(
    "fastapi"
    "uvicorn[standard]"
    "python-multipart"
    "python-pam"
  )

  local all_ok=1
  for pkg in "${PACKAGES[@]}"; do
    python3 -m pip install -U "$pkg" >>"$log" 2>&1
    if [[ $? -eq 0 ]]; then
      step_ok "pip install ${pkg}"
    else
      step_fail "pip install ${pkg} failed — see ${log}"
      all_ok=0
    fi
  done

  # meraki SDK (separate — don't conflict with system requests)
  python3 -m pip install -U meraki >>"$log" 2>&1
  [[ $? -eq 0 ]] && step_ok "pip install meraki" || step_fail "pip install meraki failed"

  [[ $all_ok -eq 1 ]] && step_ok "All Python packages installed" || step_fail "Some Python packages failed — see ${log}"
  sleep 1
}

# =============================================================
# STEP 23 — DEPLOY CMDS-GO APP (from GitHub Release tarball)
# =============================================================
deploy_cmds_web() {
  section "Deploy CMDS-GO Application"
  local log="$LOGDIR/deploy.log"
  : > "$log"

  local TARBALL_URL="https://github.com/fumatchu/CMDS_WEB/releases/latest/download/cmds-go.tar.gz"
  local TARBALL="/tmp/cmds-go.tar.gz"

  # Download tarball from GitHub Releases
  step_info "Downloading application package from GitHub..."
  wget -q -O "$TARBALL" "$TARBALL_URL" 2>>"$log"
  if [[ $? -ne 0 || ! -s "$TARBALL" ]]; then
    step_fail "Download failed: ${TARBALL_URL}"
    step_info "Make sure a GitHub Release exists with cmds-go.tar.gz attached."
    step_info "See: prepare-release.sh to build and upload the package."
    return 1
  fi
  local SIZE; SIZE=$(du -sh "$TARBALL" | cut -f1)
  step_ok "Downloaded cmds-go.tar.gz (${SIZE})"

  # Back up any existing install
  if [[ -d "$INSTALL_BASE" ]]; then
    local BACKUP="${INSTALL_BASE}.bak.$(date +%Y%m%d%H%M%S)"
    step_info "Backing up existing install to ${BACKUP}..."
    mv "$INSTALL_BASE" "$BACKUP" >>"$log" 2>&1 && step_ok "Backup created" || step_info "Backup skipped (non-fatal)"
  fi

  # Extract
  step_info "Extracting to /opt/..."
  tar -xzf "$TARBALL" -C /opt/ >>"$log" 2>&1
  if [[ $? -ne 0 ]]; then
    step_fail "Extraction failed — see ${log}"
    return 1
  fi
  step_ok "Extracted to ${INSTALL_BASE}"
  rm -f "$TARBALL"

  # Ensure runtime dirs exist (emptied before packaging)
  mkdir -p \
    "${INSTALL_BASE}/data"  \
    "${INSTALL_BASE}/logs"  \
    "${INSTALL_BASE}/runs"  \
    "${INSTALL_BASE}/state" \
    "${INSTALL_BASE}/tmp"
  step_ok "Runtime directories ready"

  # ── Permissions ──────────────────────────────────────────
  step_info "Setting file permissions..."

  # All directories: 755
  find "$INSTALL_BASE" -type d -exec chmod 755 {} \;

  # Python / config files: 644
  find "${INSTALL_BASE}/api" -type f \
    \( -name "*.py" -o -name "*.json" -o -name "*.yaml" -o -name "*.env.example" \) \
    -exec chmod 644 {} \;

  # Web-served content: 644
  find "${INSTALL_BASE}/ui"           -type f -exec chmod 644 {} \;
  find "${INSTALL_BASE}/docs"         -type f -exec chmod 644 {} \;
  find "${INSTALL_BASE}/uplink_types" -type f -exec chmod 644 {} \; 2>/dev/null || true

  # Strip ACL flags (CRITICAL — SFTP/Mountain Duck sets ACL+ which causes 403)
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -R -b "${INSTALL_BASE}/ui"   >>"$log" 2>&1 || true
    setfacl -R -b "${INSTALL_BASE}/docs" >>"$log" 2>&1 || true
    step_ok "ACL flags stripped from ui/ and docs/"
  fi

  # Shell scripts in scripts/ AND lib/: 700
  find "${INSTALL_BASE}/scripts" -type f -name "*.sh" -exec chmod 700 {} \;
  find "${INSTALL_BASE}/lib"     -type f -name "*.sh" -exec chmod 700 {} \;
  step_ok "Shell scripts (scripts/ and lib/) set to 700"

  # lib/ non-sh files: 644
  find "${INSTALL_BASE}/lib" -type f ! -name "*.sh" -exec chmod 644 {} \;

  # Runtime dirs: 755
  chmod 755 \
    "${INSTALL_BASE}/data"  \
    "${INSTALL_BASE}/logs"  \
    "${INSTALL_BASE}/runs"  \
    "${INSTALL_BASE}/state" \
    "${INSTALL_BASE}/tmp"

  step_ok "All permissions set"
  sleep 1
}

# =============================================================
# STEP 24 — SELINUX FOR CMDS-GO
# =============================================================
configure_selinux_cmds() {
  section "SELinux — CMDS-GO"
  local log="$LOGDIR/selinux-cmds.log"
  : > "$log"

  if ! command -v semanage >/dev/null 2>&1; then
    step_fail "semanage not found — install policycoreutils-python-utils"
    return 1
  fi

  # UI and docs served by Apache
  for dir in ui docs; do
    semanage fcontext -a -t httpd_sys_content_t \
      "${INSTALL_BASE}/${dir}(/.*)?" >>"$log" 2>&1 \
      || semanage fcontext -m -t httpd_sys_content_t \
        "${INSTALL_BASE}/${dir}(/.*)?" >>"$log" 2>&1 || true
    restorecon -Rv "${INSTALL_BASE}/${dir}" >>"$log" 2>&1 || true
    step_ok "SELinux: httpd_sys_content_t on ${dir}/"
  done

  # Allow Apache to proxy to uvicorn
  setsebool -P httpd_can_network_connect 1 >>"$log" 2>&1
  step_ok "SELinux: httpd_can_network_connect enabled"

  sleep 1
}

# =============================================================
# STEP 25 — APACHE VIRTUALHOST
# =============================================================
configure_apache_cmds() {
  section "Apache VirtualHost"
  local log="$LOGDIR/apache.log"
  local CONF="/etc/httpd/conf.d/cmds-go.conf"
  : > "$log"

  cat > "$CONF" <<'APACHECONF'
<VirtualHost *:80>
    DocumentRoot "/opt/cmds-go/ui"
    LimitRequestBody 2147483648

    # Disable mod_reqtimeout body limit — allows large IOS-XE uploads (1GB+)
    # over slow/routed paths without Apache killing the connection mid-transfer.
    # (Default body=20,MinRate=500 drops connections on I226-V NIC + inter-VLAN paths)
    RequestReadTimeout body=0

    <Directory "/opt/cmds-go/ui">
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    # =====================================================
    # CMDS DOCS
    # =====================================================
    Alias /cmds-docs /opt/cmds-go/docs
    <Directory "/opt/cmds-go/docs">
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    DirectoryIndex index.html

    # =====================================================
    # API REVERSE PROXY
    # =====================================================
    ProxyRequests Off
    ProxyPreserveHost On

    ProxyPass        /api/login http://127.0.0.1:8000/api/login
    ProxyPassReverse /api/login http://127.0.0.1:8000/api/login

    ProxyPass        /api/auth/check http://127.0.0.1:8000/api/auth/check
    ProxyPassReverse /api/auth/check http://127.0.0.1:8000/api/auth/check

    ProxyPass        /api/ http://127.0.0.1:8000/
    ProxyPassReverse /api/ http://127.0.0.1:8000/

    # =====================================================
    # LOGGING
    # =====================================================
    ErrorLog /var/log/httpd/cmds-go-error.log
    CustomLog /var/log/httpd/cmds-go-access.log combined
</VirtualHost>
APACHECONF

  step_ok "VirtualHost written: ${CONF}"

  # Syntax test
  local syntax_out
  syntax_out=$(apachectl configtest 2>&1)
  if echo "$syntax_out" | grep -q "Syntax OK"; then
    step_ok "Apache config syntax OK"
  else
    step_fail "Apache config syntax error:"
    echo "$syntax_out"
  fi

  # Enable and start httpd
  systemctl enable --now httpd >>"$log" 2>&1
  systemctl restart httpd >>"$log" 2>&1

  if systemctl is-active --quiet httpd; then
    step_ok "Apache (httpd) running"
  else
    step_fail "Apache failed to start — see ${log} and /var/log/httpd/error_log"
  fi
  sleep 1
}

# =============================================================
# STEP 26 — CMDS-GO SYSTEMD SERVICE
# =============================================================
install_cmds_service() {
  section "CMDS-GO Service"
  local SVC_FILE="/etc/systemd/system/cmds-go.service"
  local log="$LOGDIR/cmds-service.log"
  : > "$log"

  cat > "$SVC_FILE" <<'EOF'
[Unit]
Description=CMDS-go FastAPI Backend
After=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/cmds-go/api
ExecStart=/usr/local/bin/uvicorn main:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload >>"$log" 2>&1
  systemctl enable --now cmds-go >>"$log" 2>&1
  sleep 3

  if systemctl is-active --quiet cmds-go; then
    step_ok "cmds-go service running"
  else
    step_fail "cmds-go service failed to start"
    step_info "Check: journalctl -u cmds-go -n 50 --no-pager"
  fi
  sleep 1
}

# =============================================================
# STEP 27 — COCKPIT
# =============================================================
enable_cockpit() {
  section "Cockpit Web Console"
  local log="$LOGDIR/cockpit.log"
  : > "$log"

  systemctl enable --now cockpit.socket >>"$log" 2>&1

  if systemctl is-active --quiet cockpit.socket; then
    step_ok "Cockpit active (https://<server-ip>:9090)"
  else
    step_fail "Cockpit failed to start — see ${log}"
  fi
  sleep 1
}

# =============================================================
# STEP 28 — FINAL STATUS REPORT
# =============================================================
final_status_report() {
  section "Installation Summary"
  echo ""

  local services=("cmds-go" "httpd" "tftp-server.socket" "fail2ban" "chronyd" "firewalld")
  local optional=("kea-dhcp4" "cockpit.socket")

  echo -e "  ${CYAN}Core Services:${TEXTRESET}"
  for svc in "${services[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      step_ok "${svc}"
    else
      step_fail "${svc} (not running)"
    fi
  done

  echo ""
  echo -e "  ${CYAN}Optional Services:${TEXTRESET}"
  for svc in "${optional[@]}"; do
    if systemctl is-enabled "$svc" 2>/dev/null | grep -q enabled; then
      if systemctl is-active --quiet "$svc" 2>/dev/null; then
        step_ok "${svc}"
      else
        step_fail "${svc} (enabled but not running)"
      fi
    else
      step_info "${svc} (not installed)"
    fi
  done

  local server_ip
  server_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || hostname -I | awk '{print $1}')

  echo ""
  echo -e "  ${CYAN}Access Points:${TEXTRESET}"
  echo -e "  ${YELLOW}→${TEXTRESET}  Web UI:      http://${server_ip}/"
  echo -e "  ${YELLOW}→${TEXTRESET}  Cockpit:     https://${server_ip}:9090/"
  echo -e "  ${YELLOW}→${TEXTRESET}  Logs:        journalctl -u cmds-go -f"
  echo -e "  ${YELLOW}→${TEXTRESET}  Installer log: ${LOGDIR}/"
  echo ""
  echo -e "  ${GREEN}CMDS-GO installation complete.${TEXTRESET}"
  echo ""
}

# =============================================================
# MAIN INSTALLATION FLOW
# =============================================================
main() {
  # ── Resume detection (read state file early, act after interface is known) ──
  RESUME_AFTER_NETWORK=0
  RESUME_EXPECTED_IP=""
  if [[ -f /root/.cmds_install_resume ]]; then
    RESUME_AFTER_NETWORK=1
    RESUME_EXPECTED_IP=$(grep -oP '(?<=ip=)\S+' /root/.cmds_install_resume || true)
    rm -f /root/.cmds_install_resume
    # Remove the auto-resume hook from .bashrc
    sed -i '/# BEGIN CMDS-GO-AUTORESUME/,/# END CMDS-GO-AUTORESUME/d' /root/.bashrc
  fi
  # ─────────────────────────────────────────────────────────────────────────────

  check_root_and_os
  check_and_enable_selinux
  detect_active_interface   # sets $INTERFACE

  if [[ $RESUME_AFTER_NETWORK -eq 1 ]]; then
    section "Resuming Installation"
    step_info "Resuming after DHCP→static IP reboot"
    # Validate the static IP is actually in place before continuing
    CURRENT_IP=$(nmcli -g IP4.ADDRESS device show "$INTERFACE" 2>/dev/null | head -1 | cut -d/ -f1)
    if [[ -n "$RESUME_EXPECTED_IP" && "$CURRENT_IP" == "$RESUME_EXPECTED_IP" ]]; then
      step_ok "Static IP confirmed: ${CURRENT_IP} on ${INTERFACE}"
    elif [[ -z "$RESUME_EXPECTED_IP" ]]; then
      step_ok "Continuing install — network reboot complete"
    else
      step_fail "Expected ${RESUME_EXPECTED_IP} but ${INTERFACE} shows ${CURRENT_IP:-none}"
      dialog --title "Network Validation Failed" \
        --yesno "Static IP did not apply as expected.\n\nExpected: ${RESUME_EXPECTED_IP}\nFound:    ${CURRENT_IP:-none} on ${INTERFACE}\n\nContinue anyway?" 11 62
      [[ $? -ne 0 ]] && exit 1
    fi
  else
    prompt_static_ip_if_dhcp
  fi

  check_internet_connectivity
  validate_and_set_hostname
  show_server_checklist
  enable_repos
  run_system_upgrade
  update_and_install_packages
  vm_detection
  configure_ntp
  configure_dhcp_kea
  configure_firewall
  configure_fail2ban
  update_issue_file
  disable_bracketed_paste
  tftp_setup_module
  http_repo_setup_module
  create_iosxe_symlink_module
  images_autofix_module
  install_python_packages
  deploy_cmds_web
  configure_selinux_cmds
  configure_apache_cmds
  install_cmds_service
  enable_cockpit
  final_status_report

  # ── Cleanup installer artifacts ───────────────────────────
  # Remove installer files from /root so nothing re-runs on next login/reboot.
  step_info "Cleaning up installer files..."
  rm -rf "$SRC_BASE"                          # /root/CMDS_WEBInstaller/
  rm -f  /root/.cmds_install_resume           # state file (should already be gone)
  # Belt-and-suspenders: remove auto-resume hook from .bashrc if still present
  sed -i '/# BEGIN CMDS-GO-AUTORESUME/,/# END CMDS-GO-AUTORESUME/d' /root/.bashrc 2>/dev/null || true
  step_ok "Installer files removed"

  # ── Final reboot ─────────────────────────────────────────
  # Ensures the upgraded kernel (from dnf upgrade) and all service
  # changes take effect cleanly.
  local server_ip
  server_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | \
    awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || \
    hostname -I | awk '{print $1}')

  echo ""
  echo -e "${GREEN}══════════════════════════════════════════════════${TEXTRESET}"
  echo -e "${GREEN}  CMDS-GO installation complete.${TEXTRESET}"
  echo -e "${GREEN}══════════════════════════════════════════════════${TEXTRESET}"
  echo ""
  echo -e "  ${CYAN}Install log:${TEXTRESET}  ${LOGDIR}/"
  echo -e "  ${CYAN}Web UI:${TEXTRESET}       http://${server_ip}/"
  echo -e "  ${CYAN}Cockpit:${TEXTRESET}      https://${server_ip}:9090/"
  echo ""
  echo -e "  Scroll up to review install output."
  echo -e "  Log files are available after reboot at: ${LOGDIR}/"
  echo ""
  read -rp "  Press Enter to reboot... " _
  reboot
}

main

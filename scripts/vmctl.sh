#!/usr/bin/env bash
#
# vmctl - create / destroy the daisy-chain cluster on a libvirt/KVM host.
#
# This is the imperative "operations" counterpart to the declarative NixOS
# configuration: NixOS decides what is *inside* each VM (addresses, firewall,
# services); vmctl wires up the libvirt *networks* and *domains* that those VMs
# run on.  The network/VM layout below mirrors lib/topology.nix and must be kept
# in sync with it.
#
# Typical use on the server:
#   nix build .#image-gateway .#image-www .#image-cache .#image-db
#   # copy each result/nixos.qcow2 into $IMG_DIR as <host>.qcow2, then:
#   IMG_DIR=/var/lib/wso/images sudo -E vmctl up
#   vmctl status
#   sudo vmctl down
#
set -euo pipefail

# --- configuration ----------------------------------------------------------
PREFIX="${VMCTL_PREFIX:-wso}"          # name prefix for libvirt objects
IMG_DIR="${IMG_DIR:-./images}"         # where <host>.qcow2 base images live
DISK_DIR="${DISK_DIR:-/var/lib/libvirt/images}"  # per-VM writable overlays
MEM_MB="${MEM_MB:-1024}"
VCPUS="${VCPUS:-1}"

# Isolated layer-2 segments (no host routing, no DHCP - NixOS owns addressing).
ISOLATED_NETS=(edge app data)

# The uplink: a libvirt NAT network giving the gateway VM Internet access.
WAN_NET="wan"
WAN_HOST_IP="192.0.2.254"
WAN_NETMASK="255.255.255.0"

# VM -> ordered list of networks it attaches to (NIC order == eth0, eth1, ...).
declare -A VM_NETS=(
  [gateway]="wan edge"
  [www]="edge app"
  [cache]="app data"
  [db]="data"
)
VM_ORDER=(gateway www cache db)

# --- helpers ----------------------------------------------------------------
log()  { printf '\033[1;34m[vmctl]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[vmctl]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[vmctl]\033[0m %s\n' "$*" >&2; exit 1; }

netname() { printf '%s-%s' "$PREFIX" "$1"; }
vmname()  { printf '%s-%s' "$PREFIX" "$1"; }

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# --- network XML ------------------------------------------------------------
isolated_net_xml() {
  local net="$1" full
  full="$(netname "$net")"
  cat <<EOF
<network>
  <name>${full}</name>
  <bridge name='virbr-${net}' stp='on' delay='0'/>
</network>
EOF
}

wan_net_xml() {
  local full
  full="$(netname "$WAN_NET")"
  cat <<EOF
<network>
  <name>${full}</name>
  <forward mode='nat'/>
  <bridge name='virbr-${WAN_NET}' stp='on' delay='0'/>
  <ip address='${WAN_HOST_IP}' netmask='${WAN_NETMASK}'/>
</network>
EOF
}

# --- domain XML -------------------------------------------------------------
domain_xml() {
  local host="$1" disk="$2"
  local full ifaces=""
  full="$(vmname "$host")"
  for net in ${VM_NETS[$host]}; do
    ifaces+="    <interface type='network'>
      <source network='$(netname "$net")'/>
      <model type='virtio'/>
    </interface>
"
  done
  cat <<EOF
<domain type='kvm'>
  <name>${full}</name>
  <memory unit='MiB'>${MEM_MB}</memory>
  <vcpu>${VCPUS}</vcpu>
  <os>
    <type arch='x86_64' machine='pc'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features><acpi/><apic/></features>
  <cpu mode='host-passthrough'/>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${disk}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
${ifaces}    <serial type='pty'><target port='0'/></serial>
    <console type='pty'><target type='serial' port='0'/></console>
  </devices>
</domain>
EOF
}

# --- network lifecycle ------------------------------------------------------
net_exists() { virsh net-info "$1" >/dev/null 2>&1; }

net_up() {
  local net full xml
  for net in "$WAN_NET" "${ISOLATED_NETS[@]}"; do
    full="$(netname "$net")"
    if net_exists "$full"; then
      log "network ${full} already defined"
    else
      if [ "$net" = "$WAN_NET" ]; then xml="$(wan_net_xml)"; else xml="$(isolated_net_xml "$net")"; fi
      printf '%s' "$xml" | virsh net-define /dev/stdin
      log "defined network ${full}"
    fi
    virsh net-autostart "$full" >/dev/null
    virsh net-start "$full" >/dev/null 2>&1 || true
    log "started network ${full}"
  done
}

net_down() {
  local net full
  for net in "${ISOLATED_NETS[@]}" "$WAN_NET"; do
    full="$(netname "$net")"
    net_exists "$full" || continue
    virsh net-destroy "$full" >/dev/null 2>&1 || true
    virsh net-undefine "$full" >/dev/null 2>&1 || true
    log "removed network ${full}"
  done
}

# --- VM lifecycle -----------------------------------------------------------
vm_exists() { virsh dominfo "$1" >/dev/null 2>&1; }

vm_up() {
  local host full base disk
  mkdir -p "$DISK_DIR"
  for host in "${VM_ORDER[@]}"; do
    full="$(vmname "$host")"
    base="${IMG_DIR}/${host}.qcow2"
    disk="${DISK_DIR}/${full}.qcow2"
    [ -f "$base" ] || die "base image not found: ${base} (build it with 'nix build .#image-${host}')"

    if vm_exists "$full"; then
      log "domain ${full} already defined"
    else
      # Per-VM writable overlay backed by the read-only base image.
      qemu-img create -f qcow2 -F qcow2 -b "$(readlink -f "$base")" "$disk" >/dev/null
      domain_xml "$host" "$disk" | virsh define /dev/stdin
      log "defined domain ${full}"
    fi
    virsh start "$full" >/dev/null 2>&1 || true
    log "started domain ${full}"
  done
}

vm_down() {
  local host full disk
  for host in "${VM_ORDER[@]}"; do
    full="$(vmname "$host")"
    disk="${DISK_DIR}/${full}.qcow2"
    if vm_exists "$full"; then
      virsh destroy "$full" >/dev/null 2>&1 || true
      virsh undefine "$full" >/dev/null 2>&1 || true
      log "removed domain ${full}"
    fi
    [ -f "$disk" ] && rm -f "$disk" && log "removed disk ${disk}"
  done
}

# --- status -----------------------------------------------------------------
status() {
  local host net full
  printf '\nNetworks:\n'
  for net in "$WAN_NET" "${ISOLATED_NETS[@]}"; do
    full="$(netname "$net")"
    if net_exists "$full"; then
      printf '  %-14s %s\n' "$full" "$(virsh net-info "$full" | awk -F': *' '/Active/{print $2}')"
    else
      printf '  %-14s (absent)\n' "$full"
    fi
  done
  printf '\nDomains:\n'
  for host in "${VM_ORDER[@]}"; do
    full="$(vmname "$host")"
    if vm_exists "$full"; then
      printf '  %-14s %s\n' "$full" "$(virsh domstate "$full" 2>/dev/null)"
    else
      printf '  %-14s (absent)\n' "$full"
    fi
  done
  printf '\n'
}

usage() {
  cat <<EOF
vmctl - manage the daisy-chain VM cluster on libvirt/KVM

Usage: vmctl <command>

Commands:
  up          create+start networks, then VMs (full bring-up)
  down        stop+remove all VMs, then networks (full tear-down)
  net-up      create+start the libvirt networks only
  net-down    remove the libvirt networks only
  vm-up       create+start the VMs only (networks must exist)
  vm-down     stop+remove the VMs only
  status      show network and domain state
  console H   attach to a VM's serial console (H = gateway|www|cache|db)
  help        show this message

Environment:
  IMG_DIR     base qcow2 images, named <host>.qcow2  (default: ./images)
  DISK_DIR    per-VM writable overlays               (default: /var/lib/libvirt/images)
  VMCTL_PREFIX  libvirt object name prefix           (default: wso)
  MEM_MB, VCPUS  per-VM resources                    (default: 1024, 1)
EOF
}

main() {
  need virsh
  local cmd="${1:-help}"
  case "$cmd" in
    up)       need qemu-img; net_up; vm_up; status ;;
    down)     vm_down; net_down ;;
    net-up)   net_up ;;
    net-down) net_down ;;
    vm-up)    need qemu-img; vm_up ;;
    vm-down)  vm_down ;;
    status)   status ;;
    console)  [ $# -ge 2 ] || die "console needs a host name"; exec virsh console "$(vmname "$2")" ;;
    help|-h|--help) usage ;;
    *)        warn "unknown command: ${cmd}"; usage; exit 1 ;;
  esac
}

main "$@"

#!/bin/bash
# voereir07: host prerequisites for OVS-DPDK and SR-IOV, before kolla-ansible
# deploy. Run as root, then reboot.
#  - IOMMU (vfio-pci for DPDK, VF passthrough for SR-IOV)
#  - 36 x 1G hugepages: 2 for OVS-DPDK, 34 for VMs
#  - CPUs for OVS-DPDK PMDs (2,14) and pinned VMs (6-11,18-23) isolated from
#    the kernel scheduler
#  - 16 SR-IOV VFs on enp8s0f1, recreated at every boot
#  - enp8s0f0 marked optional, as DPDK takes it away from the kernel
#  - MAAS's deprecated gateway4 replaced by a default route
#  - crudini, needed by kolla's ovs-dpdkctl.sh
set -euo pipefail

NUM_VFS=16
SRIOV_PF=enp8s0f1
DPDK_PORT=enp8s0f0

grep -qw pdpe1gb /proc/cpuinfo || { echo "CPU lacks 1G hugepage support" >&2; exit 1; }

# kolla's ovs-dpdkctl.sh keeps its config with crudini, which nothing else
# installs. Without it the deploy hangs in "Install ovs-dpdkctl service and
# config".
apt-get install -y crudini

cat > /etc/default/grub.d/90-voereir07-nfv.cfg <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT intel_iommu=on iommu=pt default_hugepagesz=1G hugepagesz=1G hugepages=36 isolcpus=2,6-11,14,18-23 nohz_full=2,6-11,14,18-23 rcu_nocbs=2,6-11,14,18-23"
EOF
update-grub

cat > /etc/systemd/system/sriov-vfs.service <<EOF
[Unit]
Description=Create SR-IOV VFs on ${SRIOV_PF}
Requires=sys-subsystem-net-devices-${SRIOV_PF}.device
After=sys-subsystem-net-devices-${SRIOV_PF}.device
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'f=/sys/class/net/${SRIOV_PF}/device/sriov_numvfs; [ "\$(cat \$f)" -eq ${NUM_VFS} ] || echo ${NUM_VFS} > \$f'

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable sriov-vfs.service

# MAAS writes the deprecated gateway4; replace it with a default route. Stop
# cloud-init re-rendering the netplan file so the change stays.
MAAS_NETPLAN=/etc/netplan/50-cloud-init.yaml
if grep -qE '^\s*gateway4:' "$MAAS_NETPLAN"; then
    if grep -qE '^\s*routes:' "$MAAS_NETPLAN"; then
        echo "$MAAS_NETPLAN already has routes; replace gateway4 by hand" >&2
        exit 1
    fi
    cp -p "$MAAS_NETPLAN" /root/50-cloud-init.yaml.orig
    sed -i -E 's/^(\s*)gateway4:\s*(\S+)\s*$/\1routes:\n\1- to: default\n\1  via: \2/' "$MAAS_NETPLAN"
fi
echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

netplan set "ethernets.${DPDK_PORT}.optional=true"
netplan generate

echo "Done. Reboot, then check:"
echo "  cat /proc/cmdline; grep Huge /proc/meminfo; cat /sys/devices/system/cpu/isolated"
echo "  ip -d link show ${SRIOV_PF} | grep -c 'vf '"

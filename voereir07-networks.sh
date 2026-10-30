#!/bin/bash
# voereir07: networks after kolla-ansible deploy and post-deploy. Run on the
# node with the OpenStack client installed. Safe to re-run.
#  - public:  external, flat physnet2 (br_ex, eno2), 172.16.227.0/24.
#             Floating IPs 172.16.227.12-19 (reserved in MAAS); the router
#             gateway takes .12, leaving 7 floating IPs.
#  - private: tenant VXLAN network (normal vNICs), routed to public
#  - dpdk-net:  flat physnet1 (br_dpdk, enp8s0f0, OVS-DPDK), 20.0.0.0/24
#  - sriov-net: VLAN 1000 on sriovnet1 (enp8s0f1 VFs), 30.0.0.0/24, no DHCP:
#               Neutron's DHCP port can't bind on sriovnet1 (no OVS bridge),
#               so VMs get the address from the metadata (cloud-init).
set -euo pipefail

source /etc/kolla/admin-openrc.sh

exists() { openstack "$1" show "$2" >/dev/null 2>&1; }

# eno2 can't be a DPDK port, so it joins br_ex as a kernel port. The OVS
# database keeps it across restarts.
sudo docker exec ovsdpdk_db ovs-vsctl --may-exist add-port br_ex eno2

exists network public || openstack network create --external \
    --provider-network-type flat --provider-physical-network physnet2 public
exists subnet public-subnet || openstack subnet create --network public \
    --subnet-range 172.16.227.0/24 --gateway 172.16.227.1 --no-dhcp \
    --allocation-pool start=172.16.227.12,end=172.16.227.19 public-subnet

exists network private || openstack network create private
exists subnet private-subnet || openstack subnet create --network private \
    --subnet-range 192.168.100.0/24 --dns-nameserver 172.16.227.116 private-subnet

if ! exists router private-router; then
    openstack router create private-router
    openstack router set private-router --external-gateway public \
        --fixed-ip subnet=public-subnet,ip-address=172.16.227.12
    openstack router add subnet private-router private-subnet
fi

exists network dpdk-net || openstack network create --share \
    --provider-network-type flat --provider-physical-network physnet1 dpdk-net
exists subnet dpdk-subnet || openstack subnet create --network dpdk-net \
    --subnet-range 20.0.0.0/24 --gateway none \
    --allocation-pool start=20.0.0.200,end=20.0.0.250 dpdk-subnet

exists network sriov-net || openstack network create --share \
    --provider-network-type vlan --provider-physical-network sriovnet1 \
    --provider-segment 1000 sriov-net
exists subnet sriov-subnet || openstack subnet create --network sriov-net \
    --subnet-range 30.0.0.0/24 --gateway none --no-dhcp \
    --allocation-pool start=30.0.0.200,end=30.0.0.250 sriov-subnet
# Also for subnets created before DHCP was turned off here.
openstack subnet set --no-dhcp sriov-subnet

# Every VM needs 1G hugepages: normal vNICs are vhost-user on OVS-DPDK.
exists flavor m1.small.hp || openstack flavor create --vcpus 2 --ram 4096 \
    --disk 20 --property hw:mem_page_size=1GB m1.small.hp

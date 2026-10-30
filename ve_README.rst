======================================================
voereir07: OpenStack 2026.2 all-in-one (kolla-ansible)
======================================================

VoerEir deployment notes for the ``aio-hibiscus-voereir07`` branch: a single
node OpenStack 2026.2 cloud on voereir07, with normal (vhost-user) vNICs,
OVS-DPDK and SR-IOV. Keep this file up to date when a step changes.

.. contents::
   :local:
   :depth: 2

Design
======

Host
----

* Dell PowerEdge R420: 2 x Xeon E5-2430 (12 cores, 24 threads), 64 GB RAM,
  PERC H710 Mini, Intel X520 (2 x 10G), 2 x 1G Broadcom LOM.
* Ubuntu 24.04. MAAS fails to deploy 24.04 and later on this machine
  (`LP: #2171042 <https://bugs.launchpad.net/maas/+bug/2171042>`__), so it is
  deployed as 22.04 and upgraded with ``do-release-upgrade``.
* Container engine: podman.

Storage
-------

========== ========= ================================================
Disk       Size      Use
========== ========= ================================================
``sdb``    960 GB    ``/`` (virt02): OS, container images, Glance,
                     Nova ephemeral disks
``sda``    1.8 TB    LVM volume group ``cinder-volumes`` (virt01):
                     Cinder LVM backend
========== ========= ================================================

The PERC boot device must be virt02 (Ctrl+R, *Ctrl Mgmt*, *Select Boot
Device*), as GRUB is on ``sdb``.

Networks
--------

============ =============================== ==================================
Interface    Switch                          Use
============ =============================== ==================================
eno1         voereir_switch_2, VLAN 2725     172.16.227.107: APIs, Horizon,
                                             SSH, VXLAN tunnel endpoint
eno2         voereir_switch_2, VLAN 2725     ``br_ex`` (kernel port),
                                             ``physnet2``: external network,
                                             floating IPs
enp8s0f0     voereir_switch 1/29, VLAN 1     ``br_dpdk`` (DPDK port),
                                             ``physnet1``: OVS-DPDK networks,
                                             20.0.0.0/24
enp8s0f1     voereir_switch 1/9, VLAN 1000   16 SR-IOV VFs, ``sriovnet1``:
             (tagged)                        SR-IOV networks, 30.0.0.0/24
============ =============================== ==================================

OpenStack networks (created by ``voereir07-networks.sh``):

* ``primary``: tenant VXLAN network (normal vNICs), routed to ``public``.
* ``public``: flat on ``physnet2``, 172.16.227.0/24, gateway .1. Floating IPs
  172.16.227.12-19 (reserved in MAAS); the router gateway takes .12, leaving 7
  floating IPs.
* ``dpdk-net``: flat on ``physnet1``, 20.0.0.0/24, no gateway.
* ``sriov-net``: VLAN 1000 on ``sriovnet1``, 30.0.0.0/24, no gateway. Ports
  use ``--vnic-type direct``.

On a DPDK host every normal vNIC is a vhost-user port, so every VM needs a
flavor with ``hw:mem_page_size=1GB``.

CPUs and memory
---------------

NUMA node 0 has the even CPUs, node 1 the odd ones; CPU *n* and *n+12* are
hyper-thread siblings. The X520 is on node 0.

============= ==================================================
CPUs          Use
============= ==================================================
0,12 1,13     Host and control plane (OVS lcore on CPU 0)
2,14          OVS-DPDK PMD threads (``ovs_pmd_coremask: 0x4004``)
3-5,15-17     Nova shared CPUs (``cpu_shared_set``)
6-11,18-23    Nova dedicated CPUs (``cpu_dedicated_set``)
============= ==================================================

36 x 1G hugepages: 1 per NUMA node for OVS-DPDK, 34 for VMs. Nova reserves
26 GB of host memory and does not overcommit RAM.

Files
=====

``etc/kolla/globals.yml``
    Deployment settings. Symlinked to ``/etc/kolla/globals.yml``.

``etc/kolla/config/``
    Service config overrides. Symlinked to ``/etc/kolla/config``:
    ``neutron/ml2_conf.ini`` (physnets and VLAN ranges),
    ``neutron/openvswitch_agent.ini`` (OVS firewall driver for vhost-user),
    ``nova.conf`` (NUMA and PCI scheduler filters) and
    ``nova/nova-compute.conf`` (hugepages, memory and CPU sets).

``ansible/roles/ovs-dpdk/``
    Patched to pass ``ovs_coremask``, ``ovs_pmd_coremask`` and
    ``ovs_dpdk_interface_driver`` to ``ovs-dpdkctl.sh``.

``CloudConfig-voereir07-kolla-aio.yaml``
    MAAS cloud-init user data.

``voereir07-host-prep.sh``
    Host setup before deploying: IOMMU, hugepages, CPU isolation, SR-IOV VFs,
    netplan fixes.

``voereir07-networks.sh``
    Networks, router and flavor after deploying.

``etc/kolla/passwords.yml`` stays an empty template in the repository. The
real one lives only in ``/etc/kolla``, next to the service configs kolla
generates there.

Host provisioning
=================

MAAS
----

Ubuntu 24.04 cannot be deployed directly: on this MAAS, curtin fails with
``E: Unable to locate package zfsutils-linux`` and ``python3-pyudev``
(`LP: #2171042 <https://bugs.launchpad.net/maas/+bug/2171042>`__); 26.04 fails
the same way. 22.04 deploys fine, so the host is deployed as 22.04 and upgraded
in place to 24.04, the host OS kolla-ansible 2026.2 supports.

#. Storage: set ``sdb`` as boot disk with a flat layout, and create the volume
   group ``cinder-volumes`` on ``sda``:

   .. code-block:: console

      maas $PROFILE block-device set-boot-disk $SID <sdb_id>
      maas $PROFILE machine set-storage-layout $SID storage_layout=flat root_device=<sdb_id>
      maas $PROFILE volume-groups create $SID name=cinder-volumes block_devices=<sda_id>

#. Network: eno1 static 172.16.227.107; eno2 *Unconfigured*; enp8s0f0 static
   20.0.0.107; enp8s0f1 with ``enp8s0f1.1000`` static 30.0.0.107.

#. Reserve the floating IPs 172.16.227.12-19 in MAAS. 172.16.227.0/24
   (VLAN 2725) is the lab's shared management network, where MAAS runs DHCP
   and assigns static addresses (servers use .1NN). Neutron hands out floating
   IPs from the range itself, so MAAS must never give them out: use a
   *Reserved* range, not a *Dynamic* one. Check that nothing uses the
   addresses first.

   .. code-block:: console

      maas $PROFILE ipranges create type=reserved start_ip=172.16.227.12 end_ip=172.16.227.19 comment="voereir07 OpenStack floating IPs"
      maas $PROFILE ipranges read | jq -r '.[] | "\(.type) \(.start_ip)-\(.end_ip) \(.comment)"'

   The router gateway takes .12, leaving 7 floating IPs. If the range changes,
   change ``voereir07-networks.sh`` to match.

#. PERC boot device: Ctrl+R during POST, *Ctrl Mgmt* tab, *Select Boot
   Device* = VD1 (virt02). (Not the F2 menu of *VD Mgmt*, which has *Clear
   Config*.)

   In legacy BIOS mode the BIOS only sees the PERC's boot virtual disk, VD0
   (virt01, ``sda``) by default, while GRUB is on ``sdb`` (VD1) and ``sda``
   holds LVM with no boot record. Without the change the machine hangs after
   installation at ``Booting local disk ... WARN: No MBR magic``.

   Not needed if either check passes:

   * The server boots in UEFI mode (UEFI uses the installer's boot entry):

     .. code-block:: console

        racadm -r voereir07-idrac.voereir.io -u root get BIOS.BiosBootSettings.BootMode    # BootMode=Uefi

   * The controller's boot virtual disk already is the one MAAS puts ``/``
     on (*Select Boot Device* on *Ctrl Mgmt* shows it), e.g. with root on
     ``sda``/VD0. Match virtual disks to MAAS block devices by size:

     .. code-block:: console

        racadm -r voereir07-idrac.voereir.io -u root storage get vdisks -o
        maas $PROFILE block-devices read $SID | jq -r '.[] | "\(.id) \(.name) \(.size) \(.used_for)"'

#. Deploy 22.04 (not 24.04, see above) with the cloud-init user data, then
   lock the machine:

   .. code-block:: console

      maas $PROFILE machine deploy $SID osystem=ubuntu distro_series=jammy user_data="$(base64 -w0 CloudConfig-voereir07-kolla-aio.yaml)"
      maas $PROFILE machine lock $SID comment="kolla-ansible AIO 2026.2"

#. On the node, upgrade to 24.04:

   .. code-block:: console

      sudo apt update && sudo apt full-upgrade -y && sudo reboot
      sudo do-release-upgrade

Host preparation
----------------

Check that SR-IOV and VT-d are enabled in the BIOS:

.. code-block:: console

   racadm -r voereir07-idrac.voereir.io -u root get BIOS.IntegratedDevices.SriovGlobalEnable
   racadm -r voereir07-idrac.voereir.io -u root get BIOS.ProcSettings.ProcVirtualization

Run the host preparation script, apply netplan and reboot:

.. code-block:: console

   sudo bash voereir07-host-prep.sh
   sudo netplan apply
   sudo reboot

After the reboot:

.. code-block:: console

   cat /proc/cmdline
   grep HugePages_Total /proc/meminfo                   # 36
   cat /sys/devices/system/cpu/isolated                 # 2,6-11,14,18-23
   ip -d link show enp8s0f1 | grep -c 'vf '             # 16
   ip -br addr                                          # eno1 .107, eno2 up without IPv4

Deployment
==========

Run steps 1 to 10 on voereir07 as the user ``voereir``, inside ``tmux``. Any
user with ``sudo`` access to ``root`` works; replace ``voereir`` in the
commands.

The user needs SSH access, ``sudo`` and write access to ``/opt/voereir_admin``
(group ``voereir_admins``). With ``CloudConfig-voereir07-kolla-aio.yaml``,
``voereir`` has none of these (``DenyUsers``, no ``sudo``, not in
``voereir_admins``): grant them first, or use a personal admin account.

0. Copy the repository to the node
----------------------------------

From a checkout on your workstation (replace ``<path-to-kolla-ansible>``).
``.git`` is copied too, as kolla-ansible reads its version from git:

.. code-block:: console

   rsync -a --delete --exclude /venv/ <path-to-kolla-ansible>/ voereir@172.16.227.107:/opt/voereir_admin/kolla-ansible/

Or clone the branch on the node:

.. code-block:: console

   git clone -b aio-hibiscus-voereir07 git@github.com:VoerEirAB/kolla-ansible.git /opt/voereir_admin/kolla-ansible

``/opt/voereir_admin`` is the shared admin directory (admin accounts have
``~/voereir_admin`` pointing to it). ``--exclude /venv/`` keeps the
kolla-ansible venv on the node, which only exists there.

1. Install kolla-ansible
------------------------

.. code-block:: console

   sudo apt install libdbus-glib-1-dev pkg-config
   python3 -m venv /opt/voereir_admin/kolla-ansible/venv && source /opt/voereir_admin/kolla-ansible/venv/bin/activate && pip install -U pip && pip install -e /opt/voereir_admin/kolla-ansible
   kolla-ansible install-deps
   export INV=/opt/voereir_admin/kolla-ansible/ansible/inventory/all-in-one ANSIBLE_BECOME_ASK_PASS=True ANSIBLE_TRANSFORM_INVALID_GROUP_CHARS=ignore ANSIBLE_CALLBACKS_ENABLED=ansible.posix.profile_tasks,ansible.posix.timer

kolla-ansible has no option to ask for the sudo password;
``ANSIBLE_BECOME_ASK_PASS`` makes Ansible prompt for it, possibly more than
once per command. ``ANSIBLE_TRANSFORM_INVALID_GROUP_CHARS=ignore`` keeps the
``-`` in kolla's group names (as kolla needs) without warning about them.

``ANSIBLE_CALLBACKS_ENABLED`` adds a timestamp and the elapsed time to every
task (``profile_tasks``), the slowest tasks at the end of each playbook and
the total run time (``timer``). Both come from the ``ansible.posix``
collection that ``install-deps`` installs; kolla's CI uses them too.

Every run also warns ``Could not match supplied host pattern, ignoring:
all_using_limit_True``. That group only has hosts when ``--limit`` is used;
the warning is harmless.

This venv runs kolla-ansible. kolla's modules on the host run in a second one,
``/opt/kolla-runtime-venv`` (``virtualenv`` in ``globals.yml``), which
``bootstrap-servers`` creates with ``dbus-python`` and the podman SDK. The
``libdbus-glib-1-dev`` and ``pkg-config`` packages are needed to build
``dbus-python``. Without the runtime venv, prechecks fail with ``No module
named 'dbus'``.

2. Destroy an earlier deployment
--------------------------------

Only if containers exist. Run it before step 3, with the configuration and
container engine the earlier deployment used:

.. code-block:: console

   sudo podman ps -q 2>/dev/null | wc -l; sudo docker ps -q 2>/dev/null | wc -l
   kolla-ansible destroy -i $INV --yes-i-really-really-mean-it

3. Set up ``/etc/kolla``
------------------------

``/etc/kolla`` must be a real directory: kolla writes the generated service
configs, with credentials, to ``/etc/kolla/<service>/``. Only ``globals.yml``
and ``config/`` are symlinks into the repository.

.. code-block:: console

   sudo mkdir -p /etc/kolla && sudo chown $USER:$USER /etc/kolla && rm -rf /etc/kolla/globals.yml /etc/kolla/config
   ln -s /opt/voereir_admin/kolla-ansible/etc/kolla/globals.yml /etc/kolla/globals.yml && ln -s /opt/voereir_admin/kolla-ansible/etc/kolla/config /etc/kolla/config
   cp --update=none /opt/voereir_admin/kolla-ansible/etc/kolla/passwords.yml /etc/kolla/passwords.yml && kolla-genpwd

``cp --update=none`` keeps an existing ``passwords.yml``.

Check:

.. code-block:: console

   ls -l /etc/kolla
   grep -E '^[a-z]' /etc/kolla/globals.yml
   find -L /etc/kolla/config -type f

4. Bootstrap the server
-----------------------

Installs podman, creates the ``kolla`` user, adds the host to ``/etc/hosts``
and disables host firewalls:

.. code-block:: console

   kolla-ansible bootstrap-servers -i $INV
   getent ahostsv4 voereir07                            # 172.16.227.107

5. Prechecks
------------

.. code-block:: console

   kolla-ansible prechecks -i $INV --use-test-images

The images come from ``quay.io/openstack.kolla``, which upstream publishes
for testing: they are rebuilt often and the ``2026.2-ubuntu-noble`` tags move.
Prechecks refuse them unless ``--use-test-images`` is given; ``deploy`` has
no such check. For a cloud that must stay reproducible, build the images with
``kolla-build`` and push them to a local registry (``docker_registry`` and
``docker_namespace`` in ``globals.yml``).

6. Deploy
---------

Takes 30 to 60 minutes. enp8s0f0 moves to DPDK, so 20.0.0.107 disappears from
the host. If it fails, fix the cause and run it again.

.. code-block:: console

   kolla-ansible deploy -i $INV

``ovs-dpdkctl.sh`` (task *Install ovs-dpdkctl service and config*) needs
``crudini`` on the host; ``voereir07-host-prep.sh`` installs it. Without it the
task hangs: the script writes an empty ``/etc/kolla/ovsdpdk-db/ovs-dpdkctl.conf``
and then waits in ``grep -ws /etc/modules`` with an empty driver name. To
recover, stop the deploy, then:

.. code-block:: console

   sudo pkill -f 'ovs-dpdkctl.sh install'
   sudo apt install crudini
   sudo rm /etc/kolla/ovsdpdk-db/ovs-dpdkctl.conf
   kolla-ansible deploy -i $INV

The handler *Wait for dpdk tunnel ip* always pauses for 5 minutes: it gives
``wait_for`` a host but no port, so Ansible just sleeps for the timeout.

The script only generates ``ovs-dpdkctl.conf`` when it doesn't exist. After
changing ``ovs_*`` settings in ``globals.yml`` (CPU masks, socket memory,
driver, port mappings), delete it before ``deploy`` or ``reconfigure``.

7. Post-deploy and OpenStack client
-----------------------------------

.. code-block:: console

   kolla-ansible post-deploy -i $INV
   pip install python-openstackclient -c https://releases.openstack.org/constraints/upper/2026.2
   source /etc/kolla/admin-openrc.sh

8. Check the deployment
-----------------------

.. code-block:: console

   sudo podman ps --format '{{.Names}}\t{{.Status}}' | grep -v healthy
   openstack network agent list
   openstack compute service list
   sudo podman exec ovsdpdk_db ovs-vsctl show
   sudo podman exec ovsdpdk_vswitchd ovs-appctl dpif-netdev/pmd-rxq-show

Expected:

* No unhealthy containers.
* Open vSwitch, NIC Switch (SR-IOV), L3, DHCP and metadata agents alive.
* ``br_dpdk`` with ``enp8s0f0`` as ``type: dpdk``; ``br_ex`` present.
* PMD threads on CPUs 2 and 14.

9. Create the networks
----------------------

.. code-block:: console

   bash /opt/voereir_admin/kolla-ansible/voereir07-networks.sh
   openstack network list
   openstack router show primary-router -c external_gateway_info

The script also adds eno2 to ``br_ex`` and creates the ``m1.small.hp``
flavor. It can be run again safely.

10. Test VM
-----------

A VM with a normal, an OVS-DPDK and an SR-IOV vNIC, and a floating IP:

.. code-block:: console

   curl -LO https://github.com/cirros-dev/cirros/releases/download/0.6.3/cirros-0.6.3-x86_64-disk.img
   openstack image create --disk-format qcow2 --container-format bare --public --file cirros-0.6.3-x86_64-disk.img cirros
   openstack security group rule create --proto icmp default
   openstack security group rule create --proto tcp --dst-port 22 default
   openstack port create --network sriov-net --vnic-type direct vm1-sriov
   openstack server create --flavor m1.small.hp --image cirros --nic net-id=primary --nic net-id=dpdk-net --nic port-id=vm1-sriov --wait vm1
   FIP=$(openstack floating ip create public -f value -c floating_ip_address) && openstack server add floating ip vm1 $FIP && echo $FIP
   ping -c3 $FIP && ssh cirros@$FIP

The CirrOS login is ``cirros`` / ``gocubsgo``. Pinned VMs need a flavor with
``hw:cpu_policy=dedicated`` as well.

Changing the configuration
==========================

Edit ``globals.yml`` or ``etc/kolla/config/`` in the repository, copy it to
the node (step 0), then:

.. code-block:: console

   kolla-ansible reconfigure -i $INV

``rsync --delete`` does not touch ``/etc/kolla/passwords.yml`` or the
generated service configs, as they are outside the repository.

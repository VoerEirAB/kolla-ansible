ZED roles folder location: /usr/local/share/kolla-ansible/ansible/roles 

Steps to deploy ZED openstack Cluster:
1. If swift is enbale : Create rings using official docs

sudo kolla-ansible -i inventory destroy --configdir etc/kolla/ --yes-i-really-really-mean-it
sudo kolla-ansible -i inventory  bootstrap-servers --configdir etc/kolla/
sudo kolla-ansible -i inventory prechecks --configdir etc/kolla/
sudo kolla-ansible -i inventory deploy --configdir etc/kolla/
sudo kolla-ansible -i inventory post-deploy --configdir /home/voereir/harshit_dev/kolla-ansible/etc/kolla/

source etc/kolla/admin-rc.sh
source init-runonce

Nova compute memory settings:
etc/kolla/config/nova/nova-compute.conf sets cpu_allocation_ratio = 8.0,
ram_allocation_ratio = 1.0 and reserved_host_memory_mb = 8192 on every
compute. Do not raise the RAM ratio above 1.0: with 2.0 Nova booked twice a
host's RAM and the computes hung out of memory. The file is read from
node_custom_config in globals.yml, so it must be in that directory on the
deploy host. Apply it with:

sudo kolla-ansible -i inventory reconfigure --configdir etc/kolla/ --tags nova

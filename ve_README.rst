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

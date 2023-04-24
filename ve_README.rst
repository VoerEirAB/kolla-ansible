
# Commands
#Update by Harshit : 01/06/2022
Move latest voereir certificates in /etc/kolla/certificates and append privkey.pem in fullchain.pem.
create rings for swift before start deployment: Follow link ( https://docs.openstack.org/kolla-ansible/xena/reference/storage/swift-guide.html )
run this playbook to add directory in /srv/node/ :- ansible-playbook -vv -i ./inventory ~/add_swift_storage_dev.yml
ansible-playbook -vv -i inventory fetch_ceph.yml
kolla-ansible -vv -i ./inventory destroy --yes-i-really-really-mean-it
kolla-ansible -vv -i ./inventory bootstrap-servers
kolla-ansible -vv -i ./inventory prechecks
kolla-ansible -vv -i ./inventory deploy
kolla-ansible -vv -i ./inventory post-deploy

# After sourcing the openRC
source tools/init-runonce

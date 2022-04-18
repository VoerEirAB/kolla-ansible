
# Commands

ansible-playbook -vv -i inventory fetch_ceph.yml
kolla-ansible -vv -i ./inventory destroy --yes-i-really-really-mean-it
kolla-ansible -vv -i ./inventory bootstrap-servers
kolla-ansible -vv -i ./inventory prechecks
kolla-ansible -vv -i ./inventory deploy

# After sourcing the openRC

tools/init-runonce

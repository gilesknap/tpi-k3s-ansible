# Initial setup of your infrastructure as code environment

## Set up a master keypair

We will first create a master keypair that will be used to access all of the nodes in the cluster including the BMC.

Here we call it ansible, if you choose a different name then update the variable public_key in the hosts file.
```bash
# PERFORM THIS ON YOUR HOST MACHINE outside of the dev container
ssh-keygen -t rsa -b 4096 -C "ansible master key" -f $HOME/.ssh/ansible_rsa
# copy the public key to the pub_keys folder in this repo
cp $HOME/.ssh/ansible_rsa.pub pub/ansible_rsa.pub
```

You should create a strong passphrase for this keypair.

## Authorize your keypair for each Turing Pi

Do the following for each of your turing pi boards. The name should be turingpi or turingpi.local for the first board and turingpi-2, turingpi-3 etc for the others.

```bash
# copy over the ansible public key to the turing pi (using password authentication)
scp pub_keys/ansible_rsa.pub root@turingpi:.ssh/authorized_keys
# connect - you will be asked for your passphrase from above
ssh root@turingpi
# change the password to something secure
passwd
# or even better disable password login in /etc/ssh/sshd_config
# (but then don't loose your ssh key!)
sed -E -i 's|^#?(PasswordAuthentication)\s.*|\1 no|' /etc/ssh/sshd_config
# return to your host
exit
```


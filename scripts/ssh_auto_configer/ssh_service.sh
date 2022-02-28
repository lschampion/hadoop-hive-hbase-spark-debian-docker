#!/bin/bash
apk add --no-cache openssh-server openssh-client openrc
rc-update add sshd
sed -i "s/#PermitRootLogin.*/PermitRootLogin yes/g" /etc/ssh/sshd_config
sed -i "s/#Port 22/Port 22/g" /etc/ssh/sshd_config
/etc/init.d/sshd start

# ssh-keygen -A
# autogen id_rsa file
ssh-keygen -t rsa -N '' <<EOF
/root/.ssh/id_rsa
yes


EOF

rc-status
touch /run/openrc/softlevel
/etc/init.d/sshd restart
# ssh-copy-id -i /root/.ssh/id_rsa.pub master
# ssh-copy-id -i /root/.ssh/id_rsa.pub worker1
# ssh-copy-id -i /root/.ssh/id_rsa.pub worker2

passwd=$1
echo "passwd is $passwd"
shift
apk add tcl tk expect

# auto ssh function
auto_ssh(){
username=$1
password=$2
hostname=$3
/usr/bin/expect <<EOF
set timeout 10
spawn ssh-copy-id -i /root/.ssh/id_rsa.pub $username@$hostname
expect {
            #first connect, no public key in ~/.ssh/known_hosts
            "*yes/no*" {
            send "yes\r"
            expect "*password*"
                send "$password\r"
            }
            #already has public key in ~/.ssh/known_hosts
            "*password*" {
                send "$password\r"
            }
            "Now try logging into the machine" {
                #it has authorized, do nothing!
            }
        }
expect eof

EOF
}

# test example
# auto_ssh root 123456 master

for hostname in $@;do
  echo "enter sending id_rsa loop,now hostname is $hostname"
  auto_ssh root $passwd $hostname    
done


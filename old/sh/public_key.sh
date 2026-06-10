#!/bin/bash
if [ ! -e '/usr/bin/wget' ]; then
yum -y install wget
fi
wget -O /tmp/id_rsa.pub http://file.asuhu.com/so/id_rsa.pub
   if [ ! -e '/tmp/id_rsa.pub' ];then
wget -O /tmp/id_rsa.pub http://arv.asuhu.com/ftp/so/id_rsa.pub
    fi
if [ ! -d "/root/.ssh" ]; then
  mkdir -p /root/.ssh
fi
cat '/tmp/id_rsa.pub' >>/root/.ssh/authorized_keys
chmod -R 400 /root/.ssh

chcon -R --reference=/etc/ssh/sshd_config /root/.ssh/authorized_keys  
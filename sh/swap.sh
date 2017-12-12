#!/bin/bash
install_swap(){
memtotal=`free -m | grep Mem | awk '{print $2}'`
swaptotal=`free -m | grep Swap | awk '{print $2}'`
if [ $memtotal -lt 1000 ];
then swapcreat=$memtotal
elif [[ $memtotal -gt 1000 && $memtotal -lt 8000 ]];
then swapcreat=`expr $memtotal / 2`
elif [ $memtotal -gt 8000 ];
then swapcreat=`expr $memtotal / 8`
fi

if [  $swaptotal -eq 0  ] ;then
sudo dd if=/dev/zero of=/swapfile bs=$swapcreat count=1024k
sudo mkswap /swapfile
sudo swapon /swapfile
sudo chmod 600 /swapfile

sudo sh -c 'echo "/swapfile none swap sw 0 0" >> /etc/fstab'

cat >>  /etc/sysctl.conf << EOF
vm.swappiness=10
EOF
fi

free -m
}
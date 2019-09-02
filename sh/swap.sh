#!/bin/bash
install_swap(){
memtotal=`free -m | grep Mem | awk '{print $2}'`
swaptotal=`free -m | grep Swap | awk '{print $2}'`
#if [ $memtotal -lt 1024 ];
#then swapcreat=$memtotal
#elif [[ $memtotal -gt 1025 && $memtotal -lt 8192 ]];
#then swapcreat=`expr $memtotal / 4`
#elif [[ $memtotal -gt 8193 && $memtotal -lt 16384 ]];
#then swapcreat=`expr $memtotal / 8`
#elif [ $memtotal -gt 16385 ];
#then swapcreat=`expr $memtotal / 16`
#fi

if [ $memtotal -lt 1024 ];
then swapcreat=512
elif [[ $memtotal -gt 1025 && $memtotal -lt 8192 ]];
then swapcreat=1024
elif [[ $memtotal -gt 8193 && $memtotal -lt 16384 ]];
then swapcreat=2048
elif [ $memtotal -gt 16385 ];
then swapcreat=8192
fi


if [  $swaptotal -eq 0  ] ;then
read -p "Do you want to enable Swap? [y/n]: " new_swap
  if [ $new_swap  == 'y' ]; then
sudo dd if=/dev/zero of=/swapfile bs=$swapcreat count=1024k
sudo mkswap /swapfile
sudo swapon /swapfile
sudo chmod 600 /swapfile

sudo sh -c 'echo "/swapfile none swap sw 0 0" >> /etc/fstab'

cat >>  /etc/sysctl.conf << EOF
vm.swappiness=10
EOF
else
echo "Choose not to install Swap"
  fi
fi

free -m
}
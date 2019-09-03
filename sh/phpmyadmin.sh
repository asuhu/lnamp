#!/bin/bash
if [ -d /home/wwwroot/web ];then
webdir=/home/wwwroot/web
elif [ -d /home/wwwroot/default ];then
webdir=/home/wwwroot/default
fi
#
pmaversion=`curl -s https://www.phpmyadmin.net/files/ | awk -F\> '/\/files\//{print $3}'|grep -v '^$'|grep -v alpha1|cut -d'<' -f1 | sort -V | tail -1`
if [ -z ${pmaversion} ];then
pmaversion=4.9.0.1
else
echo "phpmyadmin version check ok"
fi
#
a=$(cat /proc/cpuinfo | grep 'model name'| wc -l)
sqlpass=$(date +%s%N | sha256sum | base64 | head -c 12)
Mem=$( free -m | awk '/Mem/ {print $2}' )
if [ ! -e '/usr/bin/wget' ]; then
yum -y install wget
fi
cd $webdir
#echo "nameserver 8.8.8.8" > /etc/resolv.conf
#echo "nameserver 8.8.4.4" >> /etc/resolv.conf
wget -4 --no-check-certificate  https://files.phpmyadmin.net/phpMyAdmin/$pmaversion/phpMyAdmin-$pmaversion-all-languages.tar.gz
tar -zxvf phpMyAdmin-$pmaversion-all-languages.tar.gz
rm -rf phpMyAdmin-$pmaversion-all-languages.tar.gz
mv phpMyAdmin-$pmaversion-all-languages phpMyAdmin 
cd phpMyAdmin
cp config.sample.inc.php config.inc.php;
mkdir $webdir/phpMyAdmin/{upload,save}
sed -i "s@UploadDir.*@UploadDir'\] = 'upload';@" $webdir/phpMyAdmin/config.inc.php
sed -i "s@SaveDir.*@SaveDir'\] = 'save';@" $webdir/phpMyAdmin/config.inc.php
sed -i "s@blowfish_secret.*;@blowfish_secret\'\] = \'`cat /dev/urandom | head -1 | md5sum | head -c 55`\';@" config.inc.php
# 配置文件中的密文(blowfish_secret)太短。
cd $webdir
id -u www >/dev/null 2>&1
if [ $? -eq 0 ];then
chown -R www.www $webdir/phpMyAdmin
elif [ $? -ne 0 ];then
chown -R apache.apache $webdir/phpMyAdmin
fi
##
chmod o-rw ${webdir}/phpMyAdmin/config.inc.php
chmod -R 0 ${webdir}/phpMyAdmin/setup 
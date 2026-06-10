#!/bin/bash
#log-error=/data/mysql/log/mysqld.log
#datadir=/data/mysql/data
#20221103

cores=$(cat /proc/cpuinfo | grep 'model name'| wc -l)
cname=$( cat /proc/cpuinfo | grep 'model name' | uniq | awk -F : '{print $2}')
tram=$( free -m | awk '/Mem/ {print $2}' )
swap=$( free -m | awk '/Swap/ {print $2}' )
a=$(cat /proc/cpuinfo | grep 'model name'| wc -l)
Mem=$( free -m | awk '/Mem/ {print $2}' )
#version=$(cat /etc/redhat-release |grep -Po [0-9] | head -n 1)

echo "Total amount of Mem  : $tram MB"
echo "Total amount of Swap : $swap MB"
echo "CPU model            : $cname"
echo "Number of cores      : $cores"
sleep 1

#如果没有/etc/redhat-release，则退出
if [ ! -e '/etc/redhat-release' ]; then
echo "Only Support CentOS6 CentOS7 RHEL6 RHEL7"
kill -9 $$
fi

#检测版本6还是7
if  [ -n "$(grep ' 7\.' /etc/redhat-release)" ] ;then
CentOS_RHEL_version=7
elif
[ -n "$(grep ' 6\.' /etc/redhat-release)" ]; then
CentOS_RHEL_version=6
fi

next() {
    printf "%-70s\n" "-" | sed 's/\s/-/g'
}
next
sleep 1

yum -y install epel-release
if [ ! -e '/usr/bin/wget' ]; then yum -y install wget ;fi

systemctl status firewalld
if [ $?=0 ];then
	firewall-cmd --zone=public --add-port=3306/tcp --permanent
	firewall-cmd --zone=public --add-port=3360/tcp --permanent
	systemctl restart firewalld
	firewall-cmd --list-all
fi
#################################################Yum begin
#1、卸载mariadb
rpm -e mariadb-libs-5.5.65-1.el7.x86_64 --nodeps
rpm -e mariadb-libs.x86_64 1:5.5.68-1.el7 --nodeps 

#2、安装组件
yum install libaio perl net-tools -y

#3、下载解压
cd ~
mkdir mysql
if ping -c 4 10.53.220.1;then
wget -O mysql-5.7.39-1.el7.x86_64.rpm-bundle.tar http://10.53.123.144/Mysql/mysql-5.7.39-1.el7.x86_64.rpm-bundle.tar
else
wget -4 -O mysql-5.7.39-1.el7.x86_64.rpm-bundle.tar https://cdn.mysql.com//Downloads/MySQL-5.7/mysql-5.7.39-1.el7.x86_64.rpm-bundle.tar
fi
tar -xf mysql-5.7.39-1.el7.x86_64.rpm-bundle.tar -C mysql
cd ~/mysql
yum -y install ./*

#4、创建目录
mkdir -p /data/mysql && mkdir -p /data/mysql/data && mkdir -p /data/mysql/log && chown -R mysql.mysql /data/mysql && ls -ld /data/mysql

#5、编辑修改/etc/my.cnf
cat > /etc/my.cnf << EOF
[mysqld]
server-id = 1
port=3360
bind_address=0.0.0.0
init-connect = 'SET NAMES utf8mb4'
character-set-server = utf8mb4
#
datadir=/data/mysql/data
socket=/data/mysql/mysql.sock
log-error=/data/mysql/log/mysqld.log
pid-file=/data/mysql/mysqld.pid
#
log_bin = mysql-bin
binlog_format = mixed
binlog_cache_size = 1M
expire_logs_days = 180
#basedir = /data/mysql YUM安装不需要配置
#
# Disabling symbolic-links is recommended to prevent assorted security risks
symbolic-links=0
#
open_files_limit = 65535
key_buffer_size = 256M
query_cache_size = 64M
thread_cache_size = 64
#
lower_case_table_names = 1
default_storage_engine=InnoDB
innodb_buffer_pool_size = 1024M
#
performance_schema = 0
explicit_defaults_for_timestamp
skip-external-locking
skip-name-resolve
#
[client]
port = 3360
socket=/data/mysql/mysql.sock
EOF

#6、数据库初始化，初始化完成后，会生成一个root账号密码，位于/var/log/mysqld.log文件最后一行
mysqld --initialize --user=mysql

#7、查看密码tail /data/mysql/log/mysqld.log
PASS=`tail -n 1 /data/mysql/log/mysqld.log | awk '{print $NF}'`

#8 启动
systemctl start mysqld

#8、修改默认密码
#Please use --connect-expired-password option or invoke mysql in interactive mode.
/usr/bin/mysql -uroot -p${PASS} -S /data/mysql/mysql.sock --connect-expired-password -e "alter user 'root'@'localhost' identified by 'Admin@tyuVGZvpe2022..'"
/usr/bin/mysql -uroot -p'Admin@tyuVGZvpe2022..' -S /data/mysql/mysql.sock -e "select user,host from mysql.user;"
next
echo -e "Mysql initial password  \033[41;36m ${PASS} \033[0m" 
next
echo -e "Mysql finally password  \033[41;36m Admin@tyuVGZvpe2022.. \033[0m" 
next
echo -e "Mysql Server Port  \033[41;36m  3360 \033[0m" 
#################################################Yum end
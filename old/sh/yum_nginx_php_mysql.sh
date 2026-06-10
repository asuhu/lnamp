#!/bin/bash
#/usr/share/nginx/html     rpm -ql nginx
#log-error=/var/log/mysqld-error.log
#basedir = /var/lib/mysql
# 配置文件默认位置/etc/nginx/nginx.conf  /etc/php.ini /etc/php-fpm.conf /etc/my.cnf
#https://dev.mysql.com/doc/mysql-yum-repo-quick-guide/en/
#20170423

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
exit
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

cat >> /etc/rc.local << EOF
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 223.5.5.5" >> /etc/resolv.conf
EOF

yum -y install epel-release


if [ ! -e '/usr/bin/wget' ]; then
    yum -y install wget
fi

if [ $CentOS_RHEL_version -eq 7 ];then
systemctl stop firewalld.service
systemctl mask firewalld.service 
yum install iptables-services iptables-devel -y
/bin/systemctl enable iptables.service 
/bin/systemctl start iptables.service
fi
iptables -I INPUT -p tcp  -m multiport --dports 80,443,8080,3306 -j ACCEPT;service iptables save;service iptables restart

yum -y remove httpd httpd*
if [ $CentOS_RHEL_version -eq 6 ];then
cat > /etc/yum.repos.d/nginx.repo << EOF
[nginx]
name=nginx repo
baseurl=http://nginx.org/packages/centos/6/x86_64/$basearch/
gpgcheck=0
enabled=1
EOF
else
cat > /etc/yum.repos.d/nginx.repo << EOF
[nginx]
name=nginx repo
baseurl=http://nginx.org/packages/centos/7/x86_64/$basearch/
gpgcheck=0
enabled=1
EOF
fi


#https://webtatic.com/packages/php56/

if [ $CentOS_RHEL_version -eq 6 ];then
    rpm -ivh https://dev.mysql.com/get/mysql57-community-release-el6-9.noarch.rpm
    rpm -Uvh https://mirror.webtatic.com/yum/el6/latest.rpm
else
    rpm -ivh http://repo.mysql.com//mysql57-community-release-el7-9.noarch.rpm
    rpm -Uvh https://mirror.webtatic.com/yum/el7/webtatic-release.rpm
fi

yum clean all;yum makecache
yum install nginx -y
yum install php56w-fpm php56w-opcache php56w-cli php56w-common	php56w-gd php56w-imap php56w-ldap php56w-mcrypt php56w-mysql php56w-pear php56w-snmp php56w-soap php56w-tidy php56w-xml php56w-xmlrpc -y
yum install -y mysql-community-client mysql-community-server

cat > /etc/php-fpm.conf << EOF
;;;;;;;;;;;;;;;;;;;;;
; FPM Configuration ;
;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;
; Global Options ;
;;;;;;;;;;;;;;;;;;

[global]
pid = /var/run/php-fpm/php-fpm.pid
error_log = /var/log/php-fpm/error.log
log_level = warning 

emergency_restart_threshold = 30
emergency_restart_interval = 60s 
process_control_timeout = 5s
daemonize = yes

;;;;;;;;;;;;;;;;;;;;
; Pool Definitions ;
;;;;;;;;;;;;;;;;;;;;

[www]
listen = 127.0.0.1:9000
listen.backlog = -1
listen.allowed_clients = 127.0.0.1
listen.owner = nginx 
listen.group = nginx
listen.mode = 0666
user = nginx 
group = nginx

pm = dynamic
pm.max_children = 12
pm.start_servers = 8
pm.min_spare_servers = 6
pm.max_spare_servers = 12
pm.max_requests = 2048
pm.process_idle_timeout = 10s
request_terminate_timeout = 120
request_slowlog_timeout = 0

pm.status_path = /php-fpm_status
slowlog = log/slow.log
rlimit_files = 51200
rlimit_core = 0

catch_workers_output = yes
;env[HOSTNAME] = youdomain.com
env[PATH] = /usr/local/bin:/usr/bin:/bin
env[TMP] = /tmp
env[TMPDIR] = /tmp
env[TEMP] = /tmp
EOF

if [ $Mem -gt 1000 -a $Mem -le 2500 ];then
sed -i "s@^memory_limit.*@memory_limit = 64M@" /etc/php.ini
elif [ $Mem -gt 2500 -a $Mem -le 3500 ];then
sed -i "s@^memory_limit.*@memory_limit = 128M@" /etc/php.ini
elif [ $Mem -gt 3500 ];then
sed -i "s@^memory_limit.*@memory_limit = 256M@" /etc/php.ini
fi

sed -i 's@^output_buffering =@output_buffering = On\noutput_buffering =@' /etc/php.ini
sed -i 's@^;cgi.fix_pathinfo.*@cgi.fix_pathinfo=0@' /etc/php.ini
sed -i 's@^short_open_tag = Off@short_open_tag = On@' /etc/php.ini 
sed -i 's@^expose_php = On@expose_php = Off@' /etc/php.ini
sed -i 's@^request_order.*@request_order = "CGP"@' /etc/php.ini
sed -i 's@^;date.timezone.*@date.timezone = Asia/Shanghai@' /etc/php.ini
sed -i 's@^post_max_size.*@post_max_size = 100M@' /etc/php.ini
sed -i 's@^upload_max_filesize.*@upload_max_filesize = 50M@' /etc/php.ini
sed -i 's@^max_execution_time.*@max_execution_time = 5@' /etc/php.ini
sed -i 's@^disable_functions.*@disable_functions = passthru,exec,system,chroot,chgrp,chown,shell_exec,proc_open,proc_get_status,ini_alter,ini_restore,dl,openlog,syslog,readlink,symlink,popepassthru,stream_socket_server,fsocket,popen@' /etc/php.ini

wget -O /etc/nginx/nginx.conf http://file.asuhu.com/Others/yum/nginx.conf
wget -O /etc/nginx/conf.d/default.conf http://file.asuhu.com/Others/yum/default.conf

sleep 1

#探针
wget -O /usr/share/nginx/html/proble.tar.gz http://file.asuhu.com/Others/sh/proble.tar.gz
cd /usr/share/nginx/html/
tar -zxvf proble.tar.gz
service php-fpm restart
rm -rf proble.tar.gz

#chkconfig mysqld on  mysql会自启动
chkconfig php-fpm on
chkconfig nginx on
service mysqld restart


#if [ $CentOS_RHEL_version -eq 6 ];then
#centos6 需要这样 mysql_secure_installation
#centos7 需要这样 mysqld --initialize  2017-04-23T09:20:53.504401Z 0 [ERROR] --initialize specified but the data directory has files in it. Aborting.
#fi

#centos6 use mysql;  ERROR 1820 (HY000): You must reset your password using ALTER USER statement before executing this statement.
#centos7 use mysql;  ERROR 1820 (HY000): You must reset your password using ALTER USER statement before executing this statement.
#mysql> set password=password("MMMmmm111@#");
#mysql> flush privileges;


#禁用不常用的repo
yum -y install yum-utils
sudo yum-config-manager --disable nginx >/dev/null
sudo yum-config-manager --disable webtatic >/dev/null
sudo yum-config-manager --disable mysql57-community >/dev/null
sudo yum-config-manager --disable mysql-connectors-community >/dev/null
sudo yum-config-manager --disable mysql-tools-community >/dev/null

mysqlpassword=$(grep 'temporary password' /var/log/mysqld.log | awk '{print $11}')
echo -e "mysql password  \033[41;36m $mysqlpassword \033[0m" 
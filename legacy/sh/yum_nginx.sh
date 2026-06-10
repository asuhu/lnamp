#!/bin/bash
#/usr/share/nginx/html     rpm -ql nginx
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


yum -y install epel-release
if [ ! -e '/usr/bin/wget' ]; then yum -y install wget ;fi

systemctl status firewalld
if [ $?=0 ];then
	firewall-cmd --zone=public --add-port=80/tcp --permanent
	firewall-cmd --zone=public --add-port=443/tcp --permanent
	firewall-cmd --zone=public --add-port=8080/tcp --permanent
	systemctl restart firewalld
	firewall-cmd --list-all
fi

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

yum -y install nginx && systemctl start nginx&& systemctl status nginx
#禁用不常用的repo
yum -y install yum-utils
sudo yum-config-manager --disable nginx >/dev/null
next
echo -e "Nginx config document \033[41;36m /etc/nginx \033[0m" 
echo -e "Nginx html document \033[41;36m  /usr/share/nginx/html \033[0m" 
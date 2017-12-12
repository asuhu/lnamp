#!/bin/bash
#如果没有/etc/redhat-release，则退出
if [ ! -e '/etc/redhat-release' ]; then
echo "Only Support CentOS6 CentOS7 RHEL6 RHEL7"
exit
fi

#Check if user is root
[ $(id -u) != "0" ] && { echo "Error: You must be root to run this script"; exit 1; }

#增加swap
source ~/sh/swap.sh
lscpu  >/dev/null 2>&1
[ $? -eq 0 ] && install_swap

cores=$(cat /proc/cpuinfo | grep 'model name'| wc -l)
cname=$( cat /proc/cpuinfo | grep 'model name' | uniq | awk -F : '{print $2}')
tram=$( free -m | awk '/Mem/ {print $2}' )
swap=$( free -m | awk '/Swap/ {print $2}' )

yum remove httpd* php* mysql-server mysql* php-mysql -y
yum -y groupremove "FTP Server" "PostgreSQL Database client" "PostgreSQL Database server" "MySQL Database server" "MySQL Database client" "Web Server" "Office Suite and Productivity" "E-mail server" "Ruby Support" "Printing client"

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

#版本定义
nginx_openssl=Nginx1.12.2
apache=Apache2.2.34_prefork_No_HTTP2
apache_openssl=Apache2.4.29_event_HTTP2
php5apache=PHP5.6.32_Only_Support_Apache
php5=PHP5.6.32_Not_Support_Apache
php7=PHP7.0.25_Not_Support_Apache
mysql6=Mysql5.6.38
mysql7=Mysql5.7.20

    if [ -f /etc/redhat-release -a -n "$(grep ' 6\.' /etc/redhat-release)" ]; then

#netstat -nxltp | grep sshd | head -1 | awk '{print $4}' | cut -d: -f2
echo -e "\033[41;36m  Your system version is 6  \033[0m";
 [ -z "`grep ^Port /etc/ssh/sshd_config`" ] && ssh_port=22 || ssh_port=`grep ^Port /etc/ssh/sshd_config | awk '{print $2}'`
read -p "Please input new SSH port(Default: $ssh_port): " new_ssh_port
 [ -z "$new_ssh_port" ] && new_ssh_port=22
   if [ $new_ssh_port -lt 1024 >/dev/null 2>&1 -o $new_ssh_port eq 22]; then
      echo "The port greater than 1024"
exit
   fi
echo -e "SSH port will change to $new_ssh_port"

chmod +x ./sh/*.sh

#SSH优化
sed -i 's@^#UseDNS yes@UseDNS no@' /etc/ssh/sshd_config
sed -i 's@^GSSAPIAuthentication yes@GSSAPIAuthentication no@' /etc/ssh/sshd_config
iptables -I INPUT -p tcp -m tcp --dport "$new_ssh_port" -j ACCEPT
service iptables save;service iptables restart;
  if [ -z "`grep ^Port /etc/ssh/sshd_config`" -a "$new_ssh_port" != '22' ]; then
    sed -i "s@^#Port.*@&\nPort $new_ssh_port@" /etc/ssh/sshd_config
  elif [ -n "`grep ^Port /etc/ssh/sshd_config`" ]; then
    sed -i "s@^Port.*@Port $new_ssh_port@" /etc/ssh/sshd_config
  fi
#service sshd restart  配合后面的source 重启生效


rm -rf /etc/localtime
ln -s /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
yum -y groupremove "FTP Server" "PostgreSQL Database client" "PostgreSQL Database server" "MySQL Database server" "MySQL Database client" "Web Server" "Office Suite and Productivity" "Ruby Support"
yum clean all
yum -y install gcc gcc-c++ make vim screen python wget git lsof


      elif [ -f /etc/redhat-release -a -n "$(grep ' 7\.' /etc/redhat-release)" ]; then
chmod +x ./sh/*.sh
echo -e "\033[41;36m  Your System Version is 7  \033[0m";

#判断CentOS7的防火墙状态
if ! systemctl status firewald;then
 [ -z "`grep ^Port /etc/ssh/sshd_config`" ] && ssh_port=22 || ssh_port=`grep ^Port /etc/ssh/sshd_config | awk '{print $2}'`
read -p "Please input new SSH port(Default: $ssh_port): " new_ssh_port
 [ -z "$new_ssh_port" ] && new_ssh_port=22
   if [ $new_ssh_port -lt 1024 >/dev/null 2>&1 -o $new_ssh_port eq 22]; then
      echo "The port greater than 1024"
exit
   fi
  if [ -z "`grep ^Port /etc/ssh/sshd_config`" -a "$new_ssh_port" != '22' ]; then
    sed -i "s@^#Port.*@&\nPort $new_ssh_port@" /etc/ssh/sshd_config
  elif [ -n "`grep ^Port /etc/ssh/sshd_config`" ]; then
    sed -i "s@^Port.*@Port $new_ssh_port@" /etc/ssh/sshd_config
  fi
fi


#SSH优化
sed -i 's@^#UseDNS yes@UseDNS no@' /etc/ssh/sshd_config
sed -i 's@^GSSAPIAuthentication yes@GSSAPIAuthentication no@' /etc/ssh/sshd_config
timedatectl set-timezone Asia/Shanghai

#systemctl restart sshd 重启生效

yum -y remove mariadb-libs-5.5.41-2.el7_0.x86_64
yum install -y perl-Module-Install.noarch lsof
#FATAL ERROR: please install the following Perl modules before executing /usr/local/mysql/scripts/mysql_install_db:
    fi


#清屏
clear

#关闭安全上下文
setenforce 0
sed -i 's/^SELINUX=.*$/SELINUX=disabled/' /etc/selinux/config

next
echo "Total amount of Mem  : $tram MB"
echo "Total amount of Swap : $swap MB"
echo "CPU model            : $cname"
echo "Number of cores      : $cores"
sleep 1
next

#################################################################
#菜单
  read -p "Do you want to install Web server? [y/n]: " Web_yn
  if [[ ! $Web_yn =~ ^[y,n]$ ]]; then
    echo "input error! Please only input 'y' or 'n'"
exit 1
  else
    if [ "$Web_yn" == 'y' ]; then 
        echo 'Please select Web server:'
        echo -e "\033[31m 1 $apache \033[0m"
        echo -e "\033[31m 2 $apache_openssl \033[0m"
        echo -e "\033[31m 3 $nginx_openssl \033[0m"
        echo -e "\033[31m 4 Yum install nginx php mysql \033[0m"
	echo -e "\033[31m 5 Tomcat8 \033[0m"
        read -p "Please input a number:(Default 3 press Enter) " Web_version
        [ -z "$Web_version" ] && Web_version=3
        if [[ ! $Web_version =~ ^[1-5]$ ]]; then
          echo "input error! Please only input number 1,2,3,4,5"
        fi
    fi
  fi
  

    read -p "Do you want to install php? [y/n]: " PHP_yn
  if [[ ! $PHP_yn =~ ^[y,n]$ ]]; then
    echo "input error! Please only input 'y' or 'n'"
exit 1
  else
    if [ "$PHP_yn" == 'y' ]; then 
        echo 'Please select php:'
        echo -e "\033[31m 1 $php5apache \033[0m"
        echo -e "\033[31m 2 $php5 \033[0m"
        echo -e "\033[31m 3 $php7 \033[0m"
        read -p "Please input a number:(Default 2 press Enter) " PHP_version
        [ -z "$PHP_version" ] && PHP_version=2
        if [[ ! $PHP_version =~ ^[1-3]$ ]]; then
          echo "input error! Please only input number 1,2,3"
        fi
    fi
  fi
  
  
  read -p "Do you want to install database? [y/n]: " DB_yn
  if [[ ! $DB_yn =~ ^[y,n]$ ]]; then
    echo "input error! Please only input 'y' or 'n'"
exit 1
  else
    if [ "$DB_yn" == 'y' ]; then 
        echo 'Please select database:'
	echo -e "\033[31m 1 Do not install database \033[0m"
        echo -e "\033[31m 2 $mysql6 \033[0m"
        echo -e "\033[31m 3 $mysql7 \033[0m"
        echo -e "\033[31m 4 $mysql7 binary \033[0m"
        read -p "Please input a number:(Default 1 press Enter) " Db_version
        [ -z "$Db_version" ] && Db_version=1
        if [[ ! $Db_version =~ ^[1-4]$ ]]; then
          echo "input error! Please only input number 1,2,3,4"
        fi
    fi
  fi 


cat >> /etc/security/limits.conf <<EOF
* soft nproc 65535  
* hard nproc 65535  
* soft nofile 65535  
* hard nofile 65535  
EOF

echo "ulimit -SH 65535" >> /etc/rc.local
#soft 指的是当前系统生效的设置值  hard 表明系统中所能设定的最大值
#nofile - 打开文件的最大数目  noproc - 进程的最大数目



echo -e "\033[31m 10s later will install \033[0m"
 sleep 10

#Web server
   if [ "$Web_version" == '1' ]; then
./sh/apache.sh 2>&1 | tee apache.log
  elif [ "$Web_version" == '2' ]; then
./sh/apache_openssl.sh 2>&1 | tee apache_openssl.log 
  elif [ "$Web_version" == '3' ]; then
./sh/nginx.sh 2>&1 | tee nginx.log
   elif [ "$Web_version" == '4' ]; then
./sh/yum_nginx_php_mysql.sh 2>&1 | tee yum_nginx_php_mysql.log
   elif [ "$Web_version" == '5' ]; then
./sh/tomcat.sh 2>&1 | tee tomcat.log
fi

#php
  if [ "$PHP_version" == '1' ]; then
./sh/php5apache.sh 2>&1 | tee php5apache.log;
  elif [ "$PHP_version" == '2' ]; then
./sh/php5.sh 2>&1 | tee php5.log;
  elif [ "$PHP_version" == '3' ]; then
./sh/php7.sh 2>&1 | tee php7.log;
fi
 
#数据库
  if [ "$Db_version" == '1' ]; then
echo do not install database
elif [ "$Db_version" == '2' ]; then
 ./sh/mysql.sh 2>&1 |tee mysql.log;
  elif [ "$Db_version" == '3' ]; then
 ./sh/mysql5.7.sh 2>&1 |tee mysql.log;
  elif [ "$Db_version" == '4' ]; then
 ./sh/mysql5.7_binary.sh 2>&1 |tee mysql.log;
fi

# ps -ef | grep *.sh|grep -v grep  无法退出脚本
#root      1800  1791  0 16:33 pts/1    00:00:00 bash install.sh
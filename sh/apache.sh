#!/bin/bash
#Apache httpd 2.2 End-of-Life The final release 2.2.34 was published in July 2017
THREAD=$(cat /proc/cpuinfo | grep 'model name'| wc -l)
apstable=2.2.34
yum -y install gcc make epel-release  pcre-devel zlib-devel lynx openssl openssl-devel

if ping -c 3 file.asuhu.com >/dev/null;then
echo "website configuration files check ok"
else
echo "website configuration files check error. Please contact 860116511@qq.com"
exit 1
fi

if [ ! -e '/usr/bin/wget' ];then yum -y install wget;fi

cd ~
wget http://archive.apache.org/dist//httpd/httpd-$apstable.tar.gz  #http://archive.apache.org/dist/httpd/
tar -zxf httpd-$apstable.tar.gz && rm -rf httpd-$apstable.tar.gz

cd ~
yum -y install expat-devel
#http://archive.apache.org/dist/apr/apr-1.6.5.tar.gz http://archive.apache.org/dist/apr/apr-util-1.6.1.tar.gz
aprversion=apr-1.6.5
aprutilversion=apr-util-1.6.1
wget http://archive.apache.org/dist/apr/${aprversion}.tar.gz
wget http://archive.apache.org/dist/apr/${aprutilversion}.tar.gz
tar zxf ${aprversion}.tar.gz && cp -fr ./${aprversion} ./httpd-$apstable/srclib/apr
tar zxf ${aprutilversion}.tar.gz && cp -fr ./${aprutilversion} ./httpd-$apstable/srclib/apr-util
rm -rf ${aprversion}.tar.gz && rm -rf ${aprutilversion}.tar.gz

#Diy Apache version
sed -i 's/^#define AP_SERVER_BASEVENDOR.*/#define AP_SERVER_BASEVENDOR "Microsoft-IIS Software Foundation" /g'  ~/httpd-${apstable}/include/ap_release.h
sed -i 's/^#define AP_SERVER_BASEPROJECT.*/#define AP_SERVER_BASEPROJECT "Microsoft-IIS HTTP Server" /g' ~/httpd-${apstable}/include/ap_release.h
sed -i 's@^#define AP_SERVER_BASEPRODUCT.*@#define AP_SERVER_BASEPRODUCT "Microsoft-IIS/10.0" @g'  ~/httpd-${apstable}/include/ap_release.h

#configuration
cd ~
cd httpd-$apstable;
	./configure \
	--prefix=/usr/local/apache \
	--with-mpm=prefork \
	--with-included-apr \
	--with-ssl \
	--with-pcre \
	--enable-dav \
	--enable-so \
	--enable-suexec \
	--enable-proxy \
	--enable-proxy-balancer \
	--enable-deflate=shared \
	--enable-expires=shared \
	--enable-ssl=shared \
	--enable-headers=shared \
	--enable-rewrite=shared \
	--enable-static-support \
	--enable-modules=all \
	--enable-mods-shared=all
make -j ${THREAD} && make install
cd ~

if [ ! -e '/usr/local/apache/bin/httpd' ]; then
echo -e "\033[31m Install apache error ... \033[0m \n"
kill -9 $$
fi

    id -u apache >/dev/null 2>&1
    [ $? -ne 0 ] && useradd -M -s /sbin/nologin apache
chown apache.apache -R /usr/local/apache  #创建用户和文件夹并赋予文件夹用户权限
###
cp -f /usr/local/apache/bin/apachectl /etc/init.d/httpd;
sed -i '2a # chkconfig: - 85 15' /etc/init.d/httpd;
sed -i '3a # description: Apache is a World Wide Web server. It is used to server' /etc/init.d/httpd;
chkconfig --add httpd;chkconfig httpd on;
chmod +x /etc/init.d/httpd
###
if service iptables status ;then
iptables -I INPUT -p tcp -m multiport --dport 80,443,8080,3306 -j ACCEPT
service iptables save;service iptables restart
elif systemctl status firewalld.service;then
firewall-cmd --zone=public --add-port=80/tcp --permanent
firewall-cmd --zone=public --add-port=443/tcp --permanent
firewall-cmd --zone=public --add-port=8080/tcp --permanent
firewall-cmd --zone=public --add-port=3306/tcp --permanent
firewall-cmd --reload
fi
###
#修改apache的用户和组，监听端口，管理员邮箱，DirectoryIndex，MPM，支持目录索引autoindex
    sed -i 's/^User.*/User apache/i' /usr/local/apache/conf/httpd.conf
    sed -i 's/^Group.*/Group apache/i' /usr/local/apache/conf/httpd.conf
    sed -i 's/^#ServerName www.example.com:80/ServerName 0.0.0.0:80/' /usr/local/apache/conf/httpd.conf
    sed -i 's/^ServerAdmin you@example.com/ServerAdmin admin@localhost/' /usr/local/apache/conf/httpd.conf
    sed -i 's@^#Include conf/extra/httpd-info.conf@Include conf/extra/httpd-info.conf@' /usr/local/apache/conf/httpd.conf
    sed -i 's@DirectoryIndex index.html@DirectoryIndex index.html index.htm index.php index.shtml@' /usr/local/apache/conf/httpd.conf
    sed -i "s@^#Include conf/extra/httpd-mpm.conf@Include conf/extra/httpd-mpm.conf@" /usr/local/apache/conf/httpd.conf
    sed -i 's@^#Include conf/extra/httpd-autoindex.conf@Include conf/extra/httpd-autoindex.conf@' /usr/local/apache/conf/httpd.conf
    sed -i 's@^#Include conf/extra/httpd-languages.conf@Include conf/extra/httpd-languages.conf@' /usr/local/apache/conf/httpd.conf
#Apache 2.2.34 Source compilation .so will be enabled,No separate configuration required
#https://httpd.apache.org/docs/2.2/mod/
#    sed -i -r 's/^#(.*mod_cache.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_cache_socache.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_socache_shmcb.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_socache_dbm.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_socache_memcache.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_proxy.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_proxy_connect.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_proxy_ftp.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_proxy_http.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_proxy_fcgi.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_suexec.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_vhost_alias.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_rewrite.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_deflate.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_expires.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_ssl.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_dav.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_dav_fs.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_dav_lock.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_remoteip.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_watchdog.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_buffer.so)/\1/' /usr/local/apache/conf/httpd.conf
#    sed -i -r 's/^#(.*mod_info.so)/\1/' /usr/local/apache/conf/httpd.conf

    sed -i 's/Allow from All/Require all granted/' /usr/local/apache/conf/extra/httpd-vhosts.conf
    sed -i 's/Require host .example.com/Require host localhost/g' /usr/local/apache/conf/extra/httpd-info.conf

#server-status server-info
sed -i 's@Allow from .example.com@Allow from 127.0.0.1 ::1@g' /usr/local/apache/conf/extra/httpd-info.conf
#httpd.conf
  cat >> /usr/local/apache/conf/httpd.conf << "EOF"
<IfModule mod_headers.c>
  AddOutputFilterByType DEFLATE text/html text/plain text/css text/xml text/javascript
  <FilesMatch "\.(js|css|html|htm|png|jpg|swf|pdf|shtml|xml|flv|gif|ico|jpeg)\$">
    RequestHeader edit "If-None-Match" "^(.*)-gzip(.*)\$" "\$1\$2"
    Header edit "ETag" "^(.*)-gzip(.*)\$" "\$1\$2"
  </FilesMatch>
  DeflateCompressionLevel 6
  SetOutputFilter DEFLATE
</IfModule>

PidFile /var/run/httpd.pid
ServerTokens ProductOnly
ServerSignature Off
Include conf/vhost/*.conf

#To parse .shtml files for server-side includes (SSI):
#(You will also need to add "Includes" to the "Options" directive.)
AddType text/html .shtml
AddOutputFilter INCLUDES .shtml
EOF
##########
#设置Apache 支持 PHP
sed -i "s@AddType\(.*\)Z@AddType\1Z\n    AddType application/x-httpd-php .php .phtml\n    AddType appication/x-httpd-php-source .phps@"  /usr/local/apache/conf/httpd.conf;
##########
mkdir -p /home/{wwwroot,wwwlogs}
mkdir -p /home/wwwroot/default
mkdir -p /usr/local/apache/conf/vhost
wwwroot_dir=/home/wwwroot
wwwlogs_dir=/home/wwwlogs

#cat > /usr/local/apache/conf/vhost/default.conf << "EOF" 变量失效
cat > /usr/local/apache/conf/vhost/default.conf << EOF
NameVirtualHost *:80
<VirtualHost *:80>
  ServerAdmin admin@example.com
  DocumentRoot "${wwwroot_dir}/default"
  ServerName 127.0.0.1
  ErrorLog "|/usr/local/apache/bin/rotatelogs ${wwwlogs_dir}/error_log_%Y%m%d 86400 480"
  CustomLog "|/usr/local/apache/bin/rotatelogs ${wwwlogs_dir}/access_log_%Y%m%d 86400 480" combined
<Directory "${wwwroot_dir}/default">
  SetOutputFilter DEFLATE
  Options FollowSymLinks IncludesNoExec
  AllowOverride All
  Order allow,deny
  Allow from all
  DirectoryIndex index.html index.php
</Directory>
<Location /server-status>
  SetHandler server-status
  Order Deny,Allow
  Deny from all
  Allow from 127.0.0.1 ::1
</Location>
</VirtualHost>
EOF


chown apache.apache -R /usr/local/apache
chown apache.apache -R /home/{wwwroot,wwwlogs}
/usr/local/apache/bin/httpd -V
#path
echo 'export PATH=/usr/local/apache/bin:$PATH'>>/etc/profile && source /etc/profile
#
cd ~
rm -rf httpd-${apstable}
rm -rf ${aprversion}
rm -rf ${aprutilversion}

#Options 所有前面加有"+"号的可选项将强制覆盖当前的可选项设置，而所有前面有"-"号的可选项将强制从当前可选项设置中去除
#Options -Indexes FollowSymLinks #不允许目录游览，允许符号链接
#Options Indexes                 #表示启用目录浏览
#Options FollowSymLinks ExecCGI  #允许目录游览和符号链接，允许使用mod_cgi模块执行CGI脚本
#
#AllowOverride None              #表示禁止用户对目录配置文件（.htaccess进行修改）重载
#AllowOverride All               #rewrite规则会写在 .htaccess 文件里
#
#Includes                            #启用SSI （Server Side Include）规范有效 <!--#exec cmd="..."-->  <!--#exec cgi="..."-->  <!--#include file="..."-->
#IncludesNoExec                 #启用SSI （Server Side Include），但EXEC指令无效（执行CGI程序的指令） <!--#include file="..."-->规范有效  ，<!--#exec cmd="..."-->  <!--#exec cgi="..."-->  exec等程序执行将受到限制不能执行
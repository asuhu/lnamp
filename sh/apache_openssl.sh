#!/bin/bash
a=$(cat /proc/cpuinfo | grep 'model name'| wc -l)
apstable=2.4.29
yum -y install gcc make epel-release  pcre-devel zlib-devel lynx perl

#安装openssl
source ~/sh/function.sh
install_phpopenssl

cd ~
wget http://archive.apache.org/dist//httpd/httpd-$apstable.tar.gz
tar -zxf httpd-$apstable.tar.gz;rm -rf httpd-$apstable.tar.gz;

source ~/sh/function.sh
install_nghttp2

cd ~
yum -y install expat-devel
wget http://archive.apache.org/dist/apr/apr-1.6.2.tar.gz
wget http://archive.apache.org/dist/apr/apr-util-1.6.0.tar.gz
tar zxf apr-1.6.2.tar.gz && cp -fr ./apr-1.6.2 ./httpd-$apstable/srclib/apr
tar zxf apr-util-1.6.0.tar.gz && cp -fr ./apr-util-1.6.0 ./httpd-$apstable/srclib/apr-util
rm -rf apr-1.6.2.tar.gz;rm -rf apr-util-1.6.0.tar.gz
cd ~
cd httpd-$apstable;
./configure \
--prefix=/usr/local/apache \
--with-mpm=event \
--enable-mpms-shared=all \
--with-included-apr \
--with-nghttp2=/usr/local/nghttp2 \
--with-pcre \
--with-zlib \
--with-ssl=/usr/local/openssl \
--enable-headers \
--enable-deflate \
--enable-so \
--enable-dav \
--enable-rewrite \
--enable-ssl
--enable-mime-magic \
--enable-proxy \
--enable-http2 \
--enable-expires --enable-static-support --enable-suexec \
--enable-modules=all --enable-mods-shared=all
make -j$a
make install
#编译完毕
#event /usr/local/php/lib/php/extensions/no-debug-zts-20131226
#LoadModule mpm_event_module modules/mod_mpm_event.so
#mod_mpm_event.so
#mod_mpm_prefork.so
#mod_mpm_worker.so
#可以切换apache的工作模式，但是worker和event需要启用php的线程安全

if [ ! -e '/usr/local/apache/bin/httpd' ]; then
echo -e "\033[31m Install apache error ... \033[0m \n"
exit
fi

cd ~
useradd -M -s /sbin/nologin apache;chown apache.apache -R /usr/local/apache;  #创建用户和文件夹并赋予文件夹用户权限
cp -f /usr/local/apache/bin/apachectl /etc/init.d/httpd;
sed -i '2a # chkconfig: - 85 15' /etc/init.d/httpd;
sed -i '3a # description: Apache is a World Wide Web server. It is used to server' /etc/init.d/httpd;
chkconfig --add httpd;chkconfig httpd on;
chmod +x /etc/init.d/httpd;
iptables -I INPUT -p tcp -m multiport --dport 80,443,8080,3306 -j ACCEPT;
service iptables save;service iptables restart;
echo 'export PATH=/usr/local/apache/bin:$PATH'>>/etc/profile;
source /etc/profile;
#日志轮训
    cat > /etc/logrotate.d/httpd <<EOF
   /usr/local/apache/logs/*log{
        daily
        rotate 14
        missingok
        notifempty
        compress
        sharedscripts
        postrotate
            [ ! -f /usr/local/apache/logs/httpd.pid ] || kill -USR1 \`cat /usr/local/apache/logs/httpd.pid\`
        endscript
    }
EOF

#修改apache的用户和组，监听端口，管理员邮箱，对php文件的支持，MPM
    sed -i 's/^User.*/User apache/i' /usr/local/apache/conf/httpd.conf
    sed -i 's/^Group.*/Group apache/i' /usr/local/apache/conf/httpd.conf
    sed -i 's/^#ServerName www.example.com:80/ServerName 0.0.0.0:80/' /usr/local/apache/conf/httpd.conf
    sed -i 's/^ServerAdmin you@example.com/ServerAdmin admin@localhost/' /usr/local/apache/conf/httpd.conf
    sed -i 's@^#Include conf/extra/httpd-info.conf@Include conf/extra/httpd-info.conf@' /usr/local/apache/conf/httpd.conf
    sed -i 's@DirectoryIndex index.html@DirectoryIndex index.html index.htm index.php index.shtml@' /usr/local/apache/conf/httpd.conf
    sed -i "s@^#Include conf/extra/httpd-mpm.conf@Include conf/extra/httpd-mpm.conf@" /usr/local/apache/conf/httpd.conf
    sed -i 's@^#Include conf/extra/httpd-autoindex.conf@Include conf/extra/httpd-autoindex.conf@' /usr/local/apache/conf/httpd.conf
    sed -i 's@^#Include conf/extra/httpd-languages.conf@Include conf/extra/httpd-languages.conf@' /usr/local/apache/conf/httpd.conf
#启用模块
    sed -i -r 's/^#(.*mod_cache.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_cache_socache.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_socache_shmcb.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_socache_dbm.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_socache_memcache.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_proxy.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_proxy_connect.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_proxy_ftp.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_proxy_http.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_suexec.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_vhost_alias.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_rewrite.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_deflate.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_expires.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_ssl.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_dav.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_dav_fs.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_dav_lock.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_proxy_fcgi.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_remoteip.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_watchdog.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_buffer.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_http2.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_proxy_http2.so)/\1/' /usr/local/apache/conf/httpd.conf
    sed -i -r 's/^#(.*mod_negotiation.so)/\1/' /usr/local/apache/conf/httpd.conf
#启用常见的模块sed -i -r 's/^#(.*.so)/\1/' /usr/local/apache/conf/httpd.conf  不能使用这个，范围太大

#设置server-status的允许范围
    sed -i 's/Allow from All/Require all granted/' /usr/local/apache/conf/extra/httpd-vhosts.conf
    sed -i 's/Require host localhost/Require ip 0.0.0.0/g' /usr/local/apache/conf/extra/httpd-info.conf
    sed -i 's/Require ip 127/Require ip ::1/g' /usr/local/apache/conf/extra/httpd-info.conf

#字符设置
sed -i -e '/Options Indexes FollowSymLinks/a\IndexOptions Charset=UTF-8' /usr/local/apache/conf/httpd.conf

  cat >> /usr/local/apache/conf/httpd.conf <<EOF
<IfModule mod_headers.c>
  AddOutputFilterByType DEFLATE text/html text/plain text/css text/xml text/javascript
  <FilesMatch "\.(js|css|html|htm|png|jpg|swf|pdf|shtml|xml|flv|gif|ico|jpeg)\$">
    RequestHeader edit "If-None-Match" "^(.*)-gzip(.*)\$" "\$1\$2"
    Header edit "ETag" "^(.*)-gzip(.*)\$" "\$1\$2"
  </FilesMatch>
  DeflateCompressionLevel 6
  SetOutputFilter DEFLATE
</IfModule>

ProtocolsHonorOrder On
        Protocols h2 http/1.1
        Protocols h2c http/1.1
        PidFile /var/run/httpd.pid
    ServerTokens ProductOnly
    ServerSignature Off
EOF

mkdir -p /usr/local/apache/conf/vhost
chown apache.apache -R /usr/local/apache
/usr/local/apache/bin/httpd -V
#Include conf/vhost/*.conf
#Require ip 0.0.0.0   允许本机所有地址
#Require ip ::1       允许本机IPV6地址
#Require all granted 所有的都允许
#Require all denied  所有的都拒绝
# 对于 https 服务器 Protocols h2 http/1.1
# 对于 http 服务器 Protocols h2c http/1.1
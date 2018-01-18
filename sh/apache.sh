#!/bin/bash
a=$(cat /proc/cpuinfo | grep 'model name'| wc -l)
apstable=2.2.34
yum -y install gcc make epel-release  pcre-devel zlib-devel lynx openssl openssl-devel

cd ~
#原版wget http://archive.apache.org/dist//httpd/httpd-$apstable.tar.gz
#判断国内国外下载优化版的apache
cd ~
if ping -c 1 216.58.200.4 >/dev/null;then
wget http://file.asuhu.com/so/httpd-2.2.34.tar.gz   #http://arv.asuhu.com/ftp/so/httpd-2.2.34.tar.gz
else
wget http://qiniu.geecdn.com/httpd-2.2.34.tar.gz
fi
tar -zxf httpd-$apstable.tar.gz

cd ~
yum -y install expat-devel
wget http://archive.apache.org/dist/apr/apr-1.6.2.tar.gz
wget http://archive.apache.org/dist/apr/apr-util-1.6.0.tar.gz
tar zxf apr-1.6.2.tar.gz && cp -fr ./apr-1.6.2 ./httpd-$apstable/srclib/apr
tar zxf apr-util-1.6.0.tar.gz && cp -fr ./apr-util-1.6.0 ./httpd-$apstable/srclib/apr-util
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
        --enable-deflate=shared \
        --enable-expires=shared \
        --enable-ssl=shared \
        --enable-headers=shared \
        --enable-rewrite=shared \
        --enable-static-support \
        --enable-modules=all \
        --enable-mods-shared=all
make -j$a
make install

if [ ! -e '/usr/local/apache/bin/httpd' ]; then
echo -e "\033[31m Install apache error ... \033[0m \n"
exit 1
fi

    id -u apache >/dev/null 2>&1
    [ $? -ne 0 ] && useradd -M -s /sbin/nologin apache
chown apache.apache -R /usr/local/apache  #创建用户和文件夹并赋予文件夹用户权限
cp -f /usr/local/apache/bin/apachectl /etc/init.d/httpd;
sed -i '2a # chkconfig: - 85 15' /etc/init.d/httpd;
sed -i '3a # description: Apache is a World Wide Web server. It is used to server' /etc/init.d/httpd;
chkconfig --add httpd;chkconfig httpd on;
iptables -I INPUT -p tcp -m multiport --dport 80,443,8080,3306 -j ACCEPT;
service iptables save;service iptables restart;
chmod +x /etc/init.d/httpd
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
#修改apache的用户和组，监听端口，管理员邮箱，对php文件的支持
    sed -i 's/^User.*/User apache/i' /usr/local/apache/conf/httpd.conf
    sed -i 's/^Group.*/Group apache/i' /usr/local/apache/conf/httpd.conf
    sed -i 's/^#ServerName www.example.com:80/ServerName 0.0.0.0:80/' /usr/local/apache/conf/httpd.conf
    sed -i 's/^ServerAdmin you@example.com/ServerAdmin admin@localhost/' /usr/local/apache/conf/httpd.conf
    sed -i 's@^#Include conf/extra/httpd-info.conf@Include conf/extra/httpd-info.conf@' /usr/local/apache/conf/httpd.conf
    sed -i 's@DirectoryIndex index.html@DirectoryIndex index.html index.htm index.php index.shtml@' /usr/local/apache/conf/httpd.conf
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

    sed -i 's/Allow from All/Require all granted/' /usr/local/apache/conf/extra/httpd-vhosts.conf
    sed -i 's/Require host .example.com/Require host localhost/g' /usr/local/apache/conf/extra/httpd-info.conf
#server-status server-info
sed -i 's/Allow from .example.com/Allow from ::1/g' /usr/local/apache/conf/extra/httpd-info.conf

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
EOF

mkdir -p /usr/local/apache/conf/vhost
chown apache.apache -R /usr/local/apache
#Include conf/vhost/*.conf
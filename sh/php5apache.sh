#!/bin/bash
#apache
#使用了EPEL源
#定义常量
if [ $? -gt 0 ] ;then echo "error";exit 1 ;fi

a=$(cat /proc/cpuinfo | grep 'model name'| wc -l)
Mem=$( free -m | awk '/Mem/ {print $2}' )
Bit=$(getconf LONG_BIT)
phpstable56=5.6.33

#yum安装
yum -y install wget gcc make vim screen epel-release
yum clean all
yum install libxml2-devel curl-devel libjpeg-devel libjpeg-devel libpng-devel freetype-devel  bzip2-devel net-snmp-devel openldap-devel gmp-devel -y

if [ ! -e '/usr/bin/wget' ]; then
yum -y install wget
fi

#if [ $Bit -eq 64 ]; then
#cp -frp /usr/lib64/libldap* /usr/lib/
#fi
#上面的将用--with-libdir=lib64代替，安装的系统是64位的，而64位的用户库文件默认是在/usr/lib64，指定--with-libdir=lib64，而编译脚本默认是lib

#安装一些扩展
source ~/sh/function.sh
install_add

#安装libmcrypt
source ~/sh/function.sh
install_phpmcrypt

#安装openssl
source ~/sh/function.sh
install_phpopenssl

#安装curl
source ~/sh/function.sh
install_curl
/usr/local/curl/bin/curl --version

cd ~
wget -4 -q http://hk2.php.net/distributions/php-${phpstable56}.tar.gz  #wget -4 http://www.php.net/distributions/php-${phpstable56}.tar.gz
tar -zxf php-${phpstable56}.tar.gz && rm -rf php-${phpstable56}.tar.gz 
cd php-${phpstable56}
yum -y install zlib-devel
if [ $Bit -eq 64 ]; then
CFLAGS= CXXFLAGS= ./configure --prefix=/usr/local/php \
--with-apxs2=/usr/local/apache/bin/apxs \
--with-config-file-path=/usr/local/php/etc --with-config-file-scan-dir=/usr/local/php/etc/php.d \
--with-mysql=mysqlnd --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd --enable-opcache \
--with-iconv-dir=/usr/local  --with-freetype-dir --with-jpeg-dir --with-png-dir \
--with-libxml-dir=/usr --enable-xml --disable-rpath \
--with-snmp=shared --with-bz2 \
--with-ldap \
--with-ldap-sasl \
--with-libdir=lib64 \
--with-gd --with-mcrypt \
--with-openssl-dir=/usr/local/openssl --with-openssl --with-curl=/usr/local/curl --with-zlib \
--with-mhash --with-xmlrpc --without-pear --with-gettext \
--enable-json --enable-bcmath --enable-calendar --enable-wddx \
--enable-shmop --enable-sysvsem --enable-inline-optimization \
--enable-mbregex --enable-mbstring \
--enable-ftp --enable-gd-native-ttf --enable-pcntl --enable-sockets --enable-zip --enable-soap --enable-exif \
--disable-ipv6 --disable-debug --disable-fileinfo
 elif [ $Bit -eq 32 ];then
CFLAGS= CXXFLAGS= ./configure --prefix=/usr/local/php \
--with-apxs2=/usr/local/apache/bin/apxs \
--with-config-file-path=/usr/local/php/etc --with-config-file-scan-dir=/usr/local/php/etc/php.d \
--with-mysql=mysqlnd --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd --enable-opcache \
--with-iconv-dir=/usr/local  --with-freetype-dir --with-jpeg-dir --with-png-dir \
--with-libxml-dir=/usr --enable-xml --disable-rpath \
--with-snmp=shared --with-bz2 \
--with-ldap \
--with-ldap-sasl \
--with-gd --with-mcrypt \
--with-openssl-dir=/usr/local/openssl --with-openssl --with-curl=/usr/local/curl --with-zlib-dir=/usr/local/zlib --with-zlib \
--with-mhash --with-xmlrpc --without-pear --with-gettext \
--enable-json --enable-bcmath --enable-calendar --enable-wddx \
--enable-shmop --enable-sysvsem --enable-inline-optimization \
--enable-mbregex --enable-mbstring \
--enable-ftp --enable-gd-native-ttf --enable-pcntl --enable-sockets --enable-zip --enable-soap --enable-exif \
--disable-ipv6 --disable-debug --disable-fileinfo
fi
cp -f /usr/local/apache/build/libtool /root/php-${phpstable56}/libtool

make -j"$a"
make install

#Scan this dir for additional .ini files
mkdir -p /usr/local/php/etc/php.d

#添加用户和权限apache
id -u apache >/dev/null 2>&1
    [ $? -ne 0 ] && useradd -M -s /sbin/nologin apache
chown apache.apache -R /usr/local/php;

#检测php是否安装成功
if [ ! -e '/usr/local/php/bin/phpize' ]; then
echo -e "\033[31m Install php error ... \033[0m \n"
exit 1
fi

#apache结合php的配置
chown apache.apache -R /usr/local/php
cp /root/php-${phpstable56}/php.ini-development  /usr/local/php/etc/php.ini;

#设置Apache 支持 PHP
sed -i "s@AddType\(.*\)Z@AddType\1Z\n    AddType application/x-httpd-php .php .phtml\n    AddType appication/x-httpd-php-source .phps@"  /usr/local/apache/conf/httpd.conf

if [ $Mem -gt 1000 -a $Mem -le 2500 ];then
sed -i "s@^memory_limit.*@memory_limit = 64M@" /usr/local/php/etc/php.ini
elif [ $Mem -gt 2500 -a $Mem -le 3500 ];then
sed -i "s@^memory_limit.*@memory_limit = 128M@" /usr/local/php/etc/php.ini
elif [ $Mem -gt 3500 ];then
sed -i "s@^memory_limit.*@memory_limit = 256M@" /usr/local/php/etc/php.ini
fi

sed -i 's@^output_buffering =@output_buffering = On\noutput_buffering =@' /usr/local/php/etc/php.ini
sed -i 's@^;cgi.fix_pathinfo.*@cgi.fix_pathinfo=0@' /usr/local/php/etc/php.ini
sed -i 's@^short_open_tag = Off@short_open_tag = On@' /usr/local/php/etc/php.ini 
sed -i 's@^expose_php = On@expose_php = Off@' /usr/local/php/etc/php.ini
sed -i 's@^request_order.*@request_order = "CGP"@' /usr/local/php/etc/php.ini
sed -i 's@^;date.timezone.*@date.timezone = Asia/Shanghai@' /usr/local/php/etc/php.ini
sed -i 's@^post_max_size.*@post_max_size = 100M@' /usr/local/php/etc/php.ini
sed -i 's@^upload_max_filesize.*@upload_max_filesize = 50M@' /usr/local/php/etc/php.ini
sed -i 's@^max_execution_time.*@max_execution_time = 5@' /usr/local/php/etc/php.ini
sed -i 's@^disable_functions.*@disable_functions = passthru,exec,system,chroot,chgrp,chown,shell_exec,proc_open,proc_get_status,ini_alter,ini_restore,dl,openlog,syslog,readlink,symlink,popepassthru,stream_socket_server,fsocket,popen,eval,parse_ini_file,show_source,pclose,multi_exec,chmod,set_time_limit@' /usr/local/php/etc/php.ini



#探针
wget -O /usr/local/apache/htdocs/proble.tar.gz http://file.asuhu.com/so/proble.tar.gz
cd /usr/local/apache/htdocs/
tar -zxvf proble.tar.gz
service httpd restart
rm -rf proble.tar.gz

#php扩展
cat > /usr/local/php/etc/php.d/opcache.ini << EOF
[opcache]
zend_extension=opcache.so
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=4000
opcache.revalidate_freq=60
opcache.save_comments=0
opcache.fast_shutdown=1
opcache.enable_cli=1
;opcache.optimization_level=0
EOF

#apache 2.4.27 prefork不支持http2,worker evnet需要线程安全
#ioncube_loader安装
if [ -e /usr/local/php/lib/php/extensions/no-debug-non-zts-20131226 ];then
cd ~ 
wget -O /usr/local/php/lib/php/extensions/no-debug-non-zts-20131226/ioncube_loader_lin_5.6.so http://file.asuhu.com/so/ioncube/ioncube_loader_lin_5.6.so
    if [ ! -e '/usr/local/php/lib/php/extensions/no-debug-non-zts-20131226/ioncube_loader_lin_5.6.so' ];then
wget -O /usr/local/php/lib/php/extensions/no-debug-non-zts-20131226/ioncube_loader_lin_5.6.so http://arv.asuhu.com/ftp/so/ioncube/ioncube_loader_lin_5.6.so
    fi
chmod +x /usr/local/php/lib/php/extensions/no-debug-non-zts-20131226/ioncube_loader_lin_5.6.so
cat > /usr/local/php/etc/php.d/ioncube.ini << EOF
[ioncube]
zend_extension=ioncube_loader_lin_5.6.so
EOF

elif [ -e /usr/local/php/lib/php/extensions/no-debug-non-zts-20131226 ]; then
cd ~ 
wget -O /usr/local/php/lib/php/extensions/no-debug-zts-20131226/ioncube_loader_lin_5.6_ts.so  http://file.asuhu.com/so/ioncube/ioncube_loader_lin_5.6_ts.so
    if [ ! -e '/usr/local/php/lib/php/extensions/no-debug-zts-20131226/ioncube_loader_lin_5.6_ts.so' ];then
wget -O /usr/local/php/lib/php/extensions/no-debug-zts-20131226/ioncube_loader_lin_5.6_ts.so  http://arv.asuhu.com/ftp/so/ioncube/ioncube_loader_lin_5.6_ts.so
    fi
chmod +x /usr/local/php/lib/php/extensions/no-debug-zts-20131226/ioncube_loader_lin_5.6_ts.so
cat > /usr/local/php/etc/php.d/ioncube.ini << EOF
[ioncube]
zend_extension=ioncube_loader_lin_5.6_ts.so
EOF
fi

#安装ZendGuardLoader.so
if [ -e /usr/local/php/lib/php/extensions/no-debug-non-zts-20131226 ];then
cd ~ 
wget -O /usr/local/php/lib/php/extensions/no-debug-non-zts-20131226/ZendGuardLoader.so http://file.asuhu.com/so/zend/ZendGuardLoader.so
    if [ ! -e '/usr/local/php/lib/php/extensions/no-debug-non-zts-20131226/ZendGuardLoader.so' ];then
wget -O /usr/local/php/lib/php/extensions/no-debug-non-zts-20131226/ZendGuardLoader.so http://arv.asuhu.com/ftp/so/zend/ZendGuardLoader.so
    fi
chmod +x /usr/local/php/lib/php/extensions/no-debug-non-zts-20131226/ZendGuardLoader.so
cat > /usr/local/php/etc/php.d/zend.ini << EOF
[Zend Guard]
zend_extension = ZendGuardLoader.so
zend_loader.enable = 1
zend_loader.disable_licensing = 0
zend_loader.obfuscation_level_support = 3
zend_loader.license_path =
EOF
elif [ -e /usr/local/php/lib/php/extensions/no-debug-non-zts-20131226 ]; then
echo "nothing to do"
cd ~
#wget http://downloads.zend.com/guard/7.0.0/zend-loader-php5.6-linux-x86_64.tar.gz
#wget http://downloads.zend.com/guard/7.0.0/ZendGuard-7.0.0-linux.gtk.x86_64.tar.gz
#wget -O /usr/local/php/lib/php/extensions/no-debug-zts-20131226/ZendGuardLoader.so  http://file.asuhu.com/so/zend/ZendGuardLoader.so
#chmod +x /usr/local/php/lib/php/extensions/no-debug-zts-20131226/ZendGuardLoader.so
# /usr/local/php/lib/php/extensions/no-debug-zts-20131226/ZendGuardLoader.so: undefined symbol: executor_globals
fi

#为了避免冲突，snmp用单独的模块，/usr/bin/ld: warning: libssl.so.10, needed by /usr/lib/gcc/x86_64-redhat-linux.8.5/../../../../lib64/libnetsnmp.so, may conflict with libssl.so.1.0.0
cat > /usr/local/php/etc/php.d/snmp.ini << EOF
[snmp]
extension = snmp.so
EOF

#安装phpredis
source ~/sh/function.sh
install_phpredis

#解决phpcertificate问题
source ~/sh/function.sh
install_certificate

/etc/init.d/httpd restart
#libtool: warning: remember to run 'libtool --finish /root/php-5.6.31/libs'
#PEAR package PHP_Archive not installed: generated phar will require PHP's phar extension be enabled.
#删除php源码文件
cd ~
/root/php-${phpstable56}/libtool --finish /usr/local/php/lib
echo "/usr/local/php/lib" > /etc/ld.so.conf.d/php.conf
/usr/local/php/bin/php --version
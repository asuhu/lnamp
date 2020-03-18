#!/bin/bash
#enable epel-release
#https://www.php.net/supported-versions.php
#PHP7.3 matching OpenSSL1.1.1 
#https://www.php.net/manual/en/zip.installation.php
#As of PHP 7.3.0, building against the bundled libzip is discouraged, but still possible by adding --without-libzip to the configuration.

THREAD=$(cat /proc/cpuinfo | grep 'model name'| wc -l)
Mem=$( free -m | awk '/Mem/ {print $2}' )
Bit=$(getconf LONG_BIT)



if  [ ! -n "$(grep ' 7\.' /etc/redhat-release)" ] ;then
echo "PHP7 Need CentOS_7"
kill -9 $$
fi

if [ $Mem -le 640 ]; then
  Memory_limit=64
elif [ $Mem -gt 640 -a $Mem -le 1280 ]; then
  Mem_level=1G
  Memory_limit=128
elif [ $Mem -gt 1280 -a $Mem -le 2500 ]; then
  Mem_level=2G
  Memory_limit=192
elif [ $Mem -gt 2500 -a $Mem -le 3500 ]; then
  Mem_level=3G
  Memory_limit=256
elif [ $Mem -gt 3500 -a $Mem -le 4500 ]; then
  Mem_level=4G
  Memory_limit=320
elif [ $Mem -gt 4500 -a $Mem -le 8000 ]; then
  Mem_level=6G
  Memory_limit=384
elif [ $Mem -gt 8000 ]; then
  Mem_level=8G
  Memory_limit=448
fi

sudo yum -y install wget gcc make vim screen epel-release
if ! which yum-config-manager;then sudo yum -y install yum-utils;fi
sudo yum-config-manager --enable epel
sudo yum -y install libxml2 libxml2-devel libjpeg-devel libpng-devel freetype-devel bzip2 bzip2-devel net-snmp-devel gmp-devel zlib-devel bison gd-devel 
sudo yum -y install python python-devel        #checking consistency of all components of python development environment... no
sudo yum -y install CUnit CUnit-devel          #configure: WARNING: No package 'cunit' found
sudo yum -y install libicu-devel

#yum -y install jansson-devel                  #configure: No package 'jansson' found ��nghttp2��ͻ
#yum -y install openldap-devel
#/usr/bin/ld: warning: libssl.so.10, needed by /usr/lib/gcc/x86_64-redhat-linux/4.8.5/../../../../lib64/libldap.so, may conflict with libssl.so.1.0.0
#/usr/bin/ld: warning: libcrypto.so.10, needed by /usr/lib/gcc/x86_64-redhat-linux/4.8.5/../../../../lib64/libldap.so, may conflict with libcrypto.so.1.0.0

if [ ! -e '/usr/bin/wget' ];then yum -y install wget;fi

yum -y install bison bison-devel libevent libevent-devel libxslt-devel libidn-devel libcurl-devel readline-devel re2c
#Cancel installation libmcrypt
#Source installation openssl111��curl(��zlib)
source ~/sh/function.sh
install_phpopenssl111
install_curl

#Download PHP7
php73_ver=7.3.15
cd ~
wget -4 -q --no-check-certificate https://www.php.net/distributions/php-${php73_ver}.tar.gz   #http://jp2.php.net/distributions/php-${php73_ver}.tar.gz
tar -zxf php-${php73_ver}.tar.gz && rm -rf php-${php73_ver}.tar.gz

#PHP7.3 New features
cd ~
argon2_ver=argon2-20171227
if [ ! -e "/usr/lib/libargon2.a" ]; then
wget -4 -q http://file.asuhu.com/so/${argon2_ver}.tar.gz
tar -zxf ${argon2_ver}.tar.gz && rm -rf ${argon2_ver}.tar.gz
cd ~/${argon2_ver}
make -j ${THREAD} && make install

fi

cd ~
libsodium_ver=libsodium-1.0.18
if [ ! -e "/usr/local/lib/libsodium.la" ]; then
wget -4 -q http://file.asuhu.com/so/${libsodium_ver}.tar.gz
tar -zxf ${libsodium_ver}.tar.gz && rm -rf ${libsodium_ver}.tar.gz
cd ~/${libsodium_ver}
./configure --disable-dependency-tracking --enable-minimal
make -j ${THREAD} && make install
fi

if [ ! -e "/usr/local/lib/libsodium.la" ]; then
echo "libsodium error"
kill -9 $$
else
rm -rf  ~/${libsodium_ver}
fi

if [ ! -e "/usr/lib/libargon2.a" ]; then
echo "argon2 error"
kill -9 $$
else
rm -rf  ~/${argon2_ver}
fi


#libzip https://blog.csdn.net/zhangatle/article/details/90169494
yum -y remove libzip libzip-devel
cd ~
wget https://libzip.org/download/libzip-1.3.0.tar.gz
tar -zxf libzip-1.3.0.tar.gz && rm -rf libzip-1.3.0.tar.gz
cd libzip-1.3.0
./configure
make && make install
cd ~
rm -rf ~/libzip-1.3.0
cp /usr/local/lib/libzip/include/zipconf.h /usr/local/include/zipconf.h
#libzip

#ld.so.conf.d
[ -z "`grep /usr/local/lib /etc/ld.so.conf.d/*.conf`" ] && echo '/usr/local/lib' > /etc/ld.so.conf.d/local.conf
ldconfig

cd ~/php-${php73_ver}
CFLAGS= CXXFLAGS= ./configure --prefix=/usr/local/php \
--with-config-file-path=/usr/local/php/etc \
--with-config-file-scan-dir=/usr/local/php/etc/php.d \
--with-apxs2=/usr/local/apache/bin/apxs \
--enable-opcache \
--enable-mysqlnd --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd \
--with-iconv-dir=/usr/local  --with-freetype-dir --with-jpeg-dir --with-png-dir \
--with-libxml-dir=/usr --enable-xml --disable-rpath --enable-bcmath --enable-shmop --enable-exif \
--enable-sysvsem --enable-inline-optimization --enable-mbregex \
--enable-mbstring --with-password-argon2 --with-sodium=/usr/local --with-gd  \
--with-mhash --enable-pcntl --enable-sockets --with-xmlrpc --enable-ftp  --enable-intl --with-xsl \
--with-gettext --enable-zip --enable-soap \
--with-openssl=/usr/local/openssl --with-curl=/usr/local/curl --with-zlib=/usr/local/zlib \
--enable-wddx \
--with-snmp=shared --with-gmp \
--disable-debug --disable-fileinfo

#--enable-fpm --with-fpm-user=www --with-fpm-group=www \
#--without-libzip
#--enable-gd-native-ttf configure: #WARNING: unrecognized options: --enable-gd-native-ttf
#--with-libdir=lib64               #��װ��ϵͳ��64λ�ģ���64λ���û����ļ�Ĭ������/usr/lib64��ָ��--with-libdir=lib64��������ű�Ĭ����lib
#--with-mcrypt                     #The Mcrypt library has been declared DEPRECATED since PHP 7.1, to use in its OpenSSL
#--with-ldap --with-ldap-sasl 
#configure: error: off_t undefined; check your library configuration #echo '/usr/local/lib64 /usr/local/lib /usr/lib /usr/lib64'>>/etc/ld.so.conf&&ldconfig -v
#--disable-opcache       Disable Zend OPcache support
#--enable-maintainer-zts Enable thread safety - for code maintainers only!!
#--disable-json          Disable JavaScript Object Serialization support

make -j ${THREAD} && make install

mkdir -p /usr/local/php/etc/php.d   #Scan this dir for additional .ini files
#����û���Ȩ��apache
id -u apache >/dev/null 2>&1
    [ $? -ne 0 ] && useradd -M -s /sbin/nologin apache
chown apache.apache -R /usr/local/php;

if [ ! -e '/usr/local/php/bin/php' ]; then
echo -e "\033[31m Install PHP${php73_ver} Error ... \033[0m \n"
kill -9 $$
fi

#apache���php������
chown apache.apache -R /usr/local/php
cp ~/php-${php73_ver}/php.ini-production  /usr/local/php/etc/php.ini;

################
#php.ini�Ż�
#memory_limit��������PHP��ռ�õ��ڴ��
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
sed -i 's@^max_execution_time.*@max_execution_time = 60@' /usr/local/php/etc/php.ini
sed -i 's@^disable_functions.*@disable_functions = passthru,exec,system,chroot,chgrp,chown,shell_exec,proc_open,proc_get_status,ini_alter,ini_restore,dl,openlog,syslog,readlink,symlink,popepassthru,stream_socket_server,fsocket,popen,eval,parse_ini_file,show_source,pclose,multi_exec,chmod,set_time_limit@' /usr/local/php/etc/php.ini
sed -i "s@^;curl.cainfo.*@curl.cainfo = /usr/local/openssl/cert.pem@" /usr/local/php/etc/php.ini
sed -i "s@^;openssl.cafile.*@openssl.cafile = /usr/local/openssl/cert.pem@" /usr/local/php/etc/php.ini
  [ -e /usr/sbin/sendmail ] && sed -i 's@^;sendmail_path.*@sendmail_path = /usr/sbin/sendmail -t -i@' /usr/local/php/etc/php.ini
sed -i "s@^;openssl.capath.*@openssl.capath = "/usr/local/openssl/cert.pem"@" /usr/local/php/etc/php.ini
sed -i 's@^;realpath_cache_size.*@realpath_cache_size = 2M@' /usr/local/php/etc/php.ini
################
#̽��
wget -t 3 -O /home/wwwroot/default/proble.tar.gz http://file.asuhu.com/so/proble.tar.gz
cd /home/wwwroot/default && tar -zxvf proble.tar.gz && rm -rf proble.tar.gz

#/usr/local/php/lib/php/extensions/no-debug-zts-20180731/
################
#PHP_opcache
cat > /usr/local/php/etc/php.d/opcache.ini << EOF
[opcache]
zend_extension=opcache.so
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=${Memory_limit}
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=100000
opcache.max_wasted_percentage=5
opcache.use_cwd=1
opcache.validate_timestamps=1
opcache.revalidate_freq=60
opcache.save_comments=0
opcache.fast_shutdown=1
opcache.consistency_checks=0
;opcache.optimization_level=0
EOF
################
#######################################
cd ~
#ioncube_loader��װ
if [ -e /usr/local/php/lib/php/extensions/no-debug-zts-20180731 ];then
#http://www.ioncube.com/loaders.php https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz  http://downloads3.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz
php_extensions_path=/usr/local/php/lib/php/extensions/no-debug-zts-20180731
ioncube_loader_path=ioncube_loader_lin_7.3_ts.so
#
wget -t 3 -O ${php_extensions_path}/${ioncube_loader_path} http://file.asuhu.com/so/ioncube/${ioncube_loader_path}
    if [ ! -e "${php_extensions_path}/${ioncube_loader_path}" ];then
wget -O "${php_extensions_path}/${ioncube_loader_path}" http://arv.asuhu.com/ftp/so/ioncube/${ioncube_loader_path}
    fi
chmod +x ${php_extensions_path}/${ioncube_loader_path}
cat > /usr/local/php/etc/php.d/ioncube.ini << EOF
[ioncube]
zend_extension=${ioncube_loader_path}
EOF
	elif [ -e /usr/local/php/lib/php/extensions/no-debug-non-zts-20180731 ]; then
php_extensions_path=/usr/local/php/lib/php/extensions/no-debug-non-zts-20180731
ioncube_loader_path=ioncube_loader_lin_7.3.so
#
wget -t 3 -O ${php_extensions_path}/${ioncube_loader_path} http://file.asuhu.com/so/ioncube/${ioncube_loader_path}
    if [ ! -e "${php_extensions_path}/${ioncube_loader_path}" ];then
wget -O "${php_extensions_path}/${ioncube_loader_path}" http://arv.asuhu.com/ftp/so/ioncube/${ioncube_loader_path}
    fi
chmod +x ${php_extensions_path}/${ioncube_loader_path}
cat > /usr/local/php/etc/php.d/ioncube.ini << EOF
[ioncube]
zend_extension=${ioncube_loader_path}
EOF
fi
#######################################
#Zend Guard �� Zend �ٷ���Ʒ��һ�� PHP Դ����ܲ�Ʒ�������������Ч�ط�ֹ����δ����ɵ�ʹ�ú����򹤳̡�
#Zend Guard Loader �������ʹ�� Zend Guard ���ܺ�� PHP ��������л��������������û�а�װ Zend Guard Loader�����޷����о� Zend Guard ���ܺ�� PHP ���롣
#ZendGuardLoader ֧�� PHP5.5 �� PHP5.6  δ֧��PHP7
#ZendGuardLoader ��֧��NTS�汾��PHP 

#Ϊ�˱����ͻ��snmpʹ�õ�����ģ��/usr/bin/ld: warning: libssl.so.10, needed by /usr/lib/gcc/x86_64-redhat-linux.8.5/../../../../lib64/libnetsnmp.so, may conflict with libssl.so.1.0.0
cat > /usr/local/php/etc/php.d/snmp.ini << EOF
[snmp]
extension = snmp.so
EOF

#��װphpredis
#source ~/sh/function.sh
#install_phpredis7

#CentOS7
#libtool: warning: remember to run 'libtool --finish /root/php-5.6.31/libs'
#/usr/bin/libtool --version   libtool (GNU libtool) 2.4.2 Copyright (C) 2011 Free Software Foundation, Inc.
#/root/php-7.3.13/libtool --version ltmain.sh (GNU libtool) 1.5.26 (1.1220.2.492 2008/01/30 06:40:56)

cd ~
if ! which libtool;then yum -y install libtool;fi
libtool --finish /usr/local/php/lib
echo 'export PATH=/usr/local/php/bin:$PATH'>>/etc/profile && source /etc/profile
/usr/local/php/bin/php --version
rm -rf php-${php73_ver}
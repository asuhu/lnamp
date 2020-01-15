#!/bin/bash
#Apache_APACHE2HANDLER
#used epel-release
#PHP 5.6.40 is the last scheduled release of PHP 5.6 branch  matching OpenSSL1.0.2
THREAD=$(cat /proc/cpuinfo | grep 'model name'| wc -l)
Mem=$( free -m | awk '/Mem/ {print $2}' )
Bit=$(getconf LONG_BIT)
phpstable56=5.6.40


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


#yum安装
yum -y install wget gcc make vim screen epel-release
if ! which yum-config-manager;then sudo yum -y install yum-utils;fi
sudo yum-config-manager --enable epel
yum -y install libxml2 libxml2-devel curl-devel libjpeg-devel libpng-devel freetype-devel  bzip2 bzip2-devel net-snmp-devel gmp-devel zlib-devel bison gd-devel 
yum -y install python python-devel        #checking consistency of all components of python development environment... no
yum -y install CUnit CUnit-devel          #configure: WARNING: No package 'cunit' found

#yum -y install jansson-devel             #configure: No package 'jansson' found 和nghttp2冲突
#yum -y openldap-devel
#/usr/bin/ld: warning: libssl.so.10, needed by /usr/lib/gcc/x86_64-redhat-linux/4.8.5/../../../../lib64/libldap.so, may conflict with libssl.so.1.0.0
#/usr/bin/ld: warning: libcrypto.so.10, needed by /usr/lib/gcc/x86_64-redhat-linux/4.8.5/../../../../lib64/libldap.so, may conflict with libcrypto.so.1.0.0

if [ ! -e '/usr/bin/wget' ];then yum -y install wget;fi

yum -y install bison bison-devel libevent libevent-devel libxslt-devel libidn-devel libcurl-devel readline-devel re2c
#Source installation bison libmcrypt openssl和curl(含zlib)
source ~/sh/function.sh
install_56_bison
install_phpmcrypt
install_phpopenssl
install_curl


cd ~
wget -4 -q --no-check-certificate https://www.php.net/distributions/php-${phpstable56}.tar.gz   #http://jp2.php.net/distributions/php-${phpstable56}.tar.gz
tar -zxf php-${phpstable56}.tar.gz && rm -rf php-${phpstable56}.tar.gz 
cd php-${phpstable56}
CFLAGS= CXXFLAGS= ./configure --prefix=/usr/local/php \
--with-apxs2=/usr/local/apache/bin/apxs \
--with-config-file-path=/usr/local/php/etc --with-config-file-scan-dir=/usr/local/php/etc/php.d \
--with-mysql=mysqlnd --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd --enable-opcache \
--with-iconv-dir=/usr/local  --with-freetype-dir --with-jpeg-dir --with-png-dir \
--with-libxml-dir=/usr --enable-xml --disable-rpath \
--with-snmp=shared --with-bz2 \
--with-gd --with-mcrypt \
--with-openssl=/usr/local/openssl --with-curl=/usr/local/curl --with-zlib=/usr/local/zlib \
--with-mhash --with-xmlrpc --without-pear --with-gettext \
--enable-json --enable-bcmath --enable-calendar --enable-wddx \
--enable-shmop --enable-sysvsem --enable-inline-optimization \
--enable-mbregex --enable-mbstring \
--enable-ftp --enable-gd-native-ttf --enable-pcntl --enable-sockets --enable-zip --enable-soap --enable-exif \
--disable-ipv6 --disable-debug --disable-fileinfo

make -j ${THREAD} && make install

mkdir -p /usr/local/php/etc/php.d   #Scan this dir for additional .ini files
#添加用户和权限apache
id -u apache >/dev/null 2>&1
    [ $? -ne 0 ] && useradd -M -s /sbin/nologin apache
chown apache.apache -R /usr/local/php;

#检测php是否安装成功
if [ ! -e '/usr/local/php/bin/phpize' ]; then
echo -e "\033[31m Install php error ... \033[0m \n"
kill -9 $$
fi

#apache结合php的配置
chown apache.apache -R /usr/local/php
cd ~/php-${phpstable56}/php.ini-production  /usr/local/php/etc/php.ini;

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
sed -i 's@^max_execution_time.*@max_execution_time = 60@' /usr/local/php/etc/php.ini
sed -i 's@^disable_functions.*@disable_functions = passthru,exec,system,chroot,chgrp,chown,shell_exec,proc_open,proc_get_status,ini_alter,ini_restore,dl,openlog,syslog,readlink,symlink,popepassthru,stream_socket_server,fsocket,popen,eval,parse_ini_file,show_source,pclose,multi_exec,chmod,set_time_limit@' /usr/local/php/etc/php.ini
sed -i "s@^;curl.cainfo.*@curl.cainfo = /usr/local/openssl/cert.pem@" /usr/local/php/etc/php.ini
sed -i "s@^;openssl.cafile.*@openssl.cafile = /usr/local/openssl/cert.pem@" /usr/local/php/etc/php.ini

#探针
wget -t 3 -O /home/wwwroot/default/proble.tar.gz http://file.asuhu.com/so/proble.tar.gz
cd /home/wwwroot/default && tar -zxvf proble.tar.gz && rm -rf proble.tar.gz

#php扩展 opcache.ini可能造成内存泄露 zend_mm_heap corrupted #https://github.com/lj2007331/lnmp/blob/master/include/php-5.6.sh
cat > /usr/local/php/etc/php.d/opcache.ini << EOF
[opcache]
zend_extension=opcache.so
opcache.enable=1
opcache.memory_consumption=${Memory_limit}
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=4000
opcache.revalidate_freq=60
opcache.save_comments=0
opcache.fast_shutdown=1
opcache.enable_cli=1
;opcache.optimization_level=0
EOF

#apache 2.4.27 prefork不支持http2,worker evnet需要线程安全

########################################
cd ~
#ioncube_loader安装
#http://www.ioncube.com/loaders.php
#https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz  http://downloads3.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz
if [ -e /usr/local/php/lib/php/extensions/no-debug-non-zts-20131226 ];then
cd ~ 
wget -t 3 -O /usr/local/php/lib/php/extensions/no-debug-non-zts-20131226/ioncube_loader_lin_5.6.so http://file.asuhu.com/so/ioncube/ioncube_loader_lin_5.6.so
    if [ ! -e '/usr/local/php/lib/php/extensions/no-debug-non-zts-20131226/ioncube_loader_lin_5.6.so' ];then
wget -O /usr/local/php/lib/php/extensions/no-debug-non-zts-20131226/ioncube_loader_lin_5.6.so http://arv.asuhu.com/ftp/so/ioncube/ioncube_loader_lin_5.6.so
    fi
chmod +x /usr/local/php/lib/php/extensions/no-debug-non-zts-20131226/ioncube_loader_lin_5.6.so
cat > /usr/local/php/etc/php.d/ioncube.ini << EOF
[ioncube]
zend_extension=ioncube_loader_lin_5.6.so
EOF

elif [ -e /usr/local/php/lib/php/extensions/no-debug-zts-20131226 ]; then
cd ~ 
wget -t 3 -O /usr/local/php/lib/php/extensions/no-debug-zts-20131226/ioncube_loader_lin_5.6_ts.so  http://file.asuhu.com/so/ioncube/ioncube_loader_lin_5.6_ts.so
    if [ ! -e '/usr/local/php/lib/php/extensions/no-debug-zts-20131226/ioncube_loader_lin_5.6_ts.so' ];then
wget -O /usr/local/php/lib/php/extensions/no-debug-zts-20131226/ioncube_loader_lin_5.6_ts.so  http://arv.asuhu.com/ftp/so/ioncube/ioncube_loader_lin_5.6_ts.so
    fi
chmod +x /usr/local/php/lib/php/extensions/no-debug-zts-20131226/ioncube_loader_lin_5.6_ts.so
cat > /usr/local/php/etc/php.d/ioncube.ini << EOF
[ioncube]
zend_extension=ioncube_loader_lin_5.6_ts.so
EOF
fi
########################################

###########################################################
#安装ZendGuardLoader.so #Zend Guard 是 Zend 官方出品的一款 PHP 源码加密产品解决方案，能有效地防止程序未经许可的使用和逆向工程。
#ZendGuardLoader 支持 PHP5.5 和 PHP5.6  并未支持PHP7 http://www.zend.com/en/products/loader/downloads#Linux
#ZendGuardLoader安装  wget http://downloads.zend.com/guard/7.0.0/zend-loader-php5.6-linux-x86_64.tar.gz
#Zend Guard Loader 则是针对使用 Zend Guard 加密后的 PHP 代码的运行环境。如果环境中没有安装 Zend Guard Loader，则无法运行经 Zend Guard 加密后的 PHP 代码。仅支持NTS版本的PHP
if [ -e /usr/local/php/lib/php/extensions/no-debug-non-zts-20131226 ];then
cd ~ 
wget -t 3 -O /usr/local/php/lib/php/extensions/no-debug-non-zts-20131226/ZendGuardLoader.so http://file.asuhu.com/so/zend/ZendGuardLoader.so
    if [ ! -e "/usr/local/php/lib/php/extensions/no-debug-non-zts-20131226/ZendGuardLoader.so" ];then
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
elif [ -e /usr/local/php/lib/php/extensions/no-debug-zts-20131226 ]; then
echo "Will not install ZendGuardLoader.so"
#/usr/local/php/lib/php/extensions/no-debug-zts-20131226/ZendGuardLoader.so: undefined symbol: executor_globals
fi
###########################################################

#为了避免冲突，snmp用单独的模块，/usr/bin/ld: warning: libssl.so.10, needed by /usr/lib/gcc/x86_64-redhat-linux.8.5/../../../../lib64/libnetsnmp.so, may conflict with libssl.so.1.0.0
cat > /usr/local/php/etc/php.d/snmp.ini << EOF
[snmp]
extension = snmp.so
EOF

#安装phpredis
#source ~/sh/function.sh
#install_phpredis

#libtool: install: install .libs/libphp5.so /usr/local/apache/modules/libphp5.so  install: warning: remember to run `libtool --finish /root/php-5.6.30/libs
#libtool: warning: remember to run 'libtool --finish /root/php-5.6.31/libs'
#/usr/bin/libtool --version    ltmain.sh (GNU libtool) 2.2.6b
#/root/php/libtool --version   ltmain.sh (GNU libtool) 1.5.26 (1.1220.2.492 2008/01/30 06:40:56)
#/usr/local/apache/build/libtool --version    libtool (GNU libtool) 2.4.6

cd ~
if ! which libtool;then yum -y install libtool;fi
libtool --finish /usr/local/php/lib
/etc/init.d/httpd restart
/usr/local/php/bin/php --version
rm -rf php-${phpstable56}
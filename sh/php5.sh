#!/bin/bash
#used epel-release
#https://www.php.net/supported-versions.php
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

#Download PHP5
cd ~
wget -4 -q --no-check-certificate https://www.php.net/distributions/php-${phpstable56}.tar.gz   #http://jp2.php.net/distributions/php-${phpstable56}.tar.gz
tar -zxf php-${phpstable56}.tar.gz && rm -rf php-${phpstable56}.tar.gz
cd php-${phpstable56}
CFLAGS= CXXFLAGS= ./configure --prefix=/usr/local/php --with-config-file-path=/usr/local/php/etc \
--with-config-file-scan-dir=/usr/local/php/etc/php.d \
--enable-fpm --with-fpm-user=www --with-fpm-group=www \
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
--disable-ipv6 --disable-debug --disable-fileinfo -with-gmp --disable-maintainer-zts
#--with-ldap \
#--with-ldap-sasl \

make -j ${THREAD} && make install

mkdir -p /usr/local/php/etc/php.d   #Scan this dir for additional .ini files
#添加用户和权限www.www
    id -u www >/dev/null 2>&1
    [ $? -ne 0 ] && useradd -M -s /sbin/nologin www
chown www.www -R /usr/local/php;

#检测php是否安装成功
if [ ! -e '/usr/local/php/bin/phpize' ]; then
echo -e "\033[31m Install PHP Error ... \033[0m \n"
kill -9 $$
fi

cp /usr/local/php/etc/php-fpm.conf.default /usr/local/php/etc/php-fpm.conf;          #修改fpm配置php-fpm.conf.default文件名称
cp /root/php-${phpstable56}/php.ini-production /usr/local/php/etc/php.ini;           #复制php.ini配置文件
cp /root/php-${phpstable56}/sapi/fpm/init.d.php-fpm /etc/init.d/php-fpm;             #复制php-fpm启动脚本到init.d
chmod +x /etc/init.d/php-fpm;                                                        #赋予执行权限
chkconfig --add php-fpm;chkconfig php-fpm on;

#php-fpm.conf
cat > /usr/local/php/etc/php-fpm.conf <<EOF
;;;;;;;;;;;;;;;;;;;;;
; FPM Configuration ;
;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;
; Global Options ;
;;;;;;;;;;;;;;;;;;

[global]
pid = run/php-fpm.pid
error_log = log/php-fpm.log
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
listen.owner = www
listen.group = www
listen.mode = 0666
user = www
group = www

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
;env[HOSTNAME] = $HOSTNAME
env[PATH] = /usr/local/bin:/usr/bin:/bin
env[TMP] = /tmp
env[TMPDIR] = /tmp
env[TEMP] = /tmp
EOF


#memory_limit顾名思义，这个值是用来限制PHP所占用的内存的，具体一点说就是一个PHP工作进程即php-fpm所能够使用的最大内存，默认是128MB，
#php.ini优化
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

#Nginx PHP fastcgi
mkdir -p /home/{wwwroot,/wwwlogs};mkdir -p /home/wwwroot/web;mkdir -p /home/wwwroot/web/ftp;chown -R www.www /home/wwwroot;
wget -t 3 -O  /usr/local/nginx/conf/nginx.conf  http://file.asuhu.com/so/nginx.conf
    if [ ! -e '/usr/local/nginx/conf/nginx.conf' ];then
wget -O /usr/local/nginx/conf/nginx.conf http://arv.asuhu.com/ftp/so/nginx.conf
    fi

#探针
wget -t 3 -O /home/wwwroot/web/proble.tar.gz  http://file.asuhu.com/so/proble.tar.gz
cd /home/wwwroot/web/ && tar -zxvf proble.tar.gz && rm -rf proble.tar.gz

#PHPopcache扩展，线程安全不适合这个模块/usr/local/php/lib/php/extensions/no-debug-zts-20131226/ZendGuardLoader.so: undefined symbol: executor_globals
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

#############################
cd ~
#ioncube_loader安装 http://www.ioncube.com/loaders.php #https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz  http://downloads3.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz
php_extensions_path=/usr/local/php/lib/php/extensions/no-debug-non-zts-20131226

wget -t 3 -O ${php_extensions_path}/ioncube_loader_lin_5.6.so http://file.asuhu.com/so/ioncube/ioncube_loader_lin_5.6.so
    if [ ! -e "${php_extensions_path}/ioncube_loader_lin_5.6.so" ];then
wget -O ${php_extensions_path}/ioncube_loader_lin_5.6.so http://arv.asuhu.com/ftp/so/ioncube/ioncube_loader_lin_5.6.so
    fi
chmod +x ${php_extensions_path}/ioncube_loader_lin_5.6.so
cat > /usr/local/php/etc/php.d/ioncube.ini << EOF
[ioncube]
zend_extension=ioncube_loader_lin_5.6.so
EOF
#############################

###########################################################
cd ~
#ZendGuardLoader 支持 PHP5.5 和 PHP5.6  并未支持PHP7 http://www.zend.com/en/products/loader/downloads#Linux
#ZendGuardLoader安装  wget http://downloads.zend.com/guard/7.0.0/zend-loader-php5.6-linux-x86_64.tar.gz
#Zend Guard 是 Zend 官方出品的一款 PHP 源码加密产品解决方案，能有效地防止程序未经许可的使用和逆向工程。
#Zend Guard Loader 则是针对使用 Zend Guard 加密后的 PHP 代码的运行环境。如果环境中没有安装 Zend Guard Loader，则无法运行经 Zend Guard 加密后的 PHP 代码。仅支持NTS版本的PHP
wget -t 3 -O ${php_extensions_path}/ZendGuardLoader.so  http://file.asuhu.com/so/zend/ZendGuardLoader.so
    if [ ! -e "${php_extensions_path}/ZendGuardLoader.so" ];then
wget -O "${php_extensions_path}/ZendGuardLoader.so"  http://arv.asuhu.com/ftp/so/zend/ZendGuardLoader.so
    fi
chmod +x ${php_extensions_path}/ZendGuardLoader.so
cat > /usr/local/php/etc/php.d/zend.ini << EOF
[Zend Guard]
zend_extension = ZendGuardLoader.so
zend_loader.enable = 1
zend_loader.disable_licensing = 0
zend_loader.obfuscation_level_support = 3
zend_loader.license_path =
EOF
###########################################################

#为了避免冲突，snmp用单独的模块/usr/bin/ld: warning: libssl.so.10, needed by /usr/lib/gcc/x86_64-redhat-linux.8.5/../../../../lib64/libnetsnmp.so, may conflict with libssl.so.1.0.0
cat > /usr/local/php/etc/php.d/snmp.ini << EOF
[snmp]
extension = snmp.so
EOF

#安装phpredis
#source ~/sh/function.sh
#install_phpredis

#disable-maintainer-zts
#libtool: warning: remember to run 'libtool --finish /root/php-5.6.31/libs'
#/usr/bin/libtool --version    ltmain.sh (GNU libtool) 2.2.6b
#/root/php/libtool --version   ltmain.sh (GNU libtool) 1.5.26 (1.1220.2.492 2008/01/30 06:40:56)

cd ~
if ! which libtool;then yum -y install libtool;fi
libtool --finish /usr/local/php/lib
/etc/init.d/php-fpm restart
#path
echo 'export PATH=/usr/local/php/bin:$PATH'>>/etc/profile
source /etc/profile
/usr/local/php/bin/php --version
rm -rf php-${phpstable56}
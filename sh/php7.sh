#!/bin/bash
#enable epel-release
#https://www.php.net/supported-versions.php
#PHP7.3 matching OpenSSL1.1.1 
#https://www.php.net/manual/en/zip.installation.php
#As of PHP 7.3.0, building against the bundled libzip is discouraged, but still possible by adding --without-libzip to the configuration.
if [ ! -e '/usr/bin/wget' ];then yum -y install wget;fi
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
sudo yum -y rsync screen net-tools dnf unzip vim htop iftop htop tcping tcpdump sysstat bash-completion perl
if ! which yum-config-manager;then sudo yum -y install yum-utils;fi
sudo yum-config-manager --enable epel
sudo yum -y install libxml2 libxml2-devel libjpeg-devel libpng-devel freetype-devel bzip2 bzip2-devel net-snmp-devel gmp-devel zlib-devel bison gd-devel 
sudo yum -y install python python-devel        #checking consistency of all components of python development environment... no
sudo yum -y install CUnit CUnit-devel          #configure: WARNING: No package 'cunit' found
sudo yum -y install libicu-devel
sudo yum -y install sqlite-devel oniguruma-devel libsodium-devel

#yum -y install jansson-devel                    #configure: No package 'jansson' found 和nghttp2冲突
#yum -y install openldap-devel
#/usr/bin/ld: warning: libssl.so.10, needed by /usr/lib/gcc/x86_64-redhat-linux/4.8.5/../../../../lib64/libldap.so, may conflict with libssl.so.1.0.0
#/usr/bin/ld: warning: libcrypto.so.10, needed by /usr/lib/gcc/x86_64-redhat-linux/4.8.5/../../../../lib64/libldap.so, may conflict with libcrypto.so.1.0.0

yum -y install bison bison-devel libevent libevent-devel libxslt-devel libidn-devel libcurl-devel readline-devel re2c
#Cancel installation libmcrypt
#Source installation openssl111和curl(含zlib)
source ~/sh/function.sh
install_phpopenssl111
install_curl

#Download PHP7
php74_ver=7.4.33
cd ~
wget -4 -q --no-check-certificate https://www.php.net/distributions/php-${php74_ver}.tar.gz   #http://jp2.php.net/distributions/php-${php74_ver}.tar.gz
tar -zxf php-${php74_ver}.tar.gz && rm -rf php-${php74_ver}.tar.gz

#PHP7.3 New features
cd ~
argon2_ver=argon2-20171227
if [ ! -e "/usr/lib/libargon2.a" ]; then
wget -4 -q --no-check-certificate https://www.zhangfangzhou.cn/third/so/${argon2_ver}.tar.gz
tar -zxf ${argon2_ver}.tar.gz && rm -rf ${argon2_ver}.tar.gz
cd ~/${argon2_ver}
make -j ${THREAD} && make install
fi

cd ~
libsodium_ver=libsodium-1.0.18
if [ ! -e "/usr/local/lib/libsodium.la" ]; then
wget -4 -q --no-check-certificate https://www.zhangfangzhou.cn/third/so/${libsodium_ver}.tar.gz
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
wget --no-check-certificate https://www.zhangfangzhou.cn/third/libzip-1.2.0.tar.gz
tar -zxf libzip-1.2.0.tar.gz && rm -rf libzip-1.2.0.tar.gz 
cd libzip-1.2.0
./configure
make && make install
cd ~
rm -rf ~/libzip-1.2.0
cp /usr/local/lib/libzip/include/zipconf.h /usr/local/include/zipconf.h
#libzip

#ld.so.conf.d
[ -z "`grep /usr/local/lib /etc/ld.so.conf.d/*.conf`" ] && echo '/usr/local/lib' > /etc/ld.so.conf.d/local.conf
ldconfig -v

cd ~/php-${php74_ver}
CFLAGS= CXXFLAGS= ./configure --prefix=/usr/local/php \
--with-config-file-path=/usr/local/php/etc \
--with-config-file-scan-dir=/usr/local/php/etc/php.d \
--enable-fpm --with-fpm-user=www --with-fpm-group=www \
--enable-opcache \
--enable-mysqlnd --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd \
--with-iconv-dir=/usr/local \
--enable-xml --disable-rpath --enable-bcmath --enable-shmop --enable-exif \
--enable-sysvsem --enable-inline-optimization --enable-mbregex \
--enable-fileinfo --enable-gd --enable-zip \
--enable-mbstring --with-password-argon2 --with-sodium=/usr/local \
--with-mhash --enable-pcntl --enable-sockets --with-xmlrpc --enable-ftp  --enable-intl --with-xsl \
--with-gettext --enable-soap \
--with-openssl=/usr/local/openssl --with-curl=/usr/local/curl --with-zlib=/usr/local/zlib \
--with-snmp=shared --with-gmp \
--disable-debug

#--without-libzip
#--enable-gd-native-ttf configure: #WARNING: unrecognized options: --enable-gd-native-ttf
#--with-libdir=lib64               #安装的系统是64位的，而64位的用户库文件默认是在/usr/lib64，指定--with-libdir=lib64，而编译脚本默认是lib
#--with-mcrypt                     #The Mcrypt library has been declared DEPRECATED since PHP 7.1, to use in its OpenSSL
#--with-ldap --with-ldap-sasl 
#configure: error: off_t undefined; check your library configuration #echo '/usr/local/lib64 /usr/local/lib /usr/lib /usr/lib64'>>/etc/ld.so.conf&&ldconfig -v
#--disable-opcache       Disable Zend OPcache support
#--enable-maintainer-zts Enable thread safety - for code maintainers only!!
#--disable-json          Disable JavaScript Object Serialization support

make -j ${THREAD} && make install

mkdir -p /usr/local/php/etc/php.d   #Scan this dir for additional .ini files
#添加用户和权限www.www
    id -u www >/dev/null 2>&1
    [ $? -ne 0 ] && useradd -M -s /sbin/nologin www
chown www.www -R /usr/local/php;

if [ ! -e '/usr/local/php/bin/php' ]; then
echo -e "\033[31m Install PHP${php74_ver} Error ... \033[0m \n"
kill -9 $$
fi
#修改fpm配置php-fpm.conf.default文件名称
cp /usr/local/php/etc/php-fpm.conf.default /usr/local/php/etc/php-fpm.conf
#复制php.ini配置文件
cp /root/php-${php74_ver}/php.ini-production /usr/local/php/etc/php.ini
#复制php-fpm启动脚本到init.d，也可以使用/root/php-${php74_ver}/sapi/fpm/php-fpm.service脚本
cp /root/php-${php74_ver}/sapi/fpm/init.d.php-fpm /etc/init.d/php-fpm
#赋予执行权限
chmod +x /etc/init.d/php-fpm
chkconfig --add php-fpm;chkconfig php-fpm on

cd ~
#php-fpm配置
cat > /usr/local/php/etc/php-fpm.conf <<"EOF"
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
listen = /dev/shm/php-cgi.sock
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
#######################################
#php.ini优化
#memory_limit用来限制PHP所占用的内存的
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
sed -i "s@^;openssl.cafile.*@openssl.cafile = /usr/local/openssl/cert.pem@" /usr/local/php/etc/php.ini
  [ -e /usr/sbin/sendmail ] && sed -i 's@^;sendmail_path.*@sendmail_path = /usr/sbin/sendmail -t -i@' /usr/local/php/etc/php.ini
sed -i "s@^;openssl.capath.*@openssl.capath = "/usr/local/openssl/cert.pem"@" /usr/local/php/etc/php.ini
sed -i 's@^;realpath_cache_size.*@realpath_cache_size = 2M@' /usr/local/php/etc/php.ini
################
#set error log
sed -i 's/;error_log = php_errors.log/error_log = php_errors.log/g' /usr/local/php/etc/php.ini
sed -i 's/;opcache.error_log=/opcache.error_log= opcache.error.log/g' /usr/local/php/etc/php.ini
################
#Nginx PHP fastcgi
mkdir -p /home/{wwwroot,/wwwlogs};mkdir -p /home/wwwroot/web;mkdir -p /home/wwwroot/web/ftp;chown -R www.www /home/wwwroot;
wget  --no-check-certificate -t 3 -O  /usr/local/nginx/conf/nginx.conf  https://www.zhangfangzhou.cn/third/nginx.conf
	if [ ! -e '/usr/local/nginx/conf/nginx.conf' ];then
		cp ~/sh/conf/nginx.conf /usr/local/nginx/conf/nginx.conf
	fi

#探针
wget  --no-check-certificate -t 3 -O /home/wwwroot/web/proble.tar.gz  https://www.zhangfangzhou.cn/third/proble.tar.gz
	if [ ! -e '/home/wwwroot/web/proble.tar.gz' ];then
		cp ~/sh/conf/proble.tar.gz /home/wwwroot/web/proble.tar.gz
	fi
cd /home/wwwroot/web/ && tar -zxvf proble.tar.gz && rm -rf proble.tar.gz
#######################################
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
#######################################
cd ~
#ioncube_loader安装，如果您的PHP应用程序使用了ionCube编码器进行了加密保护，那么您需要安装ionCube Loader才能够正常运行这些加密的PHP代码
if [ -e /usr/local/php/lib/php/extensions/no-debug-zts-20190902 ];then
#download http://www.ioncube.com/loaders.php https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz 
php_extensions_path=/usr/local/php/lib/php/extensions/no-debug-zts-20190902
ioncube_loader_path=ioncube_loader_lin_7.4_ts.so
#
wget  --no-check-certificate -t 3 -O ${php_extensions_path}/${ioncube_loader_path} https://www.zhangfangzhou.cn/third/so/ioncube/${ioncube_loader_path}
    if [ ! -e "${php_extensions_path}/${ioncube_loader_path}" ];then
wget -O "${php_extensions_path}/${ioncube_loader_path}" http://arv.asuhu.com/ftp/so/ioncube/${ioncube_loader_path}
    fi
chmod +x ${php_extensions_path}/${ioncube_loader_path}
cat > /usr/local/php/etc/php.d/ioncube.ini << EOF
[ioncube]
zend_extension=${ioncube_loader_path}
EOF
	elif [ -e /usr/local/php/lib/php/extensions/no-debug-non-zts-20190902 ]; then
php_extensions_path=/usr/local/php/lib/php/extensions/no-debug-non-zts-20190902
ioncube_loader_path=ioncube_loader_lin_7.4.so
#
wget --no-check-certificate -t 3 -O ${php_extensions_path}/${ioncube_loader_path} https://www.zhangfangzhou.cn/third/so/ioncube/${ioncube_loader_path}
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
#Zend Guard 是 Zend 官方出品的一款 PHP 源码加密产品解决方案，能有效地防止程序未经许可的使用和逆向工程。
#Zend Guard Loader 则是针对使用 Zend Guard 加密后的 PHP 代码的运行环境。仅支持NTS版本的PHP，目前不支持PHP7。
#######################################
#/usr/bin/ld: warning: libssl.so.10, needed by /usr/lib/gcc/x86_64-redhat-linux.8.5/../../../../lib64/libnetsnmp.so, may conflict with libssl.so.1.0.0
#为了避免冲突，snmp使用单独的模块--with-snmp=shared
cat > /usr/local/php/etc/php.d/snmp.ini << EOF
[snmp]
extension = snmp.so
EOF

#install phpredis
#source ~/sh/function.sh
#install_phpredis7

#CentOS7 libtool
#libtool: warning: remember to run 'libtool --finish /root/php-7.4.32/libs'
#/usr/bin/libtool --version   libtool (GNU libtool) 2.4.2 Copyright (C) 2011 Free Software Foundation, Inc.
#/root/php-${php74_ver}/libtool --version ltmain.sh (GNU libtool) 1.5.26 (1.1220.2.492 2008/01/30 06:40:56)

#Clear
cd ~
if ! which libtool;then yum -y install libtool;fi
libtool --finish /usr/local/php/lib
/etc/rc.d/init.d/php-fpm restart
echo 'export PATH=/usr/local/php/bin:$PATH'>>/etc/profile && source /etc/profile
/usr/local/php/bin/php --version
rm -rf php-${php74_ver}
#!/bin/bash
#enable epel-release
#https://www.php.net/supported-versions.php
#PHP7.3 matching OpenSSL1.1.1 
#https://www.php.net/manual/en/zip.installation.php
#As of PHP 7.3.0, building against the bundled libzip is discouraged, but still possible by adding --without-libzip to the configuration.

# Get system information
THREAD=$(grep 'model name' /proc/cpuinfo | wc -l)
Mem=$(free -m | awk '/Mem/ {print $2}')
Bit=$(getconf LONG_BIT)

# Check CentOS version
if ! grep -q ' 7\.' /etc/redhat-release; then
    echo "Requires CentOS 7"
    exit 1
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

# Check if wget is installed and install if not
if ! command -v wget > /dev/null; then
    sudo yum -y install wget
fi

# Install required packages
sudo yum -y install gcc make vim screen epel-release

# Check if yum-config-manager is available and install yum-utils if not
if ! command -v yum-config-manager > /dev/null; then
    sudo yum -y install yum-utils
fi

# Enable the EPEL repository
sudo yum-config-manager --enable epel

# Install additional packages
sudo yum -y install rsync screen net-tools dnf unzip vim htop iftop htop tcping tcpdump sysstat bash-completion perl

# Install required development packages
sudo yum -y install gcc autoconf gcc-c++ libxml2 libxml2-devel openssl openssl-devel bzip2 bzip2-devel libcurl libcurl-devel \
libjpeg libjpeg-devel libpng libpng-devel freetype freetype-devel gmp gmp-devel readline readline-devel libxslt libxslt-devel \
systemd-devel openjpeg-devel oniguruma oniguruma-devel sqlite-devel python python-devel CUnit CUnit-devel libicu-devel \
net-snmp-devel bison bison-devel libevent libevent-devel libxslt-devel libidn-devel libcurl-devel readline-devel re2c

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
# Function to download and install argon2 library
install_argon2() {
argon2_ver=argon2-20190702
    if [ ! -f "/usr/lib/libargon2.a" ]; then
        sudo yum install -y libargon2 libargon2-devel
        wget -4 -q --no-check-certificate https://www.zhangfangzhou.cn/third/so/${argon2_ver}.tar.gz
        tar -zxf ${argon2_ver}.tar.gz && rm -rf ${argon2_ver}.tar.gz
        cd ~/${argon2_ver}
        make -j ${THREAD} && sudo make install
        [ ! -d /usr/local/lib/pkgconfig ] && sudo mkdir -p /usr/local/lib/pkgconfig
        sudo cp libargon2.pc /usr/local/lib/pkgconfig/
    fi
}
# Install argon2 library
cd ~
install_argon2

# Check argon2 installation
if [ ! -f "/usr/lib/x86_64-linux-gnu/libargon2.a" ]; then
    echo "install argon2 error"
    exit 1
else
    sudo rm -rf ~/${argon2_ver}
fi

# Function to download and install libsodium library
install_libsodium() {
libsodium_ver=libsodium-1.0.18
if [ ! -e "/usr/local/lib/libsodium.la" ]; then
wget -4 -q --no-check-certificate https://www.zhangfangzhou.cn/third/so/${libsodium_ver}.tar.gz
tar -zxf ${libsodium_ver}.tar.gz && rm -rf ${libsodium_ver}.tar.gz
cd ~/${libsodium_ver}
./configure --disable-dependency-tracking --enable-minimal
make -j ${THREAD} && make install
fi
}


# Install libsodium library
cd ~
install_libsodium

# Check libsodium installation
if [ ! -f "/usr/local/lib/libsodium.la" ]; then
    echo "install libsodium error"
    exit 1
else
    sudo rm -rf ~/${libsodium_ver}
fi

#libzip https://blog.csdn.net/zhangatle/article/details/90169494
#!/bin/bash

install_libzip() {
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
}

install_libzip

#ld.so.conf.d
[ -z "`grep /usr/local/lib /etc/ld.so.conf.d/*.conf`" ] && echo '/usr/local/lib' > /etc/ld.so.conf.d/local.conf
ldconfig -v

cd ~/php-${php74_ver}
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig/:$PKG_CONFIG_PATH
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
#--with-libdir=lib64               #安装的系统是64位的，而64位的用户库文件默认是在/usr/lib64，指定--with-libdir=lib64，而编译脚本默认是lib
#--with-mcrypt                     #The Mcrypt library has been declared DEPRECATED since PHP 7.1, to use in its OpenSSL
#--with-ldap --with-ldap-sasl 
#configure: error: off_t undefined; check your library configuration #echo '/usr/local/lib64 /usr/local/lib /usr/lib /usr/lib64'>>/etc/ld.so.conf&&ldconfig -v
#--disable-opcache       Disable Zend OPcache support
#--enable-maintainer-zts Enable thread safety - for code maintainers only!!
#--disable-json          Disable JavaScript Object Serialization support

make -j ${THREAD} && make install

mkdir -p /usr/local/php/etc/php.d   #Scan this dir for additional .ini files
#添加用户和权限apache
id -u apache >/dev/null 2>&1
    [ $? -ne 0 ] && useradd -M -s /sbin/nologin apache
chown apache.apache -R /usr/local/php;

if [ ! -e '/usr/local/php/bin/php' ]; then
echo -e "\033[31m Install PHP${php73_ver} Error ... \033[0m \n"
kill -9 $$
fi

#apache结合php的配置
chown apache.apache -R /usr/local/php
cp ~/php-${php73_ver}/php.ini-production  /usr/local/php/etc/php.ini;

################
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
#探针
wget  --no-check-certificate -t 3 -O /home/wwwroot/web/proble.tar.gz  https://www.zhangfangzhou.cn/third/proble.tar.gz
	if [ ! -e '/home/wwwroot/web/proble.tar.gz' ];then
		cp ~/sh/conf/proble.tar.gz /home/wwwroot/web/proble.tar.gz
	fi
cd /home/wwwroot/web/ && tar -zxvf proble.tar.gz && rm -rf proble.tar.gz
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
echo 'export PATH=/usr/local/php/bin:$PATH'>>/etc/profile && source /etc/profile
/usr/local/php/bin/php --version
rm -rf php-${php74_ver}
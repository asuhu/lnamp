#!/bin/bash
yum -y install gcc gcc-c++ make vim screen python wget git zlib zlib-devel
THREAD=$(cat /proc/cpuinfo | grep 'model name'| wc -l)

###############################################################################
install_56_bison() {
yum -y install bison bison-devel
if ! which gcc;then yum -y install gcc;fi
#PHP5.6.40 (need) . WARNING: This bison version is not supported for regeneration of the Zend/PHP parsers (found: 3.0, min: 204, excluded: 3.0).
#bisonversion=`bison --version | head -n 1|awk '{print $NF}'|awk -F "." '{print $1}'`
#if [ ${bisonversion} -eq 2 ];then
cd ~
wget http://ftp.gnu.org/gnu/bison/bison-3.5.2.tar.gz
tar -zxf bison-3.5.2.tar.gz && rm -rf bison-3.5.2.tar.gz
cd bison-3.5.2
 ./configure
make -j ${THREAD} && make install
cd ~
rm -rf bison-3.5.2
}
###############################################################################

install_re2c(){
wget -4  --no-check-certificate https://github.com/skvadrik/re2c/releases/download/1.1.1/re2c-1.1.1.tar.gz
}

############install_nghttp2####################################
install_nghttp2(){
#yum -y install jansson-devel
#configure: No package 'jansson' found 和nghttp2冲突     #nghttp2  https://github.com/nghttp2/nghttp2/releases

if [ ! -d /usr/local/nghttp2  ];then
nghttp2version=nghttp2-1.40.0
cd ~
  if wget -4 http://file.asuhu.com/so/${nghttp2version}.tar.gz
  then
  echo "download nghttp2 success"
  else
  wget -4 http://arv.asuhu.com/ftp/so/${nghttp2version}.tar.gz
  fi
tar -zxf $nghttp2version.tar.gz;rm -rf $nghttp2version.tar.gz;
cd $nghttp2version
./configure --prefix=/usr/local/nghttp2
make -j ${THREAD} && make install

if [ ! -e '/usr/local/nghttp2/include/nghttp2/nghttp2.h' ]; then
  echo -e "\033[31m Install nghttp2 error ... \033[0m \n"
  kill -9 $$
fi


echo "/usr/local/nghttp2/lib" > /etc/ld.so.conf.d/nghttp2.conf
ldconfig
else
  echo 'Already installed nghttp2'
fi

cd ~
rm -rf ${nghttp2version}
}
############install_nghttp2####################################
############install_curl#######################################
install_curl(){
yum -y install autoconf            #如果不安装，这一步会错误/usr/local/php/bin/phpize
autoconfversion=`autoconf --version | head -n 1 | awk '{print $4}'|grep -Po [0-9]  | tail -n 1`
if [ $autoconfversion -eq 3 ]; then
cd /tmp/
wget -4 http://ftp.gnu.org/gnu/autoconf/autoconf-2.69.tar.gz
tar -zxvf autoconf-2.69.tar.gz
cd /tmp/autoconf-2.69
./configure
make -j ${THREAD} && make install
fi


cd ~
sudo yum -y install epel-release
sudo yum -y install yum-utils
sudo yum-config-manager --enable epel
sudo yum -y install gcc gcc-c++ make vim screen python wget git zlib zlib-devel
sudo yum -y install libpsl libpsl-devel libidn2 libidn2-devel               #centos安装epel可以安装

#若要支持https需安装libssh2:(Centos) yum install libssh2-devel
#若要支持PSL 验证 Cookie 和证书的 Domain 信息，则安装libpsl:(Centos) yum psl libpsl-devel wget https://github.com/rockdaboot/libpsl/releases/download/libpsl-0.10.0/libpsl-0.10.0.tar.gz
#若要支持HTTP2 ,则安装nghttp2:(Centos) yum install libnghttp2-devel nghttp2 
#若要支持IDN,则安装libidn:(Centos) yum install libidn2 libidn2-devel

#########取消安装
#yum -y install libssh2-devel#取消安装，不然会冲突
#wget https://www.libssh2.org/download/libssh2-1.8.0.tar.gz
#tar -zxf libssh2-1.8.0.tar.gz
#cd libssh2-1.8.0
#CFLAGS="-I/usr/local/openssl/include" ./configure --prefix=/usr/local/libssh2
#unset CFLAGS
#unset LDFLAGS
#/usr/bin/ld: warning: libssl.so.10, needed by /usr/local/libssh2/lib/libssh2.so.1, may conflict with libssl.so.1.0.0
#/usr/bin/ld: warning: libcrypto.so.10, needed by /usr/local/libssh2/lib/libssh2.so.1, may conflict with libcrypto.so.1.0.0
#ldconfig: Can't stat /libx32: No such file or directory
#上面三行是取消原因
#########取消安装

if [ ! -d /usr/local/nghttp2 ];then
install_nghttp2
else
echo "Already installed nghttp2"
fi


if [ ! -d /usr/local/zlib ];then
cd ~
wget -4 http://zlib.net/zlib-1.2.11.tar.gz
tar -zxvf zlib-1.2.11.tar.gz && rm -rf zlib-1.2.11.tar.gz
cd zlib-1.2.11
./configure  --prefix=/usr/local/zlib
make -j ${THREAD} && make install
echo "/usr/local/zlib/lib" > /etc/ld.so.conf.d/zlib.conf
ldconfig -v
rm -rf ~/zlib-1.2.11
else
echo "Already installed zlib"
fi


if [ ! -d /usr/local/openssl ];then
install_phpopenssl
else
echo "Already installed openssl"
fi


cd ~
curlversion=curl-7.67.0
wget --no-check-certificate -4 -q https://curl.haxx.se/download/$curlversion.tar.gz
tar -zxf ${curlversion}.tar.gz && rm -rf ${curlversion}.tar.gz
cd ${curlversion}
#./configure --prefix=/usr/local --enable-ldap --enable-ldaps --with-nghttp2 --with-libssh2   CFLAGS="-I/usr/local/include/openssl" LDFLAGS="-L/usr/local/lib" --with-ssl-headers=/usr/local/include/openssl --with-ssl-lib=/usr/local/lib/ 故意出问题查看OpenSSL library version
CFLAGS= CXXFLAGS= ./configure --prefix=/usr/local/curl --with-ssl=/usr/local/openssl --with-nghttp2=/usr/local/nghttp2 \
--with-zlib=/usr/local/zlib --enable-verbose --enable-optimize --enable-ipv6 --disable-ldap 2>&1 >~/curl.log
make -j ${THREAD} 2>&1 >>~/curl.log
make install 2>&1 >>~/curl.log
/usr/local/curl/bin/curl --version 2>&1 >>~/curl.log

if [ ! -e '/usr/local/curl/bin/curl' ]; then
  echo -e "\033[31m Install curl error ... \033[0m \n"
     kill -9 $$
fi

#echo "/usr/local/curl/lib">>/etc/ld.so.conf.d/curl.conf
#ldconfig -v
#CentOS 7 yum -y install cmake  /usr/lib64/python2.7/site-packages/pycurl.so: undefined symbol: CRYPTO_num_locks  会出现这个错误，需要取消#echo "/usr/local/curl/lib">>/etc/ld.so.conf.d/curl.conf
cd ~
rm -rf ${curlversion}
}
############install_curl#######################################
############install_phpopenssl#######################
install_phpopenssl(){
#https://wiki.openssl.org/index.php/Compilation_and_Installation
#make[2]: warning: jobserver unavailable: using -j1.  Add `+' to parent make rule.
#no-shared：指示生成静态库    shared 生成动态库文件，需要配合echo "/usr/local/openssl/lib" > /etc/ld.so.conf.d/openssl.conf
#/usr/bin/ld: /usr/local/openssl/lib/libssl.a(s3_clnt.o): relocation R_X86_64_32 against `.rodata' can not be used when making a shared object; recompile with -fPIC

cd ~
yum -y install gcc gcc-c++ make vim screen python wget git zlib zlib-devel
  if [ ! -e '/usr/local/openssl/bin/openssl' ]; then
wget -4 --no-check-certificate  https://www.openssl.org/source/openssl-1.0.2-latest.tar.gz
tar -zxf openssl-1.0.2-latest.tar.gz && rm -rf openssl-1.0.2-latest.tar.gz && mv openssl-1.0.2? openssl-1.0.2-latest
cd ~/openssl-1.0.2-latest
make clean
./config --prefix=/usr/local/openssl --openssldir=/usr/local/openssl shared zlib-dynamic 2>&1 >~/phpopenssl-1.0.2-latest.log
make 2>&1 >>~/phpopenssl-1.0.2-latest.log
make install 2>&1 >>~/phpopenssl-1.0.2-latest.log
/usr/local/openssl/bin/openssl version -a >>~/phpopenssl-1.0.2-latest.log

    if [ -f "/usr/local/openssl/lib/libcrypto.a" ]; then
      echo "openssl-1.0.2 installed successfully"
mv /usr/bin/openssl /usr/bin/openssl`date "+%Y%m%d%H%M%S"`
\cp -f /usr/local/openssl/bin/openssl /usr/bin/openssl
    else
      echo "openssl-1.0.2 install failed"
      kill -9 $$
    fi

echo "/usr/local/openssl/lib" > /etc/ld.so.conf.d/openssl.conf
ldconfig -v
else
echo "/usr/local/openssl/lib" > /etc/ld.so.conf.d/openssl.conf
ldconfig -v
  fi

cd ~
rm -rf openssl-1.0.2-latest
wget -4 -O /usr/local/openssl/cert.pem http://curl.haxx.se/ca/cacert.pem
#升级curl就会出现这个问题 OpenSSL Error messages: error:14090086:SSL routines:ssl3_get_server_certificate:certificate verify
}

#####################################################
############install_phpopenssl111##################
install_phpopenssl111(){
#no-shared：指示生成静态库    shared 生成动态库文件，需要配合echo "/usr/local/openssl/lib" > /etc/ld.so.conf.d/openssl.conf
#/usr/bin/ld: /usr/local/openssl/lib/libssl.a(s3_clnt.o): relocation R_X86_64_32 against `.rodata' can not be used when making a shared object; recompile with -fPIC
cd ~
yum -y install gcc gcc-c++ make vim screen python wget git zlib zlib-devel
  if [ ! -e '/usr/local/openssl/bin/openssl' ]; then
wget -4 --no-check-certificate  https://www.openssl.org/source/openssl-1.1.1-latest.tar.gz
tar -zxf openssl-1.1.1-latest.tar.gz && rm -rf openssl-1.1.1-latest.tar.gz && mv openssl-1.1.1? openssl-1.1.1-latest
cd ~/openssl-1.1.1-latest
./config --prefix=/usr/local/openssl --openssldir=/usr/local/openssl shared zlib-dynamic 2>&1 >~/phpopenssl-1.1.1-latest.log
make -j ${THREAD} 2>&1 >>~/phpopenssl-1.1.1-latest.log
make install 2>&1 >>~/phpopenssl-1.1.1-latest.log
/usr/local/openssl/bin/openssl version -a >>~/phpopenssl-1.1.1-latest.log

    if [ -f "/usr/local/openssl/lib/libcrypto.a" ]; then
      echo "openssl-1.1.1 installed successfully"
mv /usr/bin/openssl /usr/bin/openssl`date "+%Y%m%d%H%M%S"`
\cp -f /usr/local/openssl/bin/openssl /usr/bin/openssl
    else
      echo "openssl-1.1.1 install failed"
      kill -9 $$
    fi

echo "/usr/local/openssl/lib" > /etc/ld.so.conf.d/openssl.conf
ldconfig -v
else
echo "/usr/local/openssl/lib" > /etc/ld.so.conf.d/openssl.conf
ldconfig -v
  fi

cd ~
rm -rf openssl-1.1.1-latest
wget -4 -O /usr/local/openssl/cert.pem http://curl.haxx.se/ca/cacert.pem
#升级curl就会出现这个问题 OpenSSL Error messages: error:14090086:SSL routines:ssl3_get_server_certificate:certificate verify
}
############install_phpopenssl#######################

#PHP5
install_phpmcrypt(){
sudo yum -y install epel-release
if ! which yum-config-manager;then sudo yum -y install yum-utils;fi
sudo yum-config-manager --enable epel
yum -y install mhash mhash-devel libmcrypt libmcrypt-devel mcrypt
#wget http://file.asuhu.com/ex/libmcrypt-2.5.8.tar.gz
#wget http://file.asuhu.com/ex/mhash-0.9.9.9.tar.gz
#wget http://file.asuhu.com/ex/mcrypt-2.6.8.tar.gz
}

####################################################################
install_phpredis5() {
#phpredis模块http://pecl.php.net/package/redis   #PHP extension for interfacing with Redis
#Redis 4.3.0 This is probably the latest release with PHP 5 suport!!!
phpredisvs=phpredis-4.3.0
cd ~

if wget -4 http://file.asuhu.com/so/${phpredisvs}.tar.gz
then
echo "download phpredis success"
else
wget -4 http://arv.asuhu.com/ftp/so/${phpredisvs}.tar.gz
fi

tar -zxvf ${phpredisvs}.tar.gz && rm -rf ${phpredisvs}.tar.gz
cd ${phpredisvs}
/usr/local/php/bin/phpize
./configure --with-php-config=/usr/local/php/bin/php-config
make -j ${THREAD} && make install
cat > /usr/local/php/etc/php.d/redis.ini << EOF
[redis]
extension = redis.so
EOF

cd ~
rm -rf ${phpredisvs}
}
#
install_phpredis7() {
#http://pecl.php.net/package/redis
phpredisvs=phpredis-5.1.1
cd ~
if wget -4 http://file.asuhu.com/so/${phpredisvs}.tar.gz
then
echo "download phpredis success"
else
wget -4 http://arv.asuhu.com/ftp/so/${phpredisvs}.tar.gz
fi

tar -zxvf ${phpredisvs}.tar.gz && rm -rf ${phpredisvs}.tar.gz
cd ${phpredisvs}
/usr/local/php/bin/phpize
./configure --with-php-config=/usr/local/php/bin/php-config
make -j ${THREAD} && make install
cat > /usr/local/php/etc/php.d/redis.ini << EOF
[redis]
extension = redis.so
EOF

cd ~
rm -rf ${phpredisvs}
}
####################################################################

#http://pecl.php.net/package/swoole   #Event-driven asynchronous and concurrent networking engine with high performance for PHP.
install_swoole7() {
cd ~
wget -c http://pecl.php.net/get/swoole-4.2.1.tgz
tar -zxf swoole-4.2.1.tgz && rm -rf swoole-4.2.1.tgz
cd swoole-4.2.1
/usr/local/php/bin/phpize
./configure --with-php-config=/usr/local/php/bin/php-config
make -j ${THREAD} && make install
cat > /usr/local/php/etc/php.d/swoole.ini << EOF
[swoole]
extension=swoole.so
EOF
}

install_swoole5() {
cd ~
wget -c http://pecl.php.net/get/swoole-1.10.5.tgz
tar -zxf swoole-1.10.5.tgz && rm -rf swoole-1.10.5.tgz
cd swoole-1.10.5
/usr/local/php/bin/phpize
./configure --with-php-config=/usr/local/php/bin/php-config
make -j ${THREAD} && make install
cat > /usr/local/php/etc/php.d/swoole.ini << EOF
[swoole]
extension=swoole.so
EOF
}

install_xdebug5() {
cd ~
wget -4  --no-check-certificate https://xdebug.org/files/xdebug-2.5.5.tgz
tar -zxf xdebug-2.5.5.tgz && rm -rf xdebug-2.5.5.tgz
cd xdebug-2.5.5
/usr/local/php/bin/phpize
./configure --enable-xdebug --with-php-config=/usr/local/php/bin/php-config
make -j ${THREAD} && make install

cat > /usr/local/php/etc/php.d/xdebug.ini << EOF
[swoole]
zend_extension=xdebug.so
xdebug.trace_output_dir=/tmp/xdebug
xdebug.profiler_output_dir = /tmp/xdebug
xdebug.profiler_enable = On
xdebug.profiler_enable_trigger = 1
xdebug.idekey="PHPSTORM"
xdebug.remote_host=127.0.0.1
xdebug.remote_port=9001
xdebug.remote_enable=on
EOF

cd ~
rm -rf xdebug-2.5.5
}


install_xdebug7() {
cd ~
wget -4  --no-check-certificate https://xdebug.org/files/xdebug-2.6.1.tgz
tar -zxf xdebug-2.6.1.tgz && rm -rf xdebug-2.6.1.tgz
cd xdebug-2.6.1
/usr/local/php/bin/phpize
./configure --enable-xdebug --with-php-config=/usr/local/php/bin/php-config
make -j ${THREAD} && make install

cat > /usr/local/php/etc/php.d/xdebug.ini << EOF
[swoole]
zend_extension=xdebug.so
xdebug.trace_output_dir=/tmp/xdebug
xdebug.profiler_output_dir = /tmp/xdebug
xdebug.profiler_enable = On
xdebug.profiler_enable_trigger = 1
xdebug.idekey="PHPSTORM"
xdebug.remote_host=127.0.0.1
xdebug.remote_port=9001
xdebug.remote_enable=on
EOF

cd ~
rm -rf xdebug-2.6.1
}


install_pecl_mongodb() {
cd ~
wget -4 --no-check-certificate https://pecl.php.net/get/mongodb-1.5.3.tgz
tar -zxvf mongodb-1.5.3.tgz && rm -rf mongodb-1.5.3.tgz
cd mongodb-1.5.3
/usr/local/php/bin/phpize
 ./configure --with-php-config=/usr/local/php/bin/php-config
make -j ${THREAD} && make install

cat > /usr/local/php/etc/php.d/mongodb.ini << EOF
[mongodb]
extension=mongodb.so
EOF

cd ~
rm -rf mongodb-1.5.3
echo "PHP mongodb module installed successfully! "
}


install_fileinfo() {
  src_url=https://www.php.net/distributions/php-7.3.4.tar.gz
  src_url=https://www.php.net/distributions/php-5.6.40.tar.gz
    tar xzf php-7.3.4.tar.gz
cd php-7.3.4/ext/fileinfo
/usr/local/php/bin/phpize
./configure --with-php-config=/usr/local/php/bin/php-config
make -j ${THREAD} && make install

echo 'extension=fileinfo.so' > /usr/local/php/etc/php.d/fileinfo.ini
}


#https://pecl.php.net/package/PDO_IBM
#https://pecl.php.net/get/PDO_PGSQL-1.0.2.tgz configure: error: Cannot find libpq-fe.h. Please specify correct PostgreSQL installation path     ./configure --with-pgsql=${pgsql_install_dir} --with-php-config=${php_install_dir}/bin/php-config
#echo 'extension=pgsql.so'
#echo 'extension=pdo_pgsql.so'
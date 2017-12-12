#!/bin/bash
yum -y install gcc gcc-c++ make vim screen python wget git zlib zlib-devel
a=$(cat /proc/cpuinfo | grep 'model name'| wc -l)

cp_libtool(){
#libtool: install: warning: remember to run `libtool --finish /root/php-5.6.30/libs' ������libtool�汾��һ����ɵġ� ��apache Ŀ¼build�����libtool��������php���밲װ��Ŀ¼��
cp -f /usr/local/apache/build/libtool /root/php-5.6.31/libtool
}

install_add(){
#wget http://ftp.gnu.org/gnu/bison/bison-2.4.1.tar.gz
yum -y install bison bison-devel libevent libevent-devel libxslt-devel  libidn-devel libcurl-devel readline-devel
#libtool
}

install_re2c(){
cd ~
wget https://sourceforge.net/projects/re2c/files/0.16/re2c-0.16.tar.gz
tar zxf re2c-0.16.tar.gz && cd re2c-0.16
./configure
make -j$a && make install
cd ~
rm -rf re2c-0.16*
}

#��װnghttp2
install_nghttp2(){
if [ ! -d /usr/local/nghttp2  ];then
cd ~
wget http://file.asuhu.com/so/nghttp2-1.26.0.tar.gz   #wget https://github.com/nghttp2/nghttp2/releases/download/v1.26.0/nghttp2-1.26.0.tar.gz
#wget http://arv.asuhu.com/ftp/so/nghttp2-1.26.0.tar.gz
tar -zxvf nghttp2-1.26.0.tar.gz;rm -rf nghttp2-1.26.0.tar.gz
cd nghttp2-1.26.0
./configure --prefix=/usr/local/nghttp2
make && make install
echo "/usr/local/nghttp2/lib" > /etc/ld.so.conf.d/nghttp2.conf
ldconfig
else
echo 'install nghttp2 ok'
fi
}

#���ذ�װ���°��curl
install_curl(){
yum -y install autoconf
#�������װ����һ�������/usr/local/php/bin/phpize
autoconfversion=`autoconf --version | head -n 1 | awk '{print $4}'|grep -Po [0-9]  | tail -n 1`
if [ $autoconfversion -eq 3 ]; then
cd /tmp/
wget -4 http://ftp.gnu.org/gnu/autoconf/autoconf-2.69.tar.gz
tar -zxvf autoconf-2.69.tar.gz
cd /tmp/autoconf-2.69
./configure
make -j$a
make install
fi


cd ~
yum -y install epel-release
yum -y install yum-utils
sudo yum-config-manager --enable epel
yum -y install gcc gcc-c++ make vim screen python wget git zlib zlib-devel

#��Ҫ֧��https�谲װlibssh2:(Centos) yum install libssh2-devel
#��Ҫ֧��PSL ��֤ Cookie ��֤��� Domain ��Ϣ����װlibpsl:(Centos) yum psl libpsl-devel
#wget https://github.com/rockdaboot/libpsl/releases/download/libpsl-0.10.0/libpsl-0.10.0.tar.gz
#��Ҫ֧��HTTP2 ,��װnghttp2:(Centos) yum install libnghttp2-devel nghttp2 
#��Ҫ֧��IDN,��װlibidn:(Centos) yum install libidn2 libidn2-devel
yum -y install libpsl libpsl-devel
#No package libpsl available.
#No package libpsl-devel available.
#configure: WARNING: libpsl was not found

#yum -y install libssh2-devel
#ȡ����װ����Ȼ���ͻ

yum -y install yum install libidn2 libidn2-devel


if [ ! -d /usr/local/nghttp2 ];then
install_nghttp2
else
echo "ok"
fi

if [ ! -d /usr/local/zlib ];then
cd ~
wget http://zlib.net/zlib-1.2.11.tar.gz
tar -zxvf zlib-1.2.11.tar.gz && rm -rf zlib-1.2.11.tar.gz
cd zlib-1.2.11
./configure  --prefix=/usr/local/zlib
make -j$a
make install
echo "/usr/local/zlib/lib" > /etc/ld.so.conf.d/zlib.conf
ldconfig
else
echo "install zlib ok"
fi



cd ~
curlversion=curl-7.57.0
wget -4  https://curl.haxx.se/download/$curlversion.tar.gz
tar -zxf $curlversion.tar.gz
rm -rf $curlversion.tar.gz
mv $curlversion curl
cd curl
#./configure --prefix=/usr/local --enable-ldap --enable-ldaps --with-nghttp2 --with-libssh2   CFLAGS="-I/usr/local/include/openssl" LDFLAGS="-L/usr/local/lib" --with-ssl-headers=/usr/local/include/openssl --with-ssl-lib=/usr/local/lib/ ���������鿴OpenSSL library version
CFLAGS= CXXFLAGS= ./configure  --prefix=/usr/local/curl --with-ssl=/usr/local/openssl --with-nghttp2=/usr/local/nghttp2 --with-zlib=/usr/local/zlib --enable-verbose --enable-ipv6 2>&1 >~/curl.log
make -j $a 2>&1 >>~/curl.log
make install 2>&1 >>~/curl.log
/usr/local/curl/bin/curl --version 2>&1 >>~/curl.log

if [ ! -e '/usr/local/curl/bin/curl' ]; then
echo -e "\033[31m Install curl error ... \033[0m \n"
exit 1
fi

echo "/usr/local/curl/lib">>/etc/ld.so.conf.d/curl.conf
ldconfig -v
}
install_phpopenssl(){
#��װopenssl1.0.2
cd ~
yum -y install gcc gcc-c++ make vim screen python wget git zlib zlib-devel
  if [ ! -e '/usr/local/openssl/bin/openssl' ]; then
wget -4 --no-check-certificate  https://www.openssl.org/source/openssl-1.0.2-latest.tar.gz
tar -zxf openssl-1.0.2-latest.tar.gz
rm -rf openssl-1.0.2-latest.tar.gz
mv openssl-1.0.2? openssl-1.0.2-latest
#�����nginx���ظ���Ŀǰphp������nginxʹ�õ�openssl.1.1
cd ~/openssl-1.0.2-latest
./config  --prefix=/usr/local/openssl shared zlib-dynamic enable-camellia 2>&1 >~/phpopenssl-1.0.2-latest.log
make 2>&1 >>~/phpopenssl-1.0.2-latest.log

#��֧��make[2]: warning: jobserver unavailable: using -j1.  Add `+' to parent make rule.

make install 2>&1 >>~/phpopenssl-1.0.2-latest.log
/usr/local/openssl/bin/openssl version >>~/phpopenssl-1.0.2-latest.log

if [ ! -e '/usr/local/openssl/bin/openssl' ]; then
echo -e "\033[31m Install openssl error ... \033[0m \n"
exit 1
fi

echo "/usr/local/openssl/lib" > /etc/ld.so.conf.d/openssl.conf
ldconfig -v
else
echo "/usr/local/openssl/lib" > /etc/ld.so.conf.d/openssl.conf
ldconfig -v
  fi
}

install_phpmcrypt(){
yum -y install epel-release
yum -y install yum-utils
sudo yum-config-manager --enable epel
yum -y install mhash mhash-devel libmcrypt libmcrypt-devel mcrypt

#wget http://file.asuhu.com/ex/libmcrypt-2.5.8.tar.gz
#wget http://file.asuhu.com/ex/mhash-0.9.9.9.tar.gz
#./configure --prefix=/usr/local
#yum -y install libtool
#wget http://file.asuhu.com/ex/mcrypt-2.6.8.tar.gz
#echo '/usr/local/lib' > /etc/ld.so.conf.d/local.conf
}


install_certificate(){
#ֻҪ����curl�ͻ����������� OpenSSL Error messages: error:14090086:SSL routines:ssl3_get_server_certificate:certificate verify 
wget -O /usr/local/openssl/ssl/cert.pem http://curl.haxx.se/ca/cacert.pem
}


install_phpredis() {
#phpredisģ��
cd ~
wget http://file.asuhu.com/so/phpredis-3.1.4.tar.gz   #wget http://arv.asuhu.com/ftp/so/phpredis-3.1.4.tar.gz
tar -zxvf phpredis-3.1.4.tar.gz;rm -rf phpredis-3.1.4.tar.gz
cd phpredis-3.1.4
/usr/local/php/bin/phpize
./configure --with-php-config=/usr/local/php/bin/php-config
make
make install
cat > /usr/local/php/etc/php.d/redis.ini << EOF
[redis]
extension = redis.so
EOF
}

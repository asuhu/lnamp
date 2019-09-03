#!/bin/bash
a=$(cat /proc/cpuinfo | grep 'model name'| wc -l)
Bit=$(getconf LONG_BIT)
ngstable=1.16.1
zlibstable=1.2.11
pcrestable=8.42

yum -y remove httpd httpd* nginx
yum -y install gcc gcc-c++ make vim screen python git

cd ~
yum -y install zlib-devel gzip man 
wget -4 -q http://zlib.net/zlib-${zlibstable}.tar.gz;tar -zxf zlib-${zlibstable}.tar.gz
wget -4 -q --no-check-certificate https://ftp.pcre.org/pub/pcre/pcre-${pcrestable}.tar.gz;tar -zxf pcre-${pcrestable}.tar.gz
wget -4 -q --no-check-certificate https://www.openssl.org/source/openssl-1.1.1-latest.tar.gz;tar -zxf openssl-1.1.1-latest.tar.gz && mv openssl-1.1.1? openssl-1.1.1-latest
wget -4 -q http://nginx.org/download/nginx-${ngstable}.tar.gz;tar -zxf nginx-${ngstable}.tar.gz   

cp -f ~/nginx-${ngstable}/man/nginx.8 /usr/share/man/man8  #Copy NGINX manual page to /usr/share/man/man8:
gzip /usr/share/man/man8/nginx.8

yum -y install git
git clone https://github.com/google/ngx_brotli.git
cd ngx_brotli
git submodule update --init
cd ~/ngx_brotli/deps/brotli
make

git clone https://github.com/cuber/ngx_http_google_filter_module
git clone https://github.com/yaoweibin/ngx_http_substitutions_filter_module


cd ~/nginx-${ngstable}
./configure --prefix=/usr/local/nginx --user=www --group=www \
--build=CentOS \
--add-module=/root/ngx_http_google_filter_module \
--add-module=/root/ngx_http_substitutions_filter_module \
--modules-path=/usr/local/nginx/modules \
--with-openssl=/root/openssl-1.1.1-latest \
--with-pcre=/root/pcre-${pcrestable} \
--with-zlib=/root/zlib-${zlibstable} \
--with-http_stub_status_module \
--with-http_secure_link_module \
--with-threads \
--with-file-aio \
--with-http_v2_module \
--with-http_ssl_module \
--with-http_gzip_static_module \
--with-http_gunzip_module \
--with-http_realip_module \
--with-http_flv_module \
--with-http_mp4_module \
--with-http_sub_module \
--with-http_dav_module \
--with-stream \
--with-stream=dynamic \
--with-stream_ssl_module \
--with-stream_realip_module \
--with-stream_ssl_preread_module
#########################

cd ~/nginx-${ngstable}
./configure --prefix=/usr/local/nginx --user=www --group=www \
--build=CentOS \
--modules-path=/usr/local/nginx/modules \
--with-openssl=/root/openssl-1.1.1-latest \
--with-pcre=/root/pcre-${pcrestable} \
--with-zlib=/root/zlib-${zlibstable} \
--with-http_stub_status_module \
--with-http_secure_link_module \
--with-threads \
--with-file-aio \
--with-http_v2_module \
--with-http_ssl_module \
--with-http_gzip_static_module \
--with-http_gunzip_module \
--with-http_realip_module \
--with-http_flv_module \
--with-http_mp4_module \
--with-http_sub_module \
--with-http_dav_module \
--with-stream \
--with-stream=dynamic \
--with-stream_ssl_module \
--with-stream_realip_module \
--with-stream_ssl_preread_module
#########################

make -j ${a}


## brotli插件
accept-encoding:gzip, deflate, sdch, br br 是一个加密模块

编译libbrotli

$ cd ~/nginx
$ yum install libtool
$ git clone https://github.com/bagder/libbrotli.git
$ cd libbrotli
$ ./autogen.sh
$ ./configure
$ make
$ make install
下载 ngx_brotli

$ cd ~/nginx
$ git clone https://github.com/google/ngx_brotli.git
$ cd ngx_brotli
$ git submodule update --init
$ vim config
have=NGX_HTTP_GZIP . auto/have上面加一行

have=NGX_HTTP_HEADERS . auto/have


#平滑升级nginx
mv /usr/local/nginx/sbin/nginx /usr/local/nginx/sbin/nginx.old

#然后拷贝一份新编译的二进制文件：
cp  ~/nginx-${ngstable}/objs/nginx /usr/local/nginx/sbin/

#检测配置
/usr/local/nginx/sbin/nginx -t
kill -USR2 `cat /var/run/nginx.pid`
kill -HUP `cat /var/run/nginx.pid`
如果想要更改配置而不需停止并重新启动服务，则使用该命令。在对配置文件作必要的更改后，发出该命令以动态更新服务配置。
示例：
   重启Nginx：
   # kill -HUP `cat /app/nginx/nginx.pid`




if [ ! -e '/usr/local/nginx/sbin/nginx' ]; then
echo -e "\033[31m Install nginx error ... \033[0m \n"
kill -9 $$
fi

#检测web用户是否存在
    id -u www >/dev/null 2>&1
    [ $? -ne 0 ] && useradd -M -s /sbin/nologin www;
chown www.www -R /usr/local/nginx;



ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
ssl_ciphers TLS13-AES-256-GCM-SHA384:TLS13-CHACHA20-POLY1305-SHA256:TLS13-AES-128-GCM-SHA256:TLS13-AES-128-CCM-8-SHA256:TLS13-AES-128-CCM-SHA256:EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+ECDSA+AES128:EECDH+aRSA+AES128:RSA+AES128:EECDH+ECDSA+AES256:EECDH+aRSA+AES256:RSA+AES256:EECDH+ECDSA+3DES:EECDH+aRSA+3DES:RSA+3DES:!MD5;
#!/bin/bash
THREAD=$(cat /proc/cpuinfo | grep 'model name'| wc -l)
Bit=$(getconf LONG_BIT)
ngstable=1.20.2
zlibstable=1.2.11
pcrestable=8.45
Google_ip=216.58.200.4
Within_China=http://qnvideo.henan100.net/

yum -y remove httpd httpd* nginx
yum -y install gcc gcc-c++ make vim screen python git

cd ~
yum -y install zlib-devel
if ping -c 2 ${Google_ip} >/dev/null;then
wget -4 -q http://zlib.net/zlib-${zlibstable}.tar.gz
wget -4 -q --no-check-certificate http://qnvideo.henan100.net/pcre-${pcrestable}.tar.gz
wget -4 -q --no-check-certificate -O openssl-1.1.1-latest.tar.gz https://www.openssl.org/source/openssl-1.1.1l.tar.gz
wget -4 -q  http://nginx.org/download/nginx-${ngstable}.tar.gz
else
wget -4 -q ${Within_China}/zlib-${zlibstable}.tar.gz
wget -4 -q ${Within_China}/pcre-${pcrestable}.tar.gz
wget -4 -q ${Within_China}/openssl-1.1.1-latest.tar.gz
wget -4 -q ${Within_China}/nginx-${ngstable}.tar.gz
fi

#openssl
tar -zxf openssl-1.1.1-latest.tar.gz && mv openssl-1.1.1? openssl-1.1.1-latest

cd ~
tar -zxf zlib-${zlibstable}.tar.gz
cd zlib-${zlibstable}
./configure --prefix=/usr/local/zlib
make -j ${THREAD} && make install
echo "/usr/local/zlib/lib" > /etc/ld.so.conf.d/zlib.conf
ldconfig

#pcre PCRE库是一组函数，它们使用与Perl 5相同的语法和语义实现正则表达式模式匹配.(非必要编译安装)
cd ~
tar -zxf pcre-${pcrestable}.tar.gz
cd pcre-${pcrestable}
./configure --prefix=/usr/local/pcre --enable-utf8
make -j ${THREAD} && make install
~/pcre-${pcrestable}/libtool --finish  /usr/local/pcre/lib/
echo "/usr/local/pcre/lib/" > /etc/ld.so.conf.d/pcre.conf
ldconfig

#Install Nginx
cd ~
yum -y install gzip man
tar -zxf nginx-${ngstable}.tar.gz
#
#Custom nginx name
sed -i 's@^#define NGINX_VER          "nginx/" NGINX_VERSION@#define NGINX_VER          "Microsoft-IIS/10.0/" NGINX_VERSION@g'  ~/nginx-${ngstable}/src/core/nginx.h
sed -i 's@^#define NGINX_VAR          "NGINX"@#define NGINX_VAR          "Microsoft-IIS"@g'  ~/nginx-${ngstable}/src/core/nginx.h
#
#Nginx shows the file name length of a static directory file
sed -i 's/^#define NGX_HTTP_AUTOINDEX_PREALLOCATE  50/#define NGX_HTTP_AUTOINDEX_PREALLOCATE  150/'  ~/nginx-${ngstable}/src/http/modules/ngx_http_autoindex_module.c
sed -i 's/^#define NGX_HTTP_AUTOINDEX_NAME_LEN     50/#define NGX_HTTP_AUTOINDEX_NAME_LEN     150/'  ~/nginx-${ngstable}/src/http/modules/ngx_http_autoindex_module.c
#
cp -f ~/nginx-${ngstable}/man/nginx.8 /usr/share/man/man8  #Copy NGINX manual page to /usr/share/man/man8:
gzip /usr/share/man/man8/nginx.8

----------------------------------------------------------------------------------------------------
#DIY

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

--add-module=/root/sticky \
--add-module=/root/ngx_http_google_filter_module \
--add-module=/root/ngx_http_substitutions_filter_module \
--add-module=/root/ngx_http_substitutions_filter_module \
#########################
make -j ${THREAD}




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


wget -t 3 -O  /usr/local/nginx/conf/nginx.conf  http://file.asuhu.com/so/nginx.conf
    if [ ! -e '/usr/local/nginx/conf/nginx.conf' ];then
wget -O /usr/local/nginx/conf/nginx.conf http://arv.asuhu.com/ftp/so/nginx.conf
    fi



##################set systemctl nginx.service
cat > /usr/lib/systemd/system/nginx.service << EOF
[Unit]
Description=nginx - high performance web server
Documentation=http://nginx.org/en/docs/
After=network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/var/run/nginx.pid
ExecStartPost=/bin/sleep 0.1
ExecStartPre=/usr/local/nginx/sbin/nginx -t -c /usr/local/nginx/conf/nginx.conf
ExecStart=/usr/local/nginx/sbin/nginx -c /usr/local/nginx/conf/nginx.conf
ExecReload=/usr/local/nginx/sbin/nginx -s reload
ExecStop=/usr/local/nginx/sbin/nginx -s stop
PrivateTmp=true
LimitNOFILE=51200
LimitNPROC=51200
LimitCORE=51200

[Install]
WantedBy=multi-user.target
EOF

chmod +x /usr/lib/systemd/system/nginx.service
systemctl enable nginx.service
################
mkdir -p /home/{wwwroot,/wwwlogs};mkdir -p /home/wwwroot/web;mkdir -p /home/wwwroot/web/ftp;chown -R www.www /home/wwwroot;

################
#Nginx日志轮训，需要配合crontab和logrotate
#安装crond Cronie (sys-process/cronie) is a fork of vixie-cron done by Fedora. Because of it being a fork it has the same feature set the original vixie-cron provides
if ! which crond >/dev/null 2>&1;then yum install cronie -y; fi
################
yum -y install logrotate
cat > /etc/logrotate.d/nginx << EOF
/home/wwwlogs/*log {
daily
rotate 30
missingok
dateext
notifempty
sharedscripts
postrotate
    [ -e /var/run/nginx.pid ] && kill -USR1 \`cat /var/run/nginx.pid \`
endscript
}
EOF
################
#path
echo 'export PATH=/usr/local/nginx/sbin:$PATH'>>/etc/profile && source /etc/profile
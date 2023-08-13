#!/bin/bash
THREAD=$(cat /proc/cpuinfo | grep 'model name'| wc -l)
Bit=$(getconf LONG_BIT)
ngstable=1.24.0
zlibstable=1.2.13
pcrestable=8.45
Google_ip=216.58.200.4
Within_China=https://www.zhangfangzhou.cn/third/

if ping -c 10 file.asuhu.com >/dev/null;then
	echo "website configuration files check ok"
	else
	echo "website configuration files check error. Please contact 860116511@qq.com"
	kill -9 $$
fi

if [ ! -e '/usr/bin/wget' ]; then yum -y install wget; fi

#system version
if  [ -n "$(grep ' 7\.' /etc/redhat-release)" ] ;then
	CentOS_RHEL_version=7
	elif
	[ -n "$(grep ' 6\.' /etc/redhat-release)" ]; then
	CentOS_RHEL_version=6
fi

yum -y remove httpd httpd* nginx
yum -y install gcc gcc-c++ make vim screen python git
yum -y install rsync wget gcc screen net-tools dnf unzip vim htop iftop htop tcping tcpdump sysstat bash-completion perl
cd ~
yum -y install zlib-devel
if ping -c 2 ${Google_ip} >/dev/null;then
	wget -4 -q http://zlib.net/zlib-${zlibstable}.tar.gz
	wget -4 -q --no-check-certificate https://www.zhangfangzhou.cn/third/pcre-${pcrestable}.tar.gz
	wget -4 -q --no-check-certificate -O openssl-1.1.1-latest.tar.gz https://www.openssl.org/source/openssl-1.1.1t.tar.gz
	wget -4 -q --no-check-certificate http://nginx.org/download/nginx-${ngstable}.tar.gz
	else
	wget -4 -q --no-check-certificate ${Within_China}/zlib-${zlibstable}.tar.gz
	wget -4 -q --no-check-certificate ${Within_China}/pcre-${pcrestable}.tar.gz
	wget -4 -q --no-check-certificate -O openssl-1.1.1-latest.tar.gz ${Within_China}/openssl-1.1.1t.tar.gz
	wget -4 -q --no-check-certificate ${Within_China}/nginx-${ngstable}.tar.gz
fi

#openssl
tar -zxf openssl-1.1.1-latest.tar.gz && mv openssl-1.1.1? openssl-1.1.1-latest

yum -y install libtool  #wget http://ftpmirror.gnu.org/libtool/libtool-2.4.6.tar.gz
#Libtool是一种属于GNU建构系统的GNU程序设计工具，用来产生便携式的库

#zlib 是提供数据压缩之用的库 (非必要编译安装)
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
sed -i '30,40s@nginx@Microsoft-IIS@g'  ~/nginx-${ngstable}/src/http/ngx_http_special_response.c
sed -i '45,50s@nginx@Microsoft-IIS@g' ~/nginx-${ngstable}/src/http/ngx_http_header_filter_module.c
#
#Nginx shows the file name length of a static directory file
sed -i 's/^#define NGX_HTTP_AUTOINDEX_PREALLOCATE  50/#define NGX_HTTP_AUTOINDEX_PREALLOCATE  150/'  ~/nginx-${ngstable}/src/http/modules/ngx_http_autoindex_module.c
sed -i 's/^#define NGX_HTTP_AUTOINDEX_NAME_LEN     50/#define NGX_HTTP_AUTOINDEX_NAME_LEN     150/'  ~/nginx-${ngstable}/src/http/modules/ngx_http_autoindex_module.c
#
#Copy NGINX manual page to /usr/share/man/man8:
cp -f ~/nginx-${ngstable}/man/nginx.8 /usr/share/man/man8
gzip /usr/share/man/man8/nginx.8

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
make -j ${THREAD} && make install


#git clone https://github.com/cuber/ngx_http_google_filter_module
#git clone https://github.com/yaoweibin/ngx_http_substitutions_filter_module
#--add-module=/root/ngx_http_google_filter_module
#--add-module=/root/ngx_http_substitutions_filter_module
#--modules-path=PATH                set modules path
#--add-dynamic-module=PATH          enable dynamic external module
#stream采用动态模块加载
#--with-ipv6 废弃的参数
# + using PCRE library: /root/pcre
# + using OpenSSL library: /root/openssl
# + using zlib library: /root/zlib


if [ ! -e '/usr/local/nginx/sbin/nginx' ]; then
echo -e "\033[31m Install Nginx${ngstable} Error ... \033[0m \n"
kill -9 $$
fi

#检测web用户是否存在
    id -u www >/dev/null 2>&1
    [ $? -ne 0 ] && useradd -M -s /sbin/nologin www;
chown www.www -R /usr/local/nginx;

#开始判断CentOS版本
if [ ${CentOS_RHEL_version} -eq 6 ];then

cat > /etc/init.d/nginx << "EOF"
#!/bin/bash
#
# nginx - this script starts and stops the nginx daemon
#
# chkconfig:   - 85 15
# description:  Nginx is an HTTP(S) server, HTTP(S) reverse \
#               proxy and IMAP/POP3 proxy server
# processname: nginx
# config:      /usr/local/nginx/conf/nginx.conf
# pidfile:     /var/run/nginx.pid

# Source function library.
. /etc/rc.d/init.d/functions

# Source networking configuration.
. /etc/sysconfig/network

# Check that networking is up.
[ "$NETWORKING" = "no" ] && exit 0

nginx="/usr/local/nginx/sbin/nginx"
prog=$(basename $nginx)

NGINX_CONF_FILE="/usr/local/nginx/conf/nginx.conf"

[ -f /etc/sysconfig/nginx ] && . /etc/sysconfig/nginx

lockfile=/var/lock/subsys/nginx

make_dirs() {
   # make required directories
   user=`$nginx -V 2>&1 | grep "configure arguments:" | sed 's/[^*]*--user=\([^ ]*\).*/\1/g' -`
   if [ -z "`grep $user /etc/passwd`" ]; then
       useradd -M -s /bin/nologin $user
   fi
   options=`$nginx -V 2>&1 | grep 'configure arguments:'`
   for opt in $options; do
       if [ `echo $opt | grep '.*-temp-path'` ]; then
           value=`echo $opt | cut -d "=" -f 2`
           if [ ! -d "$value" ]; then
               # echo "creating" $value
               mkdir -p $value && chown -R $user $value
           fi
       fi
   done
}

start() {
    [ -x $nginx ] || exit 5
    [ -f $NGINX_CONF_FILE ] || exit 6
    make_dirs
    echo -n $"Starting $prog: "
    daemon $nginx -c $NGINX_CONF_FILE
    retval=$?
    echo
    [ $retval -eq 0 ] && touch $lockfile
    return $retval
}

stop() {
    echo -n $"Stopping $prog: "
    killproc $prog -QUIT
    retval=$?
    echo
    [ $retval -eq 0 ] && rm -f $lockfile
    return $retval
}

restart() {
    configtest || return $?
    stop
    sleep 3
    start
}

reload() {
    configtest || return $?
    echo -n $"Reloading $prog: "
    killproc $nginx -HUP
    RETVAL=$?
    echo
}

force_reload() {
    restart
}

configtest() {
  $nginx -t -c $NGINX_CONF_FILE
}

rh_status() {
    status $prog
}

rh_status_q() {
    rh_status >/dev/null 2>&1
}

case "$1" in
    start)
        rh_status_q && exit 0
        $1
        ;;
    stop)
        rh_status_q || exit 0
        $1
        ;;
    restart|configtest)
        $1
        ;;
    reload)
        rh_status_q || exit 7
        $1
        ;;
    force-reload)
        force_reload
        ;;
    status)
        rh_status
        ;;
    condrestart|try-restart)
        rh_status_q || exit 0
            ;;
    *)
        echo $"Usage: $0 {start|stop|status|restart|condrestart|try-restart|reload|force-reload|configtest}"
        exit 2
esac
EOF

#赋予权限
chmod +x /etc/init.d/nginx;

#开机启动
chkconfig --add nginx; chkconfig nginx on;

#防火墙设置
service iptables start;chkconfig iptables on;
iptables -I INPUT -p tcp -m multiport --dport 80,443,8080,8081,3306 -j ACCEPT;
service iptables save;service iptables restart;
###################
#CentOS7使用firewalld
  elif [ ${CentOS_RHEL_version} -eq 7 ];then
	if systemctl status firewalld;then
firewall-cmd --zone=public --add-port=80/tcp --add-port=8080/tcp --add-port=443/tcp --add-port=8443/tcp --permanent
firewall-cmd --zone=public --add-port=3306/tcp --add-port=3360/tcp --permanent
systemctl restart firewalld
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
fi
#CentOS 6 7 判断结束

#Nginx日志轮训，需要配合crontab和logrotate
#安装crond Cronie (sys-process/cronie) is a fork of vixie-cron done by Fedora. Because of it being a fork it has the same feature set the original vixie-cron provides
if ! which crond >/dev/null 2>&1;then yum install cronie -y; fi

yum -y install logrotate
if [ ${CentOS_RHEL_version} -eq 6 ];then
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
  elif [ ${CentOS_RHEL_version} -eq 7 ];then
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
  else
echo "logrotate nginx error";
fi

#清理nginx openssl pcre zlib
cd ~
rm -rf nginx-${ngstable}.tar.gz;rm -rf nginx-${ngstable};
rm -rf  openssl-1.1.1-latest.tar.gz;rm -rf openssl-1.1.1-latest;
rm -rf pcre-${pcrestable}.tar.gz;rm -rf pcre-${pcrestable};
rm -rf zlib-${zlibstable}.tar.gz;rm -rf zlib-${zlibstable}
#path
echo 'export PATH=/usr/local/nginx/sbin:$PATH'>>/etc/profile && source /etc/profile
#ldd $(which nginx)
/usr/local/nginx/sbin/nginx -V
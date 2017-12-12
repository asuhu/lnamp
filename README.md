<pre>
1、一键源码编译安装LNMP LAMP 支持CentOS6、CentOS7、RHEL6、RHEL7
2、nginx/1.12.2 built with OpenSSL 1.1.0g
3、Apache2.2为PreforkMPM，Apache2.4为Event MPM(编译Prefork、Worker和Event三种MPM可以自行切换)
4、Mysql5.6,Mysql5.7
5、Tomcat8
6、PHP集成了 Zend OPcache、Zend Guard Loader、ionCube Loader、 phpredis等扩展
7、Redis-Server
8、curl 7.57.0 (x86_64-pc-linux-gnu) libcurl/7.57.0 OpenSSL/1.0.2n zlib/1.2.11 libidn2/2.0.4 nghttp2/1.26.0
9、TLS SNI support enabled
10、Nginx 配置https和反向代理的例子
</pre>

<pre>
安装使用
cd /root
yum -y install wget screen curl python
screen -S lnamp
wget --no-check-certificate https://blog.asuhu.com/sh/lnamp.tar.gz
tar -zxvf lnamp.tar.gz
bash install.sh
</pre>

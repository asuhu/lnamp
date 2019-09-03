<ol>
<li>一键编译安装LNMP LAMP 支持CentOS6、CentOS7、RHEL6、RHEL7</li>
<li>启用Swap</li>
<li>修改SSH服务端口</li>
<li>Nginx/1.16.1 built with OpenSSL 1.1.1</li>
<li>iptables</li>
<li>Apache2.2为PreforkMPM,Apache2.4为Event MPM(编译Prefork、Worker和Event三种MPM可以自行切换)</li>
<li>PHP5.6.40</li>
<li>PHP7.2.22</li>
<li>Zend OPcache、Zend Guard Loader、ionCube Loader、 phpredis、swoole、xdebug、fileinfo</li>
<li>snmp(支持zabbix、cacti、Nagios)</li>
<li>MySQL-5.6</li>
<li>MySQL-5.7</li>
<li>MySQL-5.7_binary</li>
<li>phpMyAdmin</li>
<li>Redis-Server</li>
<li>Tomcat8 JDK1.8</li>
<li>curl 7.64.0 (x86_64-pc-linux-gnu) libcurl/7.64.0 OpenSSL/1.0.2s zlib/1.2.11 libidn2/2.2.0 libpsl/0.7.0 (+libicu/50.1.2) nghttp2/1.39.2</li>
<li>TLS SNI support enabled</li>
<li>多个Nginx HTTPS配置和反向代理配置</li>
</ol>

<h2>Supported System</h2>
<ol>
<li>CentOS-6.x</li>
<li>CentOS-7.x</li>
<li>RHEL-6.x</li>
<li>RHEL7-7.x</li>
<li>Oracle Linux -6.x</li>
<li>Oracle Linux -7.x</li>
</ol>

<pre>
安装使用
cd /root
yum -y install wget screen curl python
screen -S lnamp
wget --no-check-certificate https://blog.asuhu.com/sh/lnamp.tar.gz
tar -zxvf lnamp.tar.gz
bash install.sh
</pre>


Licensed under the GPLv3 License.

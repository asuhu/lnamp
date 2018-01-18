<ol>
<li>一键源码编译安装LNMP LAMP 支持CentOS6、CentOS7、RHEL6、RHEL7</li>
<li>Nginx/1.12.2 built with OpenSSL 1.1.0g</li>
<li>Apache2.2为PreforkMPM,Apache2.4为Event MPM(编译Prefork、Worker和Event三种MPM可以自行切换)</li>
<li>MySQL-5.6</li>
<li>MySQL-5.7</li>
<li>PHP集成了 Zend OPcache、Zend Guard Loader、ionCube Loader、 phpredis等模块</li>
<li>PHP集成snmp模块，支持zabbix、cacti、Nagios直接使用snmp协议</li>
<li>支持Redis-Server</li>
<li>Tomcat8 JDK1.8</li>
<li>curl 7.57.0 (x86_64-pc-linux-gnu) libcurl/7.57.0 OpenSSL/1.0.2n zlib/1.2.11 libidn2/2.0.4 nghttp2/1.26.0</li>
<li>TLS SNI support enabled</li>
<li>多个配置Nginx https和反向代理的例子</li>
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

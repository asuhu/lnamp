#### 一键编译安装LNMP LAMP 支持CentOS6、CentOS7、RHEL6、RHEL7

##### Nginx

<li>Nginx/1.22 built with OpenSSL 1.1.1</li>
<li>define NGINX_VAR for Microsoft-IIS/10.0</li>
<li>define NGX_HTTP_AUTOINDEX_PREALLOCATE  50 to 150</li>
<li>TLS SNI support enabled</li>
<li>多个Nginx HTTPS配置和反向代理配置</li>

##### Apache

<li>Apache2.2.34工作模式为PreforkMPM(The final release 2.2.34 was published in July 2017)</li>
<li>Apache2.4工作模式为Event MPM(编译全部Prefork、Worker和Event三种MPM可以自行切换)</li>	 

##### PHP

<li>PHP5.6.40(PHP 5.6.40 is the last scheduled release of PHP 5.6 branch)</li>
<li>PHP7.3</li>
<li>PHP7.4</li>
<li>PHP8.2</li>
<li>PHP扩展模块 Zend OPcache、Zend Guard Loader、ionCube Loader、 phpredis、swoole、xdebug、fileinfo、snmp(支持zabbix、cacti、Nagios)、imagick</li>
<li>phpMyAdmin</li>

##### Mysql

<li>MySQL-5.6</li>
<li>MySQL-5.7</li>
<li>Yum MySQL-5.7</li>
<li>MySQL-5.7_binary</li>

##### Others

<li>启用Swap</li>
<li>启用iptables</li>
<li>修改SSH服务端口</li>  	 
<li>Redis</li>
<li>Tomcat8 JDK1.8</li>
<li>curl 7.88.1 (x86_64-pc-linux-gnu) libcurl/7.88.1 OpenSSL/1.1.1t zlib/1.2.13 libidn2/2.3.4 libpsl/0.7.0 (+libicu/50.1.2) nghttp2/1.41.0</li>

#### Supported System

<li>CentOS-6.x</li>
<li>CentOS-7.x</li>
<li>RHEL-6.x</li>
<li>RHEL-7.x</li>
<li>Oracle Linux -6.x</li>
<li>Oracle Linux -7.x</li>

#### 安装使用

```shell
cd /root
yum -y install wget screen curl python
screen -S lnamp
wget --no-check-certificate https://raw.githubusercontent.com/asuhu/lnamp/master/lnamp.tar.gz
tar -zxvf lnamp.tar.gz
bash install.sh
```

![](https://raw.githubusercontent.com/asuhu/lnamp/master/lnmp.png)

Licensed under the GPLv3 License.
#!/bin/bash
a=$(cat /proc/cpuinfo | grep 'model name'| wc -l)
yum -y install gcc gcc-c++ make vim screen python wget git lsof
tram=$( free -m | awk '/Mem/ {print $2}' )
cd ~
wget http://download.redis.io/releases/redis-stable.tar.gz
tar zxf redis-stable.tar.gz
cd redis-stable
make -j ${a} && make install

if [ -f "/root/redis-stable/src/redis-server" ]; then
mkdir -p /usr/local/redis/{bin,etc,var}
/bin/cp /root/redis-stable/src/{redis-benchmark,redis-check-aof,redis-check-rdb,redis-cli,redis-sentinel,redis-server} /usr/local/redis/bin/
/bin/cp /root/redis-stable/redis.conf /usr/local/redis/etc/

cd /root/redis-stable/src
    id -u redis >/dev/null 2>&1
    [ $? -ne 0 ] && useradd -M -s /sbin/nologin redis

chown -R redis:redis /usr/local/redis/{var,etc}

wget -O /etc/init.d/redis-server http://file.asuhu.com/so/redis_init_script
if [ ! -e '/etc/init.d/redis-server' ]; then
wget -O /etc/init.d/redis-server http://arv.asuhu.com/ftp/so/redis_init_script
fi
chmod +x /etc/init.d/redis-server
chkconfig --add redis-server
chkconfig redis-server on

    ln -fs /usr/local/redis/bin/* /usr/local/bin/
    sed -i 's@pidfile.*@pidfile /var/run/redis.pid@' /usr/local/redis/etc/redis.conf
    sed -i "s@logfile.*@logfile /usr/local/redis/var/redis.log@" /usr/local/redis/etc/redis.conf
    sed -i "s@^dir.*@dir /usr/local/redis/var@" /usr/local/redis/etc/redis.conf
    sed -i 's@daemonize no@daemonize yes@' /usr/local/redis/etc/redis.conf
    sed -i "s@^# bind 127.0.0.1@bind 127.0.0.1@" /usr/local/redis/etc/redis.conf
    redis_maxmemory=`expr $tram / 8`000000
    [ -z "`grep ^maxmemory /usr/local/redis/etc/redis.conf`" ] && sed -i "s@maxmemory <bytes>@maxmemory <bytes>\nmaxmemory `expr $tram / 8`000000@" /usr/local/redis/etc/redis.conf
    echo "Redis-server installed successfully"
 service redis-server start
fi

cd ~
rm -rf redis-stable.tar.gz
rm -rf redis-stable
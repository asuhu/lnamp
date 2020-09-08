#!/bin/bash
#devtoolset-9 Redis 6.0.5
redis_version=redis-5.0.9
THREAD=$(cat /proc/cpuinfo | grep 'model name'| wc -l)
yum -y install gcc gcc-c++ make vim screen python wget git lsof
tram=$( free -m | awk '/Mem/ {print $2}' )
cd ~
#wget -c http://download.redis.io/releases/redis-stable.tar.gz
wget -c http://download.redis.io/releases/${redis_version}.tar.gz
tar zxf ${redis_version}.tar.gz
cd ${redis_version}
make -j ${THREAD} && make install

if [ -f "/root/${redis_version}/src/redis-server" ]; then
mkdir -p /usr/local/redis/{bin,etc,var}
/bin/cp /root/${redis_version}/src/{redis-benchmark,redis-check-aof,redis-check-rdb,redis-cli,redis-sentinel,redis-server} /usr/local/redis/bin/
/bin/cp /root/${redis_version}/redis.conf /usr/local/redis/etc/

cd /root/${redis_version}/src
    id -u redis >/dev/null 2>&1
    [ $? -ne 0 ] && useradd -M -s /sbin/nologin redis

chown -R redis:redis /usr/local/redis/{var,etc}
#
 if [ -e /bin/systemctl ]; then
cat > /lib/systemd/system/redis-server.service << "EOF"
[Unit]
Description=Redis In-Memory Data Store
After=network.target

[Service]
Type=forking
PIDFile=/var/run/redis/redis.pid
User=redis
Group=redis

Environment=statedir=/var/run/redis
PermissionsStartOnly=true
ExecStartPre=/bin/mkdir -p ${statedir}
ExecStartPre=/bin/chown -R redis:redis ${statedir}
ExecStart=/usr/local/redis/bin/redis-server /usr/local/redis/etc/redis.conf
ExecStop=/bin/kill -s TERM $MAINPID
Restart=always
LimitNOFILE=1000000
LimitNPROC=1000000
LimitCORE=1000000

[Install]
WantedBy=multi-user.target
EOF
systemctl enable redis-server
else
wget -O /etc/init.d/redis-server http://file.asuhu.com/so/redis_init_script
	if [ ! -e '/etc/init.d/redis-server' ]; then
wget -O /etc/init.d/redis-server http://arv.asuhu.com/ftp/so/redis_init_script
	fi
chmod +x /etc/init.d/redis-server
chkconfig --add redis-server
chkconfig redis-server on
fi
    ln -fs /usr/local/redis/bin/* /usr/local/bin/
    sed -i 's@pidfile.*@pidfile /var/run/redis/redis.pid@' /usr/local/redis/etc/redis.conf
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
rm -rf ${redis_version}.tar.gz
rm -rf ${redis_version}
#!/bin/bash
#https://dev.mysql.com/downloads/mysql/5.6.html#downloads
a=$(cat /proc/cpuinfo | grep 'model name'| wc -l)
sqlpass=$(date +%s%N | sha256sum | base64 | head -c 12)
Mem=$( free -m | awk '/Mem/ {print $2}' )
sqlstable=5.6.38

if [ ! -e '/usr/bin/wget' ]; then
yum -y install wget
fi

yum -y install cmake gcc-c++ ncurses-devel
cd ~
wget -4 http://cdn.mysql.com/Downloads/MySQL-5.6/mysql-${sqlstable}.tar.gz
tar -zxf mysql-${sqlstable}.tar.gz && rm -rf mysql-${sqlstable}.tar.gz
cd mysql-${sqlstable}
cmake . -DCMAKE_INSTALL_PREFIX=/usr/local/mysql \
-DMYSQL_DATADIR=/usr/local/mysql/data \
-DSYSCONFDIR=/etc \
-DWITH_INNOBASE_STORAGE_ENGINE=1 \
-DWITH_PARTITION_STORAGE_ENGINE=1 \
-DWITH_FEDERATED_STORAGE_ENGINE=1 \
-DWITH_BLACKHOLE_STORAGE_ENGINE=1 \
-DWITH_MYISAM_STORAGE_ENGINE=1 \
-DENABLED_LOCAL_INFILE=1 \
-DENABLE_DTRACE=0 \
-DDEFAULT_CHARSET=utf8mb4 \
-DDEFAULT_COLLATION=utf8mb4_general_ci \
-DWITH_EMBEDDED_SERVER=1 \
-DEXTRA_CHARSETS=all
make -j$a
make install

if [ ! -e '/usr/local/mysql/bin/mysql' ]; then
echo -e "\033[31m Install mysql5.6 error ... \033[0m \n"
exit
fi


echo 'export PATH=/usr/local/mysql/bin/:$PATH'>>/etc/profile;
source /etc/profile;
    id -u mysql >/dev/null 2>&1
    [ $? -ne 0 ] && useradd -M -s /sbin/nologin mysql
chown -R mysql.mysql /usr/local/mysql/;

/bin/cp /usr/local/mysql/support-files/mysql.server /etc/init.d/mysqld;
chmod +x /etc/init.d/mysqld;
chkconfig --add mysqld; chkconfig mysqld on;
mv /etc/my.cnf /etc/my.cnf.bak

cat > /etc/my.cnf << EOF
[client]
port = 3306
socket = /tmp/mysql.sock
default-character-set = utf8mb4

[mysql]
prompt="MySQL [\\d]> "
no-auto-rehash

[mysqld]
#/usr/share/zoneinfo/Asia/Shanghai
port = 3306
socket = /tmp/mysql.sock
basedir = /usr/local/mysql
datadir = /usr/local/mysql/data
pid-file = /usr/local/mysql/data/mysql.pid
user = mysql
bind-address = 0.0.0.0
server-id = 1
init-connect = 'SET NAMES utf8mb4'
character-set-server = utf8mb4

skip-name-resolve
#skip-networking
back_log = 300

max_connections = 1000
max_connect_errors = 6000
open_files_limit = 65535
table_open_cache = 128
max_allowed_packet = 500M
binlog_cache_size = 1M
max_heap_table_size = 8M
tmp_table_size = 16M

read_buffer_size = 2M
read_rnd_buffer_size = 8M
sort_buffer_size = 8M
join_buffer_size = 8M
key_buffer_size = 4M

thread_cache_size = 8

query_cache_type = 1
query_cache_size = 8M
query_cache_limit = 2M

ft_min_word_len = 4
log_bin = mysql-bin
binlog_format = mixed
expire_logs_days = 30
log_error = /usr/local/mysql/data/mysql-error.log
slow_query_log = 1
long_query_time = 1
slow_query_log_file = /usr/local/mysql/data/mysql-slow.log
performance_schema = 0
explicit_defaults_for_timestamp
#lower_case_table_names = 1
skip-external-locking
default_storage_engine = InnoDB
#default-storage-engine = MyISAM
innodb_file_per_table = 1
innodb_open_files = 500
innodb_buffer_pool_size = 64M
innodb_write_io_threads = 4
innodb_read_io_threads = 4
innodb_thread_concurrency = 0
innodb_purge_threads = 1
innodb_flush_log_at_trx_commit = 2
innodb_log_buffer_size = 2M
innodb_log_file_size = 32M
innodb_log_files_in_group = 3
innodb_max_dirty_pages_pct = 90
innodb_lock_wait_timeout = 120
bulk_insert_buffer_size = 8M
myisam_sort_buffer_size = 8M
myisam_max_sort_file_size = 10G
myisam_repair_threads = 1
interactive_timeout = 28800
wait_timeout = 28800
[mysqldump]
quick
max_allowed_packet = 16M
[myisamchk]
key_buffer_size = 8M
sort_buffer_size = 8M
read_buffer = 4M
write_buffer = 4M
EOF

yum -y install perl
/usr/local/mysql/scripts/mysql_install_db --defaults-file=/etc/my.cnf  --basedir=/usr/local/mysql --datadir=/usr/local/mysql/data
chown -R mysql.mysql  /usr/local/mysql

if [ $Mem -gt 1500 -a $Mem -le 2500 ];then
    sed -i 's@^thread_cache_size.*@thread_cache_size = 16@' /etc/my.cnf
    sed -i 's@^query_cache_size.*@query_cache_size = 16M@' /etc/my.cnf
    sed -i 's@^myisam_sort_buffer_size.*@myisam_sort_buffer_size = 16M@' /etc/my.cnf
    sed -i 's@^key_buffer_size.*@key_buffer_size = 16M@' /etc/my.cnf
    sed -i 's@^innodb_buffer_pool_size.*@innodb_buffer_pool_size = 128M@' /etc/my.cnf
    sed -i 's@^tmp_table_size.*@tmp_table_size = 32M@' /etc/my.cnf
    sed -i 's@^table_open_cache.*@table_open_cache = 256@' /etc/my.cnf
elif [ $Mem -gt 2500 -a $Mem -le 3500 ];then
    sed -i 's@^thread_cache_size.*@thread_cache_size = 32@' /etc/my.cnf
    sed -i 's@^query_cache_size.*@query_cache_size = 32M@' /etc/my.cnf
    sed -i 's@^myisam_sort_buffer_size.*@myisam_sort_buffer_size = 32M@' /etc/my.cnf
    sed -i 's@^key_buffer_size.*@key_buffer_size = 64M@' /etc/my.cnf
    sed -i 's@^innodb_buffer_pool_size.*@innodb_buffer_pool_size = 512M@' /etc/my.cnf
    sed -i 's@^tmp_table_size.*@tmp_table_size = 64M@' /etc/my.cnf
    sed -i 's@^table_open_cache.*@table_open_cache = 512@' /etc/my.cnf
elif [ $Mem -gt 3500 ];then
    sed -i 's@^thread_cache_size.*@thread_cache_size = 64@' /etc/my.cnf
    sed -i 's@^query_cache_size.*@query_cache_size = 64M@' /etc/my.cnf
    sed -i 's@^myisam_sort_buffer_size.*@myisam_sort_buffer_size = 64M@' /etc/my.cnf
    sed -i 's@^key_buffer_size.*@key_buffer_size = 256M@' /etc/my.cnf
    sed -i 's@^innodb_buffer_pool_size.*@innodb_buffer_pool_size = 1024M@' /etc/my.cnf
    sed -i 's@^tmp_table_size.*@tmp_table_size = 128M@' /etc/my.cnf
    sed -i 's@^table_open_cache.*@table_open_cache = 1024@' /etc/my.cnf
fi
service mysqld restart

if [ ! -e '/usr/local/mysql/data/mysql.pid' ]; then
echo -e "\033[31m config mysql error ... \033[0m \n"
exit 1
fi

/usr/local/mysql/bin/mysqladmin -uroot -p password "$sqlpass";
/usr/local/mysql/bin/mysql -uroot -p${sqlpass} <<EOF
drop database if exists test;
delete from mysql.user where not (user='root');
delete from mysql.user where password='';
delete from mysql.db where user='';
flush privileges;
exit
EOF
echo -e "mysql root password  \033[41;36m  $sqlpass  \033[0m";
#select user,host from mysql.user;
/usr/local/mysql/bin/mysql --version
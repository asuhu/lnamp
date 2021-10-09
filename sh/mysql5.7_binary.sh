#!/bin/bash
#CentOS 6 7
#Generic #https://dev.mysql.com/get/Downloads/MySQL-5.7/mysql-5.7.24-linux-glibc2.12-x86_64.tar.gz
#
THREAD=$(cat /proc/cpuinfo | grep 'model name'| wc -l)
sqlpass=$(date +%s%N | sha256sum | base64 | head -c 12)
if [ -z ${sqlpass} ];then
sqlpass='R0JZrvdUt&P@WlHs'
fi
Mem=$( free -m | awk '/Mem/ {print $2}' )
#define
mysql_install_dir=/usr/local/mysql
mysql_data_dir=/usr/local/mysql/data
sqlstable=5.7.33
glibcstable=glibc2.12
#mysql account
    id -u mysql >/dev/null 2>&1
    [ $? -ne 0 ] && useradd -M -s /sbin/nologin mysql
#folder
#  [ ! -d "${mysql_install_dir}" ] && mkdir -p ${mysql_install_dir} && chown mysql.mysql -R ${mysql_install_dir}  因为mv  mysql-${sqlstable}-linux-${glibcstable}-x86_64  ${mysql_install_dir}
#  mkdir -p ${mysql_data_dir} && chown mysql.mysql -R ${mysql_data_dir}因为mv  mysql-${sqlstable}-linux-${glibcstable}-x86_64  ${mysql_install_dir}
yum -y install gcc gcc-c++ ncurses ncurses-devel cmake curl openssl openssl-devel wget python
yum -y install libaio
yum -y install numactl                                 #/usr/local/mysql/bin/mysqld: error while loading shared libraries: libnuma.so.1

if [ ! -e '/usr/bin/wget' ]; then yum -y install wget; fi

cd ~
wget -4 -q https://cdn.mysql.com//Downloads/MySQL-5.7/mysql-${sqlstable}-linux-${glibcstable}-x86_64.tar.gz
tar -zxf mysql-${sqlstable}-linux-${glibcstable}-x86_64.tar.gz
mv  mysql-${sqlstable}-linux-${glibcstable}-x86_64  ${mysql_install_dir}

#初始化
#创建数据文件夹
mkdir -p ${mysql_data_dir} && chown -R mysql.mysql ${mysql_install_dir} && chown -R mysql.mysql  ${mysql_data_dir}
chown -R mysql.mysql ${mysql_install_dir} && chown -R mysql.mysql  ${mysql_data_dir}
${mysql_install_dir}/bin/mysqld --initialize-insecure --basedir=${mysql_install_dir} --datadir=${mysql_data_dir} --user=mysql
#cp /usr/local/mysql/support-files/my-default.cnf  /etc/my.cnf

#mysqld
/bin/cp ${mysql_install_dir}/support-files/mysql.server /etc/init.d/mysqld
chmod +x /etc/init.d/mysqld
 sed -i "s@^basedir=.*@basedir=${mysql_install_dir}@" /etc/init.d/mysqld
 sed -i "s@^datadir=.*@datadir=${mysql_data_dir}@" /etc/init.d/mysqld
/bin/cp ${mysql_install_dir}/bin/mysqldump /usr/bin/mysqldump
/bin/cp ${mysql_install_dir}/bin/mysql /usr/bin/mysql
chkconfig --add mysqld && chkconfig mysqld on


cat > /etc/my.cnf << EOF
[client]
port = 3306
socket = /tmp/mysql.sock
default-character-set = utf8mb4

[mysql]
prompt="MySQL [\\d]> "
no-auto-rehash

[mysqld]
port = 3306
socket = /tmp/mysql.sock
basedir = ${mysql_install_dir}
datadir = ${mysql_data_dir}
pid-file = ${mysql_data_dir}/mysql.pid
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
log_error = ${mysql_data_dir}/mysql-error.log
slow_query_log = 1
long_query_time = 1
slow_query_log_file = ${mysql_data_dir}/mysql-slow.log
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

#优化相关参数
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

/etc/init.d/mysqld restart
if [ ! -e "${mysql_data_dir}/mysql.pid" ]; then
echo -e "\033[31m MySQL Community Server ${sqlstable}-linux-${glibcstable}-x86_64 Config Error ... \033[0m \n"
kill -9 $$
fi

#修改默认为空的密码，添加root@127.0.0.1
${mysql_install_dir}/bin/mysql -e "grant all privileges on *.* to root@'127.0.0.1' identified by \"${sqlpass}\" with grant option;"
${mysql_install_dir}/bin/mysql -e "grant all privileges on *.* to root@'localhost' identified by \"${sqlpass}\" with grant option;"

#下面两行操作会出现[Warning] Using a password on the command line interface can be insecure.
${mysql_install_dir}/bin/mysql -uroot -p${sqlpass} -e "reset master;"
${mysql_install_dir}/bin/mysql -uroot -p${sqlpass} -e "select user,host from mysql.user;"

echo -e "MySQL Community Server ${sqlstable}-linux-${glibcstable}-x86_64 root password  \033[41;36m  $sqlpass  \033[0m";
#select user,host from mysql.user;
${mysql_install_dir}/bin/mysql --version
#添加环境变量
echo "export PATH=${mysql_install_dir}/bin/:$PATH">>/etc/profile
source /etc/profile
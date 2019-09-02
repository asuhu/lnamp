#!/bin/bash
#CentOS 6 7
#https://dev.mysql.com/downloads/mysql/5.6.html
#
a=$(cat /proc/cpuinfo | grep 'model name'| wc -l)
sqlpass=$(date +%s%N | sha256sum | base64 | head -c 12)
if [ -z ${sqlpass} ];then
sqlpass='R0JZrvdUt&P@WlHs'
fi
Mem=$( free -m | awk '/Mem/ {print $2}' )
#define
mysql_install_dir=/usr/local/mysql
mysql_data_dir=/usr/local/mysql/data
#
#mysql account
    id -u mysql >/dev/null 2>&1
    [ $? -ne 0 ] && useradd -M -s /sbin/nologin mysql
#folder
  [ ! -d "${mysql_install_dir}" ] && mkdir -p ${mysql_install_dir} && chown mysql.mysql -R ${mysql_install_dir} 
  mkdir -p ${mysql_data_dir} && chown mysql.mysql -R ${mysql_data_dir}
#
sqlstable=$(curl -s https://dev.mysql.com/downloads/mysql/5.6.html#downloads | grep "<h1>MySQL Community Server" | awk '{print $4}')
if [ -z ${sqlstable} ] ;then
sqlstable=5.6.45
echo "Install MySQL Community Server 5.6.45"
else
echo "Install MySQL Community Server ${sqlstable}"
fi

yum -y install cmake gcc-c++ ncurses-devel cmake curl openssl openssl-devel wget python net-tools
yum -y install autoconf   #FATAL ERROR: please install the following Perl modules before executing /usr/local/mysql/scripts/mysql_install_db

if [ ! -e '/usr/bin/wget' ]; then yum -y install wget; fi

cd ~
wget -q -4 http://cdn.mysql.com/Downloads/MySQL-5.6/mysql-${sqlstable}.tar.gz
tar -zxf mysql-${sqlstable}.tar.gz && rm -rf mysql-${sqlstable}.tar.gz
cd mysql-${sqlstable}
cmake . -DCMAKE_INSTALL_PREFIX=${mysql_install_dir} \
-DMYSQL_DATADIR=${mysql_data_dir} \
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
make -j ${a} && make install

if [ ! -e "${mysql_install_dir}/bin/mysql" ]; then
echo -e "\033[31m Install MySQL Community Server ${sqlstable} Install ERROR ... \033[0m \n"
     kill -9 $$
fi

#MySQL Community Server 5.6 mysqld
/bin/cp ${mysql_install_dir}/support-files/mysql.server /etc/init.d/mysqld;
chmod +x /etc/init.d/mysqld;
chkconfig --add mysqld; chkconfig mysqld on;
mv /etc/my.cnf /etc/my.cnf.bak
 sed -i "s@^basedir=.*@basedir=${mysql_install_dir}@" /etc/init.d/mysqld
 sed -i "s@^datadir=.*@datadir=${mysql_data_dir}@" /etc/init.d/mysqld

#MySQL Community Server 5.6 my.cnf配置
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

#初始化MySQL Community Server 5.6
#初始化-initial-insecure创建空密码的 root@localhost，--initialize创建带密码的 root@localhost，密码在log-error日志文件中（在5.6版本中是放在 ~/.mysql_secret 文件中）
yum -y install perl
chown -R mysql.mysql  ${mysql_install_dir}  && chown -R mysql.mysql  ${mysql_data_dir}
${mysql_install_dir}/scripts/mysql_install_db --defaults-file=/etc/my.cnf  --basedir=${mysql_install_dir} --datadir=${mysql_data_dir}

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
echo -e "\033[31m Install MySQL Community Server ${sqlstable} Config Error ... \033[0m \n"
kill -9 $$
fi

#${mysql_install_dir}/bin/mysqladmin -uroot -p password "$sqlpass";  #这样需要手动按回车键才可以继续
#修改默认为空的密码，添加root@127.0.0.1
 ${mysql_install_dir}/bin/mysql -e "grant all privileges on *.* to root@'127.0.0.1' identified by \"${sqlpass}\" with grant option;"
 ${mysql_install_dir}/bin/mysql -e "grant all privileges on *.* to root@'localhost' identified by \"${sqlpass}\" with grant option;"
 ${mysql_install_dir}/bin/mysql -uroot -p${sqlpass} -e "delete from mysql.user where Password='';"
 ${mysql_install_dir}/bin/mysql -uroot -p${sqlpass} -e "delete from mysql.db where User='';"
 ${mysql_install_dir}/bin/mysql -uroot -p${sqlpass} -e "delete from mysql.proxies_priv where Host!='localhost';"
 ${mysql_install_dir}/bin/mysql -uroot -p${sqlpass} -e "drop database test;"
 ${mysql_install_dir}/bin/mysql -uroot -p${sqlpass} -e "reset master;"
 ${mysql_install_dir}/bin/mysql -uroot -p${sqlpass} -e "select user,host from mysql.user;"
#${mysql_install_dir}/bin/mysql -uroot -p${sqlpass} <<EOF
#drop database if exists test;
#delete from mysql.user where not (user='root');
#delete from mysql.user where password='';
#delete from mysql.db where user='';
#delete from mysql.proxies_priv where Host!='localhost';
#reset master;
#flush privileges;
#exit
#EOF
#
#################默认安装完成的Mysql5.6数据库
#       用户名	主机名          	密码	全局权限 	授权
#	任意	%	                否	USAGE	        否
#	任意	izj6cer1t2ub255k466jyoz	否	USAGE    	否
#	任意	localhost        	否	USAGE	        否
#	root	127.0.0.1        	否	ALL PRIVILEGES	是
#	root	::1              	否	ALL PRIVILEGES	是
#	root	izj6cer1t2ub255k466jyoz	否	ALL PRIVILEGES	是
#	root	localhost       	是	ALL PRIVILEGES	是
#################
#select user,host from mysql.user;
#/usr/local/mysql/my.cnf # http://dev.mysql.com/doc/refman/5.6/en/server-configuration-defaults.html
#
#/usr/local/mysql/bin/mysql_secure_installation
#which will also give you the option of removing the test databases and anonymous user created by default.  This is strongly recommended for production servers.
#
#You can test the MySQL daemon with mysql-test-run.pl
#cd /usr/local/mysql/mysql-test ; perl mysql-test-run.pl

rm -rf /etc/ld.so.conf.d/{mysql,mariadb,percona,alisql}*.conf;
[ -e "${mysql_install_dir}/my.cnf" ] && rm -f ${mysql_install_dir}/my.cnf;
echo "${mysql_install_dir}/lib" > /etc/ld.so.conf.d/mysql.conf;
ldconfig;
#
echo -e "MySQL Community Server ${sqlstable} root password  \033[41;36m  $sqlpass  \033[0m";
${mysql_install_dir}/bin/mysql --version
#
cd ~
rm -rf mysql-${sqlstable}
#添加环境变量
echo "export PATH=${mysql_install_dir}/bin/:$PATH">>/etc/profile && source /etc/profile
source /etc/profile
service mysqld stop    #不然会卡在./mysql.sh 2>&1 | tee mysql.log
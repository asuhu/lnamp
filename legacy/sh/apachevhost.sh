#!/bin/bash
wwwroot_dir=/home/wwwroot
wwwlogs_dir=/home/wwwlogs

apaversion=$(/usr/local/apache/bin/httpd -v | grep 2.4)

if [ -z ${apaversion} ];then

read -p "Do you want you website HTTPS? [y/n]: " https_flag
if [ "${https_flag}" == 'y' ]; then
########################################################################
read -p "Please input ssl domain(example: www.asuhu.com): " domain
    if [ -z "$(echo ${domain} | grep '.*\..*')" ]; then
      echo "Your Domain ${domain} is invalid!"
      exit 1
    else
      echo "Added https virtual host ${domain}"
    fi

if [ -e /usr/local/apache/conf/vhost/${domain}.conf ];then
confbk=`date "+%Y-%m-%d_%H:%M:%S"`
cp /usr/local/apache/conf/vhost/${domain}.conf /usr/local/apache/conf/vhost/${domain}.conf.${confbk}
fi

#webdir
mkdir -p ${wwwroot_dir}/${domain}

#confdir
if [ ! -e /usr/local/apache/conf/vhostssl ];then
mkdir -p /usr/local/apache/conf/vhostssl
fi

#sslcertificatedir
if [ ! -e /usr/local/apache/conf/vhostssl/${domain} ];then
mkdir -p /usr/local/apache/conf/vhostssl/${domain}
fi

cat > /usr/local/apache/conf/vhostssl/${domain}.conf << EOF
<VirtualHost *:443>
  ServerAdmin admin@${domain}
  DocumentRoot "${wwwroot_dir}/${domain}"
  ServerName ${domain}
  SSLEngine on
  SSLCertificateFile /usr/local/apache/conf/vhostssl/${domain}/server.crt
  SSLCertificateKeyFile /usr/local/apache/conf/vhostssl/${domain}/server.key
  SSLCertificateChainFile /usr/local/apache/conf/vhostssl/${domain}/all.crt
  SSLProtocol -all +SSLv3 +TLSv1 +TLSv1.1 +TLSv1.2
  SSLCipherSuite EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:ECDHE-RSA-AES128-SHA:DHE-RSA-AES128-GCM-SHA256:AES256+EDH:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA:DHE-RSA-AES256-SHA256:DHE-RSA-AES128-SHA256:DHE-RSA-AES256-SHA:DHE-RSA-AES128-SHA:ECDHE-RSA-DES-CBC3-SHA:EDH-RSA-DES-CBC3-SHA:AES256-GCM-SHA384:AES128-GCM-SHA256:AES256-SHA256:AES128-SHA256:AES256-SHA:AES128-SHA:DES-CBC3-SHA:HIGH:!aNULL:!eNULL:!EXPORT:!DES:!MD5:!PSK:!RC4
  ErrorLog "|/usr/local/apache/bin/rotatelogs ${wwwlogs_dir}/${domain}_error_log_%Y%m%d 86400 480"
  CustomLog "|/usr/local/apache/bin/rotatelogs ${wwwlogs_dir}/${domain}_access_log_%Y%m%d 86400 480" combined
<Directory "${wwwroot_dir}/${domain}">
  SetOutputFilter DEFLATE
  Options FollowSymLinks ExecCGI IncludesNoExec
  AllowOverride All
  Order allow,deny
  Allow from all
  DirectoryIndex index.html index.php
</Directory>
<Location /server-status>
  SetHandler server-status
  Order Deny,Allow
  Deny from all
  Allow from 127.0.0.1 ::1
</Location>
</VirtualHost>
EOF

echo "you need add SSLCertificateFile /usr/local/apache/conf/vhostssl/${domain}/server.crt"
echo "you need add SSLCertificateKeyFile /usr/local/apache/conf/vhostssl/${domain}/server.key"
echo "you need add SSLCertificateChainFile /usr/local/apache/conf/vhostssl/${domain}/all.crt"
echo "Http Has been redirected to HTTPS"
echo "Added after completion service httpd restart" 

################################
#Include conf/vhostssl/*.conf
#Include conf/extra/httpd-ssl.conf
cp /usr/local/apache/conf/extra/httpd-ssl.conf /usr/local/apache/conf/extra/httpd-ssl.conf.bak
#cat > /usr/local/apache/conf/extra/httpd-ssl.conf << EOF
#Listen 443
#NameVirtualHost *:443
#EOF
################################
#301
cat > /usr/local/apache/conf/vhost/${domain}.conf << EOF
<VirtualHost *:80>
  ServerAdmin admin@${domain}
  ServerName ${domain}
   Redirect permanent / https://${domain}/
</VirtualHost>
EOF

#website
cat > ${wwwroot_dir}/${domain}/index.html << EOF
${domain}
EOF
chown apache.apache ${wwwroot_dir}/${domain}
#end of apache2.2 https

else

read -p "Please input domain(example: www.asuhu.com): " domain
    if [ -z "$(echo ${domain} | grep '.*\..*')" ]; then
      echo "Your Domain ${domain} is invalid!"
      exit 1
    else
      echo "Added virtual host ${domain}"
    fi

if [ -e /usr/local/apache/conf/vhost/${domain}.conf ];then
confbk=`date "+%Y-%m-%d_%H:%M:%S"`
cp /usr/local/apache/conf/vhost/${domain}.conf /usr/local/apache/conf/vhost/${domain}.conf.${confbk}
fi

#webdir
mkdir -p ${wwwroot_dir}/${domain}

cat > /usr/local/apache/conf/vhost/${domain}.conf << EOF
<VirtualHost *:80>
  ServerAdmin admin@${domain}
  DocumentRoot "${wwwroot_dir}/${domain}"
  ServerName ${domain}
  ErrorLog "|/usr/local/apache/bin/rotatelogs ${wwwlogs_dir}/${domain}_error_log_%Y%m%d 86400 480"
  CustomLog "|/usr/local/apache/bin/rotatelogs ${wwwlogs_dir}/${domain}_access_log_%Y%m%d 86400 480" combined
<Directory "${wwwroot_dir}/${domain}">
  SetOutputFilter DEFLATE
  Options FollowSymLinks ExecCGI IncludesNoExec
  AllowOverride All
  Order allow,deny
  Allow from all
  DirectoryIndex index.html index.php
</Directory>
<Location /server-status>
  SetHandler server-status
  Order Deny,Allow
  Deny from all
  Allow from 127.0.0.1 ::1
</Location>
</VirtualHost>
EOF

#website
cat > ${wwwroot_dir}/${domain}/index.html << EOF
${domain}
EOF

service httpd restart
chown apache.apache ${wwwroot_dir}/${domain}
#end of apache2.2
fi


else
echo "will add apache2.4"
fi
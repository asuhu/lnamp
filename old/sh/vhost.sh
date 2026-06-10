#!/bin/bash
logdir=/home/wwwlogs
webdir=/home/wwwroot

read -p "Do you want you website Only HTTPS? [y/n]: " https_flag
if [ "${https_flag}" == 'y' ]; then
########################################################################
read -p "Please input ssl domain(example: www.asuhu.com): " domain
    if [ -z "$(echo ${domain} | grep '.*\..*')" ]; then
      echo "Your Domain ${domain} is invalid!"
      exit 1
    else
      echo "Added virtual host ${domain}"
    fi

#conf dir
if [ -e /usr/local/nginx/conf/vhost/${domain} ];then
echo "${domain} conf dir ok"
else
mkdir -p /usr/local/nginx/conf/vhost/${domain}
fi

#website
if [ -e ${webdir}/${domain} ];then
echo "website ok"
else
mkdir -p ${webdir}/${domain}
fi

if [ -e /usr/local/nginx/conf/vhost/${domain}.conf ];then
confbk=`date "+%Y-%m-%d_%H:%M:%S"`
cp /usr/local/nginx/conf/vhost/${domain}.conf /usr/local/nginx/conf/vhost/${domain}.conf.${confbk}
fi

cat > /usr/local/nginx/conf/vhost/4096dhparam.pem << "EOF"
-----BEGIN DH PARAMETERS-----
MIICCAKCAgEA7djm1yi5fOnRr6HzLZzQ9M5sHMlolpERCdhRaCw7SyiMlGaZ8HKG
eIk1uKsBLMtXUX7GGOJ9lEkCvosJ7jEdXeXrPx7hytdW0lEXrgusEAfKYr4p0iFz
EVinkGSS0mkphIUEkRmfIeePhlJhXBUg8F4AFf2cX3sUKlhBrRET3lLa87zwONYF
SmRq0h58aGdo5YF3iUSHx0HwNjIlomRHnEZmYDPt5S1xIETmMJAMlnWvPJj2Dii8
YWUQFQL1wNs+XWLv+7wOUrFnW2EhejpnPHCh/6vLFy8KoDGYnf6sCp+o/KAeSTPw
uXLBrgsCInpqm78RO2BkN6ICMYrqQoJ89h/nStqGoQRsk1bgkhFib75GVPpabo4F
TqYNkzjRHaFoERhfju+En8x+9FegGtYNKTaziHIizQKdryW/o3Gi3ar199JfYEf1
jU9TquYG7fOFi5Yi3UKCHUvFAvXEsdUdcRPd0cKuVdVVHZAAG37T9HvWOOU3DoA5
WDO77YwjPXBu6CAoLOa5fBU0A/lXCyiGF2i+6RMnnvf5Njw7eUXiqSfl9EaQZD1L
6hKEhtYRXHvH5xuBRlC2pKRnanQvUMMaz5TWysxnrIfZEcMxpAw0Tzb/6L3+Jafb
7qdgyR5DGlWJJrg2awPWuemvaL6ptlNvNRw/951lRZxr6QC1ReBcS4sCAQI=
-----END DH PARAMETERS-----
EOF

  cat > /usr/local/nginx/conf/vhost/${domain}.conf << "EOF"
   server {
if ($http_user_agent ~* (ApacheBench|webbench|HttpClient|Scrapy)) {
     return 444;
}

if ($http_user_agent ~ "FeedDemon|Indy Library|WinHttp|Alexa Toolbar|AskTbFXTV|AhrefsBot|Python-urllib|Jullo|Feedly|jaunty|Java|ZmEu|CrawlDaddy|Microsoft URL Control|^$" ) {
     return 444;             
}

if ($request_uri ~* (.*)\.(bak|mdb|db|sql)$){
           return 444;
}
if ($request_method !~ ^(GET|HEAD|POST)$) {
    return 403;
}
if ($query_string ~ "[a-zA-Z0-9_]=http://") { return 444; }
if ($query_string ~ "[a-zA-Z0-9_]=(\.\.//?)+") { return 444; }
if ($query_string ~ "[a-zA-Z0-9_]=/([a-z0-9_.]//?)+") { return 444; }

if ($request_uri ~* "[+|(%20)]select[+|(%20)]") { return 444; }
if ($request_uri ~* "[+|(%20)]delete[+|(%20)]") { return 444; }
if ($request_uri ~* "[+|(%20)]update[+|(%20)]") { return 444; }
if ($request_uri ~* "[+|(%20)]insert[+|(%20)]") { return 444; }

if ($query_string ~ "(<|%3C).*script.*(>|%3E)") { return 444; }


# Deny all attempts to access hidden files such as .htaccess, .htpasswd, .DS_Store (Mac).
location ~ /\. {
	deny all;
}

# Deny access to any files with a .php extension in the uploads directory
location ~* /(?:uploads|files)/.*\.php$ {
	deny all;
}

listen 443 ssl http2;
       	ssl on;
        ssl_certificate  /usr/local/nginx/conf/vhost/domain/server.crt;
        ssl_certificate_key  /usr/local/nginx/conf/vhost/domain/server.key;
	ssl_session_timeout 10m;
	ssl_session_cache shared:SSL:10m;
	keepalive_timeout 60;
        ssl_protocols TLSv1.1 TLSv1.2;
        ssl_dhparam /usr/local/nginx/conf/vhost/4096dhparam.pem;
        ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:AES128-GCM-SHA256:RC4:HIGH:!MD5:!aNULL:!EDH:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA:EDH-DSS-DES-CBC3-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA256:AES256-SHA256:AES128-SHA:AES256-SHA:AES:!aNULL:!eNULL:!EXPORT:!CAMELLIA:!DES:!RC4:!MD5:!PSK:!aECDH:!EDH-RSA-DES-CBC3-SHA:!KRB5-DES-CBC3-SHA:!DES-CBC3-SHA;
        ssl_prefer_server_ciphers on;
        ssl_stapling on;
        ssl_stapling_verify on;
  	ssl_trusted_certificate /usr/local/nginx/conf/vhost/domain/all.crt;
        resolver 114.114.114.114 208.67.222.222 valid=300s;
        resolver_timeout 5s;
        add_header Strict-Transport-Security "max-age=31536000";
        add_header X-Frame-Options DENY;
	add_header X-Content-Type-Options nosniff;

    server_name domain;
    access_log logdir/domain_nginx.log combined;
    error_log  logdir/domain_nginx.error.log error;
    root webdir/domain;
    index index.html index.htm index.php;
    location /nginx_status {
        stub_status on;
        access_log off;
        allow 127.0.0.1;
        deny all;
                           }

  location ~ .mp4$ {
  mp4;
  mp4_buffer_size 4M;
  mp4_max_buffer_size 10M;
                   }
 location ~ \.php$ {
                    fastcgi_pass   127.0.0.1:9000;
                    fastcgi_index  index.php;
                    fastcgi_param  SCRIPT_FILENAME $document_root$fastcgi_script_name;
                    include        fastcgi_params;
            }
  location ~(tweentyfourteen|twentyeleven|twentyfifteen|twentyten|twentytwelve)/(.*)\.php  {return 400;}
  location ~ .*\.(gif|jpg|jpeg|png|bmp|swf|flv|ico)$ {
        expires 30d;
        access_log off;
        }
  location ~ .*\.(js|css)?$ {
        expires 7d;
        access_log off;
        }
location = /favicon.ico {
	log_not_found off;
	access_log off;
}

# Deny all attempts to access hidden files such as .htaccess, .htpasswd, .DS_Store (Mac).
location ~ /\. {
	deny all;
}

# Deny access to any files with a .php extension in the uploads directory
location ~* /(?:uploads|files)/.*\.php$ {
	deny all;
}
    }
EOF

sed -i "s@logdir@${logdir}@g" /usr/local/nginx/conf/vhost/${domain}.conf
sed -i "s@webdir@${webdir}@g" /usr/local/nginx/conf/vhost/${domain}.conf
sed -i "s@domain@${domain}@g" /usr/local/nginx/conf/vhost/${domain}.conf
echo "Http Has been redirected to HTTPS"
echo "Added after completion service httpd restart" 

#301
cat > /usr/local/nginx/conf/vhost/${domain}301.conf << "EOF"
server {
    listen  80;
    server_name   domain; 
    return    301 https://domain$request_uri;
}
EOF
sed -i "s@domain@${domain}@g" /usr/local/nginx/conf/vhost/${domain}301.conf
#
chown www.www ${webdir}/${domain}
echo "You need to manually add the Private key (server.key) in /usr/local/nginx/conf/vhost/${domain}"
echo "You need to manually add the SSL certificate (server.crt and all.crt)  in /usr/local/nginx/conf/vhost/${domain}"
########################################################################
elif [ "${https_flag}" == 'n' ];then
   read -p "Please input domain(example: www.asuhu.com): " domain
    if [ -z "$(echo ${domain} | grep '.*\..*')" ]; then
      echo "Your Domain ${domain} is invalid!"
      exit 1
    else
      echo "Added virtual host ${domain}"
    fi

if [ -e /usr/local/nginx/conf/vhost/ ];then
echo add ok
else
mkdir -p /usr/local/nginx/conf/vhost
fi

if [ -e ${webdir}/${domain} ];then
echo ok
else
mkdir -p ${webdir}/${domain}
fi

if [ -e /usr/local/nginx/conf/vhost/${domain}.conf ];then
confbk=`date "+%Y-%m-%d_%H:%M:%S"`
cp /usr/local/nginx/conf/vhost/${domain}.conf /usr/local/nginx/conf/vhost/${domain}.conf.${confbk}
fi

  cat > /usr/local/nginx/conf/vhost/${domain}.conf << "EOF"
   server {
if ($http_user_agent ~* (ApacheBench|webbench|HttpClient|Scrapy)) {
     return 444;
}

if ($http_user_agent ~ "FeedDemon|Indy Library|WinHttp|Alexa Toolbar|AskTbFXTV|AhrefsBot|Python-urllib|Jullo|Feedly|jaunty|Java|ZmEu|CrawlDaddy|Microsoft URL Control|^$" ) {
     return 444;             
}

if ($request_uri ~* (.*)\.(bak|mdb|db|sql)$){
           return 444;
}
if ($request_method !~ ^(GET|HEAD|POST)$) {
    return 403;
}
if ($query_string ~ "[a-zA-Z0-9_]=http://") { return 444; }
if ($query_string ~ "[a-zA-Z0-9_]=(\.\.//?)+") { return 444; }
if ($query_string ~ "[a-zA-Z0-9_]=/([a-z0-9_.]//?)+") { return 444; }

if ($request_uri ~* "[+|(%20)]select[+|(%20)]") { return 444; }
if ($request_uri ~* "[+|(%20)]delete[+|(%20)]") { return 444; }
if ($request_uri ~* "[+|(%20)]update[+|(%20)]") { return 444; }
if ($request_uri ~* "[+|(%20)]insert[+|(%20)]") { return 444; }

if ($query_string ~ "(<|%3C).*script.*(>|%3E)") { return 444; }

    listen 80;
    server_name domain;
    access_log logdir/domain_nginx.log combined;
    error_log  logdir/domain_nginx.error.log  error;  
    root webdir/domain;
    index index.html index.htm index.php;
    location /nginx_status {
        stub_status on;
        access_log off;
        allow 127.0.0.1;
        deny all;
                           }

  location ~ .mp4$ {
  mp4;
  mp4_buffer_size 4M;
  mp4_max_buffer_size 10M;
                   }
 location ~ \.php$ {
                    fastcgi_pass   127.0.0.1:9000;
                    fastcgi_index  index.php;
                    fastcgi_param  SCRIPT_FILENAME $document_root$fastcgi_script_name;
                    include        fastcgi_params;
            }
  location ~(tweentyfourteen|twentyeleven|twentyfifteen|twentyten|twentytwelve)/(.*)\.php  {return 400;}
  location ~ .*\.(gif|jpg|jpeg|png|bmp|swf|flv|ico)$ {
        expires 30d;
        access_log off;
        }
  location ~ .*\.(js|css)?$ {
        expires 7d;
        access_log off;
        }
location = /favicon.ico {
	log_not_found off;
	access_log off;
}

# Deny all attempts to access hidden files such as .htaccess, .htpasswd, .DS_Store (Mac).
location ~ /\. {
	deny all;
}

# Deny access to any files with a .php extension in the uploads directory
location ~* /(?:uploads|files)/.*\.php$ {
	deny all;
}
    }
EOF

sed -i "s@logdir@${logdir}@g" /usr/local/nginx/conf/vhost/${domain}.conf
sed -i "s@webdir@${webdir}@g" /usr/local/nginx/conf/vhost/${domain}.conf
sed -i "s@domain@${domain}@g" /usr/local/nginx/conf/vhost/${domain}.conf
chown www.www ${webdir}/${domain}
service nginx restart
########################################################################
  elif [[ ! ${https_flag} =~ ^[y,n]$ ]]; then
        echo "input error! Please only input 'y' or 'n'"
  fi
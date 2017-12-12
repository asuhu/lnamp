install_jdk(){
if ! which wget;then yum -y install wget;fi
wget --no-check-certificate -c --header "Cookie: oraclelicense=accept-securebackup-cookie" http://download.oracle.com/otn-pub/java/jdk/8u151-b12/e758a0de34e24606bca991d704f6dcbf/jdk-8u151-linux-x64.tar.gz
mkdir -p /usr/java/
tar -zxf jdk-8u151-linux-x64.tar.gz -C /usr/java/

cat >> /etc/profile << "EOF"
export JAVA_HOME=/usr/java/jdk1.8.0_151
export PATH=$JAVA_HOME/bin:$PATH
export CLASSPATH=.:$JAVA_HOME/jre/lib/rt.jar:$JAVA_HOME/lib/dt.jar:$JAVA_HOME/lib/tools.jar
EOF

source /etc/profile
java -version
}

install_tomcat(){
if ! which wget;then yum -y install wget;fi
if ! which gcc;then yum -y install gcc;fi
if ! which curl;then yum -y install curl;fi
#判断国内国外
cd ~
if ping -c 1 216.58.200.4 >/dev/null;then
wget http://archive.apache.org/dist/tomcat/tomcat-8/v8.5.24/bin/apache-tomcat-8.5.24.tar.gz
else
wget https://mirrors.tuna.tsinghua.edu.cn/apache/tomcat/tomcat-8/v8.5.24/bin/apache-tomcat-8.5.24.tar.gz
fi

tar -zxvf apache-tomcat-8.5.24.tar.gz -C /usr/local;rm -rf apache-tomcat-8.5.24-src.tar.gz
mv /usr/local/apache-tomcat-8.5.24 /usr/local/tomcat

#/usr/local/tomcat/bin/startup.sh
#/usr/local/tomcat/bin/shutdown.sh

#cat >> /usr/local/tomcat/bin/setclasspath.sh <<  "EOF"
#export JAVA_HOME=/usr/java/jdk1.8.0_151
#export PATH=$JAVA_HOME/bin:$PATH
#export CLASSPATH=.:$JAVA_HOME/jre/lib/rt.jar:$JAVA_HOME/lib/dt.jar:$JAVA_HOME/lib/tools.jar
#EOF


cat >  /etc/init.d/tomcat << "EOF"
#!/bin/bash
# description: Tomcat Start Stop Restart
# processname: tomcat
# chkconfig: 2345 20 80
   JAVA_HOME=/usr/java/jdk1.8.0_151
   export JAVA_HOME
   PATH=$JAVA_HOME/bin:$PATH
   export PATH
   CATALINA_HOME=/usr/local/tomcat

   case $1 in
   start)
     sh $CATALINA_HOME/bin/startup.sh
   ;;
   stop)
     sh $CATALINA_HOME/bin/shutdown.sh
   ;;
   restart)
     sh $CATALINA_HOME/bin/shutdown.sh
     sh $CATALINA_HOME/bin/startup.sh
   ;;
   *)
    echo $"Usage: $0 {start|stop|restart}"
    exit 1
   ;;
   esac
   exit 0
EOF

chmod +x /etc/init.d/tomcat
chkconfig --add tomcat

    id -u tomcat >/dev/null 2>&1
    [ $? -ne 0 ] && useradd -M -s /sbin/nologin tomcat;
    chown tomcat.tomcat -R /usr/local/tomcat;

sed -i 's/8080/8081/g' /usr/local/tomcat/conf/server.xml
}
install_jdk
install_tomcat

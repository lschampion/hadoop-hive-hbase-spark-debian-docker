#!/bin/bash

# reboot sshd service
/etc/init.d/sshd restart

# https://blog.csdn.net/jmx_bigdata/article/details/98506875
# Sqoop报错：ERROR Could not register mbeans java.security.AccessControlException: access denied
sed -i '/};/i permission javax.management.MBeanTrustPermission "register";' ${JAVA_HOME}/jre/lib/security/java.policy

# Sqoop报警告hcatalog does not exist!...accumulo does not exist!解决方案
sed -i 's/Warning: $HCAT_HOME does not exist! HCatalog jobs will fail./$HCAT_HOME does not exist!/g' ${SQOOP_HOME}/bin/configure-sqoop
sed -i 's/Warning: $ACCUMULO_HOME does not exist! Accumulo imports will fail./$ACCUMULO_HOME does not exist!/g' ${SQOOP_HOME}/bin/configure-sqoop


# ping服务
auto_ping(){
# ping一次该ip, 超时设置1s(如果1s内没ping通，就停止ping)
  if ping -c 1 -w 1 $1 > /dev/null;then
    echo "ping $1 success"
	return 0
  else
    echo "ping $1 fail"
	return -1
  fi
}

# auto ssh function
# 首次连接自动输入yes/no，后数据password，非首次直接输入password
auto_ssh(){
username=$1
password=$2
hostname=$3
/usr/bin/expect <<EOF
set timeout 10
spawn ssh-copy-id -i /root/.ssh/id_rsa.pub $username@$hostname
expect {
            #first connect, no public key in ~/.ssh/known_hosts
            "*yes/no*" {
            send "yes\r"
            expect "*password*"
                send "$password\r"
            }
            #already has public key in ~/.ssh/known_hosts
            "*password*" {
                send "$password\r"
            }
            "Now try logging into the machine" {
                #it has authorized, do nothing!
            }
        }
expect eof
EOF
}

# alpine root密码
ROOT_PWD=123456
# auto_ssh root 123456 master
# ${HADOOP_SERVERS_HOSTNAME}和${ROOT_PWD} 从docker-compose.yml获取所有hadoop集群主机的hostname
# 通过修改以下重试次数和休眠间隔时间可以避免不成功情况。
ssh_retry=30
ssh_sleep_secs=10
for hostname in ${HADOOP_SERVERS_HOSTNAME} ; do
  while [ ${ssh_retry} -gt 0 ] ; do
    auto_ping $hostname
	# 获取ping结果
	res=$?
    if [ $res -eq 0 ] ; then
      echo "enter sending id_rsa loop,now hostname is $hostname"
      auto_ssh root ${ROOT_PWD} $hostname
      break
	else
	  sleep $ssh_sleep_secs
	  continue
	fi
  done
done


# 由于datanode是多个，每个的UI的端口需要不同，因此需要从dock-compose.yml动态传入
if [ -n "${HADOOP_DATANODE_UI_PORT}" ]; then
  echo "Replacing default datanode UI port 9864 with ${HADOOP_DATANODE_UI_PORT}"
  # 注意</configuration>必须是最后一行，否则最在</configuration>后边插入内容
  # 检查到有此配置了，就不在插入或者更新
  if [ -z "`grep "dfs.datanode.http.address" ${HADOOP_CONF_DIR}/hdfs-site.xml`" ]; then
    p="<property><name>dfs.datanode.http.address</name><value>0.0.0.0:${HADOOP_DATANODE_UI_PORT}</value></property>"
    sed -i "$ i\  $p  " ${HADOOP_CONF_DIR}/hdfs-site.xml
  fi
fi

# HADOOP_HOME is your hadoop root directory after unpack the binary package.
HADOOP_CLASSPATH_FUNC=`$HADOOP_HOME/bin/hadoop classpath`
export HADOOP_CLASSPATH=$HADOOP_CLASSPATH:$HADOOP_CLASSPATH_FUNC


# 注意Hadoop的 start-all.sh 在alpine会报错，不可用！
if [ "${HADOOP_NODE}" == "namenode" ]; then
  echo "Starting Hadoop name node..."
  # yes | hdfs namenode -format
  # initialize namenode on the first startup
  CONTAINER_ALREADY_STARTED="CONTAINER_ALREADY_STARTED_PLACEHOLDER"
  if [ ! -e $CONTAINER_ALREADY_STARTED ]; then
      touch $CONTAINER_ALREADY_STARTED
      echo "-- First container startup : format namenade--"
  	  hdfs namenode -format
  else
      echo "-- Not first container startup --"
  fi
  hdfs --daemon start namenode  || echo "error: start namenode fail"
  hdfs --daemon start secondarynamenode || echo "error: start secondarynamenode fail on `hostname`"
  yarn --daemon start resourcemanager  || echo "error: start resourcemanager fail on `hostname`"
  mapred --daemon start historyserver  || echo "error: start historyserver fail on `hostname`"
fi
if [ "${HADOOP_NODE}" == "datanode" ]; then
  echo "Starting Hadoop data node..."
  hdfs --daemon start datanode  || echo "error: start datanode fail on `hostname`"
  yarn --daemon start nodemanager  || echo "error: start nodemanager fail on `hostname`"
fi

if [ -n "${HIVE_CONFIGURE}" ]; then
  echo "Configuring Hive..."
  schematool -dbType postgres -initSchema
  # Start metastore service.
  hive --service metastore &
  # JDBC Server.
  hiveserver2 &
fi

if [ -z "${SPARK_MASTER_ADDRESS}" ]; then
  echo "Starting Spark master node..."
  # Create directory for Spark logs
  SPARK_LOGS_HDFS_PATH=/log/spark
  if ! hadoop fs -test -d "${SPARK_LOGS_HDFS_PATH}"
  then
    hadoop fs -mkdir -p  ${SPARK_LOGS_HDFS_PATH}
    hadoop fs -chmod -R 755 ${SPARK_LOGS_HDFS_PATH}/
  fi

  # Spark on YARN
  SPARK_JARS_HDFS_PATH=/spark-jars
  if ! hadoop fs -test -d "${SPARK_JARS_HDFS_PATH}"
  then
    hadoop dfs -copyFromLocal "${SPARK_HOME}/jars" "${SPARK_JARS_HDFS_PATH}"
  fi
  "${SPARK_HOME}/sbin/start-master.sh" -h master &
  "${SPARK_HOME}/sbin/start-history-server.sh" &
else
  echo "Starting Spark slave node..."
  "${SPARK_HOME}/sbin/start-slave.sh" "${SPARK_MASTER_ADDRESS}" &
fi


TEZ_JARS_HDFS_PATH=/tez
if ! hadoop fs -test -f "${TEZ_JARS_HDFS_PATH}/tez.tar.gz"; then
  # 首次执行创建tez目录推送tez jar包
  hadoop dfs -mkdir -p "${TEZ_JARS_HDFS_PATH}"
  hadoop dfs -put "${TEZ_HOME}/share/tez.tar.gz" "${TEZ_JARS_HDFS_PATH}"
fi


# Tez jar export for hive
for jar in `ls $TEZ_HOME |grep jar`; do
    export HADOOP_CLASSPATH=$HADOOP_CLASSPATH:$TEZ_HOME/$jar
done
for jar in `ls $TEZ_HOME/lib`; do
    export HADOOP_CLASSPATH=$HADOOP_CLASSPATH:$TEZ_HOME/lib/$jar
done

# test hadoop zookeeper alive function，通过测试端口是否可用，确认服务状态 
wait_until() {
    local hostname=${1?}
    local port=${2?}
    local retry=${3:-100}
    local sleep_secs=${4:-2}
    local address_up=0
    while [ ${retry} -gt 0 ] ; do
        echo  "Waiting until ${hostname}:${port} is up ... with remaining retry times: ${retry}"
        if nc -z ${hostname} ${port}; then
            address_up=1
            break
        fi
        retry=$((retry-1))
        sleep ${sleep_secs}
    done
    if [ $address_up -eq 0 ]; then
        echo "GIVE UP waiting until ${hostname}:${port} is up! "
        return 0
    else
     return 1
	fi
}


# 把regionserver 写入配置文件方便启用一键脚本，通过start-hbase.sh脚本启动集群会使用到regionservers文件
echo '' > "${HBASE_CONF_DIR}/regionservers"
for hostname in ${HBASE_REGIONSERVER_HOSTNAME};do
  echo "$hostname"  >> "${HBASE_CONF_DIR}/regionservers"
done

# zoo_alive大于零，则认为zk已经启动成功，toTo: 通过zkServer.sh status可以确认zk集群实际状态
zoo_alive=0
for zoo_hostname in ${ZOO_SERVERS_HOSTNAME};do
  echo "hbase try nc $zoo_hostname"
  # 等待zookeep启动
  wait_until ${zoo_hostname} 2181 1000000 15
  res=$?
  zoo_alive=$((zoo_alive+res))
  if [ $zoo_alive -gt 0 ] ;then
    echo "zookeeper port has been connected!"
    break
  fi
done

# 判断hadoop是否启动完成
hadoop_alive=0
wait_until master 9000 1000000 15
res=$?
if (( $res==1 )) ; then hadoop_alive=1; fi


# HBase 集群启动方式（一）
# SSH已经配置好，以下脚本可以使用。
#if [ $zoo_alive -gt 0 ] ; then
#  echo "zookeeper is alive ready to start hbase"
#  for role in ${HBASE_ROLE}; do
#    if [ "${role}" == "hmaster" ]; then
#      echo "`date` Starting hbase cluster on `hostname`" 
#      exec start-hbase.sh
#    fi
#    if [ "${role}" == "regionserver" ]; then
#      echo "`date` will start hbase regionserver on hmaster node" 
#    fi
#    if [ "${role}" == "thrift" ]; then
#      echo "`date` Starting hbase thrift on `hostname`" 
#      exec hbase-daemon.sh start thrift
#    fi
#    if [ "${HBASE_NODE_EXTRA}" == "hmaster-backup" ]; then
#      exec hbase master --backup start
#    fi
#  done
#fi


# HBase 集群启动方式（二）
if [ $zoo_alive -gt 0 && $hadoop_alive -gt 0 ] ; then
  echo "zookeeper is alive ready to start hbase"
  for role in ${HBASE_ROLE}; do
    # HBase master startup
    if [ "${role}" == "hmaster" ]; then
        wait_until ${HADOOP_NNAMENADE_HOSTNAME} 9000 
        echo "`date` Starting hmaster main on `hostname`" 
        echo "`ulimit -a`" 2>&1
        hdfs dfs -ls /tmp > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            hdfs dfs -mkdir -p /tmp
            hdfs dfs -chmod 1777 /tmp
        fi
        hdfs dfs -ls /user > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            hdfs dfs -mkdir -p /user/hdfs
            hdfs dfs -chmod 755 /user
        fi
        hdfs dfs -ls /hbase > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            hdfs dfs -mkdir -p /hbase
            hdfs dfs -chown hbase:hbase /hbase
        fi
        hbase-daemon.sh start master || echo "error: start hmaster fail on `hostname`"
    fi
    # HBase regionserver startup
    if [ "${role}" == "regionserver" ]; then
        wait_until ${HBASE_MASTER_HOSTNAME} 16000 
        echo "`date` Starting regionserver on `hostname`" 
        echo "`ulimit -a`" 2>&1
        hbase-daemon.sh start regionserver || echo "error: start regionserver fail on `hostname`"
    fi
    if [ "${role}" == "thrift" ]; then
	    # 对于regionserver 只取最左边第一个hostname
        wait_until ${HBASE_REGIONSERVER_HOSTNAME%% *} 16020
        echo "`date` Starting thrift on `hostname`" 
        echo "`ulimit -a`" 2>&1
        hbase-daemon.sh start thrift2 || echo "error: start thrift2 fail on `hostname`"
    fi
	if [ "${role}" == "hmaster_backup" ]; then
        echo "`date` Starting hmaster backup on `hostname`" 
        echo "`ulimit -a`" 2>&1 
        hbase-daemon.sh start master --backup || echo "error: start hmaster-backup fail on `hostname`"
    fi
  done
else
  echo "zookeeper is not alive, start hbase cluster fail"
fi


echo "All initializations finished!"

# Blocking call to view all logs. This is what won't let container exit right away.
/scripts/parallel_commands.sh "scripts/watchdir ${HADOOP_LOG_DIR}" "scripts/watchdir ${SPARK_LOG_DIR}" "scripts/watchdir ${HBASE_LOG_DIR}"




function stop_server() {
  echo "container terminating,ready to stop all bigdata service"
# Stop hbase
  for role in ${HBASE_ROLE}; do
    if [ "${role}" == "hmaster" ]; then
        hbase-daemon.sh stop master || echo "error: stop hmaster fail on `hostname`"
    fi
    if [ "${role}" == "regionserver" ]; then
        hbase-daemon.sh stop regionserver || echo "error: stop regionserver fail on `hostname`"
    fi
    if [ "${role}" == "thrift" ]; then
        hbase-deamon.sh stop thrift2 || echo "error: stop thrift2 fail on `hostname`"
    fi
    if [ "${role}" == "hmaster_backup" ]; then
        hbase-daemon.sh stop master --backup || echo "error: stop hmaster-backup fail on `hostname`"
    fi
  done
# Stop hadoop
  if [ "${HADOOP_NODE}" == "namenode" ]; then
    hdfs namenode -format
    hdfs --daemon stop namenode
    hdfs --daemon stop secondarynamenode
    yarn --daemon stop resourcemanager
    mapred --daemon stop historyserver
  fi
  if [ "${HADOOP_NODE}" == "datanode" ]; then
      hdfs --daemon stop datanode
      yarn --daemon stop nodemanager
  fi
}

 
# 捕捉docker stop时发送的SIGTERM信号
trap 'stop_server' SIGTERM          
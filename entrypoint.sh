#!/bin/bash

# reboot sshd service,must refresh ssh service
/etc/init.d/sshd restart

# https://blog.csdn.net/jmx_bigdata/article/details/98506875
# Sqoop报错：ERROR Could not register mbeans java.security.AccessControlException: access denied
sed -i '/};/i permission javax.management.MBeanTrustPermission "register";' ${JAVA_HOME}/jre/lib/security/java.policy

# Sqoop报警告hcatalog does not exist!...accumulo does not exist!解决方案
sed -i 's/Warning: $HCAT_HOME does not exist! HCatalog jobs will fail./$HCAT_HOME does not exist!/g' ${SQOOP_HOME}/bin/configure-sqoop
sed -i 's/Warning: $ACCUMULO_HOME does not exist! Accumulo imports will fail./$ACCUMULO_HOME does not exist!/g' ${SQOOP_HOME}/bin/configure-sqoop


# ping函数
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

ssh_service(){
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
}

# HADOOP_HOME is your hadoop root directory after unpack the binary package.
HADOOP_CLASSPATH_FUNC=`$HADOOP_HOME/bin/hadoop classpath`
export HADOOP_CLASSPATH=$HADOOP_CLASSPATH:$HADOOP_CLASSPATH_FUNC


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


# initialize settings
CONTAINER_ALREADY_STARTED=/CONTAINER_ALREADY_STARTED_PLACEHOLDER
if [ ! -e $CONTAINER_ALREADY_STARTED ]; then
  # init ssh auto configuration
  ssh_service
  if [ "${HADOOP_NODE}" = "namenode" ]; then
    # yes | hdfs namenode -format
    # initialize namenode on the first startup
    echo "-- container first startup : format namenade--"
  	hdfs namenode -format
	echo " container first startup : Configuring Hive..."
    schematool -dbType postgres -initSchema
    echo "-- container first startup : init trino configuration--"
    # coordinator and work identify itself using different config file
    mv "${TRINO_CONF_DIR}/config.properties.coordinator" "${TRINO_CONF_DIR}/config.properties"   
  elif [ "${HADOOP_NODE}" = "datanode" ]; then 
    mv "${TRINO_CONF_DIR}/config.properties.worker" "${TRINO_CONF_DIR}/config.properties" 
  fi

  # use random number to identify trino node ID
  sed -i "s/node.id=.*/node.id=$RANDOM/g" "${TRINO_CONF_DIR}/node.properties"
  
  echo "-- First container startup : init livy conf --"
  # Configure Livy based on environment variables
  if [[ -n "${SPARK_MASTER}" ]]; then
    echo "livy.spark.master=${SPARK_MASTER}" >> "${LIVY_CONF_DIR}/livy.conf"
  fi
  if [[ -n "${SPARK_DEPLOY_MODE}" ]]; then
    echo "livy.spark.deploy-mode=${SPARK_DEPLOY_MODE}" >> "${LIVY_CONF_DIR}/livy.conf"
  fi
  if [[ -n "${LOCAL_DIR_WHITELIST}" ]]; then
    echo "livy.file.local-dir-whitelist=${LOCAL_DIR_WHITELIST}" >> "${LIVY_CONF_DIR}/livy.conf"
  fi
  if [[ -n "${ENABLE_HIVE_CONTEXT}" ]]; then
    echo "livy.repl.enable-hive-context=${ENABLE_HIVE_CONTEXT}" >> "${LIVY_CONF_DIR}/livy.conf"
  fi
  if [[ -n "${LIVY_HOST}" ]]; then
    echo "livy.server.host=${LIVY_HOST}" >> "${LIVY_CONF_DIR}/livy.conf"
  fi
  if [[ -n "${LIVY_PORT}" ]]; then
    echo "livy.server.port=${LIVY_PORT}" >> "${LIVY_CONF_DIR}/livy.conf"
  fi
else
  echo "-- Not container first startup --"
fi


# 注意Hadoop的 start-all.sh 在alpine会报错，不可用！
if [ "${HADOOP_NODE}" = "namenode" ]; then
  echo "Starting Hadoop name node..."
  hdfs --daemon start namenode  || echo "error: start namenode fail"
  hdfs --daemon start secondarynamenode || echo "error: start secondarynamenode fail on `hostname`"
  yarn --daemon start resourcemanager  || echo "error: start resourcemanager fail on `hostname`"
  mapred --daemon start historyserver  || echo "error: start historyserver fail on `hostname`"
  # Start metastore service.
  hive --service metastore &
  # JDBC Server.
  hiveserver2 &
elif [ "${HADOOP_NODE}" = "datanode" ]; then
  echo "Starting Hadoop data node..."
  hdfs --daemon start datanode  || echo "error: start datanode fail on `hostname`"
  yarn --daemon start nodemanager  || echo "error: start nodemanager fail on `hostname`"
fi


## 阻塞-等待 hdfs 启动
#wait_until master 9000 1000000 15
## 等待 hdfs 离开SAFE_MODE
#safe_mode_flag="Safe mode is ON"
#while [[ "$safe_mode_flag" != "" ]]
#do
#  safe_mode_flag=$( hdfs dfsadmin -safemode get | grep "Safe mode is ON" )
#  sleep 8
#  if [[ "$safe_mode_flag" != "" ]]; then 
#     echo "WARN: HADOOP STATUS: Safe mode is ON"
#  else 
#     echo "INFO: HADOOP STATUS: Safe mode is OFF"
#  fi
#done


# blocking until hdfs is ready to use!
# 监测hdfs 根目录是否存在，如果存在则放行否则一直循环等待。
hadoop_unalive=1
while [ $hadoop_unalive -ne 0 ] ; do
  hadoop fs -test -d /
  hadoop_unalive=$?
  sleep 5
  echo 'reach hdfs  fail,retrying !??'
done
echo 'reach hdfs success !!!'

if [ ! -e $CONTAINER_ALREADY_STARTED ]; then
  # first statup with hdfs ready
  if [ "${HADOOP_NODE}" = "namenode" ]; then
	echo "-- container first startup : init hbase dirs configuration--"
	hdfs dfs -mkdir -p /tmp /user/hdfs /hbase
    hdfs dfs -chmod 755 /tmp /user/hdfs /hbase

	# 把regionserver 写入配置文件方便启用一键脚本，通过start-hbase.sh脚本启动集群会使用到regionservers文件
    echo '' > "${HBASE_CONF_DIR}/regionservers"
    for hostname in ${HBASE_REGIONSERVER_HOSTNAME}; do
      echo "$hostname"  >> $HBASE_CONF_DIR/regionservers
    done

	# Create directory for Spark logs
    SPARK_LOGS_HDFS_PATH=/log/spark
    SPARK_JARS_HDFS_PATH=/spark-jars
    hadoop fs -mkdir -p  $SPARK_LOGS_HDFS_PATH $SPARK_JARS_HDFS_PATH
    hadoop fs -chmod -R 755 $SPARK_LOGS_HDFS_PATH $SPARK_JARS_HDFS_PATH
    # Spark on YARN
    hdfs dfs -put $SPARK_HOME/jars/* $SPARK_JARS_HDFS_PATH/
    # Tez JAR
    TEZ_JARS_HDFS_PATH=/tez
    hadoop dfs -mkdir -p $TEZ_JARS_HDFS_PATH
    hadoop dfs -put $TEZ_HOME/share/tez.tar.gz $TEZ_JARS_HDFS_PATH
    fi
 fi


if [ -z "${SPARK_MASTER_ADDRESS}" ]; then
  echo "Starting Spark master node..."
  "${SPARK_HOME}/sbin/start-master.sh" -h master &
  "${SPARK_HOME}/sbin/start-history-server.sh" &
else
  echo "Starting Spark slave node..."
  "${SPARK_HOME}/sbin/start-slave.sh" "${SPARK_MASTER_ADDRESS}" &
fi

# Tez jar export for hive,must use source not sh 
for jar in `ls $TEZ_HOME |grep jar`; do
    export HADOOP_CLASSPATH=$HADOOP_CLASSPATH:$TEZ_HOME/$jar
done
for jar in `ls $TEZ_HOME/lib`; do
    export HADOOP_CLASSPATH=$HADOOP_CLASSPATH:$TEZ_HOME/lib/$jar
done


# zoo_alive大于零，则认为zk已经启动成功，toTo: 通过zkServer.sh status可以确认zk集群实际状态
zoo_alive=0
for zoo_hostname in ${ZOO_SERVERS_HOSTNAME};do
  echo "try nc $zoo_hostname"
  # 等待zookeep启动
  wait_until ${zoo_hostname} 2181 1000000 15
  res=$?
  zoo_alive=$((zoo_alive+res))
  if [ $zoo_alive -gt 0 ] ;then
    echo "zookeeper port can be connected!"
    break
  fi
done

# HBase 集群启动方式（一）
# SSH已经配置好，以下脚本可以使用。
#if [ $zoo_alive -gt 0 ] ; then
#  echo "zookeeper is alive ready to start hbase"
#  for role in ${HBASE_ROLE}; do
#    if [ "${role}" = "hmaster" ]; then
#      echo "`date` Starting hbase cluster on `hostname`" 
#      exec start-hbase.sh
#    fi
#    if [ "${role}" = "regionserver" ]; then
#      echo "`date` will start hbase regionserver on hmaster node" 
#    fi
#    if [ "${role}" = "thrift" ]; then
#      echo "`date` Starting hbase thrift on `hostname`" 
#      exec hbase-daemon.sh start thrift
#    fi
#    if [ "${HBASE_NODE_EXTRA}" = "hmaster-backup" ]; then
#      exec hbase master --backup start
#    fi
#  done
#fi

# HBase 集群启动方式（二）
if [ $zoo_alive -gt 0 ] ; then
  echo "zookeeper is alive ready to start hbase"
  for role in ${HBASE_ROLE}; do
    # HBase master startup
    if [ "${role}" = "hmaster" ]; then
        echo "`date` Starting hmaster main on `hostname`" 
        hbase-daemon.sh start master || echo "error: start hmaster fail on `hostname`"
    fi
    # HBase regionserver startup
    if [ "${role}" = "regionserver" ]; then
        wait_until ${HBASE_MASTER_HOSTNAME} 16000 
        echo "`date` Starting regionserver on `hostname`" 
        hbase-daemon.sh start regionserver || echo "error: start regionserver fail on `hostname`"
    fi
    if [ "${role}" = "thrift" ]; then
	    # 对于regionserver 只取最左边第一个hostname
        wait_until ${HBASE_REGIONSERVER_HOSTNAME%% *} 16020
        echo "`date` Starting thrift on `hostname`" 
        hbase-daemon.sh start thrift2 || echo "error: start thrift2 fail on `hostname`"
    fi
	if [ "${role}" = "hmaster_backup" ]; then
        echo "`date` Starting hmaster backup on `hostname`" 
        hbase-daemon.sh start master --backup || echo "error: start hmaster-backup fail on `hostname`"
    fi
  done
else
  echo "zookeeper is not alive, start hbase cluster fail"
fi


# 启动 livy-server
# LIVY_SERVER is environment variable from outside
not_running_flag="not"
while [[ "$not_running_flag" != "" && "$LIVY_SERVER" == "true" ]]
do
  echo "entry loop,try to start livy-server on $HOSTNAME"
  # 启动 livy 服务
  # "$LIVY_HOME/bin/livy-server" $@
  $LIVY_HOME/bin/livy-server start &
  sleep 5
  not_running_flag=$( $LIVY_HOME/bin/livy-server status | grep "not" )
done

echo "All initializations finished!"

# generate file so next time start up would not run this segment code again
touch $CONTAINER_ALREADY_STARTED


# Blocking call to view all logs. This is what won't let container exit right away.
/scripts/parallel_commands.sh "/scripts/watchdir ${HADOOP_LOG_DIR}" "/scripts/watchdir ${SPARK_LOG_DIR}" "/scripts/watchdir ${HBASE_LOG_DIR}"

####################### 以下暂时没有生效，暂时未排查原因 ########################
function stop_server() {
  echo "container terminating,ready to stop all bigdata service"
# Stop hbase
  for role in ${HBASE_ROLE}; do
    if [ "${role}" = "hmaster" ]; then
        hbase-daemon.sh stop master || echo "error: stop hmaster fail on `hostname`"
    fi
    if [ "${role}" = "regionserver" ]; then
        hbase-daemon.sh stop regionserver || echo "error: stop regionserver fail on `hostname`"
    fi
    if [ "${role}" = "thrift" ]; then
        hbase-deamon.sh stop thrift2 || echo "error: stop thrift2 fail on `hostname`"
    fi
    if [ "${role}" = "hmaster_backup" ]; then
        hbase-daemon.sh stop master --backup || echo "error: stop hmaster-backup fail on `hostname`"
    fi
  done
# Stop hadoop
  if [ "${HADOOP_NODE}" = "namenode" ]; then
    hdfs namenode -format
    hdfs --daemon stop namenode
    hdfs --daemon stop secondarynamenode
    yarn --daemon stop resourcemanager
    mapred --daemon stop historyserver
  fi
  if [ "${HADOOP_NODE}" = "datanode" ]; then
      hdfs --daemon stop datanode
      yarn --daemon stop nodemanager
  fi
}


# 捕捉docker stop时发送的SIGTERM信号
trap 'stop_server' SIGTERM          
# Big data playground: Hadoop + Hive + HBase + Spark

Base Docker image with just essentials: Hadoop, Hive ,HBase and Spark.

## Software

* [Hadoop 3.2.0](http://hadoop.apache.org/docs/r3.2.0/) in Fully Distributed (Multi-node) Mode
* [Hive 3.1.2](http://hive.apache.org/) with HiveServer2 exposed to host.
* [Spark 2.4.5](https://spark.apache.org/docs/2.4.5/) in YARN mode (Spark Scala, PySpark and SparkR)
* [Hbase 2.3.6](https://hbase.apache.org/)  in Fully Distributed (Multi-node) Mode
* [Sqoop 1.4.7 ](https://sqoop.apache.org/)

## Usage

Take a look [at this repo](https://github.com/lschampion/bigdata-docker-compose.git)
to see how I use it as a part of a Docker Compose cluster.

User and password in alpine: 123456

SSH auto configed in hadoop cluster

HBase auto start after zookeeper and HDFS namenode started

Hive JDBC port is exposed to host:
* URI: `jdbc:hive2://localhost:10000`
* Driver: `org.apache.hive.jdbc.HiveDriver` (org.apache.hive:hive-jdbc:3.1.2)
* User and password: unused.

### Scripts

`build_env_base_image.sh ` helps build env image, which contain environment variables and component version information.

`build_app_base_image.sh` help build app image, which would participate in docker-compose.

use both above build scripts  like

```shell
sh build_env/app_base_image.sh your_version
```

`rm_none_images.sh` helps removing `<none>` tag of images in developing. use `docker image ps ` to checkout which image is created.

`tar-source-files/file_list.txt` show which local package may use. refering it when build your image

`get_hadoop_container_id.sh` help when you want to find the running hadoop container IDs.

`/scripts/ssh_auto_configer` of directory contains SSH configing scripts:

```plain
auto_ssh.sh  # single script to auto config ssh with several params
eliminate_pub_key.sh  
id_rsa_gen.sh  
ping_test.sh  
sshd_restart.start # sshd auto run for alpine,maybe not run.   
ssh_service.sh # Aggregated script to auto config ssh
```

`./scripts/format_hdfs.sh` could resolve clusterID inconsistent error, which caused by formating HDFS without correct operation.

config file stored in `.conf` directory,make sure that chechout this directory before build image.

###  Special Instructions:

hbase startup need zookeeper cluster and, it is configed in `hbase-site.xml` . default as follow:

```xml
  <property>
    <!-- 指定 zk 的地址，多个用“,”分割，注意集群模式的HBase 不能在此处制定zookeeper的端口号 -->
    <name>hbase.zookeeper.quorum</name>
    <value>zoo1,zoo2,zoo3</value>
  </property>
```

## Version compatibility notes

* Hadoop 3.2.1 and Hive 3.1.2 are incompatible due to Guava version
mismatch (Hadoop: Guava 27.0, Hive: Guava 19.0). Hive fails with
`java.lang.NoSuchMethodError: com.google.common.base.Preconditions.checkArgument(ZLjava/lang/String;Ljava/lang/Object;)`
* Spark 2.4.4 can not 
[use Hive higher than 1.2.2 as a SparkSQL engine](https://spark.apache.org/docs/2.4.4/sql-data-sources-hive-tables.html)
because of this bug: [Spark need to support reading data from Hive 2.0.0 metastore](https://issues.apache.org/jira/browse/SPARK-13446)
and associated issue [Dealing with TimeVars removed in Hive 2.x](https://issues.apache.org/jira/browse/SPARK-27349).
Trying to make it happen results in this exception:
`java.lang.NoSuchFieldError: HIVE_STATS_JDBC_TIMEOUT`.
When this is fixed in Spark 3.0, it will be able to use Hive as a
backend for SparkSQL. Alternatively you can try to downgrade Hive :)

## Maintaining

* Docker file code linting:  `docker run --rm -i hadolint/hadolint < Dockerfile`
* [To trim the fat from Docker image](https://github.com/wagoodman/dive)

## TODO
* Upgrade spark to 3.0
* When upgraded, enable Spark-Hive integration.


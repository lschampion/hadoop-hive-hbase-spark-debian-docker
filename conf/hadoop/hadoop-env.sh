# The java implementation to use. By default, this environment
# variable is REQUIRED on ALL platforms except OS X!
export JAVA_HOME=/usr/lib/jvm/java-1.8-openjdk
# kudi need `$HADOOP_HOME/bin/hadoop classpath`
export HADOOP_CLASSPATH=`$HADOOP_HOME/bin/hadoop classpath`

for jar in `ls $TEZ_HOME |grep jar`; do
    export HADOOP_CLASSPATH=$HADOOP_CLASSPATH:$TEZ_HOME/$jar
done
for jar in `ls $TEZ_HOME/lib`; do
    export HADOOP_CLASSPATH=$HADOOP_CLASSPATH:$TEZ_HOME/lib/$jar
done


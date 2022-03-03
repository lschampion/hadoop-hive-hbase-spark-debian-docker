#!/bin/bash
echo "for resolving clusterID inconsistent error, ready to format hdfs"
hdfs --daemon stop namenode
rm -rf /dfs/name/current
ssh worker1 "/usr/program/hadoop/bin/hdfs --daemon stop datanode"
ssh worker1 "rm -rf /dfs/data/current"
ssh worker2 "/usr/program/hadoop/bin/hdfs --daemon stop datanode"
ssh worker2 "rm -rf /dfs/data/current"
yes | hdfs namenode -format
echo "format completed,ready restart hdfs"
hdfs --daemon start namenode
ssh worker1 "/usr/program/hadoop/bin/hdfs --daemon start datanode"
ssh worker2 "/usr/program/hadoop/bin/hdfs --daemon start datanode"

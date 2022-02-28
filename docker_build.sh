#!/bin/bash
version=${1:-1.0}
echo "use version :$version"
docker build -t hadoop-hive-hbase-spark-docker:$version .

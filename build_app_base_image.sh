#!/bin/bash
version=${1:-1.0.0}
echo "use version :$version"
docker build --file ./Dockerfile_app --tag lisacumt/hadoop-hive-hbase-spark-docker:$version .

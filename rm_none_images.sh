#!/bin/bash
# 批量删除的方法:
docker rmi $(docker images | awk '/^<none>/ { print $3 }')

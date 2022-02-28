#!/bin/bash
# ping一次该ip, 超时设置1s(如果1s内没ping通，就停止ping)
if ping -c 1 -w 1 $1 > /dev/null;then
 echo "ping $1 success"
 return 0
else
 echo "ping $1 fail"
 return -1
fi

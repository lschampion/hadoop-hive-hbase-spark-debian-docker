#!/bin/bash
docker ps | grep hadoop | awk '{print $1}'

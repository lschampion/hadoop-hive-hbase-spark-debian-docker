#!/bin/bash
version=${1:-1.0.0}
echo "use version :$version"
docker build --file ./Dockerfile_env --tag lisacumt/bigdata_base_env_img:$version .

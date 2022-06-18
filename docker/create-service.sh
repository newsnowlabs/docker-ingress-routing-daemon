#!/bin/bash

if [ -z "$1" ]; then
  OPTS=("--install")
else
  OPTS=("$@")
fi

docker service create --name=dind --mode=global --mount=type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock newsnowlabs/dind:latest "${OPTS[@]}"

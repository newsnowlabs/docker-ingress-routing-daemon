#!/bin/bash

if [ "$1" = "manager" ]; then
  shift
  
  # Create manager container with autodetected --ingress-gateway-ips
  CMD=(docker run --rm -it --mount=type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock newsnowlabs/dind:latest)
elif [ "$1" = "manager-service" ]; then
  shift
  
  # Create manager service with autodetected --ingress-gateway-ips
  CMD=(docker service create --name=dind --replicas=1 --constraint=node.role==manager --mount=type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock newsnowlabs/dind:latest)
elif [ "$1" = "global-service" ]; then
  shift
  
  # Create global service with hardcoded --ingress-gateway-ips list
  CMD=(docker service create --name=dind-global --mode=global --mount=type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock newsnowlabs/dind:latest --global-service)
else
  echo "Usage: $0 [manager|manager-service|global-service]" >&2
  exit -1
fi

if [ -z "$1" ]; then
  OPTS=("--install")
else
  OPTS=("$@")
fi

${CMD[@]} ${OPTS[@]}

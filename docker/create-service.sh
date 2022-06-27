#!/bin/bash

IMAGE=newsnowlabs/dind:latest

if [ "$1" = "--debug" ]; then
  shift
  
  DOCKER_RUN_OPTS=(--rm -it)
else
  DOCKER_RUN_OPTS=(-d)
fi

if [ "$1" = "manager" ]; then
  shift
  
  # Create manager container with autodetected --ingress-gateway-ips
  CMD=(docker run ${DOCKER_RUN_OPTS[@]} --name=dind --mount=type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock $IMAGE)
elif [ "$1" = "manager-service" ]; then
  shift
  
  # Create manager service with autodetected --ingress-gateway-ips
  CMD=(docker service create --name=dind --replicas=1 --constraint=node.role==manager --mount=type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock $IMAGE)
elif [ "$1" = "global-service" ]; then
  shift
  
  # Create global service with hardcoded --ingress-gateway-ips list
  CMD=(docker service create --name=dind-global --mode=global --update-parallelism=0 --env="DOCKER_NODE_HOSTNAME={{.Node.Hostname}}" --mount=type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock $IMAGE --global-service)
elif [ "$1" = "daemon" ]; then
  shift

  # Create DIND daemon container
  CMD=(docker run ${DOCKER_RUN_OPTS[@]} --name=dind-child --privileged --pid=host -v /var/run/docker:/var/run/docker -v /var/run/docker.sock:/var/run/docker.sock $IMAGE --daemon)
else
  echo "Usage: $0 [--debug] [manager|manager-service|global-service|daemon]" >&2
  echo >&2
  exit -1
fi

if [ -z "$1" ]; then
  OPTS=("--install")
else
  OPTS=("$@")
fi

${CMD[@]} ${OPTS[@]}

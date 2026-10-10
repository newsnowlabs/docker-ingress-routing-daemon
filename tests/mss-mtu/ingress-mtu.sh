#!/bin/bash
# Shows how the swarm ingress network's com.docker.network.driver.mtu option maps to the MTU of the
# ingress network interfaces seen by service containers and by ingress_sbox.
# See https://github.com/newsnowlabs/docker-ingress-routing-daemon/issues/43
#
# WARNING: removes and recreates the 'ingress' network and creates/removes a service named 'mtu-test'.
#          Run only on a disposable single-node swarm ('docker swarm init').
#
# Usage: ingress-mtu.sh <mtu|default> [...]
#
#   RESTART_DOCKERD=1 - restart dockerd (as a background process) if ingress network removal remains pending;
#                       observed with Docker 29.8.2, where 'docker network rm ingress' could leave the network
#                       listed but reported as 'not found' until dockerd was restarted.

remove_ingress() {
  docker network rm ingress <<<y >/dev/null 2>&1
  for i in $(seq 20); do
    docker network inspect ingress >/dev/null 2>&1 || return 0
    sleep 1
    docker network rm ingress <<<y >/dev/null 2>&1
  done

  [ "$RESTART_DOCKERD" = 1 ] || { echo "ingress network removal pending; rerun with RESTART_DOCKERD=1" >&2; return 1; }

  pkill dockerd; while pgrep dockerd >/dev/null; do sleep 1; done
  (setsid dockerd >>/tmp/dockerd-ingress-mtu.log 2>&1 &)
  for i in $(seq 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
  docker network rm ingress <<<y >/dev/null 2>&1; sleep 2
  docker network inspect ingress >/dev/null 2>&1 && { echo "ingress network could not be removed (is another service publishing ports?)" >&2; return 1; }
  return 0
}

links() { awk '$2!="lo:" {sub(/[@:].*/,"",$2); printf "%s=%s ", $2, $5}'; }

for MTU in "$@"; do
  docker service rm mtu-test >/dev/null 2>&1
  for i in $(seq 20); do [ -z "$(docker ps -q -f label=com.docker.swarm.service.name=mtu-test)" ] && break; sleep 1; done
  remove_ingress || exit 1

  OPT=(); [ "$MTU" != default ] && OPT=(--opt com.docker.network.driver.mtu=$MTU)
  docker network create --driver overlay --ingress "${OPT[@]}" ingress >/dev/null || exit 1
  docker service create -q --name mtu-test -p 18080:80 busybox:1.36 httpd -f -p 80 >/dev/null 2>&1
  for i in $(seq 30); do CID=$(docker ps -q -f label=com.docker.swarm.service.name=mtu-test | head -n 1); [ -n "$CID" ] && break; sleep 1; done
  NID=$(docker inspect -f '{{.State.Pid}}' $CID)
  INGID=$(docker network inspect ingress -f '{{.ID}}' | cut -c1-10)

  echo "mtu option: $MTU"
  echo "  container (eth0=ingress, eth1=docker_gwbridge): $(nsenter -n -t $NID ip -o link | links)"
  echo "  ingress_sbox:                                   $(nsenter --net=/var/run/docker/netns/ingress_sbox ip -o link | links)"
  echo "  ingress overlay namespace:                      $(nsenter --net=/var/run/docker/netns/1-$INGID ip -o link | links)"
done

docker service rm mtu-test >/dev/null 2>&1

#!/bin/bash

CHILD_CTR="dind-child"
RUNNING=1

log() {
  [ -z "$_BASHPID" ] && _BASHPID="$BASHPID"
  local D=$(date +%Y-%m-%d.%H:%M:%S.%N)
  local S=$(printf "%s|%s|%05d|" "${D:0:26}" "$HOSTNAME" "$_BASHPID")
  echo "$@" | sed "s/^/$S /g"
}			

# From https://blog.dhampir.no/content/sleeping-without-a-subprocess-in-bash-and-how-to-sleep-forever

snore() {
    local IFS
    [[ -n "${_snore_fd:-}" ]] || { exec {_snore_fd}<> <(:); } 2>/dev/null ||
    {
        # workaround for MacOS and similar systems
        local fifo
        fifo=$(mktemp -u)
        mkfifo -m 700 "$fifo"
        exec {_snore_fd}<>"$fifo"
        rm "$fifo"
    }
    read ${1:+-t "$1"} -u $_snore_fd || :
}

stop_child() {
  log "DIND service stopping child container $CHILD_CTR"
  docker stop -t 5 "$CHILD_CTR" 2>/dev/null
  log "DIND service stopped child container $CHILD_CTR"
}

remove_child() {
  log "DIND service removing (any) child container $CHILD_CTR"
  docker rm -f "$CHILD_CTR" 2>/dev/null
  log "DIND service removed (any) child container $CHILD_CTR"
}

shutdown() {
  log "DIND service received TERM/INT/QUIT signal, so shutting down"
  RUNNING=0
 
  if [ -z "$DOCKER_PID" ]; then
    return
  fi

  stop_child
}

trap shutdown TERM INT QUIT

if [ "$1" = "--daemon" ]; then
  shift
  exec /opt/docker-ingress-routing-daemon "$@"
else

  log "DIND service starting up"

  if [ -z "$CHILD_IMAGE" ]; then
    CHILD_IMAGE=$(docker container inspect -f '{{ .Config.Image }}' $(hostname))
  fi
  
  log "DIND service running on image: $CHILD_IMAGE"

  # Stop any pre-existing daemon container
  remove_child
  
  while [ $RUNNING -eq 1 ]; do
    # Launch afresh, putting 'docker run' into the background (but not detaching it - we want to log its STDOUT)
    log "DIND service launching child container $CHILD_CTR ..."
    docker run --name="$CHILD_CTR" -a stdout -a stderr --rm --privileged --pid=host -v /var/run/docker:/var/run/docker -v /var/run/docker.sock:/var/run/docker.sock $CHILD_IMAGE --daemon "$@" &

    DOCKER_PID="$!"
    log "DIND service launched child container with PID $DOCKER_PID"
  
    # Wait for 'docker run' to exit
    wait
  
    # When 'docker run' exits, try removing the container just in case.
    remove_child

    # snore 1s, only if we're still running
    [ $RUNNING -eq 1 ] && snore 1
  done
  
  log "DIND service shutting down"
fi

# Upgrade
#
# Add background process that logs this node's name, and ingress IP, every few seconds.
#
# Add outer-wrapper service, replica 1, contrained to run on manager nodes, that:
# - runs 'docker service logs --since=10s' to gather node names and ingress IPs
# - looks up labels for nodes, and eliminates nodes not labelled as LoadBalancer:1
# - if the node list has changed (or first loop), shut down inner wrapper service
# - launch inner wrapper service with list of ingress IPs
# - sleep 15s

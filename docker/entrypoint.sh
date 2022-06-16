#!/bin/bash

CHILD_CTR="dind-child"
CHILD_IMAGE="${CHILD_IMAGE:-newsnowlabs/dind:latest}"
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

if [ "$1" = "--service" ]; then
  shift
  
  log "DIND service starting up"
  
  # Stop any pre-existing daemon container
  remove_child
  
  while [ $RUNNING -eq 1 ]; do
    # Launch afresh, putting 'docker run' into the background (but not detaching it - we want to log its STDOUT)
    log "DIND service launching child container $CHILD_CTR ..."
    docker run --name="$CHILD_CTR" -a stdout -a stderr --rm --privileged --pid=host -v /var/run/docker:/var/run/docker -v /var/run/docker.sock:/var/run/docker.sock dind:test "$@" &

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
else
  exec /opt/docker-ingress-routing-daemon "$@"
fi

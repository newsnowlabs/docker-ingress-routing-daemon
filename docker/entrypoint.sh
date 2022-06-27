#!/bin/bash

# Ingress Routing Daemon Container Entrypoint
# Copyright © 2020-2022 Struan Bartlett
# ----------------------------------------------------------------------
# Permission is hereby granted, free of charge, to any person 
# obtaining a copy of this software and associated documentation files 
# (the "Software"), to deal in the Software without restriction, 
# including without limitation the rights to use, copy, modify, merge, 
# publish, distribute, sublicense, and/or sell copies of the Software, 
# and to permit persons to whom the Software is furnished to do so, 
# subject to the following conditions:
#
# The above copyright notice and this permission notice shall be 
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, 
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF 
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND 
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS 
# BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN 
# ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN 
# CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE 
# SOFTWARE.
# ----------------------------------------------------------------------
# Workaround for https://github.com/moby/moby/issues/25526

CHILD_IMAGE=""
CHILD_CTR="dind-child"
NODE_LABEL_CHECK_FREQUENCY=15
DEBUG=0

log() {
  [ -z "$_BASHPID" ] && _BASHPID="$BASHPID"
  local D=$(date +%Y-%m-%d.%H:%M:%S.%N)
  local S=$(printf "%s|%s|%05d|" "${D:0:26}" "$HOSTNAME" "$_BASHPID")
  echo "$@" | sed "s/^/$S /g"
}			

debug() {
  [ "$DEBUG" = "1" ] && log "$@"
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
  log "DIND global service stopping child container $CHILD_CTR"
  docker stop -t 5 "$CHILD_CTR" 2>/dev/null
  log "DIND global service stopped child container $CHILD_CTR"
}

remove_child() {
  log "DIND global service removing (any) child container $CHILD_CTR"
  docker rm -f "$CHILD_CTR" 2>/dev/null
  log "DIND global service removed (any) child container $CHILD_CTR"
}

shutdown_global_service() {
  log "DIND global service received TERM/INT/QUIT signal, so shutting down"
  RUNNING=0
 
  if [ -z "$DOCKER_PID" ]; then
    return
  fi

  stop_child
}

stop_global_service() {
  docker service rm dind-global >/dev/null
}

shutdown_manager_service() {
  log "DIND manager service received TERM/INT/QUIT signal, so shutting down"
  RUNNING=0
  
  stop_global_service
}

detect_ingress() {
  read INGRESS_SUBNET INGRESS_DEFAULT_GATEWAY \
    < <(docker network inspect ingress --format '{{(index .IPAM.Config 0).Subnet}} {{index (split (index .Containers "ingress-sbox").IPv4Address "/") 0}}' 2>/dev/null)

  [ -n "$INGRESS_SUBNET" ] && [ -n "$INGRESS_DEFAULT_GATEWAY" ] && return 0
  
  return 1
}

ssv() {
  # Print $@ to separate lines, sort uniquely, finally remove line breaks again.
  echo $(printf "%s\n" "$@" | sort -u)
}

csv() {
  # Print $@ to separate lines, sort uniquely, remove line breaks again, then finally add commas.
  echo $(printf "%s\n" "$@" | sort -u) | tr ' ' ','
}

if [ "$1" = "--daemon" ]; then
  shift
  exec /opt/docker-ingress-routing-daemon "$@"
fi

# If not specified, determine what image tag to use for launching the global service, or the child daemon container.
if [ -z "$CHILD_IMAGE" ]; then

  # Determine what image we launched with. Might be:
  # - a local image ID e.g. 9405706ab5ff - N.B. this generally cannot be used to launch an image on separate nodes
  # - a textual image name e.g. newsnowlabs/dind:latest
  # - a textual image name and digest e.g. newsnowlabs/dind:latest@sha256:0c02b40d46df4ead415462f6a6e8d514bdbd13dbc546a7a0561f5f9a788c9ca1
  INSPECT_CONFIG_IMAGE=$(docker container inspect -f '{{ .Config.Image }}' $(hostname))
  
  if [ -n "$INSPECT_CONFIG_IMAGE" ]; then
  
    # Determine whether the image we launched with references a repo. Might be:
    # - empty string (no repo)
    # - a textual image name e.g. newsnowlabs/dind:latest
    # - a textual image name and digest e.g. newsnowlabs/dind:latest@sha256:0c02b40d46df4ead415462f6a6e8d514bdbd13dbc546a7a0561f5f9a788c9ca1
    INSPECT_REPO_DIGEST=$(docker image inspect $INSPECT_CONFIG_IMAGE -f '{{ join .RepoDigests "\n" }}' | head -n 1)
  
    if [ -n "$INSPECT_REPO_DIGEST" ]; then
      CHILD_IMAGE="$INSPECT_REPO_DIGEST"
    else
      CHILD_IMAGE="$INSPECT_CONFIG_IMAGE"
    fi
  else
  
    # If all else fails, use the default latest image
    CHILD_IMAGE="newsnowlabs/dind:latest"
  fi
fi

RUNNING=1

if [ "$1" = "--global-service" ]; then
  shift

  log "DIND global service starting up with args: $@"
  log "DIND global service running on image: $CHILD_IMAGE"

  trap shutdown_global_service TERM INT QUIT

  # Stop any pre-existing daemon container
  remove_child
  
  while [ $RUNNING -eq 1 ]; do
    detect_ingress
    log "DIND global service node IP/Node: $INGRESS_DEFAULT_GATEWAY/$DOCKER_NODE_HOSTNAME"
    snore 3
  done &
  
  while [ $RUNNING -eq 1 ]; do
    # Launch afresh, putting 'docker run' into the background (but not detaching it - we want to log its STDOUT)
    log "DIND global service launching child container $CHILD_CTR ..."
    docker run --name="$CHILD_CTR" -a stdout -a stderr --rm --privileged --pid=host -v /var/run/docker:/var/run/docker -v /var/run/docker.sock:/var/run/docker.sock $CHILD_IMAGE --daemon "$@" &

    DOCKER_PID="$!"
    log "DIND global service launched child container with PID $DOCKER_PID"
  
    # Wait for 'docker run' to exit
    wait
  
    # When 'docker run' exits, try removing the container just in case.
    remove_child

    # snore 1s, only if we're still running
    [ $RUNNING -eq 1 ] && snore 1
  done
  
  log "DIND global service shutting down"
else

  log "DIND manager service starting up with args: $@"
  log "DIND manager service running on image: $CHILD_IMAGE"
  
  stop_global_service
  
  log "DIND manager service launching global service dind-global ..."
  docker service create -d --name=dind-global --mode=global --with-registry-auth=true --update-parallelism=0 --env="DOCKER_NODE_HOSTNAME={{.Node.Hostname}}" --mount=type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock $CHILD_IMAGE --global-service "$@"

  trap shutdown_manager_service TERM INT QUIT

  while [ $RUNNING -eq 1 ]; do
  
    debug "DIND manager running: docker service logs"
    
    LBS_NEW=$(ssv $(docker service logs --raw --since=10s dind-global 2>&1 | grep "DIND global service node IP/Node" | sed -r "s!^.*DIND global service node IP/Node: !!"))
    debug "DIND manager found logged IP/node list: ${LBS_NEW:-NONE}"
    
    NOW=$(date +%s)
    if [[ (-n "$LBS_NEW") && (("$LBS_NEW" != "$LBS") || ($NOW -gt $LAST_CHECK+$NODE_LABEL_CHECK_FREQUENCY)) ]]; then
    
      if [ "$LBS" != "$LBS_NEW" ]; then
        log "DIND manager found logged IP/node list changed, from '$LBS' to '$LBS_NEW'"
      elif [[ $NOW -gt $LAST_CHECK+$NODE_LABEL_CHECK_FREQUENCY ]]; then
        log "DIND manager rechecking node labels"
      fi
      
      declare -A NODETOIP
      for IPNode in $LBS_NEW
      do
        NODE=$(echo $IPNode | sed -r 's!^[^/]+/!!')
	IP=$(echo $IPNode | sed -r 's!/[^/]+!!')
	NODETOIP[$NODE]=$IP
      done
      
      log "DIND manager found swarm nodes: ${!NODETOIP[@]}"
      
      # Inspect nodes to find those with a 'DIND-LB:1' label; these will be the selected load balancers
      LB_NODES=$(docker node inspect ${!NODETOIP[@]} --format '{{ .Description.Hostname }} {{ .Spec.Labels }}' | egrep '[\[ ]DIND-LB:1' | awk '{print $1}' | tr '\012' ' ')
      log "DIND manager selected labelled LB swarm nodes: '$LB_NODES'"
      
      if [ -n "$LB_NODES" ] || [ "$MODE" = "labelled-lbs-only" ]; then
      
        # Translate selected LB nodes back to ingress network IPs
        LBS_IPS=()
        for NODE in $LB_NODES
        do
          debug "DIND manager selected LB node: $NODE => ${NODETOIP[$NODE]}"
          LBS_IPS+=(${NODETOIP[$NODE]})
        done

        LBS_CSV_NEW=$(csv ${LBS_IPS[@]})
        log "DIND manager selected labelled nodes for LB node CSV: '$LBS_CSV_NEW' (formerly '$LBS_CSV')"
      else
        LBS_CSV_NEW=$(csv ${NODETOIP[@]})
        log "DIND manager selected ALL nodes for LB node CSV: '$LBS_CSV_NEW' (formerly '$LBS_CSV')"
      fi
      
      if [[ (-n "$LBS_CSV_NEW") && ("$LBS_CSV_NEW" != "$LBS_CSV") ]]; then
        log "DIND manager update DIND global service with: docker service update -d dind-global --args=\"--global-service $* --ingress-gateway-ips $LBS_CSV_NEW\""
        docker service update -d dind-global --args="--global-service $* --ingress-gateway-ips $LBS_CSV_NEW" >/dev/null
	
	LBS_CSV="$LBS_CSV_NEW"
      else
        log "DIND manager not updating DIND global service, as LB nodes not changed or none selected"
      fi

      LAST_CHECK="$NOW"
      LBS="$LBS_NEW"
    fi
    
    # snore 5s, only if we're still running
    [ $RUNNING -eq 1 ] && snore 5
  done
  
  log "DIND manager service shutting down"
fi

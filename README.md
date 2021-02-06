# docker-ingress-routing-daemon
Docker swarm daemon that modifies ingress mesh routing to expose true client IPs to service containers

Docker Swarm's out-of-the-box ingress mesh routing logic uses IPVS and SNAT to route incoming traffic to service containers. By using SNAT to set the source IP of each incoming connection to the ingress network IP of the node, service containers receiving traffic from multiple nodes can route the reverse path traffic back to the correct node, which is necessary for the SNAT to be reversed and the reverse path traffic returned to the correct client IP.

An unfortunate side-effect of this approach is that to service containers, all incoming traffic appears to arrive from the same set of ingress network node IPs, and service containers cannot geolocate clients.

The docker-ingress-routing-daemon works around this limitation, by inhibiting SNAT and instead using a combination of firewall and policy routing rules to route reverse path traffic back to the correct node.

The way it works is as follows.

On load-balancing nodes:

1. Inhibit Docker Swarm's SNAT rule
2. Add a firewall rule that sets the TOS byte within outgoing IP packets, destined for a service container in the ingress network, to the node's `NODE_ID`. The `NODE_ID` is determined by the final byte of the node's IP within the ingress network.

On service container nodes:

1. Monitor for newly-launched service containers, and when a new container is seen, add firewall and routing rules within the container's namespace that implement the following.
2. Map the TOS value on any incoming packets to a connection mark, using the same value.
3. Map any connection mark on reverse path traffic to a firewall mark on the individual packets
4. Create a custom routing table for each load-balancing node/TOS value/connection mark value/firewall mark value.
5. Select which custom routing table to use, according to the firewall mark on the outgoing packet.

The daemon must be run on both load-balancer nodes and nodes running service containers, but its configuration must be tailored in advance with the `NODE_ID` of all expected load-balancer nodes.

N.B. Following production testing, for performance reasons the daemon also performs the following configuration within the ingress network namespace:

1. Sets `net.ipv4.vs.conn_reuse_mode=0`, `net.ipv4.vs.expire_nodest_conn=1` and `net.ipv4.vs.expire_quiescent_template=1`
2. Sets any further (or different) sysctl settings as specified on the node filesystem in `/etc/sysctl.d/conntrack.conf` and in `/etc/sysctl.d/ipvs.conf`
3. Disables connection tracking within the ingress network namespace.

**(If you do not want these changes made on your hosts, comment out these lines before running the script).**

## Usage

### Setting up

Generate a value for `INGRESS_NODE_GATEWAY_IPS` specific for the load-balancer nodes you intend to use in your swarm. You do this by running `docker-ingress-routing-daemon` as root on every one of your swarm's nodes **_that you'd like to use as a load-balancer endpoint_** (normally only your manager nodes, or a subset of your manager nodes), noting the values shown for `INGRESS_DEFAULT_GATEWAY`. You only have to do this once, or whenever you add or remove nodes. Your `INGRESS_NODE_GATEWAY_IPS` should look like `10.0.0.2 10.0.0.3 10.0.0.4 10.0.0.5` (according to the subnet defined for the ingress network, and the number of nodes).

### Running the daemon

Run `INGRESS_NODE_GATEWAY_IPS="<Node Ingress IP List>" docker-ingress-routing-daemon --install` as root on **_each and every one_** of your load-balancer and/or service container nodes **_before_** creating your service. (If your service is already created, then ensure you scale it to 0 before scaling it back to a positive number of replicas.) The daemon will initialise iptables, detect when docker creates new containers, and apply new routing rules to each new container.

If you need to restrict the daemon’s activities to a particular service, then modify `[ -n "$SERVICE" ]` to `[ "$SERVICE" = "myservice" ]`.

### Uninstalling iptables rules

Run `docker-ingress-routing-daemon --uninstall` on each node.

## Testing

The docker-ingress-routing-daemon is used in production on the website https://www.newsnow.co.uk/, currently handling in excess of 1,000 requests per second.

We run the daemon on all 10 nodes of our swarm, of which currently only two serve as load balancers for incoming web traffic. The two load-balancer nodes direct traffic to service containers running on the remaining nodes.

Using the daemon, we have been able to avoid significant changes to our tech stack, which used to run native IPVS load-balancing, or to our application's internals (which relied upon identifying the requesting client's IP address for geolocation and security purposes).

## Limitations

As the TOS value can store an 8-bit number, this model can in principle support up to 256 load-balancer endpoint nodes.

However as the model requires every container be installed with one iptables mangle rule + one policy routing rule + one policy routing table per manager endpoint node, there might possibly be some performance degradation as the number of such endpoint nodes increases (although experience suggests this is unlikely to be noticeable with <= 16 load-balancer endpoint nodes on modern hardware).

If you add load-balancer nodes to your swarm - or want to start using existing nodes as load-balancer nodes - you will need to tread carefully as existing containers will not be able to route traffic back to the new endpoint nodes. Try restarting `INGRESS_NODE_GATEWAY_IPS="<Node Ingress IP List>" docker-ingress-routing-daemon` with the updated value for `INGRESS_NODE_GATEWAY_IPS` across the cluster first, then perform a rolling update of all containers, before using the new load-balancer node.

## Scope for native Docker integration

I’m not familiar with the Docker codebase, but I can’t see anything that `docker-ingress-routing-daemon-v2` does that couldn’t, in principle, be implemented by Docker natively, but I'll leave that for the Docker team to consider, or as an exercise for someone familiar with the Docker code.

# docker-ingress-routing-daemon

Docker swarm daemon that modifies ingress mesh routing to expose true client IPs to service containers:
- implemented _purely through routing and firewall rules_; and so
- _without the need for running any additional application layers like traefik or other reverse proxies_; and so
- _there's no need to reconfigure your existing application_.

As far as we know, at the time of writing the docker-ingress-routing-daemon is _the most lightweight way to access client IPs_ from within containers launched by docker services.

Summary of features:
- Support for replacing docker's masquerading with routing on incoming traffic either for all published services, or only for specified services on specified TCP or UDP ports
- Support for recent kernels (such as employed in Google Cloud images) that set `rp_filter=1` (strict) inside service containers (though this can be disabled)
- Automatic installation of kernel tweaks that improve IPVS performance in production

## Background

Docker Swarm's out-of-the-box ingress mesh routing logic uses IPVS and SNAT to route incoming traffic to service containers. By using SNAT to masquerade the source IP of each incoming connection to be the ingress network IP of the load balancer node, service containers receiving traffic from multiple load balancer nodes are able to route the reverse path traffic back to the correct node (which is necessary for the SNAT to be reversed and the reverse path traffic returned to the correct client IP).

An unfortunate side-effect of this approach is that to service containers, all incoming traffic appears to arrive from the same set of private network ingress network node IPs, meaning service containers cannot distinguish individual clients by IP, or geolocate clients.

This has been documented in moby/moby issue [#25526](https://github.com/moby/moby/issues/25526) (as well as [#15086](https://github.com/moby/moby/issues/15086), [#26625](https://github.com/moby/moby/issues/26625) and [#27143](https://github.com/moby/moby/issues/27143)).

Typical existing workarounds require running an independent reverse-proxy load-balancer, like nginx or traefik, in front of your docker services, and modifying your applications to examine the `X-Forwarded-For` header. Compared to docker's own load balancer, which uses the kernel's IPVS, this is likely to be less efficient.

## The solution

The docker-ingress-routing-daemon works around this limitation, by inhibiting SNAT masquerading, and instead deploying a combination of firewall and policy routing rules to allow service containers to route reverse-path traffic back to the correct load-balancing node.

The way it works is as follows.

For load-balancing nodes:

1. Inhibit Docker Swarm's SNAT rule (for all traffic, or for specified TCP and UDP traffic, depending on command line arguments)
2. Add a firewall rule that sets the TOS byte within outgoing IP packets, destined for a service container in the ingress network, to the node's `NODE_ID`. The `NODE_ID` is determined by the final byte of the node's IP within the ingress network.
3. Installation kernel sysctl tweaks that improve IPVS performance in production (unless disabled)

For service container nodes:

1. Monitor for newly-launched service containers, and when a new container is seen, if the ingress network is found, add firewall and routing rules within the container's namespace that implement the following.
2. Map the TOS value on any incoming packets to a connection mark, using the same value.
3. Map any connection mark on reverse path traffic to a firewall mark on the individual packets
4. Create a custom routing table for each load-balancing node/TOS value/connection mark value/firewall mark value.
5. Select which custom routing table to use, according to the firewall mark on the outgoing packet.
6. Enable 'loose' reverse-path filter mode on the container ingress network interface.

The daemon must be run on both load-balancer nodes and nodes running service containers, but the ingress network IPs of all nodes intended to be used as load-balancers must be specified using `--ingress-gateway-ips` as a launch-time argument.

N.B. Following production testing, for performance reasons the daemon also performs the following configuration within the ingress network namespace:

1. Sets `net.ipv4.vs.conn_reuse_mode=0`, `net.ipv4.vs.expire_nodest_conn=1` and `net.ipv4.vs.expire_quiescent_template=1`
2. Sets any further (or different) sysctl settings as specified on the node filesystem in `/etc/sysctl.d/conntrack.conf` and in `/etc/sysctl.d/ipvs.conf`
3. Disables connection tracking within the ingress network namespace.

**(If you do not want these changes made on your hosts, run the daemon with the `--no-performance` option).**

## Usage

### Setting up

Generate a list of the ingress network IPs of the nodes you intend to use as load balancers in your swarm.  You do this by running `docker-ingress-routing-daemon` as root on every one of your swarm's nodes **_that you'd like to use as a load-balancer endpoint_**, noting the ingress network IP shown. You only have to do this once, or whenever you add or remove nodes. Your ingress network IPs should look something like `10.0.0.2 10.0.0.3 10.0.0.4 10.0.0.5` (according to the subnet defined for the ingress network, and the number of nodes; IPs will not necessarily be sequential).  

### Running the daemon

Run `docker-ingress-routing-daemon --ingress-gateway-ips <Node Ingress IP List> --install` as root on **_each and every one_** of your load-balancer and/or service container nodes **_before_** creating your service. (If your service is already created, then ensure you scale it to 0 before scaling it back to a positive number of replicas.) The daemon will initialise iptables, detect when docker creates new containers, and apply new routing rules to each new container.  

If you need to restrict the daemon’s installation of routing and firewall rules within launched containers to containers for specific services, then add `--services <Service List>`.

If you do not use `--services` then all service containers with an ingress network interface will be configured by the daemon.

If you need to restrict the daemons activities to the specific TCP or UDP ports published by the above services, then add `--tcp-ports <ports>` or `--udp-ports <ports>`, or both. If you do not use these options then all IPVS traffic routed by the node will be routed to service containers instead of masqueraded.

For detailed daemon usage, run:

```
# ./docker-ingress-routing-daemon
Usage: ./docker-ingress-routing-daemon [--install [OPTIONS] | --uninstall | --help]

           --services <services>  - service names to disable masquerading for
             --tcp-ports <ports>  - TCP ports to disable masquerading for
             --udp-ports <ports>  - UDP ports to disable masquerading for
     --ingress-gateway-ips <ips>  - specify load-balance ingress IPs
                --no-performance  - disable performance optimisations

    (services, ports and IPs may be comma or space-separated or may be specified
     multiple times)
```

### Uninstalling iptables rules

Run `docker-ingress-routing-daemon --uninstall` on each node.

## Testing

The docker-ingress-routing-daemon can be tested on a single-node or multi-node docker swarm.

## Production testing

The docker-ingress-routing-daemon is used in production on the website https://www.newsnow.co.uk/, currently handling in excess of 1,000 requests per second.

We run the daemon on all 10 nodes of our swarm, of which currently only two serve as load balancers for incoming web traffic. The two load-balancer nodes direct traffic to service containers running on the remaining nodes.

Using the daemon, we have been able to avoid significant changes to our tech stack, which used to run native IPVS load-balancing, or to our application's internals (which relied upon identifying the requesting client's IP address for geolocation and security purposes).

## Adding new load-balancer nodes or bringing existing nodes into service as load-balancers

If you add load-balancer nodes to your swarm - or want to start using existing nodes as load-balancer nodes - you will need to tread carefully as existing containers will not be able to route traffic back to the new endpoint nodes. We recommend the following procedure:
1. Restart the `docker-ingress-routing-daemon` _across your cluster_ with the updated IP list for `--ingress-gateway-ips`
2. Perform a rolling update of _all service containers_, so that they will have updated policy routing rules installed referencing the new nodes ingress gateway IPs
3. Bring your new load-balancer nodes into service, allowing public internet traffic to reach them.

## Limitations

As the IP TOS byte can store an 8-bit number, this model can in principle support up to 256 load-balancer nodes.

As, currently, the unique `NODE_ID` is determined from the load-balancer node's ingress network IP, the ingress network cannot be larger than a `/24`.

As the implementation requires every container be installed with one policy routing rule and routing table per load-balancer node, there might possibly be some performance degradation as the number of such load-balancer nodes increases (although experience suggests this is unlikely to be noticeable with <= 16 load-balancer endpoint nodes on modern hardware).

## Scope for native Docker integration

I’m not familiar with the Docker codebase, but I can’t see anything that `docker-ingress-routing-daemon` does that couldn’t, in principle, be implemented by Docker natively, but I'll leave that for the Docker team to consider, or as an exercise for someone familiar with the Docker code.

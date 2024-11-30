# docker-ingress-routing-daemon (DIRD)

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

**Firstly**, generate a list of the ingress network IPs of the nodes you intend to use as load balancers in your swarm.  You do this by running `docker-ingress-routing-daemon` as root on **_every one of your swarm's nodes that you'd like to use as a load-balancer endpoint_**, noting the ingress network IP shown. You only have to do this once, or whenever you add or remove nodes. Your ingress network IPs should look something like `10.0.0.2 10.0.0.3 10.0.0.4 10.0.0.5` (according to the subnet defined for the ingress network, and the number of nodes; IPs will not necessarily be sequential).

> Use this IP list to generate the `--ingress-gateway-ips <Node Ingress IP List>` command line option. The IP list may be comma-separated or space-separated.

> N.B. Common gotcha: the list should not normally contain `10.0.0.1`; this is the gateway IP of the default `ingress` network but **WILL NOT BE** the IP of any node within that default network.

**Secondly**, for most use-cases it is advisable to whitelist (i.e. restrict the daemon’s installation of routing and firewall rules) to those specific ingress services you need. Run `docker service ls` to see what TCP and UDP ports your services publish.

> Use this service and protocol/port list to generate the `--services <Service List>` and `--tcp-ports <tcp-ports>` and/or `--udp-ports <udp-ports>` command line options. Services and ports may be comma-separated or space-separated, or these options may be specified multiple times.

> N.B. If you do not specify `--services` and `--tcp-ports` / `--udp-ports` then *ALL* service containers with an ingress network interface will be reconfigured and your access to non-service containers publishing ports might freeze.

> **WARNING:** The use of `--iptables-wait` or `--iptables-wait <n>` is strongly advised if your systems run `firewalld` or another process that performs high-frequency access to iptables. In such scenarios the xtables lock could be held, inhibiting DIRD making successful calls to iptables and producing the error *"Another app is currently holding the xtables lock"*. The use of these options should be harmless in other cases.

### Running the daemon

Having prepared your command line options (collectively, `[OPTIONS]`), run the following **as root** on **_each and every one_** of your load-balancer and/or service container nodes:

```
docker-ingress-routing-daemon --install --preexisting [OPTIONS]
```

(You may omit `--preexisting` but, if so, then you **must** _either_ launch DIRD **_before_** creating your service, _or_ -- if your service is already created -- scale your service to 0 before scaling it back to a positive number of replicas.)

The DIRD daemon will:
- initialise iptables to disable masquerading for the whitelisted TCP/UDP ports;
- apply new routing rules for the whitelisted ports to each preexisting whitelisted service container;
- loop, monitoring for when docker creates new whitelisted containers and then applying new routing rules for the whitelisted ports to each new container.

For detailed daemon usage, run:

```
# ./docker-ingress-routing-daemon
Usage: ./docker-ingress-routing-daemon [--install [OPTIONS] | --uninstall | --help]

           --services <services>  - service names to whitelist (i.e. disable masquerading for)
         --tcp-ports <tcp-ports>  - TCP ports to whitelist (i.e. disable masquerading for)
         --udp-ports <udp-ports>  - UDP ports to whitelist (i.e. disable masquerading for)
     --ingress-gateway-ips <ips>  - specify load-balance ingress IPs
                   --preexisting  - optionally install rules where needed
                                    on preexisting containers (recommended)
                                    
                --no-performance  - disable performance optimisations
                   --indexed-ids  - use sequential ids for load balancers
                                    (forced where ingress subnet larger than /24)
                                    
                 --iptables-wait  - pass '--iptables-wait' option to iptables
     --iptables-wait-seconds <n>  - pass '--iptables-wait <n>' option to iptables

    (services, ports and IPs may be comma or space-separated or may be specified
     multiple times)
```

#### Installing using systemd

To install via systemd, please see the example systemd unit at `etc/systemd/system/dird.service`, which should be copied to `/etc/systemd/system` or `/usr/local/lib/systemd/system` (according to your distribution), and modified to reflect your required arguments. As normal when installing a new systemd unit, run `systemctl daemon-reload`, then enable the unit by running `systemctl enable dird` and if needed start the unit by running `systemctl start dird`.

### Uninstalling iptables rules

Run `docker-ingress-routing-daemon --uninstall` on each node.

## Migrating a running production swarm to use DIRD

### DIRD daemon options

Recommendations for launching DIRD on a running swarm:

1. Work out the `<ips>` argument for `--ingress-gateway-ips <ips>` carefully in advance - getting this wrong will easily break things.
   - A command to run on a manager to generate `<ips>` is `docker node ls --format "{{.Hostname}}" | pdsh -N -R ssh -w - "docker network inspect ingress --format '{{index (split (index .Containers \"ingress-sbox\").IPv4Address \"/\") 0}}' 2>/dev/null" | sort -t . -n -k 1,1 -k 2,2 -k 3,3 -k 4,4'` (`pdsh` and `ssh` needed) though N.B. this `<ips>` list is overkill if you only use a subset of nodes as load balancers.
   - Be sure to embed `<ips>` in double quotes if it contains spaces e.g. `--ingress-gateway-ips "10.0.0.2 10.0.0.3"`; otherwise separate IPs with commas e.g. `--ingress-gateway-ips 10.0.0.2,10.0.0.3`.
2. Use the `--preexisting` option so that when DIRD is launched it applies policy routing rules to each matching preexisting container.
3. Use `--services <services>`, `--tcp-ports <tcp-ports>` and if you need it `--udp-ports <udp-ports>` to whitelist DIRD behaviour for _only_ the specific swarm services and ports that you need to.
4. Use `--iptables-wait` or `--iptables-wait-seconds <n>` to avoid possible errors resulting from contention with other firewall apps for the iptables lock.
5. Using a set of `[OPTIONS]` derived accordingly, prepare a `dird.service` [systemd unit](https://github.com/newsnowlabs/docker-ingress-routing-daemon?tab=readme-ov-file#installing-using-systemd) that launches `docker-ingress-routing-daemon --install [OPTIONS]` and deploy it (to `/etc/systemd/system`, or `/usr/local/lib/systemd/system` according to your distribution) to all swarm nodes (whether load balancer and/or service container nodes).
6. Enable - without running - the systemd unit across all nodes using e.g. `docker node ls --format "{{.Hostname}}" | pdsh -R ssh -w - 'systemctl daemon-reload; systemctl enable dird'`.

###  DIRD rollout strategy

During the migration to DIRD, if you can restrict incoming public requests to a subset of your nodes (i.e. nodes you nominate as "load balancers"), a recipe that works very smoothly is as follows:

1. First, launch DIRD (`systemctl start dird`), fully configured, on all nominated non-load-balancer nodes. (This will **_not_** break connection handling, as long as the incoming connections are terminated by a nominated load-balancer node not yet running DIRD.)
2. Second, bring up DIRD simultaneously on all remaining nodes, i.e. on the nominated load-balancer nodes.

Put another way, before launching DIRD on some node(s), make sure you have previously removed their public load-balancer IPs from the pool of load balancer endpoints your public requests are reaching. Repeat the process as many times as needed until you are left with a minimal set of load balancer node(s). Finally launch DIRD on the remaining load balancer node(s).

This works because:
- Nodes already running DIRD will be able to load-balance _only_ to containers on nodes already running DIRD.
- Nodes not yet running DIRD will be able to load-balance to containers, both on nodes already running and not yet running DIRD.

## Adding new load-balancer nodes or bringing existing nodes into service as load-balancers

If you add load-balancer nodes to your swarm - or want to start using existing nodes as load-balancer nodes - you will need to tread carefully as existing containers will not know how to route traffic back to the new load balancer node for public connections terminated on that node. We recommend the following procedure:

1. Restart the `docker-ingress-routing-daemon` _across your cluster_ with an updated IP list for `--ingress-gateway-ips <ips>`.
2. Perform a rolling update of _all service containers_, so that they will have updated policy routing rules installed referencing the new nodes ingress gateway IPs.
3. Bring your new load-balancer nodes into service, allowing public internet traffic to reach them.

## Testing modifications to DIRD

The docker-ingress-routing-daemon can be tested on a single-node or multi-node docker swarm.

An automated test is included in the [RunCVM](https://github.com/newsnowlabs/runcvm) repo. Run it with:

```sh
git clone https://github.com/newsnowlabs/runcvm.git && \
cd runcvm/tests/00-http-docker-swarm && \
NODES=3 DIRD=1 ./test
```

## Production testing

The docker-ingress-routing-daemon is used in production on the website https://www.newsnow.co.uk/, currently handling in excess of 1,000 requests per second.

We run the daemon on all 10 nodes of our swarm, of which currently only two serve as load balancers for incoming web traffic. The two load-balancer nodes direct traffic to service containers running on the remaining nodes.

Using the daemon, we have been able to avoid significant changes to our tech stack, which used to run native IPVS load-balancing, or to our application's internals (which relied upon identifying the requesting client's IP address for geolocation and security purposes).

## Limitations

As the IP TOS byte can store an 8-bit number, this model can in principle support up to 256 load-balancer nodes.

As the implementation requires every container be installed with one policy routing rule and routing table per load-balancer node, there might possibly be some performance degradation as the number of such load-balancer nodes increases (although experience suggests this is unlikely to be noticeable with <= 16 load-balancer endpoint nodes on modern hardware).

## Scope for native Docker integration

I’m not familiar with the Docker codebase, but I can’t see anything that `docker-ingress-routing-daemon` does that couldn’t, in principle, be implemented by Docker natively, but I'll leave that for the Docker team to consider, or as an exercise for someone familiar with the Docker code.

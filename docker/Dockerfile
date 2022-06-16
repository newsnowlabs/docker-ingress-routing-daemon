FROM amd64/debian:bullseye

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get -y install apt-transport-https ca-certificates curl gnupg2 && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add - && echo "deb [arch=amd64] https://download.docker.com/linux/debian bullseye stable" >/etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get -y install docker-ce-cli gcc- && \
    apt-get remove g++ g++-8

RUN apt-get install -y procps iproute2 iptables

ADD docker-ingress-routing-daemon /opt/
ADD docker/entrypoint.sh /opt/

ENTRYPOINT ["/opt/entrypoint.sh"]

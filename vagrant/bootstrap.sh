#!/usr/bin/env bash

#install docker an openvswitch
apt-get update
apt-get install --yes apt-transport-https vim
apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
mkdir -p /etc/apt/sources.list.d
echo "deb https://apt.dockerproject.org/repo debian-jessie main" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install --yes docker-engine openvswitch-switch
service docker start

docker pull nherbaut/adapted-video-osgi-bundle

#ip v4 forwarding on the machine
sysctl -w net.ipv4.ip_forward=1

#copy ovs-docker from host
cp /vagrant/ovs-docker /usr/local/bin
chmod +x /usr/local/bin/ovs-docker

#remove vagrant default nat gw
ip r del default

#get the old dhcp assigned ip
EGRESS_IP=$(ip a show eth1|grep "inet "|sed -rn "s/.*inet ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\/[0-9]{2}).*/\1/p")
ip a del $EGRESS_IP dev eth1




#create the two ovs bridge and ports to eth1 and eth2. 
ovs-vsctl del-br ingress
ovs-vsctl del-br egress
ovs-vsctl add-br ingress
ovs-vsctl add-br egress
ovs-vsctl add-port ingress eth2
ovs-vsctl add-port egress eth1

#boot the ovs
ip l set ingress up
ip l set egress up

#assigh eth2 ip to ingress
ip a del 10.10.10.10/24 dev eth2
ip a add 10.10.10.10/24 dev ingress

#get ip and default gateway from eth1 to assign them to egress
INGRESS_PORT=$(ovs-ofctl show ingress |sed -rn "s/ ([0-9]*)\(eth2.*/\1/p")
EGRESS_PORT=$(ovs-ofctl show egress |sed -rn "s/ ([0-9]*)\(eth1.*/\1/p")

#remove every ip from eth1 and let the egress bridge take the eth2 port address
ip a flush eth1
dhclient egress


ovs-ofctl del-flows ingress
ovs-ofctl del-flows egress

ovs-ofctl add-flow ingress actions=normal
ovs-ofctl add-flow egress actions=normal

#nat 
iptables -t nat -F
iptables -t nat -A POSTROUTING -j MASQUERADE -s 10.10.10.0/24

#clean up docker
docker kill container1 proxy
docker rm container1 proxy

#start container 1 (not sure what it does)
container1_id=$(docker run -d --net=none --privileged=true --name=container1 nherbaut/adapted-video-osgi-bundle /bin/bash -c "while true; do echo container1 |nc -l 80; done;")

#start the proxy container
proxy_id=$(docker run -d --net=none --privileged=true --name=proxy -e FRONTAL_HOSTNAME="localhost" -e FRONTAL_PORT="9090" nherbaut/adapted-video-osgi-bundle java -cp /maven/*:/maven/a fr.labri.progess.comet.app.App --frontalHostName 10.10.10.3 --frontalPort 8080 --host 0.0.0.0 --port 8080 --debug)

#cleanup old docker ports
ovs-docker del-port ingress eth0 container1 > /dev/null
ovs-docker del-port ingress eth0 proxy > /dev/null

#create new port on ovs
ovs-docker add-port ingress eth0 container1 --ipaddress=10.10.10.11/24 --macaddress=00:00:00:00:00:01
docker exec container1 ip r add default via 10.10.10.10 dev eth0

#get info on container1
CONTAINER_1_INGRESS_PORT=$(ovs-ofctl show ingress|sed -rn "s/^ ([0-9]+)\([a-f0-9]+_l\):.*/\1/p")
CONTAINER_1_INGRESS_PORT_ID=$(ovs-ofctl show ingress|sed -rn "s/^ [0-9]+\(([a-f0-9]+_l)\):.*/\1/p")

#add the internal port for the proxy
ovs-docker add-port ingress eth0 proxy --ipaddress=10.10.10.12/24 --macaddress=00:00:00:00:00:02
docker exec proxy ip r add default via 10.10.10.10 dev eth0

CONTAINER_2_INGRESS_PORT=$(ovs-ofctl show ingress|grep -v $CONTAINER_1_INGRESS_PORT_ID|sed -rn "s/^ ([0-9]+)\([a-f0-9]+_l\):.*/\1/p")

#clean up the lows on ingress
ovs-ofctl del-flows ingress

#add flow to mirlitone.com
ovs-ofctl add-flow ingress ip,tcp,nw_dst=37.59.125.79,tcp_dst=80,actions=mod_dl_dst=00:00:00:00:00:01,mod_nw_dst=10.10.10.11,output:$CONTAINER_1_INGRESS_PORT
ovs-ofctl add-flow ingress ip,tcp,in_port=$CONTAINER_1_INGRESS_PORT,tcp_src=80,actions=mod_nw_src=37.59.125.79,output:1

#add flow to Labri
ovs-ofctl add-flow ingress ip,tcp,in_port=1,nw_dst=147.210.8.59,tcp_dst=80,actions=mod_dl_dst=00:00:00:00:00:02,mod_nw_dst=10.10.10.12,mod_tp_dst=8080,output:$CONTAINER_2_INGRESS_PORT
ovs-ofctl add-flow ingress ip,tcp,in_port=$CONTAINER_2_INGRESS_PORT,tcp_src=8080,actions=mod_nw_src=147.210.8.59,mod_tp_src=80,output:1

#plug routing/nat
ovs-ofctl add-flow ingress actions=normal





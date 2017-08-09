#!/bin/bash
#
#######################################
# Programmatically assigned, no touchie

IFACE=wg-hub	# I mean, you COULD change this one in the defaults config file, or even here, but there's really no reason to.

PROG="${0##*/}"
CONFIG=${PROG//run-/}; CONFIG=${CONFIG//\.*/}.conf;
HN=$(hostname)
OUTSIDE=$(awk 'BEGIN { IGNORECASE=1 } /^[a-z0-9]+[ \t]+00000000/ { print $1 }' /proc/net/route)  # one liner default IPv4 route interface grabber

# override defaults with local settings
if [ ! -r /etc/default/wgserver ]
then
	echo "Can't locate /etc/default/wgserver for base configuration."
	exit 1
fi
. /etc/default/wgserver


do_keys() {
	server_keys
	client_keys
}

client_keys() {
	VERBOSE=$1

	for client in $(cd ${WGDIR}/clients; ls *.publickey);
	do
		[[ -n "${VERBOSE}" ]] && echo "checking client: ${client//.publickey/}"

		key=$(head -1 ${WGDIR}/clients/${client})
		if [ -z "$(grep ${key} ${WGDIR}/${CONFIG})" ];
		then
			[[ -n "${VERBOSE}" ]] && echo "adding new config for ${client//.publickey/}"
			echo "[Peer]" >> ${WGDIR}/${CONFIG}
			echo "PublicKey = ${key}" >> ${WGDIR}/${CONFIG}
			echo "AllowedIPs = 0.0.0.0/0, ::/0"  >> ${WGDIR}/${CONFIG}
			echo ""  >> ${WGDIR}/${CONFIG}
		fi
	done
}

server_keys() {
	VERBOSE=$1
	
	if [ ! -r ${WGDIR}/private/${HN}.privatekey ]; 
	then
		[[ -n "${VERBOSE}" ]] && echo "server: ${HN}.privatekey not found"
		if [ ! -r ${WGDIR}/private/${HN}.publickey ];
		then
			[[ -n "${VERBOSE}" ]] && echo "server: ${HN}.publickey not found, generating new keys"
			wg genkey | tee ${WGDIR}/private/${HN}.privatekey | wg pubkey > ${WGDIR}/private/${HN}.publickey
		else
			# public, but no private...
			echo "public key found, but no private. are we a client?"
			exit 1
		fi
	else
		# readable private key...
		if [ ! -r ${WGDIR}/private/${HN}.publickey ];
		then
			[[ -n "${VERBOSE}" ]] && echo "server: ${HN}.publickey not found, generating new public key from existing ${HN}.privatekey"
			wg genkey | tee ${WGDIR}/private/${HN}.privatekey | wg pubkey > ${WGDIR}/private/${HN}.publickey
		fi
	fi

	PK=$(head -1 ${WGDIR}/private/${HN}.privatekey)
	if [ -z "$(grep ${PK} ${WGDIR}/${CONFIG})" ];
	then
		[[ -n "${VERBOSE}" ]] && echo "replacing server privatekey in config file"
		sed -i "s/PrivateKey.*/PrivateKey = ${PK}/g" ${WGDIR}/${CONFIG}
	fi
}

status() {
	ip link show ${IFACE} >/dev/null 2>&1
	if [ $? -eq 0 ]; then
		wg show ${IFACE}
		if [ $? -eq 0 ]; then
			ip -4 route show dev ${IFACE}
			ip -6 route show dev ${IFACE}
		fi
		echo "IPv6 forwarding: $(cat /proc/sys/net/ipv6/conf/all/forwarding)"
		echo -n "iptables: IPv4 natting is "
		iptables -t nat -C POSTROUTING -s ${LOCALv4//1\//0\/} -o ${OUTSIDE} -j MASQUERADE >/dev/null 2>&1
		if [ $? -ne 0 ]; then
			echo -n "not "
		fi
		echo "enabled"
	else
		echo "not running"
	fi
}

start_nat() {
	iptables -A FORWARD -i ${IFACE} -o ${OUTSIDE} -m conntrack --ctstate NEW -j ACCEPT
	iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
	iptables -t nat -A POSTROUTING -s ${LOCALv4//1\//0\/} -o ${OUTSIDE} -j MASQUERADE

	echo 1 >/proc/sys/net/ipv4/conf/all/forwarding
}

start() {
	ip link show ${IFACE} >/dev/null 2>&1 || ip link add dev ${IFACE} type wireguard
	ip address add dev ${IFACE} ${LOCALv4}
	for CLIENT in $(grep \.wan ${WGDIR}/clients.conf | cut -f 1 -d.)
	do
		WAN=$(grep ${CLIENT}\.wan ${WGDIR}/clients.conf | cut -f 2 -d=)
		LAN=$(grep ${CLIENT}\.lan ${WGDIR}/clients.conf | cut -f 2 -d=)

		ip address add dev ${IFACE} ${WAN//::/::1}
		ip -6 route add dev ${IFACE} ${LAN} via ${WAN//::*/::2}
	done
	ip link set ${IFACE} up
	echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
	
	wg setconf ${IFACE}  ${WGDIR}/${CONFIG}

	wg show ${IFACE}

	start_nat
}

stop_nat() {
	echo 0 >/proc/sys/net/ipv4/conf/all/forwarding

        iptables -D FORWARD -i ${IFACE} -o ${OUTSIDE} -m conntrack --ctstate NEW -j ACCEPT
        iptables -D FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        iptables -t nat -D POSTROUTING -s ${LOCALv4//1\//0\/} -o ${OUTSIDE} -j MASQUERADE
}

stop() {
	stop_nat

	ip link show ${IFACE} >/dev/null 2>&1
	if [ $? -eq 0 ]; then
		ip link set ${IFACE} down
		ip link del dev ${IFACE}
	fi
}


case ${1} in
	start|up) do_keys && start
		;;
	stop|down) stop
		;;
	start_nat) start_nat
		;;
	stop_nat) stop_nat
		;;
	clients) client_keys verbose
		;;
	server) server_keys verbose
		;;
	status) status
		;;
	*) echo "${PROG} [start/up|stop/down|status]"
		;;
esac
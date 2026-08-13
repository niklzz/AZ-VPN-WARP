#!/bin/bash
set -e
shopt -s nullglob

cd /root/antizapret

./down.sh

source setup

if [[ -z "$DEFAULT_INTERFACE" ]]; then
	DEFAULT_INTERFACE="$(ip route get 1.2.3.4 2>/dev/null | grep -oP 'dev \K\S+')"
	if [[ -z "$DEFAULT_INTERFACE" ]]; then
		echo 'Default network interface not found!'
		exit 1
	fi
	DEFAULT_IP="$(ip route get 1.2.3.4 2>/dev/null | grep -oP 'src \K\S+')"
	if [[ -z "$DEFAULT_IP" ]]; then
		echo 'Default IPv4 address not found!'
		exit 2
	fi
fi

if [[ -z "$ANTIZAPRET_OUT_INTERFACE" ]]; then
	ANTIZAPRET_OUT_INTERFACE=$DEFAULT_INTERFACE
	if [[ -z "$ANTIZAPRET_OUT_IP" ]]; then
		ANTIZAPRET_OUT_IP=$DEFAULT_IP
	fi
fi

if [[ -z "$VPN_OUT_INTERFACE" ]]; then
	VPN_OUT_INTERFACE=$DEFAULT_INTERFACE
	if [[ -z "$VPN_OUT_IP" ]]; then
		VPN_OUT_IP=$DEFAULT_IP
	fi
fi

[[ "$ALTERNATIVE_CLIENT_IP" == 'y' ]] && IP="${CLIENT_IP:-172}" || IP=10
[[ "$ALTERNATIVE_FAKE_IP" == 'y' ]] && FAKE_IP="${FAKE_IP:-198.18}" || FAKE_IP="$IP.30"
# Диапазон fake IP для WARP-ветки - всегда противоположный основному, чтобы они не пересеклись
[[ "$ALTERNATIVE_FAKE_IP" == 'y' ]] && WARP_FAKE_IP="${WARP_FAKE_IP:-$IP.30}" || WARP_FAKE_IP="${WARP_FAKE_IP:-198.18}"

# Аплинк до зарубежного сервера
# Профиль готовит setup.sh: DNS вырезан, добавлены Table = 13337 и правило по метке
UPLINK_INTERFACE="${UPLINK_INTERFACE:-az}"
UPLINK_PATH="/etc/amnezia/amneziawg/$UPLINK_INTERFACE.conf"

if [[ "$UPLINK_ENABLE" == 'y' && -f $UPLINK_PATH ]]; then
	set +e
	echo "Starting $UPLINK_INTERFACE..."
	awg-quick up $UPLINK_INTERFACE 2>/dev/null

	if [[ $? -eq 0 ]]; then
		echo "Started $UPLINK_INTERFACE"
		# Апстримы kresd@2 и fallback.lua живут за Cloudflare и из России недоступны,
		# а по заблокированным доменам ещё и отвечают подменёнными записями - уводим их в аплинк.
		# Маршруты привязаны к устройству и исчезают вместе с ним, зеркало в down.sh не нужно
		for dns in 1.1.1.1 1.0.0.1 9.9.9.10 149.112.112.10 76.76.2.0 76.76.10.0 \
				64.6.64.6 64.6.65.6 208.67.222.222 86.54.11.100; do
			ip route replace "$dns" dev $UPLINK_INTERFACE
		done
	else
		echo "Starting $UPLINK_INTERFACE failed! Blocked sites will not work"
	fi
	set -e
fi

# WARP AntiZapret
WARP_ANTIZAPRET_PATH="/etc/wireguard/warp-antizapret.conf"
# Общее с warp.sh: санирование профиля, подъём интерфейса, регистрация в Cloudflare.
# Тот же код нужен и при старте, и при выборе узла, поэтому живёт отдельно.
# Без библиотеки отключаем только WARP-ветку: уронить весь up.sh значило бы остаться без firewall
if [[ -f /root/antizapret/warp-lib.sh ]]; then
	source /root/antizapret/warp-lib.sh
else
	echo 'warp-lib.sh not found! WARP list will not work'
	WARP_LIST_ENABLE=n
fi

if [[ "$WARP_LIST_ENABLE" == 'y' ]]; then
	set +e
	rm -f $WARP_ANTIZAPRET_PATH

	if [[ -f "$WARP_SOURCE" ]]; then
		echo "Starting $WARP_ANTIZAPRET_INTERFACE from $WARP_SOURCE..."
	else
		# Профиля нет - заводим свой. Пишем в тот же $WARP_SOURCE, чтобы дальше он жил наравне
		# с положенным руками, а warp.sh мог его переписать под нужный узел Cloudflare
		echo "Starting $WARP_ANTIZAPRET_INTERFACE with a fresh registration..."
		warp_register "$WARP_SOURCE" || echo "Cloudflare registration failed!"
	fi

	if [[ -f "$WARP_SOURCE" ]]; then
		warp_sanitize "$WARP_SOURCE"
		warp_up
	fi

	# Endpoint мог протухнуть с прошлого запуска - тогда перевыбираем узел и пробуем ещё раз.
	# Строго auto: у ExecStartPre нет tty, спрашивать некого, а список WARP_NODE - это решение,
	# принятое пользователем заранее. timeout обязателен, иначе скан подвесит запуск сервиса
	if ! warp_handshake && [[ -x /root/antizapret/warp.sh ]]; then
		echo "No handshake with $(awk -F'= *' '/^Endpoint/{print $2; exit}' "$WARP_SOURCE" 2>/dev/null), picking another node..."
		# warp.sh сам подберёт endpoint с портом и оставит ветку поднятой - здесь только ждём
		timeout 300 /root/antizapret/warp.sh auto || true
	fi

	if warp_handshake; then
		echo "Started $WARP_ANTIZAPRET_INTERFACE: $(awg show $WARP_ANTIZAPRET_INTERFACE endpoints | awk '{print $2}') connected"
	else
		echo "Started $WARP_ANTIZAPRET_INTERFACE, but no handshake! WARP list will not work"
	fi
	set -e
else
	rm -f $WARP_ANTIZAPRET_PATH $WARP_ANTIZAPRET_AWG_PATH
fi

# WARP VPN
WARP_VPN_INTERFACE=warp-vpn
WARP_VPN_PATH="/etc/wireguard/$WARP_VPN_INTERFACE.conf"

if [[ "$VPN_WARP" == 'y' ]]; then
	set +e
	echo "Starting $WARP_VPN_INTERFACE..."
	WARP_PRIVATE_KEY=$(wg genkey)
	KEY=$(echo "$WARP_PRIVATE_KEY" | wg pubkey)
	REG=$(curl -sSfL --connect-timeout 10 -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
		-H 'Content-Type: application/json' \
		-d "{\"key\": \"$KEY\"}")

	WARP_PUBLIC_KEY=$(echo "$REG" | jq -r '.config.peers[0].public_key')
	WARP_ENDPOINT=$(echo "$REG" | jq -r '.config.peers[0].endpoint.host')
	WARP_ADDRESS=$(echo "$REG" | jq -r '.config.interface.addresses.v4')

	echo "[Interface]
PrivateKey = $WARP_PRIVATE_KEY
Address = $WARP_ADDRESS/32
MTU = 1420
Table = 13336
PostUp = ip rule add from $IP.28.0.0/16 to $IP.28.0.0/16 lookup main priority 5000 || true
PostUp = ip rule add from $IP.28.0.0/16 lookup 13336 priority 10000 || true
PostDown = ip rule del from $IP.28.0.0/16 to $IP.28.0.0/16 priority 5000
PostDown = ip rule del from $IP.28.0.0/16 lookup 13336 priority 10000

[Peer]
PublicKey = $WARP_PUBLIC_KEY
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 15
Endpoint = $WARP_ENDPOINT" > $WARP_VPN_PATH

	wg-quick up $WARP_VPN_PATH 2>/dev/null

	if [[ $? -eq 0 ]]; then
		echo "Started $WARP_VPN_INTERFACE: $WARP_ENDPOINT connected"
		VPN_OUT_INTERFACE=$WARP_VPN_INTERFACE
		VPN_OUT_IP=$WARP_ADDRESS
	else
		echo "Starting $WARP_VPN_INTERFACE failed! Use $DEFAULT_INTERFACE"
	fi
	set -e
else
	rm -f $WARP_VPN_PATH
fi

# filter
# Default policy
iptables -w -P INPUT ACCEPT
iptables -w -P FORWARD ACCEPT
iptables -w -P OUTPUT ACCEPT
ip6tables -w -P INPUT ACCEPT
ip6tables -w -P FORWARD ACCEPT
ip6tables -w -P OUTPUT ACCEPT
# INPUT connection tracking
iptables -w -I INPUT 1 -m conntrack --ctstate INVALID -j DROP
ip6tables -w -I INPUT 1 -m conntrack --ctstate INVALID -j DROP
# FORWARD connection tracking
iptables -w -I FORWARD 1 -m conntrack --ctstate INVALID -j DROP
ip6tables -w -I FORWARD 1 -m conntrack --ctstate INVALID -j DROP
# OUTPUT connection tracking
iptables -w -I OUTPUT 1 -m conntrack --ctstate INVALID -j DROP
ip6tables -w -I OUTPUT 1 -m conntrack --ctstate INVALID -j DROP
# Torrent guard
if [[ "$TORRENT_GUARD" == 'y' ]]; then
	ipset create antizapret-torrent hash:ip timeout 60 -exist
	iptables -w -I FORWARD 2 -s $IP.28.0.0/16 -p tcp -m string --string 'GET ' --algo kmp --to 100 -m string --string 'info_hash=' --algo bm -m string --string 'peer_id=' --algo bm -m string --string 'port=' --algo bm -j SET --add-set antizapret-torrent src --exist
	iptables -w -I FORWARD 3 -s $IP.28.0.0/16 -p udp -m string --string 'BitTorrent protocol' --algo kmp --to 100 -j SET --add-set antizapret-torrent src --exist
	iptables -w -I FORWARD 4 -s $IP.28.0.0/16 -p udp -m string --string 'd1:ad2:id20:' --algo kmp --to 100 -j SET --add-set antizapret-torrent src --exist
	iptables -w -I FORWARD 5 -s $IP.28.0.0/16 -m set --match-set antizapret-torrent src -j DROP
fi
# Restrict forwarding
if [[ "$RESTRICT_FORWARD" == 'y' ]]; then
	{
		echo 'create antizapret-forward hash:net -exist'
		echo 'flush antizapret-forward'
		if [[ -f result/forward-ips.txt ]]; then
			while read -r line; do
				echo "add antizapret-forward $line"
			done < result/forward-ips.txt
		fi
	} | ipset restore
	iptables -w -I FORWARD 2 -s $IP.29.0.0/16 -m connmark --mark 0x1 -m set ! --match-set antizapret-forward dst -j DROP
fi
# Drop forwarding
{
	echo 'create antizapret-drop hash:net -exist'
	echo 'flush antizapret-drop'
	if [[ -f result/drop-ips.txt ]]; then
		while read -r cidr; do
			echo "add antizapret-drop $cidr"
		done < result/drop-ips.txt
	fi
} | ipset restore
iptables -w -I FORWARD 2 -s $IP.28.0.0/15 -m set --match-set antizapret-drop dst -j DROP
# Client and server isolation
if [[ "$CLIENT_ISOLATION" == 'y' ]]; then
	# У AntiZapret теперь три выхода, а не один, поэтому обратный трафик с аплинка и WARP
	# нужно пропустить явно - иначе его убьёт правило ниже.
	# ACCEPT'ы матчат -d, то есть трафик К клиентам, и не задевают torrent guard и antizapret-drop,
	# которые матчат -s. Изоляция клиент<->клиент сохраняется
	iptables -w -I FORWARD 2 -i $UPLINK_INTERFACE -d $IP.29.0.0/16 -j ACCEPT
	iptables -w -I FORWARD 3 -i $WARP_ANTIZAPRET_INTERFACE -d $IP.29.0.0/16 -j ACCEPT
	iptables -w -I FORWARD 4 ! -i $ANTIZAPRET_OUT_INTERFACE -d $IP.29.0.0/16 -j DROP
	iptables -w -I FORWARD 5 ! -i $VPN_OUT_INTERFACE -d $IP.28.0.0/16 -j DROP
	iptables -w -I INPUT 2 -s $IP.28.0.0/15 -p tcp ! --dport 53 -j DROP
	iptables -w -I INPUT 3 -s $IP.28.0.0/15 -p udp ! --dport 53 -j DROP
fi
# SSH protection
if [[ "$SSH_PROTECTION" == 'y' ]]; then
	iptables -w -I INPUT 2 -p tcp --dport ssh -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 5/hour --hashlimit-burst 5 --hashlimit-mode srcip --hashlimit-srcmask 24 --hashlimit-name antizapret-ssh --hashlimit-htable-expire 60000 -j DROP
	ip6tables -w -I INPUT 2 -p tcp --dport ssh -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 5/hour --hashlimit-burst 5 --hashlimit-mode srcip --hashlimit-srcmask 64 --hashlimit-name antizapret-ssh6 --hashlimit-htable-expire 60000 -j DROP
fi
# Attack protection
if [[ "$ATTACK_PROTECTION" == 'y' ]]; then
	{
		echo 'create antizapret-allow hash:net -exist'
		echo 'flush antizapret-allow'
		if [[ -f result/allow-ips.txt ]]; then
			while read -r line; do
				echo "add antizapret-allow $line"
			done < result/allow-ips.txt
		fi
	} | ipset restore
	ipset create antizapret-block hash:ip timeout 600 -exist
	ipset create antizapret-watch hash:ip,port timeout 600 -exist
	iptables -w -I INPUT 2 -i $DEFAULT_INTERFACE -m set --match-set antizapret-allow src -j ACCEPT
	iptables -w -I INPUT 3 -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m set ! --match-set antizapret-watch src,dst -m hashlimit --hashlimit-above 20/hour --hashlimit-burst 20 --hashlimit-mode srcip --hashlimit-srcmask 24 --hashlimit-name antizapret-scan --hashlimit-htable-expire 600000 -j SET --add-set antizapret-block src --exist
	iptables -w -I INPUT 4 -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 100000/hour --hashlimit-burst 100000 --hashlimit-mode srcip --hashlimit-name antizapret-ddos --hashlimit-htable-expire 600000 -j SET --add-set antizapret-block src --exist
	iptables -w -I INPUT 5 -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m set --match-set antizapret-block src -j DROP
	iptables -w -I INPUT 6 -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -j SET --add-set antizapret-watch src,dst --exist
	ipset create antizapret-allow6 hash:net family inet6 -exist
	ipset create antizapret-block6 hash:ip timeout 600 family inet6 -exist
	ipset create antizapret-watch6 hash:ip,port timeout 600 family inet6 -exist
	ip6tables -w -I INPUT 2 -i $DEFAULT_INTERFACE -m set --match-set antizapret-allow6 src -j ACCEPT
	ip6tables -w -I INPUT 3 -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m set ! --match-set antizapret-watch6 src,dst -m hashlimit --hashlimit-above 20/hour --hashlimit-burst 20 --hashlimit-mode srcip --hashlimit-srcmask 64 --hashlimit-name antizapret-scan6 --hashlimit-htable-expire 600000 -j SET --add-set antizapret-block6 src --exist
	ip6tables -w -I INPUT 4 -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 100000/hour --hashlimit-burst 100000 --hashlimit-mode srcip --hashlimit-name antizapret-ddos6 --hashlimit-htable-expire 600000 -j SET --add-set antizapret-block6 src --exist
	ip6tables -w -I INPUT 5 -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m set --match-set antizapret-block6 src -j DROP
	ip6tables -w -I INPUT 6 -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -j SET --add-set antizapret-watch6 src,dst --exist
fi
# Scan protection
if [[ "$SCAN_PROTECTION" == 'y' ]]; then
	iptables -w -I INPUT 2 -i $DEFAULT_INTERFACE -p icmp --icmp-type echo-request -j DROP
	iptables -w -I OUTPUT 2 -o $DEFAULT_INTERFACE -p tcp --tcp-flags RST RST -j DROP
	iptables -w -I OUTPUT 3 -o $DEFAULT_INTERFACE -p icmp --icmp-type port-unreachable -j DROP
	ip6tables -w -I INPUT 2 -i $DEFAULT_INTERFACE -p icmpv6 --icmpv6-type echo-request -j DROP
	ip6tables -w -I OUTPUT 2 -o $DEFAULT_INTERFACE -p tcp --tcp-flags RST RST -j DROP
	ip6tables -w -I OUTPUT 3 -o $DEFAULT_INTERFACE -p icmpv6 --icmpv6-type port-unreachable -j DROP
fi
# Deny input
{
	echo 'create antizapret-deny hash:net -exist'
	echo 'flush antizapret-deny'
	if [[ -f result/deny-ips.txt ]]; then
		while read -r cidr; do
			echo "add antizapret-deny $cidr"
		done < result/deny-ips.txt
	fi
} | ipset restore
iptables -w -I INPUT 2 -i $DEFAULT_INTERFACE -m set --match-set antizapret-deny src -j DROP

# mangle
# IP-адреса из списков АнтиЗапрета, у которых нет домена (диапазоны Cloudflare, Telegram и т.п.)
{
	echo 'create v2-route hash:net -exist'
	echo 'flush v2-route'
	if [[ -f result/route-ips.txt ]]; then
		while read -r cidr; do
			echo "add v2-route $cidr"
		done < result/route-ips.txt
	fi
} | ipset restore
# Routing marks
# Метка ставится в mangle PREROUTING (приоритет -150), то есть до nat (-100), поэтому здесь
# назначение - ещё fake IP, причём у всех пакетов соединения, а не только у первого.
# Дальше метка выбирает таблицу маршрутизации: 13337 - аплинк, 13335 - WARP, без метки - байпас.
# $FAKE_IP - пул ручного списка uplink-hosts.txt, $WARP_FAKE_IP - пул списка АнтиЗапрета
iptables -w -t mangle -A PREROUTING -s $IP.29.0.0/16 -d $FAKE_IP.0.0/15 -j MARK --set-mark 0x13337
if [[ "$WARP_LIST_ENABLE" == 'y' ]]; then
	# Список АнтиЗапрета целиком уходит в WARP - и домены через свой пул fake IP,
	# и голые IP из ipset (диапазоны Cloudflare, Telegram, у которых домена нет)
	iptables -w -t mangle -A PREROUTING -s $IP.29.0.0/16 -d $WARP_FAKE_IP.0.0/15 -j MARK --set-mark 0x13335
	iptables -w -t mangle -A PREROUTING -s $IP.29.0.0/16 -m set --match-set v2-route dst -j MARK --set-mark 0x13335
else
	# WARP выключен - везти некому, список едет через аплинк, как раньше
	iptables -w -t mangle -A PREROUTING -s $IP.29.0.0/16 -m set --match-set v2-route dst -j MARK --set-mark 0x13337
fi
# Clamp TCP MSS
iptables -w -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -w -t mangle -A OUTPUT ! -o lo -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -w -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -w -t mangle -A OUTPUT ! -o lo -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# raw
# NOTRACK loopback
iptables -w -t raw -A PREROUTING -i lo -j NOTRACK
iptables -w -t raw -A OUTPUT -o lo -j NOTRACK
ip6tables -w -t raw -A PREROUTING -i lo -j NOTRACK
ip6tables -w -t raw -A OUTPUT -o lo -j NOTRACK

# nat
# OpenVPN TCP port redirection for backup connections
if [[ "$OPENVPN_BACKUP_TCP" == 'y' ]]; then
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p tcp --dport 80 -j REDIRECT --to-ports 50080
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p tcp --dport 443 -j REDIRECT --to-ports 50443
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p tcp --dport 504 -j REDIRECT --to-ports 50443
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p tcp --dport 508 -j REDIRECT --to-ports 50080
fi
# OpenVPN UDP port redirection for backup connections
if [[ "$OPENVPN_BACKUP_UDP" == 'y' ]]; then
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 80 -j REDIRECT --to-ports 50080
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 443 -j REDIRECT --to-ports 50443
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 504 -j REDIRECT --to-ports 50443
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 508 -j REDIRECT --to-ports 50080
fi
# WireGuard/AmneziaWG port redirection for backup connections
if [[ "$WIREGUARD_BACKUP" == 'y' ]]; then
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 540 -j REDIRECT --to-ports 51443
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 580 -j REDIRECT --to-ports 51080
fi
# AmneziaWG redirection ports to WireGuard
iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 52080 -j REDIRECT --to-ports 51080
iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 52443 -j REDIRECT --to-ports 51443
# AntiZapret DNS redirection to Knot Resolver
iptables -w -t nat -A PREROUTING -s $IP.29.0.0/16 -p udp --dport 53 -j DNAT --to-destination 127.1.1.1
iptables -w -t nat -A PREROUTING -s $IP.29.0.0/16 -p tcp --dport 53 -j DNAT --to-destination 127.1.1.1
# VPN DNS redirection to Knot Resolver
if [[ "$VPN_DNS" == '1' ]]; then
	iptables -w -t nat -A PREROUTING -s $IP.28.0.0/16 -p udp --dport 53 -j DNAT --to-destination 127.2.2.2
	iptables -w -t nat -A PREROUTING -s $IP.28.0.0/16 -p tcp --dport 53 -j DNAT --to-destination 127.2.2.2
fi
# Mapping fake IP to real IP (WARP list)
# Стоит до Restrict forwarding: после DNAT обход цепочки продолжается уже с реальным адресом
if [[ "$WARP_LIST_ENABLE" == 'y' ]]; then
	iptables -w -t nat -S V2-WARP-MAPPING &>/dev/null || iptables -w -t nat -N V2-WARP-MAPPING
	iptables -w -t nat -A PREROUTING -s $IP.29.0.0/16 -d $WARP_FAKE_IP.0.0/15 -j V2-WARP-MAPPING
fi
# Restrict forwarding
if [[ "$RESTRICT_FORWARD" == 'y' ]]; then
	# Развёрнутый трафик WARP-ветки нельзя метить 0x1 - он не входит в antizapret-forward и его
	# убило бы правило FORWARD. Второй -d в одном правиле iptables не принимает, поэтому исключаем
	# по метке, поставленной в mangle
	iptables -w -t nat -A PREROUTING -s $IP.29.0.0/16 -m mark --mark 0x13335 -j RETURN
	iptables -w -t nat -A PREROUTING -s $IP.29.0.0/16 ! -d $FAKE_IP.0.0/15 -j CONNMARK --set-mark 0x1
fi
# Mapping fake IP to real IP
iptables -w -t nat -S ANTIZAPRET-MAPPING &>/dev/null || iptables -w -t nat -N ANTIZAPRET-MAPPING
iptables -w -t nat -A PREROUTING -s $IP.29.0.0/16 -d $FAKE_IP.0.0/15 -j ANTIZAPRET-MAPPING
# SNAT/MASQUERADE uplink and WARP
# MASQUERADE, а не SNAT: адрес берётся с интерфейса, у WARP он меняется при каждой регистрации
iptables -w -t nat -A POSTROUTING -s $IP.29.0.0/16 -o $UPLINK_INTERFACE -j MASQUERADE
iptables -w -t nat -A POSTROUTING -s $IP.29.0.0/16 -o $WARP_ANTIZAPRET_INTERFACE -j MASQUERADE
# SNAT/MASQUERADE VPN
if [[ "$ANTIZAPRET_OUT_INTERFACE" == "$VPN_OUT_INTERFACE" && "$ANTIZAPRET_OUT_IP" == "$VPN_OUT_IP" ]]; then
	if [[ -z "$ANTIZAPRET_OUT_IP" ]]; then
		iptables -w -t nat -A POSTROUTING -s $IP.28.0.0/15 -o $ANTIZAPRET_OUT_INTERFACE -j MASQUERADE
	else
		iptables -w -t nat -A POSTROUTING -s $IP.28.0.0/15 -o $ANTIZAPRET_OUT_INTERFACE -j SNAT --to-source $ANTIZAPRET_OUT_IP
	fi
else
	if [[ -z "$ANTIZAPRET_OUT_IP" ]]; then
		iptables -w -t nat -A POSTROUTING -s $IP.29.0.0/16 -o $ANTIZAPRET_OUT_INTERFACE -j MASQUERADE
	else
		iptables -w -t nat -A POSTROUTING -s $IP.29.0.0/16 -o $ANTIZAPRET_OUT_INTERFACE -j SNAT --to-source $ANTIZAPRET_OUT_IP
	fi
	if [[ -z "$VPN_OUT_IP" ]]; then
		iptables -w -t nat -A POSTROUTING -s $IP.28.0.0/16 -o $VPN_OUT_INTERFACE -j MASQUERADE
	else
		iptables -w -t nat -A POSTROUTING -s $IP.28.0.0/16 -o $VPN_OUT_INTERFACE -j SNAT --to-source $VPN_OUT_IP
	fi
fi

# Network tuning
SEGMENTATION_OFFLOAD="${SEGMENTATION_OFFLOAD:-off}"
TXQUEUELEN="${TXQUEUELEN:-10000}"
CPU_MASK=$(printf '%x' $(( (1 << $(nproc)) - 1 )))
MTU="${MTU:-1420}"
for dev in $(ls /sys/class/net); do
	[[ "$dev" == "lo" || "$dev" == *docker* ]] && continue
	# Packet segmentation offload
	ethtool -K "$dev" tso "$SEGMENTATION_OFFLOAD" gso "$SEGMENTATION_OFFLOAD" gro "$SEGMENTATION_OFFLOAD"
	if [[ -e "/sys/class/net/$dev/device" ]]; then
		# Set TX queue length
		ip link set "$dev" txqueuelen "$TXQUEUELEN"
		# Enable SoftIRQ CPU balance
		echo "$CPU_MASK" | tee /sys/class/net/$dev/queues/rx-*/rps_cpus >/dev/null
	else
		# Set MTU if current is greater
		if [[ $(cat /sys/class/net/$dev/mtu) -gt $MTU ]]; then
			ip link set "$dev" mtu "$MTU"
		fi
	fi
done

# Clear Knot Resolver cache
# Пустая цепочка означает, что маппинги потеряны, а в кэше могли остаться выданные ранее fake IP
CLEAR_CACHE=0
if [[ "$(iptables -w -t nat -S ANTIZAPRET-MAPPING | wc -l)" -eq 1 ]]; then
	CLEAR_CACHE=1
fi
if [[ "$WARP_LIST_ENABLE" == 'y' && "$(iptables -w -t nat -S V2-WARP-MAPPING | wc -l)" -eq 1 ]]; then
	CLEAR_CACHE=1
fi
if [[ "$CLEAR_CACHE" -eq 1 ]]; then
	count="$(echo 'cache.clear()' | socat - /run/knot-resolver/control/1 | grep -oE '[0-9]+' || echo 0)"
	echo "AntiZapret DNS cache cleared: $count entries"
fi

./custom-up.sh
exit 0
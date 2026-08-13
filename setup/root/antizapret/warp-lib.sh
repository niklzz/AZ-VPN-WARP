# Общее для WARP-ветки: санирование профиля, подъём, регистрация в Cloudflare.
# Подключается из up.sh (поднимает ветку при старте) и warp.sh (выбирает узел),
# чтобы обе стороны собирали интерфейс одинаково. Файл только для source, не исполняется.

WARP_ANTIZAPRET_INTERFACE=warp-antizapret
WARP_SOURCE="${WARP_SOURCE:-/root/v2-warp.conf}"
WARP_ANTIZAPRET_AWG_PATH="/etc/amnezia/amneziawg/$WARP_ANTIZAPRET_INTERFACE.conf"

# Санируем профиль в конфиг awg-quick: DNS вырезаем, иначе awg-quick перепишет /etc/resolv.conf
# самого сервера, а Table и метка обязательны - по ним WARP-ветка находит свой маршрут.
# Профиль при этом может быть любым: хоть положенный руками, хоть сгенерированный ниже
warp_sanitize() {
	mkdir -p /etc/amnezia/amneziawg
	{
		echo '[Interface]'
		echo 'Table = 13335'
		echo 'PostUp = ip rule add fwmark 0x13335 lookup 13335 priority 9001 || true'
		echo 'PostDown = ip rule del fwmark 0x13335 lookup 13335 priority 9001'
		sed -n '/^\[Interface\]/,/^\[Peer\]/p' "$1" | grep -viE '^[[:space:]]*(\[|DNS|Table|PostUp|PostDown)'
		echo
		echo '[Peer]'
		echo 'AllowedIPs = 0.0.0.0/0'
		sed -n '/^\[Peer\]/,$p' "$1" | grep -viE '^[[:space:]]*(\[|AllowedIPs)'
	} > "$WARP_ANTIZAPRET_AWG_PATH"
	chmod 600 "$WARP_ANTIZAPRET_AWG_PATH"
}

# awg-quick рапортует об успехе и на молчащем endpoint - интерфейс UP, tx растёт, rx нулевой,
# и WARP-ветка тихо не работает. Поэтому проверяем факт handshake, а не код возврата
warp_handshake() {
	[[ "$(awg show $WARP_ANTIZAPRET_INTERFACE latest-handshakes 2>/dev/null | awk '{print $2}')" != 0 ]]
}

warp_up() {
	awg-quick up $WARP_ANTIZAPRET_INTERFACE 2>/dev/null || return 1
	local i
	for i in $(seq 1 10); do
		warp_handshake && return 0
		sleep 1
	done
	warp_handshake
}

warp_down() {
	awg-quick down $WARP_ANTIZAPRET_INTERFACE 2>/dev/null || true
}

# Узел Cloudflare, обслуживающий туннель сейчас. Пустая строка - ветка не работает
warp_colo() {
	curl -s --max-time 12 --interface $WARP_ANTIZAPRET_INTERFACE \
		https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^colo=/{print $2}'
}

# Прописывает значение ключа в [Interface] профиля: меняет строку или добавляет, если её нет
warp_set() {
	local file="$1" key="$2" value="$3"
	if grep -qE "^$key *=" "$file"; then
		sed -i "s|^$key *=.*|$key = $value|" "$file"
	else
		sed -i "/^\[Interface\]/a $key = $value" "$file"
	fi
}

# I1 - пакет-обманка перед handshake: DPI видит начало обычной SIP-сессии, а Cloudflare молча
# отбрасывает его как невалидный. Рандомизируем не только идентификаторы, но и участников:
# хрестоматийные alice@atlanta.com / bob@biloxi.com - это пример из RFC 3261, он стоит в
# половине готовых конфигов, и искать по нему проще всего
warp_gen_i1() {
	local users=(alice bob carol dave erin frank grace henry)
	local domains=(atlanta.com biloxi.com example.net voip-provider.net sip-service.com telecom.org)
	local from="${users[RANDOM % ${#users[@]}]}"
	local to="${users[RANDOM % ${#users[@]}]}"
	local from_domain="${domains[RANDOM % ${#domains[@]}]}"
	local to_domain="${domains[RANDOM % ${#domains[@]}]}"
	local host="pc$((RANDOM % 90 + 10)).$from_domain"
	printf 'INVITE sip:%s@%s SIP/2.0\r\nVia: SIP/2.0/UDP %s;branch=z9hG4bK%s\r\nMax-Forwards: 70\r\nTo: <sip:%s@%s>\r\nFrom: <sip:%s@%s>;tag=%s\r\nCall-ID: %s@%s\r\nCSeq: %s INVITE\r\nContact: <sip:%s@%s>\r\nContent-Type: application/sdp\r\nContent-Length: 0\r\n\r\n' \
		"$to" "$to_domain" "$host" "$(openssl rand -hex 8)" "$to" "$to_domain" "$from" "$from_domain" \
		"$(openssl rand -hex 5)" "$(openssl rand -hex 8)" "$host" "$((RANDOM % 900000 + 100000))" "$from" "$host" \
		| xxd -p | tr -d '\n'
}

# Регистрируемся в Cloudflare и пишем профиль в $1.
# Профиль обязан быть обфусцированным: чистый WireGuard из России не поднимается - его handshake
# опознаётся по сигнатуре и режется (симптом: интерфейс UP, tx растёт, rx = 0). Обфускация здесь
# держится на junk-пакетах и I1, а заголовки остаются стандартными (S = 0, H = 1,2,3,4) - иначе
# Cloudflare не ответит, AmneziaWG он не знает
warp_register() {
	local key private endpoint address peer reg api_ip
	private=$(awg genkey)
	key=$(echo "$private" | awg pubkey)
	# api.cloudflareclient.com из России недоступен, а его имя может не резолвиться местным
	# резолвером - соединение уводим в аплинк, а адрес берём через уже прибитый к нему 1.1.1.1
	api_ip=$(kdig +short +time=3 +retry=1 @1.1.1.1 api.cloudflareclient.com | grep -m1 -E '^[0-9.]+$')
	reg=$(curl -sSfL --connect-timeout 10 --interface "${UPLINK_INTERFACE:-az}" \
		${api_ip:+--resolve api.cloudflareclient.com:443:$api_ip} \
		-X POST "https://api.cloudflareclient.com/v0a2158/reg" \
		-H 'Content-Type: application/json' \
		-d "{\"key\": \"$key\"}") || return 1

	peer=$(echo "$reg" | jq -r '.config.peers[0].public_key')
	endpoint=$(echo "$reg" | jq -r '.config.peers[0].endpoint.host')
	address=$(echo "$reg" | jq -r '.config.interface.addresses.v4')
	[[ -z "$peer" || "$peer" == 'null' || -z "$address" || "$address" == 'null' ]] && return 1

	# Endpoint приходит именем, а локальный резолвер возвращает адреса, часть которых молчит,
	# поэтому резолвим через прибитый к аплинку 1.1.1.1 и фиксируем IP в конфиге
	# ponytail: только IPv4 - IPv6 в системе отключён setup.sh
	local ip="${endpoint%:*}" port="${endpoint##*:}"
	[[ "$ip" =~ ^[0-9.]+$ ]] || ip=$(kdig +short +time=3 +retry=1 @1.1.1.1 "${endpoint%:*}" | grep -m1 -E '^[0-9.]+$')
	[[ -z "$ip" ]] && return 1
	# Порт из ответа Cloudflare (2408) с обфускацией проходит. Не пройдёт - тот же endpoint
	# слушает на 500, 1701 и 4500, их и перебирай через WARP_PORT в /root/antizapret/setup
	[[ -n "$WARP_PORT" ]] && port="$WARP_PORT"

	echo "[Interface]
PrivateKey = $private
Address = $address/32
MTU = 1280
Jc = ${WARP_JC:-$((RANDOM % 6 + 3))}
Jmin = ${WARP_JMIN:-$((RANDOM % 20 + 30))}
Jmax = ${WARP_JMAX:-$((RANDOM % 30 + 60))}
S1 = 0
S2 = 0
H1 = 1
H2 = 2
H3 = 3
H4 = 4
I1 = <b 0x$(warp_gen_i1)>

[Peer]
PublicKey = $peer
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 15
Endpoint = $ip:$port" > "$1"
	chmod 600 "$1"
}

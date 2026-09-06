#!/bin/bash
set -e
export LC_ALL=C

# Выбор узла Cloudflare для WARP-ветки.
#
#   warp.sh          меню: сканирует сеть и показывает узлы, через которые работает Telegram
#   warp.sh auto     без вопросов, по списку WARP_NODE - для автофолбэка из up.sh
#   warp.sh LHR      разово применить узел, не трогая сохранённый список
#
# Какой узел обслужит anycast-адрес, решает сеть, а не мы, поэтому нужный может быть недоступен
# в принципе. Тогда решение за пользователем - для этого и меню.

# Обработка ошибок
handle_error() {
	echo "$(lsb_release -ds) $(uname -r) $(date --iso-8601=seconds)"
	echo -e "\e[1;31mError at line $1: $2\e[0m"
	exit 1
}
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

cd /root/antizapret
source setup
source /root/antizapret/warp-lib.sh

WARPSCOUT=/root/antizapret/warpscout
ACCOUNT=/root/antizapret/warpscout-account.json
SETUP=/root/antizapret/setup
UPLINK_INTERFACE="${UPLINK_INTERFACE:-az}"

if [[ ! -x "$WARPSCOUT" ]]; then
	echo "$WARPSCOUT not found! Node selection needs it, reinstall or download it manually"
	exit 1
fi

MODE="${1:-menu}"
# В автофолбэке попыток меньше: его зовёт up.sh из ExecStartPre, где долгий подбор задержит старт
[[ "$MODE" == 'auto' ]] && TUNE_ATTEMPTS="${WARP_TUNE_ATTEMPTS:-6}" || TUNE_ATTEMPTS="${WARP_TUNE_ATTEMPTS:-12}"

# Проверяем до скана, а не после: иначе пользователь ждёт несколько минут ради отказа
if [[ "$MODE" == 'menu' && ! -t 0 ]]; then
	echo 'Menu needs a terminal! Use "warp.sh auto" or pass a node code'
	exit 1
fi

TMP_CONF=$(mktemp)
TMP_REPORT=$(mktemp)
trap 'rm -f "$TMP_CONF" "$TMP_REPORT"' EXIT

# Аккаунт нужен любой команде warpscout. Регистрация идёт через аплинк: api.cloudflareclient.com
# из России не отвечает вовсе, а warpscout умеет привязываться к интерфейсу сам
if [[ ! -f "$ACCOUNT" ]]; then
	echo 'Registering a WARP account...'
	"$WARPSCOUT" register -I "$UPLINK_INTERFACE" -a "$ACCOUNT" || {
		echo 'Registration failed! Check that the uplink is up'
		exit 1
	}
fi

# Скан один на всё: даёт и готовый профиль лучшего endpoint, и список доступных узлов.
# -gen-i1/-gen-junk рандомизируют обфускацию, иначе она была бы одинаковой у всех установок.
# -tg-only оставляет только endpoint'ы, через которые Telegram реально отвечает со всех пяти ДЦ,
# и ранжирует их по отклику Telegram: быстрый узел с мёртвым Telegram нам не нужен
echo 'Scanning Cloudflare endpoints, this takes a few minutes...'
"$WARPSCOUT" scan -p awg -plain -P -no-dns -mtu 1280 \
	-gen-i1 sip -gen-junk -tg-only \
	-conf "$TMP_CONF" -o "$TMP_REPORT" \
	-a "$ACCOUNT" > /dev/null 2>&1 || true

# Секция отчёта "Best endpoint per node": NODE ENDPOINT PING TUN_PING LOSS TG SEEN_AS LOCATION
NODES=$(awk '/^# Best endpoint per node/{f=1; next} f && /^NODE/{next} f && NF {print}' "$TMP_REPORT")

if [[ -z "$NODES" ]]; then
	echo 'No endpoints with working Telegram found! The profile is left as is'
	exit 1
fi

CURRENT=$(awk -F'= *' '/^Endpoint/{print $2; exit}' "$WARP_SOURCE" 2>/dev/null)

# Подбираем исходящий порт под нужный узел.
# Endpoint сам по себе узел не определяет: провайдер балансирует по хешу 5-tuple, куда входит
# и наш ListenPort. При случайном порте один и тот же endpoint даёт то AMS, то LHR, поэтому
# порт перебираем до совпадения и фиксируем в профиле - иначе узел разъедется на первом же рестарте
tune_port() {
	local want="$1" attempt port colo
	for attempt in $(seq 1 "$TUNE_ATTEMPTS"); do
		port=$((RANDOM % 40000 + 20000))
		warp_set "$WARP_SOURCE" ListenPort "$port"
		warp_sanitize "$WARP_SOURCE"
		warp_down
		if ! warp_up; then
			echo "  port $port: no handshake"
			continue
		fi
		colo=$(warp_colo)
		echo "  port $port: ${colo:-no answer}"
		[[ "$colo" == "$want" ]] && return 0
	done
	return 1
}

# Применяет endpoint выбранного узла и подбирает под него порт.
# Меняем только Endpoint и ListenPort: ключи Cloudflare привязаны к аккаунту, а не к адресу,
# поэтому любой рабочий endpoint примет тот же профиль - полный перескан ради смены узла не нужен
apply() {
	local node="$1" endpoint="$2"

	if [[ ! -s "$WARP_SOURCE" ]] || ! grep -q '^Endpoint' "$WARP_SOURCE"; then
		if [[ ! -s "$TMP_CONF" ]]; then
			echo 'Scan produced no config and there is no profile to patch!'
			exit 1
		fi
		cp -f "$TMP_CONF" "$WARP_SOURCE"
	fi
	warp_set "$WARP_SOURCE" Endpoint "$endpoint"
	chmod 600 "$WARP_SOURCE"

	echo "Tuning the source port for $node via $endpoint..."
	if tune_port "$node"; then
		echo "Node $node reached: $endpoint, source port $(awg show $WARP_ANTIZAPRET_INTERFACE listen-port)"
	else
		# Ветку оставляем поднятой: работающий туннель на соседнем узле лучше мёртвого
		local landed
		landed=$(warp_colo)
		echo "Could not land on $node after $TUNE_ATTEMPTS tries, tunnel now on ${landed:-unknown}"
		echo 'Re-run to try again - the landing node depends on the source port and shifts between runs'
	fi
}

# Ищет в результатах скана первый узел из списка (порядок списка - это порядок предпочтений)
pick_from_list() {
	local wanted node endpoint
	for wanted in ${1//,/ }; do
		while read -r node endpoint _; do
			if [[ "$node" == "$wanted" ]]; then
				echo "$node $endpoint"
				return 0
			fi
		done <<< "$NODES"
	done
	return 1
}

case "$MODE" in
	auto)
		# Автоматика не выходит за одобренный список: пусто - берём лучший из найденных
		if [[ -z "$WARP_NODE" ]]; then
			read -r node endpoint _ <<< "$(head -1 <<< "$NODES")"
			apply "$node" "$endpoint"
		elif result=$(pick_from_list "$WARP_NODE"); then
			apply ${result}
		else
			echo "None of the preferred nodes ($WARP_NODE) is reachable! The profile is left as is"
			echo "Available now: $(awk '{print $1}' <<< "$NODES" | sort -u | tr '\n' ' ')"
			echo 'Run warp.sh without arguments to pick from them'
			exit 1
		fi
		;;

	menu)
		echo
		echo 'Cloudflare edge nodes reachable from this server:'
		echo
		printf '     %-6s %-22s %-9s %-6s %-9s %s\n' 'NODE' 'ENDPOINT' 'TUN PING' 'LOSS' 'TG' 'EXIT REGION'
		i=0
		while read -r node endpoint eping tping loss tg seen _; do
			i=$((i + 1))
			mark=''
			[[ "$endpoint" == "$CURRENT" ]] && mark=' <- current'
			printf '  %2d) %-6s %-22s %-9s %-6s %-9s %s%s\n' "$i" "$node" "$endpoint" "$tping" "$loss" "$tg" "$seen" "$mark"
		done <<< "$NODES"
		echo
		echo 'Enter nodes in order of preference, comma-separated - the first reachable one is used'
		echo 'and the list is saved for automatic recovery when an endpoint dies'
		AVAILABLE=$(awk '{print $1}' <<< "$NODES" | sort -u | tr '\n' ',' | sed 's/,$//')
		until [[ -n "$CHOICE" ]]; do
			read -rp "Nodes [${WARP_NODE:-$AVAILABLE}]: " -e -i "${WARP_NODE:-$AVAILABLE}" CHOICE
		done

		if ! result=$(pick_from_list "$CHOICE"); then
			echo "None of the entered nodes ($CHOICE) was found in the scan!"
			exit 1
		fi

		# Сохраняем выбор: по нему пойдёт автофолбэк, когда спросить будет некого
		if grep -q '^WARP_NODE=' "$SETUP"; then
			sed -i "s|^WARP_NODE=.*|WARP_NODE=$CHOICE|" "$SETUP"
		else
			echo "WARP_NODE=$CHOICE" >> "$SETUP"
		fi
		apply ${result}
		;;

	*)
		if ! result=$(pick_from_list "$MODE"); then
			echo "Node $MODE is not reachable from this server!"
			echo "Available now: $(awk '{print $1}' <<< "$NODES" | sort -u | tr '\n' ' ')"
			exit 1
		fi
		apply ${result}
		;;
esac

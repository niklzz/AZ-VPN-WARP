# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Что это

**V2** — форк [GubernievS/AntiZapret-VPN](https://github.com/GubernievS/AntiZapret-VPN), живёт в
`niklzz/az-vpn`. Набор bash-скриптов и конфигов для развёртывания на Ubuntu 24.04+ / Debian 13+.
Никакой сборки/CI — это чистый deploy-код.

Отличие от апстрима: сервер ставится **внутри России** и разводит трафик по трём путям вместо одного.

| путь | что попадает | пул fake IP | метка | таблица | выход |
|---|---|---|---|---|---|
| байпас | всё, что не в списках | — | — | main | провайдер клиента (в туннель не входит) |
| заграница | `config/uplink-hosts.txt` (ручной, **приоритет**) | `FAKE_IP` = 198.18/15 | `0x13337` | 13337 | аплинк `az` (AmneziaWG) |
| WARP | список АнтиЗапрета (реестр РКН) | `WARP_FAKE_IP` = 10.30/15 | `0x13335` | 13335 | `warp-antizapret`, российский адрес Cloudflare |

**Список АнтиЗапрета идёт через WARP, а не за границу.** Обфусцированный туннель прячет его от DPI,
и этого достаточно для обхода блокировок, а выходной адрес остаётся российским — многие ресурсы
отдают россиянам контент лучше, чем хостинговым IP. Зарубежный аплинк возит только то, что вписано
руками в `uplink-hosts.txt`: сервисы, недоступные из России по геолокации. Приоритет у аплинка —
домен, попавший в оба списка, уходит за границу; обеспечивается порядком политик в `kresd.conf`
(`uplink.rpz` добавляется раньше `proxy.rpz`). Голые IP из ipset `v2-route` (Cloudflare, Telegram —
у них нет домена) метятся в WARP вместе со всем списком.

Зарубежный сервер — **тупая выходная нода**: любой WG/AWG-сервер, от него нужен только клиентский
профиль и NAT своих пиров в интернет. Вся логика (kresd, `proxy.py`, fake-IP, DNAT, списки) — на RU-сервере.

**Списки берутся из апстрима, код — из форка.** `update.sh` тянет `update.sh`/`parse.sh`/`doall.sh` с
`raw.githubusercontent.com/niklzz/az-vpn/main/...` (с `GITHUB_TOKEN`, если репа приватная), а все
курируемые списки — по-прежнему с `GubernievS`. Правка файла здесь = изменение поведения всех установок
после ближайшего `doall.sh`.

Полный VPN (`10.28.0.0/16`, файлы `vpn-*`) сохранён от апстрима без изменений.

## Ключевые грабли

- **`setup/` — это зеркало корня файловой системы сервера.** `setup.sh` делает `cp -r /tmp/antizapret/setup/* /`.
  Путь в репе `setup/root/antizapret/parse.sh` → на сервере `/root/antizapret/parse.sh`.
- **Установщик игнорирует локальную копию репы.** `setup.sh` клонирует `$V2_REPO` (`niklzz/az-vpn`), а `update.sh`
  тянет три скрипта по хардкоженым `raw.githubusercontent` URL из `main`. Чтобы протестировать правки, их надо
  сначала запушить в форк (или поменять `V2_REPO`/ветку). Локальный чекаут установщик не видит.
- **Профиль аплинка обязателен до старта установки.** `setup.sh` падает с кодом 11, если нет `/root/v2-uplink.conf`.
  Он санируется в `/etc/amnezia/amneziawg/az.conf`: `DNS` вырезается (иначе `awg-quick` перепишет `resolv.conf`
  сервера), добавляются `Table = 13337`, `MTU = 1320` и `ip rule` по метке. Параметры обфускации
  (`Jc/Jmin/Jmax/S1/S2/H1..H4/I1`) переносятся из профиля как есть.
- **`update.sh` перезаписывает сам себя, `parse.sh` и `doall.sh`** при каждом запуске (первые три `download` в
  [update.sh](setup/root/antizapret/update.sh#L127-L129)). Правки этих файлов прямо на сервере живут до первого
  обновления. `doall.sh` умеет это отследить: сравнивает sha256 до/после и перезапускает `update.sh`.
- **`/root/antizapret/setup`** — рантайм-конфиг (KEY=VALUE), генерируется `setup.sh` из ответов пользователя
  ([setup.sh:457-507](setup.sh#L457-L507)), в репе его нет. Его `source`-ят `up.sh`, `down.sh`, `parse.sh`, `update.sh`.
  Добавляя новую опцию, нужно: вопрос в `setup.sh` → строка в блоке генерации `setup` → чтение в потребителе.
  Часть значений (`MTU`, `TXQUEUELEN`, `CLIENT_IP`, `*_OUT_INTERFACE`) правится только вручную в этом файле.
  Файл теперь `chmod 600` — в нём лежит `GITHUB_TOKEN`.
- **`FAKE_IP` и `WARP_FAKE_IP` пишутся конкретными значениями**, а не пустыми: их читает systemd через
  `EnvironmentFile` в `antizapret.service` и `v2-warp-proxy.service`, а там подстановок по умолчанию нет —
  пустое значение даст `.0.0/15` и `proxy.py` не стартует. Диапазоны всегда противоположны
  (`198.18` ↔ `$IP.30`), чтобы не пересечься. Меняя `CLIENT_IP` вручную, поправь и их.
- **Порядок правил в `nat PREROUTING` несущий.** Переход в `V2-WARP-MAPPING` стоит **до** `RESTRICT_FORWARD`,
  а сразу за ним — `-m mark --mark 0x13335 -j RETURN`. Без `RETURN` уже развёрнутый WARP-трафик получил бы
  `connmark 0x1` и был бы убит правилом `FORWARD` как «не в `antizapret-forward`»; а если `RETURN` поставить
  выше перехода — он оборвёт обход цепочки до DNAT. Второй `-d` в одном правиле iptables не принимает,
  поэтому исключение и сделано через метку.
- **`setup.sh` идемпотентен и деструктивен**: сносит `/etc/openvpn/server/*`, `/etc/wireguard/templates/*`, пакеты
  (ufw, firewalld, apparmor, snapd, rsyslog…), в конце делает `reboot`. Пользовательское переживает переустановку
  только если лежит в `config/*.txt`, `custom*.sh`, `/etc/knot-resolver/*.lua` или в `backup*.tar.gz`.
- Скрипты пишутся с табами, `set -e` + `trap handle_error ERR`, комментарии внутри — на русском (сложившийся стиль репы).

## Архитектура: как работает подмена IP

Ядро AntiZapret — цепочка DNS → fake IP → DNAT. Понимание нужно почти для любой правки:

1. Клиент AntiZapret (`10.29.0.0/16`) шлёт DNS-запрос → `iptables nat PREROUTING` DNAT'ит его на `127.1.1.1`
   ([up.sh](setup/root/antizapret/up.sh)) — это **kresd@1**.
2. **kresd@1** ([kresd.conf](setup/etc/knot-resolver/kresd.conf), ветка `SYSTEMD_INSTANCE ^1`) применяет
   два RPZ подряд: сначала `uplink.rpz` → `policy.STUB('127.3.3.3')` (аплинк), потом `proxy.rpz` →
   `policy.STUB('127.4.4.4')` (WARP). **Порядок и есть приоритет:** политики kresd проверяются в порядке
   добавления, поэтому домен из обоих списков уходит за границу. Не попавшие никуда резолвятся российскими
   апстримами (`dns1`), AAAA всегда `::`, HTTPS/SVCB — NODATA.
3. **proxy.py** ([proxy.py](setup/root/antizapret/proxy.py)) — два экземпляра одного файла, различаются только
   аргументами `--address` / `--chain` / `--ip-range` (юниты `antizapret.service` и `v2-warp-proxy.service`).
   Оба спрашивают **kresd@2** (`127.2.2.2`), берут реальный A-адрес, выдают клиенту **fake IP** из своего пула
   и добавляют `iptables -t nat -A <chain> -d <fake> -j DNAT --to <real>`. Мапинги живут в самой цепочке
   iptables (она же — состояние при рестарте), протухают через `ttl*2`.
4. Клиент маршрутизирует **оба** fake-диапазона в туннель (`ccd/DEFAULT` для OpenVPN,
   `AllowedIPs`/`/etc/wireguard/ips` для WG).
5. Пакет приходит на сервер: в `mangle PREROUTING` (приоритет −150, то есть **до** `nat` с −100) по ещё не
   подменённому dst ставится метка, в `nat PREROUTING` адрес разворачивается в реальный, а метка выбирает
   таблицу маршрутизации → аплинк или WARP. Метка садится на все пакеты соединения, поэтому `CONNMARK`
   с restore не нужен.

Апстримы kresd@2 (`1.1.1.1` и соседи) и регистрация Cloudflare WARP прибиты к аплинку: из России Cloudflare
недоступен, а по заблокированным доменам ТСПУ ещё и подменяет DNS-ответы — иначе весь fake-IP-механизм
тихо получал бы мусорные адреса. Маршруты ставятся через `ip route replace <ip> dev az` и исчезают вместе
с интерфейсом, поэтому зеркала в `down.sh` не требуют.

**Профиль WARP обязан быть обфусцированным.** Чистый WireGuard из России не поднимается: его handshake
опознаётся по сигнатуре и режется (симптом: интерфейс UP, `proxy.py` живой, а `awg show warp-antizapret`
растёт только по `sent`, `0 B received`). Порт тут ни при чём — с обфускацией проходит тот же `2408`,
на котором молчал чистый WG.

Профиль берётся из `/root/v2-warp.conf`, и `up.sh` санирует его в
`/etc/amnezia/amneziawg/warp-antizapret.conf` (вырезает `DNS` — иначе `awg-quick` перепишет `resolv.conf`
сервера, добавляет `Table = 13335` и `ip rule` по метке), поднимая через **`awg-quick`**. Источников
профиля три, по убыванию приоритета:

1. **Положенный руками** `/root/v2-warp.conf` — не перезаписывается установщиком.
2. **`warp.sh`** — генерирует через `warpscout` под нужный узел Cloudflare (см. ниже).
3. **Своя генерация в `up.sh`** — если файла нет, регистрируется в Cloudflare сам и пишет
   обфусцированный профиль. Работает без внешних зависимостей.

Обфускация здесь совместима с Cloudflare, потому что **заголовки остаются стандартными**: `S1..S4 = 0`,
`H1..H4 = 1,2,3,4`. Всё маскирование — это junk-пакеты (`Jc/Jmin/Jmax`) и фейковый `I1`, которые
Cloudflare молча отбрасывает как невалидные, а DPI на них сбивается. Поставишь ненулевые `S` или
нестандартные `H` — Cloudflare перестанет отвечать, AmneziaWG он не знает. `I1` генерируется заново
при каждой регистрации, с рандомными участниками SIP-сессии: константный пакет одинаков у всех
установок и сам стал бы сигнатурой (в частности, `alice@atlanta.com`/`bob@biloxi.com` — пример
из RFC 3261, растиражированный по готовым конфигам).

Туннель идёт **байпасом**, не в аплинк: Cloudflare выдаёт адрес той страны, откуда пришли пакеты,
поэтому прямой выход из России даёт российский Cloudflare-адрес — уведёшь в аплинк, получишь адрес
страны аплинка, и смысл ветки теряется. Регистрация (`api.cloudflareclient.com`) наоборот идёт
**только через аплинк** — из России домен не отвечает вовсе.

**Выбор узла Cloudflare — `warp.sh`** (`/root/antizapret/warp.sh`, бинарник `warpscout` рядом):

| вызов | что делает |
|---|---|
| `warp.sh` | сканирует сеть, показывает доступные узлы с RTT и даёт выбрать; выбор сохраняется в `WARP_NODE` |
| `warp.sh auto` | по списку `WARP_NODE`, без вопросов — этим пользуется автофолбэк |
| `warp.sh LHR` | разово применить узел, не трогая сохранённый список |

`WARP_NODE` — список через запятую в порядке предпочтения (`HEL,ARN,FRA`). Автоматика идёт по нему
сверху вниз и **за пределы списка не выходит**. Какой узел обслужит anycast-адрес, решает сеть:
с Vpsville, например, доступны только `AMS` и `LHR`, а `HEL` не появляется вовсе — поэтому выбор
и оставлен за человеком.

**Узел определяется не одним endpoint, а парой «endpoint + исходящий порт».** Провайдер балансирует
по хешу 5-tuple, куда входит и `ListenPort` туннеля. При случайном порте один и тот же адрес даёт
то `AMS`, то `LHR` — проверено: три подъёма подряд с разными портами разошлись по узлам, а с
фиксированным `ListenPort` узел стабилен. Поэтому `warp.sh` перебирает порты до попадания в нужный
узел и **фиксирует `ListenPort` в профиле**; без этого выбор узла разъезжался бы на первом рестарте.
Сами ключи менять не нужно — они привязаны к аккаунту Cloudflare, а не к адресу, поэтому смена узла
это правка `Endpoint` и `ListenPort`, а не перерегистрация.

Не путать `colo` и `loc` в `curl --interface warp-antizapret https://www.cloudflare.com/cdn-cgi/trace`:
`colo` — узел, который обрабатывает запрос (отсюда латентность), `loc` — геолокация выданного
выходного адреса, которую видят сайты. Они расходятся: `colo=AMS` при `loc=RU` — нормально.

Диагностика: `up.sh` ждёт именно handshake, а не код возврата `awg-quick` — тот рапортует об успехе
и на молчащем endpoint. Не случился — `up.sh` зовёт `warp.sh auto` (`timeout 300`, иначе скан подвесил бы
`ExecStartPre`), и тот сам подбирает endpoint с портом и оставляет ветку поднятой. `systemctl restart`
из `warp.sh` не делается вовсе — иначе получился бы дедлок при вызове из `ExecStartPre`.

Общий код подъёма ветки живёт в [warp-lib.sh](setup/root/antizapret/warp-lib.sh) и подключается
`source`-ом из `up.sh` и `warp.sh`: санирование профиля, `awg-quick up` с ожиданием handshake,
регистрация в Cloudflare, генерация `I1`. Правку логики подъёма вносить туда, а не в оба скрипта.

Полный VPN (`10.28.0.0/16`) проще: DNS → kresd@2 (если `VPN_DNS=1`), трафик просто SNAT/MASQUERADE через
российского провайдера. Побочный эффект пункта выше: при `VPN_DNS=1` он получает заграничный DNS при
российском выходе — нужна российская геолокация, выбирай `VPN_DNS` ≠ 1.

`fallback.lua` ([setup/usr/lib/knot-resolver/kres_modules/fallback.lua](setup/usr/lib/knot-resolver/kres_modules/fallback.lua))
— самописный модуль kresd: при таймауте 2с, SERVFAIL или пустом A-ответе переключает запрос на резервные апстримы.
`setup.sh` дополнительно патчит штатный `policy.lua`, меняя `policy.PASS` на `return nil` ([setup.sh:591](setup.sh#L591)).

## Пайплайн списков

`doall.sh` = `update.sh` (скачать) + `parse.sh` (обработать и применить). Запускается по таймеру
`antizapret-update.timer` раз в сутки 02:00–04:00 (+ до 2ч рандома).

- **`update.sh`** — только скачивание в `download/` (папка каждый раз пересоздаётся). Источники: реестр РКН
  (`bol-van/rulist`, `antifilter.download`), AdGuard/OISD для adblock, плюс курируемые списки из этой репы.
  При провале прямого запроса ретрай через `api.codetabs.com` прокси; после скачивания сверяется `Content-Length`.
- **`parse.sh`** — вся логика фильтрации. Собирает `config/*.txt` + `download/*.txt` → `result/`:
  - `result/include-hosts.txt` → `/etc/knot-resolver/proxy.rpz` (реестр РКН, едет через **WARP**);
    попутно чистит казино/букмекеров regex'ом (`CLEAR_HOSTS`), схлопывает избыточные поддомены через `rev`+`sort`+`awk`.
  - `config/uplink-hosts.txt` → `result/uplink-hosts.txt` → `/etc/knot-resolver/uplink.rpz` (что гнать через
    **зарубежный аплинк**). Только пользовательский файл, скачиваемых источников у этого списка нет,
    и он имеет приоритет над реестром.
  - `result/route-ips.txt` → `ccd/DEFAULT` (push route для OpenVPN), `/etc/wireguard/ips` (для AllowedIPs),
    плюс готовые файлы маршрутов для TP-Link / Keenetic / MikroTik. В маршруты клиента идут **оба**
    fake-диапазона — иначе WARP-ветка до сервера не доедет.
  - `deny.rpz` / `deny2.rpz` — блокировка рекламы для AntiZapret и полного VPN раздельно.
  - ipset'ы `antizapret-drop`, `antizapret-deny`, `antizapret-forward`, `antizapret-allow`, `v2-route` —
    заливаются через `ipset restore`. `v2-route` = `result/route-ips.txt`, по нему `up.sh` метит трафик
    к IP-адресам АнтиЗапрета без домена (диапазоны Cloudflare, Telegram) в аплинк.
  - RPZ-файлы обновляются только при реальном изменении (diff), затем `cache.clear()` через `socat` в control-сокет kresd.
- **`config/` vs `download/`**: `config/` — пользовательское (переживает переустановку), `download/` — скачанное,
  в репе лежат курируемые автором списки, которые как раз оттуда и скачиваются.
- Аргумент `ip`/`host`/`noclear` пробрасывается через всю цепочку: `ip` — только IP-списки, `host` — только домены,
  `noclear` — не чистить кэш DNS.

## Firewall и сервисы

`antizapret.service` = `ExecStartPre=up.sh` → `ExecStart=proxy.py` → `ExecStopPost=down.sh`.
`v2-warp-proxy.service` — второй экземпляр `proxy.py` под WARP-ветку, `BindsTo`+`After` антизапрета
(`Type=simple` не допускает двух `ExecStart`). Цепочку `V2-WARP-MAPPING` создаёт `up.sh`, поэтому юнит
включается только при `WARP_LIST_ENABLE=y` — иначе он уйдёт в crash-loop.

Все правила iptables живут в [up.sh](setup/root/antizapret/up.sh) (создание) и [down.sh](setup/root/antizapret/down.sh)
(зеркальное удаление) — **правки нужно вносить в оба файла**, iptables-persistent здесь не используется (в отличие от
`proxy.sh`). Правила вставляются через `-I <chain> <N>` с явными номерами, поэтому порядок блоков в `up.sh` значим.

Опциональные блоки в `up.sh`, управляемые флагами из `setup`: `UPLINK_ENABLE` (поднимает `az` через `awg-quick`,
таблица 13337), `TORRENT_GUARD`, `RESTRICT_FORWARD` (connmark 0x1 + ipset), `CLIENT_ISOLATION`, `SSH_PROTECTION`,
`ATTACK_PROTECTION` (scan/DDoS через hashlimit + ipset с timeout), `SCAN_PROTECTION`, редиректы резервных портов,
`WARP_LIST_ENABLE` / `VPN_WARP` (поднимают `warp-antizapret`/`warp-vpn`, таблицы 13335/13336).

`CLIENT_ISOLATION` пришлось переписать: апстримное `! -i $ANTIZAPRET_OUT_INTERFACE -d 10.29.0.0/16 -j DROP`
рассчитано на **один** выход и убивает обратный трафик с `az` и `warp-antizapret`. Теперь перед ним стоят
два `ACCEPT` по `-i`. Они матчат `-d` (трафик к клиентам) и потому не задевают ни torrent guard,
ни `antizapret-drop` — те матчат `-s`.

SNAT для аплинка и WARP делается через `MASQUERADE`, а не `SNAT --to-source`: адрес берётся с интерфейса,
а у WARP он меняется при каждой регистрации. Апстримный `down.sh` читал `Address` вместе с `/32` и отдавал
его в `--to-source`, чего iptables не принимает; при `exec 2>/dev/null` это было не видно, и мёртвые правила
копились от рестарта к рестарту — маска теперь срезается.

Точки расширения для пользователя, которые нельзя ломать: `custom-doall.sh`, `custom-update.sh`, `custom-parse.sh`,
`custom-up.sh`, `custom-down.sh` (заглушки `exit 0`), `custom.lua`/`custom2.lua`, `renumber.lua`/`renumber2.lua`.

## Команды

Локально ни собрать, ни протестировать нечего — проверка только на живом Ubuntu/Debian VPS под root.

```bash
# Установка (на сервере, под root). Профиль аплинка должен уже лежать в /root/v2-uplink.conf
scp foreign-client.conf root@СЕРВЕР:/root/v2-uplink.conf
scp setup.sh root@СЕРВЕР:/root/setup.sh && ssh root@СЕРВЕР bash /root/setup.sh

/root/antizapret/doall.sh [ip|host|noclear]   # обновить списки: update.sh + parse.sh
/root/antizapret/parse.sh ip                  # только пересобрать IP-списки и ipset'ы
/root/antizapret/client.sh [1-9] [имя] [дней] # 1-3 OpenVPN, 4-6 WG/AWG, 7 пересоздать профили, 8 backup, 9 restore
/root/antizapret/patch-openvpn.sh [0-3]       # патч обхода DPI: 0 снять, 1 random, 2 strong, 3 error-free
/root/antizapret/openvpn-dco.sh [y/n]         # DCO (требует OpenVPN 2.7)
/root/antizapret/warp.sh [auto|УЗЕЛ]          # узел Cloudflare: без аргумента - меню со сканом (~3 мин)

systemctl restart antizapret                  # передёрнуть firewall + оба proxy.py
journalctl -u antizapret -u v2-warp-proxy -u kresd@1 -u kresd@2 -f
echo 'cache.clear()' | socat - /run/knot-resolver/control/1

# Диагностика трёх путей
awg show az                                   # handshake с зарубежным сервером
ip rule                                       # fwmark 0x13337 -> 13337, 0x13335 -> 13335
ip route show table 13337                     # default через az
dig +short @127.1.1.1 example.com             # 198.18.x - заграница, 10.30.x - WARP, реальный - байпас
iptables -t nat -S ANTIZAPRET-MAPPING | head  # мапинги fake->real заграничной ветки
iptables -t nat -S V2-WARP-MAPPING | head     # мапинги fake->real WARP-ветки
```

Синтаксис перед коммитом: `bash -n <файл>.sh`, `luac -p <файл>.lua` (если доступен), `python3 -m py_compile proxy.py`.

## Git

Репа личная, форк живёт в `niklzz/az-vpn`, правило про MTS-репы не действует; коммит — только по явной просьбе.
Стиль сообщений в истории: `Update <имя файла>`.

**Правки надо пушить в форк, чтобы их увидел сервер:** `setup.sh` клонирует `niklzz/az-vpn`, а `update.sh`
каждую ночь перетягивает оттуда себя, `parse.sh` и `doall.sh`. Локальный чекаут установщику не виден.

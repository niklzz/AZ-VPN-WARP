# AntiZapret VPN на сервере в РФ при помощи WARP

Форк [AntiZapret-VPN](https://github.com/GubernievS/AntiZapret-VPN) для установки на сервер
**внутри РФ**, который разводит трафик по трём маршрутам вместо двух. В чем разница с оригинальным проектом и зачем нужен еще один "велосипед"? 

Поковыряв WARP и выяснив, что если выходная нода WARP является не DME/LED, то мы получаем следующие плюсы:
- Обход блокировки для ТГ на более высокой скорости (если сравнивать с забугорными серверами) и без лагов
- При использовании WARP, ЮТУБ работает без рекламы т.к регион определяется как РФ
- Соединение РФ-РФ не так жестко блокируется ТСПУ, как РФ-ЗАРУБЕЖ. Клиент может ходить, даже по чистому WG
- Получить сервер в РФ проще, не нужны иностранные карты
- Так как весь список AZ завернут в WARP, сильно выше скорость/отзывчивость сайтов в целом
- Зарубежный сервер нужен только для сайтов из гео-блока, что позволяет по вашему усмотрению, от него отказаться полностью.
- Требования к ресурсам и пропускной способности зарубежного сервера на порядки ниже т.к теперь он нужен только для сайтов из гео-блока

Что доработано:
- Для az.conf теперь три маршрута для трафика
- Интегрирован генератор WARP соединений с обфускацией AmneziaWG
- Интегрирован "сканер" WARP серверов, который показывает доступные выходные ноды (HEL,ARN,DME) с вашего сервера и дает выбирать ноду с лучшим пингом и не

## Пояснения по трем маршрутам в AZ
```
клиент ---- РФ сервер ---------+-- ByPASS   -> провайдер клиента, трафик идет мимо ВПН туннеля
                               |-- WARP     -> Cloudflare c РФ адресом
                               `-- UPLINK   -> зарубежный сервер
```

| путь | что туда попадает | подменные IP | выход |
|---|---|---|---|
| **ByPASS** | всё, чего нет в списках | — | провайдер клиента, в туннель не входит |
| **WARP** | список АнтиЗапрета (берется из оригинального репо автора GubernievS/AntiZapret-VPN): + `config/include-hosts.txt/include-ips.txt` | `10.30.0.0/15` | Cloudflare WARP, адрес российский |
| **UPLINK** | только `config/uplink-hosts.txt` и `config/uplink-ips.txt` | `198.18.0.0/15` | зарубежный сервер по AmneziaWG |


**UPLINK приоритетнее.** Домен, попавший в оба списка, уходит в UPLINK.

Полный VPN (файлы `vpn-*`) сохранён от апстрима без изменений: весь трафик через сервер как прокси.

### Что нужно от зарубежного сервера

Ничего, кроме одного клиентского профиля. Это может быть любой AmneziaWG-сервер, поднятый
чем угодно. Логики АнтиЗапрета там нет и менять на нём нечего. Единственное требование: он NAT'ит своих пиров в интернет.

Профиль должен быть **обфусцированным** (AmneziaWG): чистый WireGuard из России не поднимается,
handshake режется по сигнатуре — интерфейс будет UP, а `received` останется нулевым.

Вся логика — kresd, `proxy.py`, подменные IP, DNAT, списки — живёт на РФ сервере.

***

## Требования

- Ubuntu 24.04 / Debian 13 или новее, чистая система, доступ под root
- сервер **в России** — в этом весь смысл сборки, за границей нужен оригинальный AntiZapret
- 1 CPU / 1 ГБ RAM / 10 ГБ диска минимум, комфортно — 2 / 2 / 20 (kresd со временем занимает ~220 МБ под кеш)
- внешний IPv4-адрес; за NAT (домашняя виртуалка) — проброс UDP-портов на сервер и DDNS-имя,
  которое надо указать установщику в вопросах про domain name
- клиентский профиль зарубежного сервера

Установщик **деструктивен и идемпотентен**: сносит `/etc/openvpn/server/*`, `/etc/wireguard/templates/*`,
удаляет пакеты (ufw, firewalld, apparmor, snapd, rsyslog), в конце перезагружает сервер. Пользовательское
переживает переустановку, только если лежит в `config/*.txt`, `custom*.sh`, `/etc/knot-resolver/*.lua`
или в `backup*.tar.gz`.

## Установка

**1. Положить профиль (файл с full vpn amneziaWG с зарубежного сервера) UPLINK в `/root` — до запуска установщика**, без него установка не начнётся.
Имя файла любое: установщик сам найдёт `*.conf` в `/root`, а если их несколько — спросит, какой из них аплинк.

```bash
scp foreign-server-client.conf root@СЕРВЕР:/root/
```

**2. Запустить установщик под root:**

```bash
ssh root@СЕРВЕР
curl -O https://raw.githubusercontent.com/niklzz/AZ-VPN-WARP/main/setup.sh
bash setup.sh
```

**3. Ответить на вопросы.** Почти везде подходит значение по умолчанию — Enter. Осмысленно ответить
надо на эти:

| вопрос | ответ | почему |
|---|---|---|
| `Route the AntiZapret list through RU Cloudflare WARP?` | `y` | ради этого всё и делалось |
| `Preferred WARP nodes:` | пусто | это список только для автовосстановления, реальный выбор узла — шаг 5 |
| `DNS resolvers for full VPN` | **не 1**, например `4` | при `1` полный VPN получит заграничный DNS при российском выходе |
| `domain name for this OpenVPN server` | внешний IP или DDNS-имя | обязательно за NAT, иначе в профиль попадёт локальный адрес |
| `domain name for this WireGuard/AmneziaWG server` | то же | то же |

Установка идёт 10–20 минут — собираются патченный OpenVPN и AmneziaWG, — в конце сервер перезагрузится сам.

**4. Забрать профили клиентов** из подпапок `/root/antizapret/client`:

```bash
scp 'root@СЕРВЕР:/root/antizapret/client/amneziawg/antizapret/*.conf' ~/Desktop/
```

`antizapret/` — три пути (обычный вариант), `vpn/` — весь трафик через сервер.
По умолчанию создаётся один клиент `antizapret-client`, новые — через `client.sh`.

**5. Выбрать оптимальный узел Cloudflare** — только после перезагрузки, скан требует поднятых туннелей:

```bash
/root/antizapret/warp.sh
```

Скан идёт пару минут и показывает узлы, реально доступные из этой сети, с задержкой. Выбранное
сохраняется в `WARP_NODE` и используется для автовосстановления, если endpoint перестанет отвечать.
Нужного узла может не быть вовсе — какой PoP обслужит anycast-адрес, решает сеть.
Не выбрать ничего тоже нормально: первый старт берёт endpoint, который выдала регистрация Cloudflare.


**Обновление** — повторный запуск `setup.sh`; списки и клиенты в `config/` переживают переустановку.
Списки сами обновляются раз в сутки ночью (таймер `antizapret-update.timer`, 02:00–04:00 + до 2 часов рандома).

***

## Списки: какой файл куда ведёт

Все файлы — в `/root/antizapret/config/`, переживают переустановку. В каждом — по одной записи на строку.

| файл | что делает | чем применить |
|---|---|---|
| `uplink-hosts.txt` | домены **за границу** | `parse.sh host` |
| `uplink-ips.txt` | адреса и подсети **за границу** | `parse.sh ip` + `systemctl restart antizapret` |
| `include-hosts.txt` | добавить домены в список АнтиЗапрета (пойдут через **WARP**) | `parse.sh host` |
| `include-ips.txt` | добавить адреса в список АнтиЗапрета (**WARP**) | `parse.sh ip` |
| `exclude-hosts.txt` | убрать домены из списка АнтиЗапрета (пойдут **мимо VPN**) | `parse.sh host` |
| `exclude-ips.txt` | убрать адреса из списка АнтиЗапрета | `parse.sh ip` |
| `allow-ips.txt` | исключения для защиты от сканирования | `parse.sh ip` |
| `forward-ips.txt` | что разрешено при `RESTRICT_FORWARD` | `parse.sh ip` |

Домены — без схемы и путей: `example.com`, `subdomain.example.com`, можно и целиком `com`.
Адреса — с маской: `8.8.8.8/32`, `20.30.40.0/24`.
Остальные файлы в `config/` (`deny-ips`, `drop-ips`, `*-adblock-hosts`, `rpz*`, `remove-hosts`) —
от апстрима, работают как в оригинале.

```bash
nano /root/antizapret/config/uplink-hosts.txt
/root/antizapret/parse.sh host
```

`doall.sh` = скачать свежие списки + применить, `parse.sh` — только применить уже скачанное.
Аргумент `host` / `ip` ограничивает работу доменами или адресами, без аргумента делается всё.

После добавления **IP-адресов** клиентам OpenVPN достаточно переподключиться, а клиентам
WireGuard/AmneziaWG нужно дописать новые адреса в `AllowedIPs` своего профиля (или пересоздать
профили через `client.sh 7`).

***

## Управление

```bash
/root/antizapret/client.sh [1-9] [имя] [дней]  # 1-3 OpenVPN, 4-6 WG/AWG, 7 пересоздать профили, 8 бэкап, 9 восстановить
/root/antizapret/warp.sh [auto|УЗЕЛ]           # узел Cloudflare: без аргумента - меню со сканом
/root/antizapret/doall.sh [host|ip|noclear]    # обновить списки: скачать + применить
/root/antizapret/parse.sh [host|ip|noclear]    # применить уже скачанные списки
/root/antizapret/patch-openvpn.sh [0-3]        # патч обхода блокировки OpenVPN: 0 снять, 1 random, 2 strong, 3 error-free
/root/antizapret/openvpn-dco.sh [y/n]          # OpenVPN DCO: меньше нагрузка на CPU, только AES-GCM и CHACHA20
systemctl restart antizapret                   # передёрнуть firewall и оба proxy.py
```

Настройки установки лежат в `/root/antizapret/setup` (`KEY=VALUE`, режим 600 — там токен GitHub).
Часть значений правится только руками: `MTU`, `TXQUEUELEN`, `CLIENT_IP`, `*_OUT_INTERFACE`.

## Диагностика

```bash
# каким путём пойдёт домен
dig +short @127.1.1.1 example.com    # 198.18.x - заграница, 10.30.x - WARP, реальный адрес - байпас

# три выхода с самого сервера
curl -s https://api.ipify.org; echo                              # провайдер сервера
curl -s --interface az https://api.ipify.org; echo               # зарубежный сервер
curl -s --interface warp-antizapret https://api.ipify.org; echo  # Cloudflare

# туннели и маршрутизация
awg show az                          # handshake с зарубежным сервером
awg show warp-antizapret             # handshake с Cloudflare
watch -n1 -d awg show az             # трафик в реальном времени
ip rule                              # fwmark 0x13337 -> 13337, 0x13335 -> 13335
ip route show table 13337

# узел Cloudflare и геолокация выходного адреса
curl -s --interface warp-antizapret https://www.cloudflare.com/cdn-cgi/trace | grep -E 'colo|loc'

# сервисы и логи
systemctl status antizapret v2-warp-proxy kresd@1 kresd@2
journalctl -u antizapret -u v2-warp-proxy -f

# текущие сопоставления подменных и реальных адресов
iptables -t nat -S ANTIZAPRET-MAPPING | head
iptables -t nat -S V2-WARP-MAPPING | head
```

`colo` и `loc` в выводе `cdn-cgi/trace` — разное: `colo` это узел, который обработал запрос,
`loc` — геолокация выданного выходного адреса. `colo=AMS` при `loc=RU` — нормально, так и должно быть.

**Аплинк без handshake** — проверить, что профиль обфусцированный
(`grep -c '^Jc' /etc/amnezia/amneziawg/az.conf` должно дать 1) и что зарубежный сервер жив.

**WARP без handshake** — ветка чинит себя сама: `up.sh` зовёт `warp.sh auto` и подбирает другой узел,
это занимает полминуты. Логи: `journalctl -u antizapret | grep -i warp`.

**Домен идёт не тем путём** — `dig` покажет, каким. Домен есть в обоих списках → уходит за границу,
это задумано. Ничего не изменилось после правки списка → не применили: `parse.sh host`, а для
`uplink-ips.txt` ещё и `systemctl restart antizapret`.

***

## Протоколы и клиенты

**OpenVPN** (файлы `*.ovpn`) — UDP и TCP, порты 50080 и 50443, резервные 80, 443, 504, 508.
Один профиль можно использовать с нескольких устройств. Если провайдер режет OpenVPN — поставить
патч обхода блокировки (`patch-openvpn.sh`, работает только для UDP; ставится по умолчанию).
Если устройство не тянет AES-NI — заменить в профиле `AES-128-GCM` на `CHACHA20-POLY1305`.
Клиенты: [OpenVPN Connect](https://openvpn.net/client), [OpenVPN Community](https://openvpn.net/community).

**AmneziaWG 1.5** (файлы `*-am.conf`) — UDP, порты 52443 (AntiZapret) и 52080 (полный VPN),
[режим обфускации WireGuard](https://habr.com/ru/companies/amnezia/articles/807539). Профиль на каждое
устройство свой. Если провайдер или хостинг режет AmneziaWG — попробовать `Jc = 3..5`. Клиент не понимает
AmneziaWG 1.5 — удалить из профиля строку `I1 = <b...`. **Не использовать клиент AmneziaVPN** — он подменяет
DNS АнтиЗапрета своими, и всё ломается; нужен именно клиент AmneziaWG:
[Windows](https://github.com/amnezia-vpn/amneziawg-windows-client/releases),
[Android](https://play.google.com/store/apps/details?id=org.amnezia.awg),
[Apple](https://apps.apple.com/ru/app/amneziawg/id6478942365).

**WireGuard** (файлы `*-wg.conf`) — UDP, порты 51443 и 51080, резервные 540 и 580 (указывать вручную
в `Endpoint`). Профиль на каждое устройство свой. Рабочий вариант, но при активном DPI предпочтительнее
AmneziaWG или OpenVPN.

Если файл не импортируется — сократить имя до 32 символов (Windows) или 15 (Linux/Android/iOS)
и убрать скобки.

**Настройка на роутерах:** OpenVPN — [Keenetic](./Keenetic.md), [TP-Link](./TP-Link.md),
[MikroTik](https://github.com/Kirito0098/AntiZapret-OpenVPN-Mikrotik).
WireGuard/AmneziaWG — [Keenetic](https://4pda.to/forum/index.php?showtopic=1095869&view=findpost&p=133090948),
[MikroTik](https://github.com/Kirito0098/AntiZapret-WG-Mikrotik),
[OpenWrt](https://telegra.ph/AntiZapret-WireGuardAmneziaWG-on-OpenWrt-03-16).

### Что нужно сделать на клиенте

1. Отключить безопасный/частный DNS (DoH/DoT) в браузере и в системе — иначе DNS уйдёт мимо
   резолвера АнтиЗапрета и подмена адресов не сработает
2. Отключить IPv6 на устройстве, в роутере и в локальной сети — сервер отдаёт только A-записи
3. На мобильных отключить умное переключение Wi-Fi ↔ мобильная сеть (Wi-Fi+, Intelligent Wi-Fi, Помощь Wi-Fi)
4. В Chrome открыть `chrome://flags/#local-network-access-check` и выставить Disabled

***

## FAQ

### Как переустановить сервер, сохранив клиентов и настройки?

```bash
/root/antizapret/client.sh 8          # создаст /root/antizapret/backup*.tar.gz
```

Скачать `backup*.tar.gz`, переустановить сервер, залить файл обратно в `/root` и запустить установщик —
он подхватит бэкап сам. Если `client.sh 8` не отработал, скачать вручную папки `/root/antizapret/config`,
`/etc/openvpn/easyrsa3`, `/etc/wireguard`.

### Какие IP-адреса используются?

| что | адреса |
|---|---|
| клиенты полного VPN | `10.28.0.0/22`, `10.28.4.0/22`, `10.28.8.0/24` |
| клиенты AntiZapret | `10.29.0.0/22`, `10.29.4.0/22`, `10.29.8.0/24` |
| DNS АнтиЗапрета | `10.29.0.1`, `10.29.4.1`, `10.29.8.1` |
| подменные IP аплинка | `198.18.0.0/15` |
| подменные IP WARP | `10.30.0.0/15` |

Через запятую — OpenVPN UDP, OpenVPN TCP, WireGuard/AmneziaWG. При выборе альтернативных диапазонов
на установке `10.` меняется на `172.`, а подменные диапазоны меняются местами. Оба подменных диапазона
всегда противоположны друг другу и прописываются в клиентские маршруты — без этого WARP-ветка
до сервера не доедет.

### Как посмотреть активные соединения?

WireGuard/AmneziaWG — `awg show` (или `wg show`). OpenVPN — файлы `*-status.log` в
`/etc/openvpn/server/logs`, обновляются раз в 30 секунд. Есть и сторонний веб-интерфейс
[StatusOpenVPN](https://github.com/TheMurmabis/StatusOpenVPN).

### Как работает защита от сканирования и сетевых атак?

IP блокируется на 10 минут при: сканировании портов (больше 20 новых подключений с разных адресов
одной подсети /24) или DDoS (больше 100 000 новых подключений с одного адреса). Без попыток
подключения 10 минут лимиты сбрасываются, при новой попытке с заблокированного адреса блокировка
продлевается. Ответ на ping и RST/ICMP port-unreachable отключены.

```bash
ipset list antizapret-block | grep '\.' | sort -u    # заблокированные
ipset list antizapret-watch | grep '\.' | sort -u    # отслеживаемые за последние 10 минут
ipset list antizapret-allow | grep '\.' | sort -u    # исключения
```

Исключения добавляются в `config/allow-ips.txt` + `parse.sh ip`. Для IPv6 те же имена с суффиксом `6`.

### Как работает защита SSH?

Подключение блокируется на минуту с 6-й попытки с одного адреса или суммарно с подсети /24 (/64 для IPv6).
Минута без попыток — лимит сбрасывается, попытка с заблокированного адреса продлевает блокировку.

### Как запретить нескольким клиентам подключаться по одному профилю OpenVPN?

Убрать строку `duplicate-cn` во всех `.conf` в `/etc/openvpn/server` и перезагрузить сервер.

### Как пересоздать все файлы подключений?

```bash
/root/antizapret/client.sh 7
```

***

## Основано на

- [GubernievS/AntiZapret-VPN](https://github.com/GubernievS/AntiZapret-VPN) — оригинальный проект,
  откуда взят весь базовый код и откуда каждую ночь тянутся списки заблокированного.
  Поддержать автора: [cloudtips](https://pay.cloudtips.ru/p/b3f20611), [boosty](https://boosty.to/gubernievs)
- [antizapret-vpn-container](https://bitbucket.org/anticensority/antizapret-vpn-container/src/master)
  ValdikSS — исходная идея раздельного туннелирования
- [warpscout](https://github.com/vernette/warpscout) — подбор узла Cloudflare WARP

Обсуждение оригинального проекта: [4pda](https://4pda.to/forum/index.php?showtopic=1095869),
[ntc.party](https://ntc.party/t/9270).

Сторонние панели и боты (StatusOpenVPN, AdminPanelAZ, vpn-control-panel) написаны под оригинал —
в V2 могут работать не полностью. [AZ-WARP](https://github.com/Liafanx/AZ-WARP) ставить нельзя:
он делает свою маршрутизацию через WARP и конфликтует с WARP-веткой V2.

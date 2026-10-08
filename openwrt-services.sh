#!/bin/sh
# OpenWrt Services Menu 1.4 - BusyBox ash, apk/opkg, native Docker images.
umask 077
CFG=owrt_services
OWNER=owrt-services-v1
say() { printf '%s\n' "$*"; }
ask() { printf '%s' "$1"; IFS= read -r ANSWER; }
get() { uci -q get "$CFG.$1"; }
put() { uci set "$CFG.$1=$2" && uci commit "$CFG"; }
exists() { docker inspect "$1" >/dev/null 2>&1; }
owned() { [ "$(docker inspect -f '{{index .Config.Labels "owrt.services"}}' "$1" 2>/dev/null)" = "$OWNER" ]; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
ready() { docker info >/dev/null 2>&1 || { say 'Сначала установите/запустите Docker (пункт 1).'; return 1; }; }
root_dir() { ROOT=$(get main.root); [ -n "$ROOT" ] && [ -f "$ROOT/.owrt-services" ] || { say 'Не найден диск с данными. Подключите его или выберите хранилище.'; return 1; }; }
choose_storage() (
    [ -z "$(get main.root)" ] || { say "Хранилище уже выбрано: $(get main.root). Перенос существующих данных вручную."; exit 0; }
    df -h
    say 'Выберите постоянный каталог на ext4/btrfs. Рекомендуется диск от 8 ГБ.'
    ask 'Каталог [/root/owrt-services]: '; d=${ANSWER:-/root/owrt-services}
    case "$d" in /*) ;; *) say 'Нужен абсолютный путь.'; exit 1;; esac
    case "$d" in /|/tmp|/tmp/*|/var|/var/*|/dev/*|/proc/*|/sys/*|*[!A-Za-z0-9_./-]*|*/../*|*/..) say 'Недопустимый или временный путь.'; exit 1;; esac
    mkdir -p "$d" || exit 1
    d=$(cd "$d" && pwd -P) || exit 1
    fs=$(df -T "$d" | awk 'END {print $2}')
    case "$fs" in tmpfs|ramfs|vfat|exfat|ntfs|fuseblk) say "Файловая система $fs не подходит для Docker."; exit 1;; esac
    kb=$(df -Pk "$d" | awk 'END {print $4}')
    [ "$kb" -ge 2097152 ] || { say 'Нужно минимум 2 ГБ свободного места; для всех серверов лучше 8 ГБ и больше.'; exit 1; }
    mkdir -p "$d/data" "$d/config" "$d/backups" || exit 1
    : > "$d/.owrt-services"
    put main.root "$d"
)
install_docker() (
    choose_storage && root_dir || exit 1
    if ! command -v dockerd >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then apk update && apk add dockerd docker ca-bundle || exit 1
        elif command -v opkg >/dev/null 2>&1; then opkg update && opkg install dockerd docker ca-bundle || exit 1
        else say 'Не найден apk/opkg.'; exit 1; fi
    fi
    # Keep an existing daemon and its image store untouched.
    if ! docker info >/dev/null 2>&1; then
        existing=$(uci -q get dockerd.globals.data_root)
        if [ -n "$existing" ] && [ -d "$existing" ] && [ -n "$(ls -A "$existing" 2>/dev/null)" ]; then
            say "Сохраняю существующее Docker-хранилище: $existing"
        else
            mkdir -p "$ROOT/docker" || exit 1
            uci set dockerd.globals=globals && uci set "dockerd.globals.data_root=$ROOT/docker" && uci commit dockerd || exit 1
        fi
        /etc/init.d/dockerd enable && /etc/init.d/dockerd start || exit 1
    else /etc/init.d/dockerd enable || exit 1; fi
    n=0
    until docker info >/dev/null 2>&1; do
        n=$((n+1)); [ "$n" -lt 20 ] || { say 'Docker не запустился: logread -e dockerd'; exit 1; }; sleep 1
    done
    say 'Docker готов. Каталог образов:'
    docker info --format '{{.DockerRootDir}}'
    say 'Если данные на внешнем диске, настройте его автоматическое монтирование до запуска Docker.'
)
select_service() {
    say '1 TorrServer  2 TeamSpeak  3 Mumble  4 RustDesk'
    ask 'Сервер: '
    case "$ANSWER" in 1) S=torrserver;; 2) S=teamspeak;; 3) S=mumble;; 4) S=rustdesk;; *) return 1;; esac
}
names() {
    case "$S" in rustdesk) if [ "$(get rustdesk.mode)" = full ]; then say 'ows-hbbr ows-hbbs'; else say 'ows-hbbr'; fi;; *) say "ows-$S";; esac
}
default_image() {
    case "$S" in torrserver) say ghcr.io/yourok/torrserver:latest;; teamspeak) if [ "$(get teamspeak.version)" = 3 ]; then say teamspeak:latest; else say teamspeaksystems/teamspeak6-server:latest; fi;; mumble) say mumblevoip/mumble-server:latest;; rustdesk) say rustdesk/rustdesk-server:latest;; esac
}
prepare_config() (
    root_dir || exit 1
    mkdir -p "$ROOT/data/$S" || exit 1
    [ -n "$(get "$S.image")" ] && exit 0
    put "$S" service || exit 1
    if [ "$S" = teamspeak ]; then
        ask 'Версия: 1 TeamSpeak 3; 2 TeamSpeak 6 Beta [1]: '
        case "${ANSWER:-1}" in 1) put teamspeak.version 3;; 2) put teamspeak.version 6;; *) exit 1;; esac
        if [ "$(get teamspeak.version)" = 3 ] && [ "$(uname -m)" != x86_64 ]; then
            say 'Официальный образ TeamSpeak 3 поддерживает только amd64. Выберите другое устройство или TeamSpeak 6, если для него есть подходящий образ.'; exit 1
        fi
    fi
    image=$(default_image)
    ask "Образ [$image] (можно указать конкретный тег): "; image=${ANSWER:-$image}
    case "$image" in ''|*[!A-Za-z0-9_./:@-]*|-*) say 'Некорректное имя образа.'; exit 1;; esac
    case "$S" in
        teamspeak)
            say 'Лицензия TeamSpeak: https://www.teamspeak.com/en/features/licensing/'
            ask 'Принимаете лицензию TeamSpeak? Напишите accept: '
            [ "$ANSWER" = accept ] || exit 1
            if [ "$(get teamspeak.version)" = 3 ]; then printf 'TS3SERVER_LICENSE=accept\n' > "$ROOT/config/teamspeak.env"
            else printf 'TSSERVER_LICENSE_ACCEPTED=accept\n' > "$ROOT/config/teamspeak.env"; fi;;
        mumble)
            ask 'Пароль SuperUser (ввод виден в терминале): '; [ -n "$ANSWER" ] || { say 'Пароль не должен быть пустым.'; exit 1; }
            printf 'MUMBLE_SUPERUSER_PASSWORD=%s\n' "$ANSWER" > "$ROOT/config/mumble.env"
            ask 'Пароль входа на сервер (Enter = без пароля): '
            printf 'MUMBLE_CONFIG_SERVER_PASSWORD=%s\nMUMBLE_CONFIG_PORT=64738\n' "$ANSWER" >> "$ROOT/config/mumble.env";;
        rustdesk)
            say '1 Только relay hbbr; требуется отдельный ID-сервер hbbs.  2 Полный сервер hbbs + hbbr.'
            ask 'Режим [2]: '; mode=${ANSWER:-2}
            case "$mode" in 1) put rustdesk.mode relay;; 2)
                ask 'Публичный IP или домен этого сервера (без схемы и порта): '
                case "$ANSWER" in ''|*[!A-Za-z0-9.-]*|-*) say 'Некорректный адрес.'; exit 1;; esac
                put rustdesk.address "$ANSWER" && put rustdesk.mode full || exit 1;; *) exit 1;; esac;;
    esac
    put "$S.image" "$image"
)
prepare_teamspeak_permissions() (
    data="$ROOT/data/teamspeak"
    [ -d "$data" ] && [ ! -L "$data" ] || { say 'Каталог данных TeamSpeak отсутствует или является символической ссылкой.'; exit 1; }
    ids=$(docker run --rm --network none --entrypoint /bin/sh "$IMAGE" -c 'id -u; id -g') || { say 'Не удалось определить UID/GID пользователя образа TeamSpeak.'; exit 1; }
    uid=$(printf '%s\n' "$ids" | sed -n '1p'); gid=$(printf '%s\n' "$ids" | sed -n '2p')
    case "$uid" in ''|*[!0-9]*) say 'Некорректный UID образа.'; exit 1;; esac
    case "$gid" in ''|*[!0-9]*) say 'Некорректный GID образа.'; exit 1;; esac
    say "Настройка владельца только каталога TeamSpeak: $uid:$gid"
    chown -hR "$uid:$gid" "$data" && chmod -R u+rwX "$data" && chmod 700 "$data" || exit 1
)

create_container() (
    name=$1
    set -- docker run -d --name "$name" --label "owrt.services=$OWNER" --network host --restart unless-stopped --log-driver json-file --log-opt max-size=5m --log-opt max-file=2
    case "$name" in
        ows-torrserver) set -- "$@" -v "$ROOT/data/torrserver:/opt/ts" "$IMAGE";;
        ows-teamspeak)
            prepare_teamspeak_permissions || exit 1
            if [ "$(get teamspeak.version)" = 3 ]; then target=/var/ts3server; else target=/var/tsserver; fi
            set -- "$@" --env-file "$ROOT/config/teamspeak.env" -v "$ROOT/data/teamspeak:$target" "$IMAGE";;
        ows-mumble) set -- "$@" --env-file "$ROOT/config/mumble.env" -v "$ROOT/data/mumble:/data" "$IMAGE";;
        ows-hbbr) set -- "$@" -v "$ROOT/data/rustdesk:/root" "$IMAGE" hbbr;;
        ows-hbbs) set -- "$@" -v "$ROOT/data/rustdesk:/root" "$IMAGE" hbbs -r "$(get rustdesk.address):21117";;
        *) exit 1;;
    esac
    "$@"
)
check_names() {
    for c in $(names); do
        if exists "$c" && ! owned "$c"; then say "Чужой контейнер $c: не изменяю."; return 1; fi
        if exists "$c-previous"; then say "Есть $c-previous от незавершённого обновления. Проверьте контейнеры вручную."; return 1; fi
    done
}
backup_data() (
    ready && root_dir && check_names || exit 1
    restart=''; rc=0
    trap 'rc=$?; for c in $restart; do docker start "$c" >/dev/null || rc=1; done; exit $rc' EXIT
    for c in $(names); do
        if running "$c"; then restart="$restart $c"; docker stop "$c" >/dev/null || exit 1; fi
    done
    mkdir -p "$ROOT/backups" || exit 1
    uci export "$CFG" > "$ROOT/config/menu.uci" || exit 1
    file="$ROOT/backups/$S-$(date +%Y%m%d-%H%M%S)-$$.tar.gz"
    tar -czf "$file" -C "$ROOT" "data/$S" config || { rm -f "$file"; exit 1; }
    say "Резервная копия: $file (содержит пароли и ключи)."
)
# Early launch rollback restores containers, not database migrations. The data backup stays available.
deploy() (
    ready && root_dir && prepare_config && check_names || exit 1
    IMAGE=$(get "$S.image")
    say "Загрузка $IMAGE для $(uname -m)…"
    docker pull "$IMAGE" || { say 'Образ недоступен для вашей архитектуры либо есть ошибка сети/места. Старые контейнеры сохранены.'; exit 1; }
    have_old=0
    case "$S" in torrserver) check_ports='8090';; teamspeak) check_ports='9987 30033';; mumble) check_ports='64738';; rustdesk) check_ports='21117'; [ "$(get rustdesk.mode)" != full ] || check_ports='21115 21116 21117';; esac
    for c in $(names); do exists "$c" && have_old=1; done
    if [ "$have_old" = 0 ]; then
        if command -v netstat >/dev/null 2>&1; then
            for p in $check_ports; do
                if netstat -lntu 2>/dev/null | awk -v p="$p" '$4 ~ (":" p "$") {found=1} END {exit !found}'; then
                    say "Порт $p уже занят. Освободите его перед установкой."; exit 1
                fi
            done
        else say 'netstat отсутствует: занятость портов проверяется при запуске контейнера.'; fi
    else backup_data || exit 1; fi
    old=''; new=''; was_running=''
    rollback() {
        for c in $new; do docker rm -f "$c" >/dev/null 2>&1; done
        for c in $old; do docker rename "$c-previous" "$c"; done
        for c in $was_running; do docker start "$c" >/dev/null; done
        say 'Возвращены прежние контейнеры. Если новая версия изменила БД, восстановите данные из резервной копии.'
    }
    trap 'rollback; exit 130' HUP INT TERM
    for c in $(names); do
        if exists "$c"; then
            running "$c" && was_running="$was_running $c"
            if ! docker stop "$c" >/dev/null || ! docker rename "$c" "$c-previous"; then rollback; exit 1; fi
            old="$old $c"
        fi
    done
    for c in $(names); do
        new="$new $c"
        create_container "$c" || { rollback; exit 1; }
    done
    n=0
    while [ "$n" -lt 3 ]; do
        sleep 5
        for c in $new; do
            if ! running "$c" || [ "$(docker inspect -f '{{.RestartCount}}' "$c")" != 0 ]; then
                docker logs --tail 30 "$c"; rollback; exit 1
            fi
        done
        n=$((n+1))
    done
    for c in $old; do docker rm "$c-previous" >/dev/null || exit 1; done
    trap - HUP INT TERM
    say 'Контейнеры запущены. Проверка работоспособности приложения — через клиент; логи доступны в меню.'
    [ "$S" != torrserver ] || say 'TorrServer: http://IP-роутера:8090 . WAN-правила для него скрипт не создаёт.'
    [ "$S" != teamspeak ] || say 'Ключ администратора: пункт «Логи», контейнер ows-teamspeak.'
    [ "$S" != rustdesk ] || { say 'Публичный ключ (для клиента):'; cat "$ROOT/data/rustdesk/id_ed25519.pub" 2>/dev/null || say 'Ключ ещё не создан; проверьте позже.'; }
)
manage() (
    ready && check_names || exit 1
    say '1 Запуск  2 Остановка  3 Перезапуск  4 Логи  5 Удалить контейнеры, сохранить данные'
    ask 'Действие: '; action=$ANSWER
    case "$action" in 1) verb=start;; 2) verb=stop;; 3) verb=restart;; 4) verb=logs;; 5) verb="rm";; *) exit 1;; esac
    for c in $(names); do
        exists "$c" || continue
        case "$verb" in logs) say "=== $c ==="; docker logs --tail 80 "$c";; rm) docker stop "$c" >/dev/null && docker rm "$c";; *) docker "$verb" "$c";; esac
    done
    [ "$verb" != rm ] || say 'Данные и настройки сохранены. WAN-правила отключаются отдельно пунктом 8.'
)
firewall_menu() (
    [ "$S" != torrserver ] || { say 'TorrServer оставлен для локальной сети. Для внешнего доступа используйте VPN.'; exit 0; }
    say 'Зоны OpenWrt:'
    i=0; while z=$(uci -q get "firewall.@zone[$i].name"); do say "$z"; i=$((i+1)); done
    ask 'Зона входящего доступа [wan]: '; zone=${ANSWER:-wan}
    case "$zone" in ''|*[!A-Za-z0-9_-]*) exit 1;; esac
    found=0; i=0
    while z=$(uci -q get "firewall.@zone[$i].name"); do [ "$z" != "$zone" ] || found=1; i=$((i+1)); done
    [ "$found" = 1 ] || { say 'Такая зона не найдена.'; exit 1; }
    ask '1 Открыть порты  2 Закрыть созданные скриптом правила: '; action=$ANSWER
    case "$S" in teamspeak) tcp=30033; udp=9987;; mumble) tcp=64738; udp=64738;; rustdesk) tcp=21117; udp=''; [ "$(get rustdesk.mode)" != full ] || { tcp='21115 21116 21117'; udp=21116; };; esac
    [ -z "$(uci changes firewall)" ] || { say 'Есть несохранённые изменения firewall. Сохраните или отмените их в LuCI.'; exit 1; }
    cp /etc/config/firewall "/tmp/ows-firewall-$$" || exit 1
    fw_done=0
    trap 'if [ "$fw_done" = 0 ]; then uci -q revert firewall; cp "/tmp/ows-firewall-$$" /etc/config/firewall; /etc/init.d/firewall reload; fi; rm -f "/tmp/ows-firewall-$$"' EXIT
    for proto in tcp udp; do
        id="ows_${S}_${zone}_${proto}"
        if uci -q get "firewall.$id" >/dev/null && [ "$(uci -q get "firewall.$id.name")" != "OWS $S $zone $proto" ]; then
            say 'Совпадение имени с чужим правилом.'; exit 1
        fi
        case "$proto" in tcp) ports=$tcp;; udp) ports=$udp;; esac
        case "$action" in
            1) [ -n "$ports" ] || continue
                uci set "firewall.$id=rule" && uci set "firewall.$id.name=OWS $S $zone $proto" && uci set "firewall.$id.src=$zone" && uci set "firewall.$id.proto=$proto" && uci set "firewall.$id.dest_port=$ports" && uci set "firewall.$id.target=ACCEPT" && uci set "firewall.$id.enabled=1" || exit 1;;
            2) uci -q delete "firewall.$id";; *) exit 1;;
        esac
    done
    uci commit firewall
    if { ! command -v fw4 >/dev/null 2>&1 || fw4 check; } && /etc/init.d/firewall reload; then
        fw_done=1; say 'Правила применены. Это вход на сам роутер, не DNAT. Проверяйте с внешней сети.'
    else exit 1; fi
)
install_snat_hooks() (
    for path in /usr/libexec/ows-ts6-snat /etc/init.d/ows-ts6-snat /etc/hotplug.d/iface/95-ows-ts6-snat; do
        if [ -e "$path" ] && ! grep -q 'Managed by OpenWrt Services: TS6 local SNAT' "$path"; then
            say "Файл $path уже существует и не принадлежит меню."; exit 1
        fi
    done
    mkdir -p /usr/libexec /etc/hotplug.d/iface || exit 1
    tmp=$(mktemp -d /tmp/ows-snat-install.XXXXXX) || exit 1
    trap 'rm -rf "$tmp"' EXIT
    cat > "$tmp/helper" <<'OWS_SNAT_HELPER'
#!/bin/sh
# Managed by OpenWrt Services: TS6 local SNAT
umask 077
TABLE=ts6_local_snat
fail() { logger -t ows-ts6-snat "$*"; printf '%s\n' "$*" >&2; exit 1; }
ipv4() { printf '%s\n' "$1" | awk -F. 'NF != 4 {exit 1} {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i>255 || length($i)>3) exit 1}'; }
command -v nft >/dev/null 2>&1 || exit 1
mkdir -p /var/lock
mkdir /var/lock/ows-ts6-snat.lock 2>/dev/null || exit 0
batch=''
trap 'rm -f "$batch"; rmdir /var/lock/ows-ts6-snat.lock 2>/dev/null' EXIT
trap 'exit 130' HUP INT TERM
present=0; nft list table ip "$TABLE" >/dev/null 2>&1 && present=1
if [ "${1:-apply}" = clear ] || [ "$(uci -q get owrt_services.teamspeak.snat_enabled)" != 1 ]; then
    [ "$present" = 0 ] || nft delete table ip "$TABLE"
    exit $?
fi
client=$(uci -q get owrt_services.teamspeak.snat_client)
iface=$(uci -q get owrt_services.teamspeak.snat_wan)
ipv4 "$client" || fail 'Неверный IPv4 клиента для TS6 SNAT.'
case "$iface" in ''|*[!A-Za-z0-9_-]*) fail 'Неверное имя интерфейса WAN.';; esac
status=$(ubus call "network.interface.$iface" status 2>/dev/null) || status=''
wan=$(printf '%s\n' "$status" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
up=$(printf '%s\n' "$status" | jsonfilter -e '@.up' 2>/dev/null)
if [ "$up" != true ] || [ -z "$wan" ]; then
    [ "$present" = 0 ] || nft delete table ip "$TABLE" || exit 1
    logger -t ows-ts6-snat "Нет IPv4 у $iface; правило будет установлено при поднятии интерфейса."
    exit 0
fi
ipv4 "$wan" || fail 'Неверный IPv4 интерфейса WAN.'
batch=$(mktemp /tmp/ows-ts6-snat.XXXXXX) || exit 1
{
    [ "$present" = 0 ] || printf 'delete table ip %s\n' "$TABLE"
    cat <<EOF
table ip $TABLE {
    chain input {
        type nat hook input priority srcnat; policy accept;
        ip saddr $client ip daddr $wan udp dport 9987 counter snat to $wan
    }
}
EOF
} > "$batch"
# One atomic transaction; invalid rules do not remove the working table.
if ! nft -c -f "$batch" || ! nft -f "$batch"; then fail 'Не удалось применить TS6 SNAT; прежние правила не удалены.'; fi
logger -t ows-ts6-snat "TS6 SNAT: $client -> $wan, UDP 9987."
OWS_SNAT_HELPER
    cat > "$tmp/init" <<'OWS_SNAT_INIT'
#!/bin/sh /etc/rc.common
# Managed by OpenWrt Services: TS6 local SNAT
START=99
STOP=10
start() { /usr/libexec/ows-ts6-snat; }
reload() { /usr/libexec/ows-ts6-snat; }
stop() { /usr/libexec/ows-ts6-snat clear; }
OWS_SNAT_INIT
    cat > "$tmp/hotplug" <<'OWS_SNAT_HOTPLUG'
#!/bin/sh
# Managed by OpenWrt Services: TS6 local SNAT
case "$ACTION" in ifup|ifupdate|ifdown)
    if [ "$INTERFACE" = "$(uci -q get owrt_services.teamspeak.snat_wan)" ]; then
        /usr/libexec/ows-ts6-snat
    fi;;
esac
OWS_SNAT_HOTPLUG
    chmod 700 "$tmp/helper" "$tmp/init" "$tmp/hotplug" || exit 1
    mv "$tmp/helper" /usr/libexec/ows-ts6-snat && mv "$tmp/init" /etc/init.d/ows-ts6-snat && mv "$tmp/hotplug" /etc/hotplug.d/iface/95-ows-ts6-snat
)
snat_menu() (
    if ! command -v nft >/dev/null 2>&1 || ! command -v fw4 >/dev/null 2>&1; then say 'Этот пункт требует OpenWrt с firewall4/nftables.'; exit 1; fi
    say "TS6 SNAT: enabled=$(get teamspeak.snat_enabled); клиент=$(get teamspeak.snat_client); WAN=$(get teamspeak.snat_wan)"
    say '1 Включить / изменить  2 Отключить  3 Статус / счётчики'
    ask 'Действие: '; action=$ANSWER
    case "$action" in
        3) nft list table ip ts6_local_snat; exit $?;;
        2) put teamspeak.snat_enabled 0 || exit 1
            if [ -x /usr/libexec/ows-ts6-snat ]; then /usr/libexec/ows-ts6-snat clear || exit 1
            elif nft list table ip ts6_local_snat >/dev/null 2>&1; then nft delete table ip ts6_local_snat || exit 1; fi
            [ ! -x /etc/init.d/ows-ts6-snat ] || /etc/init.d/ows-ts6-snat disable
            say 'SNAT отключён. Переподключите клиент TeamSpeak.'; exit 0;;
        1) ;; *) exit 1;;
    esac
    [ -z "$(uci changes firewall)" ] || { say 'Сначала сохраните или отмените изменения firewall в LuCI.'; exit 1; }
    if uci -q get firewall.ows_ts6_snat >/dev/null && [ "$(uci -q get firewall.ows_ts6_snat.path)" != /usr/libexec/ows-ts6-snat ]; then
        say 'Имя firewall.ows_ts6_snat занято другим include.'; exit 1
    fi
    client=$(get teamspeak.snat_client); client=${client:-192.168.77.2}
    ask "Локальный IPv4 Windows-клиента [$client]: "; client=${ANSWER:-$client}
    printf '%s\n' "$client" | awk -F. 'NF != 4 {exit 1} {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i>255 || length($i)>3) exit 1}' || { say 'Неверный IPv4.'; exit 1; }
    iface=$(get teamspeak.snat_wan); iface=${iface:-wan}
    ask "Логический интерфейс WAN [$iface]: "; iface=${ANSWER:-$iface}
    case "$iface" in ''|*[!A-Za-z0-9_-]*) exit 1;; esac
    uci -q get "network.$iface" >/dev/null || { say 'Такой интерфейс отсутствует в конфигурации network.'; exit 1; }
    install_snat_hooks || exit 1
    [ "$(get teamspeak)" = service ] || put teamspeak service || exit 1
    put teamspeak.snat_client "$client" && put teamspeak.snat_wan "$iface" && put teamspeak.snat_enabled 1 || exit 1
    uci set firewall.ows_ts6_snat=include && uci set firewall.ows_ts6_snat.type=script && uci set firewall.ows_ts6_snat.path=/usr/libexec/ows-ts6-snat && uci set firewall.ows_ts6_snat.fw4_compatible=1 && uci set firewall.ows_ts6_snat.enabled=1 && uci commit firewall || exit 1
    /usr/libexec/ows-ts6-snat && /etc/init.d/ows-ts6-snat enable || exit 1
    say 'SNAT включён с автозапуском, обновлением при изменениях WAN и после перезагрузки firewall.'
    say 'Полностью закройте и заново запустите TeamSpeak; подключайтесь к актуальному внешнему IPv4.'
    nft list table ip ts6_local_snat 2>/dev/null || say 'WAN пока без IPv4: правило появится после подключения.'
)

main() {
    [ "$(id -u)" = 0 ] && [ -f /etc/openwrt_release ] || { say 'Запускайте от root на OpenWrt.'; return 1; }
    command -v uci >/dev/null 2>&1 || return 1
    mkdir -p /var/lock
    mkdir /var/lock/owrt-services.lock 2>/dev/null || { say 'Меню уже запущено. После аварии удалите /var/lock/owrt-services.lock.'; return 1; }
    trap 'rmdir /var/lock/owrt-services.lock 2>/dev/null' EXIT
    trap 'exit 130' INT TERM HUP
    touch /etc/config/owrt_services
    [ "$(get main)" = settings ] || put main settings
    while :; do
        say ''; say "OpenWrt Services 1.4 | $(uname -m) | $(get main.root)"
        say '1 Установить/запустить Docker'
        say '2 Установить или обновить TorrServer'
        say '3 Установить или обновить TeamSpeak'
        say '4 Установить или обновить Mumble'
        say '5 Установить или обновить RustDesk'
        say '6 Статус и использование диска'
        say '7 Управление сервером / логи / удаление'
        say '8 Открыть или закрыть порты сервера'
        say '9 Резервная копия данных сервера'
        say '10 Расширение диска отключено'
        say '11 TS6: внешний IP локального клиента (SNAT)'
        say '0 Выход'
        ask 'Выбор: ' || break
        case "$ANSWER" in
            1) install_docker;;
            2) S=torrserver; deploy;; 3) S=teamspeak; deploy;; 4) S=mumble; deploy;; 5) S=rustdesk; deploy;;
            6) if ready; then docker ps -a --filter "label=owrt.services=$OWNER" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'; docker system df; fi; df -h;;
            7) select_service && manage;; 8) select_service && firewall_menu;; 9) select_service && backup_data;; 10) say 'Расширение диска удалено из версии 1.2. Автоматические изменения разделов и файловой системы не выполняются.';; 11) snat_menu;; 0) break;; *) say 'Неизвестный пункт.';;
        esac
    done
}
# Source-only mode for shell test harness; normal use: sh openwrt-services.sh
[ "${OWS_SOURCE_ONLY:-0}" = 1 ] || main "$@"

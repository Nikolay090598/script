#!/bin/sh
# OpenWrt (firewall4) + Docker: TeamSpeak 6 with a fixed container address.
# Run as root on the router. Review DATA_DIR and SUBNET before running.
set -eu

DATA_DIR='/overlay/teamspeak6-data'
IMAGE='teamspeaksystems/teamspeak6-server:latest'
NAME='ts6-server'
NETWORK='ts6-net'
BRIDGE='br-ts6'
SUBNET='172.30.66.0/24'  # Must not overlap LAN, VPN or other Docker networks.
GATEWAY='172.30.66.1'
TS_IP='172.30.66.2'

die() { echo "Ошибка: $*" >&2; exit 1; }
for cmd in uci docker grep sed cp mktemp mkdir; do
    command -v "$cmd" >/dev/null 2>&1 || die "Нет команды $cmd"
done
[ -f /etc/config/firewall ] || die 'Нет /etc/config/firewall'
[ -x /etc/init.d/firewall ] || die 'Нет службы firewall'

# Find the LAN zone without assuming its UCI index or section identifier.
LAN_ZONE=''
for zone in $(uci show firewall | sed -n 's/^\(firewall\.[^.=]*\)=zone$/\1/p'); do
    if [ "$(uci -q get "$zone.name" || :)" = 'lan' ]; then
        LAN_ZONE="$zone"
        break
    fi
done
[ -n "$LAN_ZONE" ] || die 'Не найдена зона lan'

if docker network inspect "$NETWORK" >/dev/null 2>&1; then
    actual_bridge=$(docker network inspect -f '{{index .Options "com.docker.network.bridge.name"}}' "$NETWORK")
    actual_subnet=$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$NETWORK")
    actual_gateway=$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$NETWORK")
    [ "$actual_bridge" = "$BRIDGE" ] && [ "$actual_subnet" = "$SUBNET" ] &&
        [ "$actual_gateway" = "$GATEWAY" ] ||
        die "Сеть $NETWORK существует с другими параметрами"
else
    docker network create --driver bridge --subnet "$SUBNET" --gateway "$GATEWAY" \
        --opt "com.docker.network.bridge.name=$BRIDGE" "$NETWORK" >/dev/null
fi

OLD_BACKUP="${NAME}-before-update"
old_present=0
old_running=0
old_ips=''
if docker container inspect "$NAME" >/dev/null 2>&1; then
    docker container inspect "$OLD_BACKUP" >/dev/null 2>&1 && die "Контейнер $OLD_BACKUP уже существует"
    old_present=1
    current_mount=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/tsserver"}}{{.Source}}{{end}}{{end}}' "$NAME")
    [ "$current_mount" = "$DATA_DIR" ] || die "У текущего контейнера другое хранилище: $current_mount"
    old_ips=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' "$NAME")
    [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = true ] && old_running=1
    [ -d "$DATA_DIR" ] || die "Каталог данных $DATA_DIR не существует"
else
    mkdir -p "$DATA_DIR"
fi

# Adopt an existing redirect when it targets this container or has a TS6 name.
# Anonymous UCI sections stay anonymous; on later runs they are found again.
choose_redirect() {
    selected="firewall.$1"
    port="$2"
    protocol="$3"
    expected_name="$4"
    if uci -q get "$selected" >/dev/null 2>&1; then
        [ "$(uci -q get "$selected")" = redirect ] || die "$selected уже занят другим типом секции"
        [ "$(uci -q get "$selected.src_dport" || :)" = "$port" ] || die "У $selected другой порт"
    fi
    for entry in $(uci show firewall | sed -n "s/^\(firewall\.[^.=]*\)\.src_dport='$port'$/\1/p"); do
        [ "$(uci -q get "$entry")" = redirect ] || continue
        rule_proto=$(uci -q get "$entry.proto" || :)
        [ -n "$rule_proto" ] || rule_proto='tcp udp'
        case " $rule_proto " in *" $protocol "*) ;; *) continue ;; esac
        [ "$entry" = "$selected" ] && continue
        if [ "$selected" != "firewall.$1" ] ||
            uci -q get "$selected" >/dev/null 2>&1; then
            die "Несколько правил на $protocol/$port"
        fi
        rule_name=$(uci -q get "$entry.name" || :)
        [ "$(uci -q get "$entry.src" || :)" = wan ] || die "У $entry другой источник"
        [ "$(uci -q get "$entry.dest" || :)" = lan ] || die "У $entry другая зона назначения"
        [ "$(uci -q get "$entry.target" || :)" = DNAT ] || die "У $entry другая цель"
        [ "$(uci -q get "$entry.dest_port" || :)" = "$port" ] || die "У $entry другой порт назначения"
        target_ip=$(uci -q get "$entry.dest_ip" || :)
        [ -n "$target_ip" ] || die "У $entry нет адреса назначения"
        if ! printf '%s\n' "$old_ips" | grep -Fxq "$target_ip"; then
            case "$rule_name" in
                "$expected_name"|"$expected_name-Forward") ;;
                *) die "Порт $protocol/$port занят правилом $entry ($rule_name), не связанным с $NAME" ;;
            esac
        fi
        selected="$entry"
    done
    printf '%s\n' "$selected"
}
VOICE_SECTION=$(choose_redirect ts6_voice 9987 udp TS6-Voice)
FILES_SECTION=$(choose_redirect ts6_files 30033 tcp TS6-Files)

# Download and validate the image before stopping the current server.
docker pull "$IMAGE" || die "Не удалось загрузить $IMAGE"

FIREWALL_BACKUP=$(mktemp /tmp/ts6-firewall.XXXXXX)
cp /etc/config/firewall "$FIREWALL_BACKUP"
completed=0
rollback() {
    result=$?
    trap - EXIT
    if [ "$completed" -ne 1 ]; then
        echo 'Ошибка настройки: восстанавливаю firewall и старый контейнер' >&2
        cp "$FIREWALL_BACKUP" /etc/config/firewall
        uci revert firewall 2>/dev/null || :
        /etc/init.d/firewall reload || :
        if docker container inspect "$NAME" >/dev/null 2>&1; then
            docker rm -f "$NAME" >/dev/null || :
        fi
        if [ "$old_present" -eq 1 ] && docker container inspect "$OLD_BACKUP" >/dev/null 2>&1; then
            docker rename "$OLD_BACKUP" "$NAME" || :
            [ "$old_running" -eq 0 ] || docker start "$NAME" >/dev/null || :
        fi
    fi
    rm -f "$FIREWALL_BACKUP"
    exit "$result"
}
trap rollback EXIT

if [ "$old_present" -eq 1 ]; then
    docker stop "$NAME" >/dev/null || :
    docker rename "$NAME" "$OLD_BACKUP"
fi

# Publish the ports as well: Docker's bridge filtering only permits published ports.
docker run -d --name "$NAME" --restart unless-stopped \
    --network "$NETWORK" --ip "$TS_IP" \
    -p 9987:9987/udp -p 30033:30033/tcp \
    -e TSSERVER_LICENSE_ACCEPTED=accept \
    -v "$DATA_DIR:/var/tsserver" "$IMAGE" >/dev/null
[ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = true ] || die 'Новый контейнер не запустился'
CONTAINER_IP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NETWORK\").IPAddress}}" "$NAME")
[ -n "$CONTAINER_IP" ] || die 'Не удалось узнать IP нового контейнера'

# The dedicated bridge belongs to the LAN zone; no other Docker bridge is changed.
if ! uci -q get "$LAN_ZONE.device" | grep -Fxq "$BRIDGE"; then
    uci add_list "$LAN_ZONE.device=$BRIDGE"
fi

add_redirect() {
    section="$1"
    label="$2"
    protocol="$3"
    port="$4"
    uci -q get "$section" >/dev/null 2>&1 || uci set "$section=redirect"
    uci set "$section.name=$label"
    uci set "$section.src=wan"
    uci set "$section.src_dport=$port"
    uci set "$section.dest=lan"
    uci set "$section.dest_ip=$CONTAINER_IP"
    uci set "$section.dest_port=$port"
    uci set "$section.proto=$protocol"
    uci set "$section.target=DNAT"
    uci set "$section.reflection=1"
    uci set "$section.reflection_zone=lan"
    uci set "$section.reflection_src=external"
    uci set "$section.enabled=1"
}
add_redirect "$VOICE_SECTION" 'TS6-Voice' udp 9987
add_redirect "$FILES_SECTION" 'TS6-Files' tcp 30033

uci commit firewall
/etc/init.d/firewall reload
completed=1
trap - EXIT
rm -f "$FIREWALL_BACKUP"
if [ "$old_present" -eq 1 ]; then
    docker rm "$OLD_BACKUP" >/dev/null
fi
echo 'TeamSpeak 6 запущен. Проверьте подключение извне и из LAN по внешнему адресу.'

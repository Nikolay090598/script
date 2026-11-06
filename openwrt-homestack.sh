#!/bin/bash
# OpenWrt HomeStack 1.0-rc1. Interactive, fresh installs or explicit maintenance.
# No package removal, no full IPv6 disable, no automatic container replacement.
set -Eeuo pipefail
umask 077
SELF=$(readlink -f "$0")
STATE=/etc/homestack.conf
BASE=/mnt/sda1/homestack
LAN=192.168.2.1
WAN=wan
ENDPOINT=''
EMAIL=''
OWNER='rPNJ9DV55exiMFhBXQXQP+l9DqJQL4KJn2wj44XU9wo='
SERVER=192.168.2.1:9987
BOT_IMAGE=ghcr.io/cookiecr2nk/ts3audiobot-docker:main
TS_IMAGE=teamspeaksystems/teamspeak6-server:latest
MM_IMAGE=mumblevoip/mumble-server:latest
RD_IMAGE=rustdesk/rustdesk-server:latest
TOR_IMAGE=ghcr.io/yourok/torrserver:latest
BES_IMAGE=henrygd/beszel:latest
CADDY_IMAGE=caddy:2-alpine
BOT=ts3audiobot-test
TOR_MODE=''
[[ ! -f $STATE ]] || source "$STATE"
[[ $(id -u) == 0 ]] || { echo 'Нужен root.'; exit 1; }
trap 'echo "Ошибка в строке $LINENO. Операция остановлена, чужие данные не удалены." >&2' ERR
msg() { printf '\n%s\n' "$*"; }
confirm() { local a; read -r -p "$* [yes/нет]: " a; [[ $a == yes ]]; }
ask() { local k=$1 v; read -r -p "$2 [${!k}]: " v; [[ -z $v ]] || printf -v "$k" '%s' "$v"; }
secret() { local k=$1 v; read -r -s -p "$2: " v; echo; [[ $v =~ ^[A-Za-z0-9_@%+=.,!-]{16,64}$ ]] || { msg 'Нужно 16–64 ASCII-символов: буквы, цифры, _ @ % + = . , ! -'; return 1; }; printf -v "$k" '%s' "$v"; }
save() { local k t; t=$(mktemp /etc/homestack.XXXXXX); for k in BASE LAN WAN ENDPOINT EMAIL OWNER SERVER BOT_IMAGE TS_IMAGE MM_IMAGE RD_IMAGE TOR_IMAGE BES_IMAGE CADDY_IMAGE BOT TOR_MODE; do printf '%s=%q\n' "$k" "${!k}" >> "$t"; done; chmod 600 "$t"; mv "$t" "$STATE"; }
exists() { docker inspect "$1" >/dev/null 2>&1; }
managed() { [[ $(docker inspect -f '{{index .Config.Labels "homestack.managed"}}' "$1") == 1 ]]; }
need() { command -v "$1" >/dev/null || { msg "Не найдена команда $1. Используйте пункт зависимостей."; return 1; }; }
ready() {
 need docker; docker info >/dev/null
 [[ $BASE == /mnt/* && $BASE != *' '* && $BASE != *$'\n'* ]] || { msg 'BASE должен быть каталогом /mnt/... без пробелов.'; return 1; }
 local parent dev
 parent=$BASE; while [[ ! -d $parent ]]; do parent=$(dirname "$parent"); done
 dev=$(df -P "$parent" | awk 'END {print $1}')
 [[ $dev == /dev/* ]] || { msg "Диск не смонтирован: файловая система $dev. Остановка."; return 1; }
 mkdir -p "$BASE" "$BASE/backups" "$BASE/https/sites"
 chmod 700 "$BASE" "$BASE/backups" "$BASE/https"
}
config() {
 ask BASE 'Корень данных на внешнем диске'
 ask LAN 'LAN IPv4 роутера, без /24'
 [[ $LAN =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && $LAN != 0.0.0.0 ]] || return 1
 ask WAN 'WAN firewall-зона'; [[ $WAN =~ ^[A-Za-z0-9_]+$ ]] || return 1
 ask ENDPOINT 'Внешний IP или DNS для RustDesk/WireGuard (без порта)'
 [[ -z $ENDPOINT || $ENDPOINT =~ ^[A-Za-z0-9.-]+$ ]] || return 1
 ask EMAIL 'Email ACME (без пробелов)'
 [[ -z $EMAIL || $EMAIL =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || return 1
 ask OWNER 'UID владельца MusicBot'; [[ $OWNER =~ ^[A-Za-z0-9+/]+=*$ ]] || return 1
 ask SERVER 'TeamSpeak адрес:порт для MusicBot'
 save
}
dependencies() {
 need apk
 msg 'Установка недостающих пакетов. Репозитории не меняются; apk del/upgrade/--force не используются.'
 confirm 'Выполнить apk update и установить Bash, Docker, curl, jq, tar и openssl-util?' || return 0
 apk update
 apk add bash docker dockerd curl ca-bundle tar jq openssl-util
 /etc/init.d/dockerd enable
 docker info >/dev/null 2>&1 || /etc/init.d/dockerd start
 msg 'Проверьте docker info: Docker Root Dir должен иметь достаточно места. Диск должен монтироваться до Docker.'
}
freeport() { local p=$1; if netstat -lntu 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$p$"; then msg "Порт $p занят. Не меняем существующий сервис."; return 1; fi; }
newonly() { local n=$1 d=$2; if exists "$n"; then msg "$n уже существует: новая установка запрещена. Используйте обслуживание."; return 1; fi; if [[ -d $d && -n $(ls -A "$d") ]]; then msg "В $d уже есть данные: отказ от перезаписи."; return 1; fi; }
run() { docker run -d --restart unless-stopped --label homestack.managed=1 --log-opt max-size=10m --log-opt max-file=3 "$@"; }
record() { docker inspect -f '{{.Name}} {{.Config.Image}} {{.Image}}' "$@" >> "$BASE/image-ids.txt"; }
# Host-network public services use INPUT rules. Do NOT infer Docker bridge security from them.
fwbegin() {
 need uci; need fw4
 [[ -z $(uci changes firewall) ]] || { msg 'Есть несохранённые firewall-изменения. Разберите их в LuCI.'; return 1; }
 local z found=false
 for z in $(uci show firewall | sed -n 's/^firewall\.\([^=]*\)=zone$/\1/p'); do
  if [[ $(uci -q get "firewall.$z.name") == "$WAN" ]]; then
   found=true; local policy; policy=$(uci -q get "firewall.$z.input" || true)
   [[ $policy == DROP || $policy == REJECT ]] || { msg 'WAN input не DROP/REJECT: публичное применение запрещено.'; return 1; }
  fi
 done
 [[ $found == true ]] || { msg 'WAN-зона не найдена.'; return 1; }
 FWBACK="$BASE/backups/firewall-$(date +%Y%m%d-%H%M%S)-$$"
 cp -p /etc/config/firewall "$FWBACK"
}
rule() {
 local id=$1 proto=$2 port=$3 target=$4 family=${5:-any} source=${6:-$WAN}
 if uci -q get "firewall.$id" >/dev/null; then [[ $(uci -q get "firewall.$id.name") == "HomeStack-$id" ]] || { msg "Чужая секция $id: отказ."; return 1; }; fi
 uci set "firewall.$id=rule"; uci set "firewall.$id.name=HomeStack-$id"
 uci set "firewall.$id.src=$source"; uci set "firewall.$id.proto=$proto"
 uci set "firewall.$id.dest_port=$port"; uci set "firewall.$id.target=$target"
 uci set "firewall.$id.family=$family"; uci reorder "firewall.$id=0"
}
fwapply() {
 if ! fw4 check; then uci revert firewall; msg 'Ошибка fw4: изменения отменены.'; return 1; fi
 uci commit firewall
 if ! /etc/init.d/firewall reload; then cp -p "$FWBACK" /etc/config/firewall; /etc/init.d/firewall reload || true; return 1; fi
 msg "Firewall сохранён. Предыдущая версия: $FWBACK"
}
closed() { fwbegin; rule "$1" "$2" "$3" REJECT any; fwapply; }
install_ts() {
 ready; newonly ts6-server "$BASE/teamspeak"; freeport 9987; freeport 30033
 msg 'Официальный TS6, host-сеть, Query выключен. Сначала WAN закрыт.'
 msg 'Лицензия: https://github.com/teamspeak/teamspeak6-server/blob/main/LICENSE.md'
 confirm 'Принимаете лицензию и устанавливаете TeamSpeak?' || return 0
 fwbegin; rule hs_ts_voice udp 9987 REJECT; rule hs_ts_file tcp 30033 REJECT; rule hs_ts_query tcp '10022 10080 10443' REJECT; fwapply
 docker pull "$TS_IMAGE"; mkdir -p "$BASE/teamspeak"
 local u g; u=$(docker run --rm --entrypoint id "$TS_IMAGE" -u); g=$(docker run --rm --entrypoint id "$TS_IMAGE" -g)
 [[ $u =~ ^[0-9]+$ && $g =~ ^[0-9]+$ ]]; chown "$u:$g" "$BASE/teamspeak"
 run --name ts6-server --network host -e TSSERVER_LICENSE_ACCEPTED=accept \
  -e TSSERVER_QUERY_HTTP_ENABLED=0 -e TSSERVER_QUERY_SSH_ENABLED=0 -e TSSERVER_QUERY_HTTPS_ENABLED=0 \
  -v "$BASE/teamspeak:/var/tsserver" "$TS_IMAGE"
 record ts6-server
 msg "Подключитесь локально к $LAN:9987, получите privilege key через меню логов, задайте пароль сервера. WAN включается ОТДЕЛЬНО."
}
install_mumble() {
 ready; newonly mumble-server "$BASE/mumble"; freeport 64738
 confirm 'Установить Mumble, пока без WAN?' || return 0
 local pass admin; secret pass 'Пароль входа'; secret admin 'ДРУГОЙ пароль SuperUser'; [[ $pass != "$admin" ]]
 closed hs_mumble 'tcp udp' 64738
 docker pull "$MM_IMAGE"; mkdir -p "$BASE/mumble"; chown 10000:10000 "$BASE/mumble"
 printf 'MUMBLE_CONFIG_SERVER_PASSWORD=%s\nMUMBLE_SUPERUSER_PASSWORD=%s\nMUMBLE_CONFIG_USERS=10\nMUMBLE_CONFIG_BANDWIDTH=128000\nMUMBLE_CONFIG_SENDVERSION=false\n' "$pass" "$admin" > "$BASE/mumble.env"
 run --name mumble-server --network host --env-file "$BASE/mumble.env" -v "$BASE/mumble:/data" "$MM_IMAGE"
 unset pass admin; record mumble-server; msg "Mumble: $LAN:64738. Сверьте сертификат. WAN — отдельный пункт."
}
install_rustdesk() {
 ready; newonly hbbs "$BASE/rustdesk"; newonly hbbr "$BASE/rustdesk"
 [[ -n $ENDPOINT ]] || { msg 'Укажите внешний IP/DNS в параметрах.'; return 1; }
 local p; for p in 21115 21116 21117; do freeport "$p"; done
 confirm 'Установить hbbs/hbbr с ключом, пока без WAN?' || return 0
 fwbegin; rule hs_rd_tcp tcp '21115 21116 21117' REJECT; rule hs_rd_udp udp 21116 REJECT; rule hs_rd_web tcp '21114 21118 21119' REJECT; fwapply
 docker pull "$RD_IMAGE"; mkdir -p "$BASE/rustdesk"
 run --name hbbs --network host -v "$BASE/rustdesk:/root" "$RD_IMAGE" hbbs -r "$ENDPOINT:21117" -k _
 local i; for i in {1..20}; do [[ ! -s $BASE/rustdesk/id_ed25519.pub ]] || break; sleep 1; done
 test -s "$BASE/rustdesk/id_ed25519.pub"
 run --name hbbr --network host -v "$BASE/rustdesk:/root" "$RD_IMAGE" hbbr -k _
 record hbbs hbbr
 msg "ID=$ENDPOINT; relay=$ENDPOINT:21117; публичный Key:"; cat "$BASE/rustdesk/id_ed25519.pub"; echo
 msg 'На удаляемых ПК настройте подтверждение/сильный пароль. Ключ сервера НЕ является паролем ПК. Для LAN может потребоваться split DNS.'
}
toml() { local x=$1; x=${x//\\/\\\\}; x=${x//\"/\\\"}; x=${x//$'\r'/\\r}; x=${x//$'\n'/\\n}; x=${x//$'\t'/\\t}; printf '"%s"' "$x"; }
install_bot() {
 ready; need curl; newonly "$BOT" "$BASE/bot/data"; freeport 58913
 confirm 'Установить MusicBot и собрать встроенную панель (нагрузка на RAM/диск)?' || return 0
 local work="$BASE/bot/build" pass='' u
 read -r -s -p 'Пароль TeamSpeak (Enter — нет): ' pass; echo
 mkdir -p "$work" "$BASE/bot/data/bots/musicbot" "$BASE/music"
 curl -fL --retry 3 https://github.com/Splamy/TS3AudioBot/archive/refs/heads/master.tar.gz -o "$work/source.tar.gz"
 tar -xzf "$work/source.tar.gz" -C "$work"
 test -f "$work/TS3AudioBot-master/WebInterface/package.json"
 docker run --rm --name hs-web-build -e npm_config_cache=/work/.npm-cache \
  -v "$work/TS3AudioBot-master/WebInterface:/work" -w /work node:16-bullseye-slim \
  sh -ec 'npm install --no-audit --no-fund; npm run build; test -s dist/index.html'
 mkdir -p "$BASE/bot/data/webinterface"
 cp -R "$work/TS3AudioBot-master/WebInterface/dist"/. "$BASE/bot/data/webinterface/"
 cat > "$BASE/bot/data/ts3audiobot.toml" <<'EOF'
[web]
hosts = ["*"]
port = 58913
[web.api]
enabled = true
command_complexity = 64
matcher = "exact"
[web.interface]
enabled = true
path = "/data/webinterface"
EOF
 { printf 'run = true\n[connect]\naddress = '; toml "$SERVER"; printf '\nname = "MusicBot"\nserver_password = { pw = '; toml "$pass"; printf ', hashed = false, autohash = false }\n'; cat <<'EOF'
client_version = { build = "3.?.? [Build: 5680278000]", platform = "Linux", sign = "Hjd+N58Gv3ENhoKmGYy2bNRBsNNgm5kpiaQWxOj5HN2DXttG6REjymSwJtpJ8muC2gSwRuZi0R+8Laan5ts5CQ==" }
EOF
 } > "$BASE/bot/data/bots/musicbot/bot.toml"
 unset pass
 printf '[[rule]]\nuseruid = "%s"\n"+" = "*"\n' "$OWNER" > "$BASE/bot/data/rights.toml"
 cat > "$BASE/bot/data/NLog.config" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<nlog xmlns="http://www.nlog-project.org/schemas/NLog.xsd" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><targets><target xsi:type="Console" name="console" layout="${longdate}|${level}|${logger}|${message}${onexception:${newline}${exception:format=tostring}}" /></targets><rules><logger name="*" minlevel="Info" writeTo="console" /></rules></nlog>
EOF
 docker pull "$BOT_IMAGE"; u=$(docker run --rm --entrypoint id "$BOT_IMAGE" -u); [[ $u =~ ^[0-9]+$ ]]
 chown -R "$u" "$BASE/bot/data"
 chmod 700 "$BASE/bot/data" "$BASE/bot/data/bots" "$BASE/bot/data/bots/musicbot"
 find "$BASE/bot/data/webinterface" -type d -exec chmod 755 {} \;
 find "$BASE/bot/data/webinterface" -type f -exec chmod 644 {} \;
 run --name "$BOT" -p "$LAN:58913:58913" -v "$BASE/bot/data:/data" -v "$BASE/music:/music:ro" "$BOT_IMAGE"
 record "$BOT"
 msg "Локальная панель: http://$LAN:58913. В личке боту: !api token. Полные права только UID владельца."
 msg 'Подключение бота к TS и файлы музыки проверьте отдельно. Публичный HTTPS для бота защищается ещё и клиентским сертификатом.'
}
install_torr() {
 ready; newonly torrserver "$BASE/torrserver"; freeport 8090
 local mode user pass ip auth
 msg '1) Публичный HTTPS позже: backend ТОЛЬКО 127.0.0.1, обязательный пароль'
 msg '2) LAN + VPN: LAN HTTP без пароля, из WAN не публикуется'
 read -r -p '> ' mode; [[ $mode == 1 || $mode == 2 ]]
 confirm 'Установить выбранный вариант TorrServer?' || return 0
 mkdir -p "$BASE/torrserver/config" "$BASE/torrserver/torrents"
 if [[ $mode == 1 ]]; then
  need jq; read -r -p 'Логин (буквы/цифры): ' user; [[ $user =~ ^[A-Za-z0-9]{3,32}$ ]]
  secret pass 'Пароль TorrServer'; jq -n --arg u "$user" --arg p "$pass" '{($u):$p}' > "$BASE/torrserver/config/accs.db"
  unset pass; ip=127.0.0.1; auth=1; TOR_MODE=public
 else ip=$LAN; auth=0; TOR_MODE=vpn; fi
 closed hs_torr_raw tcp 8090
 docker pull "$TOR_IMAGE"
 run --name torrserver --network host -e TS_IP="$ip" -e TS_PORT=8090 -e TS_HTTPAUTH="$auth" \
  -e TS_CONF_PATH=/opt/ts/config -e TS_TORR_DIR=/opt/ts/torrents -v "$BASE/torrserver:/opt/ts" "$TOR_IMAGE"
 record torrserver; save
 msg 'Публичный режим: добавьте сайт Caddy. VPN-режим: создайте WireGuard-профиль. Прямой WAN-порт 8090 не открывается.'
}
install_beszel() {
 ready; newonly beszel "$BASE/beszel"; freeport 8091
 confirm 'Установить Beszel Hub локально, без agent и без публичного доступа?' || return 0
 docker pull "$BES_IMAGE"; mkdir -p "$BASE/beszel"
 run --name beszel -p "$LAN:8091:8090" -v "$BASE/beszel:/beszel_data" "$BES_IMAGE"
 record beszel
 msg "Сначала создайте пользователя на http://$LAN:8091. Agent автоматически НЕ устанавливается: доступ к Docker/socket требует отдельного решения."
}
# Caddy never listens on host port 80. TLS-ALPN-01 requires direct external TCP443.
caddy_base() {
 [[ -n $EMAIL ]] || { msg 'Задайте EMAIL в параметрах.'; return 1; }
 mkdir -p "$BASE/https/sites" "$BASE/https/data" "$BASE/https/config" "$BASE/https/pki"
 cat > "$BASE/https/Caddyfile" <<EOF
{
 email $EMAIL
 auto_https disable_redirects
 admin 127.0.0.1:2019
 servers {
  protocols h1 h2
 }
}
import /etc/caddy/sites/*.caddy
EOF
}
caddy_reload() {
 docker run --rm --network host -v "$BASE/https:/etc/caddy:ro" "$CADDY_IMAGE" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
 if exists hs-caddy; then
  managed hs-caddy || { msg 'hs-caddy чужой: отказ.'; return 1; }
  docker exec hs-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
 else
  freeport 443; freeport 2019
  run --name hs-caddy --network host -v "$BASE/https:/etc/caddy:ro" \
   -v "$BASE/https/data:/data" -v "$BASE/https/config:/config" "$CADDY_IMAGE"
 fi
 record hs-caddy
}
client_cert() {
 need openssl
 local p="$BASE/client-pki"
 [[ ! -s $p/client.p12 ]] || { mkdir -p "$BASE/https/pki"; cp "$p/ca.crt" "$BASE/https/pki/ca.crt"; msg "Клиентский сертификат уже есть: $p/client.p12"; return 0; }
 [[ ! -e $p/ca.key ]] || { msg 'Есть частично созданный PKI: не перезаписываем.'; return 1; }
 mkdir -p "$p"; chmod 700 "$p"
 local pass; secret pass 'Пароль экспорта клиентского .p12'; printf '%s' "$pass" > "$p/export-pass.txt"; unset pass
 openssl req -x509 -newkey rsa:3072 -nodes -keyout "$p/ca.key" -out "$p/ca.crt" -days 1825 -subj /CN=HomeStack-Client-CA -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign
 openssl req -newkey rsa:3072 -nodes -keyout "$p/client.key" -out "$p/client.csr" -subj /CN=HomeStack-owner
 printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n' > "$p/client.ext"
 openssl x509 -req -in "$p/client.csr" -CA "$p/ca.crt" -CAkey "$p/ca.key" -CAcreateserial -out "$p/client.crt" -days 365 -extfile "$p/client.ext"
 openssl pkcs12 -export -out "$p/client.p12" -inkey "$p/client.key" -in "$p/client.crt" -certfile "$p/ca.crt" -passout "file:$p/export-pass.txt"
 chmod 600 "$p/"*
 mkdir -p "$BASE/https/pki"
 cp "$p/ca.crt" "$BASE/https/pki/ca.crt"
 msg "Импортируйте $p/client.p12 в браузер/систему. Пароль: защищённый файл export-pass.txt. Не публикуйте ключи."
 msg 'Сертификат действует 365 дней. Автоматического продления/отзыва клиентского PKI в этой версии нет.'
}
loopback_torr() {
 # Refuse public proxying of an existing wildcard/host-exposed backend.
 local lines
 lines=$(netstat -lnt 2>/dev/null | awk '$4 ~ /:8090$/ {print $4}')
 [[ $lines == '127.0.0.1:8090' ]] || { msg "Для публикации TorrServer нужен единственный listener 127.0.0.1:8090. Сейчас: $lines"; msg 'Существующий контейнер автоматически не пересоздаём. Используйте VPN или отдельно перенесите bind.'; return 1; }
}
site() {
 ready; need curl; need jq
 local kind domain='' upstream='' path backup='' pass user hash code
 msg '1) TorrServer — Basic Auth, только loopback-backend'
 msg '2) MusicBot — обязательный клиентский сертификат + штатный API-токен'
 msg '3) Beszel — штатный аккаунт (без AUTO_LOGIN)'
 msg '4) LuCI — отдельный пароль Caddy + штатный вход LuCI'
 read -r -p '> ' kind; [[ $kind =~ ^[1-4]$ ]]
 read -r -p 'Полный поддомен, без https:// и порта: ' domain
 domain=${domain,,}
 [[ ${#domain} -lt 254 && $domain =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,63}$ && $domain != *..* ]] || return 1
 msg 'Создайте A-запись на внешний IPv4, удалите ошибочную AAAA. TLS-ALPN требует DNS-only (без CDN-прокси) и доступного TCP443.'
 case $kind in
  1) loopback_torr; upstream=127.0.0.1:8090
     read -r -p 'Существующий логин TorrServer: ' user; [[ $user =~ ^[A-Za-z0-9]{3,32}$ ]]
     secret pass 'Тот же пароль TorrServer'
     code=$(curl -sS --max-time 8 -o /dev/null -w '%{http_code}' "http://$upstream/torrents")
     [[ $code == 401 ]] || { msg "Без авторизации backend вернул $code, а нужен 401. Публикация запрещена."; return 1; }
     local cf; cf=$(mktemp); chmod 600 "$cf"
     printf 'user = "%s:%s"\n' "$user" "$pass" > "$cf"
     code=$(curl --config "$cf" -sS --max-time 8 -o /dev/null -w '%{http_code}' "http://$upstream/"); rm -f "$cf"
     [[ $code =~ ^[23][0-9][0-9]$ ]] || { msg 'Пароль backend не подтверждён.'; return 1; } ;;
  2) upstream="$LAN:58913"; ask upstream 'Backend MusicBot IP:порт'
     client_cert; confirm 'Клиентский .p12 импортирован; права API проверены и анонимного полного доступа нет?' || return 0 ;;
  3) upstream="$LAN:8091"; ask upstream 'Backend Beszel IP:порт'
     if exists beszel; then
      docker inspect beszel --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -Eq '^AUTO_LOGIN=.+$' && { msg 'AUTO_LOGIN задан: публикация запрещена.'; return 1; }
     fi
     confirm 'Аккаунт Beszel уже создан, пароль проверен, лишние способы регистрации/входа выключены?' || return 0 ;;
  4) upstream="$LAN:80"; ask upstream 'Backend LuCI IP:порт'
     msg 'Публичная LuCI — повышенный риск. VPN предпочтительнее. SSH/ttyd и прямой WAN HTTP не открываем.'
     read -r -p 'Отдельный логин Caddy (буквы/цифры): ' user; [[ $user =~ ^[A-Za-z0-9]{3,32}$ ]]; secret pass 'Отдельный пароль Caddy'
     confirm 'Понимаете риск публичной админки и хотите продолжить?' || return 0 ;;
 esac
 [[ $upstream =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]{2,5}$ ]] || return 1
 confirm "Настроить https://$domain -> $upstream? WAN443 включается отдельно." || return 0
 docker pull "$CADDY_IMAGE"; caddy_base
 path="$BASE/https/sites/$domain.caddy"
 if [[ -f $path ]]; then
  confirm "Сайт $domain уже есть. Заменить именно его конфигурацию?" || return 0
  backup="$BASE/backups/$domain-$(date +%Y%m%d-%H%M%S).caddy"; cp -p "$path" "$backup"
 fi
 local temp; temp=$(mktemp "$BASE/https/sites/.site-XXXXXX")
 {
  printf '%s {\n bind 0.0.0.0\n tls {\n  issuer acme {\n   disable_http_challenge\n  }\n' "$domain"
  if [[ $kind == 2 ]]; then
   printf '  client_auth {\n   mode require_and_verify\n   trust_pool file /etc/caddy/pki/ca.crt\n  }\n'
  fi
  printf ' }\n'
  if [[ $kind == 1 || $kind == 4 ]]; then
   hash=$(printf '%s\n' "$pass" | docker run --rm -i "$CADDY_IMAGE" caddy hash-password)
   [[ $hash == '$2'* ]] || { msg 'Не получен bcrypt-хеш.' >&2; return 1; }
   printf ' basic_auth {\n  %s %s\n }\n' "$user" "$hash"
  fi
  printf ' reverse_proxy %s {\n' "$upstream"
  [[ $kind != 1 ]] || printf '  flush_interval -1\n'
  [[ $kind != 4 ]] || printf '  header_up -Authorization\n'
  printf ' }\n}\n'
 } > "$temp"
 unset pass
 mv "$temp" "$path"
 if ! bash "$SELF" --action caddy_apply; then
  if [[ -n $backup ]]; then cp -p "$backup" "$path"; else rm -f "$path"; fi
  msg 'Сайт возвращён к предыдущему состоянию на диске. Проверьте логи hs-caddy.'; return 1
 fi
 msg "Настроено: https://$domain. Включите WAN443 отдельно, затем проверьте из мобильной сети."
 msg 'VLC/Next Player требуют отдельной проверки передачи учётных данных. Публичных исключений для потоков нет.'
}
caddy_apply() { ready; caddy_reload; }
wan_menu() {
 ready
 msg '1) Открыть TS6 (пароль сервера уже установлен)'
 msg '2) Открыть Mumble (пароль и сертификат проверены)'
 msg '3) Открыть RustDesk (Key настроен, удалённые ПК защищены)'
 msg '4) Открыть HTTPS Caddy TCP443'
 msg '5) Закрыть публичные сервисы HomeStack (VPN не трогать)'
 local n; read -r -p '> ' n; [[ $n =~ ^[1-5]$ ]]
 msg 'Правила этого пункта рассчитаны на host-сервисы этого установщика. Чужие Docker DNAT/redirect требуют отдельного аудита.'
 confirm 'Защита настроена; применить изменение WAN?' || return 0
 fwbegin
 case $n in
  1) managed ts6-server; rule hs_ts_v6 'tcp udp' '9987 30033' REJECT ipv6; rule hs_ts_voice udp 9987 ACCEPT ipv4; rule hs_ts_file tcp 30033 ACCEPT ipv4 ;;
  2) managed mumble-server; rule hs_mm_v6 'tcp udp' 64738 REJECT ipv6; rule hs_mumble 'tcp udp' 64738 ACCEPT ipv4 ;;
  3) managed hbbs; managed hbbr; rule hs_rd_v6 'tcp udp' '21115 21116 21117' REJECT ipv6; rule hs_rd_tcp tcp '21115 21116 21117' ACCEPT ipv4; rule hs_rd_udp udp 21116 ACCEPT ipv4 ;;
  4) managed hs-caddy; rule hs_https_v6 tcp 443 REJECT ipv6; rule hs_https tcp 443 ACCEPT ipv4 ;;
  5) rule hs_ts_voice udp 9987 REJECT; rule hs_ts_file tcp 30033 REJECT; rule hs_mumble 'tcp udp' 64738 REJECT; rule hs_rd_tcp tcp '21115 21116 21117' REJECT; rule hs_rd_udp udp 21116 REJECT; rule hs_https tcp 443 REJECT ;;
 esac
 fwapply
}
wireguard() {
 ready; need wg
 [[ -n $ENDPOINT ]] || { msg 'Задайте внешний IP/DNS.'; return 1; }
 [[ ! -e $BASE/wireguard && -z $(uci -q get network.hsmedia || true) ]] || { msg 'Профиль/интерфейс уже существует: без перезаписи.'; return 1; }
 [[ -z $(uci changes network) ]] || return 1
 [[ -z $(uci -q get firewall.hs_wgzone || true) ]] || return 1
 freeport 51820
 msg 'Создаётся один VPN-клиент 10.77.77.2, сервер 10.77.77.1/24. Проверьте отсутствие пересечения подсети.'
 msg 'Клиент получает доступ только к портам 80, 8090, 8091, 58913 LAN-адреса роутера. Это доверенный административный клиент.'
 confirm 'Создать WireGuard и открыть UDP51820 в WAN?' || return 0
 fwbegin
 local nb="$BASE/backups/network-$(date +%Y%m%d-%H%M%S)" p="$BASE/wireguard" ok=false
 cp -p /etc/config/network "$nb"; mkdir -p "$p"
 wg genkey > "$p/server.key"; wg pubkey < "$p/server.key" > "$p/server.pub"
 wg genkey > "$p/client.key"; wg pubkey < "$p/client.key" > "$p/client.pub"; wg genpsk > "$p/psk"
 rollback_wg() {
  if [[ $ok == false ]]; then
   uci revert network; uci revert firewall; ifdown hsmedia 2>/dev/null || true
   cp -p "$nb" /etc/config/network; cp -p "$FWBACK" /etc/config/firewall
   /etc/init.d/firewall reload || true
   echo 'VPN-конфиги восстановлены; ключи оставлены на диске.'
  fi
 }
 trap rollback_wg EXIT
 uci set network.hsmedia=interface; uci set network.hsmedia.proto=wireguard
 uci set "network.hsmedia.private_key=$(cat "$p/server.key")"; uci set network.hsmedia.listen_port=51820
 uci add_list network.hsmedia.addresses=10.77.77.1/24
 local peer; peer=$(uci add network wireguard_hsmedia)
 uci set "network.$peer.public_key=$(cat "$p/client.pub")"; uci set "network.$peer.preshared_key=$(cat "$p/psk")"
 uci add_list "network.$peer.allowed_ips=10.77.77.2/32"; uci set "network.$peer.route_allowed_ips=1"
 uci set firewall.hs_wgzone=zone; uci set firewall.hs_wgzone.name=hswg; uci add_list firewall.hs_wgzone.network=hsmedia
 uci set firewall.hs_wgzone.input=REJECT; uci set firewall.hs_wgzone.output=ACCEPT; uci set firewall.hs_wgzone.forward=REJECT
 rule hs_wg_entry udp 51820 ACCEPT ipv4
 rule hs_wg_apps tcp '80 8090 8091 58913' ACCEPT ipv4 hswg
 uci set "firewall.hs_wg_apps.dest_ip=$LAN"
 fw4 check; uci commit network; fwapply; ifup hsmedia; sleep 3; wg show hsmedia >/dev/null
 cat > "$p/client.conf" <<EOF
[Interface]
PrivateKey = $(cat "$p/client.key")
Address = 10.77.77.2/32
[Peer]
PublicKey = $(cat "$p/server.pub")
PresharedKey = $(cat "$p/psk")
Endpoint = $ENDPOINT:51820
AllowedIPs = $LAN/32
PersistentKeepalive = 25
EOF
 chmod 600 "$p/"*; ok=true; trap - EXIT
 msg "Импортируйте $p/client.conf на одно доверенное устройство. Это СЕКРЕТ. Не выдавайте административный профиль другу для просмотра фильмов."
}
# LuCI migration: lighttpd front + OpenWrt-native uhttpd CGI/RPC backend.
# Existing working lighttpd is preserved; no package deletions.
lighttpd_migrate() {
 ready; need apk; need curl
 if pidof lighttpd >/dev/null; then
  msg 'lighttpd уже работает. Перезаписывать его конфиг не будем.'
  msg 'Сохраните текущую конфигурацию через резервную копию; проверьте вход и загрузку файлов.'
  return 0
 fi
 [[ ! -e /etc/init.d/hs-luci-backend ]] || { msg 'Служба hs-luci-backend уже есть. Автоперезапись запрещена.'; return 1; }
 msg 'Новая схема: lighttpd LAN:80 -> uhttpd 127.0.0.1:18088 для CGI/RPC LuCI.'
 msg 'Nginx не удаляется. Не выполняйте мастер во время других изменений веб-служб.'
 confirm 'Подготовить и протестировать lighttpd на временном LAN:18080?' || return 0
 [[ -z $(uci changes uhttpd) ]] || return 1
 apk update; apk add lighttpd lighttpd-mod-proxy uhttpd uhttpd-mod-ubus rpcd luci-base
 freeport 18080; freeport 18088
 local stamp="$(date +%Y%m%d-%H%M%S)" work="$BASE/luci-migration" nrun=false nen=false urun=false uen=false len=false
 [[ ! -d $work ]] || { msg 'Каталог миграции уже есть. Сначала разберите прошлый запуск.'; return 1; }
 mkdir -p "$work"
 pidof nginx >/dev/null && nrun=true || true
 /etc/init.d/nginx enabled >/dev/null 2>&1 && nen=true || true
 pidof uhttpd >/dev/null && urun=true || true
 /etc/init.d/uhttpd enabled >/dev/null 2>&1 && uen=true || true
 /etc/init.d/lighttpd enabled >/dev/null 2>&1 && len=true || true
 [[ ! -f /etc/config/uhttpd ]] || cp -p /etc/config/uhttpd "$work/uhttpd.old"
 [[ ! -d /etc/lighttpd ]] || tar -czf "$work/lighttpd.old.tar.gz" -C /etc lighttpd
 # Dedicated helper backend avoids modifying the native /etc/config/uhttpd at all.
 cat > /etc/init.d/hs-luci-backend <<'EOF'
#!/bin/sh /etc/rc.common
START=49
USE_PROCD=1
start_service() {
 procd_open_instance
 procd_set_param command /usr/sbin/uhttpd -f -h /www -p 127.0.0.1:18088 -x /cgi-bin -u /ubus
 procd_set_param respawn 3600 5 5
 procd_close_instance
}
EOF
 chmod 755 /etc/init.d/hs-luci-backend
 /etc/init.d/hs-luci-backend start
 mkdir -p /etc/lighttpd
 cat > "$work/test.conf" <<EOF
server.modules = ( "mod_proxy" )
server.document-root = "/www"
server.bind = "$LAN"
server.port = 18080
server.pid-file = "$work/test.pid"
server.errorlog = "$work/test.error.log"
proxy.server = ( "" => ( ( "host" => "127.0.0.1", "port" => 18088 ) ) )
EOF
 lighttpd -tt -f "$work/test.conf"
 lighttpd -f "$work/test.conf"
 msg "Откройте http://$LAN:18080/cgi-bin/luci/ — проверьте вход, страницы, сохранение настроек, upload и терминал."
 if ! confirm 'Все нужные функции проверены и работают?'; then
  [[ ! -f $work/test.pid ]] || kill "$(cat "$work/test.pid")" || true
  /etc/init.d/hs-luci-backend stop; msg 'Переключение отменено. Nginx не трогали.'; return 0
 fi
 kill "$(cat "$work/test.pid")"
 # Independent rollback timer survives loss of the initiating SSH connection.
 cat > "$work/rollback.sh" <<EOF
#!/bin/sh
/etc/init.d/lighttpd stop
/etc/init.d/hs-luci-backend stop
/etc/init.d/hs-luci-backend disable
if [ -f '$work/lighttpd.old.tar.gz' ]; then tar -xzf '$work/lighttpd.old.tar.gz' -C /etc; fi
EOF
 [[ $len == true ]] && echo '/etc/init.d/lighttpd enable' >> "$work/rollback.sh" || echo '/etc/init.d/lighttpd disable' >> "$work/rollback.sh"
 [[ $nen == true ]] && echo '/etc/init.d/nginx enable' >> "$work/rollback.sh" || echo '/etc/init.d/nginx disable' >> "$work/rollback.sh"
 [[ $nrun != true ]] || echo '/etc/init.d/nginx start' >> "$work/rollback.sh"
 chmod 700 "$work/rollback.sh"
 nohup sh -c "sleep 180; [ -f '$work/confirmed' ] || sh '$work/rollback.sh'" > "$work/rollback.log" 2>&1 < /dev/null &
 sed 's/server.port = 18080/server.port = 80/' "$work/test.conf" > /etc/lighttpd/lighttpd.conf
 /etc/init.d/nginx stop || true; /etc/init.d/nginx disable || true
 /etc/init.d/lighttpd enable; /etc/init.d/hs-luci-backend enable; /etc/init.d/lighttpd restart
 msg "Есть 180 секунд: проверьте http://$LAN/cgi-bin/luci/ ."
 local answer=''
 if read -r -t 150 -p 'Введите KEEP, если всё работает: ' answer && [[ $answer == KEEP ]]; then touch "$work/confirmed"; msg 'Переключение подтверждено. Пакеты Nginx сохранены.'
 else sh "$work/rollback.sh"; touch "$work/confirmed"; msg 'Выполнен откат.'; fi
}
status() {
 msg '=== OpenWrt ==='; cat /etc/openwrt_release
 msg '=== Диски ==='; df -h
 msg '=== Контейнеры ==='; docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
 msg '=== Сокеты ==='; netstat -lntu || true
 msg '=== Правила HomeStack ==='; uci show firewall | grep -E 'hs_|HomeStack' || true
 msg '=== Docker root ==='; docker info --format '{{.DockerRootDir}}' || true
 msg 'Статус Up не подтверждает авторизацию, сертификат или подключение MusicBot к TeamSpeak.'
}
logs() { local n; read -r -p 'Контейнер: ' n; [[ $n =~ ^[A-Za-z0-9_.-]+$ ]]; msg 'Осторожно: журнал может содержать ключ администратора/секреты.'; docker logs --tail 100 "$n"; }
control() {
 local n op; read -r -p 'Контейнер: ' n; [[ $n =~ ^[A-Za-z0-9_.-]+$ ]]
 read -r -p 'start / stop / restart / autostart: ' op
 case $op in start|stop|restart) confirm "$op $n?" || return 0; docker "$op" "$n";; autostart) confirm "unless-stopped для $n?" || return 0; docker update --restart unless-stopped "$n";; *) return 1;; esac
}
backup() {
 ready; need tar
 msg 'Согласованная копия данных HomeStack + конфигов роутера. Музыка и build-каталоги исключены. Содержит секреты.'
 msg 'Существующие установки ВНЕ BASE в архив НЕ входят.'
 confirm 'Остановить управляемые HomeStack-контейнеры на время архивации?' || return 0
 local dest="$BASE/backups/stack-$(date +%Y%m%d-%H%M%S).tar.gz" names=() n
 while read -r n; do [[ -z $n ]] || names+=("$n"); done < <(docker ps -q --filter label=homestack.managed=1)
 resume() { if ((${#names[@]})); then docker start "${names[@]}" >/dev/null; fi; }
 trap resume EXIT
 ((${#names[@]} == 0)) || docker stop -t 20 "${names[@]}" >/dev/null
 local snapshot="$BASE/system-snapshot"; mkdir -p "$snapshot"
 cp -p "$STATE" "$snapshot/" 2>/dev/null || true
 local files=(etc/config etc/init.d)
 [[ ! -d /etc/lighttpd ]] || files+=(etc/lighttpd)
 [[ ! -d /etc/nginx ]] || files+=(etc/nginx)
 tar -czf "$snapshot/router-configs.tar.gz" -C / "${files[@]}"
 tar --exclude='./backups' --exclude='./music' --exclude='./bot/build' -czf "$dest" -C "$BASE" .
 chmod 600 "$dest"; resume; trap - EXIT
 msg "Копия: $dest. Храните также на другом устройстве. Автоматического восстановления поверх живой системы нет."
}
audit() {
 msg '=== WAN и перенаправления: проверьте чужие ACCEPT/redirect ==='
 uci show firewall | grep -E '=redirect|\.src=|\.dest=|\.src_dport=|\.dest_port=|\.target=|\.input=' || true
 msg '=== DNS выбранного имени ==='
 local d; read -r -p 'Поддомен (Enter — пропустить): ' d
 [[ -z $d ]] || nslookup "$d" || true
 msg 'Из МОБИЛЬНОЙ сети: HTTPS без секрета не даёт приватных данных; Torr stream без auth даёт 401; прямые 80/8090/8091/58913 закрыты.'
 msg 'У MusicBot требуется .p12; у LuCI — пароль прокси и затем штатный вход. Beszel — штатная сессия.'
 msg 'Проверьте воспроизведение с учётными данными в VLC И Next Player. Если не работает — VPN, а не публичный обход auth.'
 msg 'Docker bridge может иметь собственные правила; одного INPUT REJECT недостаточно для аудита чужих публикаций.'
}
images() { ask BOT_IMAGE 'Образ MusicBot'; ask TS_IMAGE 'Образ TS6'; ask MM_IMAGE 'Образ Mumble'; ask RD_IMAGE 'Образ RustDesk'; ask TOR_IMAGE 'Образ TorrServer'; ask BES_IMAGE 'Образ Beszel'; ask CADDY_IMAGE 'Образ Caddy'; save; }
if [[ ${1:-} == --action ]]; then
 case ${2:-} in config|dependencies|install_ts|install_mumble|install_rustdesk|install_bot|install_torr|install_beszel|site|caddy_apply|wan_menu|wireguard|lighttpd_migrate|status|logs|control|backup|audit|images) "${2}";; *) exit 2;; esac
 exit
fi
if [[ ! -f $STATE ]]; then save; fi
while true; do
 cat <<EOF

OpenWrt HomeStack 1.0-rc1 — единое меню
BASE=$BASE | LAN=$LAN | WAN=$WAN
1) Общие параметры
2) Установить зависимости (apk, без удаления пакетов)
3) Проверка системы
4) Новый TeamSpeak 6
5) Новый MusicBot + панель + права владельца
6) Новый Mumble
7) Новый RustDesk hbbs/hbbr
8) Новый TorrServer: HTTPS+auth / LAN+VPN
9) Новый Beszel Hub (без агента)
10) Добавить HTTPS-сайт Caddy: TorrServer / бот / Beszel / LuCI
11) Открыть/закрыть публичные порты (отдельное подтверждение)
12) WireGuard: один доверенный административный клиент
13) Проверяемая замена Nginx на lighttpd (без удаления пакетов)
14) Журнал контейнера
15) Запуск/остановка/автозапуск контейнера
16) Резервная копия данных HomeStack
17) Аудит внешнего доступа и DNS
18) Образы/версии (в т.ч. @sha256:...)
0) Выход
EOF
 read -r -p '> ' n || break
 case $n in
 1) a=config;; 2) a=dependencies;; 3) a=status;; 4) a=install_ts;; 5) a=install_bot;;
 6) a=install_mumble;; 7) a=install_rustdesk;; 8) a=install_torr;; 9) a=install_beszel;;
 10) a=site;; 11) a=wan_menu;; 12) a=wireguard;; 13) a=lighttpd_migrate;;
 14) a=logs;; 15) a=control;; 16) a=backup;; 17) a=audit;; 18) a=images;;
 0) break;; *) continue;; esac
 bash "$SELF" --action "$a" || msg 'Операция не завершена. Проверьте сообщения. Меню остаётся доступным.'
 [[ ! -f $STATE ]] || source "$STATE"
done

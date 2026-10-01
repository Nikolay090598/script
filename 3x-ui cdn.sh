#!/bin/bash
#################### x-ui-pro + Yandex CDN xHTTP Edition #############################
[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash $0"; exit 1; }

─── Output helpers ──────────────────────────────────────────────────────────

msg_ok()  { echo -e "\e[1;42m $1 \e[0m"; }
msg_err() { echo -e "\e[1;41m $1 \e[0m"; }
msg_inf() { echo -e "\e[1;34m$1\e[0m"; }

echo; msg_inf '           ___    _   _   _  '
msg_inf      ' / __ | |  | __ |) |) / \ '
msg_inf      ' /\    |_| |   |   | \ _/ '; echo
msg_inf '      [ + Yandex Cloud CDN xHTTP Support ] '; echo

─── Pre-flight checks ───────────────────────────────────────────────────────

check_os() {
local os_id os_version
os_id=$(grep -oP '(?<=^ID=).+' /etc/os-release 2>/dev/null | tr -d '"')
os_version=$(grep -oP '(?<=^VERSION_ID=").+(?=")' /etc/os-release 2>/dev/null)

case "${os_id}" in
    ubuntu)
        [[ "$os_version" == "24.04" \vert{}\vert{} "$os_version" == "26.04" ]] && return 0
        ;;
    debian)
        [[ "$os_version" == "12" \vert{}\vert{} "$os_version" == "13" ]] && return 0
        ;;
esac

msg_err "Unsupported OS: ${os_id}${os_version}"
echo -e "\nThis script supports:\n  Ubuntu 24.04 / 26.04\n  Debian 12 / 13"
exit 1


}

check_cpu() {
local cpu_model
cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2-)

if echo "$cpu_model" | grep -qi 'QEMU'; then
    msg_err "QEMU virtual CPU detected!"
    echo -e "\nYour VPS is running with an emulated QEMU processor."
    echo -e "Please switch CPU type to host-passthrough in VPS panel."
    exit 1
fi


}

check_os
check_cpu

─── Constants ───────────────────────────────────────────────────────────────

XUIDB="/etc/x-ui/x-ui.db"
GITHUB_RAW="https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main"
FAKE_SITE_COUNT=50

─── Default argument values ─────────────────────────────────────────────────

domain=""
reality_domain=""
origin_domain=""
cdn_domain=""
ENABLE_CDN="n"
cdn_xhttp_port="9001"
cdn_xhttp_path="/video/download"
UNINSTALL="x"
INSTALL="y"
AUTODOMAIN="n"
CFALLOW="n"

─── Stop & clean previous install ───────────────────────────────────────────

clean_previous_install() {
systemctl stop x-ui 2>/dev/null || true
rm -rf /etc/systemd/system/x-ui.service
rm -rf /usr/local/x-ui
rm -rf /etc/x-ui
rm -rf /etc/nginx/sites-enabled/*
rm -rf /etc/nginx/sites-available/*
rm -rf /etc/nginx/stream-enabled/*
rm -rf /var/www/xhttp-cdn
}

─── Port / path generators ──────────────────────────────────────────────────

get_port() {
echo $(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))
}

gen_random_string() {
local length="$1"
head -c 4096 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$length"
echo
}

gen_group_id() {
head -c 4096 /dev/urandom | tr -dc 'a-z0-9' | head -c 16
echo
}

check_free() {
nc -z 127.0.0.1 "$1" &>/dev/null
return $?
}

make_port() {
while true; do
local PORT
PORT=$(get_port)
if ! check_free "$PORT"; then
echo "$PORT"
break
fi
done
}

─── Generate ports & paths ──────────────────────────────────────────────────

sub_port=$(make_port)
panel_port=$(make_port)
ws_port=$(make_port)
trojan_port=$(make_port)

sub_path=$(gen_random_string 10)
json_path=$(gen_random_string 10)
panel_path=$(gen_random_string 10)
ws_path=$(gen_random_string 10)
trojan_path=$(gen_random_string 10)
xhttp_path=$(gen_random_string 10)
config_username=$(gen_random_string 10)
config_password=$(gen_random_string 10)
diag_path="/net-$(gen_random_string 12)/"
diag_token=$(gen_random_string 16)
mtr_backend_port=$(make_port)

─── Argument parsing ────────────────────────────────────────────────────────

while [ "$#" -gt 0 ]; do
case "$1" in
-install)          INSTALL="$2";           shift 2 ;;
-subdomain)        domain="$2";            shift 2 ;;
-reality_domain)   reality_domain="$2";    shift 2 ;;
-enable_cdn)       ENABLE_CDN="$2";        shift 2 ;;
-origin_domain)    origin_domain="$2";     shift 2 ;;
-cdn_domain)       cdn_domain="$2";        shift 2 ;;
-cdn_port)         cdn_xhttp_port="$2";    shift 2 ;;
-cdn_path)         cdn_xhttp_path="$2";    shift 2 ;;
-ONLY_CF_IP_ALLOW) CFALLOW="$2";           shift 2 ;;
-version)          PANEL_VERSION="$2";     shift 2 ;;
-uninstall)        UNINSTALL="$2";         shift 2 ;;
*)                 shift 1 ;;
esac
done

Pak=$(type apt &>/dev/null && echo "apt" || echo "yum")

─────────────────────────────────────────────────────────────────────────────

UNINSTALL

─────────────────────────────────────────────────────────────────────────────

uninstall_xui() {
printf 'y\n' | x-ui uninstall 2>/dev/null || true
rm -rf /etc/x-ui/ /usr/local/x-ui/
rm -f  /usr/bin/x-ui
$Pak -y remove nginx nginx-common nginx-core nginx-full python3-certbot-nginx$Pak -y purge  nginx nginx-common nginx-core nginx-full python3-certbot-nginx
$Pak -y autoremove$Pak -y autoclean
rm -rf /var/www/html/ /var/www/diagnostics/ /var/www/subpage/ /var/www/xhttp-cdn/ /etc/nginx/ /usr/share/nginx/
systemctl stop mtr-backend 2>/dev/null || true
systemctl disable mtr-backend 2>/dev/null || true
rm -f /etc/systemd/system/mtr-backend.service
rm -rf /usr/local/lib/3x-ui-pro/
systemctl daemon-reload 2>/dev/null || true
}

if [[ ${UNINSTALL} == "y" ]]; then
uninstall_xui
clear && msg_ok "Completely Uninstalled!" && exit 0
fi

─────────────────────────────────────────────────────────────────────────────

GET SERVER IP

─────────────────────────────────────────────────────────────────────────────

IP4_REGEX="^[0-9]{1,3}.[0-9]{1,3}.[0-9]{1,3}.[0-9]{1,3}$"
IP6_REGEX="([a-f0-9:]+:+)+[a-f0-9]+"

get_server_ip() {
IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
IP6=$(ip route get 2620:fe::fe 2>&1 | grep -Po -- 'src \K\S*')
[[ $IP4 =~ $IP4_REGEX ]] \vert{}\vert{} IP4=$(curl -s ipv4.icanhazip.com | tr -d '[:space:]')
[[ $IP6 =~ $IP6_REGEX ]] \vert{}\vert{} IP6=$(curl -s ipv6.icanhazip.com | tr -d '[:space:]')
}

IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
[[ $IP4 =~ $IP4_REGEX ]] \vert{}\vert{} IP4=$(curl -s ipv4.icanhazip.com | tr -d '[:space:]')

─────────────────────────────────────────────────────────────────────────────

DOMAIN VALIDATION

─────────────────────────────────────────────────────────────────────────────

validate_domains() {
while true; do
[[ -n "$domain" ]] && break
echo -en "Enter available subdomain for Panel (sub.domain.tld): " && read -r domain
done
domain=$(echo "$domain" | tr -d '[:space:]')

while true; do
    [[ -n "$reality_domain" ]] && break
    echo -en "Enter available subdomain for REALITY (sub.domain.tld): " && read -r reality_domain
done
reality_domain=$(echo "$reality_domain" | tr -d '[:space:]')

if [[ "$domain" == "$reality_domain" ]]; then
    msg_err "Panel domain and REALITY domain must be different! Got: ${domain}"
    exit 1
fi

if [[ "$ENABLE_CDN" != "y" && "$ENABLE_CDN" != "n" ]]; then
    echo -en "\nEnable Yandex Cloud CDN + xHTTP cascade support? [y/N]: " && read -r ENABLE_CDN
    ENABLE_CDN=${ENABLE_CDN:-n}
fi

if [[ "$ENABLE_CDN" =~ ^[YyДд]$ ]]; then
    ENABLE_CDN="y"
    while true; do
        [[ -n "$origin_domain" ]] && break
        echo -en "Enter Origin domain pointing to this server IP (e.g. origin.domain.com): " && read -r origin_domain
    done
    origin_domain=$(echo "$origin_domain" | tr -d '[:space:]')

    while true; do
        [[ -n "$cdn_domain" ]] && break
        echo -en "Enter CDN domain for clients (e.g. cdn.domain.com): " && read -r cdn_domain
    done
    cdn_domain=$(echo "$cdn_domain" | tr -d '[:space:]')

    [[ "$cdn_xhttp_path" != /* ]] && cdn_xhttp_path="/$cdn_xhttp_path"

    if [[ "$origin_domain" == "$domain" || "$origin_domain" == "$reality_domain" || "$origin_domain" == "$cdn_domain" ]]; then
        msg_err "All domains (Panel, REALITY, Origin, CDN) must be distinct!"
        exit 1
    fi
fi


}

─────────────────────────────────────────────────────────────────────────────

INSTALL PACKAGES

─────────────────────────────────────────────────────────────────────────────

install_packages() {
ufw disable 2>/dev/null || true

if [[ ${INSTALL} == *"y"* ]]; then
    $Pak -y update$Pak -y install curl wget jq bash sudo nginx-full certbot python3-certbot-nginx sqlite3 ufw netcat-openbsd mtr python3 libcap2-bin
    systemctl daemon-reload && systemctl enable --now nginx
fi

apt-get install -yqq --no-install-recommends ca-certificates


}

─────────────────────────────────────────────────────────────────────────────

SSL CERTIFICATES

─────────────────────────────────────────────────────────────────────────────

get_ssl_certs() {
systemctl stop nginx 2>/dev/null || true
fuser -k 80/tcp 80/udp 443/tcp 443/udp 2>/dev/null || true

# 1. Cert for Panel domain
certbot certonly --standalone --non-interactive --agree-tos \
    --register-unsafely-without-email -d "$domain"
if [[ ! -d "/etc/letsencrypt/live/${domain}/" ]]; then
    systemctl start nginx >/dev/null 2>&1
    msg_err "$domain SSL could not be generated! Check Domain A-record." && exit 1
fi

# 2. Cert for REALITY domain
certbot certonly --standalone --non-interactive --agree-tos \
    --register-unsafely-without-email -d "$reality_domain"
if [[ ! -d "/etc/letsencrypt/live/${reality_domain}/" ]]; then
    systemctl start nginx >/dev/null 2>&1
    msg_err "$reality_domain SSL could not be generated! Check Domain A-record." && exit 1
fi

mkdir -p /root/cert/${domain}
chmod 755 /root/cert/*
ln -sf /etc/letsencrypt/live/${domain}/fullchain.pem /root/cert/${domain}/fullchain.pem
ln -sf /etc/letsencrypt/live/${domain}/privkey.pem   /root/cert/${domain}/privkey.pem

# 3. Cert for Origin domain (if CDN enabled)
if [[ "$ENABLE_CDN" == "y" ]]; then
    certbot certonly --standalone --non-interactive --agree-tos \
        --register-unsafely-without-email -d "$origin_domain"
    if [[ ! -d "/etc/letsencrypt/live/${origin_domain}/" ]]; then
        systemctl start nginx >/dev/null 2>&1
        msg_err "$origin_domain SSL could not be generated! Check that $origin_domain points to$IP4." && exit 1
    fi
    mkdir -p /root/cert/${origin_domain}
    ln -sf /etc/letsencrypt/live/${origin_domain}/fullchain.pem /root/cert/${origin_domain}/fullchain.pem
    ln -sf /etc/letsencrypt/live/${origin_domain}/privkey.pem   /root/cert/${origin_domain}/privkey.pem
fi


}

─────────────────────────────────────────────────────────────────────────────

CONFIGURE NGINX

─────────────────────────────────────────────────────────────────────────────

configure_nginx() {
mkdir -p /etc/nginx/stream-enabled /etc/nginx/snippets

local ngx_ver http2_listen="" http2_on=""
ngx_ver=$(nginx -v 2>&1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' || echo 0)
if [[ "$(printf '%s\n' 1.25.1 "$ngx_ver" | sort -V | head -1)" == "1.25.1" ]]; then
    http2_on="http2 on;"
else
    http2_listen=" http2"
fi

# Stream SNI routing:
# REALITY -> 8443 (Xray)
# Panel domain & CDN domains -> 7443 (Nginx internal SSL vhosts with proxy_protocol)
local cdn_stream_entries=""
if [[ "$ENABLE_CDN" == "y" ]]; then
    cdn_stream_entries="    ${origin_domain}     www;
${cdn_domain}        www;"
fi

cat > /etc/nginx/stream-enabled/stream.conf <<EOF


map $ssl_preread_server_name $sni_name {
hostnames;
${reality_domain}    xray;
${domain}            www;
${cdn_stream_entries}
default              xray;
}

upstream xray { server 127.0.0.1:8443; }
upstream www  { server 127.0.0.1:7443; }

server {
proxy_protocol on;
set_real_ip_from unix:;
listen     443;
listen     [::]:443;
proxy_pass $sni_name;
ssl_preread on;
}
EOF

grep -xqFR "stream { include /etc/nginx/stream-enabled/*.conf; }" /etc/nginx/* \
    || echo "stream { include /etc/nginx/stream-enabled/*.conf; }" >> /etc/nginx/nginx.conf
grep -xqFR "load_module modules/ngx_stream_module.so;" /etc/nginx/* \
    || sed -i '1s/^/load_module \/usr\/lib\/nginx\/modules\/ngx_stream_module.so; /' /etc/nginx/nginx.conf
grep -xqFR "worker_rlimit_nofile 65535;" /etc/nginx/* \
    || echo "worker_rlimit_nofile 65535;" >> /etc/nginx/nginx.conf
sed -i "/worker_connections/c\worker_connections 65535;" /etc/nginx/nginx.conf

# Port 80 redirect
local domains_80="${domain} ${reality_domain}"
[[ "$ENABLE_CDN" == "y" ]] && domains_80="${domains_80} ${origin_domain}"

cat > /etc/nginx/sites-available/80.conf <<EOF


server {
listen 80;
server_name ${domains_80};
return 301 https://$host$request_uri;
}
EOF

# Shared proxy locations for xray inbounds
cat > /etc/nginx/snippets/includes.conf <<EOF
location /${sub_path}/ {
    if (\$hack = 1) { return 404; }
    proxy_redirect off;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_pass https://127.0.0.1:${sub_port};
}
location = /${sub_path} {
    if (\$hack = 1) { return 404; }
    proxy_redirect off;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_pass https://127.0.0.1:${sub_port};
}
location ~ ^/${sub_path}/(?<clash_sub_id>[^/]+)$ {
    if (\$hack = 1) { return 404; }
    if (\$serve_clash_yaml = 1) { rewrite ^ /__clash_api?sub_id=\$clash_sub_id last; }
    proxy_redirect off;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_pass https://127.0.0.1:${sub_port};
}
location /assets  { proxy_pass https://127.0.0.1:${sub_port}; }
location /assets/ { proxy_pass https://127.0.0.1:${sub_port}; }

location /${json_path} {
    if (\$hack = 1) { return 404; }
    proxy_redirect off;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_pass https://127.0.0.1:${sub_port};
}
location /${json_path}/ {
    if (\$hack = 1) { return 404; }
    proxy_redirect off;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_pass https://127.0.0.1:${sub_port};
}

location ~ ^/(?<fwdport>\d+)/(?<fwdpath>.*)\$ {
    if (\$hack = 1) { return 404; }
    client_max_body_size 0;
    client_body_timeout 1d;
    grpc_read_timeout 1d;
    grpc_socket_keepalive on;
    proxy_read_timeout 1d;
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_socket_keepalive on;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    if (\$content_type ~* "GRPC") {
        grpc_pass grpc://127.0.0.1:\$fwdport\$is_args\$args;
        break;
    }
    if (\$http_upgrade ~* "(WEBSOCKET|WS)") {
        proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
        break;
    }
    if (\$request_method ~* ^(PUT|POST|GET)\$) {
        proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
        break;
    }
}

location / { try_files \$uri \$uri/ =404; }


EOF

cat > /etc/nginx/sites-available/00-maps.conf <<EOF


map $http_user_agent $is_clash_ua {
~*(clash|clashx|clashn|mihomo|stash|surfboard)  1;
default                                          0;
}
map "$is_clash_ua:$arg_provider" $serve_clash_yaml {
"1:"    1;
default 0;
}
EOF

# Main domain vhost
cat > "/etc/nginx/sites-available/${domain}" <<EOF


limit_req_zone  $binary_remote_addr zone=diag_api:10m  rate=6r/m;
limit_req_zone  $binary_remote_addr zone=diag_page:10m rate=30r/m;
limit_conn_zone $binary_remote_addr zone=per_ip:10m;

map $cookie_diag_key $diag_auth {
"${diag_token}" 1;
default          0;
}

server {
server_tokens off;
server_name ${domain};
listen 7443 ssl${http2_listen} proxy_protocol;
listen [::]:7443 ssl${http2_listen} proxy_protocol;
${http2_on}
index index.html index.htm index.php;
root /var/www/html/;
real_ip_header proxy_protocol;
set_real_ip_from 127.0.0.1;
absolute_redirect off;
http2_body_preread_size 128k;
client_body_buffer_size 512k;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
if (\$host !~* ^(.+\.)?${domain}$)            { return 444; }
if ($scheme ~* https)                          { set $safe 1; }
if ($ssl_server_name !~* ^(.+.)?${domain}\$) { set \$safe "\${safe}0"; }
if (\$safe = 10)                                { return 444; }
if (\$request_uri ~ "(\"|'|\`|~|,|:|;|%|\\$|&&|??|0x00|0X00|||\|{|}|

$$|$$

|<|>|...|../|///)") { set $hack 1; }
error_page 400 401 402 403 500 501 502 503 504 =404 /404;
proxy_intercept_errors on;

location /${panel_path}/ {
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_pass https://127.0.0.1:${panel_port};
}
location /${panel_path} {
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_pass https://127.0.0.1:${panel_port};
}

location = /${panel_path}/diag {
    auth_request /__diag_auth;
    error_page 401 403 = @diag_login;
    try_files /__nonexistent @diag_sso_ok;
}
location @diag_login {
    return 302 /${panel_path}/;
}
location @diag_sso_ok {
    add_header Set-Cookie "diag_key=${diag_token}; Path=${diag_path}; Secure; HttpOnly; SameSite=Lax; Max-Age=604800";
    return 302 ${diag_path};
}
location = /__diag_auth {
    internal;
    proxy_pass https://127.0.0.1:${panel_port}/${panel_path}/panel/;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Requested-With XMLHttpRequest;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_intercept_errors on;
    error_page 300 301 302 303 304 305 307 308 400 401 402 403 404 405 500 501 502 503 504 =401 @diag_denied;
}
location @diag_denied { return 401; }

location ^~ ${diag_path} {
    if (\$diag_auth = 0) { return 302 /${panel_path}/diag; }
    limit_req  zone=diag_page burst=10 nodelay;
    limit_conn per_ip 5;
    alias /var/www/diagnostics/;
    index index.html;
    try_files \$uri \$uri/ /index.html;
    add_header Set-Cookie "diag_key=${diag_token}; Path=${diag_path}; Secure; HttpOnly; SameSite=Lax; Max-Age=604800" always;
    add_header Cache-Control "no-store" always;
    add_header X-Robots-Tag "noindex, nofollow" always;
}

location ^~ ${diag_path}api/mtr {
    if (\$diag_auth = 0) { return 404; }
    limit_req  zone=diag_api burst=2 nodelay;
    limit_conn per_ip 2;
    proxy_pass         http://127.0.0.1:${mtr_backend_port}/api/mtr;
    proxy_http_version 1.1;
    proxy_set_header   X-Real-IP       \$remote_addr;
    proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_read_timeout 120s;
    proxy_send_timeout 120s;
    proxy_intercept_errors off;
}

location ^~ ${diag_path}api/st/up {
    if (\$diag_auth = 0) { return 404; }
    access_log              off;
    limit_conn              per_ip 8;
    proxy_pass              http://127.0.0.1:${mtr_backend_port}/api/st/up;
    proxy_http_version      1.1;
    proxy_set_header        X-Real-IP       \$remote_addr;
    proxy_request_buffering off;
    client_max_body_size    64m;
    proxy_read_timeout      60s;
    proxy_send_timeout      60s;
    add_header              Cache-Control "no-store" always;
}

location = ${diag_path}api/st/ping {
    if (\$diag_auth = 0) { return 404; }
    access_log off;
    limit_conn per_ip 8;
    add_header Cache-Control "no-store" always;
    default_type text/plain;
    return 200 "";
}

location = ${diag_path}api/st/getip {
    if (\$diag_auth = 0) { return 404; }
    proxy_pass          http://127.0.0.1:${mtr_backend_port}/api/st/getip;
    proxy_http_version  1.1;
    proxy_set_header    X-Real-IP \$remote_addr;
    add_header          Cache-Control "no-store" always;
}

location ^~ ${diag_path}testfiles/ {
    if (\$diag_auth = 0) { return 404; }
    alias      /var/www/diagnostics/testfiles/;
    access_log off;
    add_header Cache-Control "no-store, no-cache, must-revalidate" always;
    add_header Content-Disposition "attachment" always;
}

location = /__clash_api {
    internal;
    proxy_pass          http://127.0.0.1:${mtr_backend_port}/api/clash\$is_args\$args;
    proxy_http_version  1.1;
    proxy_set_header    X-Real-IP \$remote_addr;
    add_header          Content-Type        "text/yaml; charset=utf-8" always;
    add_header          Content-Disposition "attachment; filename=clash.yaml" always;
    add_header          Cache-Control       "no-store" always;
}

include /etc/nginx/snippets/includes.conf;


}
EOF

# REALITY domain vhost
cat > "/etc/nginx/sites-available/${reality_domain}" <<EOF


server {
server_tokens off;
server_name ${reality_domain};
listen 9443 ssl${http2_listen};
listen [::]:9443 ssl${http2_listen};
${http2_on}
index index.html index.htm index.php;
root /var/www/html/;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
ssl_certificate     /etc/letsencrypt/live/${reality_domain}/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/${reality_domain}/privkey.pem;
if (\$host !~* ^(.+\.)?${reality_domain}$)            { return 444; }
if ($scheme ~* https)                                  { set $safe 1; }
if ($ssl_server_name !~* ^(.+.)?${reality_domain}\$) { set \$safe "\${safe}0"; }
if (\$safe = 10)                                        { return 444; }
if (\$request_uri ~ "(\"|'|\`|~|,|:|;|%|\\$|&&|??|0x00|0X00|||\|{|}|

$$|$$

|<|>|...|../|///)") { set $hack 1; }
error_page 400 401 402 403 500 501 502 503 504 =404 /404;
proxy_intercept_errors on;

location /${panel_path}/ {
    proxy_redirect off;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_pass http://127.0.0.1:${panel_port};
}
location /${panel_path} {
    proxy_redirect off;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_pass http://127.0.0.1:${panel_port};
}

include /etc/nginx/snippets/includes.conf;


}
EOF

# Dedicated Origin / CDN vhost
if [[ "$ENABLE_CDN" == "y" ]]; then
    mkdir -p /var/www/xhttp-cdn
    cat > /var/www/xhttp-cdn/index.html <<'EOF'


    cat > "/etc/nginx/sites-available/${origin_domain}" <<EOF


server {
server_tokens off;
server_name ${origin_domain} ${cdn_domain};
listen 7443 ssl${http2_listen} proxy_protocol;
listen [::]:7443 ssl${http2_listen} proxy_protocol;
${http2_on}
index index.html;
root /var/www/xhttp-cdn;
real_ip_header proxy_protocol;
set_real_ip_from 127.0.0.1;
absolute_redirect off;

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
ssl_certificate     /etc/letsencrypt/live/${origin_domain}/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/${origin_domain}/privkey.pem;

client_max_body_size 0;

location ${cdn_xhttp_path} {
    rewrite ^${cdn_xhttp_path}(.*)\$ ${cdn_xhttp_path}/ break;

    proxy_pass http://127.0.0.1:${cdn_xhttp_port};
    proxy_http_version 1.1;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_buffering off;
    proxy_request_buffering off;
    proxy_read_timeout 1h;
    proxy_send_timeout 1h;
}

location / {
    try_files \$uri \$uri/ /index.html;
    expires 1h;
    add_header Cache-Control "public";
}


}
EOF
fi

# Activate configs
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default
ln -sf "/etc/nginx/sites-available/00-maps.conf"       /etc/nginx/sites-enabled/
ln -sf "/etc/nginx/sites-available/${domain}"          /etc/nginx/sites-enabled/
ln -sf "/etc/nginx/sites-available/${reality_domain}"  /etc/nginx/sites-enabled/
ln -sf "/etc/nginx/sites-available/80.conf"            /etc/nginx/sites-enabled/
if [[ "$ENABLE_CDN" == "y" ]]; then
    ln -sf "/etc/nginx/sites-available/${origin_domain}" /etc/nginx/sites-enabled/
fi

if [[ $(nginx -t 2>&1 | grep -o 'successful') != "successful" ]]; then
    msg_err "nginx config check failed!" && exit 1
fi

systemctl start nginx


}

─────────────────────────────────────────────────────────────────────────────

INSTALL PANEL (3x-ui)

─────────────────────────────────────────────────────────────────────────────

_arch() {
case "$(uname -m)" in
x86_64|x64|amd64)          echo 'amd64'  ;;
i86|x86)                  echo '386'    ;;
armv8|armv8|arm64|aarch64) echo 'arm64' ;;
armv7*|armv7|arm)          echo 'armv7'  ;;
armv6*|armv6)              echo 'armv6'  ;;
armv5*|armv5)              echo 'armv5'  ;;
s390x)                     echo 's390x'  ;;
*) echo "Unsupported CPU architecture!" && exit 1 ;;
esac
}

_panel_initial_config() {
/usr/local/x-ui/x-ui setting -username "asdfasdf" -password "asdfasdf" -port "2096" -webBasePath "asdfasdf"
/usr/local/x-ui/x-ui migrate
}

install_panel() {
local tag_version
apt-get update && apt-get install -y -q wget curl tar tzdata

cd /usr/local/

if [[ -n "$PANEL_VERSION" ]]; then
    tag_version="v${PANEL_VERSION#v}"
    if ! curl -fsLo /dev/null "https://api.github.com/repos/MHSanaei/3x-ui/releases/tags/${tag_version}"; then
        echo "3x-ui release ${tag_version} not found." && exit 1
    fi
else
    tag_version=$(curl -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" \
        | grep -m1 '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    if [[ ! "$tag_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        tag_version=$(curl -4 -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" \
            | grep -m1 '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    fi
    if [[ ! "$tag_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Failed to fetch 3x-ui version." && exit 1
    fi
fi

echo "Installing 3x-ui ${tag_version} ..."
wget -N -O /usr/local/x-ui-linux-$(_arch).tar.gz \
    "https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(_arch).tar.gz"
[[ $? -ne 0 ]] && echo "Download failed." && exit 1

wget -O /usr/bin/x-ui-temp https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh
[[ $? -ne 0 ]] && echo "Failed to download x-ui.sh" && exit 1

[[ -d /usr/local/x-ui/ ]] && systemctl stop x-ui 2>/dev/null; rm -rf /usr/local/x-ui/

tar zxvf x-ui-linux-$(_arch).tar.gz
rm -f x-ui-linux-$(_arch).tar.gz

cd x-ui
chmod +x x-ui x-ui.sh

if [[ $(_arch) == "armv5" || $(_arch) == "armv6" || $(_arch) == "armv7" ]]; then
    mv bin/xray-linux-$(_arch) bin/xray-linux-arm
    chmod +x bin/xray-linux-arm
fi
chmod +x bin/xray-linux-$(_arch)

mv -f /usr/bin/x-ui-temp /usr/bin/x-ui
chmod +x /usr/bin/x-ui

_panel_initial_config

cp -f x-ui.service.debian /etc/systemd/system/x-ui.service
systemctl daemon-reload
systemctl enable x-ui
systemctl start x-ui

msg_ok "3x-ui ${tag_version} installed."


}

─────────────────────────────────────────────────────────────────────────────

CONFIGURE X-UI DATABASE

─────────────────────────────────────────────────────────────────────────────

configure_xui_db() {
if [[ ! -f $XUIDB ]]; then
msg_err "x-ui.db not found — panel may not be installed." && exit 1
fi

x-ui stop 2>/dev/null || true

local output private_key public_key trojan_pass emoji_flag xray_bin
xray_bin="/usr/local/x-ui/bin/xray-linux-$(_arch)"
[[ -f "$xray_bin" ]] || xray_bin="/usr/local/x-ui/bin/xray-linux-arm"
output=$("$xray_bin" x25519)
private_key=$(echo "$output" | grep "^PrivateKey:" | awk '{print $2}')
public_key=$(echo "$output"  | grep "^Password"   | awk '{print $3}')
trojan_pass=$(gen_random_string 10)

local gid_col="" gid_reality="" gid_ws="" gid_xhttp="" gid_trojan="" gid_cdn=""
if sqlite3 "$XUIDB" "PRAGMA table_info(hosts);" | grep -qw "group_id"; then
    gid_col='"group_id",'
    gid_reality="'$(gen_group_id)',"
    gid_ws="'$(gen_group_id)',"
    gid_xhttp="'$(gen_group_id)',"
    gid_trojan="'$(gen_group_id)',"
    gid_cdn="'$(gen_group_id)',"
fi
emoji_flag=$(LC_ALL=en_US.UTF-8 curl -s --max-time 10 https://ipwho.is/ | jq -r '.flag.emoji' 2>/dev/null)
[[ -z "$emoji_flag" || "$emoji_flag" == "null" ]] && emoji_flag="🌐"

local sub_uri="https://${domain}/${sub_path}/"
local json_uri="https://${domain}/${json_path}?name="

local shor
shor=($(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) \
       $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8))

sqlite3 $XUIDB <<EOF


DELETE FROM "settings" WHERE "key" IN ("webCertFile","webKeyFile");

INSERT INTO "settings" ("key","value") VALUES ("subPort",             '${sub_port}');
INSERT INTO "settings" ("key","value") VALUES ("subPath",             '/${sub_path}/');
INSERT INTO "settings" ("key","value") VALUES ("subURI",              '${sub_uri}');
INSERT INTO "settings" ("key","value") VALUES ("subJsonPath",         '/${json_path}');
INSERT INTO "settings" ("key","value") VALUES ("subJsonURI",          '${json_uri}');
INSERT INTO "settings" ("key","value") VALUES ("subClashEnable",      'false');
INSERT INTO "settings" ("key","value") VALUES ("subEnableRouting",    'false');
INSERT INTO "settings" ("key","value") VALUES ("subEnable",           'true');
INSERT INTO "settings" ("key","value") VALUES ("webListen",           '');
INSERT INTO "settings" ("key","value") VALUES ("webDomain",           '');
INSERT INTO "settings" ("key","value") VALUES ("webCertFile",         '');
INSERT INTO "settings" ("key","value") VALUES ("webKeyFile",          '');
INSERT INTO "settings" ("key","value") VALUES ("sessionMaxAge",       '60');
INSERT INTO "settings" ("key","value") VALUES ("pageSize",            '50');
INSERT INTO "settings" ("key","value") VALUES ("expireDiff",          '0');
INSERT INTO "settings" ("key","value") VALUES ("trafficDiff",         '0');
INSERT INTO "settings" ("key","value") VALUES ("remarkModel",         '-ieo');
INSERT INTO "settings" ("key","value") VALUES ("tgBotEnable",         'false');
INSERT INTO "settings" ("key","value") VALUES ("tgBotToken",          '');
INSERT INTO "settings" ("key","value") VALUES ("tgBotProxy",          '');
INSERT INTO "settings" ("key","value") VALUES ("tgBotAPIServer",      '');
INSERT INTO "settings" ("key","value") VALUES ("tgBotChatId",         '');
INSERT INTO "settings" ("key","value") VALUES ("tgRunTime",           '@daily');
INSERT INTO "settings" ("key","value") VALUES ("tgBotBackup",         'false');
INSERT INTO "settings" ("key","value") VALUES ("tgBotLoginNotify",    'true');
INSERT INTO "settings" ("key","value") VALUES ("tgCpu",               '80');
INSERT INTO "settings" ("key","value") VALUES ("tgLang",              'en-US');
INSERT INTO "settings" ("key","value") VALUES ("timeLocation",        'Europe/Moscow');
INSERT INTO "settings" ("key","value") VALUES ("secretEnable",        'false');
INSERT INTO "settings" ("key","value") VALUES ("subDomain",           '');
INSERT INTO "settings" ("key","value") VALUES ("subCertFile",         '');
INSERT INTO "settings" ("key","value") VALUES ("subKeyFile",          '');
INSERT INTO "settings" ("key","value") VALUES ("subUpdates",          '12');
INSERT INTO "settings" ("key","value") VALUES ("subEncrypt",          'true');
INSERT INTO "settings" ("key","value") VALUES ("subShowInfo",         'true');
INSERT INTO "settings" ("key","value") VALUES ("subJsonFragment",     '');
INSERT INTO "settings" ("key","value") VALUES ("subJsonNoises",       '');
INSERT INTO "settings" ("key","value") VALUES ("subJsonMux",          '');
INSERT INTO "settings" ("key","value") VALUES ("subJsonRules",        '');
INSERT INTO "settings" ("key","value") VALUES ("datepicker",          'gregorian');

INSERT INTO "inbounds"
("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing")
VALUES (
'1','0','0','0','${emoji_flag} reality','1','0','','8443','vless',
'{"clients": [],"decryption": "none","fallbacks": []}',
'{
"network": "tcp",
"security": "reality",
"realitySettings": {
"show": false,
"xver": 0,
"target": "127.0.0.1:9443",
"serverNames": ["${reality_domain}"],
"privateKey": "${private_key}",
"minClient": "",
"maxClient": "",
"maxTimediff": 0,
"shortIds": [
"${shor[0]}","${shor[1]}","${shor[2]}","${shor[3]}",
"${shor[4]}","${shor[5]}","${shor[6]}","${shor[7]}"
],
"settings": {
"publicKey": "${public_key}",
"fingerprint": "firefox",
"serverName": "",
"spiderX": "/"
}
},
"tcpSettings": {
"acceptProxyProtocol": true,
"header": {"type":"none"}
}
}',
'inbound-8443',
'{"enabled":false,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
);

INSERT INTO "inbounds"
("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing")
VALUES (
'1','0','0','0','${emoji_flag} ws','1','0','','${ws_port}','vless',
'{"clients": [],"decryption": "none","fallbacks": []}',
'{
"network": "ws",
"security": "none",
"wsSettings": {
"acceptProxyProtocol": false,
"path": "/${ws_port}/${ws_path}",
"host": "${domain}",
"headers": {}
}
}',
'inbound-${ws_port}',
'{"enabled":false,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
);

INSERT INTO "inbounds"
("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing")
VALUES (
'1','0','0','0','${emoji_flag} trojan-grpc','1','0','','${trojan_port}','trojan',
'{"clients": [],"fallbacks": []}',
'{
"network": "grpc",
"security": "none",
"grpcSettings": {
"serviceName": "/${trojan_port}/${trojan_path}",
"authority": "${domain}",
"multiMode": false
}
}',
'inbound-${trojan_port}',
'{"enabled":false,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
);

INSERT INTO "hosts" ("inbound_id",${gid_col}"sort_order","remark","address","port","security","fingerprint","alpn")
VALUES
((SELECT id FROM inbounds WHERE tag='inbound-8443'),       ${gid_reality} 0, 'reality', '${domain}', 443, 'same', '',        '[]'),
((SELECT id FROM inbounds WHERE tag='inbound-${ws_port}'), ${gid_ws}      0, 'ws',      '${domain}', 443, 'tls',  'firefox', '["h2","http/1.1"]'),
((SELECT id FROM inbounds WHERE tag='inbound-${trojan_port}'), ${gid_trojan} 0, 'trojan', '${domain}', 443, 'tls', 'firefox', '["h2","http/1.1"]');
EOF

# CDN xHTTP Inbound and Host configuration
if [[ "$ENABLE_CDN" == "y" ]]; then
    local cdn_stream_settings
    cdn_stream_settings=$(cat <<EOF


{
"network": "xhttp",
"security": "none",
"xhttpSettings": {
"path": "${cdn_xhttp_path}",
"host": "",
"mode": "packet-up",
"scMaxBufferedPosts": 30,
"scMaxEachPostBytes": 1000000,
"xPaddingBytes": "100-1000",
"uplinkHTTPMethod": "GET",
"paddingObfsMode": true,
"paddingKey": "_ts",
"paddingHeader": "X-Cache-Status",
"paddingPlacement": "queryInHeader",
"paddingMethod": "tokenish",
"sessionPlacement": "cookie",
"sessionKey": "visitor_id",
"sequencePlacement": "cookie",
"sequenceKey": "chunk",
"noSSEHeader": false
}
}
EOF
)
sqlite3 $XUIDB <<EOF
INSERT INTO "inbounds"
("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing")
VALUES (
'1','0','0','0','${emoji_flag} CDN xHTTP','1','0','127.0.0.1','${cdn_xhttp_port}','vless',
'{"clients": [],"decryption": "none","fallbacks": []}',
'${cdn_stream_settings}',
'inbound-${cdn_xhttp_port}',
'{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'
);

INSERT INTO "hosts" ("inbound_id",${gid_col}"sort_order","remark","address","port","security","fingerprint","alpn")
VALUES
((SELECT id FROM inbounds WHERE tag='inbound-${cdn_xhttp_port}'), ${gid_cdn} 0, 'cdn-xhttp', '${cdn_domain}', 443, 'tls', 'firefox', '["h2"]');
EOF
fi

/usr/local/x-ui/x-ui setting \
    -username  "${config_username}" \
    -password  "${config_password}" \
    -port      "${panel_port}"      \
    -webBasePath "${panel_path}"

/usr/local/x-ui/x-ui cert \
    -webCert    "/root/cert/${domain}/fullchain.pem" \
    -webCertKey "/root/cert/${domain}/privkey.pem"

x-ui start


}

─────────────────────────────────────────────────────────────────────────────

INSTALL FAKE SITE & CLASH SUB

─────────────────────────────────────────────────────────────────────────────

install_clash_sub() {
local clash_dir="/var/www/subpage"
mkdir -p "${clash_dir}"
if curl -fsSL "${GITHUB_RAW}/assets/clash/clash.yaml" -o "${clash_dir}/clash.yaml.tpl"; then
sed -i "s|\${DOMAIN}|${domain}|g"     "${clash_dir}/clash.yaml.tpl"
sed -i "s|\${SUB_PATH}|${sub_path}|g" "${clash_dir}/clash.yaml.tpl"
chown -R www-data:www-data "${clash_dir}" 2>/dev/null || true
chmod 644 "${clash_dir}/clash.yaml.tpl"
fi
}

install_fake_site() {
local idx=$(( (RANDOM % FAKE_SITE_COUNT) + 1 ))
local site_id
site_id=$(printf "site-%02d" "$idx")
local url="${GITHUB_RAW}/assets/fake-sites/${site_id}/index.html"

mkdir -p /var/www/html
if curl -fsSL "$url" -o /var/www/html/index.html; then
    chown -R www-data:www-data /var/www/html 2>/dev/null || true
    chmod 644 /var/www/html/index.html
    msg_ok "Fake cover site '${site_id}' installed."
fi


}

─────────────────────────────────────────────────────────────────────────────

INSTALL DIAGNOSTICS PAGE

─────────────────────────────────────────────────────────────────────────────

install_diagnostics() {
local diag_webroot="/var/www/diagnostics"
local backend_script="/usr/local/lib/3x-ui-pro/mtr-backend.py"

mkdir -p "${diag_webroot}"
curl -fsSL "${GITHUB_RAW}/assets/diagnostics/index.html" -o "${diag_webroot}/index.html" 2>/dev/null || true
sed -i \
    -e "s|__DIAG_PATH__|${diag_path}|g" \
    -e "s|__SERVER_DOMAIN__|${domain}|g" \
    -e "s|__SERVER_IP__|${IP4}|g" \
    "${diag_webroot}/index.html" 2>/dev/null || true

curl -fsSL "${GITHUB_RAW}/assets/diagnostics/librespeed/speedtest.js" \
    -o "${diag_webroot}/speedtest.js" 2>/dev/null || true
curl -fsSL "${GITHUB_RAW}/assets/diagnostics/librespeed/speedtest_worker.js" \
    -o "${diag_webroot}/speedtest_worker.js" 2>/dev/null || true

local testfiles="${diag_webroot}/testfiles"
mkdir -p "${testfiles}"
[[ -f "${testfiles}/test-15k.bin"  ]] || dd if=/dev/zero bs=1024    count=15   of="${testfiles}/test-15k.bin"  status=none
[[ -f "${testfiles}/test-100m.bin" ]] || dd if=/dev/zero bs=1048576 count=100  of="${testfiles}/test-100m.bin" status=none
chown -R www-data:www-data "${diag_webroot}" 2>/dev/null || true

mkdir -p "$(dirname "${backend_script}")"
curl -fsSL "${GITHUB_RAW}/assets/diagnostics/mtr-backend.py" -o "${backend_script}" 2>/dev/null || true
chmod 755 "${backend_script}" 2>/dev/null || true

command -v setcap &>/dev/null && setcap cap_net_raw+ep "$(command -v mtr)"        2>/dev/null || true
command -v setcap &>/dev/null && setcap cap_net_raw+ep "$(command -v mtr-packet)" 2>/dev/null || true

id mtr-backend &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin mtr-backend 2>/dev/null || true

cat > /etc/systemd/system/mtr-backend.service <<EOF


[Unit]
Description=3x-ui-pro MTR diagnostics backend
After=network.target

[Service]
Type=simple
User=mtr-backend
Group=mtr-backend
ExecStart=/usr/bin/python3 ${backend_script} --port ${mtr_backend_port}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=yes
AmbientCapabilities=CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mtr-backend 2>/dev/null || true
systemctl restart mtr-backend 2>/dev/null || true


}

─────────────────────────────────────────────────────────────────────────────

SYSTEM TUNING

─────────────────────────────────────────────────────────────────────────────

tune_system() {
local params=(
"net.core.default_qdisc=fq"
"net.ipv4.tcp_congestion_control=bbr"
"net.ipv4.ip_forward=1"
"fs.file-max=2097152"
"net.ipv4.tcp_timestamps=1"
"net.ipv4.tcp_sack=1"
"net.ipv4.tcp_window_scaling=1"
"net.core.rmem_max=16777216"
"net.core.wmem_max=16777216"
"net.ipv4.tcp_rmem=4096 87380 16777216"
"net.ipv4.tcp_wmem=4096 65536 16777216"
)
for p in "${params[@]}"; do
grep -qxF "$p" /etc/sysctl.conf || echo "$p" >> /etc/sysctl.conf
done
sysctl -p >/dev/null 2>&1 || true
}

─────────────────────────────────────────────────────────────────────────────

CRON & FIREWALL

─────────────────────────────────────────────────────────────────────────────

setup_cron() {
crontab -l 2>/dev/null | grep -v "certbot|x-ui" | crontab -
(crontab -l 2>/dev/null; echo '@daily   x-ui restart > /dev/null 2>&1 && nginx -s reload')    | crontab -
(crontab -l 2>/dev/null; echo '@monthly certbot renew --non-interactive --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx" > /dev/null 2>&1') | crontab -
}

setup_firewall() {
ufw disable 2>/dev/null || true
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable
}

─────────────────────────────────────────────────────────────────────────────

RESULTS

─────────────────────────────────────────────────────────────────────────────

show_results() {
clear
if systemctl is-active --quiet x-ui; then
printf '0\n' | x-ui | grep --color=never -i ':'
msg_inf "────────────────────────────────────────────────────────────────────────────────"
msg_inf "3x-UI Secure Panel: https://${domain}/${panel_path}/\n"
echo -e "Username:  ${config_username}\n"
echo -e "Password:  ${config_password}\n"
msg_inf "────────────────────────────────────────────────────────────────────────────────"
msg_inf "REALITY Subdomain:  ${reality_domain}\n"
msg_inf "Network Diagnostics: https://${domain}/${panel_path}/diag\n"

    if [[ "$ENABLE_CDN" == "y" ]]; then
        msg_inf "────────────────────────────────────────────────────────────────────────────────"
        msg_ok "YANDEX CLOUD CDN + xHTTP READY"
        echo -e "Origin Domain:      https://${origin_domain}"
        echo -e "Client CDN Domain:  ${cdn_domain}"
        echo -e "xHTTP Location:     ${cdn_xhttp_path}"
        echo -e "Local Xray Inbound: 127.0.0.1:${cdn_xhttp_port}"
        echo -e "\nДальнейшие шаги в Yandex Cloud:"
        echo -e "1. В Certificate Manager выпустите Let's Encrypt для ${cdn_domain} (через DNS CNAME)."
        echo -e "2. В Cloud CDN создайте ресурс:"
        echo -e "   - Источник: ${origin_domain} (HTTPS, SNI host: ${origin_domain}, Host header: ${origin_domain})"
        echo -e "   - Доменное имя: ${cdn_domain}"
        echo -e "   - Сертификат: созданный сертификат из Certificate Manager"
        echo -e "   - Кеширование: ОТКЛЮЧИТЬ (в CDN и браузере)"
        echo -e "   - HTTP-методы: разрешить GET, HEAD, OPTIONS"
        echo -e "3. Добавьте CNAME запись для ${cdn_domain} на выданный хост Яндекса."
        echo -e "4. В панели 3x-ui добавьте клиента в подключение 'CDN xHTTP' и выдайте подписку!"
    fi

    msg_inf "────────────────────────────────────────────────────────────────────────────────"
    msg_inf "Please save this screen!"
else
    nginx -t
    printf '0\n' | x-ui | grep --color=never -i ':'
    msg_err "x-ui or nginx check failed. Try on a clean Linux install."
fi


}

─────────────────────────────────────────────────────────────────────────────

MAIN

─────────────────────────────────────────────────────────────────────────────

main() {
validate_domains
clean_previous_install
install_packages
get_server_ip
get_ssl_certs

if systemctl is-active --quiet x-ui; then
    x-ui restart
else
    install_panel
fi

configure_nginx
configure_xui_db
install_clash_sub
install_fake_site
install_diagnostics
tune_system
setup_cron
setup_firewall

if ! systemctl is-enabled --quiet x-ui; then
    systemctl daemon-reload && systemctl enable x-ui.service
fi
x-ui restart

show_results


}

main
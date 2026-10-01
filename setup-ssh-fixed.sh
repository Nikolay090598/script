#!/bin/bash
set -Eeuo pipefail
umask 077
trap 'echo -e "\033[0;31mОшибка на строке ${LINENO}: ${BASH_COMMAND}\033[0m" >&2' ERR

#==============================================================================
# VPS Setup v4.4.0 - VPN Foundation + SSH Honeypot + Swap + Limits
#
# Run from Gist Raw URL (interactive-safe):
#   curl -fsSL "RAW_URL" | sudo bash
#==============================================================================

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; NC='\033[0m'

echo -e "${G}VPS Setup v4.4.0 - VPN Foundation + безопасная настройка SSH${NC}"

if [[ ${EUID} -ne 0 ]]; then
  echo -e "${R}Запускайте с root!${NC}"
  exit 1
fi

exec 8>/run/vps-foundation.lock
flock -n 8 || { echo "Другой экземпляр уже работает" >&2; exit 1; }
TTY_DEV="/dev/tty"
need_tty() {
  if [[ ! -e "$TTY_DEV" ]]; then
    echo -e "${R}Нет /dev/tty. Запускайте из интерактивной SSH-сессии.${NC}" >&2
    exit 1
  fi
}

prompt() {
  local __var="$1" __msg="$2" __def="${3-}" __val=""
  need_tty
  if [[ -n "${__def}" ]]; then
    read -r -p "${__msg} [${__def}]: " __val < "$TTY_DEV"
    __val="${__val:-$__def}"
  else
    read -r -p "${__msg}: " __val < "$TTY_DEV"
  fi
  __val="${__val%$'\r'}"
  printf -v "$__var" '%s' "$__val"
}

prompt_enter() {
  need_tty
  read -r -p "$1" _ < "$TTY_DEV"
}

is_port() { [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535)); }

is_ipv4() {
  local ip="$1" a b c d o
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b c d <<< "$ip"
  for o in "$a" "$b" "$c" "$d"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    (( 10#$o >= 0 && 10#$o <= 255 )) || return 1
  done
  return 0
}

is_ip() {
  is_ipv4 "$1" || [[ "$1" == *:* && "$1" =~ ^[0-9a-fA-F:.]+$ ]]
}

get_os_info() {
  local osr=""
  [[ -e /etc/os-release ]] && osr="/etc/os-release" || osr="/usr/lib/os-release"
  . "$osr"

  local id="${ID:-}"
  local codename="${VERSION_CODENAME:-}"
  [[ -z "$codename" ]] && codename="${UBUNTU_CODENAME:-}"

  if [[ -z "$codename" && -n "${VERSION:-}" ]]; then
    codename="$(sed -n 's/.*(\([^)]\+\)).*/\1/p' <<< "$VERSION" | head -n1)"
  fi

  if [[ -z "$id" || -z "$codename" ]]; then
    echo -e "${R}Не смог определить ID/CODENAME из os-release.${NC}" >&2
    exit 1
  fi
  echo "$id" "$codename"
}

validate_supported_os() {
  local id="$1"
  if [[ "$id" != "debian" && "$id" != "ubuntu" ]]; then
    echo -e "${R}Неподдерживаемый дистрибутив ID: $id. Разрешены: debian или ubuntu.${NC}" >&2
    return 1
  fi
  return 0
}

read -r DISTRO_ID CODENAME < <(get_os_info)
validate_supported_os "$DISTRO_ID" || exit 1

CPU_FLAGS="$(grep -m1 -E '^flags\b' /proc/cpuinfo 2>/dev/null || true)"
has_flag() { grep -qw "$1" <<< "${CPU_FLAGS}"; }
supports_x64v3() {
  has_flag avx && has_flag avx2 && has_flag bmi1 && has_flag bmi2 && has_flag f16c && has_flag fma && has_flag movbe && has_flag xsave && (has_flag lzcnt || has_flag abm)
}

prompt SSH_PORT "SSH порт" "45123"
if ! is_port "$SSH_PORT" || ((10#$SSH_PORT == 22 || 10#$SSH_PORT == 80 || 10#$SSH_PORT == 443)); then
  echo -e "${R}Некорректный SSH порт: $SSH_PORT (22, 80 и 443 зарезервированы)${NC}"
  exit 1
fi

SSH_PORT="$((10#$SSH_PORT))"
prompt KEY_ONLY "Режим SSH: только по ключу (y/n)" "y"
[[ "$KEY_ONLY" =~ ^[YyNn]$ ]] || { echo "Введите y или n" >&2; exit 1; }
SSH_PUBLIC_KEY=""

if [[ "$KEY_ONLY" =~ ^[Yy]$ ]]; then
  prompt SSH_KEY_INPUT "Публичный SSH ключ (строка 'ssh-ed25519 ...')" ""
  if [[ -n "${SSH_KEY_INPUT:-}" && -f "$SSH_KEY_INPUT" ]]; then
    SSH_PUBLIC_KEY="$(cat "$SSH_KEY_INPUT")"
  else
    SSH_PUBLIC_KEY="${SSH_KEY_INPUT:-}"
  fi

  if [[ -z "${SSH_PUBLIC_KEY:-}" ]]; then
    echo -e "${R}Вы выбрали режим 'только ключ', но ключ не задан.${NC}"
    exit 1
  fi
  [[ "$SSH_PUBLIC_KEY" != *$'\n'* && "$SSH_PUBLIC_KEY" != *$'\r'* ]] || { echo "Нужен один ключ в одной строке" >&2; exit 1; }
  key_tmp="$(mktemp)"
  printf '%s\n' "$SSH_PUBLIC_KEY" > "$key_tmp"
  if ! ssh-keygen -lf "$key_tmp" >/dev/null 2>&1; then
    rm -f "$key_tmp"
    echo "Некорректный публичный SSH-ключ" >&2
    exit 1
  fi
  rm -f "$key_tmp"
else
  echo -e "${Y}Внимание: будет разрешён парольный вход по SSH.${NC}"
fi

prompt SWAP_SIZE_GB "Размер Swap в гигабайтах (0 - не создавать)" "2"
if ! [[ "$SWAP_SIZE_GB" =~ ^[0-9]{1,2}$ ]] || ((10#$SWAP_SIZE_GB > 64)); then
  echo -e "${R}Ошибка: размер Swap должен быть целым числом от 0 до 64.${NC}"
  exit 1
fi

echo ""
echo -e "${Y}--- Часовой пояс ---${NC}"
echo "1) Asia/Yekaterinburg (Екатеринбург) [По умолчанию]"
echo "2) Europe/Moscow (Москва)"
echo "3) Asia/Novosibirsk (Новосибирск)"
echo "4) Asia/Vladivostok (Владивосток)"
echo "5) UTC (Гринвич)"
echo "6) Ввести свой вариант вручную"

while true; do
  prompt TZ_CHOICE "Ваш выбор (1-6)" "1"
  TZ_CHOICE="$(tr -d '[:space:]' <<< "$TZ_CHOICE")"
  case "$TZ_CHOICE" in
    1) TIMEZONE="Asia/Yekaterinburg"; break ;;
    2) TIMEZONE="Europe/Moscow"; break ;;
    3) TIMEZONE="Asia/Novosibirsk"; break ;;
    4) TIMEZONE="Asia/Vladivostok"; break ;;
    5) TIMEZONE="UTC"; break ;;
    6) 
       prompt TIMEZONE "Введите часовой пояс (например Europe/Warsaw)" "UTC"
       break 
       ;;
    *) echo -e "${R}Некорректный ввод. Выберите цифру от 1 до 6.${NC}" >&2 ;;
  esac
done

if [[ ! -f "/usr/share/zoneinfo/$TIMEZONE" && "$TIMEZONE" != "UTC" ]]; then
  echo -e "${Y}Часовой пояс '$TIMEZONE' не найден. Будет использован UTC.${NC}"
  TIMEZONE="UTC"
fi

get_remote_ip() {
  local ip=""
  ip="$(awk '{print $1}' <<< "${SSH_CONNECTION:-}")"
  if [[ -z "${ip:-}" ]]; then
    ip="$(who -m 2>/dev/null | awk '{print $NF}' | tr -d '()' || true)"
  fi
  echo "$ip"
}

CURRENT_IP="$(get_remote_ip)"
WHITELIST_IP=""

echo ""
echo -e "${Y}--- Whitelist для fail2ban (опционально) ---${NC}"

if [[ -n "${CURRENT_IP:-}" ]]; then
  echo -e "Текущий IP (авто): ${G}${CURRENT_IP}${NC}"
  echo "1) Использовать авто-IP"
  echo "2) Ввести другой IP вручную"
  echo "3) Не использовать whitelist"

  while true; do
    prompt WL_RAW "Выбор (1/2/3 или IP)" "3"
    WL_RAW="$(tr -d '[:space:]' <<< "$WL_RAW")"
    if [[ "$WL_RAW" =~ ^[123]$ ]]; then
      case "$WL_RAW" in
        1) WHITELIST_IP="$CURRENT_IP" ;;
        2) prompt WHITELIST_IP "Введите статический IP" "" ;;
        3) WHITELIST_IP="" ;;
      esac
      break
    elif is_ip "$WL_RAW"; then
      WHITELIST_IP="$WL_RAW"
      break
    else
      echo -e "${R}Некорректный ввод.${NC}" >&2
    fi
  done
else
  echo "Авто-IP не найден. 1) Ввести вручную 2) Пропустить"
  while true; do
    prompt WL_RAW "Выбор (1/2 или IP)" "2"
    WL_RAW="$(tr -d '[:space:]' <<< "$WL_RAW")"
    if [[ "$WL_RAW" =~ ^[12]$ ]]; then
      [[ "$WL_RAW" == "1" ]] && prompt WHITELIST_IP "Введите статический IP" ""
      break
    elif is_ip "$WL_RAW"; then
      WHITELIST_IP="$WL_RAW"
      break
    fi
  done
fi
if [[ -n "$WHITELIST_IP" ]] && ! is_ip "$WHITELIST_IP"; then
  echo "Whitelist: некорректный IP, пропускаю." >&2
  WHITELIST_IP=""
fi
prompt SETUP_ONLY "Только обновить SSH и ловушку, без обновления пакетов/ядра/сети? (y/n)" "n"
[[ "$SETUP_ONLY" =~ ^[YyNn]$ ]] || { echo "Введите y или n" >&2; exit 1; }
prompt INSTALL_XANMOD "Установить стороннее ядро XanMod? (y/n)" "n"
[[ "$INSTALL_XANMOD" =~ ^[YyNn]$ ]] || { echo "Введите y или n" >&2; exit 1; }

echo ""
echo -e "${Y}═══════════════════════════════════════════${NC}"
echo -e "OS:            ${G}${DISTRO_ID} (${CODENAME})${NC}"
echo -e "Timezone:      ${G}${TIMEZONE}${NC}"
echo -e "SSH Порт:      ${G}${SSH_PORT} (с защитой UFW limit)${NC}"
echo -e "Firewall:      ${G}ALLOW 80,443(TCP+UDP) + SSH (+22 fallback)${NC}"
echo -e "Swap файл:     ${G}$(( SWAP_SIZE_GB > 0 ? SWAP_SIZE_GB : 0 )) GB${NC}"
echo "Только SSH:     $SETUP_ONLY"
echo "XanMod:        $INSTALL_XANMOD (по умолчанию сохраняется штатное ядро)"
echo "Только ключ:   применяется после проверки входа на новом порту"
echo "-------------------------------------------"
prompt_enter "Нажмите ENTER для старта..."

if [[ "$SETUP_ONLY" =~ ^[Yy]$ ]]; then
  for tool in python3 ufw fail2ban-client ssh-keygen ss iptables-restore; do
    command -v "$tool" >/dev/null || { echo "Нет $tool. Запустите полный режим настройки." >&2; exit 1; }
  done
else
echo -e "${G}[1/4] Базовая настройка (Обновление, Время, Логи, Swap)${NC}"
# Не угадываем диск для загрузчика: исправляем устаревший debconf интерактивно.
check_grub_devices() {
  local devices="" device missing=0
  if ! dpkg-query -W -f='${Status}' grub-pc 2>/dev/null | grep -q 'install '; then
    return 0
  fi
  devices="$(debconf-show grub-pc | sed -n 's/^[ *]*grub-pc\/install_devices: *//p')"
  IFS=',' read -r -a grub_devices <<< "$devices"
  for device in "${grub_devices[@]}"; do
    device="${device//[[:space:]]/}"
    [[ -z "$device" || -b "$device" ]] || missing=1
  done
  if (( missing )); then
    echo "GRUB ссылается на отсутствующий диск: $devices"
    lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS
    echo "Выберите загрузочный диск целиком, НЕ раздел. При сомнении остановитесь."
    need_tty
    DEBIAN_FRONTEND=dialog dpkg --configure grub-pc < /dev/tty
    DEBIAN_FRONTEND=dialog dpkg-reconfigure grub-pc < /dev/tty
  fi
}
BACKUP="$(mktemp -d /root/vps-backup.XXXXXXXX)"
cp -a /etc/ssh "$BACKUP/ssh"
cp -a /etc/fstab "$BACKUP/fstab"
for directory in ufw fail2ban; do
  [[ ! -d "/etc/$directory" ]] || cp -a "/etc/$directory" "$BACKUP/$directory"
done
printf '%s\n' "$BACKUP" > /root/.vps-backup-path
check_grub_devices
export DEBIAN_FRONTEND=noninteractive
dpkg --configure -a
apt update
apt upgrade -y -o Dpkg::Options::="--force-confdef"
apt install -y gnupg wget ca-certificates socat chrony curl tar ufw fail2ban iproute2 openssh-server util-linux python3

timedatectl set-timezone "$TIMEZONE" || true
systemctl enable --now chrony
chronyc makestep || true

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-vps-limits.conf << 'EOF'
[Journal]
SystemMaxUse=250M
SystemMaxFileSize=50M
ForwardToSyslog=no
EOF
systemctl restart systemd-journald

SWAP_SIZE_GB="$((10#$SWAP_SIZE_GB))"
if (( SWAP_SIZE_GB > 0 )); then
  if [[ -e /swapfile || -L /swapfile ]]; then
    [[ -f /swapfile && ! -L /swapfile ]] || { echo "Небезопасный /swapfile" >&2; exit 1; }
    [[ "$(blkid -p -s TYPE -o value /swapfile || true)" == swap ]] || {
      echo "/swapfile существует, но не является swap. Не перезаписываю." >&2; exit 1;
    }
  else
    fs_type="$(findmnt -n -o FSTYPE -T /)"
    [[ "$fs_type" == ext4 || "$fs_type" == xfs ]] || {
      echo "Swap: автоматическое создание поддерживает ext4 и XFS. Выберите размер 0." >&2; exit 1;
    }
    free_bytes="$(df -B1 --output=avail / | tail -n 1 | tr -d ' ')"
    required_bytes="$((SWAP_SIZE_GB * 1024 * 1024 * 1024))"
    (( free_bytes > required_bytes + 1073741824 )) || { echo "Недостаточно места для swap и запаса 1 GB" >&2; exit 1; }
    # dd исключает дырки в файле; не перезаписываем существующий swap.
    dd if=/dev/zero of=/swapfile bs=1M count="$((SWAP_SIZE_GB * 1024))" status=progress
    chmod 600 /swapfile
    mkswap /swapfile
  fi
  chmod 600 /swapfile
  if ! swapon --show=NAME --noheadings | grep -Fxq /swapfile; then
    swapon /swapfile
  fi
  if ! awk '$1 == "/swapfile" { found=1 } END { exit !found }' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
fi

echo -e "${G}[2/4] Ядро${NC}"
if [[ "$INSTALL_XANMOD" =~ ^[Yy]$ ]]; then
[[ "$(dpkg --print-architecture)" == amd64 ]] || { echo "XanMod требует amd64" >&2; exit 1; }
for flag in cx16 lahf_lm popcnt ssse3 sse4_1 sse4_2; do
  has_flag "$flag" || { echo "CPU не поддерживает x86-64-v2: $flag. Сохраните штатное ядро." >&2; exit 1; }
done
install -m 0755 -d /etc/apt/keyrings
wget -qO- https://dl.xanmod.org/archive.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg
chmod 644 /etc/apt/keyrings/xanmod-archive-keyring.gpg
cat > /etc/apt/sources.list.d/xanmod.sources << EOF
Types: deb
URIs: http://deb.xanmod.org
Suites: ${CODENAME}
Components: main
Signed-By: /etc/apt/keyrings/xanmod-archive-keyring.gpg
EOF
apt update

if supports_x64v3; then
  apt install -y linux-xanmod-x64v3 || apt install -y linux-xanmod-x64v2
else
  apt install -y linux-xanmod-x64v2
fi
else
  echo "Сохраняется штатное ядро."
fi

echo -e "${G}[3/4] Сеть (BBR, буферы TCP/UDP, Форвардинг)${NC}"
cat > /etc/sysctl.d/99-vpn.conf << EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_notsent_lowat=16384
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.core.somaxconn=65535
fs.file-max=1000000
net.ipv4.ip_local_port_range=1024 65535
EOF
modprobe tcp_bbr 2>/dev/null || true
if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
  sed -i '/^net.ipv4.tcp_congestion_control=bbr$/d' /etc/sysctl.d/99-vpn.conf
  echo "BBR пока недоступен: сохраняется текущий алгоритм." >&2
else
  echo 'tcp_bbr' > /etc/modules-load.d/bbr.conf
fi
if [[ ! -e /proc/sys/net/ipv6/conf/all/forwarding ]]; then
  sed -i '/^net.ipv6.conf.all.forwarding=/d' /etc/sysctl.d/99-vpn.conf
fi
sysctl -p /etc/sysctl.d/99-vpn.conf

fi
if [[ -n "$WHITELIST_IP" ]]; then
  WHITELIST_IP="$(python3 - "$WHITELIST_IP" << 'IPCHECK'
import ipaddress, sys
print(ipaddress.ip_address(sys.argv[1]))
IPCHECK
)"
fi

echo -e "${G}[4/4] Подготовка setup-ssh.sh${NC}"

cat > /root/.vps-config << EOF
$SSH_PORT
$KEY_ONLY
$SSH_PUBLIC_KEY
$WHITELIST_IP
EOF

chmod 600 /root/.vps-config

cat > /root/setup-ssh.sh << 'SSHSETUP'
#!/bin/bash
set -Eeuo pipefail
umask 077
[[ $EUID == 0 ]] || { echo 'Запустите от root'; exit 1; }
exec 9>/run/vps-ssh-setup.lock
flock -n 9 || { echo 'Другой экземпляр уже работает'; exit 1; }
mapfile -t CONFIG < /root/.vps-config
SSH_PORT="${CONFIG[0]}"
KEY_ONLY="${CONFIG[1]}"
SSH_KEY="${CONFIG[2]}"
WL_IP="${CONFIG[3]}"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && ((SSH_PORT > 0 && SSH_PORT <= 65535 && SSH_PORT != 22)) || exit 1

CURRENT_PORT="$(awk '{print $4}' <<< "${SSH_CONNECTION:-}")"
if ss -H -lntp "sport = :$SSH_PORT" | grep -q .; then
  ss -H -lntp "sport = :$SSH_PORT" | grep -q sshd || {
    echo "Порт $SSH_PORT занят другим процессом" >&2; exit 1;
  }
fi
BACKUP="$(mktemp -d /root/ssh-backup.XXXXXXXX)"
cp -a /etc/ssh "$BACKUP/ssh"
cp -a /etc/ufw/before.rules "$BACKUP/before.rules"
[[ ! -f /etc/ufw/before6.rules ]] || cp -a /etc/ufw/before6.rules "$BACKUP/before6.rules"
if [[ -f /etc/fail2ban/jail.d/99-vps-ssh.local ]]; then
  cp -a /etc/fail2ban/jail.d/99-vps-ssh.local "$BACKUP/jail"
fi
SOCKET_ACTIVE="$(systemctl is-active ssh.socket 2>/dev/null || true)"
SOCKET_ENABLED="$(systemctl is-enabled ssh.socket 2>/dev/null || true)"
# Добавляем ключ, сохраняя прежние ключи.
if [[ -n "$SSH_KEY" ]]; then
  KEY_TMP="$(mktemp)"
  printf '%s\n' "$SSH_KEY" > "$KEY_TMP"
  ssh-keygen -lf "$KEY_TMP" >/dev/null || { rm -f "$KEY_TMP"; exit 1; }
  rm -f "$KEY_TMP"
  install -d -m 700 /root/.ssh
  touch /root/.ssh/authorized_keys
  cp -a /root/.ssh/authorized_keys "$BACKUP/authorized_keys"
  if ! grep -Fxq -- "$SSH_KEY" /root/.ssh/authorized_keys; then
    printf '\n%s\n' "$SSH_KEY" >> /root/.ssh/authorized_keys
  fi
  chmod 600 /root/.ssh/authorized_keys
fi

# Управляемые правила ловушки. Удаляются только блоки с известными маркерами.
cat > /root/vps-port22-rules.py << 'RULEPY'
#!/usr/bin/python3
import os, re, sys, tempfile
from pathlib import Path
mode, filename = sys.argv[1:]
p = Path(filename)
s = p.read_text()
for tag in ('SSH_HONEYPOT_TRAP', 'VPS_PORT22_TRAP'):
    start = '# ===== ' + tag + '_START ====='
    end = '# ===== ' + tag + '_END ====='
    if s.count(start) != s.count(end) or s.count(start) > 1:
        raise SystemExit('Некорректные маркеры ловушки: ' + filename)
    if start in s:
        a, b = s.index(start), s.index(end)
        if b < a:
            raise SystemExit('Некорректный порядок маркеров: ' + filename)
        s = s[:a] + s[b+len(end):].lstrip('\n')
if mode == 'add':
    a = s.index('*filter\n')
    b = s.index('\nCOMMIT', a)
    rule = re.search(r'^-A ufw-before-input\b', s[a:b], re.M)
    if not rule:
        raise SystemExit('Не найдена цепочка ufw-before-input: ' + filename)
    pos = a + rule.start()
    block = '''# ===== VPS_PORT22_TRAP_START =====
-A ufw-before-input -p tcp --dport 22 --tcp-flags SYN,RST,ACK SYN -m conntrack --ctstate NEW -j LOG --log-prefix "VPS_PORT22_TRAP: "
-A ufw-before-input -p tcp --dport 22 -j DROP
# ===== VPS_PORT22_TRAP_END =====
'''
    s = s[:pos] + block + s[pos:]
elif mode != 'remove':
    raise SystemExit('Неизвестная операция')
st = p.stat()
fd, tmp = tempfile.mkstemp(dir=p.parent, prefix='.vps-port22-')
try:
    with os.fdopen(fd, 'w') as f:
        f.write(s)
    os.chmod(tmp, st.st_mode & 0o777)
    os.chown(tmp, st.st_uid, st.st_gid)
    os.replace(tmp, p)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
RULEPY
chmod 700 /root/vps-port22-rules.py
install -d -m 755 /etc/fail2ban/filter.d /etc/fail2ban/action.d
cat > /etc/fail2ban/filter.d/vps-port22.conf << 'FILTER'
[Definition]
# Только сообщения ядра с нашим префиксом, TCP SYN и точным портом 22.
failregex = ^.*VPS_PORT22_TRAP: IN=\S* OUT=\S* .*\bSRC=<HOST>\s+DST=\S+ .*\bPROTO=TCP\s+SPT=\d+\s+DPT=22\s+.*\bSYN\b.*$
ignoreregex =
journalmatch = _TRANSPORT=kernel
FILTER
cat > /etc/fail2ban/action.d/vps-port22-permanent.conf << 'ACTION'
[Definition]
actionstart =
actionstop =
actioncheck =
actionban = /usr/sbin/ufw insert 1 deny from <ip> to any comment 'vps-port22-permanent'
# Постоянные UFW-правила сохраняются даже при остановке или переустановке Fail2ban.
# Снимать их нужно командой /root/unban-port22.sh IP.
actionunban =
ACTION
cat > /root/unban-port22.sh << 'UNBAN'
#!/bin/bash
set -euo pipefail
[[ $EUID == 0 && $# == 1 ]] || { echo 'Использование: bash /root/unban-port22.sh IP'; exit 1; }
python3 - "$1" << 'VALIDATE'
import ipaddress, os, re, subprocess, sys
ip = ipaddress.ip_address(sys.argv[1])
status = subprocess.check_output(['ufw', 'status'], text=True, env={**os.environ, 'LC_ALL':'C'})
for line in status.splitlines():
    if '# vps-port22-permanent' not in line:
        continue
    m = re.search(r'\bDENY IN\s+(\S+)', line)
    if m and ipaddress.ip_address(m[1]) == ip:
        break
else:
    raise SystemExit('Постоянное правило этой ловушки для IP не найдено; ничего не удалено.')
VALIDATE
ufw --force delete deny from "$1" to any comment 'vps-port22-permanent'
fail2ban-client set port22-trap unbanip "$1" || true
echo "Постоянный бан $1 снят. Другие правила и jail не изменены."
UNBAN
chmod 700 /root/unban-port22.sh

# Создаём команду отката до изменения конфигурации.
{
  echo '#!/bin/bash'
  echo 'set -euo pipefail'
  printf 'BACKUP=%q\nSOCKET_ACTIVE=%q\nSOCKET_ENABLED=%q\n' "$BACKUP" "$SOCKET_ACTIVE" "$SOCKET_ENABLED"
  cat << 'ROLLBACK'
rm -f /etc/ssh/sshd_config.d/00-vps.conf
cp -a "$BACKUP/ssh/." /etc/ssh/
/usr/sbin/sshd -t
systemctl unmask ssh.socket 2>/dev/null || true
ufw delete deny log 22/tcp 2>/dev/null || true
if [[ "$SOCKET_ACTIVE" == active ]]; then
  systemctl stop ssh.service
  systemctl start ssh.socket
fi
systemctl restart ssh.service
if [[ "$SOCKET_ENABLED" == enabled ]]; then systemctl enable ssh.socket; fi
if [[ "$SOCKET_ENABLED" == masked ]]; then systemctl mask ssh.socket; fi
if [[ -f "$BACKUP/jail" ]]; then
  cp -a "$BACKUP/jail" /etc/fail2ban/jail.d/99-vps-ssh.local
else
  rm -f /etc/fail2ban/jail.d/99-vps-ssh.local
fi
cp -a "$BACKUP/before.rules" /etc/ufw/before.rules
[[ ! -f "$BACKUP/before6.rules" ]] || cp -a "$BACKUP/before6.rules" /etc/ufw/before6.rules
ufw reload || true
systemctl restart fail2ban || true
echo 'Конфигурация SSH восстановлена. Добавленные разрешения UFW оставлены.'
ROLLBACK
} > /root/rollback-ssh.sh
chmod 700 /root/rollback-ssh.sh
on_error() {
  rc=$?
  trap - ERR
  echo 'Ошибка: восстанавливаю конфигурацию SSH.' >&2
  /root/rollback-ssh.sh || echo 'Откат не завершён: используйте консоль провайдера.' >&2
  exit "$rc"
}
trap on_error ERR
python3 /root/vps-port22-rules.py remove /etc/ufw/before.rules
if [[ -f /etc/ufw/before6.rules ]]; then
  python3 /root/vps-port22-rules.py remove /etc/ufw/before6.rules
fi
ufw reload
install -d -m 755 /etc/ssh/sshd_config.d
# Явный Include в начале обеспечивает приоритет настроек перед файлами облачного образа.
if ! head -n 1 /etc/ssh/sshd_config | grep -Fxq 'Include /etc/ssh/sshd_config.d/00-vps.conf'; then
  sed -i '1i Include /etc/ssh/sshd_config.d/00-vps.conf' /etc/ssh/sshd_config
fi
{
  printf 'Port %s\nPort 22\n' "$SSH_PORT"
  if [[ "$CURRENT_PORT" =~ ^[0-9]+$ && "$CURRENT_PORT" != 22 && "$CURRENT_PORT" != "$SSH_PORT" ]]; then
    printf 'Port %s\n' "$CURRENT_PORT"
  fi
  # Парольные методы пока сохраняются: режим только ключ проверяется на втором шаге.
  echo 'PubkeyAuthentication yes'
  echo 'PermitRootLogin yes'
  echo 'MaxAuthTries 6'
  echo 'X11Forwarding no'
  echo 'UseDNS no'
} > /etc/ssh/sshd_config.d/00-vps.conf
/usr/sbin/sshd -t

# Сначала разрешаем доступ. Не сбрасываем существующие правила.
ufw delete deny log 22/tcp 2>/dev/null || true
ufw allow 22/tcp comment 'SSH fallback'
ufw limit "$SSH_PORT/tcp" comment 'SSH custom'
if [[ "$CURRENT_PORT" =~ ^[0-9]+$ && "$CURRENT_PORT" != 22 && "$CURRENT_PORT" != "$SSH_PORT" ]]; then
  ufw allow "$CURRENT_PORT/tcp" comment 'SSH existing session'
fi
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
systemctl disable --now ssh.socket 2>/dev/null || true
systemctl mask ssh.socket 2>/dev/null || true
systemctl daemon-reload
systemctl enable ssh.service
systemctl restart ssh.service
ss -H -lntp "sport = :$SSH_PORT" | grep -q sshd
ss -H -lntp 'sport = :22' | grep -q sshd
ufw default deny incoming
ufw default allow outgoing
ufw --force enable
IGN='127.0.0.1/8 ::1'
[[ -z "$WL_IP" ]] || IGN="$IGN $WL_IP"
# Только отдельный управляемый файл; пользовательский jail.local не перезаписываем.
install -d -m 755 /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/99-vps-ssh.local << EOF
[sshd]
enabled = true
port = 22,$SSH_PORT${CURRENT_PORT:+,$CURRENT_PORT}
backend = systemd
bantime = 3600
findtime = 600
maxretry = 5
ignoreip = %(known/ignoreip)s $IGN

# Переопределяем старый jail, пока порт 22 используется как запасной SSH.
[port22-trap]
enabled = false
filter = vps-port22
backend = systemd
journalmatch = _TRANSPORT=kernel
logpath =
maxretry = 3
findtime = 60
bantime = -1
bantime.increment = false
ignoreip = %(known/ignoreip)s $IGN
usedns = no
action = vps-port22-permanent
EOF
fail2ban-client -t
systemctl enable --now fail2ban
systemctl restart fail2ban
trap - ERR

cat > /root/finalize-ssh.sh << 'FINALIZE'
#!/bin/bash
set -Eeuo pipefail
umask 077
[[ $EUID == 0 ]] || exit 1
exec 9>/run/vps-ssh-setup.lock
flock -n 9 || { echo 'Другой экземпляр уже работает'; exit 1; }
mapfile -t CONFIG < /root/.vps-config
SSH_PORT="${CONFIG[0]}"
KEY_ONLY="${CONFIG[1]}"
[[ "$SSH_PORT" != 22 ]] || exit 1
CURRENT_PORT="$(awk '{print $4}' <<< "${SSH_CONNECTION:-}")"
[[ "$CURRENT_PORT" == "$SSH_PORT" ]] || {
  echo "Откройте НОВОЕ SSH-подключение на порту $SSH_PORT и запустите эту команду в нём." >&2; exit 1;
}
if [[ "$KEY_ONLY" =~ ^[Yy]$ ]]; then
  echo 'Убедитесь, что эта новая сессия открыта вашим ключом, с PreferredAuthentications=publickey.'
fi
read -r -p 'Подтвердите проверку входа и закрытие порта 22: введите ПРОВЕРЕНО: ' ANSWER < /dev/tty
[[ "$ANSWER" == ПРОВЕРЕНО ]] || exit 1
CONF=/etc/ssh/sshd_config.d/00-vps.conf
BACKUP="$(mktemp -d /root/ssh-finalize-backup.XXXXXXXX)"
cp -a "$CONF" "$BACKUP/config"
cp -a /etc/ufw/before.rules "$BACKUP/before.rules"
[[ ! -f /etc/ufw/before6.rules ]] || cp -a /etc/ufw/before6.rules "$BACKUP/before6.rules"
cp -a /etc/fail2ban/jail.d/99-vps-ssh.local "$BACKUP/jail"
restore() {
  rc=$?
  trap - ERR
  cp -a "$BACKUP/config" "$CONF"
  cp -a "$BACKUP/jail" /etc/fail2ban/jail.d/99-vps-ssh.local
  ufw delete deny log 22/tcp 2>/dev/null || true
  ufw allow 22/tcp || true
  cp -a "$BACKUP/before.rules" /etc/ufw/before.rules
  [[ ! -f "$BACKUP/before6.rules" ]] || cp -a "$BACKUP/before6.rules" /etc/ufw/before6.rules
  ufw reload || true
  systemctl restart ssh.service || true
  systemctl restart fail2ban || true
  exit "$rc"
}
trap restore ERR
if [[ "$KEY_ONLY" =~ ^[Yy]$ ]]; then
  AUTH='no'; ROOT_AUTH='prohibit-password'
else
  AUTH='yes'; ROOT_AUTH='yes'
fi
cat > "$CONF" << EOF
Port $SSH_PORT
PubkeyAuthentication yes
PasswordAuthentication $AUTH
KbdInteractiveAuthentication $AUTH
PermitRootLogin $ROOT_AUTH
MaxAuthTries 3
X11Forwarding no
UseDNS no
EOF
/usr/sbin/sshd -t
# Конфликтующие Port в других файлах могут оставлять 22 открытым: останавливаемся.
if /usr/sbin/sshd -T | awk '$1 == "port" && $2 == 22 { found=1 } END { exit !found }'; then
  echo 'Port 22 задан в другом SSH-конфиге. Устраните конфликт вручную.' >&2
  false
fi
systemctl restart ssh.service
ss -H -lntp "sport = :$SSH_PORT" | grep -q sshd
sed -i "s/^port =.*/port = $SSH_PORT/" /etc/fail2ban/jail.d/99-vps-ssh.local
# Jail ловушки включается только после подтверждения новой SSH-сессии.
sed -i '/^\[port22-trap\]/,$ s/^enabled = false$/enabled = true/' /etc/fail2ban/jail.d/99-vps-ssh.local
fail2ban-client -t
systemctl restart fail2ban
# Первая запрещающая запись перекрывает старые разрешения, в том числе IPv6.
# Ловушка логирует TCP SYN до DROP. Сервис SSH на 22 не запускается.
if [[ "$KEY_ONLY" =~ ^[Yy]$ ]]; then
  effective="$(/usr/sbin/sshd -T -C "user=root,host=localhost,addr=${SSH_CONNECTION%% *}")"
  grep -Fxq 'passwordauthentication no' <<< "$effective"
  grep -Fxq 'kbdinteractiveauthentication no' <<< "$effective"
  grep -Fxq 'pubkeyauthentication yes' <<< "$effective"
fi
python3 /root/vps-port22-rules.py add /etc/ufw/before.rules
if [[ -f /etc/ufw/before6.rules ]]; then
  python3 /root/vps-port22-rules.py add /etc/ufw/before6.rules
fi
iptables-restore --test < /etc/ufw/before.rules
if grep -qi '^IPV6=yes' /etc/default/ufw && [[ -e /proc/net/if_inet6 ]]; then
  ip6tables-restore --test < /etc/ufw/before6.rules
fi
ufw reload
fail2ban-client status port22-trap
echo 'SSH настроен. Ловушка на 22 активна: 3 TCP SYN за 60 секунд — постоянный бан IP.'
echo 'Постоянные баны записываются в UFW и действуют на все входящие порты, обслуживаемые UFW.'
echo 'Список правил: ufw status numbered. Снять бан: bash /root/unban-port22.sh IP.'
echo 'Откат настройки SSH и ловушки: /root/rollback-ssh.sh. Постоянные баны сохраняются.'
FINALIZE
chmod 700 /root/finalize-ssh.sh
# Совместимое имя команды прежней версии; постоянный бан после трёх SYN.
cat > /root/enable-honeypot.sh << 'COMPAT'
#!/bin/bash
exec /root/finalize-ssh.sh "$@"
COMPAT
chmod 700 /root/enable-honeypot.sh

echo "SSH слушает $SSH_PORT и 22. Прежние ключи и правила UFW сохранены."
echo "В новой сессии на порту $SSH_PORT проверьте вход ключом и выполните /root/finalize-ssh.sh"
echo 'Откат конфигурации SSH: /root/rollback-ssh.sh'
SSHSETUP
chmod 700 /root/setup-ssh.sh

echo -e "\n${G}Базовая настройка завершена.${NC}"
echo 'Теперь выполните: bash /root/setup-ssh.sh'
echo 'Сохраните эту сессию и проверьте новое подключение перед окончательной настройкой.'
echo 'Перезагрузка нужна для нового ядра, если вы выбрали XanMod. Автоматической перезагрузки нет.'

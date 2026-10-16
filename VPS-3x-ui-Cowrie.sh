#!/usr/bin/env bash
# VPS Foundation for 3x-ui/Xray: packages, TCP profiles, XanMod LTS/MAIN, SSH, Cowrie.
set -Eeuo pipefail
umask 077
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
SELF=/root/vps-foundation.sh
STATE=/var/lib/vps-foundation
CONFIG=$STATE/config.sh
ACTIVE=$STATE/active
MANAGED=/etc/ssh/vps-foundation.conf
JAIL=/etc/fail2ban/jail.d/99-vps-foundation.local
TIMER=vps-foundation-rollback.timer
SERVICE=vps-foundation-rollback.service
ACTIVE_TX=''; SWAP_TMP=''; TTY_FD=''; ASSUME_START=0
say() { printf '%s\n' "$*"; }
die() {
  say "ОШИБКА: $*" >&2
  if [[ -n "$SWAP_TMP" && -f "$SWAP_TMP" ]]; then rm -f -- "$SWAP_TMP"; fi
  if [[ -n "$ACTIVE_TX" && -f "$ACTIVE_TX/snapshot.sh" ]]; then
    trap - ERR HUP INT TERM
    rollback_impl || say 'Откат неполный: нужна консоль VPS.' >&2
  fi
  exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || die "Нет команды $1."; }
open_tty() {
  if [[ -z "$TTY_FD" ]]; then
    if ! { exec {TTY_FD}<>/dev/tty; } 2>/dev/null; then die 'Нужен доступный /dev/tty.'; fi
  fi
}
ask() {
  local _pv="$1" _pm="$2" _pd="${3-}" _answer=''
  open_tty
  printf '%s' "$_pm${_pd:+ [$_pd]}: " >&"$TTY_FD"
  IFS= read -r -t 90 _answer <&"$TTY_FD" || die 'Ввод прерван или истекли 90 секунд.'
  _answer="${_answer%$'\r'}"
  printf -v "$_pv" '%s' "${_answer:-$_pd}"
}
yesno() {
  local _v="$1" _m="$2" _d="${3:-n}" _yn=''
  while true; do
    ask _yn "$_m (y/n)" "$_d"
    case "$_yn" in y|Y) printf -v "$_v" y; return ;; n|N) printf -v "$_v" n; return ;; *) say 'Введите y или n.' ;; esac
  done
}
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_ip() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    print(ipaddress.ip_address(sys.argv[1]))
except ValueError:
    sys.exit(1)
PY
}
connection() {
  [[ -n "${SSH_CONNECTION:-}" ]] || die 'Нет SSH_CONNECTION. Нужна непосредственная root SSH-сессия.'
  read -r REMOTE_IP REMOTE_PORT LOCAL_IP LOCAL_PORT <<< "$SSH_CONNECTION"
  valid_ip "$REMOTE_IP" >/dev/null || die 'Некорректный адрес клиента.'
  valid_ip "$LOCAL_IP" >/dev/null || die 'Некорректный адрес сервера.'
  valid_port "$LOCAL_PORT" || die 'Некорректный порт сессии.'
}
load_config() {
  [[ -f "$CONFIG" && ! -L "$CONFIG" ]] || die 'Сначала запустите основной скрипт.'
  [[ "$(stat -c '%u:%a' "$CONFIG")" == 0:600 ]] || die 'Нужны root:600 для config.sh.'
  source "$CONFIG"
  valid_port "$SSH_PORT" || die 'Некорректный SSH_PORT.'
  [[ "$KEY_ONLY" == y || "$KEY_ONLY" == n ]] || die 'Некорректный KEY_ONLY.'
  [[ "$HONEYPOT" == y || "$HONEYPOT" == n ]] || die 'Некорректный HONEYPOT.'
  [[ "$LOG_PORT22" == y || "$LOG_PORT22" == n ]] || die 'Некорректный LOG_PORT22.'
}
read_active() {
  [[ -f "$ACTIVE" && ! -L "$ACTIVE" ]] || return 1
  IFS= read -r ACTIVE_TX < "$ACTIVE"
  [[ "$ACTIVE_TX" == "$STATE"/transactions/tx.* && -d "$ACTIVE_TX" ]] || die 'Поврежден путь транзакции.'
}
unit_active() { systemctl is-active "$1" 2>/dev/null || true; }
unit_enabled() { systemctl is-enabled "$1" 2>/dev/null || true; }
restore_enabled() {
  local u="$1" s="$2"
  case "$s" in
    enabled) systemctl unmask "$u" >/dev/null 2>&1; systemctl enable "$u" >/dev/null ;;
    enabled-runtime) systemctl unmask "$u" >/dev/null 2>&1; systemctl enable --runtime "$u" >/dev/null ;;
    disabled) systemctl unmask "$u" >/dev/null 2>&1; systemctl disable "$u" >/dev/null ;;
    masked|masked-runtime)
      systemctl disable "$u" >/dev/null 2>&1 || true
      if [[ "$s" == masked-runtime ]]; then systemctl mask --runtime "$u" >/dev/null; else systemctl mask "$u" >/dev/null; fi ;;
    *) return 0 ;;
  esac
}
cancel_timer() { systemctl disable --now "$TIMER" >/dev/null 2>&1; }
rollback_impl() {
  local tx="$ACTIVE_TX" failed=0
  [[ -n "$tx" && -f "$tx/snapshot.sh" ]] || return 1
  source "$tx/snapshot.sh"
  say "Откат SSH/UFW/Fail2ban: $tx"
  timeout 45s systemctl stop vps-cowrie.service >/dev/null 2>&1 || true
  timeout 45s systemctl stop fail2ban.service || true
  rm -f "$MANAGED" "$JAIL"
  cp -a "$tx/ssh/." /etc/ssh/ || failed=1
  cp -a "$tx/ufw/." /etc/ufw/ || failed=1
  cp -a "$tx/default-ufw" /etc/default/ufw || failed=1
  cp -a "$tx/fail2ban/." /etc/fail2ban/ || failed=1
  if [[ "$HAD_KEYS" == yes ]]; then cp -a "$tx/authorized_keys" /root/.ssh/authorized_keys || failed=1
  else rm -f /root/.ssh/authorized_keys || failed=1; fi
  if [[ "$UFW_WAS_ACTIVE" == yes ]]; then
    timeout 45s ufw --force enable || failed=1
    timeout 45s ufw reload || failed=1
  else timeout 45s ufw --force disable || failed=1; fi
  /usr/sbin/sshd -t || failed=1
  systemctl unmask ssh.socket >/dev/null 2>&1 || true
  timeout 45s systemctl stop ssh.socket || true
  systemctl daemon-reload || failed=1
  if [[ "$SOCKET_WAS_ACTIVE" == active ]]; then
    timeout 45s systemctl stop ssh.service || failed=1
    timeout 45s systemctl start ssh.socket || failed=1
    if [[ "$SSH_WAS_ACTIVE" == active ]]; then timeout 45s systemctl start ssh.service || failed=1; fi
  elif [[ "$SSH_WAS_ACTIVE" == active ]]; then timeout 45s systemctl restart ssh.service || failed=1
  else timeout 45s systemctl stop ssh.service || failed=1; fi
  restore_enabled ssh.socket "$SOCKET_WAS_ENABLED" || failed=1
  restore_enabled ssh.service "$SSH_WAS_ENABLED" || failed=1
  restore_enabled fail2ban.service "$F2B_WAS_ENABLED" || failed=1
  if [[ "$F2B_WAS_ACTIVE" == active ]]; then timeout 45s systemctl restart fail2ban.service || failed=1
  else timeout 45s systemctl stop fail2ban.service || failed=1; fi
  if [[ -n "$COWRIE_WAS_ENABLED" && "$COWRIE_WAS_ENABLED" != not-found ]]; then
    restore_enabled vps-cowrie.service "$COWRIE_WAS_ENABLED" || failed=1
    if [[ "$COWRIE_WAS_ACTIVE" == active ]]; then timeout 45s systemctl start vps-cowrie.service || failed=1; fi
  fi
  if ((failed)); then say "Откат неполный. Нужна консоль; снимок $tx" >&2; return 1; fi
  cancel_timer || return 1
  rm -f "$ACTIVE"
  ACTIVE_TX=''
  say 'Исходные SSH/UFW/Fail2ban восстановлены; Cowrie возвращён в прежнее состояние.'
  say 'Ядро/пакеты/swap/часовой пояс не отменены. Для TCP есть отдельный rollback-tcp.sh.'
}
on_error() {
  local rc=$? line="$1"
  trap - ERR HUP INT TERM
  say "Ошибка на строке $line; код $rc." >&2
  if [[ -n "$SWAP_TMP" && -f "$SWAP_TMP" ]]; then rm -f -- "$SWAP_TMP"; fi
  if [[ -n "$ACTIVE_TX" && -f "$ACTIVE_TX/snapshot.sh" ]]; then rollback_impl || say 'Нужна консоль провайдера.' >&2; fi
  exit "$rc"
}
trap 'on_error "$LINENO"' ERR
trap 'false' HUP INT TERM
arm_timer() {
  cat > "/etc/systemd/system/$SERVICE" <<EOF
[Unit]
Description=Rollback unconfirmed VPS SSH configuration
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/bin/bash $SELF --rollback
TimeoutStartSec=600
EOF
  cat > "/etc/systemd/system/$TIMER" <<EOF
[Unit]
Description=Rollback unconfirmed VPS SSH configuration in 15 minutes
[Timer]
OnActiveSec=15min
AccuracySec=1s
Unit=$SERVICE
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable "$TIMER" >/dev/null
  systemctl restart "$TIMER"
  systemctl is-active --quiet "$TIMER"
}
snapshot() {
  local tx v
  tx="$(mktemp -d "$STATE/transactions/tx.XXXXXXXX")"
  cp -a /etc/ssh "$tx/ssh"
  cp -a /etc/ufw "$tx/ufw"
  cp -a /etc/default/ufw "$tx/default-ufw"
  cp -a /etc/fail2ban "$tx/fail2ban"
  HAD_KEYS=no
  if [[ -e /root/.ssh/authorized_keys || -L /root/.ssh/authorized_keys ]]; then
    [[ -f /root/.ssh/authorized_keys && ! -L /root/.ssh/authorized_keys && ! -L /root/.ssh ]] || die 'Нестандартный authorized_keys/.ssh.'
    cp -a /root/.ssh/authorized_keys "$tx/authorized_keys"
    HAD_KEYS=yes
  fi
  UFW_WAS_ACTIVE=no
  if ufw status | grep -Fxq 'Status: active'; then UFW_WAS_ACTIVE=yes; fi
  SOCKET_WAS_ACTIVE="$(unit_active ssh.socket)"; SOCKET_WAS_ENABLED="$(unit_enabled ssh.socket)"
  SSH_WAS_ACTIVE="$(unit_active ssh.service)"; SSH_WAS_ENABLED="$(unit_enabled ssh.service)"
  F2B_WAS_ACTIVE="$(unit_active fail2ban.service)"; F2B_WAS_ENABLED="$(unit_enabled fail2ban.service)"
  COWRIE_WAS_ACTIVE="$(unit_active vps-cowrie.service)"; COWRIE_WAS_ENABLED="$(unit_enabled vps-cowrie.service)"
  for v in HAD_KEYS UFW_WAS_ACTIVE SOCKET_WAS_ACTIVE SOCKET_WAS_ENABLED SSH_WAS_ACTIVE SSH_WAS_ENABLED F2B_WAS_ACTIVE F2B_WAS_ENABLED COWRIE_WAS_ACTIVE COWRIE_WAS_ENABLED; do
    printf '%s=%q\n' "$v" "${!v}"
  done > "$tx/snapshot.sh"
  printf '%s\n' initial > "$tx/stage"
  printf '%s\n' "$tx" > "$ACTIVE"
  ACTIVE_TX="$tx"
  arm_timer
}
write_sshd() {
  local stage="$1"
  {
    printf 'Port %s\n' "$SSH_PORT"
    if [[ "$stage" == initial ]]; then
      printf 'Port 22\n'
      if [[ -n "${LOCAL_PORT:-}" && "$LOCAL_PORT" != 22 && "$LOCAL_PORT" != "$SSH_PORT" ]]; then printf 'Port %s\n' "$LOCAL_PORT"; fi
    fi
    printf '%s\n' 'AddressFamily any' 'PubkeyAuthentication yes'
    if [[ "$KEY_ONLY" == y ]]; then
      printf '%s\n' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'PermitRootLogin prohibit-password' 'AuthenticationMethods publickey'
    else
      printf '%s\n' 'PasswordAuthentication yes' 'KbdInteractiveAuthentication no' 'PermitRootLogin yes' 'AuthenticationMethods any'
    fi
    printf '%s\n' 'MaxAuthTries 6' 'X11Forwarding no' 'UseDNS no'
  } > "$MANAGED"
  chmod 600 "$MANAGED"
}
validate_effective() {
  local effective
  effective="$(/usr/sbin/sshd -T -C "user=root,host=$REMOTE_IP,addr=$REMOTE_IP,laddr=$LOCAL_IP,lport=$SSH_PORT")"
  grep -Fxq 'pubkeyauthentication yes' <<< "$effective" || die 'PubkeyAuthentication переопределён.'
  if [[ "$KEY_ONLY" == y ]]; then
    grep -Fxq 'passwordauthentication no' <<< "$effective" || die 'Парольный вход не отключён.'
    grep -Fxq 'kbdinteractiveauthentication no' <<< "$effective" || die 'Keyboard-interactive не отключён.'
    grep -Fxq 'authenticationmethods publickey' <<< "$effective" || die 'AuthenticationMethods переопределён.'
    grep -Eq '^permitrootlogin (without-password|prohibit-password)$' <<< "$effective" || die 'PermitRootLogin переопределён.'
    python3 - "$effective" <<'PY'
import shlex, sys
settings = dict(line.split(None, 1) for line in sys.argv[1].splitlines() if ' ' in line)
paths = shlex.split(settings.get('authorizedkeysfile', ''))
paths = [p.replace('%h', '/root').replace('%u', 'root').replace('%U', '0') for p in paths]
if not any(p in ('.ssh/authorized_keys', '/root/.ssh/authorized_keys') for p in paths):
    raise SystemExit('sshd не читает /root/.ssh/authorized_keys; проверьте AuthorizedKeysFile.')
PY
  else
    grep -Fxq 'passwordauthentication yes' <<< "$effective" || die 'Парольный вход переопределён.'
    grep -Fxq 'permitrootlogin yes' <<< "$effective" || die 'Вход root переопределён.'
    grep -Fxq 'authenticationmethods any' <<< "$effective" || die 'AuthenticationMethods переопределён.'
  fi
}
listener_ok() {
  local sockets
  sockets="$(ss -H -lntp "sport = :$SSH_PORT")"
  [[ "$sockets" == *sshd* ]] || { say "Нет sshd на $SSH_PORT" >&2; return 1; }
}
write_jail() {
  install -d -m 755 /etc/fail2ban/jail.d
  cat > "$JAIL" <<EOF
[sshd]
enabled = true
backend = systemd
port = $1
bantime = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.0/8 ::1${WHITELIST_IP:+ $WHITELIST_IP}
usedns = no
EOF
  fail2ban-client -t
}
check_legacy() {
  local f
  if [[ -f /root/.vps-config || -f /etc/fail2ban/jail.d/99-vps-ssh.local || -f /etc/ssh/sshd_config.d/00-vps.conf ]]; then
    die 'Найдена старая исходная версия. Нужна отдельная миграция; старый откат не заменяю.'
  fi
  for f in /etc/ufw/before.rules /etc/ufw/before6.rules; do
    if [[ -f "$f" ]] && grep -Eq 'SSH_HONEYPOT_TRAP_START|VPS_PORT22_TRAP_START' "$f"; then die 'В UFW есть старая ловушка: нужна миграция.'; fi
  done
}
ssh_setup() {
  check_legacy; load_config
  [[ ! -f "$ACTIVE" ]] || die 'Настройка уже активна. Завершите её либо выполните --rollback.'
  local t sockets answer
  for t in python3 ufw fail2ban-client ss iptables-restore ip6tables-restore timeout; do need "$t"; done
  [[ -f /etc/ufw/before.rules && -f /etc/default/ufw ]] || die 'UFW установлен некорректно: нет /etc/ufw/before.rules.'
  /usr/sbin/sshd -t
  if [[ -e /proc/net/if_inet6 ]] && [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)" == 0 ]]; then
    grep -Eqi '^IPV6=yes' /etc/default/ufw || die 'IPv6 включён, а UFW настроен с IPV6=no. Исправьте /etc/default/ufw; IPv6 автоматически не отключаю.'
  fi
  if [[ "$HONEYPOT" == y ]]; then check_cowrie_prepared; fi
  if [[ -n "${SSH_CONNECTION:-}" ]]; then connection
  else REMOTE_IP=127.0.0.1; LOCAL_IP=127.0.0.1; LOCAL_PORT=''; fi
  sockets="$(ss -H -lntp "sport = :$SSH_PORT")"
  [[ -z "$sockets" || "$sockets" == *sshd* ]] || die "Порт $SSH_PORT занят."
  say 'UFW будет включён: incoming DENY, outgoing ALLOW. Разрешаются 80/tcp, 443/tcp, 443/udp и SSH.'
  say 'Порт панели и другие inbounds автоматически НЕ открываются.'
  if [[ "$ASSUME_START" != 1 ]]; then
    ask answer 'Для применения с 15-минутным откатом введите START' ''
    [[ "$answer" == START ]] || return 0
  fi
  snapshot
  if [[ -f /etc/systemd/system/vps-cowrie.service ]]; then
    timeout 45s systemctl stop vps-cowrie.service
    systemctl disable vps-cowrie.service >/dev/null
  fi
  if [[ "$KEY_ONLY" == y ]]; then
    [[ ! -L /root/.ssh ]] || die '/root/.ssh является символической ссылкой.'
    install -d -m 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    if ! grep -Fxq -- "$SSH_PUBLIC_KEY" /root/.ssh/authorized_keys; then printf '\n%s\n' "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys; fi
    chmod 600 /root/.ssh/authorized_keys
    chown root:root /root/.ssh /root/.ssh/authorized_keys
  fi
  port22_rules remove
  if [[ "$(head -n 1 /etc/ssh/sshd_config)" != 'Include /etc/ssh/vps-foundation.conf' ]]; then
    sed -i '1i Include /etc/ssh/vps-foundation.conf' /etc/ssh/sshd_config
  fi
  write_sshd initial
  /usr/sbin/sshd -t
  validate_effective
  ufw insert 1 allow 22/tcp comment 'vps-foundation fallback'
  ufw insert 1 limit "$SSH_PORT/tcp" comment 'vps-foundation SSH'
  if [[ -n "$LOCAL_PORT" && "$LOCAL_PORT" != 22 && "$LOCAL_PORT" != "$SSH_PORT" ]]; then ufw insert 1 allow "$LOCAL_PORT/tcp" comment 'vps-foundation previous SSH'; fi
  ufw allow 80/tcp; ufw allow 443/tcp; ufw allow 443/udp
  ufw default deny incoming; ufw default allow outgoing
  timeout 45s ufw --force enable
  timeout 45s systemctl stop ssh.socket || true
  systemctl disable ssh.socket >/dev/null 2>&1 || true
  systemctl mask ssh.socket >/dev/null 2>&1 || true
  systemctl daemon-reload
  systemctl enable ssh.service >/dev/null
  timeout 45s systemctl restart ssh.service
  listener_ok
  write_jail "22,$SSH_PORT${LOCAL_PORT:+,$LOCAL_PORT}"
  systemctl enable fail2ban.service >/dev/null
  timeout 45s systemctl restart fail2ban.service
  say ''
  say "SSH ПЕРЕНЕСЁН на порт $SSH_PORT (22 пока тоже работает). Автооткат через 15 минут."
  say "1) Откройте НОВОЕ окно терминала: ssh -p $SSH_PORT root@SERVER_IP"
  say '2) В нём выполните ОДНУ команду: bash /root/finalize-ssh.sh'
  say 'Эту исходную сессию не закрывайте.'
}
wait_confirm() {
  local answer=''
  printf 'Введите CONFIRM или ROLLBACK (ожидание до 10 минут): ' >&"$TTY_FD"
  while IFS= read -r -t 600 answer <&"$TTY_FD"; do
    case "${answer%$'\r'}" in
      CONFIRM) return 0 ;;
      ROLLBACK) return 1 ;;
      *) printf 'Введите CONFIRM или ROLLBACK: ' >&"$TTY_FD" ;;
    esac
  done
  return 1
}
finalize() {
  load_config; read_active || die 'Нет активной настройки (уже подтверждена либо выполнен откат).'
  open_tty
  connection
  [[ "$LOCAL_PORT" == "$SSH_PORT" ]] || die "Запустите в НОВОЙ сессии на порту $SSH_PORT."
  [[ "$(cat "$ACTIVE_TX/stage")" == initial ]] || die 'Финализация уже выполнялась.'
  local ports conns
  systemctl restart "$TIMER"
  write_sshd final
  /usr/sbin/sshd -t
  validate_effective
  ports="$(/usr/sbin/sshd -T | awk '$1 == "port" {print $2}' | sort -nu)"
  [[ "$ports" == "$SSH_PORT" ]] || die "В других конфигах заданы дополнительные Port: $ports. Нужна ручная проверка."
  write_jail "$SSH_PORT"
  port22_rules add
  timeout 45s ufw reload
  timeout 45s systemctl restart ssh.service
  listener_ok
  if [[ "$HONEYPOT" == y ]]; then
    ufw insert 1 allow 22/tcp comment 'vps-foundation Cowrie'
    timeout 45s ufw reload
    systemctl enable vps-cowrie.service >/dev/null
    timeout 45s systemctl start vps-cowrie.service
    cowrie_listener_ok
  fi
  timeout 45s systemctl restart fail2ban.service
  printf '%s\n' finalized > "$ACTIVE_TX/stage"
  systemctl restart "$TIMER"
  if [[ "$HONEYPOT" == y ]]; then say 'Настоящий SSH только на новом порту; на 22 работает Cowrie.'
  else say 'Настоящий SSH только на новом порту; 22 закрыт для новых подключений.'; fi
  say ''
  say "Откройте ЕЩЁ ОДНО новое окно и убедитесь, что вход на порт $SSH_PORT работает."
  say 'Затем вернитесь сюда и введите CONFIRM. ROLLBACK — вернуть прежнюю конфигурацию.'
  while true; do
    wait_confirm || die 'Подтверждение не получено; выполняю откат.'
    conns="$(ss -Htn state established "( sport = :$SSH_PORT )" | wc -l)"
    if ((conns >= 2)); then break; fi
    say 'Не вижу второго подключения на этом порту. Откройте новое окно и повторите.'
  done
  /usr/sbin/sshd -t; validate_effective; listener_ok; fail2ban-client -t
  if [[ "$HONEYPOT" == y ]]; then cowrie_listener_ok; fi
  cancel_timer
  printf '%s\n' "$ACTIVE_TX" > "$STATE/last-confirmed"
  rm -f "$ACTIVE"; ACTIVE_TX=''
  say 'ГОТОВО. Автооткат отменён; снимок сохранён.'
  if [[ "$HONEYPOT" == y ]]; then
    say 'Журналы Cowrie: /var/lib/vps-cowrie/var/log/cowrie/'
    say 'Не отключайте UFW при работающем Cowrie: он ограничивает его исходящие соединения.'
  fi
  say 'Если ставилось новое ядро — перезагрузитесь командой reboot.'
}
make_swap() {
  ((SWAP_SIZE_GB > 0)) || return 0
  local fs free bytes swaps
  if [[ -e /swapfile || -L /swapfile ]]; then
    [[ -f /swapfile && ! -L /swapfile ]] || die 'Небезопасный /swapfile.'
    [[ "$(blkid -p -s TYPE -o value /swapfile || true)" == swap ]] || die '/swapfile не является swap; не перезаписываю.'
    say "Существующий swap: $(stat -c %s /swapfile) байт; размер не меняется."
  else
    fs="$(findmnt -n -o FSTYPE -T /)"
    [[ "$fs" == ext4 || "$fs" == xfs ]] || die 'Автосоздание swap только на ext4/XFS; выберите 0.'
    free="$(df -B1 --output=avail / | tail -n 1 | tr -d '[:space:]')"
    bytes=$((SWAP_SIZE_GB * 1024 * 1024 * 1024))
    ((free > bytes + 1073741824)) || die 'Недостаточно диска для swap и запаса 1 GiB.'
    SWAP_TMP="$(mktemp /swapfile.vps-new.XXXXXXXX)"
    dd if=/dev/zero of="$SWAP_TMP" bs=1M count="$((SWAP_SIZE_GB * 1024))" status=progress
    chmod 600 "$SWAP_TMP"; mkswap "$SWAP_TMP"
    mv -n -- "$SWAP_TMP" /swapfile
    [[ ! -e "$SWAP_TMP" ]] || die '/swapfile появился параллельно. Не перезаписываю.'
    SWAP_TMP=''
  fi
  chmod 600 /swapfile
  swaps="$(swapon --show=NAME --noheadings --raw)"
  if ! grep -Fxq /swapfile <<< "$swaps"; then swapon /swapfile; fi
  if ! awk '$1 == "/swapfile" {f=1} END {exit !f}' /etc/fstab; then printf '%s\n' '/swapfile none swap sw 0 0' >> /etc/fstab; fi
}
port22_rules() {
  local mode="$1" file uid=0
  if [[ "$HONEYPOT" == y ]]; then uid="$(id -u vps-cowrie)"; fi
  for file in /etc/ufw/before.rules /etc/ufw/before6.rules; do
    [[ -f "$file" ]] || continue
    python3 - "$mode" "$file" "$LOG_PORT22" "$HONEYPOT" "$uid" <<'PY'
from pathlib import Path
import os, re, sys, tempfile
mode, filename, logging, honeypot, uid = sys.argv[1:]
if not uid.isdecimal():
    raise SystemExit('Invalid UID')
p = Path(filename)
s = p.read_text()
for tag in ('VPS_FOUNDATION_PORT22', 'VPS_COWRIE_EGRESS'):
    start = '# ===== ' + tag + '_START ====='
    end = '# ===== ' + tag + '_END ====='
    if s.count(start) != s.count(end) or s.count(start) > 1:
        raise SystemExit('Повреждены маркеры: ' + filename)
    if start in s:
        a, b = s.index(start), s.index(end)
        if b < a:
            raise SystemExit('Неверный порядок маркеров')
        s = s[:a] + s[b + len(end):].lstrip('\n')
if mode == 'add':
    a = s.index('*filter\n')
    b = s.index('\nCOMMIT', a)
    if honeypot == 'y':
        m = re.search(r'^-A (ufw6?-before-output)\b', s[a:b], re.M)
        if not m:
            raise SystemExit('Нет выходящей цепочки UFW: ' + filename)
        chain = m.group(1)
        rules = ['# ===== VPS_COWRIE_EGRESS_START =====',
                 f'-A {chain} -m owner --uid-owner {uid} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT',
                 f'-A {chain} -m owner --uid-owner {uid} -j REJECT',
                 '# ===== VPS_COWRIE_EGRESS_END =====']
    else:
        m = re.search(r'^-A (ufw6?-before-input)\b', s[a:b], re.M)
        if not m:
            raise SystemExit('Нет входящей цепочки UFW: ' + filename)
        chain = m.group(1)
        rules = ['# ===== VPS_FOUNDATION_PORT22_START =====']
        if logging == 'y':
            rules.append(f'-A {chain} -p tcp --dport 22 --syn -m conntrack --ctstate NEW '
                         '-m limit --limit 6/min --limit-burst 10 -j LOG --log-prefix "VPS_PORT22: "')
        rules += [f'-A {chain} -p tcp --dport 22 -m conntrack --ctstate NEW -j DROP',
                  '# ===== VPS_FOUNDATION_PORT22_END =====']
    pos = a + m.start()
    s = s[:pos] + '\n'.join(rules) + '\n' + s[pos:]
elif mode != 'remove':
    raise SystemExit('Неизвестный режим')
st = p.stat()
fd, tmp = tempfile.mkstemp(dir=p.parent, prefix='.vps-foundation-')
try:
    with os.fdopen(fd, 'w') as f:
        f.write(s)
    os.chmod(tmp, st.st_mode & 0o777)
    os.chown(tmp, st.st_uid, st.st_gid)
    os.replace(tmp, p)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
  done
  iptables-restore --test < /etc/ufw/before.rules
  if grep -Eqi '^IPV6=yes' /etc/default/ufw && [[ -e /proc/net/if_inet6 ]]; then
    ip6tables-restore --test < /etc/ufw/before6.rules
  fi
}
prepare_cowrie() {
  local home=/var/lib/vps-cowrie venv=/opt/vps-cowrie
  if [[ -e "$home" && ! -f "$home/.vps-managed" ]]; then die "$home существует и не принадлежит этой установке."; fi
  if id vps-cowrie >/dev/null 2>&1; then
    [[ "$(getent passwd vps-cowrie | cut -d: -f6)" == "$home" ]] || die 'Конфликт пользователя vps-cowrie.'
  else
    useradd --system --user-group --home-dir "$home" --shell /usr/sbin/nologin vps-cowrie
  fi
  if [[ -e "$venv" && ! -f "$venv/.vps-managed" ]]; then die 'Нестандартный /opt/vps-cowrie.'; fi
  if [[ ! -f "$venv/.vps-managed" ]]; then
    install -d -m 755 "$venv"
    python3 -m venv "$venv"
    "$venv/bin/python" -m pip install --upgrade pip
    "$venv/bin/python" -m pip install 'cowrie>=3.0,<4'
    touch "$venv/.vps-managed"
    chown -R root:root "$venv"
    chmod -R a+rX "$venv"
  fi
  install -d -m 750 -o vps-cowrie -g vps-cowrie "$home"
  touch "$home/.vps-managed"
  if [[ ! -f "$home/etc/cowrie.cfg" ]]; then
    runuser -u vps-cowrie -- /bin/bash -c 'cd "$1"; exec /opt/vps-cowrie/bin/cowrie init' _ "$home"
  fi
  [[ -d "$home/etc" ]] || die 'cowrie init не создал каталог etc.'
  [[ ! -f "$home/etc/cowrie.cfg" ]] || cp -a "$home/etc/cowrie.cfg" "$home/etc/cowrie.cfg.before-vps"
  cat > "$home/etc/cowrie.cfg" <<EOF
[honeypot]
hostname = srv-cache
auth_class = UserDB
backend = shell
download_limit_size = 10485760
[ssh]
enabled = true
listen_endpoints = tcp:22:interface=0.0.0.0
forwarding = false
sftp_enabled = false
[telnet]
enabled = false
[output_jsonlog]
enabled = true
EOF
  printf '%s\n' 'root:x:*' 'admin:x:*' 'test:x:*' > "$home/etc/userdb.txt"
  chown -R root:vps-cowrie "$home/etc"
  chmod -R u=rwX,g=rX,o= "$home/etc"
  chown root:vps-cowrie "$home" "$home/.vps-managed"
  chmod 750 "$home"
  install -d -m 750 -o vps-cowrie -g vps-cowrie "$home/var"
  chown -R vps-cowrie:vps-cowrie "$home/var"
  cat > /etc/systemd/system/vps-cowrie.service <<'UNIT'
[Unit]
Description=Cowrie SSH honeypot (not the administration SSH server)
After=network.target ufw.service
Requires=ufw.service
[Service]
Type=simple
User=vps-cowrie
Group=vps-cowrie
WorkingDirectory=/var/lib/vps-cowrie
Environment=HOME=/var/lib/vps-cowrie
Environment=PATH=/opt/vps-cowrie/bin:/usr/bin:/bin
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart=/opt/vps-cowrie/bin/cowrie start -n
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
UMask=0077
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_UNIX
ReadWritePaths=/var/lib/vps-cowrie/var
InaccessiblePaths=-/etc/ssh -/etc/x-ui -/etc/3x-ui -/etc/xray -/usr/local/x-ui -/var/lib/x-ui -/var/lib/3x-ui
MemoryMax=256M
TasksMax=64
CPUQuota=25%
LimitNOFILE=4096
LimitFSIZE=64M
[Install]
WantedBy=multi-user.target
UNIT
  chmod 644 /etc/systemd/system/vps-cowrie.service
  systemctl daemon-reload
  "$venv/bin/python" -m pip freeze > "$home/installed-packages.txt"
  say 'Cowrie подготовлен, но ещё НЕ запущен: стартует после переноса настоящего SSH.'
}
check_cowrie_prepared() {
  [[ -x /opt/vps-cowrie/bin/cowrie && -f /var/lib/vps-cowrie/.vps-managed && -f /etc/systemd/system/vps-cowrie.service ]] || die 'Cowrie не подготовлен.'
  id vps-cowrie >/dev/null
}
cowrie_listener_ok() {
  local i
  for i in {1..10}; do
    if systemctl is-active --quiet vps-cowrie.service; then
      if python3 - <<'PY'
import socket, sys, pwd
uid = pwd.getpwnam('vps-cowrie').pw_uid
with open('/proc/net/tcp') as f:
    rows = [line.split() for line in f.readlines()[1:]]
if not any(row[1].split(':')[-1] == '0016' and row[3] == '0A' and int(row[7]) == uid for row in rows):
    sys.exit(1)
try:
    with socket.create_connection(('127.0.0.1', 22), timeout=2) as s:
        s.settimeout(2)
        banner = s.recv(256)
    if not banner.startswith(b'SSH-2.0-'):
        sys.exit(1)
except OSError:
    sys.exit(1)
PY
      then return 0; fi
    fi
    sleep 1
  done
  say 'Cowrie не отвечает SSH-баннером на 22.' >&2
  return 1
}
configure_network() {
  local backup="$1" target=/etc/sysctl.d/99-vps-foundation.conf
  local requested="$backup/network.requested" key value mem_kb maxbuf backlog fin
  [[ "$TCP_PROFILE" != off || "$BBR" == y || "$FORWARD" == y ]] || return 0
  : > "$requested"
  if [[ "$TCP_PROFILE" != off ]]; then
    mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
    maxbuf=16777216; backlog=8192; fin=30
    if ((mem_kb >= 2000000)); then maxbuf=33554432; fi
    if [[ "$TCP_PROFILE" == throughput ]]; then
      backlog=16384; fin=15
      if ((mem_kb >= 4000000)); then maxbuf=67108864; else maxbuf=33554432; fi
    fi
    cat >> "$requested" <<EOF
net.core.default_qdisc=fq
net.core.somaxconn=65535
net.core.netdev_max_backlog=$backlog
net.ipv4.tcp_max_syn_backlog=$backlog
net.core.rmem_max=$maxbuf
net.core.wmem_max=$maxbuf
net.ipv4.tcp_rmem=4096 131072 $maxbuf
net.ipv4.tcp_wmem=4096 65536 $maxbuf
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_fin_timeout=$fin
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=2
EOF
  fi
  if [[ "$BBR" == y ]]; then
    modprobe tcp_bbr 2>/dev/null || true
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
      printf '%s\n' 'net.core.default_qdisc=fq' 'net.ipv4.tcp_congestion_control=bbr' >> "$requested"
    else say 'BBR недоступен на запущенном ядре. После перезагрузки включите отдельно.'; fi
  fi
  if [[ "$FORWARD" == y ]]; then printf '%s\n' 'net.ipv4.ip_forward=1' >> "$requested"; fi
  python3 - "$target" "$requested" <<'PY'
from pathlib import Path
import sys
old, requested = map(Path, sys.argv[1:])
settings = {}
for p in (old, requested):
    if not p.exists():
        continue
    for line in p.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith(('#', ';')) and '=' in line:
            key, value = line.split('=', 1)
            settings[key.strip()] = value.strip()
requested.write_text(''.join(f'{key}={value}\n' for key, value in settings.items()))
PY
  : > "$backup/runtime.conf"
  : > "$backup/network.new"
  while IFS='=' read -r key value; do
    [[ -n "$key" ]] || continue
    if sysctl -n "$key" >/dev/null 2>&1; then
      printf '%s=%s\n' "$key" "$(sysctl -n "$key")" >> "$backup/runtime.conf"
      printf '%s=%s\n' "$key" "$value" >> "$backup/network.new"
    else say "Ядро не поддерживает $key; пропускаю."; fi
  done < "$requested"
  [[ -s "$backup/network.new" ]] || { say 'Нет доступных сетевых параметров; файл не меняется.'; return 0; }
  {
    printf '#!/bin/bash\nset -Eeuo pipefail\n[[ $EUID == 0 ]] || exit 1\n'
    printf 'BACKUP=%q\nTARGET=%q\n' "$backup" "$target"
    cat <<'RESTORENET'
if [[ -f "$BACKUP/sysctl.conf" ]]; then
  cp -a "$BACKUP/sysctl.conf" "$TARGET"
else
  rm -f "$TARGET"
fi
sysctl -p "$BACKUP/runtime.conf"
echo 'Предыдущие параметры TCP/sysctl восстановлены. Другие sysctl-файлы не менялись.'
RESTORENET
  } > /root/rollback-tcp.sh
  chmod 700 /root/rollback-tcp.sh
  install -m 644 "$backup/network.new" "$target"
  if ! sysctl -p "$target"; then
    bash /root/rollback-tcp.sh || true
    die 'Не удалось применить сетевые настройки.'
  fi
  say "TCP-профиль: $TCP_PROFILE. Откат сети: bash /root/rollback-tcp.sh"
}
install_xanmod() {
  [[ "$(dpkg --print-architecture)" == amd64 ]] || die 'XanMod требует amd64.'
  local flags flag candidate key package
  flags="$(grep -m1 -E '^flags[[:space:]]*:' /proc/cpuinfo || true)"
  for flag in cx16 lahf_lm popcnt pni ssse3 sse4_1 sse4_2; do
    grep -qw "$flag" <<< "$flags" || die "Нет флага CPU $flag для x86-64-v2."
  done
  if [[ "$XANMOD_LEVEL" == 3 ]]; then
    for flag in avx avx2 bmi1 bmi2 f16c fma movbe xsave; do
      grep -qw "$flag" <<< "$flags" || die "Нет флага CPU $flag для x86-64-v3."
    done
    if ! grep -Eq '(^|[[:space:]])(lzcnt|abm)([[:space:]]|$)' <<< "$flags"; then die 'Нет lzcnt/abm для v3.'; fi
  fi
  case "$XANMOD" in
    lts) package="linux-xanmod-lts-x64v$XANMOD_LEVEL" ;;
    main) package="linux-xanmod-x64v$XANMOD_LEVEL" ;;
    *) die 'Некорректная ветка XanMod.' ;;
  esac
  install -d -m 755 /etc/apt/keyrings
  key="$(mktemp)"
  if ! wget -qO "$key" https://dl.xanmod.org/archive.key; then rm -f "$key"; die 'Не удалось получить ключ XanMod.'; fi
  gpg --batch --yes --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg "$key"
  rm -f "$key"
  chmod 644 /etc/apt/keyrings/xanmod-archive-keyring.gpg
  [[ "$CODENAME" =~ ^[a-z][a-z0-9-]*$ ]] || die 'Некорректный codename.'
  cat > /etc/apt/sources.list.d/xanmod.sources <<EOF
Types: deb
URIs: https://deb.xanmod.org
Suites: $CODENAME
Components: main
Signed-By: /etc/apt/keyrings/xanmod-archive-keyring.gpg
EOF
  chmod 644 /etc/apt/sources.list.d/xanmod.sources
  apt-get -o Acquire::Retries=3 update
  candidate="$(apt-cache policy "$package" | awk '/Candidate:/ {print $2}')"
  [[ -n "$candidate" && "$candidate" != '(none)' ]] || die "Нет кандидата $package для этого релиза."
  say "Выбрано: $package; кандидат APT: $candidate"
  apt-get -s install "$package" >/dev/null
  apt-get install -y "$package"
  say 'Ядро установлено. Штатное ядро не удаляется; перезагрузка только после подтверждения SSH.'
}
base_setup() {
  local backup
  backup="$(mktemp -d "$STATE/base-backup.XXXXXXXX")"
  cp -a /etc/fstab "$backup/fstab"
  [[ ! -f /etc/sysctl.d/99-vps-foundation.conf ]] || cp -a /etc/sysctl.d/99-vps-foundation.conf "$backup/sysctl.conf"
  say "Базовый backup: $backup"
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::Retries=3 update
  dpkg --configure -a
  if [[ "$UPGRADE" == y ]]; then
    apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
  fi
  apt-get install -y openssh-server openssh-client ufw fail2ban python3 python3-systemd util-linux iproute2 iptables procps kmod chrony tzdata ca-certificates gnupg wget curl
  if [[ "$HONEYPOT" == y ]]; then
    apt-get install -y python3-venv python3-dev libssl-dev libffi-dev build-essential
    prepare_cowrie
  fi
  timedatectl set-timezone "$TIMEZONE" || true
  systemctl enable --now chrony.service
  make_swap
  if [[ "$XANMOD" != none ]]; then install_xanmod; fi
  configure_network "$backup"
}
write_wrappers() {
  local f mode
  for f in setup-ssh finalize-ssh rollback-ssh; do
    case "$f" in setup-ssh) mode=--ssh-setup ;; finalize-ssh) mode=--finalize ;; rollback-ssh) mode=--rollback ;; esac
    printf '#!/bin/bash\nexec /bin/bash %q %q "$@"\n' "$SELF" "$mode" > "/root/$f.sh"
    chmod 700 "/root/$f.sh"
  done
}
main() {
  [[ ! -f "$ACTIVE" ]] || die 'Есть незавершённая SSH-настройка. Завершите её или выполните --rollback.'
  check_legacy
  local t input keyfile answer choice tmp v detected_ip=''
  for t in python3 ssh-keygen apt-get dpkg systemctl stat timeout; do need "$t"; done
  [[ -d /run/systemd/system && -f /etc/os-release ]] || die 'Нужны systemd и /etc/os-release.'
  source /etc/os-release
  [[ "${ID:-}" == debian || "${ID:-}" == ubuntu ]] || die 'Поддерживаются Debian/Ubuntu.'
  CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  [[ -f "${BASH_SOURCE[0]}" ]] || die 'Сохраните скрипт в файл (curl -o setup.sh ...); запуск через pipe не поддерживается.'
  say 'VPS Foundation / 3x-ui edition. Сделайте snapshot и проверьте консоль провайдера.'
  ask SSH_PORT 'SSH-порт (не 22/80/443)' 45123
  valid_port "$SSH_PORT" || die 'Некорректный порт.'
  SSH_PORT=$((10#$SSH_PORT))
  ((SSH_PORT != 22 && SSH_PORT != 80 && SSH_PORT != 443)) || die 'Порт зарезервирован.'
  yesno KEY_ONLY 'Настоящий root SSH только по ключу' y
  SSH_PUBLIC_KEY=''
  if [[ "$KEY_ONLY" == y ]]; then
    ask input 'Публичный ключ одной строкой или путь к файлу' ''
    if [[ -f "$input" ]]; then SSH_PUBLIC_KEY="$(cat -- "$input")"; else SSH_PUBLIC_KEY="$input"; fi
    [[ -n "$SSH_PUBLIC_KEY" && "$SSH_PUBLIC_KEY" != *$'\n'* && "$SSH_PUBLIC_KEY" != *$'\r'* ]] || die 'Нужен один публичный ключ.'
    case "$SSH_PUBLIC_KEY" in 'ssh-ed25519 '*|'ssh-rsa '*|'ecdsa-sha2-'*|'sk-ssh-ed25519@openssh.com '*|'sk-ecdsa-sha2-'*) ;; *) die 'Нужен публичный ключ без authorized_keys options.' ;; esac
    keyfile="$(mktemp)"; printf '%s\n' "$SSH_PUBLIC_KEY" > "$keyfile"
    if ! ssh-keygen -lf "$keyfile" >/dev/null; then rm -f "$keyfile"; die 'Некорректный ключ.'; fi
    rm -f "$keyfile"
  else
    say 'Парольный root SSH будет разрешён. Скрипт пароль не задаёт.'
    [[ "$(passwd -S root | awk '{print $2}')" == P ]] || die 'Нет активного пароля root; используйте ключ.'
  fi
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    detected_ip="${SSH_CONNECTION%% *}"
    if ! detected_ip="$(valid_ip "$detected_ip")"; then detected_ip=''; fi
  fi
  if [[ -n "$detected_ip" ]]; then
    say "Определён ваш текущий IP: $detected_ip"
    ask WHITELIST_IP 'Whitelist Fail2ban: ENTER — этот IP, "-" — без whitelist, либо другой IP' "$detected_ip"
  else
    ask WHITELIST_IP 'Whitelist Fail2ban: IP, либо ENTER — без whitelist' ''
  fi
  if [[ "$WHITELIST_IP" == - ]]; then WHITELIST_IP=''; fi
  if [[ -n "$WHITELIST_IP" ]]; then
    if ! WHITELIST_IP="$(valid_ip "$WHITELIST_IP")"; then die 'Некорректный whitelist IP.'; fi
  fi
  yesno HONEYPOT 'Полноценный Cowrie SSH honeypot на 22/IPv4' y
  LOG_PORT22=n
  if [[ "$HONEYPOT" == y ]]; then
    say 'Cowrie: отдельный UID, systemd sandbox, UFW-запрет новых исходящих. Это не отдельная VM.'
  else yesno LOG_PORT22 'Логировать SYN на закрытом 22 без банов' n; fi
  if systemctl is-active --quiet vps-cowrie.service; then die 'Cowrie уже работает: повторная установка на ходу не поддерживается.'; fi
  ask SWAP_SIZE_GB 'Новый swap, GiB (0 — не создавать)' 2
  [[ "$SWAP_SIZE_GB" =~ ^[0-9]{1,2}$ ]] && ((10#$SWAP_SIZE_GB <= 64)) || die 'Swap: целое 0..64.'
  SWAP_SIZE_GB=$((10#$SWAP_SIZE_GB))
  ask TIMEZONE 'Часовой пояс' Asia/Yekaterinburg
  [[ "$TIMEZONE" =~ ^[A-Za-z0-9_+/-]+$ && "$TIMEZONE" != /* && "$TIMEZONE" != *..* && -f "/usr/share/zoneinfo/$TIMEZONE" ]] || die 'Некорректный часовой пояс.'
  yesno UPGRADE 'Обновить установленные пакеты (apt upgrade)' y
  XANMOD=none; XANMOD_LEVEL=2
  say 'Ядро: 0) штатное; 1) XanMod LTS; 2) XanMod MAIN (текущая не-LTS ветка).'
  ask choice 'Ядро (0/1/2)' 0
  case "$choice" in 0) XANMOD=none ;; 1) XANMOD=lts ;; 2) XANMOD=main ;; *) die 'Выберите 0/1/2.' ;; esac
  if [[ "$XANMOD" != none ]]; then
    ask XANMOD_LEVEL 'Уровень CPU: 2 — x64v2; 3 — x64v3 (проверяется)' 2
    [[ "$XANMOD_LEVEL" == 2 || "$XANMOD_LEVEL" == 3 ]] || die 'Уровень CPU: 2 или 3.'
  fi
  say 'TCP: 0) не менять; 1) balanced; 2) throughput — больше буферы/очереди.'
  ask choice 'TCP-профиль (0/1/2)' 1
  case "$choice" in 0) TCP_PROFILE=off ;; 1) TCP_PROFILE=balanced ;; 2) TCP_PROFILE=throughput ;; *) die 'Выберите 0/1/2.' ;; esac
  yesno BBR 'Включить BBR, если доступен в работающем ядре' y
  yesno FORWARD 'Включить IPv4 forwarding (не настраивает NAT/UFW route)' n
  say "OS=$ID/$CODENAME SSH=$SSH_PORT key-only=$KEY_ONLY Cowrie=$HONEYPOT whitelist=${WHITELIST_IP:-нет}"
  say "TCP=$TCP_PROFILE BBR=$BBR swap=$SWAP_SIZE_GB GiB kernel=$XANMOD/x64v$XANMOD_LEVEL upgrade=$UPGRADE"
  say 'Порт панели 3x-ui и другие inbounds НЕ открываются автоматически; проверьте и firewall провайдера.'
  ask answer 'Применить всё и настроить SSH с 15-минутным откатом? Введите START' ''
  [[ "$answer" == START ]] || return 0
  install -d -m 700 "$STATE" "$STATE/transactions"
  if [[ "$(readlink -f -- "${BASH_SOURCE[0]}")" != "$SELF" ]]; then install -m 700 -- "${BASH_SOURCE[0]}" "$SELF"; else chmod 700 "$SELF"; fi
  tmp="$(mktemp "$STATE/.config.XXXXXXXX")"
  for v in SSH_PORT KEY_ONLY SSH_PUBLIC_KEY WHITELIST_IP LOG_PORT22 HONEYPOT; do printf '%s=%q\n' "$v" "${!v}"; done > "$tmp"
  chmod 600 "$tmp"; mv -f -- "$tmp" "$CONFIG"
  write_wrappers
  base_setup
  say 'Базовая настройка завершена. Продолжаю настройку SSH.'
  ASSUME_START=1
  ssh_setup
}
case "${1:-}" in --help|-h) say 'Использование: bash setup.sh'; exit 0 ;; esac
[[ $EUID == 0 ]] || die 'Запустите от root.'
need flock
exec 9>/run/vps-foundation.lock
flock -w 120 9 || die 'Другой экземпляр держит блокировку более 120 секунд.'
case "${1:-}" in
  '') main ;;
  --ssh-setup) ssh_setup ;;
  --finalize) finalize ;;
  --rollback) if read_active; then rollback_impl; else say 'Нет активного отката.'; fi ;;
  *) die 'Неизвестный аргумент; используйте --help.' ;;
esac

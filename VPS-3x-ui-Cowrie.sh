#!/usr/bin/env bash
# VPS Foundation 6.0: interactive VPS setup and maintenance for Debian/Ubuntu.
set -Eeuo pipefail
umask 077
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
APP_VERSION=6.0
COWRIE_VERSION=3.1.2
TX_OWNED=0
EXTRA_PORTS=''
CLEAN_DAYS=14
CLEAN_MIB=1024
MIN_FREE_MIB=512
HELPERS=/usr/local/libexec/vps-foundation
GUARD_TIMER=vps-cowrie-firewall-guard.timer
CLEAN_TIMER=vps-cowrie-maintenance.timer
SELF=/root/vps-foundation.sh
STATE=/var/lib/vps-foundation
CONFIG=$STATE/config.sh
ACTIVE=$STATE/active
MANAGED=/etc/ssh/vps-foundation.conf
JAIL=/etc/fail2ban/jail.d/99-vps-foundation.local
TIMER=vps-foundation-rollback.timer
BAN_FILTER=/etc/fail2ban/filter.d/vps-cowrie-auth.conf
BAN_JAIL=/etc/fail2ban/jail.d/99-vps-cowrie-bans.local
BAN_GLOBAL=/etc/fail2ban/fail2ban.d/99-vps-cowrie-retention.local
COWRIE_LOG=/var/lib/vps-cowrie/var/log/cowrie/cowrie.json
ACTIVE_TX=''; BAN_BACKUP=''; BAN_CHANGED=0; PHASE=''; SWAP_TMP=''; TTY_FD=''; ASSUME_START=0
say() { printf '%s\n' "$*"; }
abort() {
  local rc="$1" message="$2"
  trap - ERR HUP INT TERM
  say "$message" >&2
  if [[ -n "$SWAP_TMP" && -f "$SWAP_TMP" ]]; then rm -f -- "$SWAP_TMP"; fi
  if [[ "$PHASE" == cowrie ]]; then cowrie_diagnostics; fi
  if ((BAN_CHANGED)); then restore_bans || say "Откат банов неполный: $BAN_BACKUP" >&2; fi
  if [[ "$TX_OWNED" == 1 && -n "$ACTIVE_TX" && -f "$ACTIVE_TX/snapshot.sh" ]]; then restore_ssh || say 'Откат SSH неполный: нужна консоль VPS.' >&2; fi
  exit "$rc"
}
die() { abort 1 "ОШИБКА: $*"; }
on_error() { local rc=$?; abort "$rc" "Ошибка на строке $1, код $rc, этап ${PHASE:-общий}."; }
trap 'on_error "$LINENO"' ERR
trap 'false' HUP INT TERM
need() { command -v "$1" >/dev/null 2>&1 || die "Нет команды $1."; }
open_tty() { if [[ -z "$TTY_FD" ]]; then if ! { exec {TTY_FD}<>/dev/tty; } 2>/dev/null; then die 'Нужен доступный /dev/tty.'; fi; fi; }
ask() {
  local _pv="$1" _msg="$2" _def="${3-}" _ans=''
  open_tty; printf '%s' "$_msg${_def:+ [$_def]}: " >&"$TTY_FD"
  IFS= read -r -t 180 _ans <&"$TTY_FD" || die 'Ввод прерван/таймаут 180 секунд.'
  _ans="${_ans%$'\r'}"; printf -v "$_pv" '%s' "${_ans:-$_def}"
}
yesno() {
  local _yv="$1" _ym="$2" _yd="${3:-n}" _yn=''
  while true; do
    ask _yn "$_ym (y/n)" "$_yd"; _yn="${_yn//[[:space:]]/}"
    case "$_yn" in y|Y|yes|YES|да|Да|ДА|д|Д) printf -v "$_yv" '%s' y; return ;; n|N|no|NO|нет|Нет|НЕТ|н|Н) printf -v "$_yv" '%s' n; return ;; *) say 'Введите y/да или n/нет.' ;; esac
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
check_key() {
  local key="$1" tmp
  [[ -n "$key" && "$key" != *$'\n'* && "$key" != *$'\r'* ]] || die 'Нужен один публичный ключ.'
  case "$key" in 'ssh-ed25519 '*|'ssh-rsa '*|'ecdsa-sha2-'*|'sk-ssh-ed25519@openssh.com '*|'sk-ecdsa-sha2-'*) ;; *) die 'Нужен публичный ключ без authorized_keys options.' ;; esac
  tmp="$(mktemp)"; printf '%s\n' "$key" > "$tmp"
  if ! ssh-keygen -lf "$tmp" >/dev/null 2>&1; then rm -f "$tmp"; die 'Некорректный ключ.'; fi
  rm -f "$tmp"
}
connection() {
  [[ -n "${SSH_CONNECTION:-}" ]] || die 'Нет SSH_CONNECTION: нужна непосредственная root SSH-сессия.'
  read -r REMOTE_IP REMOTE_PORT LOCAL_IP LOCAL_PORT <<< "$SSH_CONNECTION"
  valid_ip "$REMOTE_IP" >/dev/null || die 'Некорректный IP клиента.'
  valid_ip "$LOCAL_IP" >/dev/null || die 'Некорректный IP сервера.'
  valid_port "$LOCAL_PORT" || die 'Некорректный порт сессии.'
}
ban_defaults() {
  BANS="${BANS:-y}"; BAN_DAYS="${BAN_DAYS:-30}"; BAN_RETRIES="${BAN_RETRIES:-3}"
  BAN_WINDOW="${BAN_WINDOW:-600}"; BAN_SCOPE="${BAN_SCOPE:-1}"; BAN_EXTRA_IP="${BAN_EXTRA_IP:-}"
}
load_config() {
  [[ -f "$CONFIG" && ! -L "$CONFIG" ]] || die 'Нет сохранённых настроек: сначала полный запуск.'
  [[ "$(stat -c '%u:%a' "$CONFIG")" == 0:600 ]] || die 'Нужны root:600 для config.sh.'
  source "$CONFIG"
  valid_port "${SSH_PORT:-}" || die 'Некорректный SSH_PORT.'
  SSH_PORT=$((10#$SSH_PORT)); ((SSH_PORT != 22 && SSH_PORT != 80 && SSH_PORT != 443)) || die 'SSH_PORT зарезервирован.'
  [[ "${KEY_ONLY:-}" == y || "${KEY_ONLY:-}" == n ]] || die 'Некорректный KEY_ONLY.'
  [[ "${HONEYPOT:-}" == y || "${HONEYPOT:-}" == n ]] || die 'Некорректный HONEYPOT.'
  LOG_PORT22="${LOG_PORT22:-n}"; WHITELIST_IP="${WHITELIST_IP:-}"; SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
  [[ "$LOG_PORT22" == y || "$LOG_PORT22" == n ]] || die 'Некорректный LOG_PORT22.'
  if [[ -n "$WHITELIST_IP" ]]; then WHITELIST_IP="$(valid_ip "$WHITELIST_IP")"; fi
  if [[ "$KEY_ONLY" == y ]]; then check_key "$SSH_PUBLIC_KEY"; fi
  ban_defaults; maintenance_defaults
}
save_config() {
  local tmp v
  tmp="$(mktemp "$STATE/.config.XXXXXXXX")"
  for v in SSH_PORT KEY_ONLY SSH_PUBLIC_KEY WHITELIST_IP LOG_PORT22 HONEYPOT BANS BAN_DAYS BAN_RETRIES BAN_WINDOW BAN_SCOPE BAN_EXTRA_IP EXTRA_PORTS CLEAN_DAYS CLEAN_MIB MIN_FREE_MIB; do printf '%s=%q\n' "$v" "${!v}"; done > "$tmp"
  chmod 600 "$tmp"; mv -f -- "$tmp" "$CONFIG"
}
ask_bans() {
  ban_defaults
  if [[ "$HONEYPOT" != y ]]; then BANS=n; return 0; fi
  yesno BANS 'Настроить автобаны Cowrie (существующий jail при n не удаляется)' "$BANS"
  [[ "$BANS" == y ]] || return 0
  ask_number BAN_DAYS 'Бан Cowrie, суток' "$BAN_DAYS" 1 365
  ask_number BAN_RETRIES 'Авторизаций до бана' "$BAN_RETRIES" 1 20
  ask_number BAN_WINDOW 'Окно подсчёта, секунд' "$BAN_WINDOW" 60 86400
  local answer
  say '1) Только 22/tcp. 2) Весь входящий трафик к VPS (SSH/панель/Xray тоже).'
  ask_number BAN_SCOPE 'Область бана' "$BAN_SCOPE" 1 2
  ask_ip BAN_EXTRA_IP 'Дополнительный IP администратора' "$BAN_EXTRA_IP"
  if [[ "$BAN_SCOPE" == 2 ]]; then
    say 'Общий NAT/VPN-адрес может объединять бота и обычных клиентов.'
    ask answer 'Подтвердите all-ports словом ALL' ''; [[ "$answer" == ALL ]] || die 'All-ports не подтверждён.'
  fi
}
read_active() {
  [[ -f "$ACTIVE" && ! -L "$ACTIVE" ]] || return 1
  IFS= read -r ACTIVE_TX < "$ACTIVE"
  [[ "$ACTIVE_TX" == "$STATE"/transactions/tx.* && -d "$ACTIVE_TX" ]] || die 'Повреждён путь транзакции.'
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
restore_ssh() {
  local tx="$ACTIVE_TX" failed=0
  [[ -f "$tx/snapshot.sh" ]] || return 1; source "$tx/snapshot.sh"
  say "Откат SSH/UFW/Fail2ban: $tx"
  systemctl disable --now "$GUARD_TIMER" "$CLEAN_TIMER" >/dev/null 2>&1 || true
  timeout 45s systemctl stop vps-cowrie.service >/dev/null 2>&1 || true
  timeout 45s systemctl stop fail2ban.service || true
  rm -f "$MANAGED" "$JAIL" "$BAN_FILTER" "$BAN_JAIL" "$BAN_GLOBAL"
  cp -a "$tx/ssh/." /etc/ssh/ || failed=1; cp -a "$tx/ufw/." /etc/ufw/ || failed=1
  cp -a "$tx/default-ufw" /etc/default/ufw || failed=1; cp -a "$tx/fail2ban/." /etc/fail2ban/ || failed=1
  if [[ "$HAD_KEYS" == yes ]]; then cp -a "$tx/authorized_keys" /root/.ssh/authorized_keys || failed=1
  else rm -f /root/.ssh/authorized_keys || failed=1; fi
  if [[ "$UFW_WAS_ACTIVE" == yes ]]; then timeout 45s ufw --force enable || failed=1; timeout 45s ufw reload || failed=1
  else timeout 45s ufw --force disable || failed=1; fi
  /usr/sbin/sshd -t || failed=1; systemctl unmask ssh.socket >/dev/null 2>&1 || true
  timeout 45s systemctl stop ssh.socket || true; systemctl daemon-reload || failed=1
  if [[ "$SOCKET_WAS_ACTIVE" == active ]]; then
    timeout 45s systemctl stop ssh.service || failed=1; timeout 45s systemctl start ssh.socket || failed=1
    if [[ "$SSH_WAS_ACTIVE" == active ]]; then timeout 45s systemctl start ssh.service || failed=1; fi
  elif [[ "$SSH_WAS_ACTIVE" == active ]]; then timeout 45s systemctl restart ssh.service || failed=1
  else timeout 45s systemctl stop ssh.service || failed=1; fi
  restore_enabled ssh.socket "$SOCKET_WAS_ENABLED" || failed=1
  restore_enabled ssh.service "$SSH_WAS_ENABLED" || failed=1
  restore_enabled fail2ban.service "$F2B_WAS_ENABLED" || failed=1
  if [[ "$F2B_WAS_ACTIVE" == active ]]; then timeout 45s systemctl restart fail2ban.service || failed=1
  else timeout 45s systemctl stop fail2ban.service || failed=1; fi
  if [[ -n "${COWRIE_WAS_ENABLED:-}" && "$COWRIE_WAS_ENABLED" != not-found ]]; then
    restore_enabled vps-cowrie.service "$COWRIE_WAS_ENABLED" || failed=1
    if [[ "${COWRIE_WAS_ACTIVE:-}" == active ]]; then timeout 45s systemctl start vps-cowrie.service || failed=1; fi
  fi
  if [[ "${GUARD_WAS_ENABLED:-}" == enabled ]]; then systemctl enable "$GUARD_TIMER" >/dev/null || failed=1; fi
  if [[ "${GUARD_WAS_ACTIVE:-}" == active ]]; then systemctl start "$GUARD_TIMER" || failed=1; fi
  if [[ "${CLEAN_WAS_ENABLED:-}" == enabled ]]; then systemctl enable "$CLEAN_TIMER" >/dev/null || failed=1; fi
  if [[ "${CLEAN_WAS_ACTIVE:-}" == active ]]; then systemctl start "$CLEAN_TIMER" || failed=1; fi
  ((failed==0)) || return 1
  cancel_timer || return 1; rm -f "$ACTIVE"; ACTIVE_TX=''; TX_OWNED=0
  say 'Сохранённые SSH/UFW/Fail2ban восстановлены; пакеты/ядро/swap/время не отменены.'
}
arm_timer() {
  cat > /etc/systemd/system/vps-foundation-rollback.service <<EOF
[Unit]
Description=Rollback unconfirmed VPS SSH configuration
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/bin/bash $SELF --rollback
TimeoutStartSec=600
EOF
  cat > "/etc/systemd/system/$TIMER" <<'EOF'
[Unit]
Description=Rollback unconfirmed SSH configuration in 15 minutes
[Timer]
OnActiveSec=15min
AccuracySec=1s
Unit=vps-foundation-rollback.service
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload; systemctl enable "$TIMER" >/dev/null; systemctl restart "$TIMER"; systemctl is-active --quiet "$TIMER"
}
snapshot() {
  local tx v status
  tx="$(mktemp -d "$STATE/transactions/tx.XXXXXXXX")"
  cp -a /etc/ssh "$tx/ssh"; cp -a /etc/ufw "$tx/ufw"; cp -a /etc/default/ufw "$tx/default-ufw"; cp -a /etc/fail2ban "$tx/fail2ban"
  HAD_KEYS=no
  if [[ -e /root/.ssh/authorized_keys || -L /root/.ssh/authorized_keys ]]; then
    [[ -f /root/.ssh/authorized_keys && ! -L /root/.ssh/authorized_keys && ! -L /root/.ssh ]] || die 'Нестандартный authorized_keys/.ssh.'
    cp -a /root/.ssh/authorized_keys "$tx/authorized_keys"; HAD_KEYS=yes
  fi
  UFW_WAS_ACTIVE=no; status="$(ufw status)"; if grep -Fxq 'Status: active' <<< "$status"; then UFW_WAS_ACTIVE=yes; fi
  SOCKET_WAS_ACTIVE="$(unit_active ssh.socket)"; SOCKET_WAS_ENABLED="$(unit_enabled ssh.socket)"
  SSH_WAS_ACTIVE="$(unit_active ssh.service)"; SSH_WAS_ENABLED="$(unit_enabled ssh.service)"
  F2B_WAS_ACTIVE="$(unit_active fail2ban.service)"; F2B_WAS_ENABLED="$(unit_enabled fail2ban.service)"
  COWRIE_WAS_ACTIVE="$(unit_active vps-cowrie.service)"; COWRIE_WAS_ENABLED="$(unit_enabled vps-cowrie.service)"
  GUARD_WAS_ACTIVE="$(unit_active "$GUARD_TIMER")"; GUARD_WAS_ENABLED="$(unit_enabled "$GUARD_TIMER")"
  CLEAN_WAS_ACTIVE="$(unit_active "$CLEAN_TIMER")"; CLEAN_WAS_ENABLED="$(unit_enabled "$CLEAN_TIMER")"
  for v in GUARD_WAS_ACTIVE GUARD_WAS_ENABLED CLEAN_WAS_ACTIVE CLEAN_WAS_ENABLED HAD_KEYS UFW_WAS_ACTIVE SOCKET_WAS_ACTIVE SOCKET_WAS_ENABLED SSH_WAS_ACTIVE SSH_WAS_ENABLED F2B_WAS_ACTIVE F2B_WAS_ENABLED COWRIE_WAS_ACTIVE COWRIE_WAS_ENABLED; do printf '%s=%q\n' "$v" "${!v}"; done > "$tx/snapshot.sh"
  printf '%s\n' initial > "$tx/stage"; printf '%s\n' "$tx" > "$ACTIVE"; ACTIVE_TX="$tx"; TX_OWNED=1; arm_timer
}
ufw_first() {
  local added; added="$(ufw show added)"
  case "${1:-}" in allow|limit) ;; *) die 'Неверная операция ufw_first.' ;; esac
  if grep -q '^ufw ' <<< "$added"; then ufw insert 1 "$@"; else ufw "$@"; fi
}
write_sshd() {
  {
    printf 'Port %s\n' "$SSH_PORT"
    if [[ "$1" == initial ]]; then
      printf 'Port 22\n'
      if [[ -n "${LOCAL_PORT:-}" && "$LOCAL_PORT" != 22 && "$LOCAL_PORT" != "$SSH_PORT" ]]; then printf 'Port %s\n' "$LOCAL_PORT"; fi
    fi
    printf '%s\n' 'AddressFamily any' 'PubkeyAuthentication yes'
    if [[ "$KEY_ONLY" == y ]]; then printf '%s\n' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'PermitRootLogin prohibit-password' 'AuthenticationMethods publickey'
    else printf '%s\n' 'PasswordAuthentication yes' 'KbdInteractiveAuthentication no' 'PermitRootLogin yes' 'AuthenticationMethods any'; fi
    printf '%s\n' 'MaxAuthTries 6' 'X11Forwarding no' 'UseDNS no'
  } > "$MANAGED"; chmod 600 "$MANAGED"
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
settings = dict(line.split(None,1) for line in sys.argv[1].splitlines() if ' ' in line)
paths = [p.replace('%h','/root').replace('%u','root').replace('%U','0') for p in shlex.split(settings.get('authorizedkeysfile',''))]
if not any(p in ('.ssh/authorized_keys','/root/.ssh/authorized_keys') for p in paths):
    raise SystemExit('sshd не читает /root/.ssh/authorized_keys.')
PY
  else
    grep -Fxq 'passwordauthentication yes' <<< "$effective" || die 'Парольный вход переопределён.'
    grep -Fxq 'permitrootlogin yes' <<< "$effective" || die 'Root-вход переопределён.'
    grep -Fxq 'authenticationmethods any' <<< "$effective" || die 'AuthenticationMethods переопределён.'
  fi
}
listener_ok() { local s; s="$(ss -H -lntp "sport = :$SSH_PORT")"; [[ "$s" == *sshd* ]] || die "Нет sshd на $SSH_PORT."; }
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
  if [[ -f /root/.vps-config || -f /etc/fail2ban/jail.d/99-vps-ssh.local || -f /etc/ssh/sshd_config.d/00-vps.conf ]]; then die 'Найдена старая исходная версия: нужна отдельная миграция.'; fi
  for f in /etc/ufw/before.rules /etc/ufw/before6.rules; do
    if [[ -f "$f" ]] && grep -Eq 'SSH_HONEYPOT_TRAP_START|VPS_PORT22_TRAP_START' "$f"; then die 'Старая ловушка UFW: нужна миграция.'; fi
  done
}
ssh_setup() {
  check_legacy; load_config; [[ ! -f "$ACTIVE" ]] || die 'Уже есть незавершённая SSH-транзакция.'
  local t s answer
  for t in python3 ufw fail2ban-client fail2ban-regex ss iptables-restore ip6tables-restore timeout; do need "$t"; done
  [[ -f /etc/ufw/before.rules && -f /etc/default/ufw ]] || die 'Нет конфигурации UFW.'
  install -d -m 755 /run/sshd; /usr/sbin/sshd -t
  if [[ -e /proc/net/if_inet6 ]] && [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)" == 0 ]]; then
    grep -Eqi '^IPV6=yes' /etc/default/ufw || die 'IPv6 включён, но UFW имеет IPV6=no. Сначала проверьте IPv6-фильтрацию.'
  fi
  if [[ "$HONEYPOT" == y ]]; then cowrie_preflight; fi
  if [[ -n "${SSH_CONNECTION:-}" ]]; then connection; else REMOTE_IP=127.0.0.1; LOCAL_IP=127.0.0.1; LOCAL_PORT=''; fi
  s="$(ss -H -lntp "sport = :$SSH_PORT")"; [[ -z "$s" || "$s" == *sshd* ]] || die "Порт $SSH_PORT занят."
  say 'UFW: incoming DENY/outgoing ALLOW; открываются 80/tcp, 443/tcp, 443/udp и SSH. Другие порты разрешите заранее.'
  if [[ "$ASSUME_START" != 1 ]]; then ask answer 'Применить SSH с откатом через 15 минут? Введите START' ''; [[ "$answer" == START ]] || return 0; fi
  snapshot
  if [[ -f /etc/systemd/system/vps-cowrie.service ]]; then timeout 45s systemctl stop vps-cowrie.service; systemctl disable vps-cowrie.service >/dev/null; fi
  if [[ "$KEY_ONLY" == y ]]; then
    [[ ! -L /root/.ssh ]] || die 'Нестандартный /root/.ssh.'; install -d -m 700 /root/.ssh; touch /root/.ssh/authorized_keys
    if ! grep -Fxq -- "$SSH_PUBLIC_KEY" /root/.ssh/authorized_keys; then printf '\n%s\n' "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys; fi
    chmod 600 /root/.ssh/authorized_keys; chown root:root /root/.ssh /root/.ssh/authorized_keys
  fi
  port22_rules remove
  if [[ "$(head -n1 /etc/ssh/sshd_config)" != 'Include /etc/ssh/vps-foundation.conf' ]]; then sed -i '1i Include /etc/ssh/vps-foundation.conf' /etc/ssh/sshd_config; fi
  write_sshd initial; /usr/sbin/sshd -t; validate_effective
  ufw_temporary_allow 22/tcp 'vps-foundation fallback'; ufw_first limit "$SSH_PORT/tcp" comment 'vps-foundation SSH'
  if [[ -n "$LOCAL_PORT" && "$LOCAL_PORT" != 22 && "$LOCAL_PORT" != "$SSH_PORT" ]]; then ufw_temporary_allow "$LOCAL_PORT/tcp" 'vps-foundation previous SSH'; fi
  apply_extra_ports
  ufw allow 80/tcp; ufw allow 443/tcp; ufw allow 443/udp; ufw default deny incoming; ufw default allow outgoing; timeout 45s ufw --force enable
  timeout 45s systemctl stop ssh.socket || true; systemctl disable ssh.socket >/dev/null 2>&1 || true; systemctl mask ssh.socket >/dev/null 2>&1 || true
  systemctl daemon-reload; systemctl enable ssh.service >/dev/null; timeout 45s systemctl restart ssh.service; listener_ok
  write_jail "22,$SSH_PORT${LOCAL_PORT:+,$LOCAL_PORT}"; systemctl enable fail2ban.service >/dev/null; timeout 45s systemctl restart fail2ban.service
  say "SSH на $SSH_PORT; 22 пока тоже работает. Автооткат через 15 минут."
  say "Откройте НОВОЕ подключение на $SSH_PORT и выполните: bash /root/finalize-ssh.sh"
  TX_OWNED=0; ACTIVE_TX='' 
}
finalize() {
  # An invalid invocation must never own the existing transaction's rollback.
  load_config; connection
  [[ "$LOCAL_PORT" == "$SSH_PORT" ]] || die "Нужно новое подключение на $SSH_PORT. Транзакция не изменена."
  read_active || die 'Нет активной транзакции.'
  [[ "$(cat "$ACTIVE_TX/stage")" == initial ]] || die 'Этот этап уже выполнен. Используйте выданную команду --confirm или --rollback.'
  local ports token
  if [[ "$HONEYPOT" == y ]]; then cowrie_preflight; fi
  TX_OWNED=1; install_self; systemctl restart "$TIMER"
  write_sshd final; /usr/sbin/sshd -t; validate_effective
  ports="$(/usr/sbin/sshd -T | awk '$1=="port" {print $2}' | sort -nu)"
  [[ "$ports" == "$SSH_PORT" ]] || die "Лишние Port в чужих конфигах: $ports"
  write_jail "$SSH_PORT"; port22_rules add; remove_temporary_rules
  timeout 45s ufw reload; timeout 45s systemctl restart ssh.service; listener_ok
  if [[ "$HONEYPOT" == y ]]; then
    ufw_first allow 22/tcp comment 'vps-foundation Cowrie'; timeout 45s ufw reload
    install_maintenance_helpers
    systemctl reset-failed vps-cowrie.service >/dev/null 2>&1 || true
    systemctl enable vps-cowrie.service >/dev/null
    PHASE=cowrie; timeout 45s systemctl start vps-cowrie.service; cowrie_listener_ok; PHASE=''
    systemctl enable --now "$GUARD_TIMER" "$CLEAN_TIMER" >/dev/null
  fi
  timeout 45s systemctl restart fail2ban.service
  token="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
  printf '%s\n' "$token" > "$ACTIVE_TX/confirm.token"
  printf '%s\n' "$SSH_CONNECTION" > "$ACTIVE_TX/finalizer.connection"
  printf '%s\n' awaiting-confirm > "$ACTIVE_TX/stage"
  systemctl restart "$TIMER"
  say ''; say 'Откройте ЕЩЁ ОДНУ новую SSH-сессию на новом порту (без multiplexing).'
  say 'В ней выполните следующую команду. На проверку есть 15 минут:'
  say "bash $SELF --confirm $token"
  say 'До подтверждения действует автоматический откат. Эти окна можно оставить открытыми.'
  TX_OWNED=0; ACTIVE_TX=''
}
confirm_ssh() {
  local supplied="${1:-}" expected previous
  load_config; connection
  [[ "$LOCAL_PORT" == "$SSH_PORT" ]] || die "Подтверждение выполняется на порту $SSH_PORT."
  read_active || die 'Нет активной транзакции.'
  [[ "$(cat "$ACTIVE_TX/stage")" == awaiting-confirm && -f "$ACTIVE_TX/confirm.token" ]] || die 'Сначала выполните --finalize.'
  IFS= read -r expected < "$ACTIVE_TX/confirm.token"
  IFS= read -r previous < "$ACTIVE_TX/finalizer.connection"
  [[ -n "$supplied" && "$supplied" == "$expected" ]] || die 'Неверный код подтверждения; таймер и настройки не изменены.'
  [[ "$SSH_CONNECTION" != "$previous" ]] || die 'Это та же SSH-сессия. Откройте новую без ControlMaster.'
  TX_OWNED=1
  /usr/sbin/sshd -t; validate_effective; listener_ok
  if [[ "$HONEYPOT" == y ]]; then cowrie_listener_ok; "$HELPERS/firewall-check"; fi
  cancel_timer
  printf '%s\n' "$ACTIVE_TX" > "$STATE/last-confirmed"
  rm -f "$ACTIVE_TX/confirm.token" "$ACTIVE"; ACTIVE_TX=''; TX_OWNED=0
  say 'Новый авторизованный вход подтверждён. SSH сохранён; таймер отката отключён.'
  if [[ "$HONEYPOT" == y && "$BANS" == y ]]; then install_bans; BAN_CHANGED=0; fi
  say 'Готово. Если установлено новое ядро, перезагрузку выполните после проверки панели.'
}

port22_rules() {
  local mode="$1" file uid=0
  if [[ "$HONEYPOT" == y ]]; then uid="$(id -u vps-cowrie)"; fi
  for file in /etc/ufw/before.rules /etc/ufw/before6.rules; do
    [[ -f "$file" ]] || continue
    python3 - "$mode" "$file" "$LOG_PORT22" "$HONEYPOT" "$uid" <<'PY'
from pathlib import Path
import os,re,sys,tempfile
mode,filename,logging,hp,uid=sys.argv[1:]
if not uid.isdecimal():
    raise SystemExit('Invalid UID')
p=Path(filename); s=p.read_text()
for tag in ('VPS_FOUNDATION_PORT22','VPS_COWRIE_EGRESS'):
    start='# ===== '+tag+'_START ====='; end='# ===== '+tag+'_END ====='
    if s.count(start)!=s.count(end) or s.count(start)>1:
        raise SystemExit('Повреждены маркеры '+filename)
    if start in s:
        a,b=s.index(start),s.index(end)
        if b<a:
            raise SystemExit('Неверный порядок маркеров')
        s=s[:a]+s[b+len(end):].lstrip('\n')
if mode=='add':
    a=s.index('*filter\n'); b=s.index('\nCOMMIT',a)
    m=re.search(r'^-A (ufw6?-before-'+('output' if hp=='y' else 'input')+r')\b',s[a:b],re.M)
    if not m:
        raise SystemExit('Не найдена цепочка UFW: '+filename)
    chain=m.group(1)
    if hp=='y':
        block=['# ===== VPS_COWRIE_EGRESS_START =====',
               f'-A {chain} -m owner --uid-owner {uid} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT',
               f'-A {chain} -m owner --uid-owner {uid} -j REJECT',
               '# ===== VPS_COWRIE_EGRESS_END =====']
    else:
        block=['# ===== VPS_FOUNDATION_PORT22_START =====']
        if logging=='y':
            block.append(f'-A {chain} -p tcp --dport 22 --syn -m conntrack --ctstate NEW -m limit --limit 6/min --limit-burst 10 -j LOG --log-prefix "VPS_PORT22: "')
        block += [f'-A {chain} -p tcp --dport 22 -m conntrack --ctstate NEW -j DROP','# ===== VPS_FOUNDATION_PORT22_END =====']
    pos=a+m.start(); s=s[:pos]+'\n'.join(block)+'\n'+s[pos:]
elif mode!='remove':
    raise SystemExit('Неизвестный режим')
st=p.stat(); fd,tmp=tempfile.mkstemp(dir=p.parent,prefix='.vps-foundation-')
try:
    with os.fdopen(fd,'w') as f:
        f.write(s)
    os.chmod(tmp,st.st_mode&0o777); os.chown(tmp,st.st_uid,st.st_gid); os.replace(tmp,p)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
  done
  iptables-restore --test < /etc/ufw/before.rules
  if grep -Eqi '^IPV6=yes' /etc/default/ufw && [[ -e /proc/net/if_inet6 ]]; then ip6tables-restore --test < /etc/ufw/before6.rules; fi
}
cowrie_diagnostics() {
  say '=== Cowrie: диагностика до отката ===' >&2
  systemctl status vps-cowrie.service --no-pager -l >&2 || true
  journalctl -u vps-cowrie.service -b -n100 --no-pager -o cat >&2 || true
}
write_cowrie_unit() {
  local backup
  if [[ -f /etc/systemd/system/vps-cowrie.service ]]; then backup="$(mktemp "$STATE/cowrie-unit-backup.XXXXXXXX")"; cp -a /etc/systemd/system/vps-cowrie.service "$backup"; fi
  cat > /etc/systemd/system/vps-cowrie.service <<'UNIT'
[Unit]
Description=Cowrie SSH honeypot (not administration SSH)
After=network.target ufw.service
BindsTo=ufw.service
Requires=ufw.service
[Service]
Type=simple
User=vps-cowrie
Group=vps-cowrie
WorkingDirectory=/var/lib/vps-cowrie
Environment=HOME=/var/lib/vps-cowrie
Environment=PATH=/opt/vps-cowrie/bin:/usr/bin:/bin
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStartPre=+/bin/bash /usr/local/libexec/vps-foundation/firewall-check
ExecStart=/opt/vps-cowrie/bin/python /opt/vps-cowrie/bin/twistd --umask 0077 --nodaemon --pidfile= -l - cowrie
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
  chmod 644 /etc/systemd/system/vps-cowrie.service; systemctl daemon-reload
}
prepare_cowrie() {
  local home=/var/lib/vps-cowrie venv=/opt/vps-cowrie
  python3 -c 'import sys; sys.exit(sys.version_info < (3,10))' || die 'Cowrie требует Python 3.10+. Используйте поддерживаемый релиз Debian/Ubuntu.'
  if systemctl is-active --quiet vps-cowrie.service; then die 'Cowrie уже работает: обновление на ходу не выполняется.'; fi
  [[ ! -e "$home" || -f "$home/.vps-managed" ]] || die 'Нестандартный каталог Cowrie.'
  if id vps-cowrie >/dev/null 2>&1; then [[ "$(getent passwd vps-cowrie|cut -d: -f6)" == "$home" ]] || die 'Конфликт пользователя Cowrie.'
  else useradd --system --user-group --home-dir "$home" --shell /usr/sbin/nologin vps-cowrie; fi
  [[ ! -e "$venv" || -f "$venv/.vps-managed" || -f "$venv/.vps-installing" ]] || die 'Нестандартный venv Cowrie.'
  if [[ ! -f "$venv/.vps-managed" ]]; then
    install -d -m755 "$venv"; touch "$venv/.vps-installing"; python3 -m venv "$venv"
    "$venv/bin/python" -m pip install --upgrade pip; "$venv/bin/python" -m pip install "cowrie==$COWRIE_VERSION"
    mv "$venv/.vps-installing" "$venv/.vps-managed"; chown -R root:root "$venv"; chmod -R a+rX "$venv"
  fi
  install -d -m750 -o vps-cowrie -g vps-cowrie "$home"; touch "$home/.vps-managed"
  if [[ ! -f "$home/etc/cowrie.cfg" ]]; then runuser -u vps-cowrie -- /bin/bash -c 'cd "$1"; exec /opt/vps-cowrie/bin/cowrie init' _ "$home"; fi
  [[ -d "$home/etc" ]] || die 'Нет etc Cowrie.'
  [[ ! -f "$home/etc/cowrie.cfg" ]] || cp -a "$home/etc/cowrie.cfg" "$home/etc/cowrie.cfg.before-vps"
  cat > "$home/etc/cowrie.cfg" <<'COWRIE'
[honeypot]
hostname = srv-cache
auth_class = UserDB
backend = shell
download_limit_size = 10485760
logtype = rotating
[ssh]
enabled = true
listen_endpoints = tcp:22:interface=0.0.0.0
forwarding = false
sftp_enabled = false
[telnet]
enabled = false
[output_jsonlog]
enabled = true
COWRIE
  printf '%s\n' 'root:x:*' 'admin:x:*' 'test:x:*' > "$home/etc/userdb.txt"
  chown -R root:vps-cowrie "$home/etc"; chmod -R u=rwX,g=rX,o= "$home/etc"
  chown root:vps-cowrie "$home" "$home/.vps-managed"; chmod 750 "$home"
  install -d -m750 -o vps-cowrie -g vps-cowrie "$home/var"; chown -R vps-cowrie:vps-cowrie "$home/var"
  install_maintenance_helpers; write_cowrie_unit; "$venv/bin/python" -m pip freeze > "$home/installed-packages.txt"; cowrie_preflight
}
check_cowrie_prepared() {
  [[ -x /opt/vps-cowrie/bin/python && -f /opt/vps-cowrie/bin/twistd && -f /var/lib/vps-cowrie/.vps-managed && -f /var/lib/vps-cowrie/etc/cowrie.cfg ]] || die 'Cowrie не подготовлен: нужен полный запуск.'
  id vps-cowrie >/dev/null
}
cowrie_preflight() {
  local cmd output
  check_cowrie_prepared; cmd="$(systemctl show vps-cowrie.service -p ExecStart --value)"
  [[ "$cmd" == *'/opt/vps-cowrie/bin/twistd'* && "$cmd" == *'--nodaemon'* && "$cmd" != *'/bin/cowrie start'* ]] || die 'Неверный ExecStart Cowrie/override: systemctl cat vps-cowrie.service --no-pager'
  [[ "$(systemctl show vps-cowrie.service -p User --value)" == vps-cowrie ]] || die 'Cowrie не должен запускаться как root.'
  [[ "$(systemctl show vps-cowrie.service -p WorkingDirectory --value)" == /var/lib/vps-cowrie ]] || die 'Неверный каталог Cowrie.'
  runuser -u vps-cowrie -- test -r /var/lib/vps-cowrie/etc/cowrie.cfg || die 'Cowrie не читает конфиг.'
  runuser -u vps-cowrie -- test -w /var/lib/vps-cowrie/var || die 'Cowrie не пишет состояние.'
  if ! output="$(runuser -u vps-cowrie -- /bin/bash -c 'cd /var/lib/vps-cowrie; exec /opt/vps-cowrie/bin/python -' 2>&1 <<'PY'
from twisted.application.service import IServiceMaker
from twisted.plugin import getPlugins
from importlib.metadata import version
names=[p.tapname for p in getPlugins(IServiceMaker)]
if 'cowrie' not in names:
    raise SystemExit('Twisted не видит cowrie: '+', '.join(names))
print('Cowrie '+version('cowrie')+': Twisted plugin OK')
PY
  )"; then printf '%s\n' "$output" >&2; die 'Предварительная проверка Cowrie не пройдена.'; fi
  printf '%s\n' "$output"
}
cowrie_listener_ok() {
  local i
  for i in {1..15}; do
    if systemctl is-active --quiet vps-cowrie.service; then
      if python3 - <<'PY'
import socket,sys,pwd
uid=pwd.getpwnam('vps-cowrie').pw_uid
with open('/proc/net/tcp') as f:
    rows=[s.split() for s in f.readlines()[1:]]
if not any(r[1].split(':')[-1]=='0016' and r[3]=='0A' and int(r[7])==uid for r in rows):
    sys.exit(1)
try:
    with socket.create_connection(('127.0.0.1',22),timeout=2) as s:
        s.settimeout(2); banner=b''
        while b'\n' not in banner and len(banner)<256:
            chunk=s.recv(256-len(banner))
            if not chunk:
                break
            banner+=chunk
    if not banner.startswith(b'SSH-2.0-'):
        sys.exit(1)
except OSError:
    sys.exit(1)
PY
      then return 0; fi
    fi
    sleep 1
  done
  return 1
}
make_swap() {
  ((SWAP_SIZE_GB>0)) || return 0
  local fs free swaps need_bytes
  if [[ -e /swapfile || -L /swapfile ]]; then
    [[ -f /swapfile && ! -L /swapfile ]] || die 'Небезопасный swapfile.'
    [[ "$(blkid -p -s TYPE -o value /swapfile || true)" == swap ]] || die 'Существующий /swapfile не является swap.'
    say "Существующий swap: $(stat -c %s /swapfile) байт, размер не меняется."
  else
    fs="$(findmnt -n -o FSTYPE -T /)"; [[ "$fs" == ext4 || "$fs" == xfs ]] || die 'Автосоздание swap только ext4/XFS.'
    free="$(df -B1 --output=avail /|tail -n1|tr -d '[:space:]')"; need_bytes=$((SWAP_SIZE_GB*1073741824))
    ((free>need_bytes+1073741824)) || die 'Недостаточно диска для swap и запаса 1 GiB.'
    SWAP_TMP="$(mktemp /swapfile.vps-new.XXXXXXXX)"
    dd if=/dev/zero of="$SWAP_TMP" bs=1M count="$((SWAP_SIZE_GB*1024))" status=progress
    chmod 600 "$SWAP_TMP"; mkswap "$SWAP_TMP"; mv -n -- "$SWAP_TMP" /swapfile
    [[ ! -e "$SWAP_TMP" ]] || die '/swapfile появился параллельно.'; SWAP_TMP=''
  fi
  chmod 600 /swapfile; swaps="$(swapon --show=NAME --noheadings --raw)"
  if ! grep -Fxq /swapfile <<< "$swaps"; then swapon /swapfile; fi
  if ! awk '$1=="/swapfile" {f=1} END {exit !f}' /etc/fstab; then printf '%s\n' '/swapfile none swap sw 0 0' >> /etc/fstab; fi
}
configure_network() {
  local backup="$1" target=/etc/sysctl.d/99-vps-foundation.conf requested="$1/network.requested" key value mem max backlog fin
  [[ "$TCP_PROFILE" != off || "$BBR" == y || "$FORWARD" == y ]] || return 0
  : > "$requested"
  if [[ "$TCP_PROFILE" != off ]]; then
    mem="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"; max=16777216; backlog=8192; fin=30
    if ((mem>=2000000)); then max=33554432; fi
    if [[ "$TCP_PROFILE" == throughput ]]; then backlog=16384; fin=15; if ((mem>=4000000)); then max=67108864; else max=33554432; fi; fi
    cat >> "$requested" <<EOF
net.core.default_qdisc=fq
net.core.somaxconn=65535
net.core.netdev_max_backlog=$backlog
net.ipv4.tcp_max_syn_backlog=$backlog
net.core.rmem_max=$max
net.core.wmem_max=$max
net.ipv4.tcp_rmem=4096 131072 $max
net.ipv4.tcp_wmem=4096 65536 $max
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
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then printf '%s\n' 'net.core.default_qdisc=fq' 'net.ipv4.tcp_congestion_control=bbr' >> "$requested"
    else say 'BBR недоступен в работающем ядре; проверьте после загрузки нового.'; fi
  fi
  if [[ "$FORWARD" == y ]]; then printf '%s\n' 'net.ipv4.ip_forward=1' >> "$requested"; fi
  python3 - "$target" "$requested" <<'PY'
from pathlib import Path
import sys
old,new=map(Path,sys.argv[1:]); settings={}
for p in (old,new):
    if p.exists():
        for line in p.read_text().splitlines():
            line=line.strip()
            if line and not line.startswith(('#',';')) and '=' in line:
                k,v=line.split('=',1); settings[k.strip()]=v.strip()
new.write_text(''.join(f'{k}={v}\n' for k,v in settings.items()))
PY
  : > "$backup/runtime.conf"; : > "$backup/network.new"
  while IFS='=' read -r key value; do
    [[ -n "$key" ]] || continue
    if sysctl -n "$key" >/dev/null 2>&1; then printf '%s=%s\n' "$key" "$(sysctl -n "$key")" >> "$backup/runtime.conf"; printf '%s=%s\n' "$key" "$value" >> "$backup/network.new"; fi
  done < "$requested"
  [[ -s "$backup/network.new" ]] || return 0
  {
    printf '#!/bin/bash\nset -Eeuo pipefail\n[[ $EUID == 0 ]] || exit 1\n'; printf 'BACKUP=%q\nTARGET=%q\n' "$backup" "$target"
    cat <<'NETBACK'
if [[ -f "$BACKUP/sysctl.conf" ]]; then cp -a "$BACKUP/sysctl.conf" "$TARGET"; else rm -f "$TARGET"; fi
sysctl -p "$BACKUP/runtime.conf"
NETBACK
  } > /root/rollback-tcp.sh
  chmod 700 /root/rollback-tcp.sh; install -m644 "$backup/network.new" "$target"
  if ! sysctl -p "$target"; then bash /root/rollback-tcp.sh || true; die 'Не удалось применить TCP.'; fi
}
install_xanmod() {
  [[ "$(dpkg --print-architecture)" == amd64 ]] || die 'XanMod требует amd64.'
  local flags flag pkg candidate tmp
  flags="$(grep -m1 -E '^flags[[:space:]]*:' /proc/cpuinfo || true)"
  for flag in cx16 lahf_lm popcnt pni ssse3 sse4_1 sse4_2; do grep -qw "$flag" <<< "$flags" || die "Нет CPU-флага $flag для v2."; done
  if [[ "$XANMOD_LEVEL" == 3 ]]; then
    for flag in avx avx2 bmi1 bmi2 f16c fma movbe xsave; do grep -qw "$flag" <<< "$flags" || die "Нет CPU-флага $flag для v3."; done
    grep -Eq '(^|[[:space:]])(lzcnt|abm)([[:space:]]|$)' <<< "$flags" || die 'Нет lzcnt/abm.'
  fi
  case "$XANMOD" in lts) pkg="linux-xanmod-lts-x64v$XANMOD_LEVEL" ;; main) pkg="linux-xanmod-x64v$XANMOD_LEVEL" ;; *) die 'Неверная ветка ядра.' ;; esac
  install -d -m755 /etc/apt/keyrings; tmp="$(mktemp)"
  if ! wget -qO "$tmp" https://dl.xanmod.org/archive.key; then rm -f "$tmp"; die 'Не получен ключ XanMod.'; fi
  gpg --batch --yes --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg "$tmp"; rm -f "$tmp"; chmod 644 /etc/apt/keyrings/xanmod-archive-keyring.gpg
  [[ "$CODENAME" =~ ^[a-z][a-z0-9-]*$ ]] || die 'Некорректный codename.'
  cat > /etc/apt/sources.list.d/xanmod.sources <<EOF
Types: deb
URIs: https://deb.xanmod.org
Suites: $CODENAME
Components: main
Signed-By: /etc/apt/keyrings/xanmod-archive-keyring.gpg
EOF
  chmod 644 /etc/apt/sources.list.d/xanmod.sources; apt-get -o Acquire::Retries=3 update
  candidate="$(apt-cache policy "$pkg"|awk '/Candidate:/ {print $2}')"
  [[ -n "$candidate" && "$candidate" != '(none)' ]] || die "Нет кандидата $pkg для этого релиза."
  say "Выбран $pkg, версия $candidate"; apt-get -s install "$pkg" >/dev/null; apt-get install -y "$pkg"
}

restore_bans() {
  local failed=0 name dst old
  [[ -n "$BAN_BACKUP" && -d "$BAN_BACKUP" ]] || return 1
  for name in filter jail global; do
    case "$name" in filter) dst="$BAN_FILTER" ;; jail) dst="$BAN_JAIL" ;; global) dst="$BAN_GLOBAL" ;; esac
    if [[ -f "$BAN_BACKUP/$name.old" ]]; then cp -a "$BAN_BACKUP/$name.old" "$dst" || failed=1
    else rm -f "$dst" || failed=1; fi
  done
  fail2ban-client -t || failed=1; fail2ban-client reload || failed=1
  if [[ -f "$BAN_BACKUP/retention.old" ]]; then
    old="$(cat "$BAN_BACKUP/retention.old")"
    if [[ "$old" =~ ^[0-9]+$ ]]; then fail2ban-client set dbpurgeage "$old" >/dev/null || failed=1; fi
  fi
  ((failed==0)) || return 1; BAN_CHANGED=0
  say 'Прежняя конфигурация банов и срок хранения истории возвращены; SSH не перенастраивался.'
}
install_bans() {
  local v db oldkeep keep current name dst
  [[ "$BANS" == y && "$HONEYPOT" == y ]] || return 0
  for v in fail2ban-client fail2ban-regex iptables ip6tables python3; do need "$v"; done
  systemctl is-active --quiet fail2ban.service || die 'Fail2ban не запущен.'
  systemctl is-active --quiet vps-cowrie.service || die 'Cowrie не запущен.'
  [[ -f "$COWRIE_LOG" ]] || die 'Нет JSON-журнала Cowrie.'
  [[ ! -e /etc/fail2ban/filter.d/vps-cowrie-auth.local ]] || die 'Есть vps-cowrie-auth.local: сначала проверьте override вручную.'
  for dst in "$BAN_FILTER" "$BAN_JAIL" "$BAN_GLOBAL"; do
    if [[ -f "$dst" ]]; then grep -Fq 'VPS_COWRIE_BANS_MANAGED' "$dst" || die "Чужой файл $dst: не перезаписываю."; fi
  done
  [[ "$BAN_DAYS" =~ ^[0-9]{1,3}$ && "$BAN_RETRIES" =~ ^[0-9]{1,2}$ && "$BAN_WINDOW" =~ ^[0-9]{1,5}$ ]] || die 'Некорректные числовые параметры банов.'
  for v in BAN_DAYS BAN_RETRIES BAN_WINDOW; do printf -v "$v" '%s' "$((10#${!v}))"; done
  ((BAN_DAYS>=1 && BAN_DAYS<=365 && BAN_RETRIES>=1 && BAN_RETRIES<=20 && BAN_WINDOW>=60 && BAN_WINDOW<=86400)) || die 'Параметры банов вне диапазона.'
  [[ "$BAN_SCOPE" == 1 || "$BAN_SCOPE" == 2 ]] || die 'Неверная область бана.'
  fail2ban-client -t
  db="$(fail2ban-client get dbfile)"; [[ -n "$db" && "$db" != None && "$db" != none ]] || die 'Постоянная БД Fail2ban отключена: сначала включите dbfile для восстановления длительных банов.'
  oldkeep="$(fail2ban-client get dbpurgeage)"; [[ "$oldkeep" =~ ^[0-9]+$ ]] || die 'Не удалось прочитать dbpurgeage.'
  keep=$(((BAN_DAYS+10)*86400)); if ((keep<3456000)); then keep=3456000; fi
  if ((oldkeep>keep)); then keep="$oldkeep"; fi
  BAN_BACKUP="$(mktemp -d "$STATE/bans-backup.XXXXXXXX")"; printf '%s\n' "$oldkeep" > "$BAN_BACKUP/retention.old"
  current="${SSH_CONNECTION:-}"; current="${current%% *}"
  python3 - "$BAN_BACKUP" "$COWRIE_LOG" "$BAN_RETRIES" "$BAN_WINDOW" "$((BAN_DAYS*86400))" "$BAN_SCOPE" "$WHITELIST_IP" "$current" "${BAN_EXTRA_IP:-}" <<'PY'
from pathlib import Path
import sys, re, json, ipaddress, datetime, subprocess
work, logfile, retry, window, seconds, scope, *ips = sys.argv[1:]
work, logfile = Path(work), Path(logfile)
ignore = ['127.0.0.0/8','::1']
for value in ips:
    if value.strip():
        ip = str(ipaddress.ip_address(value.strip()))
        if ip not in ignore:
            ignore.append(ip)
if scope == '2' and len(ignore) == 2:
    raise SystemExit('Для all-ports нужен явный IP администратора в исключениях.')
q = r'"(?:[^"\\\r\n]|\\[^\r\n])*"'
number = r'-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?'
value = '(?:' + q + '|' + number + '|true|false|null)'
pair = q + r'\s*:\s*' + value
head = r'^\s*\{\s*(?:' + pair + r'\s*,\s*)*'
middle = r'\s*,\s*(?:' + pair + r'\s*,\s*)*'
tail = r'(?:\s*,\s*' + pair + r')*\s*\}\s*$'
event = r'"eventid"\s*:\s*"cowrie\.login\.(?:failed|success)"'
source = r'"src_ip"\s*:\s*"<ADDR>"'
patterns = [head+event+middle+source+tail, head+source+middle+event+tail]
date = r'{UNB}(?:(?<="timestamp": ")|(?<="timestamp":"))%%Y-%%m-%%dT%%H:%%M:%%S(?:\.%%f)?%%z'
filt = work/'filter.new.conf'
filt.write_text('# VPS_COWRIE_BANS_MANAGED\n[Definition]\nfailregex = ' + '\n            '.join(patterns) + '\nignoreregex =\nmaxlines = 1\ndatepattern = ' + date + '\n')
compiled = [re.compile(p.replace('<ADDR>',r'(?P<host>[0-9a-fA-F:.]+)')) for p in patterns]
now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='microseconds').replace('+00:00','Z')
valid = [
    {'eventid':'cowrie.login.failed','username':'u','password':'bad','src_ip':'192.0.2.10','timestamp':now},
    {'src_ip':'198.51.100.2','password':'"src_ip":"203.0.113.99"','timestamp':now,'eventid':'cowrie.login.success'},
    {'timestamp':now,'src_ip':'2001:db8::10','eventid':'cowrie.login.failed','message':'test'},
]
invalid = [
    {'timestamp':now,'src_ip':'192.0.2.30','eventid':'cowrie.command.input','input':'"eventid":"cowrie.login.failed", "src_ip":"203.0.113.55"'},
    {'eventid':'cowrie.session.connect','src_ip':'192.0.2.40','timestamp':now,'message':'cowrie.login.success'},
]
lines = []
for i,obj in enumerate(valid+invalid):
    line = json.dumps(obj,separators=(',',':') if i%2 else None)
    matches = [m for rx in compiled if (m:=rx.fullmatch(line))]
    if i<len(valid):
        assert len(matches)==1 and matches[0].group('host')==obj['src_ip']
    else:
        assert not matches
    lines.append(line)
fixture = work/'fixture.json'; fixture.write_text('\n'.join(lines)+'\n')
def test_file(path,expected,count):
    result = subprocess.run(['fail2ban-regex',str(path),str(filt)],capture_output=True,text=True)
    report = result.stdout+'\n'+result.stderr
    matched = re.search(r'Failregex:\s*(\d+)\s+total',report)
    section = report.split('Date template hits:',1)[-1].split('Lines:',1)[0]
    date_hits = sum(map(int,re.findall(r'(?m)^\s*\|\s*\[\s*(\d+)\s*\]',section)))
    if result.returncode or 'Date template hits:' not in report or not matched or int(matched[1])!=expected or date_hits<count:
        (work/'regex-diagnostic.txt').write_text(report)
        raise SystemExit('Фильтр не прошёл fail2ban-regex; изменения не применены. Диагностика root-only: '+str(work/'regex-diagnostic.txt'))
test_file(fixture,len(valid),len(lines))
with logfile.open('rb') as f:
    f.seek(0,2); f.seek(max(0,f.tell()-2*1024*1024)); raw=f.read(2*1024*1024)
actual=[]
for line in raw.splitlines():
    if len(line)>65536:
        continue
    try:
        obj=json.loads(line)
    except (ValueError,UnicodeDecodeError,RecursionError):
        continue
    if isinstance(obj,dict) and obj.get('eventid') in ('cowrie.login.failed','cowrie.login.success') and obj.get('timestamp') and obj.get('src_ip'):
        actual.append(line)
actual=actual[-30:]
if actual:
    sample=work/'actual-auth.json'; sample.write_bytes(b'\n'.join(actual)+b'\n')
    test_file(sample,len(actual),len(actual)); sample.unlink()
    print('Фильтр прошёл реальные auth-строки:',len(actual))
else:
    print('В конце журнала нет auth-строк; синтетические тесты пройдены.')
action_name='iptables-multiport' if scope=='1' else 'iptables-allports'
if not Path('/etc/fail2ban/action.d/'+action_name+'.conf').is_file():
    raise SystemExit('Нет штатного action '+action_name)
action='iptables-multiport[name=vps-cowrie-auth, port="22", protocol=tcp]' if scope=='1' else 'iptables-allports[name=vps-cowrie-auth, protocol=all]'
jail="""# VPS_COWRIE_BANS_MANAGED
[vps-cowrie-auth]
enabled = true
filter = vps-cowrie-auth
backend = polling
logpath = {logfile} tail
logencoding = utf-8
logtimezone = UTC
usedns = no
maxretry = {retry}
findtime = {window}
bantime = {seconds}
bantime.increment = false
ignoreself = true
ignoreip = {ignore}
action = {action}
""".format(logfile=logfile,retry=retry,window=window,seconds=seconds,ignore=' '.join(ignore),action=action)
(work/'jail.new').write_text(jail)
print('Исключения нового jail:',' '.join(ignore))
PY
  for name in filter jail global; do
    case "$name" in filter) dst="$BAN_FILTER" ;; jail) dst="$BAN_JAIL" ;; global) dst="$BAN_GLOBAL" ;; esac
    [[ ! -f "$dst" ]] || cp -a "$dst" "$BAN_BACKUP/$name.old"
  done
  BAN_CHANGED=1
  install -d -m 755 /etc/fail2ban/filter.d /etc/fail2ban/jail.d /etc/fail2ban/fail2ban.d
  install -m 644 "$BAN_BACKUP/filter.new.conf" "$BAN_FILTER"; install -m 644 "$BAN_BACKUP/jail.new" "$BAN_JAIL"
  printf '# VPS_COWRIE_BANS_MANAGED\n[Definition]\ndbpurgeage = %s\n' "$keep" > "$BAN_GLOBAL"; chmod 644 "$BAN_GLOBAL"
  fail2ban-client -t; fail2ban-client -d > "$BAN_BACKUP/config-dump.txt"
  python3 - "$BAN_BACKUP/config-dump.txt" "$keep" <<'PY'
import ast,sys
found=None
for line in open(sys.argv[1]):
    try:
        item=ast.literal_eval(line.strip())
    except (ValueError,SyntaxError):
        continue
    if isinstance(item,(list,tuple)) and len(item)>=3 and list(item[:2])==['set','dbpurgeage']:
        found=int(item[2])
if found is None or found<int(sys.argv[2]):
    raise SystemExit('Другой конфиг переопределяет dbpurgeage. Изменения отменяются.')
PY
  fail2ban-client reload; fail2ban-client set dbpurgeage "$keep" >/dev/null
  fail2ban-client status vps-cowrie-auth
  printf '#!/bin/bash\nexec /bin/bash %q --rollback-bans %q\n' "$SELF" "$BAN_BACKUP" > /root/rollback-cowrie-bans.sh
  chmod 700 /root/rollback-cowrie-bans.sh
  say "Баны Cowrie: $BAN_DAYS суток ($((BAN_DAYS*86400)) с), область=$BAN_SCOPE; история >= $keep с."
  say 'Статус: fail2ban-client status vps-cowrie-auth'
  say 'Разбан: fail2ban-client set vps-cowrie-auth unbanip IP'
  say "Backup банов: $BAN_BACKUP; откат: bash /root/rollback-cowrie-bans.sh"
}

ensure_bootstrap() {
  local missing=() c
  for c in python3 ssh-keygen; do
    if ! command -v "$c" >/dev/null 2>&1; then case "$c" in python3) missing+=(python3) ;; ssh-keygen) missing+=(openssh-client) ;; esac; fi
  done
  [[ -f /usr/share/zoneinfo/UTC ]] || missing+=(tzdata)
  if ((${#missing[@]})); then apt-get -o Acquire::Retries=3 update; DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"; fi
}
ensure_runtime_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install openssh-server openssh-client ufw fail2ban python3 python3-systemd util-linux iproute2 iptables procps kmod ca-certificates gnupg wget curl
}
check_grub_devices() {
  local devices='' device
  if ! dpkg-query -W -f='${Status}' grub-pc 2>/dev/null | grep -q 'install ok installed'; then return 0; fi
  devices="$(debconf-show grub-pc|sed -n 's/^[ *]*grub-pc\/install_devices: *//p')"
  local -a entries=(); IFS=',' read -r -a entries <<< "$devices"
  for device in "${entries[@]}"; do device="${device//[[:space:]]/}"; if [[ -n "$device" && ! -b "$device" ]]; then die "GRUB: отсутствует диск $device. Сначала исправьте загрузчик через консоль."; fi; done
}
base_setup() {
  local backup
  backup="$(mktemp -d "$STATE/base-backup.XXXXXXXX")"; cp -a /etc/fstab "$backup/fstab"
  [[ ! -f /etc/sysctl.d/99-vps-foundation.conf ]] || cp -a /etc/sysctl.d/99-vps-foundation.conf "$backup/sysctl.conf"
  [[ ! -f /etc/apt/sources.list.d/xanmod.sources ]] || cp -a /etc/apt/sources.list.d/xanmod.sources "$backup/xanmod.sources"
  [[ ! -f /etc/apt/keyrings/xanmod-archive-keyring.gpg ]] || cp -a /etc/apt/keyrings/xanmod-archive-keyring.gpg "$backup/xanmod-key.gpg"
  say "Базовый backup: $backup"; export DEBIAN_FRONTEND=noninteractive
  check_grub_devices; dpkg --configure -a; apt-get -o Acquire::Retries=3 update
  if [[ "$UPGRADE" == y ]]; then apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade; fi
  ensure_runtime_packages; apt-get install -y chrony tzdata
  if [[ "$HONEYPOT" == y ]]; then apt-get install -y python3-venv python3-dev libssl-dev libffi-dev build-essential; prepare_cowrie; fi
  timedatectl set-timezone "$TIMEZONE"; systemctl enable --now chrony.service; make_swap
  if [[ "$XANMOD" != none ]]; then install_xanmod; fi
  configure_network "$backup"
}
install_self() {
  local backup
  [[ -f "${BASH_SOURCE[0]}" ]] || die 'Сохраните скрипт в файл; pipe не поддерживается.'
  install -d -m700 "$STATE" "$STATE/transactions"
  if [[ "$(readlink -f -- "${BASH_SOURCE[0]}")" != "$SELF" ]]; then
    if [[ -f "$SELF" ]]; then backup="$(mktemp "$STATE/script-backup.XXXXXXXX")"; cp -a "$SELF" "$backup"; fi
    install -m700 -- "${BASH_SOURCE[0]}" "$SELF"
  else chmod 700 "$SELF"; fi
}
write_wrappers() {
  local f mode backup
  backup="$(mktemp -d "$STATE/commands-backup.XXXXXXXX")"
  for f in setup-ssh finalize-ssh rollback-ssh; do
    case "$f" in setup-ssh) mode=--resume-ssh ;; finalize-ssh) mode=--finalize ;; rollback-ssh) mode=--rollback ;; esac
    [[ ! -f "/root/$f.sh" ]] || cp -a "/root/$f.sh" "$backup/$f.sh"
    printf '#!/bin/bash\nexec /bin/bash %q %q "$@"\n' "$SELF" "$mode" > "/root/$f.sh"; chmod 700 "/root/$f.sh"
  done
}
configure_bans_only() {
  [[ ! -f "$ACTIVE" ]] || die 'Сначала завершите SSH-транзакцию и CONFIRM.'
  ensure_bootstrap; load_config; [[ "$HONEYPOT" == y ]] || die 'В сохранённых настройках Cowrie выключен.'
  systemctl is-active --quiet vps-cowrie.service || die 'Для этого режима Cowrie уже должен работать.'
  systemctl is-active --quiet fail2ban.service || die 'Fail2ban должен работать.'
  say 'Обновляются только собственные настройки банов/истории Fail2ban. SSH/ядро/TCP/Cowrie unit не перенастраиваются.'
  ask_bans
  local answer
  ask answer 'Применить выбранные настройки банов? Введите START' ''; [[ "$answer" == START ]] || return 0
  install_self; write_wrappers
  if [[ "$BANS" == y ]]; then install_bans; else say 'Существующий jail оставлен без изменений.'; fi
  save_config; BAN_CHANGED=0
  say "ГОТОВО, версия $APP_VERSION. Новые баны Cowrie: $BAN_DAYS суток при включённом jail."
}
resume_ssh() {
  [[ ! -f "$ACTIVE" ]] || die 'Есть незавершённая SSH-транзакция: завершите её или выполните --rollback.'
  check_legacy; ensure_bootstrap; load_config
  if [[ "$HONEYPOT" == y ]]; then
    check_cowrie_prepared
    if systemctl is-active --quiet vps-cowrie.service; then die 'Cowrie уже работает: для добавления банов используйте --configure-bans, а не повторный SSH.'; fi
  fi
  ask_bans
  local answer
  ask answer "Продолжить сохранённый SSH на $SSH_PORT? Введите START" ''; [[ "$answer" == START ]] || return 0
  install_self; write_wrappers; save_config
  apt-get -o Acquire::Retries=3 update; ensure_runtime_packages
  if [[ "$HONEYPOT" == y ]]; then write_cowrie_unit; cowrie_preflight; fi
  ASSUME_START=1; ssh_setup
}
section() { say ''; printf '\033[1;36m%s\033[0m\n' "$*"; }
ask_number() {
  local _nv="$1" _nm="$2" _nd="$3" _min="$4" _max="$5" _n=''
  while true; do
    ask _n "$_nm ($_min..$_max)" "$_nd"
    if [[ "$_n" =~ ^[0-9]{1,8}$ ]] && ((10#$_n >= _min && 10#$_n <= _max)); then printf -v "$_nv" '%s' "$((10#$_n))"; return; fi
    say 'Введите число в указанном диапазоне.'
  done
}
ask_port() {
  local _pn="$1" _pm="$2" _pd="$3" _port=''
  while true; do
    ask _port "$_pm" "$_pd"
    if valid_port "$_port" && ((10#$_port!=22 && 10#$_port!=80 && 10#$_port!=443)); then
      printf -v "$_pn" '%s' "$((10#$_port))"; return
    fi
    say 'Нужен порт 1..65535, кроме 22, 80 и 443.'
  done
}
ask_ip() {
  local _iv="$1" _im="$2" _id="${3:-}" _ip='' _normalized=''
  while true; do
    ask _ip "$_im (- — без IP)" "$_id"
    if [[ -z "$_ip" || "$_ip" == - ]]; then printf -v "$_iv" '%s' ''; return; fi
    if _normalized="$(valid_ip "$_ip" 2>/dev/null)"; then printf -v "$_iv" '%s' "$_normalized"; return; fi
    say 'Не удалось распознать IPv4/IPv6-адрес.'
  done
}
validate_extra_ports() {
  python3 - "$1" <<'PY'
import re,sys
items=sys.argv[1].split()
if len(items)>20:
    raise SystemExit('Не более 20 правил.')
for item in items:
    m=re.fullmatch(r'([0-9]{1,5})(?::([0-9]{1,5}))?/(tcp|udp)',item)
    if not m:
        raise SystemExit('Формат: 2053/tcp 8443/tcp 10000:10100/udp')
    a=int(m[1]); b=int(m[2] or m[1])
    if not 1<=a<=b<=65535 or a<=22<=b:
        raise SystemExit('Порты 1..65535; 22 управляется отдельно.')
PY
}
maintenance_defaults() {
  EXTRA_PORTS="${EXTRA_PORTS:-}"; CLEAN_DAYS="${CLEAN_DAYS:-14}"
  CLEAN_MIB="${CLEAN_MIB:-1024}"; MIN_FREE_MIB="${MIN_FREE_MIB:-512}"
  local n
  for n in CLEAN_DAYS CLEAN_MIB MIN_FREE_MIB; do
    [[ "${!n}" =~ ^[0-9]{1,8}$ ]] || die "Некорректный $n."
    printf -v "$n" '%s' "$((10#${!n}))"
  done
  ((CLEAN_DAYS>=2 && CLEAN_DAYS<=365 && CLEAN_MIB>=128 && CLEAN_MIB<=65536 && MIN_FREE_MIB>=128 && MIN_FREE_MIB<=65536)) || die 'Параметры обслуживания вне диапазона.'
  validate_extra_ports "$EXTRA_PORTS"
}
apply_extra_ports() {
  local port; local -a items=()
  validate_extra_ports "$EXTRA_PORTS"
  read -r -a items <<< "$EXTRA_PORTS" || true
  for port in "${items[@]}"; do ufw allow "$port" comment 'vps-foundation application'; done
}
ufw_temporary_allow() {
  local port="$1" label="$2" added
  added="$(ufw show added)"
  # Preserve existing universal rules and their comments instead of relabelling them.
  if python3 - "$added" "$port" <<'PYUFW'
import shlex,sys
for line in sys.argv[1].splitlines():
    try: args=shlex.split(line)
    except ValueError: continue
    if 'comment' in args: args=args[:args.index('comment')]
    if args in (['ufw','allow',sys.argv[2]],['ufw','allow',sys.argv[2].split('/')[0]]):
        raise SystemExit(0)
raise SystemExit(1)
PYUFW
  then say "Существующее разрешение $port сохранено."
  else ufw_first allow "$port" comment "$label"; fi
}
remove_temporary_rules() {
  # Delete only our labelled fallback rules, in descending numeric order.
  python3 - <<'PY'
import re,subprocess
output=subprocess.check_output(['ufw','status','numbered'],text=True)
ids=[]
for line in output.splitlines():
    m=re.match(r'^\[\s*(\d+)\]\s+.*#\s*vps-foundation (?:fallback|previous SSH)\s*$',line)
    if m: ids.append(int(m[1]))
for n in sorted(set(ids),reverse=True):
    subprocess.run(['ufw','--force','delete',str(n)],check=True)
PY
}
install_maintenance_helpers() {
  maintenance_defaults
  install -d -m755 "$HELPERS"
  cat > "$HELPERS/firewall-check" <<'GUARD'
#!/bin/bash
set -euo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
if [[ "${1:-}" == --enforce ]]; then systemctl is-active --quiet vps-cowrie.service || exit 0; fi
if ! python3 - <<'PY'
from pathlib import Path
import pwd,subprocess,shlex
uid=str(pwd.getpwnam('vps-cowrie').pw_uid)
if 'ENABLED=yes' not in Path('/etc/ufw/ufw.conf').read_text().splitlines():
    raise SystemExit('UFW выключен в конфигурации.')
status=subprocess.check_output(['ufw','status'],text=True)
if not status.startswith('Status: active'):
    raise SystemExit('UFW не активен.')
commands=['iptables']
if Path('/proc/net/if_inet6').exists() and 'IPV6=yes' in Path('/etc/default/ufw').read_text().splitlines():
    commands.append('ip6tables')
for cmd in commands:
    chain='ufw6-before-output' if cmd=='ip6tables' else 'ufw-before-output'
    subprocess.run([cmd,'-w','5','-C','OUTPUT','-j',chain],check=True)
    rules=subprocess.check_output([cmd,'-w','5','-S',chain],text=True).splitlines()
    rules=[shlex.split(r) for r in rules if r.startswith('-A ')]
    expected1=['-A',chain,'-m','owner','--uid-owner',uid,'-m','conntrack','--ctstate','ESTABLISHED,RELATED','-j','ACCEPT']
    expected2=['-A',chain,'-m','owner','--uid-owner',uid,'-j','REJECT']
    def normalize(r):
        if '--ctstate' in r:
            i=r.index('--ctstate')+1; r[i]=','.join(sorted(r[i].split(',')))
        if '--reject-with' in r:
            i=r.index('--reject-with'); del r[i:i+2]
        return r
    if len(rules)<2 or normalize(rules[0])!=normalize(expected1) or normalize(rules[1])!=expected2:
        raise SystemExit(cmd+': защитные правила Cowrie отсутствуют или стоят не первыми.')
print('UFW и запрет исходящих Cowrie: OK')
PY
then
  logger -t vps-foundation 'Cowrie firewall check failed' || true
  if [[ "${1:-}" == --enforce ]]; then systemctl stop vps-cowrie.service; fi
  exit 1
fi
GUARD
  cat > "$HELPERS/cleanup.py" <<'PY'
#!/usr/bin/python3
"""Runs as vps-cowrie; never walks SSH host keys or arbitrary /var/lib files."""
import json,os,stat,time,shutil
from pathlib import Path
policy=json.loads(Path('/etc/vps-cowrie-maintenance.json').read_text())
days=int(policy['days']); cap=int(policy['mib'])*1024**2; reserve=int(policy['free_mib'])*1024**2
if not (2<=days<=365 and 128*1024**2<=cap<=65536*1024**2 and 128*1024**2<=reserve<=65536*1024**2):
    raise SystemExit('Invalid maintenance policy')
base=Path('/var/lib/vps-cowrie/var'); now=time.time(); total=0; files=[]
# Each entry holds a pathname; no elevated privileges are used when unlinking it.
for root in (base/'log/cowrie',base/'lib/cowrie/tty',base/'lib/cowrie/downloads'):
    if root.is_symlink():
        raise SystemExit('Refusing symlink: '+str(root))
    if not root.is_dir(): continue
    for directory,dirs,names in os.walk(root,followlinks=False):
        dirs[:]=[d for d in dirs if not Path(directory,d).is_symlink()]
        for name in names:
            path=Path(directory,name)
            try: info=path.lstat()
            except FileNotFoundError: continue
            if not stat.S_ISREG(info.st_mode): continue
            total+=info.st_size
            protected=name in ('cowrie.log','cowrie.json') or info.st_mtime>now-86400
            files.append((info.st_mtime,info.st_size,path,protected))
removed=0
for mtime,size,path,protected in sorted(files):
    free=shutil.disk_usage(base).free
    if protected or not (mtime<now-days*86400 or total>cap or free<reserve): continue
    try: path.unlink()
    except FileNotFoundError: continue
    total-=size; removed+=1
free=shutil.disk_usage(base).free
print(f'Cowrie: deleted={removed}, remaining={total//1024**2} MiB, free={free//1024**2} MiB')
if total>cap or free<reserve:
    raise SystemExit('Cowrie stopped: protected/recent files or low disk space; inspect logs before restarting.')
PY
  cat > "$HELPERS/cleanup" <<'CLEAN'
#!/bin/bash
set -euo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
if ! runuser -u vps-cowrie -- python3 /usr/local/libexec/vps-foundation/cleanup.py; then
  logger -t vps-foundation 'Cowrie maintenance failed or disk threshold reached; stopping Cowrie' || true
  systemctl stop vps-cowrie.service
  exit 1
fi
CLEAN
  chown root:root "$HELPERS/firewall-check" "$HELPERS/cleanup" "$HELPERS/cleanup.py"
  chmod 755 "$HELPERS/firewall-check" "$HELPERS/cleanup" "$HELPERS/cleanup.py"
  python3 - "$CLEAN_DAYS" "$CLEAN_MIB" "$MIN_FREE_MIB" <<'PY'
import json,os,sys,tempfile
fd,tmp=tempfile.mkstemp(dir='/etc',prefix='.vps-cowrie-policy-')
try:
    with os.fdopen(fd,'w') as f:
        json.dump(dict(zip(('days','mib','free_mib'),map(int,sys.argv[1:]))),f)
    os.chmod(tmp,0o644); os.replace(tmp,'/etc/vps-cowrie-maintenance.json')
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
  cat > /etc/systemd/system/vps-cowrie-firewall-guard.service <<EOF
[Unit]
Description=Check Cowrie firewall and stop on protection loss
[Service]
Type=oneshot
ExecStart=/bin/bash $HELPERS/firewall-check --enforce
TimeoutStartSec=30
EOF
  cat > "/etc/systemd/system/$GUARD_TIMER" <<'EOF'
[Unit]
Description=Check Cowrie firewall every 30 seconds
[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=1s
[Install]
WantedBy=timers.target
EOF
  cat > /etc/systemd/system/vps-cowrie-maintenance.service <<EOF
[Unit]
Description=Prune old Cowrie recordings and enforce disk thresholds
[Service]
Type=oneshot
ExecStart=/bin/bash $HELPERS/cleanup
TimeoutStartSec=120
Nice=10
EOF
  cat > "/etc/systemd/system/$CLEAN_TIMER" <<'EOF'
[Unit]
Description=Maintain Cowrie recordings every 5 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=10s
[Install]
WantedBy=timers.target
EOF
  chmod 644 /etc/systemd/system/vps-cowrie-{firewall-guard,maintenance}.{service,timer}
  systemctl daemon-reload
}
setup_maintenance() {
  [[ ! -f "$ACTIVE" ]] || die 'Сначала подтвердите SSH или выполните откат.'
  ensure_bootstrap; load_config; check_cowrie_prepared
  [[ "$HONEYPOT" == y ]] || die 'Cowrie выключен в настройках.'
  section 'Обслуживание Cowrie'
  say 'Будут добавлены проверка firewall, таймеры и очистка старых журналов/записей.'
  say 'Ключи SSH Cowrie сохраняются; файлы моложе суток не удаляются.'
  ask_number CLEAN_DAYS 'Хранить записи, дней' "$CLEAN_DAYS" 2 365
  ask_number CLEAN_MIB 'Целевой общий объём журналов/tty/downloads, MiB' "$CLEAN_MIB" 128 65536
  ask_number MIN_FREE_MIB 'Оставлять свободно на диске, MiB' "$MIN_FREE_MIB" 128 65536
  say 'Проверка диска — раз в 5 минут. Если безопасно освободить место нельзя, Cowrie останавливается.'
  say 'Защитные проверки ставятся без перезапуска работающего Cowrie.'
  local answer; ask answer 'Применить политику очистки и защиту? Введите START' ''
  [[ "$answer" == START ]] || return 0
  # Verify current UFW rules before enabling the watchdog against a working instance.
  install_self; install_maintenance_helpers; "$HELPERS/firewall-check"
  install -d -m755 /etc/systemd/system/vps-cowrie.service.d
  cat > /etc/systemd/system/vps-cowrie.service.d/20-vps-protection.conf <<EOF
[Unit]
BindsTo=ufw.service
After=ufw.service
[Service]
ExecStartPre=+/bin/bash $HELPERS/firewall-check
EOF
  chmod 644 /etc/systemd/system/vps-cowrie.service.d/20-vps-protection.conf
  save_config; systemctl daemon-reload
  systemctl enable --now "$GUARD_TIMER" "$CLEAN_TIMER" >/dev/null
  say 'Защитные проверки и обслуживание включены.'
}
show_status() {
  section "VPS Foundation $APP_VERSION — состояние"
  say "ОС: ${PRETTY_NAME:-unknown}; ядро: $(uname -r)"
  say "RAM: $(free -h | awk '/^Mem:/ {print $2}'); swap: $(free -h | awk '/^Swap:/ {print $2}')"
  df -h /; say ''
  local u
  for u in ssh.service ssh.socket vps-cowrie.service fail2ban.service "$TIMER" "$GUARD_TIMER" "$CLEAN_TIMER"; do
    printf '%-38s %s\n' "$u" "$(unit_active "$u")"
  done
  if [[ -f "$ACTIVE" ]]; then
    say 'ВНИМАНИЕ: SSH ещё не подтверждён. Проверьте таймер, завершите финализацию или выполните откат.'
    systemctl list-timers "$TIMER" --no-pager || true
  fi
  if command -v ufw >/dev/null; then ufw status verbose || true; fi
  if command -v ss >/dev/null; then ss -lntup || true; fi
  if command -v fail2ban-client >/dev/null && systemctl is-active --quiet fail2ban.service; then fail2ban-client status vps-cowrie-auth || true; fi
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true
}
check_health() {
  local failed=0
  section 'Диагностика (без изменения настроек)'
  if [[ -x /usr/sbin/sshd ]]; then /usr/sbin/sshd -t || failed=1; else say 'sshd не установлен.'; failed=1; fi
  if command -v fail2ban-client >/dev/null; then fail2ban-client -t || failed=1; fi
  if systemctl is-active --quiet vps-cowrie.service; then
    cowrie_listener_ok || { say 'Не пройдена проверка баннера Cowrie.'; failed=1; }
    if [[ -x "$HELPERS/firewall-check" ]]; then "$HELPERS/firewall-check" || failed=1
    else say 'Проверки firewall новой версии ещё не установлены; используйте --setup-maintenance.'; fi
  fi
  df -h /; systemctl --failed --no-pager || true
  if ((failed)); then say 'Найдены проблемы; смотрите вывод выше.'; return 1; fi
  say 'Доступные проверки пройдены. Внешнюю доступность панели проверьте с клиента.'
}
show_logs() {
  local which
  say '1) Cowrie; 2) настоящий SSH; 3) Fail2ban; 4) очистка/контроль firewall'
  ask which 'Журнал' 1
  case "$which" in
    1) journalctl -u vps-cowrie.service -n80 --no-pager -o cat ;;
    2) journalctl -u ssh.service -n80 --no-pager -o cat ;;
    3) journalctl -u fail2ban.service -n80 --no-pager -o cat ;;
    4) journalctl -u vps-cowrie-maintenance.service -u vps-cowrie-firewall-guard.service -n80 --no-pager -o cat ;;
    *) say 'Неверный выбор.' ;;
  esac
}
unban_ip() {
  local ip answer jail
  need python3; need fail2ban-client
  ask_ip ip 'Какой IP разблокировать' ''; [[ -n "$ip" ]] || return 0
  say '1) Cowrie; 2) настоящий SSH'
  ask jail 'Jail' 1
  case "$jail" in 1) jail=vps-cowrie-auth ;; 2) jail=sshd ;; *) die 'Выберите 1 или 2.' ;; esac
  ask answer "Разблокировать $ip в $jail? Введите UNBAN" ''
  [[ "$answer" == UNBAN ]] || return 0
  fail2ban-client set "$jail" unbanip "$ip"
}
disable_bans() {
  [[ ! -f "$ACTIVE" ]] || die 'Сначала завершите SSH-транзакцию.'
  load_config; local answer
  [[ -f "$BAN_JAIL" ]] || { say 'Управляемый jail отсутствует.'; return; }
  grep -Fq 'VPS_COWRIE_BANS_MANAGED' "$BAN_JAIL" || die 'Файл jail не принадлежит этому скрипту.'
  say 'Будет отключён только jail Cowrie. Его действующие баны будут сняты.'
  ask answer 'Отключить баны Cowrie? Введите DISABLE' ''; [[ "$answer" == DISABLE ]] || return 0
  BAN_BACKUP="$(mktemp -d "$STATE/bans-backup.XXXXXXXX")"
  local name dst
  for name in filter jail global; do
    case "$name" in filter) dst="$BAN_FILTER" ;; jail) dst="$BAN_JAIL" ;; global) dst="$BAN_GLOBAL" ;; esac
    [[ ! -f "$dst" ]] || cp -a "$dst" "$BAN_BACKUP/$name.old"
  done
  fail2ban-client get dbpurgeage > "$BAN_BACKUP/retention.old"
  BAN_CHANGED=1
  printf '# VPS_COWRIE_BANS_MANAGED\n[vps-cowrie-auth]\nenabled = false\n' > "$BAN_JAIL"
  fail2ban-client -t; fail2ban-client reload
  BANS=n; save_config; BAN_CHANGED=0
  say "Баны отключены. Backup: $BAN_BACKUP"
}
main() {
  [[ ! -f "$ACTIVE" ]] || die 'Есть незавершённая SSH-транзакция: выберите финализацию или откат.'
  check_legacy
  if systemctl is-active --quiet vps-cowrie.service; then die 'Cowrie уже работает. Используйте меню банов/обслуживания.'; fi
  section "VPS Foundation $APP_VERSION — мастер установки"
  say 'Сохраните snapshot и проверьте консоль провайдера. Панель 3x-ui устанавливается отдельно.'
  say 'После вопросов будут показаны настройки. Основные изменения начнутся после START.'
  say 'При отсутствии Python/ssh-keygen сначала потребуется установка минимальных зависимостей.'
  local answer mode detected='' input choice panel=''
  if [[ -f "$CONFIG" ]]; then
    say 'Найдены сохранённые настройки. Для продолжения неудачной установки есть --resume-ssh.'
    ask answer 'Начать ПОЛНУЮ настройку заново? Введите FULL' ''; [[ "$answer" == FULL ]] || return 0
  fi
  if ! command -v python3 >/dev/null || ! command -v ssh-keygen >/dev/null; then
    ask answer 'Установить минимальные зависимости для проверки ввода? Введите TOOLS' ''
    [[ "$answer" == TOOLS ]] || return 0
  fi
  ensure_bootstrap
  say '1) Простой мастер; 2) расширенные параметры'
  ask mode 'Режим' 1; [[ "$mode" == 1 || "$mode" == 2 ]] || die 'Выберите 1 или 2.'
  section '1/5 — доступ SSH'
  ask_port SSH_PORT 'Новый SSH-порт' 45123
  KEY_ONLY=y; SSH_PUBLIC_KEY=''
  if [[ "$mode" == 2 ]]; then yesno KEY_ONLY 'Настоящий root SSH только по ключу' y; fi
  if [[ "$KEY_ONLY" == y ]]; then
    while true; do
      ask input 'Публичный ключ одной строкой либо путь к файлу' ''
      if [[ -f "$input" ]]; then SSH_PUBLIC_KEY="$(cat -- "$input")"; else SSH_PUBLIC_KEY="$input"; fi
      # Invalid input is checked in a separate process so it cannot abort this wizard.
      if (check_key "$SSH_PUBLIC_KEY"); then break; fi
      say 'Повторите ввод публичного ключа.'
    done
  else
    [[ "$(passwd -S root | awk '{print $2}')" == P ]] || die 'У root нет активного пароля: выберите ключ.'
  fi
  if [[ -n "${SSH_CONNECTION:-}" ]]; then detected="${SSH_CONNECTION%% *}"; fi
  ask_ip WHITELIST_IP 'IP администратора для исключений Fail2ban' "$detected"
  section '2/5 — Cowrie и баны'
  yesno HONEYPOT 'Включить Cowrie на 22/tcp IPv4' y; LOG_PORT22=n
  BANS=y; BAN_DAYS=30; BAN_RETRIES=3; BAN_WINDOW=600; BAN_SCOPE=1; BAN_EXTRA_IP=''
  if [[ "$HONEYPOT" == y ]]; then
    say 'По умолчанию: бан на 30 суток после 3 авторизаций за 10 минут, только на 22/tcp.'
    if [[ "$mode" == 2 ]]; then ask_bans; fi
  else
    BANS=n
    if [[ "$mode" == 2 ]]; then yesno LOG_PORT22 'Логировать SYN на закрытом 22' n; fi
  fi
  section '3/5 — панель и входящие порты'
  while true; do
    ask panel 'Порт панели 3x-ui TCP (ENTER — не открывать)' ''
    [[ -z "$panel" ]] && break
    if valid_port "$panel" && ((10#$panel!=22 && 10#$panel!=SSH_PORT)); then panel="$((10#$panel))/tcp"; break; fi
    say 'Некорректный порт панели или совпадение с SSH.'
  done
  while true; do
    ask EXTRA_PORTS 'Другие порты через пробел, например 8443/tcp 10000:10100/udp' ''
    if validate_extra_ports "$EXTRA_PORTS"; then break; fi
  done
  EXTRA_PORTS="${panel}${panel:+ }$EXTRA_PORTS"
  section '4/5 — система'
  SWAP_SIZE_GB=2; TIMEZONE=Asia/Yekaterinburg; UPGRADE=y; XANMOD=none; XANMOD_LEVEL=2
  TCP_PROFILE=balanced; BBR=y; FORWARD=n; CLEAN_DAYS=14; CLEAN_MIB=1024; MIN_FREE_MIB=512
  if [[ "$mode" == 2 ]]; then
    ask_number SWAP_SIZE_GB 'Swap GiB (0 — не создавать)' 2 0 64
    while true; do
      ask TIMEZONE 'Часовой пояс' Asia/Yekaterinburg
      if [[ "$TIMEZONE" =~ ^[A-Za-z0-9_+/-]+$ && "$TIMEZONE" != /* && "$TIMEZONE" != *..* && -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then break; fi
      say 'Часовой пояс не найден.'
    done
    yesno UPGRADE 'Обновить установленные пакеты' y
    say 'Ядро: 0) штатное; 1) XanMod LTS; 2) XanMod MAIN'
    ask choice 'Ядро' 0
    case "$choice" in 0) ;; 1) XANMOD=lts ;; 2) XANMOD=main ;; *) die 'Выберите 0/1/2.' ;; esac
    if [[ "$XANMOD" != none ]]; then ask_number XANMOD_LEVEL 'CPU x64v2/x64v3' 2 2 3; fi
    say 'TCP: 0) не менять; 1) balanced; 2) throughput'
    ask choice 'Профиль' 1
    case "$choice" in 0) TCP_PROFILE=off ;; 1) TCP_PROFILE=balanced ;; 2) TCP_PROFILE=throughput ;; *) die 'Выберите 0/1/2.' ;; esac
    yesno BBR 'Включить BBR, если доступен' y
    yesno FORWARD 'Включить IPv4 forwarding (без NAT)' n
    if [[ "$HONEYPOT" == y ]]; then
      ask_number CLEAN_DAYS 'Хранить записи Cowrie, дней' 14 2 365
      ask_number CLEAN_MIB 'Целевой объём записей Cowrie, MiB' 1024 128 65536
    fi
  fi
  if [[ "$HONEYPOT" == y ]]; then
    python3 -c 'import sys; sys.exit(sys.version_info < (3,10))' || die 'Для Cowrie нужен Python 3.10+.'
  fi
  maintenance_defaults
  section '5/5 — проверьте перед применением'
  printf 'SSH: %s; только ключ: %s; whitelist: %s\n' "$SSH_PORT" "$KEY_ONLY" "${WHITELIST_IP:-нет}"
  printf 'Cowrie: %s; баны: %s; суток: %s; область: %s\n' "$HONEYPOT" "$BANS" "$BAN_DAYS" "$BAN_SCOPE"
  printf 'Порты приложений: %s; также 80/tcp, 443/tcp, 443/udp\n' "${EXTRA_PORTS:-нет}"
  printf 'Swap: %s GiB; TZ: %s; apt upgrade: %s\n' "$SWAP_SIZE_GB" "$TIMEZONE" "$UPGRADE"
  printf 'Ядро: %s/x64v%s; TCP: %s; BBR: %s\n' "$XANMOD" "$XANMOD_LEVEL" "$TCP_PROFILE" "$BBR"
  printf 'Записи Cowrie: %s дней, целевой объём %s MiB; свободно минимум %s MiB\n' "$CLEAN_DAYS" "$CLEAN_MIB" "$MIN_FREE_MIB"
  say 'Автооткат защищает SSH/UFW/Fail2ban. Пакеты, ядро, swap и TCP в него не входят.'
  say 'Откройте новый SSH-порт также в firewall провайдера. Автоматической перезагрузки нет.'
  ask answer 'Применить эти настройки? Введите START' ''; [[ "$answer" == START ]] || return 0
  install_self; write_wrappers; save_config
  section 'Подготовка системы, пакетов и Cowrie'
  base_setup
  section 'Перенос SSH с автоматическим откатом'
  ASSUME_START=1; ssh_setup
}
menu() {
  local choice mode source_path="${BASH_SOURCE[0]}"
  open_tty
  while true; do
    section "VPS Foundation $APP_VERSION"
    if [[ -f "$ACTIVE" ]]; then say 'Есть неподтверждённая смена SSH! Доступны финализация и откат.'; fi
    say ' 1) Установить / настроить VPS'
    say ' 2) Продолжить подготовленную настройку SSH'
    say ' 3) Финализировать SSH из нового подключения'
    say ' 4) Настроить баны Cowrie'
    say ' 5) Состояние служб и портов'
    say ' 6) Проверить конфигурации и защиту'
    say ' 7) Посмотреть журналы'
    say ' 8) Разблокировать IP'
    say ' 9) Настроить очистку и контроль firewall Cowrie'
    say '10) Отключить баны Cowrie'
    say '11) Откатить неподтверждённую смену SSH'
    say ' 0) Выход'
    ask choice 'Действие' 5
    case "$choice" in
      1) mode=--install ;; 2) mode=--resume-ssh ;; 3) mode=--finalize ;; 4) mode=--configure-bans ;;
      5) mode=--status ;; 6) mode=--check ;; 7) mode=--logs ;; 8) mode=--unban ;;
      9) mode=--setup-maintenance ;; 10) mode=--disable-bans ;;
      11) ask choice 'Вернуть прежние SSH/UFW/Fail2ban? Введите ROLLBACK' ''
          [[ "$choice" == ROLLBACK ]] || continue; mode=--rollback ;;
      0) return 0 ;; *) say 'Выберите пункт меню.'; continue ;;
    esac
    # Subprocess isolation keeps ERR handling active in the operation, even if it fails.
    if bash "$source_path" "$mode"; then :; else say 'Действие завершилось с ошибкой. Смотрите сообщение выше.'; fi
    ask choice 'ENTER — вернуться в меню' ''
  done
}
usage() {
  say "VPS Foundation $APP_VERSION — Debian/Ubuntu + systemd; запуск от root"
  say 'Без аргументов: интерактивное меню. --install: мастер установки.'
  say '--status | --check | --logs | --unban | --setup-maintenance'
  say '--configure-bans | --disable-bans | --resume-ssh'
  say '--finalize: второй этап SSH. --confirm CODE: проверка из ещё одной новой сессии.'
  say '--rollback: откат активной SSH-транзакции.'
  say '--rollback-bans /var/lib/vps-foundation/bans-backup.XXXXXXXX'
  say 'GitHub: сначала скачать в файл, затем bash -n и bash; команда есть в инструкции.'
}
# VPS_FOUNDATION_ENTRYPOINT
case "${1:-}" in
  --version) say "VPS Foundation $APP_VERSION"; exit 0 ;;
  --help|-h) usage; exit 0 ;;
esac
[[ $EUID == 0 ]] || die 'Запустите от root (sudo -i).'
need apt-get; need systemctl
[[ -d /run/systemd/system && -f /etc/os-release ]] || die 'Нужны Debian/Ubuntu с systemd.'
source /etc/os-release
[[ "${ID:-}" == debian || "${ID:-}" == ubuntu ]] || die 'Поддерживаются Debian/Ubuntu.'
CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
[[ -f "${BASH_SOURCE[0]}" ]] || die 'Сначала скачайте скрипт в файл. Используйте команду из инструкции.'
case "${1:-}" in
  ''|--menu) menu; exit 0 ;;
  --status) show_status; exit 0 ;;
  --check) check_health; exit $? ;;
  --logs) show_logs; exit 0 ;;
esac
case "${1:-}" in
  --install|--configure-bans|--disable-bans|--resume-ssh|--ssh-setup|--finalize|--confirm|--rollback|--rollback-bans|--setup-maintenance|--unban) ;;
  *) die 'Неизвестный аргумент; используйте --help.' ;;
esac
if ! command -v flock >/dev/null 2>&1; then
  say 'Для блокировки параллельных запусков нужен util-linux. Установите: apt-get install util-linux'
  exit 1
fi
exec 9>/run/vps-foundation.lock
flock -w120 9 || die 'Другой экземпляр держит блокировку.'
case "${1:-}" in
  --install) main ;;
  --configure-bans) configure_bans_only ;;
  --disable-bans) disable_bans ;;
  --resume-ssh|--ssh-setup) resume_ssh ;;
  --finalize) finalize ;;
  --confirm) confirm_ssh "${2:-}" ;;
  --rollback) if read_active; then restore_ssh; else say 'Нет активной SSH-транзакции.'; fi ;;
  --rollback-bans)
    [[ ! -f "$ACTIVE" ]] || die 'Сначала завершите активную SSH-транзакцию.'
    BAN_BACKUP="${2:-}"
    [[ "$BAN_BACKUP" == "$STATE"/bans-backup.* && -d "$BAN_BACKUP" && -f "$BAN_BACKUP/retention.old" ]] || die 'Некорректный backup банов.'
    restore_bans ;;
  --setup-maintenance) setup_maintenance ;;
  --unban) unban_ip ;;
esac

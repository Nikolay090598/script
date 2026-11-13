#!/bin/bash
# OpenWrt HomeStack 3.8 (NanoPi R76S / sbwml OpenWrt 25.x + apk)
# Возможности:
#   - До ребута (пункт 1): разметка SD-карты (f2fs), проверка переноса /overlay, запись fstab
#   - После ребута (пункт 2+): USB-драйверы (хаб/UAS/AX88179), btop, все темы + Proton 2025, RU, тюнинг (без конфликта с Shortcut-FE и Docker Root), Samba4 (root), banIP
#   - Принятие существующих контейнеров (пункт 20), атомарное обновление (пункт 12), бэкап/восстановление по RepoDigests (пункты 17-18)
set -Eeuo pipefail
umask 077

SELF=$(readlink -f "$0")
STATE=/etc/homestack.conf
declare -a RUN_EXTRA_ARGS=()

# --- Базовые значения по умолчанию ---
BASE=/opt/homestack
DOCKER_ROOT=/overlay/docker
HDD_MOUNT=/mnt/sda1
HDD_UUID=''
TZ_ZONE='Asia/Yekaterinburg'
TZ_STR='YEKT-5'
NTP_SERVER='ntp.ix.ru'

LAN=192.168.2.1
PC_IP=192.168.2.3
WAN=wan
WAN_PROTO='dhcp'
PPPOE_USER=''
PPPOE_PASS=''
WAN_STATIC_IP=''
WAN_STATIC_GW=''
WAN_STATIC_DNS='77.88.8.8 77.88.8.1'
WAN_MAC='0A:50:17:D7:61:A2'
LAN_MAC='0A:50:17:D7:61:A3'
USE_ONT='yes'
ONT_IP='192.168.101.2'
USE_USB_ETH2='yes'

ENDPOINT='136.169.254.11'
EMAIL=''
OWNER=''
SERVER='192.168.2.1:9987'

BOT_IMAGE='ghcr.io/cookiecr2nk/ts3audiobot-docker:main'
TS_IMAGE='teamspeaksystems/teamspeak6-server:latest'
MM_IMAGE='mumblevoip/mumble-server:latest'
RD_IMAGE='rustdesk/rustdesk-server:latest'
TOR_IMAGE='ghcr.io/yourok/torrserver:latest'
BES_IMAGE='henrygd/beszel:latest'
CADDY_IMAGE='caddy:2-alpine'
BOT='ts3audiobot-test'
TOR_MODE=''

msg() { printf '\n%s\n' "$*"; }
confirm() {
  local a
  read -r -p "$* [yes/нет]: " a
  a=$(printf '%s' "$a" | tr -d ' \t\r\n')
  [[ ${a,,} == yes || ${a,,} == да ]]
}
ask() {
  local k=$1 v
  read -r -p "$2 [${!k}] (введите '-' чтобы очистить): " v
  if [[ $v == '-' ]]; then
    printf -v "$k" '%s' ''
  elif [[ -n $v ]]; then
    printf -v "$k" '%s' "$v"
  fi
}
secret() {
  local k=$1 v
  read -r -s -p "$2: " v; echo
  [[ $v =~ ^[A-Za-z0-9_@%+=.,!-]{16,64}$ ]] || { msg 'Нужно 16–64 ASCII-символов: буквы, цифры, _ @ % + = . , ! -'; return 1; }
  printf -v "$k" '%s' "$v"
}

# Атомарное чтение конфигурации по белому списку ключей
load_conf_safe() {
  local file=$1 line key raw val inner tmp us=$'\x1f'
  local -a parsed_keys=() parsed_vals=()
  local lineno=0 i ch nxt
  [[ -f $file ]] || return 1

  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    [[ -z $line || $line == \#* ]] && continue
    if [[ ! $line =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
      msg "Ошибка формата конфигурации $file в строке $lineno."
      return 1
    fi
    key=${BASH_REMATCH[1]}
    raw=${BASH_REMATCH[2]}
    case $key in
      BASE|DOCKER_ROOT|HDD_MOUNT|HDD_UUID|TZ_ZONE|TZ_STR|NTP_SERVER|LAN|PC_IP|WAN|WAN_PROTO|PPPOE_USER|PPPOE_PASS|WAN_STATIC_IP|WAN_STATIC_GW|WAN_STATIC_DNS|WAN_MAC|LAN_MAC|USE_ONT|ONT_IP|USE_USB_ETH2|ENDPOINT|EMAIL|OWNER|SERVER|BOT_IMAGE|TS_IMAGE|MM_IMAGE|RD_IMAGE|TOR_IMAGE|BES_IMAGE|CADDY_IMAGE|BOT|TOR_MODE)
        ;;
      *)
        msg "Неизвестный ключ '$key' в конфигурации $file (строка $lineno)."
        return 1 ;;
    esac

    if [[ $raw == "''" || -z $raw ]]; then
      val=''
    elif [[ ${#raw} -ge 2 && ${raw:0:1} == "'" && ${raw: -1} == "'" ]]; then
      inner=${raw:1:${#raw}-2}
      tmp=${inner//\'\\\'\'/$us}
      if [[ $tmp == *"'"* ]]; then
        msg "Некорректное экранирование кавычек для ключа $key в $file (строка $lineno)."
        return 1
      fi
      val=${tmp//$us/\'}
    elif [[ $raw =~ ^\$\'([^\'\\]|\\.)*\'$ ]]; then
      inner=${raw:2:${#raw}-3}
      printf -v val '%b' "$inner"
    elif [[ $raw =~ ^([A-Za-z0-9_./:@%+=-]|\\[^[:cntrl:]])*$ ]]; then
      val=''
      i=0
      while (( i < ${#raw} )); do
        ch=${raw:i:1}
        if [[ $ch == '\' ]]; then
          i=$((i + 1))
          nxt=${raw:i:1}
          val+="$nxt"
        else
          val+="$ch"
        fi
        i=$((i + 1))
      done
    else
      msg "Недопустимое значение для ключа $key в $file (строка $lineno)."
      return 1
    fi

    parsed_keys+=("$key")
    parsed_vals+=("$val")
  done < "$file"

  for i in "${!parsed_keys[@]}"; do
    printf -v "${parsed_keys[$i]}" '%s' "${parsed_vals[$i]}"
  done
}

[[ ! -f $STATE ]] || load_conf_safe "$STATE"
[[ $(id -u) == 0 ]] || { echo 'Нужен root.'; exit 1; }
trap 'echo "Ошибка в строке $LINENO. Выполнение остановлено; проверьте вывод выше." >&2' ERR

valid_ipv4() {
  local ip=$1 o1 o2 o3 o4
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  o1=${BASH_REMATCH[1]}; o2=${BASH_REMATCH[2]}; o3=${BASH_REMATCH[3]}; o4=${BASH_REMATCH[4]}
  (( 10#$o1 <= 255 && 10#$o2 <= 255 && 10#$o3 <= 255 && 10#$o4 <= 255 ))
}

# Пошаговая канонизация пути с разрешением симлинков на каждом уровне
normalize_path() {
  local p=$1
  [[ -n $p && $p == /* && $p != *$'\n'* ]] || return 1
  local IFS='/' parts=() cur='/' part
  read -ra parts <<< "$p"
  for part in "${parts[@]}"; do
    [[ -z $part || $part == '.' ]] && continue
    if [[ $part == '..' ]]; then
      [[ $cur == '/' ]] || cur=$(dirname "$cur")
    else
      [[ $cur == '/' ]] && cur="/$part" || cur="$cur/$part"
    fi
    if [[ -e $cur || -L $cur ]]; then
      cur=$(readlink -f "$cur") || return 1
    fi
  done
  printf '%s\n' "$cur"
}

safe_path() {
  local raw=$1 p
  [[ -n $raw && $raw == /* && $raw != *'/..'* && $raw != *'/.'* && $raw != *' '* ]] || return 1
  p=$(normalize_path "$raw") || return 1
  case $p in
    /|/bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/lib|/lib/*|/lib64|/lib64/*|/proc|/proc/*|/rom|/rom/*|/root|/root/*|/run|/run/*|/sbin|/sbin/*|/sys|/sys/*|/tmp|/tmp/*|/usr|/usr/*|/var|/var/*|/www|/www/*|/overlay|/overlay/*|/mnt|/opt)
      return 1 ;;
  esac
  return 0
}

paths_disjoint() {
  local a b
  a=$(normalize_path "$1") || return 1
  b=$(normalize_path "$2") || return 1
  [[ $a != "$b" && $a != "$b/"* && $b != "$a/"* ]]
}

validate_all_paths() {
  safe_path "$BASE" || { msg "Небезопасный путь BASE: '$BASE'"; return 1; }
  BASE=$(normalize_path "$BASE")
  # Разрешаем /overlay/docker (штатный корень Docker в сборках sbwml)
  if [[ $(normalize_path "$DOCKER_ROOT" 2>/dev/null || true) == '/overlay/docker' ]]; then
    DOCKER_ROOT='/overlay/docker'
  else
    safe_path "$DOCKER_ROOT" || { msg "Небезопасный путь DOCKER_ROOT: '$DOCKER_ROOT'"; return 1; }
    DOCKER_ROOT=$(normalize_path "$DOCKER_ROOT")
  fi
  paths_disjoint "$BASE" "$DOCKER_ROOT" || { msg 'BASE и DOCKER_ROOT не должны пересекаться.'; return 1; }
  if [[ -n $HDD_MOUNT ]]; then
    safe_path "$HDD_MOUNT" || { msg "Небезопасный путь HDD_MOUNT: '$HDD_MOUNT'"; return 1; }
    HDD_MOUNT=$(normalize_path "$HDD_MOUNT")
    paths_disjoint "$HDD_MOUNT" "$BASE" || { msg 'HDD_MOUNT и BASE не должны пересекаться.'; return 1; }
    paths_disjoint "$HDD_MOUNT" "$DOCKER_ROOT" || { msg 'HDD_MOUNT и DOCKER_ROOT не должны пересекаться.'; return 1; }
  fi
}

dev_majmin() {
  stat -Lc '%t:%T' "$1" 2>/dev/null || lsblk -ndo MAJ:MIN "$1" 2>/dev/null | xargs
}

save() {
  local k t val
  t=$(mktemp /etc/homestack.XXXXXX)
  for k in BASE DOCKER_ROOT HDD_MOUNT HDD_UUID TZ_ZONE TZ_STR NTP_SERVER LAN PC_IP WAN WAN_PROTO PPPOE_USER PPPOE_PASS WAN_STATIC_IP WAN_STATIC_GW WAN_STATIC_DNS WAN_MAC LAN_MAC USE_ONT ONT_IP USE_USB_ETH2 ENDPOINT EMAIL OWNER SERVER BOT_IMAGE TS_IMAGE MM_IMAGE RD_IMAGE TOR_IMAGE BES_IMAGE CADDY_IMAGE BOT TOR_MODE; do
    val=${!k}
    [[ $val != *$'\n'* && $val != *$'\r'* ]] || { rm -f "$t"; msg "Ошибка сохранения: перевод строки в параметре $k"; return 1; }
    val=${val//\'/\'\\\'\'}
    printf "%s='%s'\n" "$k" "$val" >> "$t"
  done
  chmod 600 "$t"; mv "$t" "$STATE"
}

exists() { docker inspect "$1" >/dev/null 2>&1; }
managed() { [[ $(docker inspect -f '{{index .Config.Labels "homestack.managed"}}' "$1" 2>/dev/null || true) == 1 ]]; }
need() { command -v "$1" >/dev/null || { msg "Не найдена команда $1. Сначала выполните базовую настройку."; return 1; }; }

# Защита от установки пакетов и контейнеров в RAM (tmpfs) до перезагрузки
overlay_ready() {
  local ov_dev
  ov_dev=$(awk '$2 == "/overlay" && $1 ~ /^\/dev\// {print $1; exit}' /proc/mounts)
  if [[ -z $ov_dev ]]; then
    msg 'ОШИБКА: /overlay всё ещё находится в оперативной памяти (tmpfs)!'
    msg 'Сначала выполните пункт 1 (разметка SD-карты) и ПЕРЕЗАГРУЗИТЕ роутер.'
    msg 'Примечание: скрипт рассчитан на squashfs-образ sbwml.'
    return 1
  fi
}

# Строгая проверка: безопасный путь, не пересекается с BASE/DOCKER_ROOT, смонтирован /dev/* и совпадает UUID
hdd_mounted() {
  safe_path "$HDD_MOUNT" || return 1
  paths_disjoint "$HDD_MOUNT" "$BASE" || return 1
  paths_disjoint "$HDD_MOUNT" "$DOCKER_ROOT" || return 1
  local norm_mnt dev
  norm_mnt=$(normalize_path "$HDD_MOUNT") || return 1
  dev=$(awk -v m="$norm_mnt" '$2 == m && $1 ~ /^\/dev\// {print $1; exit}' /proc/mounts)
  [[ -n $dev && -b $dev ]] || return 1
  if [[ -n $HDD_UUID ]]; then
    command -v blkid >/dev/null 2>&1 || return 1
    local cur_uuid
    cur_uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null) || return 1
    [[ -n $cur_uuid && $cur_uuid == "$HDD_UUID" ]] || return 1
  fi
  return 0
}

# Выбор USB-раздела для HDD, запись в fstab и монтирование
select_hdd() {
  safe_path "$HDD_MOUNT" || { msg "Небезопасный путь HDD_MOUNT: '$HDD_MOUNT'"; return 1; }
  paths_disjoint "$HDD_MOUNT" "$BASE" || { msg 'HDD_MOUNT пересекается с BASE.'; return 1; }
  paths_disjoint "$HDD_MOUNT" "$DOCKER_ROOT" || { msg 'HDD_MOUNT пересекается с DOCKER_ROOT.'; return 1; }
  need lsblk; need blkid; need uci

  local parts=() labels=() name type pkname sys_real size fstype uuid model
  while read -r name type; do
    [[ $type == part && -n $name ]] || continue
    pkname=$(lsblk -ndo PKNAME "$name" 2>/dev/null || true)
    pkname=${pkname##*/}
    [[ -n $pkname ]] || continue
    sys_real=$(readlink -f "/sys/class/block/$pkname" 2>/dev/null || true)
    [[ $sys_real == *'/usb'* ]] || continue

    size=$(lsblk -ndo SIZE "$name" 2>/dev/null | xargs || true)
    fstype=$(blkid -s TYPE -o value "$name" 2>/dev/null || true)
    uuid=$(blkid -s UUID -o value "$name" 2>/dev/null || true)
    model=$(lsblk -ndo MODEL "/dev/$pkname" 2>/dev/null | xargs || true)
    parts+=("$name")
    labels+=("$name | ${size:-?} | ФС: ${fstype:-нет} | UUID: ${uuid:-нет} | ${model:-USB Disk}")
  done < <(lsblk -nrpo NAME,TYPE)

  if ((${#parts[@]} == 0)); then
    msg 'Внешние USB-разделы не обнаружены.'
    return 1
  fi

  local chosen_part=''
  if ((${#parts[@]} == 1)); then
    msg "Обнаружен USB-раздел: ${labels[0]}"
    if confirm "Использовать этот раздел для монтирования в $HDD_MOUNT?"; then
      chosen_part="${parts[0]}"
    else
      return 1
    fi
  else
    msg 'Обнаружено несколько USB-разделов:'
    local i
    for i in "${!labels[@]}"; do
      printf ' %d) %s\n' "$((i + 1))" "${labels[$i]}"
    done
    local pick
    read -r -p "Выберите номер раздела [1-${#parts[@]}] (0 — пропустить): " pick
    [[ $pick =~ ^[0-9]+$ && $pick -ge 1 && $pick -le ${#parts[@]} ]] || return 1
    chosen_part="${parts[$((pick - 1))]}"
  fi

  local usb_uuid usb_fs
  usb_uuid=$(blkid -s UUID -o value "$chosen_part" 2>/dev/null || true)
  usb_fs=$(blkid -s TYPE -o value "$chosen_part" 2>/dev/null || true)
  [[ -n $usb_uuid ]] || { msg "У раздела $chosen_part отсутствует UUID (отформатируйте его в ext4)."; return 1; }

  HDD_UUID="$usb_uuid"
  HDD_MOUNT=$(normalize_path "$HDD_MOUNT")
  save
  mkdir -p "$HDD_MOUNT"

  local idx
  for idx in $(uci show fstab | sed -n "s/^fstab\.\(@mount\[[0-9]*\]\)\.target='${HDD_MOUNT//\//\\/}'$/\1/p" | tac); do
    uci delete "fstab.$idx"
  done
  local m_hdd
  m_hdd=$(uci add fstab mount)
  uci set "fstab.$m_hdd.target=$HDD_MOUNT"
  uci set "fstab.$m_hdd.uuid=$usb_uuid"
  [[ -z $usb_fs ]] || uci set "fstab.$m_hdd.fstype=$usb_fs"
  uci set "fstab.$m_hdd.options=rw,noatime"
  uci set "fstab.$m_hdd.enabled=1"
  uci commit fstab

  block mount 2>/dev/null || mount -U "$usb_uuid" "$HDD_MOUNT" 2>/dev/null || true
  if hdd_mounted; then
    msg "Внешний HDD $chosen_part (UUID: $usb_uuid) смонтирован в $HDD_MOUNT."
  else
    msg "Запись для $chosen_part сохранена в fstab, но немедленное монтирование в $HDD_MOUNT не подтверждено."
  fi
}

# Установка драйверов USB-хаба, USB 3.0, HDD (UAS/ext4) и USB-сетевых карт (AX88179 / RTL8152)
usb_drivers() {
  need apk
  msg '=== Проверка и установка драйверов USB-хаба, USB 3.0, HDD (UAS) и USB-Ethernet ==='
  local kmods=(
    kmod-usb-core
    kmod-usb2
    kmod-usb3
    kmod-usb-storage
    kmod-usb-storage-uas
    kmod-fs-ext4
    kmod-usb-net
    kmod-usb-net-asix
    kmod-usb-net-asix-ax88179
    kmod-usb-net-rtl8152
    kmod-usb-net-cdc-ether
    usbutils
  )
  local m failed=()
  for m in "${kmods[@]}"; do
    apk info -e "$m" >/dev/null 2>&1 && continue
    if ! apk add "$m" >/dev/null 2>&1; then
      failed+=("$m")
    fi
  done
  if ((${#failed[@]} > 0)); then
    msg "Примечание: пакеты не поставились из репо (обычно уже вшиты в ядро sbwml): ${failed[*]}"
  fi
  sleep 2
}

ready() {
  overlay_ready
  validate_all_paths
  need docker; docker info >/dev/null
  mkdir -p "$BASE" "$BASE/backups" "$BASE/https/sites"
  chmod 700 "$BASE" "$BASE/backups" "$BASE/https"
}

# Запись актуального манифеста RepoDigests с проверкой статуса docker ps
write_manifest() {
  command -v docker >/dev/null 2>&1 || return 0
  mkdir -p "$BASE"
  local tmp_m all_cnames cname img_ref img_id digest
  all_cnames=$(docker ps -a --filter label=homestack.managed=1 --format '{{.Names}}') || return 1
  tmp_m=$(mktemp "$BASE/.manifest-XXXXXX")
  while IFS= read -r cname; do
    [[ -n $cname ]] || continue
    img_ref=$(docker inspect -f '{{.Config.Image}}' "$cname" 2>/dev/null || true)
    img_id=$(docker inspect -f '{{.Image}}' "$cname" 2>/dev/null || true)
    digest=''
    if [[ -n $img_id ]]; then
      digest=$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$img_id" 2>/dev/null | grep -E '@sha256:[0-9a-f]{64}$' | head -n1 || true)
    fi
    printf '%s\t%s\t%s\n' "$cname" "${img_ref:-none}" "${digest:-none}" >> "$tmp_m"
  done <<< "$all_cnames"
  chmod 600 "$tmp_m"
  mv "$tmp_m" "$BASE/image-manifest.txt"
}

# ==============================================================================
# МАСТЕР ПАРАМЕТРОВ (ДЛЯ СЕБЯ ИЛИ ДЛЯ РОУТЕРА ДРУГА)
# ==============================================================================
config() {
  msg '=== Настройка параметров роутера (свой профиль или профиль друга) ==='
  msg '1) Интерактивный мастер для друга / нового роутера (выбор цифрами)'
  msg '2) Быстрый пресет Николая (Екатеринбург, Уфанет DHCP + MAC, WAN_ONT, LAN 192.168.2.1)'
  msg '3) Ручное редактирование всех переменных по очереди'
  local mode; read -r -p '> ' mode

  if [[ $mode == 2 ]]; then
    TZ_ZONE='Asia/Yekaterinburg'; TZ_STR='YEKT-5'; NTP_SERVER='ntp.ix.ru'
    LAN='192.168.2.1'; PC_IP='192.168.2.3'
    WAN_PROTO='dhcp'; WAN_MAC='0A:50:17:D7:61:A2'; LAN_MAC='0A:50:17:D7:61:A3'
    USE_ONT='yes'; ONT_IP='192.168.101.2'; USE_USB_ETH2='yes'
    ENDPOINT='136.169.254.11'; SERVER='192.168.2.1:9987'
    BASE='/opt/homestack'
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      local cur_dr
      cur_dr=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
      [[ -z $cur_dr ]] || DOCKER_ROOT="$cur_dr"
    fi
    if [[ -n $HDD_MOUNT ]] && command -v blkid >/dev/null 2>&1; then
      local mdev muuid
      mdev=$(awk -v m="$HDD_MOUNT" '$2 == m && $1 ~ /^\/dev\// {print $1; exit}' /proc/mounts)
      if [[ -n $mdev && -b $mdev ]]; then
        muuid=$(blkid -s UUID -o value "$mdev" 2>/dev/null || true)
        [[ -z $muuid ]] || HDD_UUID="$muuid"
      fi
    fi
    ask OWNER 'Ваш TeamSpeak UID для MusicBot'
    ask EMAIL 'Email для HTTPS-сертификатов Caddy'
    validate_all_paths
    save
    msg 'Пресет Николая сохранён.'
    return 0
  fi

  if [[ $mode == 1 ]]; then
    msg '--- Шаг 1: Выберите часовой пояс (введите цифру от 1 до 12) ---'
    msg ' 1) Калининград (UTC+2)'
    msg ' 2) Москва, Санкт-Петербург, Центр (UTC+3)'
    msg ' 3) Самара, Ижевск, Удмуртия (UTC+4)'
    msg ' 4) Екатеринбург, Урал, Башкортостан, Тюмень (UTC+5)'
    msg ' 5) Омск (UTC+6)'
    msg ' 6) Новосибирск, Красноярск, Кузбасс (UTC+7)'
    msg ' 7) Иркутск, Бурятия (UTC+8)'
    msg ' 8) Якутск, Чита, Амурская обл. (UTC+9)'
    msg ' 9) Владивосток, Хабаровск (UTC+10)'
    msg '10) Магадан, Сахалин (UTC+11)'
    msg '11) Камчатка, Чукотка (UTC+12)'
    msg '12) Ввести свой пояс вручную'
    local tz_choice; read -r -p '> ' tz_choice
    case $tz_choice in
      1)  TZ_ZONE='Europe/Kaliningrad'; TZ_STR='EET-2' ;;
      2)  TZ_ZONE='Europe/Moscow';      TZ_STR='MSK-3' ;;
      3)  TZ_ZONE='Europe/Samara';      TZ_STR='SAMT-4' ;;
      4)  TZ_ZONE='Asia/Yekaterinburg'; TZ_STR='YEKT-5' ;;
      5)  TZ_ZONE='Asia/Omsk';          TZ_STR='OMST-6' ;;
      6)  TZ_ZONE='Asia/Krasnoyarsk';   TZ_STR='KRAT-7' ;;
      7)  TZ_ZONE='Asia/Irkutsk';       TZ_STR='IRKT-8' ;;
      8)  TZ_ZONE='Asia/Yakutsk';       TZ_STR='YAKT-9' ;;
      9)  TZ_ZONE='Asia/Vladivostok';   TZ_STR='VLAT-10' ;;
      10) TZ_ZONE='Asia/Magadan';       TZ_STR='MAGT-11' ;;
      11) TZ_ZONE='Asia/Kamchatka';     TZ_STR='PETT-12' ;;
      *)  ask TZ_ZONE 'Имя зоны (например Europe/Minsk)'; ask TZ_STR 'POSIX-строка пояса (например MSK-3)' ;;
    esac
    ask NTP_SERVER 'NTP-сервер синхронизации времени'

    msg '--- Шаг 2: Локальная сеть роутера ---'
    ask LAN 'LAN IPv4 роутера (например 192.168.1.1 или 192.168.2.1)'
    valid_ipv4 "$LAN" && [[ $LAN != 0.0.0.0 ]] || { msg 'Некорректный LAN IPv4.'; return 1; }
    SERVER="${LAN}:9987"
    if confirm 'Подключён ли USB-Ethernet адаптер (eth2), который нужно объединить с LAN?'; then
      USE_USB_ETH2='yes'
    else
      USE_USB_ETH2='no'
    fi

    msg '--- Шаг 3: Подключение к провайдеру (WAN на eth0) ---'
    msg '1) DHCP (автоматический IP + привязка по MAC, без логина/пароля)'
    msg '2) PPPoE (если провайдер требует логин и пароль в роутере)'
    msg '3) Статический IPv4 (IP, маска, шлюз, DNS)'
    local wp; read -r -p '> ' wp
    case $wp in
      2)
        WAN_PROTO='pppoe'
        ask PPPOE_USER 'Логин PPPoE'
        read -r -s -p 'Пароль PPPoE: ' PPPOE_PASS; echo
        ;;
      3)
        WAN_PROTO='static'
        ask WAN_STATIC_IP 'Внешний IP с маской (например 95.10.20.30/24)'
        ask WAN_STATIC_GW 'Шлюз провайдера (Gateway)'
        valid_ipv4 "$WAN_STATIC_GW" || { msg 'Некорректный IP шлюза.'; return 1; }
        ask WAN_STATIC_DNS 'DNS-серверы через пробел'
        ;;
      *)
        WAN_PROTO='dhcp'
        PPPOE_USER=''; PPPOE_PASS=''
        ;;
    esac

    local mac_in=''
    while true; do
      read -r -p 'MAC-адрес для WAN в формате XX:XX:XX:XX:XX:XX (Enter — оставить заводской MAC): ' mac_in
      if [[ -z $mac_in ]]; then
        WAN_MAC=''
        break
      elif [[ $mac_in =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        WAN_MAC="${mac_in^^}"
        break
      else
        msg 'Неверный формат MAC. Пример: 0A:50:17:D7:61:A2'
      fi
    done
    LAN_MAC=''

    if confirm 'Нужен ли дополнительный интерфейс WAN_ONT для доступа в меню оптического терминала (мост)?'; then
      USE_ONT='yes'
      ask ONT_IP 'IP роутера в подсети терминала (например 192.168.101.2)'
      valid_ipv4 "$ONT_IP" || { msg 'Некорректный IP для WAN_ONT.'; return 1; }
    else
      USE_ONT='no'
    fi

    msg '--- Шаг 4: Внешний доступ, HDD и сервисы (ненужное очищайте через "-") ---'
    ENDPOINT=''; PC_IP=''; OWNER=''; EMAIL=''; HDD_UUID=''
    ask ENDPOINT 'Внешний белый IP или DDNS-домен'
    ask PC_IP 'Локальный IP домашнего ПК для пробросов портов'
    [[ -z $PC_IP ]] || valid_ipv4 "$PC_IP" || { msg 'Некорректный PC_IP.'; return 1; }
    ask HDD_MOUNT 'Точка монтирования внешнего HDD для Samba4 (введите "-" если диска нет)'
    ask OWNER 'TeamSpeak UID владельца для MusicBot'
    ask EMAIL 'Email для SSL-сертификатов Caddy'
    validate_all_paths
    save
    msg 'Параметры успешно сохранены в /etc/homestack.conf!'
    return 0
  fi

  # Режим 3: ручное редактирование всех полей
  ask TZ_ZONE 'Часовой пояс (zonename)'
  ask TZ_STR 'Строка пояса (timezone)'
  ask NTP_SERVER 'NTP сервер'
  ask BASE 'Каталог данных HomeStack (на SD-карте)'
  ask DOCKER_ROOT 'Каталог образов Docker (на SD-карте)'
  ask HDD_MOUNT 'Точка монтирования внешнего USB HDD'
  ask HDD_UUID 'UUID внешнего USB HDD'
  validate_all_paths
  ask LAN 'LAN IPv4 роутера'
  valid_ipv4 "$LAN" || { msg 'Некорректный LAN IPv4.'; return 1; }
  ask PC_IP 'Локальный IP ПК для пробросов'
  [[ -z $PC_IP ]] || valid_ipv4 "$PC_IP" || { msg 'Некорректный PC_IP.'; return 1; }
  ask WAN_PROTO 'Протокол WAN (dhcp / pppoe / static)'
  if [[ $WAN_PROTO == pppoe ]]; then
    ask PPPOE_USER 'Логин PPPoE'
    local v; read -r -s -p 'Пароль PPPoE (Enter — не менять): ' v; echo
    [[ -z $v ]] || PPPOE_PASS="$v"
  elif [[ $WAN_PROTO == static ]]; then
    ask WAN_STATIC_IP 'Статический IP WAN с маской (IP/PREFIX)'
    ask WAN_STATIC_GW 'Шлюз WAN'
    ask WAN_STATIC_DNS 'DNS WAN'
  fi
  ask WAN_MAC 'MAC-адрес WAN'
  ask LAN_MAC 'MAC-адрес LAN'
  ask USE_ONT 'Поднимать WAN_ONT (yes/no)'
  [[ $USE_ONT != yes ]] || ask ONT_IP 'IP интерфейса WAN_ONT'
  ask USE_USB_ETH2 'Добавлять USB eth2 в br-lan (yes/no)'
  ask ENDPOINT 'Внешний IP или DDNS'
  ask EMAIL 'Email ACME для Caddy'
  ask OWNER 'TeamSpeak UID владельца MusicBot'
  ask SERVER 'Адрес:порт TeamSpeak для MusicBot'
  save
}

# ==============================================================================
# 1. АВТОРАЗМЕТКА SD-КАРТЫ ПОД /overlay (f2fs) И ЗАПИСЬ HDD В FSTAB (ДО РЕБУТА)
# ==============================================================================
disk_overlay() (
  set -Eeuo pipefail
  need awk; need sed
  validate_all_paths
  msg '=== Авторазметка SD-карты под /overlay (без установки лишних пакетов в RAM) ==='

  missing=()
  command -v parted >/dev/null 2>&1 || missing+=(parted)
  command -v mkfs.f2fs >/dev/null 2>&1 || missing+=(f2fs-tools)
  command -v block >/dev/null 2>&1 || missing+=(block-mount)
  command -v lsblk >/dev/null 2>&1 || missing+=(lsblk)
  command -v blkid >/dev/null 2>&1 || missing+=(blkid)
  if ((${#missing[@]} > 0)); then
    need apk
    apk update
    apk add "${missing[@]}"
  fi

  partuuid=$(sed -n 's/.*root=PARTUUID=\([^ ]*\).*/\1/p' /proc/cmdline)
  [[ -n $partuuid ]] || { msg 'Не удалось определить root=PARTUUID из /proc/cmdline.'; exit 1; }

  root_part=$(blkid -t "PARTUUID=$partuuid" -o device 2>/dev/null || true)
  [[ -b $root_part ]] || { msg "Раздел с PARTUUID=$partuuid не найден."; exit 1; }

  if [[ $root_part =~ ^(/dev/mmcblk[0-9]+)p[0-9]+$ ]]; then
    root_disk="${BASH_REMATCH[1]}"
  else
    msg "Загрузочный раздел $root_part не является mmcblk. Остановка ради безопасности."
    exit 1
  fi

  p3="${root_disk}p3"
  root_mm=$(dev_majmin "$root_part")
  active_ov=$(awk '$2 == "/overlay" && $1 ~ /^\/dev\// {print $1; exit}' /proc/mounts)
  active_ov_mm=''
  [[ -z $active_ov ]] || active_ov_mm=$(dev_majmin "$active_ov")

  if [[ -b $p3 ]]; then
    p3_mm=$(dev_majmin "$p3")
    [[ -n $p3_mm && $p3_mm != "$root_mm" ]] || { msg 'Отказ: целевой раздел совпадает с корневым.'; exit 1; }
    if [[ -n $active_ov_mm && $p3_mm == "$active_ov_mm" ]]; then
      msg "Раздел $p3 УЖЕ активен как /overlay! Повторная разметка не требуется."
      exit 0
    fi
    while read -r mdev mpt _; do
      [[ $mdev == /dev/* ]] || continue
      if [[ $(dev_majmin "$mdev") == "$p3_mm" ]]; then
        msg "Отказ: раздел $p3 уже смонтирован в $mpt. Отмонтируйте его вручную."
        exit 1
      fi
    done < /proc/mounts
  fi

  tmp_mnt=''
  cleanup_mnt() {
    if [[ -n $tmp_mnt ]]; then
      umount "$tmp_mnt" 2>/dev/null || true
      rmdir "$tmp_mnt" 2>/dev/null || true
    fi
  }
  trap cleanup_mnt EXIT

  need_copy=false
  msg "Загрузочный накопитель: $root_disk (корневой раздел: $root_part)"

  if [[ -b $p3 ]]; then
    p3_fs=$(blkid -s TYPE -o value "$p3" 2>/dev/null || true)
    if [[ $p3_fs == f2fs ]]; then
      tmp_mnt=$(mktemp -d)
      mount -t f2fs "$p3" "$tmp_mnt"
      if [[ -f $tmp_mnt/.homestack_overlay_ready ]]; then
        msg "Раздел $p3 уже содержит подготовленный overlay."
        if confirm "Обновить на $p3 текущие конфиги из оперативного /overlay?"; then
          need_copy=true
        fi
      else
        msg "Раздел $p3 имеет f2fs, но маркер переноса отсутствует. Выполняем перенос..."
        need_copy=true
      fi
      umount "$tmp_mnt"; rmdir "$tmp_mnt"; tmp_mnt=''
    else
      msg "ВНИМАНИЕ: Раздел $p3 уже существует, но его ФС: '${p3_fs:-не определена}' (нужна f2fs)."
      typed_name=''
      read -r -p "Для подтверждения форматирования введите точное имя раздела (${p3#/dev/}): " typed_name
      [[ $typed_name == "${p3#/dev/}" ]] || { msg 'Имя не совпало — форматирование отменено.'; exit 1; }
      mkfs.f2fs -f -l rootfs_data "$p3"
      need_copy=true
    fi
  else
    confirm "Создать раздел $p3 на всё свободное место $root_disk и отформатировать в f2fs под /overlay?" || exit 0
    end_sec=$(parted -ms "$root_disk" unit s print | awk -F: '$1=="2"{gsub(/s/,"",$3); print $3}')
    total_sec=$(parted -ms "$root_disk" unit s print | awk -F: '$1 ~ /^\/dev\//{gsub(/s/,"",$2); print $2}')
    [[ $end_sec =~ ^[0-9]+$ && $total_sec =~ ^[0-9]+$ && $((total_sec - end_sec)) -gt 204800 ]] || {
      msg 'Недостаточно свободного места после 2-го раздела.'; exit 1;
    }
    start_sec=$((end_sec + 1))

    parted -s "$root_disk" mkpart primary f2fs "${start_sec}s" 100%
    partprobe "$root_disk" 2>/dev/null || blockdev --rereadpt "$root_disk" 2>/dev/null || true
    sleep 2
    [[ -b $p3 ]] || { msg "Раздел $p3 не появился. Перезагрузите роутер и запустите пункт снова."; exit 1; }

    mkfs.f2fs -f -l rootfs_data "$p3"
    need_copy=true
  fi

  p3_uuid=$(blkid -s UUID -o value "$p3" || true)
  [[ -n $p3_uuid ]] || { msg "Не удалось прочитать UUID раздела $p3."; exit 1; }

  for idx in $(uci show fstab | sed -n "s/^fstab\.\(@mount\[[0-9]*\]\)\.target='\/overlay'$/\1/p" | tac); do
    uci delete "fstab.$idx"
  done
  m_ov=$(uci add fstab mount)
  uci set "fstab.$m_ov.target=/overlay"
  uci set "fstab.$m_ov.uuid=$p3_uuid"
  uci set "fstab.$m_ov.fstype=f2fs"
  uci set "fstab.$m_ov.options=rw,noatime"
  uci set "fstab.$m_ov.enabled=1"

  uci set fstab.@global[0].auto_mount='1'
  uci set fstab.@global[0].auto_swap='1'
  uci set fstab.@global[0].delay_root='5'
  uci commit fstab

  if [[ -n $HDD_MOUNT ]] && ! hdd_mounted; then
    select_hdd || true
  fi
  save

  if [[ $need_copy == true ]]; then
    [[ -d /overlay && -n $(ls -A /overlay 2>/dev/null) ]] || { msg 'Исходный /overlay пуст или недоступен.'; exit 1; }
    tmp_mnt=$(mktemp -d)
    mount -t f2fs "$p3" "$tmp_mnt"
    rm -f "$tmp_mnt/.homestack_overlay_ready"
    sync
    cp -a /overlay/. "$tmp_mnt/"
    [[ -f $tmp_mnt/upper/etc/config/fstab || -f $tmp_mnt/etc/config/fstab ]] || {
      msg 'Проверка переноса не пройдена: на новом разделе не найден etc/config/fstab.'
      exit 1
    }
    touch "$tmp_mnt/.homestack_overlay_ready"
    sync
    umount "$tmp_mnt"; rmdir "$tmp_mnt"; tmp_mnt=''
    msg "Раздел $p3 готов, конфиги и скрипт перенесены и проверены."
  fi

  trap - EXIT
  if confirm 'Перезагрузить роутер сейчас, чтобы активировать новый /overlay на SD-карте?'; then
    reboot
  fi
)

# ==============================================================================
# 2. БАЗОВАЯ НАСТРОЙКА (USB-ДРАЙВЕРЫ, BTOP, ТЕМЫ/RU, ВЫБОР HDD)
# ==============================================================================
base_system() {
  overlay_ready
  validate_all_paths
  need apk
  msg '=== Установка драйверов USB, btop и обязательных утилит на постоянный /overlay ==='
  apk update
  usb_drivers

  local req_pkgs=(bash btop docker dockerd curl ca-bundle tar jq openssl-util irqbalance luci-app-irqbalance lsblk blkid block-mount)
  [[ $WAN_PROTO != pppoe ]] || req_pkgs+=(ppp ppp-mod-pppoe)
  local pkg
  for pkg in "${req_pkgs[@]}"; do
    apk info -e "$pkg" >/dev/null 2>&1 || apk add "$pkg" 2>/dev/null || true
  done
  for pkg in docker jq curl tar openssl; do
    need "$pkg"
  done

  if [[ -n $HDD_MOUNT ]] && ! hdd_mounted; then
    block mount 2>/dev/null || true
    if ! hdd_mounted; then
      select_hdd || true
    fi
  fi

  msg "=== Настройка часового пояса ($TZ_ZONE) и NTP ($NTP_SERVER) ==="
  uci set "system.@system[0].zonename=$TZ_ZONE"
  uci set "system.@system[0].timezone=$TZ_STR"
  uci -q delete system.ntp.server || true
  uci add_list "system.ntp.server=$NTP_SERVER"
  uci add_list system.ntp.server='0.ru.pool.ntp.org'
  uci set system.ntp.enabled='1'
  uci commit system
  /etc/init.d/sysntpd restart 2>/dev/null || true

  msg '=== Установка всех доступных стоковых тем оформления из репозитория OpenWrt ==='
  local stock_themes
  stock_themes=$(apk list 'luci-theme-*' 2>/dev/null | awk '{print $1}' | sed -E 's/-[0-9]+(\.[0-9]+|~|-r).*$//' | sort -u || true)
  if [[ -n $stock_themes ]]; then
    for pkg in $stock_themes; do
      apk info -e "$pkg" >/dev/null 2>&1 || apk add "$pkg" 2>/dev/null || true
    done
  fi

  msg '=== Проверка и включение темы Proton 2025 ==='
  if ! apk info -e luci-theme-proton2025 >/dev/null 2>&1; then
    apk add luci-theme-proton2025 2>/dev/null || {
      local p_url
      p_url=$(curl -fsSL https://api.github.com/repos/Chester/luci-theme-proton2025/releases/latest 2>/dev/null | jq -r '.assets[]?.browser_download_url | select(endswith(".apk"))' | head -n1 || true)
      if [[ -n $p_url ]] && confirm "Скачать и установить luci-theme-proton2025 с GitHub ($p_url)?"; then
        curl -fL "$p_url" -o /tmp/proton2025.apk && apk add --allow-untrusted /tmp/proton2025.apk && rm -f /tmp/proton2025.apk
      fi
    }
  fi

  msg '=== Установка русских языковых пакетов LuCI (luci-i18n-*-ru) ==='
  local base_name i18n_pkgs=()
  for pkg in $(apk list -I 2>/dev/null | awk '{print $1}' | grep -E '^luci-(app|mod|theme)-'); do
    base_name=$(echo "$pkg" | sed -E 's/-[0-9]+(\.[0-9]+|~|-r).*$//; s/^luci-(app|mod|theme)-//')
    [[ -n $base_name ]] && i18n_pkgs+=("luci-i18n-${base_name}-ru")
  done
  i18n_pkgs+=("luci-i18n-base-ru")
  for pkg in "${i18n_pkgs[@]}"; do
    apk info -e "$pkg" >/dev/null 2>&1 || apk add "$pkg" 2>/dev/null || true
  done

  if [[ -d /www/luci-static/proton2025 ]]; then
    uci set luci.main.mediaurlbase='/luci-static/proton2025'
  fi
  uci set luci.main.lang='ru'
  uci commit luci
  msg 'Драйверы USB, btop, часовой пояс, все темы (активна Proton 2025) и русский язык LuCI применены.'
}

# ==============================================================================
# 3. НАСТРОЙКА СЕТИ С АТОМАРНЫМ ЗАМКОМ WATCHDOG И ПРОВЕРКОЙ FW4
# ==============================================================================
net_setup() {
  need uci; need fw4
  validate_all_paths
  valid_ipv4 "$LAN" || { msg "Некорректный LAN IP: $LAN"; return 1; }
  [[ -z $(uci changes network) ]] || { msg 'Есть несохранённые изменения network в LuCI. Примените или сбросьте их.'; return 1; }
  [[ -z $(uci changes firewall) ]] || { msg 'Есть несохранённые изменения firewall в LuCI. Примените или сбросьте их.'; return 1; }

  msg "=== Настройка сети (LAN=$LAN, WAN=$WAN_PROTO, MAC=${WAN_MAC:-заводской}, USB_ETH2=$USE_USB_ETH2) ==="
  mkdir -p "$BASE/backups"
  local stamp nb fb lockdir wd_start
  stamp=$(date +%Y%m%d-%H%M%S)
  nb="$BASE/backups/network-$stamp"
  fb="$BASE/backups/firewall-$stamp"
  lockdir="/tmp/hs-net-lock-$stamp"
  cp -p /etc/config/network "$nb"
  cp -p /etc/config/firewall "$fb"

  local dev_sec found_br=false found_eth0=false found_eth1=false found_eth2=false
  for dev_sec in $(uci show network | sed -n 's/^network\.\([^.=]*\)=device$/\1/p'); do
    case $(uci -q get "network.$dev_sec.name") in
      br-lan)
        found_br=true
        if [[ -n $LAN_MAC ]]; then uci set "network.$dev_sec.macaddr=$LAN_MAC"; else uci -q delete "network.$dev_sec.macaddr" || true; fi
        uci set "network.$dev_sec.ipv6=0"
        uci -q delete "network.$dev_sec.ports" || true
        uci add_list "network.$dev_sec.ports=eth1"
        [[ $USE_USB_ETH2 != yes ]] || uci add_list "network.$dev_sec.ports=eth2"
        ;;
      eth0)
        found_eth0=true
        if [[ -n $WAN_MAC ]]; then uci set "network.$dev_sec.macaddr=$WAN_MAC"; else uci -q delete "network.$dev_sec.macaddr" || true; fi
        uci set "network.$dev_sec.ipv6=0"
        ;;
      eth1)
        found_eth1=true
        if [[ -n $LAN_MAC ]]; then uci set "network.$dev_sec.macaddr=$LAN_MAC"; else uci -q delete "network.$dev_sec.macaddr" || true; fi
        uci set "network.$dev_sec.ipv6=0"
        ;;
      eth2)
        found_eth2=true
        uci set "network.$dev_sec.mtu=1500"
        uci set "network.$dev_sec.ipv6=0"
        ;;
    esac
  done

  if [[ $found_br == false ]]; then
    dev_sec=$(uci add network device)
    uci set "network.$dev_sec.name=br-lan"
    uci set "network.$dev_sec.type=bridge"
    [[ -z $LAN_MAC ]] || uci set "network.$dev_sec.macaddr=$LAN_MAC"
    uci set "network.$dev_sec.ipv6=0"
    uci add_list "network.$dev_sec.ports=eth1"
    [[ $USE_USB_ETH2 != yes ]] || uci add_list "network.$dev_sec.ports=eth2"
  fi
  if [[ $found_eth0 == false ]]; then
    dev_sec=$(uci add network device)
    uci set "network.$dev_sec.name=eth0"
    [[ -z $WAN_MAC ]] || uci set "network.$dev_sec.macaddr=$WAN_MAC"
    uci set "network.$dev_sec.ipv6=0"
  fi
  if [[ $USE_USB_ETH2 == yes && $found_eth2 == false ]]; then
    dev_sec=$(uci add network device)
    uci set "network.$dev_sec.name=eth2"; uci set "network.$dev_sec.mtu=1500"; uci set "network.$dev_sec.ipv6=0"
  fi

  uci set network.lan.device='br-lan'
  uci set network.lan.proto='static'
  uci set "network.lan.ipaddr=$LAN/24"
  uci set network.lan.delegate='0'

  uci -q delete network.wan || true
  uci set network.wan=interface
  uci set network.wan.device='eth0'
  uci set network.wan.ipv6='0'
  case $WAN_PROTO in
    pppoe)
      uci set network.wan.proto='pppoe'
      uci set "network.wan.username=$PPPOE_USER"
      uci set "network.wan.password=$PPPOE_PASS"
      ;;
    static)
      uci set network.wan.proto='static'
      uci set "network.wan.ipaddr=$WAN_STATIC_IP"
      uci set "network.wan.gateway=$WAN_STATIC_GW"
      uci set network.wan.peerdns='0'
      local d; for d in $WAN_STATIC_DNS; do uci add_list "network.wan.dns=$d"; done
      ;;
    *)
      uci set network.wan.proto='dhcp'
      ;;
  esac

  local z
  if [[ $USE_ONT == yes ]]; then
    uci set network.WAN_ONT=interface
    uci set network.WAN_ONT.proto='static'
    uci set network.WAN_ONT.device='eth0'
    uci set "network.WAN_ONT.ipaddr=$ONT_IP"
    uci set network.WAN_ONT.netmask='255.255.255.0'
    uci set network.WAN_ONT.defaultroute='0'
    uci set network.WAN_ONT.delegate='0'
    for z in $(uci show firewall | sed -n 's/^firewall\.\([^=]*\)=zone$/\1/p'); do
      if [[ $(uci -q get "firewall.$z.name") == "$WAN" ]]; then
        uci -q get "firewall.$z.network" | grep -qw 'WAN_ONT' || uci add_list "firewall.$z.network=WAN_ONT"
      fi
    done
  else
    uci -q delete network.WAN_ONT || true
    for z in $(uci show firewall | sed -n 's/^firewall\.\([^=]*\)=zone$/\1/p'); do
      if [[ $(uci -q get "firewall.$z.name") == "$WAN" ]]; then
        uci -q del_list "firewall.$z.network=WAN_ONT" || true
      fi
    done
  fi

  if ! fw4 check; then
    uci revert network; uci revert firewall
    msg 'Ошибка проверки fw4: изменения сети и фаервола отменены.'
    return 1
  fi

  wd_start=$(date +%s)
  nohup sh -c "sleep 90; if mkdir '$lockdir' 2>/dev/null; then uci -q revert network || true; uci -q revert firewall || true; cp -p '$nb' /etc/config/network; cp -p '$fb' /etc/config/firewall; /etc/init.d/network reload; /etc/init.d/firewall reload; fi" >/dev/null 2>&1 < /dev/null &

  uci commit network
  uci commit firewall
  /etc/init.d/network reload
  /etc/init.d/firewall reload

  local rem=$(( 90 - ($(date +%s) - wd_start) ))
  if (( rem <= 10 )); then
    if mkdir "$lockdir" 2>/dev/null; then
      uci -q revert network || true; uci -q revert firewall || true
      cp -p "$nb" /etc/config/network; cp -p "$fb" /etc/config/firewall
      /etc/init.d/network reload; /etc/init.d/firewall reload
    fi
    msg 'Применение сети заняло слишком много времени — выполнен автооткат.'
    return 1
  fi

  local wait_sec=$(( rem - 5 ))
  msg "Сеть перезагружена (LAN: $LAN). У вас ${wait_sec} сек для подтверждения."
  local ans=''
  if read -r -t "$wait_sec" -p 'Введите KEEP, чтобы закрепить настройки сети: ' ans && [[ $ans == KEEP ]]; then
    if mkdir "$lockdir" 2>/dev/null; then
      msg 'Сетевые настройки подтверждены и закреплены!'
      return 0
    else
      msg 'Время истекло прямо перед подтверждением — watchdog уже выполнил откат.'
      return 1
    fi
  else
    if mkdir "$lockdir" 2>/dev/null; then
      uci -q revert network || true; uci -q revert firewall || true
      cp -p "$nb" /etc/config/network; cp -p "$fb" /etc/config/firewall
      /etc/init.d/network reload; /etc/init.d/firewall reload
    fi
    msg 'Подтверждение не получено — выполнен откат к предыдущей конфигурации сети.'
    return 1
  fi
}

# ==============================================================================
# 4. ОПТИМИЗАЦИИ ЯДРА, BBR, CPU PERFORMANCE, IRQBALANCE И ПРОВЕРКА DOCKER ROOT
# ==============================================================================
tuning() {
  overlay_ready
  validate_all_paths
  msg '=== Тюнинг ядра, BBR+fq, CPU Performance, Irqbalance и проверка Docker Root ==='

  mkdir -p /etc/modules.d
  echo 'options nf_conntrack hashsize=250000' > /etc/modules.d/nf-conntrack
  [[ ! -w /sys/module/nf_conntrack/parameters/hashsize ]] || echo 250000 > /sys/module/nf_conntrack/parameters/hashsize || true

  modprobe tcp_bbr 2>/dev/null || true
  local cc_line='net.ipv4.tcp_congestion_control=bbr'
  if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw 'bbr'; then
    msg 'Примечание: модуль bbr не обнаружен в tcp_available_congestion_control, оставляем текущий алгоритм TCP.'
    cc_line='# bbr не поддерживается текущим ядром'
  fi

  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/99-homestack-tuning.conf <<EOF
net.netfilter.nf_conntrack_max=1000000
net.core.default_qdisc=fq
$cc_line
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.netdev_max_backlog=5000
net.ipv4.tcp_fin_timeout=15
net.netfilter.nf_conntrack_udp_timeout=30
net.netfilter.nf_conntrack_udp_timeout_stream=120
EOF
  sysctl -p /etc/sysctl.d/99-homestack-tuning.conf >/dev/null

  if [[ -f /etc/config/cpufreq ]]; then
    uci -q set cpufreq.policy0.governor='performance' || true
    uci -q set cpufreq.policy0.minfreq='600000' || true
    if [[ -r /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq ]]; then
      uci -q set "cpufreq.policy0.maxfreq=$(cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq)" || true
    fi
    uci -q set cpufreq.policy4.governor='performance' || true
    uci -q set cpufreq.policy4.minfreq='600000' || true
    if [[ -r /sys/devices/system/cpu/cpufreq/policy4/cpuinfo_max_freq ]]; then
      uci -q set "cpufreq.policy4.maxfreq=$(cat /sys/devices/system/cpu/cpufreq/policy4/cpuinfo_max_freq)" || true
    fi
    uci commit cpufreq
    /etc/init.d/cpufreq restart 2>/dev/null || true
    if [[ -e /etc/init.d/hs-cpufreq ]]; then
      /etc/init.d/hs-cpufreq disable 2>/dev/null || true
      rm -f /etc/init.d/hs-cpufreq
    fi
  else
    cat > /etc/init.d/hs-cpufreq <<'EOF'
#!/bin/sh /etc/rc.common
START=95
start() {
  for p in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$p" ] || continue
    echo performance > "$p/scaling_governor" 2>/dev/null || true
    [ -r "$p/cpuinfo_max_freq" ] && cat "$p/cpuinfo_max_freq" > "$p/scaling_max_freq" 2>/dev/null || true
  done
}
EOF
    chmod 755 /etc/init.d/hs-cpufreq
    /etc/init.d/hs-cpufreq enable
    /etc/init.d/hs-cpufreq start
  fi

  if [[ -f /etc/config/irqbalance ]]; then
    uci set irqbalance.irqbalance.enabled='1'
    uci commit irqbalance
    /etc/init.d/irqbalance enable 2>/dev/null || true
    /etc/init.d/irqbalance restart 2>/dev/null || true
  fi

  # Безопасная проверка Docker Root: если Docker уже работает на разделе /overlay (/overlay/docker или /opt/docker), не ломаем его
  if [[ -f /etc/config/dockerd ]]; then
    /etc/init.d/dockerd enable
    docker info >/dev/null 2>&1 || /etc/init.d/dockerd start
    local i actual_root root_dev
    for i in {1..20}; do
      docker info >/dev/null 2>&1 && break
      sleep 1
    done
    docker info >/dev/null
    actual_root=$(docker info --format '{{.DockerRootDir}}')
    root_dev=$(df -P "$actual_root" 2>/dev/null | awk 'END{print $1}')
    if [[ $root_dev == /dev/* && ( $actual_root == '/overlay/docker' || $actual_root == '/opt/docker' ) ]]; then
      if [[ $DOCKER_ROOT != "$actual_root" ]]; then
        DOCKER_ROOT="$actual_root"
        save
      fi
      msg "Docker уже настроен на постоянном разделе: $actual_root ($root_dev)."
    else
      mkdir -p "$DOCKER_ROOT"
      uci set "dockerd.globals.data_root=$DOCKER_ROOT"
      uci commit dockerd
      /etc/init.d/dockerd restart
      for i in {1..20}; do
        docker info >/dev/null 2>&1 && break
        sleep 1
      done
      actual_root=$(docker info --format '{{.DockerRootDir}}')
      [[ $actual_root == "$DOCKER_ROOT" ]] || { msg "ОШИБКА: Docker использует $actual_root вместо $DOCKER_ROOT"; return 1; }
    fi
  fi

  msg "Тюнинг завершён. Docker Root: $DOCKER_ROOT."
}

# ==============================================================================
# 5. SAMBA4 ДЛЯ WINDOWS 11 И ЛОКАЛЬНЫХ УСТРОЙСТВ (СТРОГАЯ ПРОВЕРКА МОНТАЖА HDD)
# ==============================================================================
samba_setup() {
  overlay_ready
  validate_all_paths
  need apk; need uci
  if ! hdd_mounted; then
    msg "ВНИМАНИЕ: Внешний диск не смонтирован в $HDD_MOUNT (или не совпал UUID). Samba4 пропущена."
    return 0
  fi
  msg "=== Настройка Samba4 для $HDD_MOUNT (пользователь root, полный доступ в LAN) ==="
  apk update
  apk info -e samba4-server >/dev/null 2>&1 || apk add samba4-server
  apk info -e luci-app-samba4 >/dev/null 2>&1 || apk add luci-app-samba4
  apk add luci-i18n-samba4-ru 2>/dev/null || true

  if [[ -f /etc/samba/smb.conf.template ]]; then
    sed -i 's/^[[:space:]]*invalid users = root/# invalid users = root/' /etc/samba/smb.conf.template
  fi

  msg "Задайте пароль Samba для пользователя root (для подключения с Windows 11 / телефонов к \\\\$LAN\\HDD):"
  smbpasswd -a root

  uci set samba4.@samba[0].workgroup='WORKGROUP'
  uci set samba4.@samba[0].charset='UTF-8'
  uci set samba4.@samba[0].description='NanoPi-R76S'
  uci set samba4.@samba[0].enable_extra_tuning='1'
  uci set samba4.@samba[0].interface='lan'

  local idx s_name s_path
  for idx in $(uci show samba4 | sed -n 's/^samba4\.\(@sambashare\[[0-9]*\]\)=sambashare$/\1/p' | tac); do
    s_name=$(uci -q get "samba4.$idx.name" || true)
    s_path=$(uci -q get "samba4.$idx.path" || true)
    if [[ $s_name == HDD || $s_path == "$HDD_MOUNT" ]]; then
      uci delete "samba4.$idx"
    fi
  done

  local sh
  sh=$(uci add samba4 sambashare)
  uci set "samba4.$sh.name=HDD"
  uci set "samba4.$sh.path=$HDD_MOUNT"
  uci set "samba4.$sh.read_only=no"
  uci set "samba4.$sh.guest_ok=no"
  uci set "samba4.$sh.create_mask=0666"
  uci set "samba4.$sh.dir_mask=0777"
  uci set "samba4.$sh.force_root=1"
  uci set "samba4.$sh.inherit_owner=yes"
  uci set "samba4.$sh.users=root"

  uci commit samba4
  /etc/init.d/samba4 enable
  /etc/init.d/samba4 restart
  msg "Samba4 готова! Подключайтесь по адресу \\\\$LAN\\HDD под логином root."
}

# ==============================================================================
# 6. ЗАЩИТА ОТ СКАНЕРОВ СЕТИ: BANIP
# ==============================================================================
banip_setup() {
  overlay_ready
  need apk; need uci
  msg '=== Установка и настройка banIP ==='
  apk update
  apk info -e banip >/dev/null 2>&1 || apk add banip
  apk info -e luci-app-banip >/dev/null 2>&1 || apk add luci-app-banip
  apk add luci-i18n-banip-ru 2>/dev/null || true

  [[ -f /etc/config/banip ]] || { msg 'Конфиг /etc/config/banip не создан.'; return 1; }
  uci set banip.global.ban_enabled='1'
  uci -q delete banip.global.ban_dev || true
  uci add_list banip.global.ban_dev='eth0'
  uci -q delete banip.global.ban_ifv4 || true
  uci add_list banip.global.ban_ifv4='wan'
  uci set banip.global.ban_autodetect='0'
  uci set banip.global.ban_loginput='1'
  uci set banip.global.ban_logforwardwan='1'
  uci -q delete banip.global.ban_feed || true
  for feed in deblist drop cinsscore threat; do
    uci add_list "banip.global.ban_feed=$feed"
  done
  uci commit banip

  mkdir -p /etc/banip
  touch /etc/banip/banip.allowlist
  grep -q "^${LAN%.*}.0/24" /etc/banip/banip.allowlist || echo "${LAN%.*}.0/24" >> /etc/banip/banip.allowlist
  [[ -z $ENDPOINT ]] || grep -q "^$ENDPOINT" /etc/banip/banip.allowlist || echo "$ENDPOINT" >> /etc/banip/banip.allowlist

  /etc/init.d/banip enable
  /etc/init.d/banip restart
  msg 'banIP активирован на WAN.'
}

# ==============================================================================
# ФАЕРВОЛ И ПРОБРОСЫ ПОРТОВ
# ==============================================================================
port_listening() {
  local p=$1 hex
  if command -v netstat >/dev/null 2>&1; then
    netstat -lntu 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$p$"
    return $?
  fi
  hex=$(printf '%04X' "$p")
  awk -v h=":$hex" 'NR>1 && $4=="0A" && ($2 ~ h"$") {found=1} END{exit !found}' /proc/net/tcp /proc/net/tcp6 2>/dev/null && return 0
  awk -v h=":$hex" 'NR>1 && $4=="07" && ($2 ~ h"$") {found=1} END{exit !found}' /proc/net/udp /proc/net/udp6 2>/dev/null
}

freeport() {
  local p=$1
  if port_listening "$p"; then
    msg "Порт $p занят. Не меняем существующий сервис."; return 1
  fi
}
newonly() {
  local n=$1 d=$2
  if exists "$n"; then msg "$n уже существует: новая установка запрещена."; return 1; fi
  if [[ -d $d && -n $(ls -A "$d") ]]; then msg "В $d уже есть данные: отказ от перезаписи."; return 1; fi
}
run() {
  docker run -d --restart unless-stopped --label homestack.managed=1 "${RUN_EXTRA_ARGS[@]}" --log-opt max-size=10m --log-opt max-file=3 "$@"
}

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
  mkdir -p "$BASE/backups"
  FWBACK="$BASE/backups/firewall-$(date +%Y%m%d-%H%M%S)-$$"
  cp -p /etc/config/firewall "$FWBACK"
}

rule() {
  local id=$1 proto=$2 port=$3 target=$4 family=${5:-any} source=${6:-$WAN}
  if uci -q get "firewall.$id" >/dev/null; then
    [[ $(uci -q get "firewall.$id.name") == "HomeStack-$id" ]] || { msg "Чужая секция $id: отказ."; return 1; }
  fi
  uci set "firewall.$id=rule"; uci set "firewall.$id.name=HomeStack-$id"
  uci set "firewall.$id.src=$source"; uci set "firewall.$id.proto=$proto"
  uci set "firewall.$id.dest_port=$port"; uci set "firewall.$id.target=$target"
  uci set "firewall.$id.family=$family"
}

dnat_rule() {
  local id=$1 proto=$2 src_port=$3 dest_ip=$4 dest_port=$5
  if uci -q get "firewall.$id" >/dev/null; then
    [[ $(uci -q get "firewall.$id.name") == "HomeStack-$id" ]] || { msg "Чужая секция $id: отказ."; return 1; }
  fi
  uci set "firewall.$id=redirect"
  uci set "firewall.$id.name=HomeStack-$id"
  uci set "firewall.$id.target=DNAT"
  uci set "firewall.$id.src=$WAN"
  uci set "firewall.$id.dest=lan"
  uci set "firewall.$id.proto=$proto"
  uci set "firewall.$id.src_dport=$src_port"
  uci set "firewall.$id.dest_ip=$dest_ip"
  uci set "firewall.$id.dest_port=$dest_port"
  uci set "firewall.$id.family=ipv4"
}

fwapply() {
  if ! fw4 check; then uci revert firewall; msg 'Ошибка fw4: изменения отменены.'; return 1; fi
  uci commit firewall
  if ! /etc/init.d/firewall reload; then cp -p "$FWBACK" /etc/config/firewall; /etc/init.d/firewall reload || true; return 1; fi
  msg "Firewall сохранён. Предыдущая версия: $FWBACK"
}
closed() { fwbegin; rule "$1" "$2" "$3" REJECT any; fwapply; }

port_forwards() {
  valid_ipv4 "$PC_IP" || { msg 'Сначала укажите корректный PC_IP в мастере параметров (пункт 4).'; return 1; }
  msg "=== Пробросы портов WAN -> локальный ПК ($PC_IP) ==="
  confirm "Настроить пробросы SFTP(2244), Torrent(59193), Torserv(35231), SDI(30589), WOL(9999->9) на $PC_IP?" || return 0
  fwbegin
  dnat_rule hs_fwd_sftp 'tcp udp' 2244 "$PC_IP" 2244
  dnat_rule hs_fwd_torrent 'tcp udp' 59193 "$PC_IP" 59193
  dnat_rule hs_fwd_torserv 'tcp udp' 35231 "$PC_IP" 35231
  dnat_rule hs_fwd_sdi 'tcp udp' 30589 "$PC_IP" 30589
  dnat_rule hs_fwd_wol 'udp' 9999 "$PC_IP" 9
  if confirm 'Также пробросить внешний порт SSH 2256 -> 22 роутера?'; then
    uci set firewall.hs_fwd_ssh=redirect
    uci set firewall.hs_fwd_ssh.name='HomeStack-hs_fwd_ssh'
    uci set firewall.hs_fwd_ssh.target='DNAT'
    uci set firewall.hs_fwd_ssh.src="$WAN"
    uci set firewall.hs_fwd_ssh.proto='tcp'
    uci set firewall.hs_fwd_ssh.src_dport='2256'
    uci set firewall.hs_fwd_ssh.dest_ip="$LAN"
    uci set firewall.hs_fwd_ssh.dest_port='22'
    uci set firewall.hs_fwd_ssh.family='ipv4'
  fi
  fwapply
}

# ==============================================================================
# DOCKER-СЕРВИСЫ (НА SD-КАРТЕ)
# ==============================================================================
install_ts() {
  ready; newonly ts6-server "$BASE/teamspeak"; freeport 9987; freeport 30033
  confirm 'Установить TeamSpeak 6 (host-сеть, Query выключен)?' || return 0
  fwbegin; rule hs_ts_voice udp 9987 REJECT; rule hs_ts_file tcp 30033 REJECT; rule hs_ts_query tcp '10022 10080 10443' REJECT; fwapply
  docker pull "$TS_IMAGE"; mkdir -p "$BASE/teamspeak"
  local u g; u=$(docker run --rm --entrypoint id "$TS_IMAGE" -u); g=$(docker run --rm --entrypoint id "$TS_IMAGE" -g)
  [[ $u =~ ^[0-9]+$ && $g =~ ^[0-9]+$ ]]; chown "$u:$g" "$BASE/teamspeak"
  run --name ts6-server --network host -e TSSERVER_LICENSE_ACCEPTED=accept \
    -e TSSERVER_QUERY_HTTP_ENABLED=0 -e TSSERVER_QUERY_SSH_ENABLED=0 -e TSSERVER_QUERY_HTTPS_ENABLED=0 \
    -v "$BASE/teamspeak:/var/tsserver" "$TS_IMAGE"
  write_manifest
  msg "TeamSpeak 6 запущен на $LAN:9987. WAN открывается в пункте 14."
}

install_mumble() {
  ready; newonly mumble-server "$BASE/mumble"; freeport 64738
  confirm 'Установить Mumble (TCP/UDP 64738)?' || return 0
  local pass admin; secret pass 'Пароль входа'; secret admin 'ДРУГОЙ пароль SuperUser'; [[ $pass != "$admin" ]]
  closed hs_mumble 'tcp udp' 64738
  docker pull "$MM_IMAGE"; mkdir -p "$BASE/mumble"; chown 10000:10000 "$BASE/mumble"
  printf 'MUMBLE_CONFIG_SERVER_PASSWORD=%s\nMUMBLE_SUPERUSER_PASSWORD=%s\nMUMBLE_CONFIG_USERS=10\nMUMBLE_CONFIG_BANDWIDTH=128000\nMUMBLE_CONFIG_SENDVERSION=false\n' "$pass" "$admin" > "$BASE/mumble.env"
  run --name mumble-server --network host --env-file "$BASE/mumble.env" -v "$BASE/mumble:/data" "$MM_IMAGE"
  unset pass admin; write_manifest; msg "Mumble запущен на $LAN:64738."
}

install_rustdesk() {
  ready; newonly hbbs "$BASE/rustdesk"; newonly hbbr "$BASE/rustdesk"
  [[ -n $ENDPOINT ]] || { msg 'Укажите внешний IP/DNS в мастере параметров (пункт 4).'; return 1; }
  local p; for p in 21115 21116 21117; do freeport "$p"; done
  confirm 'Установить RustDesk (hbbs + hbbr с шифрованием -k _)?' || return 0
  fwbegin; rule hs_rd_tcp tcp '21115 21116 21117' REJECT; rule hs_rd_udp udp 21116 REJECT; rule hs_rd_web tcp '21114 21118 21119' REJECT; fwapply
  docker pull "$RD_IMAGE"; mkdir -p "$BASE/rustdesk"
  run --name hbbs --network host -v "$BASE/rustdesk:/root" "$RD_IMAGE" hbbs -r "$ENDPOINT:21117" -k _
  local i; for i in {1..20}; do [[ ! -s $BASE/rustdesk/id_ed25519.pub ]] || break; sleep 1; done
  test -s "$BASE/rustdesk/id_ed25519.pub"
  run --name hbbr --network host -v "$BASE/rustdesk:/root" "$RD_IMAGE" hbbr -k _
  write_manifest
  msg "ID=$ENDPOINT | Relay=$ENDPOINT:21117 | Публичный Key:"; cat "$BASE/rustdesk/id_ed25519.pub"; echo
}

toml() { local x=$1; x=${x//\\/\\\\}; x=${x//\"/\\\"}; x=${x//$'\r'/\\r}; x=${x//$'\n'/\\n}; x=${x//$'\t'/\\t}; printf '"%s"' "$x"; }
install_bot() {
  ready; need curl; newonly "$BOT" "$BASE/bot/data"; freeport 58913
  [[ -n $OWNER ]] || { msg 'Сначала укажите OWNER (TeamSpeak UID) в пункте 4!'; return 1; }
  confirm 'Установить MusicBot и собрать веб-панель?' || return 0
  local work="$BASE/bot/build" pass='' u
  read -r -s -p 'Пароль TeamSpeak (Enter — нет): ' pass; echo
  mkdir -p "$work" "$BASE/bot/data/bots/musicbot" "$BASE/music"
  curl -fL --retry 3 https://github.com/Splamy/TS3AudioBot/archive/refs/heads/master.tar.gz -o "$work/source.tar.gz"
  tar -xzf "$work/source.tar.gz" -C "$work"
  test -f "$work/TS3AudioBot-master/WebInterface/package.json"
  docker run --rm --name hs-web-build -e npm_config_cache=/work/.npm-cache \
    -v "$work/TS3AudioBot-master/WebInterface:/work" -w /work node:20-alpine \
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
  write_manifest
  msg "Панель MusicBot: http://$LAN:58913"
}

install_torr() {
  ready; newonly torrserver "$BASE/torrserver"; freeport 8090
  local mode user pass ip auth
  msg '1) Публичный HTTPS через Caddy: backend ТОЛЬКО 127.0.0.1:8090 + пароль'
  msg '2) LAN + WireGuard VPN: слушает LAN IP без пароля, в WAN не публикуется'
  read -r -p '> ' mode; [[ $mode == 1 || $mode == 2 ]]
  confirm 'Установить TorrServer?' || return 0
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
  write_manifest; save
  msg 'TorrServer установлен (порт 8090 в WAN закрыт).'
}

install_beszel() {
  ready; newonly beszel "$BASE/beszel"; freeport 8091
  confirm 'Установить Beszel Hub на 8091?' || return 0
  docker pull "$BES_IMAGE"; mkdir -p "$BASE/beszel"
  run --name beszel -p "$LAN:8091:8090" -v "$BASE/beszel:/beszel_data" "$BES_IMAGE"
  write_manifest
  msg "Beszel доступен локально: http://$LAN:8091"
}

# ==============================================================================
# 12. АТОМАРНОЕ ОБНОВЛЕНИЕ DOCKER-КОНТЕЙНЕРОВ (СНИМОК ДАННЫХ + HEALTHCHECK + EXIT-ОТКАТ)
# ==============================================================================
recreate_single_container() {
  local cname=$1 img=$2
  case $cname in
    ts6-server)
      run --name ts6-server --network host -e TSSERVER_LICENSE_ACCEPTED=accept \
        -e TSSERVER_QUERY_HTTP_ENABLED=0 -e TSSERVER_QUERY_SSH_ENABLED=0 -e TSSERVER_QUERY_HTTPS_ENABLED=0 \
        -v "$BASE/teamspeak:/var/tsserver" "$img" || return 1
      ;;
    mumble-server)
      run --name mumble-server --network host --env-file "$BASE/mumble.env" -v "$BASE/mumble:/data" "$img" || return 1
      ;;
    hbbs)
      run --name hbbs --network host -v "$BASE/rustdesk:/root" "$img" hbbs -r "$ENDPOINT:21117" -k _ || return 1
      ;;
    hbbr)
      run --name hbbr --network host -v "$BASE/rustdesk:/root" "$img" hbbr -k _ || return 1
      ;;
    "$BOT")
      mkdir -p "$BASE/music" || return 1
      run --name "$BOT" -p "$LAN:58913:58913" -v "$BASE/bot/data:/data" -v "$BASE/music:/music:ro" "$img" || return 1
      ;;
    torrserver)
      local tip="$LAN" tauth=0
      [[ $TOR_MODE != public ]] || { tip=127.0.0.1; tauth=1; }
      run --name torrserver --network host -e TS_IP="$tip" -e TS_PORT=8090 -e TS_HTTPAUTH="$tauth" \
        -e TS_CONF_PATH=/opt/ts/config -e TS_TORR_DIR=/opt/ts/torrents -v "$BASE/torrserver:/opt/ts" "$img" || return 1
      ;;
    beszel)
      run --name beszel -p "$LAN:8091:8090" -v "$BASE/beszel:/beszel_data" "$img" || return 1
      ;;
    hs-caddy)
      run --name hs-caddy --network host -v "$BASE/https:/etc/caddy:ro" \
        -v "$BASE/https/data:/data" -v "$BASE/https/config:/config" "$img" || return 1
      ;;
    *)
      msg "Неизвестный контейнер: $cname"; return 1
      ;;
  esac
}

# Прикладная проверка готовности сервиса (HTTP-запрос или проверка сокета)
app_ready_check() {
  local cname=$1 code=''
  case $cname in
    beszel)
      command -v curl >/dev/null 2>&1 || return 1
      curl -fsS --max-time 3 "http://$LAN:8091/" >/dev/null 2>&1
      ;;
    torrserver)
      command -v curl >/dev/null 2>&1 || return 1
      local thost="$LAN"
      [[ $TOR_MODE != public ]] || thost='127.0.0.1'
      code=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "http://$thost:8090/" 2>/dev/null || echo 000)
      [[ $code == 200 || $code == 401 ]]
      ;;
    "$BOT")
      command -v curl >/dev/null 2>&1 || return 1
      code=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "http://$LAN:58913/" 2>/dev/null || echo 000)
      [[ $code == 200 || $code == 301 || $code == 302 ]]
      ;;
    hs-caddy)
      command -v curl >/dev/null 2>&1 || return 1
      curl -fsS --max-time 3 "http://127.0.0.1:2019/config/" >/dev/null 2>&1
      ;;
    ts6-server)    port_listening 9987 ;;
    mumble-server) port_listening 64738 ;;
    hbbs)          port_listening 21116 ;;
    hbbr)          port_listening 21117 ;;
    *)             return 1 ;;
  esac
}

# Ожидание готовности по реальному дедлайну $SECONDS
wait_container_healthy() {
  local cname=$1 max_sec=${2:-60} start_sec=$SECONDS deadline status health restarts
  deadline=$((start_sec + max_sec))
  while (( SECONDS < deadline )); do
    exists "$cname" || return 1
    status=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo dead)
    [[ $status == running ]] || return 1
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cname" 2>/dev/null || echo none)
    restarts=$(docker inspect -f '{{.RestartCount}}' "$cname" 2>/dev/null || echo 1)

    if [[ $health == healthy ]]; then
      app_ready_check "$cname" && return 0
    elif [[ $health == unhealthy ]]; then
      return 1
    elif [[ $health == none && $((SECONDS - start_sec)) -ge 5 && $restarts == 0 ]]; then
      if app_ready_check "$cname"; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

service_data_rel() {
  case $1 in
    ts6-server)    echo 'teamspeak' ;;
    mumble-server) echo 'mumble' ;;
    hbbs|hbbr)     echo 'rustdesk' ;;
    "$BOT")        echo 'bot/data' ;;
    torrserver)    echo 'torrserver/config' ;;
    beszel)        echo 'beszel' ;;
    hs-caddy)      echo 'https' ;;
    *)             echo '' ;;
  esac
}

restore_service_snapshot() {
  local snap=$1 rel_dir=$2 stamp=$3
  local upd_stage broken_dir
  upd_stage=$(mktemp -d "$BASE/.upd-stage-XXXXXX")
  if ! tar -xzf "$snap" -C "$upd_stage" || [[ ! -d "$upd_stage/$rel_dir" ]]; then
    rm -rf "$upd_stage" 2>/dev/null || true
    return 1
  fi
  broken_dir="$BASE/.upd-broken-${stamp}-${rel_dir//\//_}"
  if [[ -e "$BASE/$rel_dir" ]]; then
    if ! mv "$BASE/$rel_dir" "$broken_dir"; then
      rm -rf "$upd_stage" 2>/dev/null || true
      return 1
    fi
  fi
  mkdir -p "$(dirname "$BASE/$rel_dir")"
  if ! mv "$upd_stage/$rel_dir" "$BASE/$rel_dir"; then
    [[ ! -e $broken_dir ]] || mv "$broken_dir" "$BASE/$rel_dir" 2>/dev/null || true
    rm -rf "$upd_stage" 2>/dev/null || true
    return 1
  fi
  rm -rf "$broken_dir" "$upd_stage" 2>/dev/null || true
  return 0
}

update_one_service() (
  set -Eeuo pipefail
  cname=$1
  img=$2
  if ! exists "$cname"; then
    exit 0
  fi
  if ! managed "$cname"; then
    msg "Пропуск $cname (контейнер создан не через HomeStack — сначала выполните пункт 20)."
    exit 0
  fi

  msg "Проверка обновления для $cname ($img)..."
  old_img_id=$(docker inspect -f '{{.Image}}' "$cname" 2>/dev/null || true)
  docker pull "$img"
  new_img_id=$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null || true)

  if [[ -n $old_img_id && $old_img_id == "$new_img_id" ]]; then
    msg "$cname уже использует самый свежий образ."
    exit 0
  fi

  was_running=$(docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null || echo false)
  stamp=$(date +%Y%m%d-%H%M%S)
  tx_id="upd-${stamp}-${cname}-$$"
  bak_name="hs-upd-${stamp}-${cname}"
  rel_dir=$(service_data_rel "$cname")
  wait_sec=60
  [[ $cname != "$BOT" ]] || wait_sec=90
  data_snap=''
  tmp_snap=''
  snapshot_ready=false
  renamed=false
  upd_done=false

  rollback_update() {
    local rc=$?
    trap - ERR EXIT
    set +e
    RUN_EXTRA_ARGS=()
    [[ -z $tmp_snap ]] || rm -f "$tmp_snap" 2>/dev/null || true
    if [[ $upd_done == true ]]; then
      return 0
    fi

    msg "Сбой обновления $cname (код $rc) — выполняем полный откат..."
    local tx_cids still_tx new_removed=true data_restored=true
    if ! tx_cids=$(docker ps -aq --filter "label=homestack.transaction=$tx_id" 2>/dev/null); then
      new_removed=false
      msg "КРИТИЧНО: Не удалось получить состояние Docker для tx=$tx_id! Замена данных заблокирована."
    elif [[ -n $tx_cids ]]; then
      docker rm -f $tx_cids >/dev/null 2>&1 || true
      if ! still_tx=$(docker ps -aq --filter "label=homestack.transaction=$tx_id" 2>/dev/null); then
        new_removed=false
        msg "КРИТИЧНО: Не удалось подтвердить удаление нового контейнера $cname!"
      elif [[ -n $still_tx ]]; then
        new_removed=false
        msg "КРИТИЧНО: Новый контейнер $cname не удалён! Замена данных и запуск старого заблокированы."
      fi
    fi

    if [[ $new_removed == false ]]; then
      exit "$rc"
    fi

    if [[ $snapshot_ready == true && -n $data_snap && -f $data_snap && -n $rel_dir ]]; then
      if ! restore_service_snapshot "$data_snap" "$rel_dir" "$stamp"; then
        data_restored=false
        msg "КРИТИЧНО: Не удалось восстановить данные $rel_dir из $data_snap! Старый контейнер ($bak_name) не запущен."
      fi
    fi

    if [[ $renamed == true ]]; then
      if ! docker rename "$bak_name" "$cname" >/dev/null 2>&1; then
        msg "ВНИМАНИЕ: Не удалось вернуть имя $bak_name -> $cname."
      fi
    fi
    if [[ $data_restored == true && $was_running == true ]] && exists "$cname"; then
      if ! docker start "$cname" >/dev/null 2>&1; then
        msg "ВНИМАНИЕ: Данные восстановлены, но старый контейнер $cname не запустился."
      fi
    fi
    exit "$rc"
  }
  trap rollback_update EXIT

  msg "Остановка $cname и создание атомарного снимка данных..."
  docker stop -t 20 "$cname" >/dev/null
  [[ $(docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null || echo true) == false ]] || {
    msg "Не удалось остановить $cname — обновление отменено."
    exit 1
  }

  if [[ -n $rel_dir && -d "$BASE/$rel_dir" ]]; then
    mkdir -p "$BASE/backups"
    data_snap="$BASE/backups/upd-data-${stamp}-${cname}.tar.gz"
    tmp_snap="$data_snap.tmp"
    tar -czf "$tmp_snap" -C "$BASE" "$rel_dir"
    tar -tzf "$tmp_snap" >/dev/null
    chmod 600 "$tmp_snap"
    mv "$tmp_snap" "$data_snap"
    tmp_snap=''
    snapshot_ready=true
  fi

  docker rename "$cname" "$bak_name"
  renamed=true

  RUN_EXTRA_ARGS=(--label "homestack.transaction=$tx_id")
  recreate_single_container "$cname" "$img"
  RUN_EXTRA_ARGS=()
  wait_container_healthy "$cname" "$wait_sec"

  if [[ $was_running != true ]]; then
    docker stop -t 10 "$cname" >/dev/null 2>&1 || true
  fi
  docker rm "$bak_name" >/dev/null 2>&1 || true
  upd_done=true
  trap - EXIT
  msg "Контейнер $cname успешно обновлён и проверен (снимок: ${data_snap:-нет})."
)

update_rustdesk_pair() (
  set -Eeuo pipefail
  if ! exists hbbs && ! exists hbbr; then
    exit 0
  fi
  if (exists hbbs && ! managed hbbs) || (exists hbbr && ! managed hbbr); then
    msg 'Пропуск RustDesk (hbbs/hbbr созданы не через HomeStack — сначала выполните пункт 20).'
    exit 0
  fi

  msg "Проверка обновления RustDesk ($RD_IMAGE)..."
  id_s=$(docker inspect -f '{{.Image}}' hbbs 2>/dev/null || true)
  id_r=$(docker inspect -f '{{.Image}}' hbbr 2>/dev/null || true)
  docker pull "$RD_IMAGE"
  new_id=$(docker image inspect -f '{{.Id}}' "$RD_IMAGE" 2>/dev/null || true)

  if [[ $id_s == "$new_id" && $id_r == "$new_id" ]]; then
    msg 'RustDesk (hbbs + hbbr) уже использует самый свежий образ.'
    exit 0
  fi

  run_s=false; run_r=false
  [[ $(docker inspect -f '{{.State.Running}}' hbbs 2>/dev/null || echo false) != true ]] || run_s=true
  [[ $(docker inspect -f '{{.State.Running}}' hbbr 2>/dev/null || echo false) != true ]] || run_r=true
  stamp=$(date +%Y%m%d-%H%M%S)
  tx_id="upd-${stamp}-rustdesk-$$"
  bak_s="hs-upd-${stamp}-hbbs"
  bak_r="hs-upd-${stamp}-hbbr"
  renamed_s=false; renamed_r=false
  data_snap=''; tmp_snap=''; snapshot_ready=false
  upd_done=false

  rollback_rd() {
    local rc=$?
    trap - ERR EXIT
    set +e
    RUN_EXTRA_ARGS=()
    [[ -z $tmp_snap ]] || rm -f "$tmp_snap" 2>/dev/null || true
    if [[ $upd_done == true ]]; then
      return 0
    fi

    msg "Сбой обновления RustDesk (код $rc) — выполняем полный откат пары..."
    local tx_cids still_tx new_removed=true data_restored=true
    if ! tx_cids=$(docker ps -aq --filter "label=homestack.transaction=$tx_id" 2>/dev/null); then
      new_removed=false
      msg "КРИТИЧНО: Не удалось получить состояние Docker для tx=$tx_id! Замена данных заблокирована."
    elif [[ -n $tx_cids ]]; then
      docker rm -f $tx_cids >/dev/null 2>&1 || true
      if ! still_tx=$(docker ps -aq --filter "label=homestack.transaction=$tx_id" 2>/dev/null); then
        new_removed=false
        msg 'КРИТИЧНО: Не удалось подтвердить удаление новых контейнеров RustDesk!'
      elif [[ -n $still_tx ]]; then
        new_removed=false
        msg 'КРИТИЧНО: Новые контейнеры RustDesk не удалены! Замена данных заблокирована.'
      fi
    fi

    if [[ $new_removed == false ]]; then
      exit "$rc"
    fi

    if [[ $snapshot_ready == true && -n $data_snap && -f $data_snap ]]; then
      if ! restore_service_snapshot "$data_snap" 'rustdesk' "$stamp"; then
        data_restored=false
        msg "КРИТИЧНО: Не удалось восстановить данные rustdesk из $data_snap!"
      fi
    fi

    if [[ $renamed_s == true ]]; then
      docker rename "$bak_s" hbbs >/dev/null 2>&1 || msg "ВНИМАНИЕ: Не удалось вернуть $bak_s -> hbbs."
    fi
    if [[ $renamed_r == true ]]; then
      docker rename "$bak_r" hbbr >/dev/null 2>&1 || msg "ВНИМАНИЕ: Не удалось вернуть $bak_r -> hbbr."
    fi

    if [[ $data_restored == true ]]; then
      [[ $run_s != true ]] || docker start hbbs >/dev/null 2>&1 || msg 'ВНИМАНИЕ: hbbs не запустился после отката.'
      [[ $run_r != true ]] || docker start hbbr >/dev/null 2>&1 || msg 'ВНИМАНИЕ: hbbr не запустился после отката.'
    fi
    exit "$rc"
  }
  trap rollback_rd EXIT

  if exists hbbs; then
    docker stop -t 20 hbbs >/dev/null
    [[ $(docker inspect -f '{{.State.Running}}' hbbs 2>/dev/null || echo true) == false ]] || exit 1
  fi
  if exists hbbr; then
    docker stop -t 20 hbbr >/dev/null
    [[ $(docker inspect -f '{{.State.Running}}' hbbr 2>/dev/null || echo true) == false ]] || exit 1
  fi

  if [[ -d "$BASE/rustdesk" ]]; then
    mkdir -p "$BASE/backups"
    data_snap="$BASE/backups/upd-data-${stamp}-rustdesk.tar.gz"
    tmp_snap="$data_snap.tmp"
    tar -czf "$tmp_snap" -C "$BASE" rustdesk
    tar -tzf "$tmp_snap" >/dev/null
    chmod 600 "$tmp_snap"
    mv "$tmp_snap" "$data_snap"
    tmp_snap=''
    snapshot_ready=true
  fi

  if exists hbbs; then docker rename hbbs "$bak_s"; renamed_s=true; fi
  if exists hbbr; then docker rename hbbr "$bak_r"; renamed_r=true; fi

  RUN_EXTRA_ARGS=(--label "homestack.transaction=$tx_id")
  recreate_single_container hbbs "$RD_IMAGE"
  wait_container_healthy hbbs 60
  recreate_single_container hbbr "$RD_IMAGE"
  wait_container_healthy hbbr 60
  RUN_EXTRA_ARGS=()

  [[ $run_s == true ]] || docker stop -t 10 hbbs >/dev/null 2>&1 || true
  [[ $run_r == true ]] || docker stop -t 10 hbbr >/dev/null 2>&1 || true
  docker rm -f "$bak_s" "$bak_r" >/dev/null 2>&1 || true
  upd_done=true
  trap - EXIT
  msg 'RustDesk (hbbs + hbbr) успешно обновлён и проверен!'
)

update_containers() {
  ready
  msg '=== Обновление Docker-контейнеров HomeStack ==='
  msg '1) Обновить ВСЕ установленные контейнеры'
  msg '2) Только TorrServer'
  msg '3) Только TeamSpeak 6'
  msg '4) Только Mumble'
  msg '5) Только RustDesk (hbbs + hbbr парой)'
  msg '6) Только MusicBot'
  msg '7) Только Beszel Hub'
  msg '8) Только Caddy HTTPS'
  local choice; read -r -p '> ' choice
  [[ $choice =~ ^[1-8]$ ]] || return 1

  case $choice in
    1)
      update_one_service torrserver "$TOR_IMAGE"
      update_one_service ts6-server "$TS_IMAGE"
      update_one_service mumble-server "$MM_IMAGE"
      update_rustdesk_pair
      update_one_service "$BOT" "$BOT_IMAGE"
      update_one_service beszel "$BES_IMAGE"
      update_one_service hs-caddy "$CADDY_IMAGE"
      ;;
    2) update_one_service torrserver "$TOR_IMAGE" ;;
    3) update_one_service ts6-server "$TS_IMAGE" ;;
    4) update_one_service mumble-server "$MM_IMAGE" ;;
    5) update_rustdesk_pair ;;
    6) update_one_service "$BOT" "$BOT_IMAGE" ;;
    7) update_one_service beszel "$BES_IMAGE" ;;
    8) update_one_service hs-caddy "$CADDY_IMAGE" ;;
  esac

  write_manifest
  if confirm 'Удалить старые неиспользуемые образы Docker (освободить место на SD-карте)?'; then
    docker image prune -f >/dev/null 2>&1 || true
    msg 'Старые образы очищены.'
  fi
}

caddy_base() {
  [[ -n $EMAIL ]] || { msg 'Укажите EMAIL в пункте 4.'; return 1; }
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
    if [[ $(docker inspect -f '{{.State.Running}}' hs-caddy) == true ]]; then
      docker exec hs-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
    else
      docker start hs-caddy >/dev/null
    fi
  else
    freeport 443; freeport 2019
    run --name hs-caddy --network host -v "$BASE/https:/etc/caddy:ro" \
      -v "$BASE/https/data:/data" -v "$BASE/https/config:/config" "$CADDY_IMAGE"
  fi
  write_manifest
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
  msg "Импортируйте $p/client.p12 в браузер/телефон (пароль в $p/export-pass.txt)."
}

loopback_torr() {
  local lines
  if command -v netstat >/dev/null 2>&1; then
    lines=$(netstat -lnt 2>/dev/null | awk '$4 ~ /:8090$/ {print $4}')
    [[ $lines == '127.0.0.1:8090' ]] || { msg "Для публикации TorrServer нужен единственный listener 127.0.0.1:8090. Сейчас: ${lines:-нет}"; return 1; }
  else
    lines=$(awk 'NR>1 && $4=="0A" && $2 ~ /:1F9A$/ {print $2}' /proc/net/tcp /proc/net/tcp6 2>/dev/null)
    [[ $lines == '0100007F:1F9A' ]] || { msg "Для публикации TorrServer нужен единственный listener 127.0.0.1:8090 (0100007F:1F9A). Сейчас: ${lines:-нет}"; return 1; }
  fi
}

site() (
  set -Eeuo pipefail
  ready; need curl; need jq
  kind='' domain='' upstream='' path='' backup='' cfile_bak='' pass='' user='' hash='' code='' temp=''
  site_existed=false
  cfile_existed=false
  site_modified=false
  cfile_modified=false
  site_committed=false

  rollback_site() {
    [[ -z $temp ]] || rm -f "$temp" 2>/dev/null || true
    if [[ $site_committed == false ]]; then
      if [[ $site_modified == true && -n $path ]]; then
        if [[ $site_existed == true && -n $backup && -f $backup ]]; then
          cp -p "$backup" "$path"
        elif [[ $site_existed == false ]]; then
          rm -f "$path"
        fi
      fi
      if [[ $cfile_modified == true ]]; then
        if [[ $cfile_existed == true && -n $cfile_bak && -f $cfile_bak ]]; then
          cp -p "$cfile_bak" "$BASE/https/Caddyfile"
        elif [[ $cfile_existed == false ]]; then
          rm -f "$BASE/https/Caddyfile"
        fi
      fi
    fi
  }
  trap rollback_site EXIT

  msg '1) TorrServer — Basic Auth, только loopback-backend (127.0.0.1:8090)'
  msg '2) MusicBot — клиентский сертификат (.p12) + API-токен'
  msg '3) Beszel — штатный аккаунт'
  msg '4) LuCI — отдельный пароль Caddy + штатный вход LuCI'
  read -r -p '> ' kind; [[ $kind =~ ^[1-4]$ ]]
  read -r -p 'Полный поддомен (без https://): ' domain
  domain=${domain,,}
  [[ ${#domain} -lt 254 && $domain =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,63}$ && $domain != *..* ]] || exit 1
  case $kind in
    1) loopback_torr; upstream=127.0.0.1:8090
       read -r -p 'Существующий логин TorrServer: ' user; [[ $user =~ ^[A-Za-z0-9]{3,32}$ ]]
       secret pass 'Тот же пароль TorrServer'
       code=$(curl -sS --max-time 8 -o /dev/null -w '%{http_code}' "http://$upstream/torrents")
       [[ $code == 401 ]] || { msg "Без авторизации backend вернул $code вместо 401."; exit 1; }
       cf=$(mktemp); chmod 600 "$cf"
       printf 'user = "%s:%s"\n' "$user" "$pass" > "$cf"
       code=$(curl --config "$cf" -sS --max-time 8 -o /dev/null -w '%{http_code}' "http://$upstream/"); rm -f "$cf"
       [[ $code =~ ^[23][0-9][0-9]$ ]] || { msg 'Пароль backend не подтверждён.'; exit 1; } ;;
    2) upstream="$LAN:58913"; ask upstream 'Backend MusicBot IP:порт'
       client_cert; confirm 'Клиентский .p12 импортирован?' || exit 0 ;;
    3) upstream="$LAN:8091"; ask upstream 'Backend Beszel IP:порт'
       if exists beszel; then
         docker inspect beszel --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -Eq '^AUTO_LOGIN=.+$' && { msg 'AUTO_LOGIN задан: публикация запрещена.'; exit 1; }
       fi
       confirm 'Аккаунт Beszel уже создан?' || exit 0 ;;
    4) upstream="$LAN:80"; ask upstream 'Backend LuCI IP:порт'
       read -r -p 'Отдельный логин Caddy: ' user; [[ $user =~ ^[A-Za-z0-9]{3,32}$ ]]; secret pass 'Отдельный пароль Caddy'
       confirm 'Продолжить настройку HTTPS для LuCI?' || exit 0 ;;
  esac
  [[ $upstream =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]{2,5}$ ]] || exit 1
  path="$BASE/https/sites/$domain.caddy"
  if [[ -f $path ]]; then
    site_existed=true
    confirm "Сайт $domain уже есть. Заменить его конфигурацию?" || exit 0
  else
    confirm "Настроить https://$domain -> $upstream?" || exit 0
  fi

  docker pull "$CADDY_IMAGE"
  if [[ -f $BASE/https/Caddyfile ]]; then
    cfile_existed=true
    cfile_bak="$BASE/backups/Caddyfile-$(date +%Y%m%d-%H%M%S)"
    cp -p "$BASE/https/Caddyfile" "$cfile_bak"
  fi
  if [[ $site_existed == true ]]; then
    backup="$BASE/backups/$domain-$(date +%Y%m%d-%H%M%S).caddy"
    cp -p "$path" "$backup"
  fi

  cfile_modified=true
  caddy_base

  temp=$(mktemp "$BASE/https/sites/.site-XXXXXX")
  {
    printf '%s {\n bind 0.0.0.0\n tls {\n  issuer acme {\n   disable_http_challenge\n  }\n' "$domain"
    if [[ $kind == 2 ]]; then
      printf '  client_auth {\n   mode require_and_verify\n   trust_pool file /etc/caddy/pki/ca.crt\n  }\n'
    fi
    printf ' }\n'
    if [[ $kind == 1 || $kind == 4 ]]; then
      hash=$(printf '%s\n' "$pass" | docker run --rm -i "$CADDY_IMAGE" caddy hash-password)
      [[ $hash == '$2'* ]] || { msg 'Не получен bcrypt-хеш.' >&2; exit 1; }
      printf ' basic_auth {\n  %s %s\n }\n' "$user" "$hash"
    fi
    printf ' reverse_proxy %s {\n' "$upstream"
    [[ $kind != 1 ]] || printf '  flush_interval -1\n'
    [[ $kind != 4 ]] || printf '  header_up -Authorization\n'
    printf ' }\n}\n'
  } > "$temp"
  unset pass

  site_modified=true
  mv "$temp" "$path"
  temp=''
  caddy_reload
  site_committed=true
  trap - EXIT
  msg "Настроено: https://$domain. Включите WAN TCP443 в пункте 14 (предварительно освободив 443 от Nginx)."
)
caddy_apply() { ready; caddy_reload; }

wan_menu() {
  ready
  msg '1) Открыть TS6 (UDP 9987, TCP 30033)'
  msg '2) Открыть Mumble (TCP/UDP 64738)'
  msg '3) Открыть RustDesk (TCP 21115-21117, UDP 21116)'
  msg '4) Открыть HTTPS Caddy (TCP 443)'
  msg '5) Закрыть все публичные сервисы HomeStack'
  local n; read -r -p '> ' n; [[ $n =~ ^[1-5]$ ]]
  case $n in
    1) managed ts6-server || { msg 'Контейнер ts6-server не найден.'; return 1; } ;;
    2) managed mumble-server || { msg 'Контейнер mumble-server не найден.'; return 1; } ;;
    3) managed hbbs && managed hbbr || { msg 'Контейнеры hbbs/hbbr не найдены.'; return 1; } ;;
    4) managed hs-caddy || { msg 'Контейнер hs-caddy не найден.'; return 1; } ;;
  esac
  confirm 'Применить изменение правил WAN?' || return 0
  fwbegin
  case $n in
    1) rule hs_ts_v6 'tcp udp' '9987 30033' REJECT ipv6; rule hs_ts_voice udp 9987 ACCEPT ipv4; rule hs_ts_file tcp 30033 ACCEPT ipv4 ;;
    2) rule hs_mm_v6 'tcp udp' 64738 REJECT ipv6; rule hs_mumble 'tcp udp' 64738 ACCEPT ipv4 ;;
    3) rule hs_rd_v6 'tcp udp' '21115 21116 21117' REJECT ipv6; rule hs_rd_tcp tcp '21115 21116 21117' ACCEPT ipv4; rule hs_rd_udp udp 21116 ACCEPT ipv4 ;;
    4) rule hs_https_v6 tcp 443 REJECT ipv6; rule hs_https tcp 443 ACCEPT ipv4 ;;
    5) rule hs_ts_voice udp 9987 REJECT; rule hs_ts_file tcp 30033 REJECT; rule hs_mumble 'tcp udp' 64738 REJECT; rule hs_rd_tcp tcp '21115 21116 21117' REJECT; rule hs_rd_udp udp 21116 REJECT; rule hs_https tcp 443 REJECT ;;
  esac
  fwapply
}

# ==============================================================================
# БЕЗОПАСНАЯ МИГРАЦИЯ NGINX -> LIGHTTPD (ОТКАТ СТРОГО НА NGINX)
# ==============================================================================
lighttpd_migrate() {
  ready; need apk; need curl
  if pidof lighttpd >/dev/null 2>&1; then
    msg 'lighttpd уже работает.'; return 0
  fi
  [[ ! -e /etc/init.d/hs-luci-backend ]] || { msg 'Служба hs-luci-backend уже есть.'; return 1; }
  confirm 'Перевести веб-интерфейс с Nginx на lighttpd (освобождает порт 443 для Caddy)?' || return 0
  [[ -z $(uci changes uhttpd) ]] || return 1

  local nrun=false nen=false len=false
  pidof nginx >/dev/null 2>&1 && nrun=true || true
  /etc/init.d/nginx enabled >/dev/null 2>&1 && nen=true || true
  /etc/init.d/lighttpd enabled >/dev/null 2>&1 && len=true || true

  apk update
  local pkg
  for pkg in lighttpd lighttpd-mod-proxy uhttpd uhttpd-mod-ubus rpcd luci-base; do
    apk info -e "$pkg" >/dev/null 2>&1 || apk add "$pkg"
  done

  /etc/init.d/uhttpd stop 2>/dev/null || true
  /etc/init.d/uhttpd disable 2>/dev/null || true

  local work="$BASE/luci-migration"
  restore_nginx_early() {
    [[ ! -f $work/test.pid ]] || kill "$(cat "$work/test.pid")" 2>/dev/null || true
    /etc/init.d/hs-luci-backend stop 2>/dev/null || true
    /etc/init.d/hs-luci-backend disable 2>/dev/null || true
    rm -f /etc/init.d/hs-luci-backend
    /etc/init.d/uhttpd stop 2>/dev/null || true
    /etc/init.d/uhttpd disable 2>/dev/null || true
    if [[ $nen == true ]]; then /etc/init.d/nginx enable 2>/dev/null || true; fi
    if [[ $nrun == true ]] && ! pidof nginx >/dev/null 2>&1; then /etc/init.d/nginx start 2>/dev/null || true; fi
  }
  trap 'restore_nginx_early; echo "Ошибка миграции на строке $LINENO — работа Nginx сохранена." >&2' ERR

  freeport 18080; freeport 18088
  [[ ! -d $work ]] || { msg "Каталог $work уже есть. Удалите его перед повторным запуском."; return 1; }
  mkdir -p "$work"

  [[ ! -d /etc/lighttpd ]] || tar -czf "$work/lighttpd.old.tar.gz" -C /etc lighttpd

  cat > /etc/init.d/hs-luci-backend <<'EOF'
#!/bin/sh /etc/rc.common
START=49
USE_PROCD=1
start_service() {
  procd_open_instance
  procd_set_param command /usr/sbin/uhttpd -f -h /www -p 127.0.0.1:18088 -x /cgi-bin -u /ubus -t 120 -T 60
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
server.max-request-size = 2097152
server.stream-request-body = 1
server.stream-response-body = 1
server.reject-expect-100-with-417 = "disable"
proxy.header = ( "map-host-request" => ( "-" => "-" ) )
proxy.server = ( "" => ( ( "host" => "127.0.0.1", "port" => 18088 ) ) )
EOF
  lighttpd -tt -f "$work/test.conf"
  lighttpd -f "$work/test.conf"
  msg "Проверьте http://$LAN:18080/cgi-bin/luci/ (включая загрузку/скачивание в Quick File Manager)."
  if ! confirm 'Всё работает?'; then
    restore_nginx_early
    trap - ERR
    msg 'Отменено, Nginx не затрагивался.'; return 0
  fi

  kill "$(cat "$work/test.pid")"
  cat > "$work/rollback.sh" <<EOF
#!/bin/sh
/etc/init.d/lighttpd stop 2>/dev/null || true
/etc/init.d/hs-luci-backend stop 2>/dev/null || true
/etc/init.d/hs-luci-backend disable 2>/dev/null || true
/etc/init.d/uhttpd stop 2>/dev/null || true
/etc/init.d/uhttpd disable 2>/dev/null || true
rm -f /etc/init.d/hs-luci-backend /etc/lighttpd/lighttpd.conf
if [ -f '$work/lighttpd.old.tar.gz' ]; then tar -xzf '$work/lighttpd.old.tar.gz' -C /etc; fi
EOF
  [[ $len == true ]] && echo '/etc/init.d/lighttpd enable' >> "$work/rollback.sh" || echo '/etc/init.d/lighttpd disable' >> "$work/rollback.sh"
  [[ $nen == true ]] && echo '/etc/init.d/nginx enable' >> "$work/rollback.sh" || echo '/etc/init.d/nginx disable' >> "$work/rollback.sh"
  [[ $nrun != true ]] || echo '/etc/init.d/nginx start' >> "$work/rollback.sh"
  chmod 700 "$work/rollback.sh"

  trap - ERR
  nohup sh -c "sleep 180; [ -f '$work/confirmed' ] || sh '$work/rollback.sh'" > "$work/rollback.log" 2>&1 < /dev/null &
  sed 's/server.port = 18080/server.port = 80/' "$work/test.conf" > /etc/lighttpd/lighttpd.conf
  /etc/init.d/nginx stop 2>/dev/null || true; /etc/init.d/nginx disable 2>/dev/null || true
  /etc/init.d/lighttpd enable; /etc/init.d/hs-luci-backend enable; /etc/init.d/lighttpd restart

  msg "Есть 180 секунд: откройте http://$LAN/cgi-bin/luci/ ."
  local answer=''
  if read -r -t 150 -p 'Введите KEEP для подтверждения: ' answer && [[ $answer == KEEP ]]; then
    touch "$work/confirmed"; msg 'Переключение на lighttpd подтверждено! Порт 443 теперь свободен для Caddy.'
  else
    sh "$work/rollback.sh"; touch "$work/confirmed"; msg 'Выполнен полный откат на Nginx.'
  fi
}

# ==============================================================================
# WIREGUARD VPN
# ==============================================================================
wireguard() (
  set -Eeuo pipefail
  ready; need apk
  apk update
  apk info -e wireguard-tools >/dev/null 2>&1 || apk add wireguard-tools 2>/dev/null || true
  apk info -e kmod-wireguard >/dev/null 2>&1 || apk add kmod-wireguard 2>/dev/null || true
  apk add luci-proto-wireguard 2>/dev/null || true
  need wg

  [[ -n $ENDPOINT ]] || { msg 'Укажите внешний IP/DNS.'; exit 1; }
  [[ -z $(uci -q get network.hsmedia || true) ]] || { msg 'Интерфейс network.hsmedia уже существует.'; exit 1; }
  [[ -z $(uci changes network) ]] || exit 1
  [[ -z $(uci -q get firewall.hs_wgzone || true) ]] || exit 1
  freeport 51820

  p="$BASE/wireguard"
  if [[ -e $p ]]; then
    confirm "Обнаружен каталог $p от прошлой попытки. Удалить его и создать ключи заново?" || exit 1
    rm -rf "$p"
  fi

  confirm 'Создать WireGuard (UDP 51820)?' || exit 0

  fwbegin
  nb="$BASE/backups/network-$(date +%Y%m%d-%H%M%S)"
  ok=false
  cp -p /etc/config/network "$nb"; mkdir -p "$p"
  wg genkey > "$p/server.key"; wg pubkey < "$p/server.key" > "$p/server.pub"
  wg genkey > "$p/client.key"; wg pubkey < "$p/client.key" > "$p/client.pub"; wg genpsk > "$p/psk"

  rollback_wg() {
    if [[ $ok == false ]]; then
      uci -q revert network || true
      uci -q revert firewall || true
      ifdown hsmedia 2>/dev/null || true
      cp -p "$nb" /etc/config/network 2>/dev/null || true
      cp -p "$FWBACK" /etc/config/firewall 2>/dev/null || true
      /etc/init.d/firewall reload 2>/dev/null || true
      rm -rf "$p" 2>/dev/null || true
      echo 'Откат WireGuard выполнен.' >&2
    fi
  }
  trap rollback_wg EXIT

  uci set network.hsmedia=interface; uci set network.hsmedia.proto=wireguard
  uci set "network.hsmedia.private_key=$(cat "$p/server.key")"; uci set network.hsmedia.listen_port=51820
  uci add_list network.hsmedia.addresses=10.77.77.1/24
  peer=$(uci add network wireguard_hsmedia)
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
  chmod 600 "$p/"*
  ok=true
  trap - EXIT
  msg "Клиентский конфиг: $p/client.conf"
)

status() {
  msg '=== OpenWrt ==='; cat /etc/openwrt_release
  msg '=== Диски и Overlay ==='; df -h
  msg '=== Статус HDD ==='
  if hdd_mounted; then echo "Смонтирован: $HDD_MOUNT (UUID: ${HDD_UUID:-не задан})"; else echo "НЕ смонтирован: $HDD_MOUNT"; fi
  msg '=== Тюнинг ядра ==='; sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.netfilter.nf_conntrack_max
  msg '=== Docker Root ==='; docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "$DOCKER_ROOT"
  msg '=== Контейнеры ==='; docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
}

# ==============================================================================
# 17. РЕЗЕРВНОЕ КОПИРОВАНИЕ НА HDD (СОВМЕСТИМО С BUSYBOX TAR -X)
# ==============================================================================
tar_base_clean() {
  local out_tar=$1 src_dir=$2 ex
  ex=$(mktemp /tmp/hs-tar-ex.XXXXXX)
  printf '%s\n' \
    './backups' './backups/*' 'backups' 'backups/*' \
    './music' './music/*' 'music' 'music/*' \
    './bot/build' './bot/build/*' 'bot/build' 'bot/build/*' \
    './.restore-stage-*' '.restore-stage-*' \
    './.rollback-*' '.rollback-*' \
    './.upd-*' '.upd-*' > "$ex"
  if ! tar -X "$ex" -czf "$out_tar" -C "$src_dir" .; then
    rm -f "$ex"
    return 1
  fi
  rm -f "$ex"
}

backup_dir() {
  if hdd_mounted; then
    echo "$HDD_MOUNT/homestack-backups"
  else
    echo "$BASE/backups"
  fi
}

backup() (
  set -Eeuo pipefail
  validate_all_paths
  need tar
  bdir=$(backup_dir)
  if ! hdd_mounted; then
    msg "ВНИМАНИЕ: Внешний HDD не смонтирован! Бэкап пойдёт на SD-карту ($bdir)."
  fi
  mkdir -p "$bdir" "$BASE"
  msg "Резервная копия будет сохранена в: $bdir"
  msg 'Примечание: каталоги ./backups, ./music, ./bot/build и временные снимки в архив не включаются.'
  confirm 'Создать бэкап конфигов роутера (включая ключи SSH) и данных HomeStack?' || exit 0

  dest="$bdir/stack-$(date +%Y%m%d-%H%M%S).tar.gz"
  tmp_dest="$dest.tmp"
  names=()
  if command -v docker >/dev/null 2>&1; then
    docker info >/dev/null || { msg 'Docker демон не отвечает — создание согласованного бэкапа невозможно.'; exit 1; }
    write_manifest
    if ! running_list=$(docker ps -q --filter label=homestack.managed=1); then
      msg 'Не удалось получить список запущенных контейнеров Docker.'
      exit 1
    fi
    while IFS= read -r n; do
      [[ -z $n ]] || names+=("$n")
    done <<< "$running_list"
  fi

  resume() {
    rm -f "$tmp_dest" 2>/dev/null || true
    if ((${#names[@]})); then
      docker start "${names[@]}" >/dev/null 2>&1 || true
    fi
  }
  trap resume EXIT

  ((${#names[@]} == 0)) || docker stop -t 20 "${names[@]}" >/dev/null

  cat > "$BASE/manifest.txt" <<EOF
format=homestack-backup
format_version=1
created_at=$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)
base_path=$BASE
EOF

  snapshot="$BASE/system-snapshot"; mkdir -p "$snapshot"
  cp -p "$STATE" "$snapshot/" 2>/dev/null || true
  cp -p "$STATE" "$bdir/homestack.conf" 2>/dev/null || true

  files=(etc/config etc/init.d etc/sysctl.d etc/modules.d)
  [[ ! -d /etc/dropbear ]] || files+=(etc/dropbear)
  [[ ! -d /etc/samba ]] || files+=(etc/samba)
  [[ ! -d /etc/banip ]] || files+=(etc/banip)
  [[ ! -d /etc/lighttpd ]] || files+=(etc/lighttpd)
  [[ ! -d /etc/nginx ]] || files+=(etc/nginx)
  tar -czf "$snapshot/router-configs.tar.gz" -C / "${files[@]}"
  tar_base_clean "$tmp_dest" "$BASE"
  tar -tzf "$tmp_dest" >/dev/null
  chmod 600 "$tmp_dest" "$bdir/homestack.conf" 2>/dev/null || true
  mv "$tmp_dest" "$dest"

  resume
  trap - EXIT
  msg "Бэкап успешно создан и проверен: $dest"
)

# ==============================================================================
# 18. ПОЛНОЕ ФАЗОВОЕ ТРАНЗАКЦИОННОЕ ВОССТАНОВЛЕНИЕ ИЗ БЭКАПА С HDD
# ==============================================================================
pinned_image() {
  local cname=$1 fallback=$2 manifest=$3
  if [[ -f $manifest ]]; then
    local digest
    digest=$(awk -F'\t' -v c="$cname" '$1 == c && $3 ~ /@sha256:[0-9a-f]{64}$/ {print $3; exit}' "$manifest")
    if [[ -n $digest ]]; then
      printf '%s\n' "$digest"
      return 0
    fi
  fi
  printf '%s\n' "$fallback"
}

restore() (
  set -Eeuo pipefail
  overlay_ready
  validate_all_paths
  need tar
  bdir=$(backup_dir)
  [[ -d $bdir ]] || { msg "Каталог бэкапов $bdir не найден."; exit 1; }

  archives=()
  i=1
  for f in "$bdir"/stack-*.tar.gz "$bdir"/pre-restore-*.tar.gz; do
    [[ -f $f ]] || continue
    archives+=("$f")
    printf '%d) %s (%s)\n' "$i" "$(basename "$f")" "$(du -h "$f" | awk '{print $1}')"
    i=$((i + 1))
  done
  ((${#archives[@]} > 0)) || { msg "В $bdir нет файлов резервных копий."; exit 1; }

  read -r -p "Выберите номер архива [1-${#archives[@]}]: " pick
  [[ $pick =~ ^[0-9]+$ && $pick -ge 1 && $pick -le ${#archives[@]} ]] || exit 1
  chosen="${archives[$((pick - 1))]}"

  msg 'Проверка целостности архива...'
  tar -tzf "$chosen" >/dev/null || { msg 'Архив повреждён! Восстановление отменено.'; exit 1; }

  orig_base="$BASE"
  mkdir -p "$orig_base"

  stamp=$(date +%Y%m%d-%H%M%S)
  tx_id="restore-${stamp}-$$"
  stage=$(mktemp -d "$orig_base/.restore-stage-XXXXXX")
  phase='prepare'
  rollback_dir=""
  moved_items=()
  old_renamed_pairs=()
  old_running_names=()
  etc_bak_tar=""
  etc_backup_ready=false
  state_bak=""
  tx_done=false

  tx_rollback() {
    local rc=$?
    trap - ERR EXIT
    set +e
    RUN_EXTRA_ARGS=()
    rm -rf "$stage" 2>/dev/null || true
    if [[ $tx_done == true ]]; then
      return 0
    fi

    msg "Сбой на этапе '$phase' (код $rc) — выполняем откат..."
    local rb_errors=()
    local files_ok=true containers_stopped=true net_ok=true

    if command -v docker >/dev/null 2>&1; then
      local tx_cids still_tx
      if ! tx_cids=$(docker ps -aq --filter "label=homestack.transaction=$tx_id" 2>/dev/null); then
        containers_stopped=false
        rb_errors+=("не удалось получить состояние Docker для tx=$tx_id")
      elif [[ -n $tx_cids ]]; then
        docker rm -f $tx_cids >/dev/null 2>&1 || true
        if ! still_tx=$(docker ps -aq --filter "label=homestack.transaction=$tx_id" 2>/dev/null); then
          containers_stopped=false
          rb_errors+=("не удалось подтвердить удаление контейнеров tx=$tx_id")
        elif [[ -n $still_tx ]]; then
          containers_stopped=false
          rb_errors+=("новые контейнеры не удалены: $still_tx")
        fi
      fi
    fi

    if [[ $containers_stopped == true ]]; then
      if [[ $phase == moving_old && -n $rollback_dir && -d $rollback_dir ]]; then
        for mname in "${moved_items[@]}"; do
          if [[ -e "$rollback_dir/$mname" || -L "$rollback_dir/$mname" ]]; then
            mv "$rollback_dir/$mname" "$target_base/" || { files_ok=false; rb_errors+=("mv $mname"); }
          fi
        done
        if [[ $files_ok == true ]]; then
          rmdir "$rollback_dir" 2>/dev/null || true
        fi
      elif [[ ($phase == installing_new || $phase == starting_new) && -n $rollback_dir && -d $rollback_dir ]]; then
        shopt -s dotglob nullglob
        for item in "$target_base"/*; do
          bname=$(basename "$item")
          [[ $bname == backups || $bname == music || $bname == .rollback-* || $bname == .restore-stage-* ]] && continue
          rm -rf "$item" || { files_ok=false; rb_errors+=("rm $bname"); }
        done
        for item in "$rollback_dir"/*; do
          mv "$item" "$target_base/" || { files_ok=false; rb_errors+=("mv $(basename "$item")"); }
        done
        if [[ $files_ok == true ]]; then
          rmdir "$rollback_dir" 2>/dev/null || true
        fi
      fi
    else
      files_ok=false
    fi

    if [[ -n $state_bak && -f $state_bak ]]; then
      cp -p "$state_bak" "$STATE" || rb_errors+=("restore $STATE")
    fi
    if [[ $etc_backup_ready == true && -n $etc_bak_tar && -f $etc_bak_tar ]]; then
      if tar -xzf "$etc_bak_tar" -C /; then
        /etc/init.d/network reload >/dev/null 2>&1 || { net_ok=false; rb_errors+=("network reload"); }
        /etc/init.d/firewall reload >/dev/null 2>&1 || { net_ok=false; rb_errors+=("firewall reload"); }
        sysctl -p /etc/sysctl.d/99-homestack-tuning.conf >/dev/null 2>&1 || true
      else
        net_ok=false
        rb_errors+=("restore /etc")
      fi
    fi

    if [[ $files_ok == true ]] && ((${#old_renamed_pairs[@]} > 0)) && command -v docker >/dev/null 2>&1; then
      for pair in "${old_renamed_pairs[@]}"; do
        orig_n=${pair%%:*}
        bak_n=${pair#*:}
        docker rename "$bak_n" "$orig_n" >/dev/null 2>&1 || rb_errors+=("rename $bak_n -> $orig_n")
      done
    fi
    if [[ $files_ok == true ]] && ((${#old_running_names[@]} > 0)) && command -v docker >/dev/null 2>&1; then
      for rn in "${old_running_names[@]}"; do
        docker start "$rn" >/dev/null 2>&1 || rb_errors+=("start $rn")
      done
    fi

    if ((${#rb_errors[@]} > 0)); then
      msg "ВНИМАНИЕ: Откат выполнен частично. Ошибки: ${rb_errors[*]}. Каталог $rollback_dir сохранён."
    else
      msg "Откат завершён: данные=${files_ok}, сеть=${net_ok}, прежние контейнеры возвращены (добавленные в /etc файлы проверьте отдельно)."
    fi
    exit "$rc"
  }
  trap tx_rollback EXIT

  tar -xzf "$chosen" -C "$stage"

  if [[ -f $stage/manifest.txt ]]; then
    grep -qx 'format=homestack-backup' "$stage/manifest.txt" || {
      msg 'Ошибка: выбранный архив не является полным бэкапом HomeStack.'; exit 1;
    }
    grep -qx 'format_version=1' "$stage/manifest.txt" || {
      msg 'Ошибка: неподдерживаемая версия формата бэкапа.'; exit 1;
    }
  elif [[ -f $stage/system-snapshot/homestack.conf ]]; then
    msg 'Примечание: архив создан старой версией скрипта (без manifest.txt).'
  else
    msg 'Ошибка: в архиве отсутствует манифест HomeStack.'; exit 1
  fi

  target_base="$orig_base"
  if [[ -f $stage/system-snapshot/homestack.conf ]]; then
    (
      load_conf_safe "$stage/system-snapshot/homestack.conf"
      validate_all_paths
    )
    target_base=$(
      load_conf_safe "$stage/system-snapshot/homestack.conf"
      normalize_path "$BASE"
    )
  fi
  safe_path "$target_base" || { msg "Небезопасный BASE в архиве: '$target_base'"; exit 1; }
  target_base=$(normalize_path "$target_base")
  mkdir -p "$target_base"

  need_kb=$(du -sk "$stage" | awk '{print $1}')
  avail_target_kb=$(df -Pk "$target_base" | awk 'END{print $4}')
  (( avail_target_kb > need_kb + 51200 )) || { msg "Недостаточно места в $target_base (нужно ~$((need_kb/1024)) МБ)."; exit 1; }

  cur_kb=$(du -sk "$target_base" | awk '{print $1}')
  avail_bdir_kb=$(df -Pk "$bdir" | awk 'END{print $4}')
  (( avail_bdir_kb > cur_kb + 51200 )) || { msg "Недостаточно места в $bdir для страховочной копии."; exit 1; }

  confirm "Остановить контейнеры, создать страховочную копию и восстановить доверенный архив $(basename "$chosen") в $target_base?" || exit 0

  if command -v docker >/dev/null 2>&1; then
    docker info >/dev/null || { msg 'Docker демон не отвечает — восстановление отменено.'; exit 1; }
    if ! cur_running=$(docker ps --filter label=homestack.managed=1 --format '{{.Names}}'); then
      msg 'Не удалось получить список запущенных контейнеров.'
      exit 1
    fi
    while IFS= read -r rn; do
      [[ -z $rn ]] || old_running_names+=("$rn")
    done <<< "$cur_running"

    if ! cur_all=$(docker ps -a --filter label=homestack.managed=1 --format '{{.Names}}'); then
      msg 'Не удалось получить список управляемых контейнеров.'
      exit 1
    fi
    while IFS= read -r an; do
      [[ -z $an ]] || {
        docker stop -t 20 "$an" >/dev/null
        [[ $(docker inspect -f '{{.State.Running}}' "$an" 2>/dev/null || echo true) == false ]] || {
          msg "Не удалось остановить контейнер $an."; exit 1;
        }
        bak_cn="hs-old-${stamp}-${an}"
        docker rename "$an" "$bak_cn" >/dev/null
        old_renamed_pairs+=("${an}:${bak_cn}")
      }
    done <<< "$cur_all"
  fi

  if [[ -d $target_base && -n $(ls -A "$target_base" 2>/dev/null) ]]; then
    mkdir -p "$bdir"
    pre_bak="$bdir/pre-restore-$stamp.tar.gz"
    tmp_pre="$pre_bak.tmp"
    tar_base_clean "$tmp_pre" "$target_base"
    tar -tzf "$tmp_pre" >/dev/null
    chmod 600 "$tmp_pre"
    mv "$tmp_pre" "$pre_bak"
    msg "Согласованная страховочная копия сохранена: $pre_bak"
  fi

  phase='moving_old'
  rollback_dir="$target_base/.rollback-$stamp"
  mkdir -p "$rollback_dir"
  shopt -s dotglob nullglob
  for item in "$target_base"/*; do
    bname=$(basename "$item")
    [[ $bname == backups || $bname == music || $bname == .restore-stage-* || $bname == .rollback-* ]] && continue
    mv "$item" "$rollback_dir/"
    moved_items+=("$bname")
  done

  phase='installing_new'
  for item in "$stage"/*; do
    mv "$item" "$target_base/"
  done
  rm -rf "$stage"

  mkdir -p "$target_base/backups/sys-snapshots"
  if [[ -f $target_base/system-snapshot/homestack.conf ]]; then
    state_bak="$target_base/backups/sys-snapshots/pre-restore-state-$stamp.conf"
    [[ ! -f $STATE ]] || cp -p "$STATE" "$state_bak"
    cp -p "$target_base/system-snapshot/homestack.conf" "$STATE"
    chmod 600 "$STATE"
    load_conf_safe "$STATE"
    validate_all_paths
    msg 'Файл параметров /etc/homestack.conf восстановлен.'
  fi

  if [[ -f $target_base/system-snapshot/router-configs.tar.gz ]] && confirm 'Также восстановить конфиги роутера (/etc/config, /etc/dropbear, /etc/sysctl.d, /etc/banip)?'; then
    etc_bak_tar="$target_base/backups/sys-snapshots/pre-restore-etc-$stamp.tar.gz"
    tmp_etc="$etc_bak_tar.tmp"
    cur_etc=(etc/config etc/init.d etc/sysctl.d etc/modules.d)
    [[ ! -d /etc/dropbear ]] || cur_etc+=(etc/dropbear)
    [[ ! -d /etc/samba ]] || cur_etc+=(etc/samba)
    [[ ! -d /etc/banip ]] || cur_etc+=(etc/banip)
    [[ ! -d /etc/lighttpd ]] || cur_etc+=(etc/lighttpd)
    [[ ! -d /etc/nginx ]] || cur_etc+=(etc/nginx)
    tar -czf "$tmp_etc" -C / "${cur_etc[@]}"
    tar -tzf "$tmp_etc" >/dev/null
    mv "$tmp_etc" "$etc_bak_tar"
    etc_backup_ready=true

    lockdir="/tmp/hs-restore-lock-$stamp"
    wd_start=$(date +%s)
    nohup sh -c "sleep 90; if mkdir '$lockdir' 2>/dev/null; then uci -q revert network || true; uci -q revert firewall || true; tar -xzf '$etc_bak_tar' -C /; /etc/init.d/network reload; /etc/init.d/firewall reload; fi" >/dev/null 2>&1 < /dev/null &

    tar -xzf "$target_base/system-snapshot/router-configs.tar.gz" -C /
    /etc/init.d/network reload 2>/dev/null || true
    /etc/init.d/firewall reload 2>/dev/null || true
    sysctl -p /etc/sysctl.d/99-homestack-tuning.conf >/dev/null 2>&1 || true

    rem=$(( 90 - ($(date +%s) - wd_start) ))
    (( rem > 10 )) || exit 1
    wait_sec=$(( rem - 5 ))
    ans=''
    if read -r -t "$wait_sec" -p 'Введите KEEP для подтверждения восстановленной сети: ' ans && [[ $ans == KEEP ]] && mkdir "$lockdir" 2>/dev/null; then
      msg 'Конфиги роутера восстановлены и подтверждены.'
    else
      exit 1
    fi
  fi

  phase='starting_new'
  if command -v docker >/dev/null 2>&1; then
    if confirm 'Скачать образы (по сохранённым RepoDigests) и запустить восстановленные контейнеры?'; then
      ready
      RUN_EXTRA_ARGS=(--label "homestack.transaction=$tx_id")
      manifest="$target_base/image-manifest.txt"
      if [[ -d $target_base/teamspeak ]]; then
        img=$(pinned_image ts6-server "$TS_IMAGE" "$manifest")
        docker pull "$img"
        recreate_single_container ts6-server "$img"
        wait_container_healthy ts6-server 60
      fi
      if [[ -d $target_base/mumble && -f $target_base/mumble.env ]]; then
        img=$(pinned_image mumble-server "$MM_IMAGE" "$manifest")
        docker pull "$img"
        recreate_single_container mumble-server "$img"
        wait_container_healthy mumble-server 60
      fi
      if [[ -s $target_base/rustdesk/id_ed25519.pub ]]; then
        img=$(pinned_image hbbs "$RD_IMAGE" "$manifest")
        docker pull "$img"
        recreate_single_container hbbs "$img"
        wait_container_healthy hbbs 60
        recreate_single_container hbbr "$img"
        wait_container_healthy hbbr 60
      fi
      if [[ -f $target_base/bot/data/ts3audiobot.toml ]]; then
        img=$(pinned_image "$BOT" "$BOT_IMAGE" "$manifest")
        docker pull "$img"
        recreate_single_container "$BOT" "$img"
        wait_container_healthy "$BOT" 90
      fi
      if [[ -d $target_base/torrserver ]]; then
        img=$(pinned_image torrserver "$TOR_IMAGE" "$manifest")
        docker pull "$img"
        recreate_single_container torrserver "$img"
        wait_container_healthy torrserver 60
      fi
      if [[ -d $target_base/beszel ]]; then
        img=$(pinned_image beszel "$BES_IMAGE" "$manifest")
        docker pull "$img"
        recreate_single_container beszel "$img"
        wait_container_healthy beszel 60
      fi
      if [[ -f $target_base/https/Caddyfile ]]; then
        img=$(pinned_image hs-caddy "$CADDY_IMAGE" "$manifest")
        docker pull "$img"
        recreate_single_container hs-caddy "$img"
        wait_container_healthy hs-caddy 60
      fi
      RUN_EXTRA_ARGS=()
      write_manifest
      msg 'Все восстановленные контейнеры запущены и прошли первичную проверку.'
    else
      confirm 'Оставить восстановленные файлы БЕЗ запуска контейнеров?' || exit 1
    fi
  fi

  tx_done=true
  trap - EXIT
  if ((${#old_renamed_pairs[@]} > 0)) || [[ -d $rollback_dir ]]; then
    if confirm 'Проверьте работу клиентов. Удалить старые резервные контейнеры (hs-old-*) и каталог отката?'; then
      if ((${#old_renamed_pairs[@]} > 0)) && command -v docker >/dev/null 2>&1; then
        for pair in "${old_renamed_pairs[@]}"; do
          docker rm -f "${pair#*:}" >/dev/null 2>&1 || true
        done
      fi
      rm -rf "$rollback_dir" 2>/dev/null || true
      msg 'Резервные копии этой транзакции очищены.'
    else
      msg "Старые контейнеры (остановлены) и $rollback_dir сохранены на диске для ручной проверки."
    fi
  fi
)

# ==============================================================================
# 19. АВТОЗАПУСК МЕНЮ ПРИ ПОДКЛЮЧЕНИИ ПО SSH
# ==============================================================================
ssh_autostart() {
  local hook=/etc/profile.d/99-homestack-autostart.sh
  if [[ -f $hook ]]; then
    msg 'Автозапуск меню при входе по SSH сейчас ВКЛЮЧЁН.'
    if confirm 'Отключить автозапуск при входе по SSH?'; then
      rm -f "$hook"
      msg 'Автозапуск отключён.'
    fi
  else
    [[ $SELF != /tmp/* && $SELF != /var/run/* ]] || {
      msg "Ошибка: скрипт запущен из временного каталога ($SELF). Перенесите его в /root/homestack.sh."
      return 1
    }
    msg 'Автозапуск меню при входе по SSH сейчас ВЫКЛЮЧЕН.'
    if confirm "Включить автооткрытие HomeStack при входе по SSH (запуск шелла без меню: ssh -t root@$LAN 'HOMESTACK_ACTIVE=1 /bin/ash -l')?"; then
      mkdir -p /etc/profile.d
      cat > "$hook" <<EOF
# Автозапуск OpenWrt HomeStack только для интерактивного SSH-сеанса root
if [ -z "\${HOMESTACK_ACTIVE:-}" ] && [ -t 0 ] && [ -t 1 ] && [ -n "\${SSH_TTY:-}" ] && [ "\$(id -u)" = "0" ] && [ -x "$SELF" ]; then
  export HOMESTACK_ACTIVE=1
  bash "$SELF"
fi
EOF
      chmod 644 "$hook"
      msg 'Автозапуск включён! При следующем входе по SSH откроется меню (выход в шелл — пункт 0).'
    fi
  fi
}

# ==============================================================================
# 20. ПРИНЯТИЕ СУЩЕСТВУЮЩИХ КОНТЕЙНЕРОВ В HOMESTACK (МИГРАЦИЯ В /opt/homestack)
# ==============================================================================
mount_src_for_dest() {
  local cname=$1 dest=$2
  docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$dest\"}}{{.Source}}{{end}}{{end}}" "$cname" 2>/dev/null || true
}

adopt_containers() {
  ready
  msg '=== Принятие существующих контейнеров под управление HomeStack ==='
  msg "Данные сервисов будут скопированы в $BASE, а старые контейнеры остановлены и переименованы в legacy-*."
  confirm 'Начать перенос и пересоздание неуправляемых контейнеров?' || return 0

  local src
  # 1. TeamSpeak 6
  if exists ts6-server && ! managed ts6-server; then
    src=$(mount_src_for_dest ts6-server '/var/tsserver')
    if [[ -n $src && -d $src ]]; then
      msg "Перенос ts6-server ($src -> $BASE/teamspeak)..."
      docker stop -t 20 ts6-server
      mkdir -p "$BASE/teamspeak"
      cp -a "$src/." "$BASE/teamspeak/"
      docker rename ts6-server legacy-ts6-server
      recreate_single_container ts6-server "$TS_IMAGE"
      wait_container_healthy ts6-server 60
    fi
  fi

  # 2. Mumble
  if exists mumble-server && ! managed mumble-server; then
    src=$(mount_src_for_dest mumble-server '/data')
    if [[ -n $src && -d $src ]]; then
      msg "Перенос mumble-server ($src -> $BASE/mumble)..."
      docker inspect mumble-server --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E '^MUMBLE_' > "$BASE/mumble.env" || true
      chmod 600 "$BASE/mumble.env"
      docker stop -t 20 mumble-server
      mkdir -p "$BASE/mumble"
      cp -a "$src/." "$BASE/mumble/"
      docker rename mumble-server legacy-mumble-server
      recreate_single_container mumble-server "$MM_IMAGE"
      wait_container_healthy mumble-server 60
    fi
  fi

  # 3. RustDesk (hbbs + hbbr)
  if (exists hbbs && ! managed hbbs) || (exists hbbr && ! managed hbbr); then
    src=''
    ! exists hbbs || src=$(mount_src_for_dest hbbs '/root')
    [[ -n $src ]] || ! exists hbbr || src=$(mount_src_for_dest hbbr '/root')
    if [[ -n $src && -d $src ]]; then
      msg "Перенос RustDesk ($src -> $BASE/rustdesk)..."
      ! exists hbbs || docker stop -t 20 hbbs
      ! exists hbbr || docker stop -t 20 hbbr
      mkdir -p "$BASE/rustdesk"
      cp -a "$src/." "$BASE/rustdesk/"
      ! exists hbbs || docker rename hbbs legacy-hbbs
      ! exists hbbr || docker rename hbbr legacy-hbbr
      recreate_single_container hbbs "$RD_IMAGE"
      wait_container_healthy hbbs 60
      recreate_single_container hbbr "$RD_IMAGE"
      wait_container_healthy hbbr 60
    fi
  fi

  # 4. Beszel Hub
  if exists beszel && ! managed beszel; then
    src=$(mount_src_for_dest beszel '/beszel_data')
    if [[ -n $src && -d $src ]]; then
      msg "Перенос beszel ($src -> $BASE/beszel)..."
      docker stop -t 20 beszel
      mkdir -p "$BASE/beszel"
      cp -a "$src/." "$BASE/beszel/"
      docker rename beszel legacy-beszel
      recreate_single_container beszel "$BES_IMAGE"
      wait_container_healthy beszel 60
    fi
  fi

  # 5. TorrServer
  if exists torrserver && ! managed torrserver; then
    src=$(mount_src_for_dest torrserver '/opt/ts/config')
    [[ -n $src ]] || src=$(mount_src_for_dest torrserver '/config')
    if [[ -n $src && -d $src ]]; then
      msg "Перенос torrserver ($src -> $BASE/torrserver/config)..."
      docker stop -t 20 torrserver
      mkdir -p "$BASE/torrserver/config" "$BASE/torrserver/torrents"
      cp -a "$src/." "$BASE/torrserver/config/"
      docker rename torrserver legacy-torrserver
      if [[ -s "$BASE/torrserver/config/accs.db" ]]; then
        TOR_MODE=public
      else
        TOR_MODE=vpn
      fi
      docker pull "$TOR_IMAGE"
      recreate_single_container torrserver "$TOR_IMAGE"
      wait_container_healthy torrserver 60
    fi
  fi

  # 6. TS3AudioBot
  if exists "$BOT" && ! managed "$BOT"; then
    src=$(mount_src_for_dest "$BOT" '/data')
    local msrc
    msrc=$(mount_src_for_dest "$BOT" '/music')
    if [[ -n $src && -d $src ]]; then
      msg "Перенос $BOT ($src -> $BASE/bot/data)..."
      docker stop -t 20 "$BOT"
      mkdir -p "$BASE/bot/data" "$BASE/music"
      cp -a "$src/." "$BASE/bot/data/"
      [[ -z $msrc || ! -d $msrc ]] || cp -a "$msrc/." "$BASE/music/"
      docker rename "$BOT" "legacy-$BOT"
      recreate_single_container "$BOT" "$BOT_IMAGE"
      wait_container_healthy "$BOT" 90
    fi
  fi

  # Автофиксация HDD_UUID и актуального DOCKER_ROOT
  if [[ -n $HDD_MOUNT && -z $HDD_UUID ]] && command -v blkid >/dev/null 2>&1; then
    local mdev muuid
    mdev=$(awk -v m="$HDD_MOUNT" '$2 == m && $1 ~ /^\/dev\// {print $1; exit}' /proc/mounts)
    if [[ -n $mdev && -b $mdev ]]; then
      muuid=$(blkid -s UUID -o value "$mdev" 2>/dev/null || true)
      [[ -z $muuid ]] || HDD_UUID="$muuid"
    fi
  fi
  save
  write_manifest
  msg 'Перенос завершён! Проверьте работу сервисов; старые контейнеры сохранены с префиксом legacy-*.'
}

full_base() {
  base_system
  net_setup
  tuning
  samba_setup
  banip_setup
  msg '=== Базовая настройка роутера полностью завершена! ==='
}

# Автодетект сохранённого конфига на смонтированном HDD при первом запуске
if [[ ! -f $STATE ]]; then
  if [[ -f /mnt/sda1/homestack-backups/homestack.conf ]]; then
    msg 'Обнаружен сохранённый профиль /mnt/sda1/homestack-backups/homestack.conf!'
    if confirm 'Загрузить сохранённый профиль? (Нажмите нет, если настраиваете роутер друга)'; then
      cp -p /mnt/sda1/homestack-backups/homestack.conf "$STATE"
      chmod 600 "$STATE"
      load_conf_safe "$STATE"
    else
      save
    fi
  else
    save
  fi
fi

validate_all_paths || msg 'ВНИМАНИЕ: проверьте корректность путей в пункте 4!'

if [[ ${1:-} == --action ]]; then
  case ${2:-} in
    disk_overlay|full_base|port_forwards|config|base_system|net_setup|tuning|samba_setup|banip_setup|install_ts|install_mumble|install_rustdesk|install_bot|install_torr|install_beszel|update_containers|site|caddy_apply|wan_menu|wireguard|lighttpd_migrate|status|backup|restore|ssh_autostart|adopt_containers)
      "${2}" ;;
    *) exit 2 ;;
  esac
  exit
fi

export HOMESTACK_ACTIVE=1
while true; do
  ssh_flag='ВЫКЛ'
  [[ ! -f /etc/profile.d/99-homestack-autostart.sh ]] || ssh_flag='ВКЛ'
  cat <<EOF

====================================================================
OpenWrt HomeStack 3.8 (NanoPi R76S / sbwml / apk)
Пояс: $TZ_ZONE | LAN: $LAN | WAN: $WAN_PROTO (${WAN_MAC:-hw-mac})
SD Docker: $DOCKER_ROOT | HDD Samba/Backup: ${HDD_MOUNT:-нет}
====================================================================
--- ПОДГОТОВКА И БАЗОВАЯ НАСТРОЙКА ПОСЛЕ ПРОШИВКИ ---
 1) Авторазметка SD-карты (/overlay f2fs) и запись HDD в fstab (ДО ребута)
 2) Полная базовая настройка (USB-драйверы + btop + Темы/RU + Сеть + Тюнинг + Samba + banIP)
 3) Пробросы портов DNAT на ПК (${PC_IP:-не задан})
 4) Мастер параметров (профиль друга / выбор пояса цифрами, провайдера, MAC, IP)
 5) Проверка состояния системы, дисков и тюнинга

--- КОНТЕЙНЕРЫ (НА SD-КАРТЕ) И ОБСЛУЖИВАНИЕ ---
 6) Новый TeamSpeak 6
 7) Новый MusicBot + веб-панель
 8) Новый Mumble
 9) Новый RustDesk (hbbs/hbbr)
10) Новый TorrServer (HTTPS+auth / LAN+VPN)
11) Новый Beszel Hub
12) Обновить установленные Docker-контейнеры (TorrServer, TS6 и др.)
13) Добавить HTTPS-сайт в Caddy (TorrServer / MusicBot / Beszel / LuCI)
14) Открыть / закрыть публичные порты в WAN
15) WireGuard VPN для администрирования
16) Безопасная замена Nginx на lighttpd (освобождает 443 + Quick File Manager)
17) Резервная копия на HDD (/mnt/sda1/homestack-backups)
18) Транзакционное восстановление из резервной копии с HDD
19) Автозапуск меню при входе по SSH [сейчас: $ssh_flag]
20) Принять существующие контейнеры в HomeStack (миграция данных в $BASE)
 0) Выход (в обычный терминал OpenWrt)
EOF
  read -r -p '> ' n || break
  case $n in
    1) a=disk_overlay;; 2) a=full_base;; 3) a=port_forwards;; 4) a=config;; 5) a=status;;
    6) a=install_ts;; 7) a=install_bot;; 8) a=install_mumble;; 9) a=install_rustdesk;;
    10) a=install_torr;; 11) a=install_beszel;; 12) a=update_containers;; 13) a=site;;
    14) a=wan_menu;; 15) a=wireguard;; 16) a=lighttpd_migrate;; 17) a=backup;;
    18) a=restore;; 19) a=ssh_autostart;; 20) a=adopt_containers;;
    0) break;; *) continue;;
  esac
  bash "$SELF" --action "$a" || msg 'Операция прервана. Проверьте вывод выше.'
  [[ ! -f $STATE ]] || load_conf_safe "$STATE"
done
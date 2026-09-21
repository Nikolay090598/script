#!/bin/sh
set -e

# Определение характеристик оборудования
TOTAL_RAM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
OVERLAY_FREE_MB=$(df -m /overlay | awk 'NR==2 {print $4}')

echo "=================================================="
echo " Обнаружено ОЗУ: ${TOTAL_RAM_MB} МБ"
echo " Свободно в /overlay: ${OVERLAY_FREE_MB} МБ"
echo "=================================================="

# Проверка пакетного менеджера (OpenWrt 25+)
if ! command -v apk >/dev/null 2>&1; then
    echo "Ошибка: пакетный менеджер apk не найден. Скрипт предназначен для OpenWrt 25+."
    exit 1
fi

# Предупреждение о малом объеме накопителя
if [ "$OVERLAY_FREE_MB" -lt 2048 ]; then
    echo "[ВНИМАНИЕ] В /overlay доступно менее 2 ГБ. Рекомендуется расширить раздел накопителя."
fi

# Обработка аргументов командной строки (--zram / --no-zram)
INSTALL_ZRAM=""
for arg in "$@"; do
    case "$arg" in
        --zram)    INSTALL_ZRAM="y" ;;
        --no-zram) INSTALL_ZRAM="n" ;;
    esac
done

# Интерактивный запрос, если аргумент не был передан
if [ -z "$INSTALL_ZRAM" ]; then
    if [ "$TOTAL_RAM_MB" -le 1500 ]; then
        printf "\n[?] Объем ОЗУ <= 1.5 ГБ. Рекомендуется включить zRAM.\nУстановить zram-swap? [Y/n]: "
        read -r answer
        case "$answer" in
            [nN][oO]|[nN]) INSTALL_ZRAM="n" ;;
            *)             INSTALL_ZRAM="y" ;;
        esac
    else
        printf "\n[?] Объем ОЗУ > 1.5 ГБ (памяти достаточно).\nУстановить zram-swap для подстраховки? [y/N]: "
        read -r answer
        case "$answer" in
            [yY][eE][sS]|[yY]) INSTALL_ZRAM="y" ;;
            *)                 INSTALL_ZRAM="n" ;;
        esac
    fi
fi

echo ""
echo "=== [1/5] Обновление пакетов и установка Docker ==="
apk update

if [ "$INSTALL_ZRAM" = "y" ]; then
    echo "-> Установка и запуск zram-swap..."
    apk add zram-swap
    /etc/init.d/zram enable
    /etc/init.d/zram start
else
    echo "-> Пропуск установки zram-swap."
fi

apk add dockerd docker docker-compose luci-app-dockerman

echo "=== [2/5] Подготовка постоянного хранилища ==="
rm -f /etc/docker/daemon.json
mkdir -p /overlay/docker

echo "=== [3/5] Конфигурация Docker через UCI ==="
uci set dockerd.globals.data_root='/overlay/docker'
uci set dockerd.globals.iptables='0'

# Надежные DNS (Яндекс)
uci delete dockerd.globals.dns 2>/dev/null || true
uci add_list dockerd.globals.dns='77.88.8.8'
uci add_list dockerd.globals.dns='77.88.8.1'
uci commit dockerd

echo "=== [4/5] Настройка Firewall4 (изоляция от Tachyon/VLESS) ==="
uci del_list firewall.@zone[0].device='docker0' 2>/dev/null || true
uci del_list firewall.@zone[0].device='br-+' 2>/dev/null || true

uci set firewall.docker=zone
uci set firewall.docker.name='docker'
uci set firewall.docker.input='ACCEPT'
uci set firewall.docker.output='ACCEPT'
uci set firewall.docker.forward='ACCEPT'

uci delete firewall.docker.device 2>/dev/null || true
uci add_list firewall.docker.device='docker0'
uci add_list firewall.docker.device='br-+'

uci set firewall.docker_wan=forwarding
uci set firewall.docker_wan.src='docker'
uci set firewall.docker_wan.dest='wan'

uci set firewall.lan_docker=forwarding
uci set firewall.lan_docker.src='lan'
uci set firewall.lan_docker.dest='docker'

uci commit firewall

# Очистка паразитных таблиц iptables-nft
nft delete table ip filter 2>/dev/null || true
nft delete table ip nat 2>/dev/null || true

# Перезапуск сервисов
/etc/init.d/firewall restart
/etc/init.d/dockerd enable
/etc/init.d/dockerd restart

echo "=== [5/5] Проверка сетевой связности ==="
sleep 2
echo -n "Проверка прямого выхода в сеть: "
if docker run --rm alpine ping -c 2 77.88.8.8 >/dev/null 2>&1; then
    echo "OK (IP доступен)"
else
    echo "ОШИБКА (пакеты теряются)"
fi

echo -n "Проверка DNS: "
if docker run --rm alpine ping -c 2 ya.ru >/dev/null 2>&1; then
    echo "OK (Домен ya.ru успешно разрешен)"
else
    echo "ОШИБКА (DNS не отвечает)"
fi

echo "=================================================="
echo " Установка завершена!"
echo "=================================================="
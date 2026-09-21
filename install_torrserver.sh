#!/bin/sh
set -e

# По умолчанию ставится проверенная версия MatriX.145 (либо передается аргументом)
VERSION=${1:-145}

ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
    BIN_ARCH="arm64"
elif [ "$ARCH" = "x86_64" ]; then
    BIN_ARCH="amd64"
else
    echo "Ошибка: архитектура $ARCH не поддерживается."
    exit 1
fi

echo "=================================================="
echo " Установка TorrServer MatriX.${VERSION} (${BIN_ARCH})"
echo " Режим: Чистый кэш в ОЗУ (без износа SD-карты)"
echo "=================================================="

# Проверка наличия curl на хосте
if ! command -v curl >/dev/null 2>&1; then
    echo "Установка curl..."
    apk add curl
fi

echo "=== [1/4] Остановка старого контейнера ==="
docker stop torrserver 2>/dev/null || true
docker rm torrserver 2>/dev/null || true

echo "=== [2/4] Подготовка постоянных каталогов в /overlay ==="
mkdir -p /overlay/torrserver/bin
mkdir -p /overlay/torrserver/config

echo "=== [3/4] Загрузка бинарника с GitHub Releases ==="
BIN_URL="https://github.com/YouROK/TorrServer/releases/download/MatriX.${VERSION}/TorrServer-linux-${BIN_ARCH}"
echo "Скачивание: $BIN_URL"
curl -fL -o /overlay/torrserver/bin/torrserver "$BIN_URL"
chmod +x /overlay/torrserver/bin/torrserver

echo "=== [4/4] Подготовка базового окружения и запуск ==="
# Собираем базовый образ один раз, если он еще не существует
if ! docker image inspect torrserver-env:latest >/dev/null 2>&1; then
    echo "Сборка окружения (Alpine + ffmpeg + gcompat)..."
    docker rm -f ts-temp-builder 2>/dev/null || true
    docker run --name ts-temp-builder --network host alpine:latest sh -c "
        apk update && \
        apk add --no-cache gcompat ca-certificates ffmpeg
    "
    docker commit ts-temp-builder torrserver-env:latest
    docker rm -f ts-temp-builder
fi

# Конфигурация docker-compose (дисковый кэш исключен, сохраняется только база данных)
cat << 'EOF' > /overlay/torrserver/docker-compose.yml
services:
  torrserver:
    image: torrserver-env:latest
    container_name: torrserver
    restart: unless-stopped
    network_mode: host
    volumes:
      - /overlay/torrserver/bin/torrserver:/usr/local/bin/torrserver:ro
      - /overlay/torrserver/config:/config
    environment:
      - TZ=Asia/Yekaterinburg
    command: ["/usr/local/bin/torrserver", "--path", "/config", "--port", "8090"]
EOF

cd /overlay/torrserver
docker-compose up -d

ROUTER_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo "<IP_роутера>")

echo "=================================================="
echo " TorrServer MatriX.${VERSION} успешно запущен!"
echo " Веб-интерфейс: http://${ROUTER_IP}:8090"
echo "=================================================="
echo " НАСТРОЙКИ В ВЕБ-ИНТЕРФЕЙСЕ (Settings -> Server Settings):"
echo " 1. Кэш (Cache): выберите 'Память (RAM)'."
echo " 2. Размер кэша (Cache size):"
echo "    - Для NanoPi R3S (1 ГБ ОЗУ): 64 МБ или 100 МБ"
echo "    - Для NanoPi R76S (4 ГБ ОЗУ): 256 МБ или 512 МБ"
echo " 3. Предзагрузка (Preload buffer): 25%"
echo " 4. Лимит соединений (Connections limit): 25-35"
echo "=================================================="
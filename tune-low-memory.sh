#!/usr/bin/env bash
set -euo pipefail

# Настройка хоста под мало памяти. Писался для сервера платформы: 961 МБ RAM,
# одно ядро, 20 ГБ диска. Идемпотентен — повторный запуск ничего не ломает.
#
# Что делает и почему:
#
#   1. zram — сжатая память вместо страниц на диске. На таком объёме даёт
#      эффективно +200-400 МБ и убирает дисковый ввод-вывод из-под свопа.
#      Диск здесь один и тот же для свопа и для данных, поэтому своп в файл
#      тормозит ровно то, ради чего он затевался.
#   2. multipathd — демон многопутевого доступа к SAN-дискам. На VPS с одним
#      /dev/sda он не делает ничего и стоит 27 МБ.
#   3. Регулярная уборка docker. За месяц работы кэш сборок вырос до 2.5 ГБ,
#      диск дошёл до 93%, и это опаснее нехватки памяти: своп тормозит, а
#      кончившийся диск останавливает всё сразу, включая прод.
#
# Usage: sudo ./tune-low-memory.sh

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Запускать от root: sudo $0" >&2
  exit 1
fi

echo "[1/4] zram"
if ! dpkg -s zram-tools >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y zram-tools
fi

# Размер = половина RAM. Больше брать не стоит: сжатые страницы всё равно
# занимают память, и слишком большой zram начинает вытеснять сам себя.
cat > /etc/default/zramswap <<'EOF'
# Алгоритм: zstd жмёт заметно лучше lzo при сопоставимой скорости.
ALGO=zstd
# Половина физической памяти под сжатый своп.
PERCENT=50
# Приоритет выше файлов подкачки (-2 и -3), чтобы ядро сначала шло в память,
# а на диск — только когда сжатый своп кончился.
PRIORITY=100
EOF

systemctl enable zramswap.service
systemctl restart zramswap.service

echo "[2/4] multipathd"
if systemctl is-enabled multipathd >/dev/null 2>&1; then
  systemctl disable --now multipathd.service multipathd.socket || true
else
  echo "  уже отключён"
fi

echo "[3/4] swappiness"
# 60 по умолчанию — ядро охотно вытесняет страницы. С zram вытеснение стало
# дешёвым, поэтому значение оставляем высоким осознанно: страницы уходят в
# сжатую память, а не на диск. Фиксируем явно, чтобы не зависеть от умолчания.
cat > /etc/sysctl.d/99-low-memory.conf <<'EOF'
vm.swappiness = 60
# Кэш инодов/дентри на маленькой машине стоит отдавать охотнее.
vm.vfs_cache_pressure = 200
EOF
sysctl --quiet -p /etc/sysctl.d/99-low-memory.conf

echo "[4/4] еженедельная уборка docker"
cat > /etc/cron.weekly/docker-gc <<'EOF'
#!/bin/sh
# Кэш сборок и образы, за которыми не стоит ни один контейнер. Без -a у
# image prune: образы сервисов пересобираются на одном ядре по несколько
# минут, и удалять их ради места — плохая сделка.
docker builder prune -f --filter 'until=168h' >/dev/null 2>&1
docker image prune -f >/dev/null 2>&1
docker container prune -f --filter 'until=168h' >/dev/null 2>&1
EOF
chmod +x /etc/cron.weekly/docker-gc

echo
echo "Готово. Проверить:"
echo "  swapon --show          # должен появиться /dev/zram0 с приоритетом 100"
echo "  free -m                # available должно вырасти"
echo "  systemctl is-active multipathd   # inactive"

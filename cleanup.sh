#!/usr/bin/env bash
# VPS disk cleanup. Scans first, then asks once before making changes.
set -Eeuo pipefail
umask 077

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  cat <<'EOF'
Usage: sudo bash cleanup.sh

Checks common cleanup targets, displays what it found, then asks once:
  [y/N] to proceed, any other key to cancel.

May clean APT packages/cache, old journald and rotated logs, unused Docker
images/build cache, old disabled Snap revisions, root pip/npm caches, and old
regular files in /tmp and /var/tmp. Docker containers and volumes are untouched.
EOF
  exit 0
fi
if (( $# > 0 )); then echo "Неизвестный параметр: $1" >&2; exit 2; fi
if [[ $EUID -ne 0 ]]; then echo "Запусти от root: sudo bash $0" >&2; exit 1; fi

have() { command -v "$1" >/dev/null 2>&1; }
step() { printf '\n==> %s\n' "$1"; }
avail_bytes() { df --output=avail -B1 / | tail -n1 | tr -d ' '; }
human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 B"; }

BEFORE=$(avail_bytes)
echo "Проверяю, что можно очистить. Свободно сейчас: $(human "$BEFORE")"
df -h / | tail -n1

step "APT: кеш и неиспользуемые пакеты"
if have apt-get; then
  echo "Кеш пакетов APT будет очищен. План autoremove:"
  apt-get -s autoremove --purge || true
else echo "APT не найден."; fi

step "journald: логи старше 7 дней и ограничение 200 МБ"
if have journalctl; then journalctl --disk-usage 2>/dev/null || true; else echo "journald не найден."; fi

step "Ротированные логи старше 30 дней"
if [[ -d /var/log ]]; then
  find /var/log -xdev -type f -mtime +30 \
    \( -name '*.gz' -o -name '*.xz' -o -name '*.old' -o -name '*.[0-9]' -o -name '*.[0-9].log' \) \
    -print 2>/dev/null || true
fi

step "Docker: неиспользуемые образы и build-кеш (без контейнеров и томов)"
DOCKER_READY=0
if have docker && docker info >/dev/null 2>&1; then DOCKER_READY=1; docker system df || true; else echo "Docker не установлен или недоступен."; fi

step "Snap: старые отключённые ревизии"
if have snap; then
  snap list --all 2>/dev/null | awk '/disabled/{print}' || true
else echo "Snap не установлен."; fi

step "Кеш pip/npm пользователя root"
if have pip3; then pip3 cache info 2>/dev/null || true
elif have pip; then pip cache info 2>/dev/null || true
fi
if have npm && [[ -d /root/.npm ]]; then du -sh /root/.npm 2>/dev/null || true; fi

step "Временные файлы (только файлы старше заданного срока)"
[[ ! -d /tmp ]] || find /tmp -xdev -type f -mtime +7 -print 2>/dev/null || true
[[ ! -d /var/tmp ]] || find /var/tmp -xdev -type f -mtime +30 -print 2>/dev/null || true

if [[ ! -r /dev/tty ]]; then
  echo "Не найден терминал для подтверждения. Ничего не удалено." >&2
  exit 1
fi
answer=''
printf '\nОчистить перечисленное? [y/N]: ' > /dev/tty
read -r -n 1 answer </dev/tty || true
printf '\n' > /dev/tty
case "$answer" in y|Y) ;; *) echo "Отменено, ничего не удалено."; exit 0 ;; esac

export DEBIAN_FRONTEND=noninteractive
step "APT"
if have apt-get; then
  apt-get clean
  apt-get autoremove --purge -y
  apt-get autoclean -y
fi

step "journald"
if have journalctl; then journalctl --vacuum-time=7d; journalctl --vacuum-size=200M; fi

step "Ротированные логи"
if [[ -d /var/log ]]; then
  find /var/log -xdev -type f -mtime +30 \
    \( -name '*.gz' -o -name '*.xz' -o -name '*.old' -o -name '*.[0-9]' -o -name '*.[0-9].log' \) \
    -print -delete 2>/dev/null || true
fi

step "Docker"
if (( DOCKER_READY )); then
  docker image prune -a -f
  docker builder prune -a -f
fi

step "Snap"
if have snap; then
  snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r name rev; do
    [[ -n "$name" && -n "$rev" ]] && snap remove "$name" --revision="$rev"
  done
fi

step "Кеши pip/npm пользователя root"
have pip3 && pip3 cache purge || true
have pip && pip cache purge || true
have npm && npm cache clean --force || true

step "Временные файлы"
[[ ! -d /tmp ]] || find /tmp -xdev -type f -mtime +7 -print -delete 2>/dev/null || true
[[ ! -d /var/tmp ]] || find /var/tmp -xdev -type f -mtime +30 -print -delete 2>/dev/null || true

AFTER=$(avail_bytes)
FREED=$(( AFTER - BEFORE )); (( FREED < 0 )) && FREED=0
step "Готово"
echo "Свободно после очистки: $(human "$AFTER")"
echo "Освобождено: $(human "$FREED")"
df -h / | tail -n1

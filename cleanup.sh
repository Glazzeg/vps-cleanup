#!/usr/bin/env bash
# Conservative disk cleanup for Ubuntu VPS. Defaults to a preview; see --help.
set -Eeuo pipefail
umask 077

APPLY=0
DO_AUTOREMOVE=0
DO_DOCKER=0
DO_CACHES=0
DO_TMP=0

usage() {
  cat <<'EOF'
Usage: sudo bash cleanup.sh [options]

Default: preview only. With --apply, run the conservative cleanup tasks:
  - APT package cache cleanup
  - journald vacuum (logs older than 7 days; cap at 200 MB)
  - old rotated log files (over 30 days)

Optional cleanup tasks require explicit opt-in:
  --autoremove  APT autoremove (review the displayed package list first)
  --docker      Remove unused Docker images and build cache (never volumes)
  --caches      Purge pip/npm caches for root only
  --tmp         Remove regular files in /tmp older than 7 days and /var/tmp
                older than 30 days (review preview; active files can be affected)
  --apply       Execute selected tasks; asks for confirmation
  -h, --help    Show this help

Examples:
  bash cleanup.sh                         # preview
  sudo bash cleanup.sh --apply            # conservative cleanup
  sudo bash cleanup.sh --autoremove       # preview APT autoremove candidates
  sudo bash cleanup.sh --apply --docker   # include Docker image/cache cleanup
EOF
}

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --autoremove) DO_AUTOREMOVE=1 ;;
    --docker) DO_DOCKER=1 ;;
    --caches) DO_CACHES=1 ;;
    --tmp) DO_TMP=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Неизвестный параметр: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }
step() { printf '\n==> %s\n' "$1"; }
avail_bytes() { df --output=avail -B1 / | tail -n1 | tr -d ' '; }
human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 B"; }
run() {
  if (( APPLY )); then "$@"; else printf '[просмотр]'; printf ' %q' "$@"; printf '\n'; fi
}

if (( APPLY )) && [[ $EUID -ne 0 ]]; then
  echo "Для --apply запусти от root: sudo bash $0 --apply" >&2
  exit 1
fi

if (( ! APPLY )); then
  echo "Режим просмотра: ничего не будет удалено. Для выполнения добавь --apply."
else
  read -r -p "Будут выполнены выбранные операции очистки. Продолжить? Введи YES: " confirm
  [[ "$confirm" == YES ]] || { echo "Отменено."; exit 0; }
fi

BEFORE=$(avail_bytes)
echo "Свободно до очистки: $(human "$BEFORE")"
df -h / | tail -n1

step "APT: кеш пакетов"
have apt-get && run apt-get clean || echo "apt-get не найден, пропускаю."

if (( DO_AUTOREMOVE )); then
  step "APT: список кандидатов autoremove"
  if have apt-get; then
    if (( APPLY )); then
      apt-get -s autoremove --purge
      read -r -p "Показанный список пакетов допустимо удалить? Введи YES: " answer
      [[ "$answer" == YES ]] || { echo "Autoremove пропущен."; }
      [[ "$answer" == YES ]] && apt-get autoremove --purge
    else
      apt-get -s autoremove --purge
    fi
  fi
fi

step "journald: старше 7 дней / свыше 200 МБ"
if have journalctl; then
  run journalctl --vacuum-time=7d
  run journalctl --vacuum-size=200M
else echo "journalctl не найден, пропускаю."; fi

step "Старые ротированные логи в /var/log (старше 30 дней)"
if (( APPLY )); then
  find /var/log -xdev -type f -mtime +30 \
    \( -name '*.gz' -o -name '*.xz' -o -name '*.old' -o -name '*.[0-9]' -o -name '*.[0-9].log' \) \
    -print -delete 2>/dev/null || true
else
  find /var/log -xdev -type f -mtime +30 \
    \( -name '*.gz' -o -name '*.xz' -o -name '*.old' -o -name '*.[0-9]' -o -name '*.[0-9].log' \) \
    -print 2>/dev/null || true
fi

if (( DO_DOCKER )); then
  step "Docker: неиспользуемые образы и build-кеш; тома не трогаются"
  if have docker && docker info >/dev/null 2>&1; then
    run docker image prune -a
    run docker builder prune
  else echo "Docker недоступен, пропускаю."; fi
fi

if (( DO_CACHES )); then
  step "Кеши pip/npm пользователя root"
  if have pip3; then run pip3 cache purge; fi
  if have pip; then run pip cache purge; fi
  if have npm; then run npm cache clean --force; fi
fi

if (( DO_TMP )); then
  step "Временные файлы: /tmp старше 7 дней, /var/tmp старше 30 дней"
  for spec in "/tmp 7" "/var/tmp 30"; do
    read -r dir days <<< "$spec"
    [[ -d "$dir" ]] || continue
    if (( APPLY )); then
      find "$dir" -xdev -type f -mtime "+$days" -print -delete 2>/dev/null || true
    else
      find "$dir" -xdev -type f -mtime "+$days" -print 2>/dev/null || true
    fi
  done
fi

if (( APPLY )); then
  AFTER=$(avail_bytes)
  FREED=$(( AFTER - BEFORE )); (( FREED < 0 )) && FREED=0
  step "Готово"
  echo "Свободно после очистки: $(human "$AFTER")"
  echo "Освобождено: $(human "$FREED")"
  df -h / | tail -n1
else
  echo "Предпросмотр завершён."
fi

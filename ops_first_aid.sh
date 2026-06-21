#!/usr/bin/env bash
#
# ops_first_aid.sh — інструмент первинної діагностики Linux-сервера
#
# Призначення: швидко зібрати інформацію про користувачів, систему,
# процеси, логи та файли, а також безпечно керувати окремими процесами.
#
# Підтримується ТІЛЬКИ Linux (ps, /proc та інші команди поводяться
# по-іншому на BSD/macOS).

set -uo pipefail
# Примітка: ми навмисно НЕ використовуємо `set -e`.
# Багато команд у цьому скрипті (grep -c, ps -p, id) можуть штатно
# повертати ненульовий код (наприклад, "нічого не знайдено"), і це
# не є помилкою скрипту. З `-e` скрипт міг би завершуватись достроково
# в цілком нормальних ситуаціях.

# -------------------- Глобальні налаштування --------------------

REPORT_DIR="/var/tmp/ops_reports"
SCRIPT_NAME="$(basename "$0")"

# -------------------- Допоміжні функції --------------------

# Перевірка, що скрипт виконується на Linux
check_linux() {
    if [ "$(uname -s)" != "Linux" ]; then
        echo "ПОМИЛКА: Цей скрипт підтримує тільки Linux." >&2
        echo "Виявлена система: $(uname -s)." >&2
        exit 1
    fi
}

# Перевірка наявності команди в системі
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Перевірка, що значення є цілим числом (можливо з мінусом, для nice)
is_integer() {
    [[ "$1" =~ ^-?[0-9]+$ ]]
}

show_help() {
    cat <<EOF
=== Довідка з використання $SCRIPT_NAME ===

Призначення:
  Скрипт первинної діагностики Linux-сервера: користувачі, системний
  звіт, процеси, пошук файлів, аналіз логів, безпечне керування PID.

Використання:
  ./$SCRIPT_NAME --users
  ./$SCRIPT_NAME --users --user <імя_користувача>
  ./$SCRIPT_NAME --report
  ./$SCRIPT_NAME --proc
  ./$SCRIPT_NAME --proc --pid <номер_pid>
  ./$SCRIPT_NAME --find <директорія> <патерн_пошуку>
  ./$SCRIPT_NAME --log <шлях_до_файлу>
  ./$SCRIPT_NAME --log <шлях_до_файлу> --follow
  ./$SCRIPT_NAME --pid <номер_pid> --signal <TERM|KILL|STOP|CONT>
  ./$SCRIPT_NAME --pid <номер_pid> --renice <нове_значення_nice>
  ./$SCRIPT_NAME --help

Приклади:
  ./$SCRIPT_NAME --users --user test1
  ./$SCRIPT_NAME --find /etc "*ssh*"
  ./$SCRIPT_NAME --log /var/log/auth.log --follow
  ./$SCRIPT_NAME --pid 1234 --signal TERM
  ./$SCRIPT_NAME --pid 1234 --renice 5
EOF
}

# -------------------- Режим 1: Користувачі --------------------

cmd_users() {
    local username

    if [ "${1:-}" == "--user" ] && [ -n "${2:-}" ]; then
        username="$2"
        echo "=================================================="
        echo "          АУДИТ КОРИСТУВАЧА: $username            "
        echo "=================================================="

        if id "$username" >/dev/null 2>&1; then
            local user_info
            user_info=$(getent passwd "$username")

            echo "[UID]: $(id -u "$username")"
            echo "[GID]: $(id -g "$username")"
            echo "[Групи (id -nG)]: $(id -nG "$username" | sed 's/ /, /g')"
            echo "[Групи (groups)]: $(groups "$username" 2>/dev/null | cut -d: -f2 | sed 's/^ //')"
            echo "[Домашня директорія]: $(echo "$user_info" | cut -d: -f6)"
            echo "[Оболонка (Shell)]: $(echo "$user_info" | cut -d: -f7)"
        else
            echo "Помилка: Користувача '$username' не знайдено."
        fi
        echo "=================================================="
    else
        echo "=================================================="
        echo "          ЗАГАЛЬНИЙ АУДИТ КОРИСТУВАЧІВ            "
        echo "=================================================="

        echo "[Звичайні користувачі (Regular Users)]:"
        awk -F: '$3 >= 1000 && $3 <= 60000 {print "  - " $1 " (UID: " $3 ")"}' /etc/passwd

        echo "--------------------------------------------------"

        echo "[Користувачі онлайн (Активні сесії, who)]:"
        if [ -z "$(who)" ]; then
            echo "  Зараз немає активних сесій."
        else
            who | awk '{print "  - " $1 " (Термінал: " $2 ", Вхід: " $3 " " $4 ")"}'
        fi

        echo "--------------------------------------------------"
        echo "[Детальніше про сесії (w)]:"
        if command_exists w; then
            w
        else
            echo "  Утиліта 'w' не знайдена."
        fi
        echo "=================================================="
    fi
}

# -------------------- Режим 2: Системний звіт --------------------

generate_report_body() {
    echo "=================================================="
    echo "          СИСТЕМНИЙ ЗВІТ (OPS FIRST AID)          "
    echo "=================================================="

    local current_user is_root
    current_user=$(whoami)
    if [ "$EUID" -eq 0 ]; then
        is_root="Так (Privileged)"
    else
        is_root="Ні"
    fi
    echo "[Користувач]: $current_user | Запущено від root/sudo: $is_root"

    echo "[Хост]: $(hostname)"
    echo "[Час звіту]: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "[Uptime]: $(uptime -p 2>/dev/null || uptime)"
    echo "--------------------------------------------------"

    local cpu_model cpu_cores mem_total mem_free
    cpu_model=$(grep -m 1 "model name" /proc/cpuinfo | awk -F: '{print $2}' | sed 's/^[ \t]*//')
    cpu_cores=$(grep -c "^processor" /proc/cpuinfo)
    mem_total=$(awk '/MemTotal/ {printf "%.2f GB", $2/1024/1024}' /proc/meminfo)
    mem_free=$(awk '/MemAvailable/ {printf "%.2f GB", $2/1024/1024}' /proc/meminfo)

    echo "[Процесор]: ${cpu_model:-N/A} (${cpu_cores} cores)"
    echo "[Пам'ять]: Всього $mem_total, Доступно $mem_free"
    echo "--------------------------------------------------"

    echo "[Дисковий простір (df -h)]:"
    df -h -x tmpfs -x devtmpfs | head -n 6
    echo "--------------------------------------------------"

    echo "[Активні сесії користувачів (who)]:"
    if [ -z "$(who)" ]; then
        echo "  Зараз немає активних сесій."
    else
        who | awk '{print "  - " $1 " (Термінал: " $2 ", Вхід: " $3 " " $4 ", IP: " $5 ")"}'
    fi
    echo "--------------------------------------------------"

    echo "[Топ-5 процесів за CPU]:"
    ps -eo pid,user,%cpu,%mem,command --sort=-%cpu | head -n 6 | awk '{print "  " $0}'
    echo ""

    echo "[Топ-5 процесів за Пам'яттю]:"
    ps -eo pid,user,%cpu,%mem,command --sort=-%mem | head -n 6 | awk '{print "  " $0}'
    echo "--------------------------------------------------"

    local zombies
    zombies=$(ps -eo stat,pid,user,command | awk '$1 ~ /^[ZT]/' | grep -v "awk" || true)
    echo "[Зомбі (Z) або Зупинені (T) процеси]:"
    if [ -z "$zombies" ]; then
        echo "  Не знайдено. Все чисто."
    else
        echo "$zombies" | awk '{print "  " $0}'
    fi
    echo "=================================================="

    local root_disk_usage status status_reason
    root_disk_usage=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')

    status="OK"
    status_reason="Система працює в штатному режимі."

    if [ "$root_disk_usage" -ge 90 ]; then
        status="CRITICAL"
        status_reason="Критично мало місця на кореневому диску (використано ${root_disk_usage}%)."
    elif [ "$root_disk_usage" -ge 80 ]; then
        status="WARNING"
        status_reason="Кореневий диск заповнюється (використано ${root_disk_usage}%)."
    elif [ -n "$zombies" ]; then
        status="WARNING"
        status_reason="Виявлені зомбі або завислі (зупинені) процеси."
    fi

    echo "[ПІДСУМКОВИЙ СТАТУС]: $status"
    echo "[ДЕТАЛІ]: $status_reason"
    echo "=================================================="
}

cmd_report() {
    mkdir -p "$REPORT_DIR" 2>/dev/null || {
        echo "Попередження: не вдалося створити $REPORT_DIR, звіт буде показано лише в терміналі." >&2
        generate_report_body
        return
    }

    local report_file="${REPORT_DIR}/report_$(date '+%Y-%m-%d_%H-%M-%S').txt"

    # Показуємо в терміналі і одночасно зберігаємо у файл
    generate_report_body | tee "$report_file"

    echo ""
    echo "[Звіт збережено]: $report_file"

    # Бонус: симлінк на останній звіт
    ln -sf "$report_file" "${REPORT_DIR}/latest_report.txt" 2>/dev/null || true
}

# -------------------- Режим 3: Процеси --------------------

cmd_proc() {
    if [ "${1:-}" == "--pid" ] && [ -n "${2:-}" ]; then
        local pid="$2"

        if ! is_integer "$pid"; then
            echo "Помилка: PID повинен бути числом, отримано: '$pid'."
            return 1
        fi

        echo "=================================================="
        echo "          ДЕТАЛІ ПРОЦЕСУ PID: $pid                "
        echo "=================================================="

        if ps -p "$pid" >/dev/null 2>&1; then
            local proc_info user ppid stat cmd
            proc_info=$(ps -o user=,pid=,ppid=,stat=,args= -p "$pid")

            user=$(echo "$proc_info" | awk '{print $1}')
            ppid=$(echo "$proc_info" | awk '{print $3}')
            stat=$(echo "$proc_info" | awk '{print $4}')
            cmd=$(echo "$proc_info" | awk '{$1=$2=$3=$4=""; print $0}')

            echo "[Власник]: $user"
            echo "[PID / PPID]: $pid / $ppid"
            echo "[Статус]: $stat"
            echo "[Команда]: $cmd"
            echo "--------------------------------------------------"
            echo "[Ланцюг батьківських процесів (pstree)]:"
            if command_exists pstree; then
                pstree -s "$pid"
            else
                echo "  Утиліта 'pstree' не встановлена."
            fi
        else
            echo "Помилка: Процес із PID $pid не знайдено."
        fi
        echo "=================================================="
    else
        echo "=================================================="
        echo "          МОНІТОРИНГ СТАНІВ ПРОЦЕСІВ             "
        echo "=================================================="

        echo "[Топ-10 процесів за навантаженням]:"
        ps aux --sort=-%cpu | head -n 11 | awk '{print "  " $1, $2, $3, $4, $11}'
        echo ""

        echo "[Статистика за станами]:"
        for state in R S D T Z; do
            local count
            count=$(ps -eo stat | grep -c "^$state" || true)
            echo "  Стан $state: $count процеси(ів)"
        done
        echo "=================================================="
    fi
}

# -------------------- Режим 4: Пошук файлів --------------------

cmd_find() {
    local search_dir="${1:-}"
    local pattern="${2:-}"

    if [ -z "$search_dir" ] || [ -z "$pattern" ]; then
        echo "Помилка: Потрібно вказати директорію та патерн."
        echo "Приклад: ./$SCRIPT_NAME --find /etc \"*ssh*\""
        return 1
    fi

    if [ ! -d "$search_dir" ]; then
        echo "Помилка: Директорія $search_dir не існує."
        return 1
    fi

    echo "=================================================="
    echo "          ПОШУК: '$pattern' У '$search_dir'        "
    echo "=================================================="

    if command_exists file; then
        find "$search_dir" -name "$pattern" -exec file {} \; 2>/dev/null
    else
        echo "Утиліта 'file' не знайдена, показую лише шляхи:"
        find "$search_dir" -name "$pattern" 2>/dev/null
    fi

    echo "--------------------------------------------------"
    echo "[Дерево структури (глибина 2)]:"

    if command_exists tree; then
        tree -L 2 "$search_dir"
    else
        echo "  Утиліта 'tree' не встановлена. Встановіть її для візуалізації (sudo apt install tree)."
    fi
    echo "=================================================="
}

# -------------------- Режим 5: Логи --------------------

cmd_log() {
    local log_file="${1:-}"
    local follow_flag="${2:-}"

    if [ -z "$log_file" ]; then
        echo "Помилка: Вкажіть шлях до лог-файлу."
        return 1
    fi

    if [ ! -f "$log_file" ]; then
        echo "Помилка: Файл '$log_file' не знайдено."
        return 1
    fi

    echo "=================================================="
    echo "          АНАЛІЗ ЛОГУ: $log_file                  "
    echo "=================================================="

    local line_count
    line_count=$(wc -l < "$log_file")
    echo "[Загальна кількість рядків]: $line_count"
    echo "--------------------------------------------------"

    echo "[Останні 20 рядків]:"
    tail -n 20 "$log_file"
    echo "--------------------------------------------------"

    if [ "$follow_flag" == "--follow" ]; then
        echo "[РЕЖИМ LIVE]: Переходжу в режим стеження (tail -f)."
        echo "Натисніть Ctrl+C для завершення."
        echo "=================================================="
        tail -f "$log_file"
    else
        echo "Для моніторингу в реальному часі додайте прапорець '--follow'."
        echo "=================================================="
    fi
}

# -------------------- Режим 6: Дії з PID (сигнали, renice) --------------------

cmd_pid_action() {
    local pid="${1:-}"
    local action="${2:-}"
    local value="${3:-}"

    if [ -z "$pid" ] || ! is_integer "$pid"; then
        echo "ПОМИЛКА: Потрібно вказати коректний числовий PID."
        return 1
    fi

    if [ "$pid" -eq 1 ]; then
        echo "ПОМИЛКА: Операції з PID 1 заборонені! Це серце системи."
        return 1
    fi

    if ! ps -p "$pid" >/dev/null 2>&1; then
        echo "ПОМИЛКА: Процес із PID $pid не знайдено."
        return 1
    fi

    case "$action" in
        --signal)
            case "$value" in
                TERM|KILL|STOP|CONT)
                    if { [ "$value" == "KILL" ] || [ "$value" == "TERM" ]; } && [ "$EUID" -ne 0 ]; then
                        echo "ПОМИЛКА: Для відправки сигналів TERM або KILL потрібні права root (sudo)."
                        return 1
                    fi
                    echo "ДІЯ: Відправляю сигнал $value процесу $pid..."
                    kill -"$value" "$pid"
                    ;;
                *)
                    echo "ПОМИЛКА: Непідтримуваний сигнал '$value'. Дозволені: TERM, KILL, STOP, CONT."
                    return 1
                    ;;
            esac
            ;;

        --renice)
            if ! is_integer "$value"; then
                echo "ПОМИЛКА: Значення nice повинно бути цілим числом."
                return 1
            fi
            if [ "$value" -lt 0 ] && [ "$EUID" -ne 0 ]; then
                echo "ПОМИЛКА: Підвищення пріоритету (від'ємні значення) доступне тільки для root."
                return 1
            fi
            echo "ДІЯ: Змінюю пріоритет (nice) процесу $pid на $value..."
            renice -n "$value" -p "$pid"
            ;;

        *)
            echo "ПОМИЛКА: Невідома дія '$action'. Використовуйте --signal або --renice."
            return 1
            ;;
    esac
}

# -------------------- Точка входу --------------------

main() {
    check_linux

    local command="${1:-}"

    case "$command" in
        --help|-h)
            show_help
            ;;

        --users)
            cmd_users "${2:-}" "${3:-}"
            ;;

        --report)
            cmd_report
            ;;

        --proc)
            cmd_proc "${2:-}" "${3:-}"
            ;;

        --find)
            cmd_find "${2:-}" "${3:-}"
            ;;

        --log)
            cmd_log "${2:-}" "${3:-}"
            ;;

        --pid)
            cmd_pid_action "${2:-}" "${3:-}" "${4:-}"
            ;;

        "")
            echo "Помилка: Команда не вказана."
            echo ""
            show_help
            exit 1
            ;;

        *)
            echo "Помилка: Невідома команда або аргумент: '$command'."
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
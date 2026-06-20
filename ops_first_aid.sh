#!/bin/bash

COMMAND="$1"

case "$COMMAND" in

    # 1. Блок роботи з користувачами
    --users)
        if [ "$2" == "--user" ] && [ -n "$3" ]; then
            USERNAME="$3"
            echo "=================================================="
            echo "          АУДИТ КОРИСТУВАЧА: $USERNAME            "
            echo "=================================================="
            
            # Перевіряємо, чи існує такий користувач у системі
            if id "$USERNAME" >/dev/null 2>&1; then
                # Отримуємо повний рядок конфігурації користувача
                USER_INFO=$(getent passwd "$USERNAME")
                
                # Витягуємо потрібні дані
                echo "[UID]: $(id -u "$USERNAME")"
                echo "[GID]: $(id -g "$USERNAME")"
                # id -nG виводить імена груп через пробіл, замінюємо пробіли на коми для краси
                echo "[Групи]: $(id -nG "$USERNAME" | sed 's/ /, /g')"
                echo "[Домашня директорія]: $(echo "$USER_INFO" | cut -d: -f6)"
                echo "[Оболонка (Shell)]: $(echo "$USER_INFO" | cut -d: -f7)"
            else
                echo "Помилка: Користувача '$USERNAME' не знайдено."
            fi
            echo "=================================================="
        else
            echo "=================================================="
            echo "          ЗАГАЛЬНИЙ АУДИТ КОРИСТУВАЧІВ            "
            echo "=================================================="
            
            echo "[Звичайні користувачі (Regular Users)]:"
            # Фільтруємо реєстр: шукаємо користувачів з UID від 1000 до 60000
            awk -F: '$3 >= 1000 && $3 <= 60000 {print "  - " $1 " (UID: " $3 ")"}' /etc/passwd
            
            echo "--------------------------------------------------"
            
            echo "[Користувачі онлайн (Активні сесії)]:"
            # Команда who показує активні підключення
            if [ -z "$(who)" ]; then
                echo "  Зараз немає активних сесій."
            else
                who | awk '{print "  - " $1 " (Термінал: " $2 ", Вхід: " $3 " " $4 ")"}'
            fi
            echo "=================================================="
        fi
        ;;

    # 2. Блок загального звіту
    --report)
        echo "=================================================="
        echo "          СИСТЕМНИЙ ЗВІТ (OPS FIRST AID)          "
        echo "=================================================="

        # 1. Поточний користувач та перевірка root
        CURRENT_USER=$(whoami)
        if [ "$EUID" -eq 0 ]; then
            IS_ROOT="Так (Privileged)"
        else
            IS_ROOT="Ні"
        fi
        echo "[Користувач]: $CURRENT_USER | Запущено від root/sudo: $IS_ROOT"

        # 2. Ім'я хоста та дата
        echo "[Хост]: $(hostname)"
        echo "[Час звіту]: $(date '+%Y-%m-%d %H:%M:%S')"

        # 3. Час безперервної роботи (Uptime)
        echo "[Uptime]: $(uptime -p)"
        echo "--------------------------------------------------"

        # 4. Інформація про CPU та пам'ять з /proc
        CPU_MODEL=$(grep -m 1 "model name" /proc/cpuinfo | awk -F: '{print $2}' | sed 's/^[ \t]*//')
        CPU_CORES=$(grep -c "processor" /proc/cpuinfo)
        MEM_TOTAL=$(awk '/MemTotal/ {printf "%.2f GB", $2/1024/1024}' /proc/meminfo)
        MEM_FREE=$(awk '/MemAvailable/ {printf "%.2f GB", $2/1024/1024}' /proc/meminfo)
        
        echo "[Процесор]: $CPU_MODEL ($CPU_CORES cores)"
        echo "[Пам'ять]: Всього $MEM_TOTAL, Доступно $MEM_FREE"
        echo "--------------------------------------------------"

        # 5. Змонтовані файлові системи (Тільки реальні диски, без tmpfs)
        echo "[Дисковий простір (df -h)]:"
        df -h -x tmpfs -x devtmpfs | head -n 6
        echo "--------------------------------------------------"

        # 6. Користувачі, які зараз увійшли в систему
        echo "[Активні сесії користувачів]:"
        who | awk '{print "  - " $1 " (Термінал: " $2 ", Вхід: " $3 " " $4 ", IP: " $5 ")"}'
        echo "--------------------------------------------------"

        # 7. Топ-5 процесів (CPU)
        echo "[Топ-5 процесів за CPU]:"
        ps -eo pid,user,%cpu,%mem,command --sort=-%cpu | head -n 6 | awk '{print "  " $0}'
        echo ""
        
        # 8. Топ-5 процесів (Пам'ять)
        echo "[Топ-5 процесів за Пам'яттю]:"
        ps -eo pid,user,%cpu,%mem,command --sort=-%mem | head -n 6 | awk '{print "  " $0}'
        echo "--------------------------------------------------"

        # 9. Процеси "зомбі" або зупинені процеси
        ZOMBIES=$(ps -eo stat,pid,user,command | awk '$1 ~ /^[ZT]/' | grep -v "awk")
        echo "[Зомбі (Z) або Зупинені (T) процеси]:"
        if [ -z "$ZOMBIES" ]; then
            echo "  Не знайдено. Все чисто."
        else
            echo "$ZOMBIES" | awk '{print "  " $0}'
        fi
        echo "=================================================="

        # 10. Підсумкове резюме статусу (Логіка оцінки)
        ROOT_DISK_USAGE=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
        
        STATUS="OK"
        STATUS_REASON="Система працює в штатному режимі."

        if [ "$ROOT_DISK_USAGE" -ge 90 ]; then
            STATUS="CRITICAL"
            STATUS_REASON="Критично мало місця на кореневому диску (використано ${ROOT_DISK_USAGE}%)."
        elif [ "$ROOT_DISK_USAGE" -ge 80 ]; then
            STATUS="WARNING"
            STATUS_REASON="Кореневий диск заповнюється (використано ${ROOT_DISK_USAGE}%)."
        elif [ -n "$ZOMBIES" ]; then
            STATUS="WARNING"
            STATUS_REASON="Виявлені зомбі або завислі (зупинені) процеси."
        fi

        echo "[ПІДСУМКОВИЙ СТАТУС]: $STATUS"
        echo "[ДЕТАЛІ]: $STATUS_REASON"
        echo "=================================================="
        ;;

    # 3. Блок роботи з процесами
    -proc)
        if [ "$2" == "--pid" ] && [ -n "$3" ]; then
            PID="$3"
            echo "=================================================="
            echo "          ДЕТАЛІ ПРОЦЕСУ PID: $PID                "
            echo "=================================================="
            
            # Перевіряємо, чи існує процес
            if ps -p "$PID" >/dev/null 2>&1; then
                # Отримуємо дані про процес
                # user, pid, ppid, stat, args
                PROC_INFO=$(ps -o user=,pid=,ppid=,stat=,args= -p "$PID")
                
                USER=$(echo "$PROC_INFO" | awk '{print $1}')
                PID=$(echo "$PROC_INFO" | awk '{print $2}')
                PPID=$(echo "$PROC_INFO" | awk '{print $3}')
                STAT=$(echo "$PROC_INFO" | awk '{print $4}')
                CMD=$(echo "$PROC_INFO" | awk '{$1=$2=$3=$4=""; print $0}')
                
                echo "[Власник]: $USER"
                echo "[PID / PPID]: $PID / $PPID"
                echo "[Статус]: $STAT"
                echo "[Команда]: $CMD"
                echo "--------------------------------------------------"
                echo "[Ланцюг батьківських процесів (pstree)]:"
                pstree -s "$PID"
            else
                echo "Помилка: Процес із PID $PID не знайдено."
            fi
            echo "=================================================="
        else
            echo "=================================================="
            echo "          МОНІТОРИНГ СТАНІВ ПРОЦЕСІВ             "
            echo "=================================================="
            
            # 1. Топ процесів (просто короткий список)
            echo "[Топ-10 процесів за навантаженням]:"
            ps aux --sort=-%cpu | head -n 11 | awk '{print "  " $1, $2, $3, $4, $11}'
            echo ""
            
            # 2. Детекція процесів за станами (R, S, D, T, Z)
            echo "[Статистика за станами]:"
            for state in R S D T Z; do
                count=$(ps -eo stat | grep -c "^$state")
                echo "  Стан $state: $count процеси(ів)"
            done
            echo "=================================================="
        fi
        ;;

    # 4. Блок пошуку файлів
    -find)
        # $2 — директорія, $3 — патерн
        SEARCH_DIR="$2"
        PATTERN="$3"

        if [ -z "$SEARCH_DIR" ] || [ -z "$PATTERN" ]; then
            echo "Помилка: Потрібно вказати директорію та патерн."
            exit 1
        fi

        if [ ! -d "$SEARCH_DIR" ]; then
            echo "Помилка: Директорія $SEARCH_DIR не існує."
            exit 1
        fi

        echo "=================================================="
        echo "          ПОШУК: '$PATTERN' У '$SEARCH_DIR'        "
        echo "=================================================="

        # 1. Пошук файлів та визначення їх типу
        # find шукає, а для кожного знайденого об'єкта виконується команда file
        find "$SEARCH_DIR" -name "$PATTERN" -exec file {} \; 2>/dev/null
        
        echo "--------------------------------------------------"
        echo "[Дерево структури (глибина 2)]:"
        
        # 2. Перевірка наявності утиліти tree
        if command -v tree >/dev/null 2>&1; then
            # Якщо tree встановлено, показуємо дерево
            tree -L 2 "$SEARCH_DIR"
        else
            # Якщо tree відсутня — виводимо коректне попередження
            echo "  Утиліта 'tree' не встановлена. Встановіть її для візуалізації (sudo apt install tree)."
        fi
        echo "=================================================="
        ;;

    # 5. Блок роботи з логами
    -log)
        # $2 — шлях до файлу, $3 — опціональний прапорець -follow
        LOG_FILE="$2"
        FOLLOW="$3"

        # 1. Перевірка, чи вказано шлях
        if [ -z "$LOG_FILE" ]; then
            echo "Помилка: Вкажіть шлях до лог-файлу."
            exit 1
        fi

        # 2. Перевірка існування файлу
        if [ ! -f "$LOG_FILE" ]; then
            echo "Помилка: Файл '$LOG_FILE' не знайдено."
            exit 1
        fi

        # 3. Аналіз файлу
        echo "=================================================="
        echo "          АНАЛІЗ ЛОГУ: $LOG_FILE                  "
        echo "=================================================="
        
        # Кількість рядків у файлі
        LINE_COUNT=$(wc -l < "$LOG_FILE")
        echo "[Загальна кількість рядків]: $LINE_COUNT"
        echo "--------------------------------------------------"
        
        # Останні 20 рядків
        echo "[Останні 20 рядків]:"
        tail -n 20 "$LOG_FILE"
        echo "--------------------------------------------------"

        # 4. Режим моніторингу
        if [ "$FOLLOW" == "-follow" ]; then
            echo "[РЕЖИМ LIVE]: Переходжу в режим стеження (tail -f)."
            echo "Натисніть Ctrl+C для завершення."
            echo "=================================================="
            tail -f "$LOG_FILE"
        else
            echo "Для моніторингу в реальному часі додайте прапорець '-follow'."
            echo "=================================================="
        fi
        ;;

    # 6. Блок управління конкретним PID (Сигнали та Пріоритети)
    --pid)
        # $2 — це PID (1234)
        # $3 — це дія (--signal або --renice)
        # $4 — це значення (TERM, 5 тощо)
        
        PID="$2"
        ACTION="$3"
        VALUE="$4"

        # 1. Захист від PID 1 (Init/Systemd)
        if [ "$PID" -eq 1 ]; then
            echo "ПОМИЛКА: Операції з PID 1 заборонені! Це серце системи."
            exit 1
        fi

        # 2. Перевірка існування процесу
        if ! ps -p "$PID" >/dev/null 2>&1; then
            echo "ПОМИЛКА: Процес із PID $PID не знайдено."
            exit 1
        fi

        # 3. Виконання дій
        case "$ACTION" in
            --signal)
                # Перевірка на небезпечні сигнали (потрібен root)
                if [[ "$VALUE" == "KILL" || "$VALUE" == "TERM" ]]; then
                    if [ "$EUID" -ne 0 ]; then
                        echo "ПОМИЛКА: Для відправки сигналів TERM або KILL потрібні права root (sudo)."
                        exit 1
                    fi
                fi
                
                echo "ДІЯ: Відправляю сигнал $VALUE процесу $PID..."
                kill -"$VALUE" "$PID"
                ;;

            --renice)
                # Перевірка на підвищення пріоритету (потрібен root)
                # Якщо значення < 0, це підвищення пріоритету, що потребує root
                if [ "$VALUE" -lt 0 ] && [ "$EUID" -ne 0 ]; then
                    echo "ПОМИЛКА: Підвищення пріоритету (від'ємні значення) доступне тільки для root."
                    exit 1
                fi
                
                echo "ДІЯ: Змінюю пріоритет (nice) процесу $PID на $VALUE..."
                renice -n "$VALUE" -p "$PID"
                ;;

            *)
                echo "ПОМИЛКА: Невідома дія '$ACTION'. Використовуйте --signal або --renice."
                exit 1
                ;;
        esac
        ;;

    # 7. Блок за замовчуванням (Довідка)
    *)
        # Спрацює, якщо скрипт запустили без аргументів або ввели щось неправильне
        echo "Помилка: Невідома команда або аргумент."
        echo ""
        echo "=== Довідка з використання ops_first_aid.sh ==="
        echo "Використовуйте одну з наступних команд:"
        echo "  ./ops_first_aid.sh --users"
        echo "  ./ops_first_aid.sh --users --user <імя_користувача>"
        echo "  ./ops_first_aid.sh -report"
        echo "  ./ops_first_aid.sh -proc"
        echo "  ./ops_first_aid.sh -proc --pid <номер_pid>"
        echo "  ./ops_first_aid.sh -find <директорія> <патерн_пошуку>"
        echo "  ./ops_first_aid.sh -log <шлях_до_файлу>"
        echo "  ./ops_first_aid.sh -log <шлях_до_файлу> -follow"
        echo "  ./ops_first_aid.sh -pid <номер_pid> -signal <назва_сигналу>"
        echo "  ./ops_first_aid.sh -pid <номер_pid> -renice <нове_значення_nice>"
        ;;
esac
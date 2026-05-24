#!/bin/bash

# Не строгая проверка на ошибки (сразу выход)
set -o pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# === Обработка флагов запуска ===
AUTO_YES=false
while getopts "y" opt; do
    case $opt in
        y) AUTO_YES=true ;;
        \?) echo "Недопустимая опция: -$OPTARG" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

#===============================================================================
# Функции логирования и вывода
#===============================================================================
LOG_FILE="/var/log/install_talsql_$(date +%Y%m%d_%H%M%S).log"
WINEPREFIX="WINEPREFIX=$HOME/.talsql"
SHARES=()
USER="" PASS=""
SERVER=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

info()  { echo -e "${BLUE}[INFO]${NC} $1"; log "INFO: $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; log "WARN: $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; log "ERROR: $1"; }
success(){ echo -e "${GREEN}[OK]${NC} $1"; log "OK: $1"; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        ORIG_USER=$(whoami)      
        echo "[!] Требуются права root. Введите пароль:"
        
        # Собираем флаги для повторной передачи
        local flags=""
        [[ "$AUTO_YES" == "true" ]] && flags="-y"
        
        # Безопасное экранирование аргументов для su -c
        local escaped_args=()
        for arg in "$@"; do
            escaped_args+=("$(printf '%q' "$arg")")
        done
        
        # Перезапуск с сохранением окружения и аргументов
        exec su root -c "ORIG_USER='$ORIG_USER' AUTO_YES='$AUTO_YES' bash \"$(realpath "$0")\" $flags ${escaped_args[*]}"
    fi
}

show_preview(){
    echo -e "${GREEN}===========================================${NC}"
    echo -e "${GREEN}        Установка Талисмана SQL            ${NC}"
    echo -e "${GREEN}Этапы установки:                           ${NC}"
    echo -e "${GREEN}- Установка Wine                           ${NC}"
    echo -e "${GREEN}- Настройка сетевых папок                  ${NC}"
    echo -e "${GREEN}- Установка Талисмана SQL                  ${NC}"
    echo -e "${GREEN}- Копирование из out в TalSQL              ${NC}"
    echo -e "${GREEN}- Копирование библиотек в system32         ${NC}"
    echo -e "${GREEN}- Установка Designfr                       ${NC}"
    echo -e "${GREEN}- Установка BDE для импорта питания        ${NC}"
    echo -e "${GREEN}Логирование:                               ${NC}"
    echo -e "${GREEN}$LOG_FILE ${NC}"
    echo -e "${GREEN}Архив fstab:                               ${NC}"
    echo -e "${GREEN}/root/backup_t                             ${NC}"
    echo -e "${GREEN}===========================================${NC}"
}

show_success(){
    echo -e "${GREEN}===========================================${NC}"
    echo -e "${GREEN}Поздравляю!                                ${NC}"
    echo -e "${GREEN}"Талисман SQL успешно установлен!"         ${NC}"
    echo -e "${GREEN}===========================================${NC}"
}

#===============================================================================
# Подтверждение действия пользователем
#===============================================================================
confirm() {
    # Если запущено с -y, всегда возвращаем "Да" без запроса
    if [[ "$AUTO_YES" == "true" ]]; then
        return 0
    fi

    local prompt="$1"
    local response
    
    while true; do
        echo -e "${YELLOW}$prompt${NC} [Y/n]: "
        read -r response
        
        # Проверка на допустимые варианты
        if [[ -z "$response" ]] || [[ "$response" =~ ^[YyNn]$ ]]; then
            # Допустимый ввод
            if [[ -z "$response" ]] || [[ "$response" =~ ^[Yy]$ ]]; then
                return 0  # Да
            else
                return 1  # Нет (N/n)
            fi
        else
            # Неверный ввод
            echo -e "${RED}Ошибка: введите Y, y, N, n или нажмите Enter${NC}"
        fi
    done
}

#===============================================================================
# Попытки выполнить команду и проверка
#===============================================================================
check() {
    local func="$1"; shift
    local max_attempts=3
    local attempt=0

    while (( attempt < max_attempts )); do
        ((attempt++))
        if (( attempt > 1 )); then
            info "Попытка #$attempt/$max_attempts выполнить '$func'..."
        fi

        # Запуск функции
        "$func" "$@" 2>&1
        local status=${PIPESTATUS[0]}  # ← Статус именно функции, а не tee

        if [[ $status -eq 0 ]]; then
            if (( attempt == 1 )); then
                success "Шаг '$func' выполнен успешно"
            else
                success "Шаг '$func' выполнен успешно со $attempt-й попытки"
            fi
            return 0  # ← Сразу выходим, не доходя до confirm
        fi

        warn "Ошибка выполнения '$func' (код: $status)"
        if (( attempt < max_attempts )); then
            info "Повторная попытка через 10 секунд..."
            sleep 10
        fi
    done

    error "Не удалось выполнить шаг '$func' после $max_attempts попыток"
    if confirm "Продолжить выполнение скрипта?"; then
        warn "Пользователь согласился игнорировать ошибку"
        return 0
    else
        warn "Пользователь прервал выполнение скрипта"
        exit 1
    fi
}

#===============================================================================
# Запустить от имени пользователя
#===============================================================================
urun(){
    # 1. Если ORIG_USER пуст, запрашиваем и валидируем
    if [[ -z "$ORIG_USER" ]]; then
        read -rp "Введите имя пользователя для запуска: " ORIG_USER
        [[ -z "$ORIG_USER" ]] && { error "Имя пользователя не указано"; return 1; }
        if ! id "$ORIG_USER" &>/dev/null; then
            error "Пользователь '$ORIG_USER' не существует в системе"
            return 1
        fi
    fi

    # 2. su -c ожидает ОДНУ строку-команду, поэтому "$*" здесь корректно
    local cmd="$*"
    
    # 3. Запуск с выводом ошибок в поток su
    if su - "$ORIG_USER" -c "$cmd" 2>&1; then
        success "$cmd выполнен успешно"
        return 0
    else
        error "Не удалось выполнить: $cmd"
        return 1
    fi
}

#===============================================================================
# Backup
#===============================================================================
backup() {
    local file="$1"
    local backup_dir="${2:-/root/backup_t}"  # 2-й аргумент = кастомный путь, иначе /root/backup_t
    
    [[ -z "$file" ]] && { echo "Не указан файл для бэкапа." >&2; return 1; }
    [[ ! -f "$file" ]] && { echo "Файл '$file' не существует или не является файлом." >&2; return 1; }
    [[ ! -r "$file" ]] && { echo "Нет прав на чтение '$file'." >&2; return 1; }

    local filename="${file##*/}"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local dest="$backup_dir/${filename}.${timestamp}"

    mkdir -p "$backup_dir" 2>/dev/null || { error "Не удалось создать $backup_dir" >&2; return 1; }

    if cp -p "$file" "$dest" 2>/dev/null; then
        info "Бэкап создан: $dest" >&2
        return 0
    else
        error "Бэкап '$file' не создан (проверьте права/место/ФС)." >&2
        return 1
    fi
}

# Удаляет элементы из глобального массива SHARES по индексам
_remove_from_shares() {
    [[ ${#SHARES[@]} -eq 0 ]] && { echo "   Список SHARES пуст."; return 0; }
    
    echo "Удаление шар из списка:"
    for i in "${!SHARES[@]}"; do
        echo "   [$i] ${SHARES[$i]}"
    done
    echo "   [q] Отмена"
    echo "   Введите номера через запятую: 0,2,3"
    
    while true; do
        read -p "   Удалить: " choice
        choice="${choice,,}"
        
        # Отмена
        [[ "$choice" == "q" ]] && { echo "   Отменено."; return 1; }
        
        # Парсинг ввода
        choice="${choice// /}"  # убираем пробелы
        IFS=',' read -ra parts <<< "$choice"
        
        local -a to_remove=()
        local valid=true
        
        for part in "${parts[@]}"; do
            [[ -z "$part" ]] && continue
            if ! [[ "$part" =~ ^[0-9]+$ ]]; then
                echo "   '$part' — не число."
                valid=false; break
            fi
            if (( part < 0 || part >= ${#SHARES[@]} )); then
                echo "   Номер $part вне диапазона (0–$((${#SHARES[@]}-1)))."
                valid=false; break
            fi
            # Проверка дублей в рамках ввода
            local dup=false
            for r in "${to_remove[@]}"; do [[ "$r" == "$part" ]] && { dup=true; break; }; done
            $dup || to_remove+=("$part")
        done
        
        $valid || continue
        [[ ${#to_remove[@]} -eq 0 ]] && { echo "   Введите номер или 'q'."; continue; }
        
        # === Удаление: собираем новый массив без указанных индексов ===
        local -a new_shares=()
        for i in "${!SHARES[@]}"; do
            local skip=false
            for idx in "${to_remove[@]}"; do
                (( i == idx )) && { skip=true; break; }
            done
            $skip || new_shares+=("${SHARES[$i]}")
        done
        
        # Показываем, что удаляем
        echo "   Будет удалено:"
        for idx in "${to_remove[@]}"; do
            echo "      • ${SHARES[$idx]}"
        done
        
        # Подтверждение (опционально, можно убрать)
        # confirm "Подтвердить удаление?" || continue
        
        SHARES=("${new_shares[@]}")
        echo "   Удалено. Осталось: ${#SHARES[@]} шар(а/ов)"
        return 0
    done
}

#===============================================================================
# Функция обнаружения и выбора шары
#===============================================================================

discover_and_select_share() {
    info "Подключение к серверу."
    local TARGET_SHARES=("out" "pochta" "talisman_sql" "talismansql" "strah")
    local ALL_DISK_SHARES=()
    
    SHARES=()  # Сброс результата при новом вызове

    # --- Ввод сервера ---
    read -p "Введите IP или имя сервера (Например: 192.168.1.100): " SERVER
    [[ -z "$SERVER" ]] && { warn "Сервер не указан."; return 1; }

    # --- Проверка smbclient ---
    if ! command -v smbclient &>/dev/null; then
        warn "Требуется пакет samba-client."
        info "   Установите: sudo apt-get install samba-client"
        return 1
    fi

    info "Сканирование шар на $SERVER..."

    # --- Попытка анонимного доступа ---
    local AUTH="-N"
    local RAW
    RAW=$(smbclient -L "//$SERVER" $AUTH -g 2>/dev/null)

    # --- Если анонимно не вышло — запрашиваем учётку ---
    if [[ $? -ne 0 || -z "$RAW" ]]; then
        info "   Анонимный доступ запрещён или сервер не отвечает."
        info "   Введите логин и пароль для подключения к серверу:"
        read -p "   Логин (Enter для пропуска): " USER
        if [[ -n "$USER" ]]; then
            read -sp "   Пароль: " PASS; echo
            AUTH="-U $USER%$PASS"
            RAW=$(smbclient -L "//$SERVER" $AUTH -g 2>/dev/null)
        fi
    fi

    [[ -z "$RAW" ]] && { echo "Не удалось получить список шар."; return 1; }

    # --- Парсинг вывода: собираем ВСЕ дисковые шары и отдельно ЦЕЛЕВЫЕ ---
    while IFS='|' read -r type name _; do
        [[ "$type" != "Disk" ]] && continue
        [[ -z "$name" ]] && continue
        
        ALL_DISK_SHARES+=("//$SERVER/$name")
        
        local lower="${name,,}"
        for t in "${TARGET_SHARES[@]}"; do
            if [[ "$lower" == "$t" ]]; then
                SHARES+=("//$SERVER/$name")
                break
            fi
        done
    done <<< "$RAW"

    # --- Вспомогательная функция выбора из списка ---
    # Использует глобальную переменную _SELECTED_ITEM для возврата значения
    _select_share_from_list() {
        local -n _list=$1  # nameref на массив (Bash ≥4.3)
        local _prompt="$2"
        local _choice
        local -a _selected=()

        while true; do

            echo "$_prompt"
            for i in "${!_list[@]}"; do
                echo "   [$i] ${_list[$i]}"
            done
            echo "   [d] Удалить [q] Выход"

            read -p "   Ваш выбор: " _choice
            _choice="${_choice,,}"
            
            if [[ "$_choice" == "q" ]]; then
                info "Выбор отменён пользователем."
                return 0
            fi
            
            if [[ "$_choice" == "d" ]]; then
                info "Выбран режим удаления из списка."
                for share in "${SHARES[@]}"; do
                    echo "$share"
                done
                _remove_from_shares
            fi

            # === Парсинг ввода через запятую ===
            # Убираем пробелы, разбиваем по запятой
            _choice="${_choice// /}"  # удаляем все пробелы
            IFS=',' read -ra _parts <<< "$_choice"
            _selected=()  # сброс
            local _valid=true
            
            for part in "${_parts[@]}"; do
                # Пропускаем пустые элементы (на случай ",," или "0,,2")
                [[ -z "$part" ]] && continue
                [[ "$part" == "d" ]] && continue

                # Проверка: только цифры
                if ! [[ "$part" =~ ^[0-9]+$ ]]; then
                    warn "   '$part' — некорректный номер. Введите числа или 'd' 'q'."
                    _valid=false
                    break
                fi
                
                # Проверка диапазона
                if (( part < 0 || part >= ${#_list[@]} )); then
                    warn "   Номер $part вне диапазона (0–$((${#_list[@]}-1)))."
                    _valid=false
                    break
                fi
                
                # Проверка на дубликаты в рамках одного ввода
                local is_dup=false
                for already in "${_selected[@]}"; do
                    [[ "$already" == "$part" ]] && { is_dup=true; break; }
                done
                if $is_dup; then
                    warn "   Номер $part уже выбран (пропущен дубль)."
                    continue
                fi
                
                _selected+=("$part")
            done

            # Если были ошибки — повторяем цикл
            $valid || continue
            [[ ${#_selected[@]} -eq 0 ]] && { info "   Введите хотя бы один номер или 'q'."; continue; }

            # === Добавляем выбранные элементы в глобальный SHARES ===
            for idx in "${_selected[@]}"; do
                local item="${_list[$idx]}"
                # Проверка на дубликаты в глобальном массиве (на всякий случай)
                local already_added=false
                for existing in "${SHARES[@]}"; do
                    [[ "$existing" == "$item" ]] && { already_added=true; break; }
                done
                if ! $already_added; then
                    SHARES+=("$item")
                    echo "   Добавлено: $item"
                fi
            done

            echo "Всего выбрано: ${#SHARES[@]} шар(а/ов)"
            for share in "${SHARES[@]}"; do
                success "$share"
            done
            confirm "Подтвердить выбор?" || continue
            return 0
        done
    }

    # --- Сценарий 1: Найдены целевые шары ---
    if [[ ${#SHARES[@]} -gt 0 ]]; then
        echo "Найдено ${#SHARES[@]} целевых шар:"
        for i in "${SHARES[@]}"; do
            echo "${i}"
        done
        ! confirm "Подтвердить выбор?" || return 0
    fi

    # --- Сценарий 2: Целевых нет — предлагаем ВСЕ дисковые шары ---
    if [[ ${#ALL_DISK_SHARES[@]} -eq 0 ]]; then
        echo "На сервере не найдено ни одной дисковой шары."
        return 1
    fi

    echo "Целевые шары (${TARGET_SHARES[*]}) не найдены."

    if _select_share_from_list ALL_DISK_SHARES "Все доступные дисковые шары — выберите вручную через запятую (Например: 1,2,3):"; then
        return 0
    else
        return 1
    fi
}

mount_talsql(){
    confirm "Подключится к серверу Талисмана SQL?" || return 0
    # Константы
    local CRED_FILE="/root/.cifstalsql"      # Единый путь для credentials
    local FSTAB_OPTS="noauto,x-systemd.automount,_netdev,rw,credentials=$CRED_FILE,soft,file_mode=0777,dir_mode=0777,nofail"
    
    # Запускаем обнаружение и выбор шар
    if ! discover_and_select_share; then
        echo "Операция прервана."
        return 1
    fi
    
    local BASE_MOUNT="/mnt/$SERVER"         # Базовая директория для всех шар
    
    echo "Готово. В массиве SHARES:"
    for s in "${SHARES[@]}"; do
        echo "   • $s"
    done
    
    # --- Создание файла учётных данных (если есть логин/пароль) ---
    if [[ -n "$USER" && -n "$PASS" ]]; then
        cat > "$CRED_FILE" <<EOF
username=$USER
password=$PASS
EOF
        chmod 600 "$CRED_FILE"
        echo "Файл учётных данных создан: $CRED_FILE"
    else
        # Для анонимного доступа создаём пустой файл (guest)
        echo "username=guest" > "$CRED_FILE"
        echo "password=" >> "$CRED_FILE"
        chmod 600 "$CRED_FILE"
    fi
    
    # Бэкап fstab перед добавление шар
    backup "/etc/fstab"

    # --- Монтирование КАЖДОЙ шары из массива ---
    for share_unc in "${SHARES[@]}"; do
        # Извлекаем имя шары из UNC: //192.168.205.4/strah → strah
        local share_name="${share_unc##*/}"
        local mount_point="$BASE_MOUNT/$share_name"
        local share_unc_fstab="${share_unc// /\\040}"
        local mount_point_fstab="${mount_point// /\\040}"
        
        echo ""
        echo "Обработка: $share_unc → $mount_point"
        
        # 1. Создаём точку монтирования
        mkdir -p "$mount_point"
        
        # 2. Добавляем запись в /etc/fstab (если ещё нет)
        if ! grep -qF "$share_unc_fstab $mount_point_fstab" /etc/fstab 2>/dev/null; then
            echo "$share_unc_fstab $mount_point_fstab cifs $FSTAB_OPTS 0 0" | tee -a /etc/fstab >/dev/null
            echo "   $mount_point_fstab Добавлено в /etc/fstab"
        else
            echo "   Запись уже есть в /etc/fstab"
        fi
    done
    
    # === АКТИВАЦИЯ SYSTEMD AUTOMOUNT ===
    echo ""
    echo "Активация systemd-юнитов для авто-монтирования..."
    
    # 1. Перезагружаем конфигурацию systemd (чтобы увидел новые записи fstab)
    systemctl daemon-reload 2>/dev/null || {
        echo "Не удалось выполнить daemon-reload (проверьте права/наличие systemd)"
    }
    
    # 2. Запускаем .automount для каждой шары
    for share_unc in "${SHARES[@]}"; do
        local share_name="${share_unc##*/}"
        local mount_point="$BASE_MOUNT/$share_name"
        
        # Конвертируем путь в имя юнита: /mnt/$SERVER/strah → mnt-$SERVER-strah
        local unit_name
        unit_name=$(systemd-escape --path "$mount_point")
        local automount_unit="${unit_name}.automount"
        
        echo "   Запуск $automount_unit ..."
        
        # Запускаем automount (не mount! — чтобы сработало по требованию)
        if systemctl start "$automount_unit" 2>/dev/null; then
            echo "   $automount_unit активирован"
        else
            # Если .automount нет, пробуем .mount (на случай, если опция noauto не сработала)
            if systemctl start "${unit_name}.mount" 2>/dev/null; then
                echo "   ${unit_name}.mount смонтирован напрямую"
            else
                echo "   Не удалось активировать $automount_unit (проверьте: systemctl status $automount_unit)"
            fi
        fi
    done
    
    echo ""
    echo "Все шары обработаны."
    echo "Проверка:   mount | grep talsql"
    echo "Статус юнитов:   systemctl list-units | grep talsql"
    echo "Тест автомонта:   ls /mnt/$SERVER/out  # должно подмонтировать автоматически"
    return 0
}

create_unc_links() {
    # Проверка AUTO_YES для пропуска вопроса
    if [[ "$AUTO_YES" != "true" ]]; then
        confirm "Создать ссылки с шарами для Wine?" || return 0
    fi

    # 1. Если SERVER не задан, запрашиваем интерактивно
    if [[ -z "$SERVER" ]]; then
        read -rp "Введите IP или имя сервера для UNC-путей (Например: 192.168.1.100): " SERVER
        [[ -z "$SERVER" ]] && { error "Сервер не указан."; return 1; }
    fi

    # Раскрываем ~ в пути, чтобы не создавать ссылки в /root/
    local unc_dir="${WINEPREFIX#WINEPREFIX=}/dosdevices/unc/$SERVER"
    local mount_base="/mnt/$SERVER"

    # 2. Проверка, что шары действительно смонтированы
    if [[ ! -d "$mount_base" || -z "$(ls -A "$mount_base" 2>/dev/null)" ]]; then
        warn "Директория $mount_base пуста или не найдена. Шары не смонтированы?"
        return 1
    fi

    # 3. Создаём структуру UNC (проверяем существование перед созданием)
    if [[ ! -d "$unc_dir" ]]; then
        urun "mkdir -p $(printf '%q' "$unc_dir")" || { error "Ошибка создания $unc_dir"; return 1; }
    fi

    info "Создание UNC-ссылок для //$SERVER..."

    local count=0
    local skipped=0
    
    # Проходим по всем папкам в точке монтирования
    for share_path in "$mount_base"/*/; do
        [[ -d "$share_path" ]] || continue  # Пропуск, если glob не сработал

        # Извлекаем чистое имя шары
        local share_name="${share_path%/}"
        share_name="${share_name##*/}"

        local link_path="$unc_dir/$share_name"
        
        # === ПРОВЕРКА: Существует ли уже ссылка? ===
        # -L проверяет именно символическую ссылку
        if [[ -L "$link_path" ]]; then
            # Проверяем, куда она ведёт (читаем цель ссылки)
            local current_target
            current_target=$(readlink "$link_path")
            
            # Сравниваем с желаемым путём (нормализуем для сравнения)
            if [[ "$current_target" == "$share_path" ]]; then
                info "   [SKIP] $share_name: ссылка уже существует и верна"
                ((skipped++))
                continue  # Переходим к следующей, не создаём заново
            else
                warn "   [UPDATE] $share_name: ссылка ведёт на '$current_target', обновляем..."
                # Если ссылка есть, но ведёт не туда — удалим старую перед созданием новой
                urun "rm -f $(printf '%q' "$link_path")"
            fi
        elif [[ -e "$link_path" ]]; then
            # Если это не ссылка, а файл или папка (конфликт имён)
            error "   [CONFLICT] $link_path существует, но не является ссылкой. Пропускаем."
            ((skipped++))
            continue
        fi
        # =========================================

        # Создаём/обновляем симлинк
        local safe_path safe_dest
        safe_path=$(printf '%q' "$share_path")
        safe_dest=$(printf '%q' "$share_name")
        
        if urun "ln -sf $safe_path $unc_dir/$safe_dest"; then
            info "   [OK] $share_name -> $share_path"
            ((count++))
        else
            error "   [ERROR] Ошибка создания ссылки для $share_name"
        fi
    done

    if [[ $count -eq 0 && $skipped -eq 0 ]]; then
        warn "В $mount_base не найдено доступных папок."
        return 1
    fi

    success "Готово. Создано: $count, пропущено: $skipped"
    success "В Wine доступны пути: \\\\$SERVER\\<имя_шары>"
    return 0
}

#===============================================================================
# Вспомогательная функция: поиск папки "out" в дереве каталогов (глубина 2)
#===============================================================================
find_out_directory() {
    local base_path="$1"
    local -a candidates=()
    
    # 1. Сначала проверяем очевидные варианты в корне и на 1 уровне вложенности
    local known_patterns=("out" "Out" "OUT" "Talisman_sql/out" "Talismansql/out" "talisman_sql/out" "Talisman_SQL/out" "talismansql/out")
    for pattern in "${known_patterns[@]}"; do
        if [[ -d "$base_path/$pattern" && -n "$(ls -A "$base_path/$pattern" 2>/dev/null)" ]]; then
            echo "$base_path/$pattern"
            return 0
        fi
    done
    
    # 2. Рекурсивный поиск с ограничением глубины 2 уровня
    # -mindepth 2: пропускаем саму base_path и её прямые подкаталоги (они уже проверены выше)
    # -maxdepth 2: не уходим глубже второго уровня
    while IFS= read -r -d '' dir; do
        # Проверяем, что папка не пустая
        if [[ -n "$(ls -A "$dir" 2>/dev/null)" ]]; then
            candidates+=("$dir")
        fi
    done < <(find "$base_path" -mindepth 2 -maxdepth 2 -type d -name "out" -print0 2>/dev/null)
    
    # 3. Обработка результатов
    if [[ ${#candidates[@]} -eq 0 ]]; then
        return 1  # Не найдено
    elif [[ ${#candidates[@]} -eq 1 ]]; then
        echo "${candidates[0]}"  # Найдено ровно одно
        return 0
    else
        # Найдено несколько — выводим список для выбора
        # printf '%s\n' "${candidates[@]}"
        echo "${candidates[0]}"
        return 0
    fi
}

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
install_wine(){
    confirm "Установить Wine?" || return 0

    local pkgs=(i586-wine winetricks wine-mono-8.1.0)

    apt-get update || { error "Ошибка update"; return 1; }
    success "update Завершен Успешно"

    for pkg in "${pkgs[@]}"; do
        if apt-get install -y "$pkg"; then
            success "$pkg установлен"
        else
            error "Ошибка установки $pkg"
            return 1
        fi
    done
}

create-prefix(){
    confirm "Создать Префикс .talsql?" || return 0
    local base_cmd="$WINEPREFIX WINEARCH=win32 wineboot"
    urun "$base_cmd" || return 1
    return 0
}

install-components(){
    confirm "Установить дополнительные компоненты?" || return 0

    local base_cmd="$WINEPREFIX winetricks -q"

    # --- Применение настроек ---
    for setting in win2k8 glsl=disabled ddr=gdi; do
        echo "Настройка: $setting"
        urun "$base_cmd $setting" || { confirm "Продолжить?" || return 1; }
    done

    # --- Установка пакетов ---
    for pkg in dotnet452 msxml3 msxml6 msftedit corefonts tahoma \
               riched20 riched30 vb6run gdiplus vcrun2005 vcrun2008 vcrun2010 \
               vcrun2012 vcrun2013; do
        echo "Установка: $pkg"
        
        local max_retries=3    # Количество повторов
        local attempt=0        # Счётчик текущей попытки
        local success=false

        while [ $attempt -le $max_retries ]; do
            # 1. Запускаем установку
            if urun "$base_cmd $pkg"; then
                success=true
                break  # Успех → выходим из цикла
            fi
            
            attempt=$((attempt + 1))
            
            # 2. Если попытки закончились → выходим
            if [ $attempt -gt $max_retries ]; then
                echo "[!] Превышен лимит попыток ($max_retries) для $pkg. Пропускаю."
                break
            fi
            
            # 3. Спрашиваем пользователя
            local remaining=$((max_retries - attempt + 1))
            if ! confirm "Повторить попытку установки $pkg? (Осталось: $remaining)"; then
                echo "[!] Отменено пользователем. Пропускаю $pkg."
                break
            fi
            info "Повторная попытка через 10 секунд..."
            sleep 10
        done
    done
    
    return 0
}

check-talsql(){
    confirm "Проверить наличие установочного файла Талисмана SQL (Reinstall_Tal3.1.52.exe)?" || return 0
    
    # === 1. Путь к скрипту (для внутренних операций) ===
    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    
    local installertalsql="Reinstall_Tal3.1.52.exe"
    local installer_path="$script_dir/$installertalsql"  # ← Обычный путь, без экранирования
    
    # === 2. Проверка существования (используем обычный путь!) ===
    if [[ -f "$installer_path" ]]; then
        success "$installer_path существует. Продолжаем установку..."
    else
        warn "$installer_path не найден!"
        
        # === 3. Для команд, передаваемых в urun — экранируем ОТДЕЛЬНО ===
        local safe_workpath
        safe_workpath=$(printf '%q' "$script_dir")  # ← Только здесь!
        
        confirm "Для скачивания потребуется установить модуль python3-module-pip, ydiskarc tqdm. Установить модули и Скачать $installertalsql?" || return 1
        
        apt-get install -y python3-module-pip || { error "Ошибка установки python3-module-pip"; return 1; }
        urun "pip3 install ydiskarc && python3 -c 'import ydiskarc'" || { error "Ошибка установки ydiskarc"; return 1; }
        urun "pip3 install tqdm && python3 -c 'import tqdm'" || { error "Ошибка установки tqdm"; return 1; }
        
        # Здесь используем $safe_workpath, т.к. это часть команды для su -c
        urun "~/.local/bin/ydiskarc sync https://disk.yandex.ru/d/V02lQpBYE3Wzog -o $safe_workpath" || { error "ydiskarc: ошибка скачивания $installertalsql"; return 1; }
        
        # === 4. Проверка после скачивания (снова обычный путь!) ===
        if [[ ! -f "$installer_path" ]]; then
            error "Не удалось скачать $installertalsql!"
            return 1
        else
            success "Файл успешно скачан в $script_dir"
        fi
    fi
    return 0
}

check_designfr(){
    confirm "Проверить наличие установочного файла Designfr" || return 0
    
    # === 1. Путь к скрипту (для внутренних операций) ===
    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    
    local installertalsql="designfr.exe"
    local installer_path="$script_dir/$installertalsql"  # ← Обычный путь, без экранирования
    
    # === 2. Проверка существования (используем обычный путь!) ===
    if [[ -f "$installer_path" ]]; then
        success "$installer_path существует. Продолжаем установку..."
    else
        warn "$installer_path не найден!"
        
        # === 3. Для команд, передаваемых в urun — экранируем ОТДЕЛЬНО ===
        local safe_workpath
        safe_workpath=$(printf '%q' "$script_dir")  # ← Только здесь!
        
        confirm "Для скачивания потребуется установить модуль python3-module-pip, ydiskarc tqdm. Установить модули и Скачать $installertalsql?" || return 1
        
        apt-get install -y python3-module-pip || { error "Ошибка установки python3-module-pip"; return 1; }
        urun "pip3 install ydiskarc && python3 -c 'import ydiskarc'" || { error "Ошибка установки ydiskarc"; return 1; }
        urun "pip3 install tqdm && python3 -c 'import tqdm'" || { error "Ошибка установки tqdm"; return 1; }
        
        # Здесь используем $safe_workpath, т.к. это часть команды для su -c
        urun "~/.local/bin/ydiskarc sync https://disk.yandex.ru/d/V02lQpBYE3Wzog -o $safe_workpath" || { error "ydiskarc: ошибка скачивания $installertalsql"; return 1; }
        
        # === 4. Проверка после скачивания (снова обычный путь!) ===
        if [[ ! -f "$installer_path" ]]; then
            error "Не удалось скачать $installertalsql!"
            return 1
        else
            success "Файл успешно скачан в $script_dir"
        fi
    fi
    return 0
}

check_bde(){
    confirm "Проверить наличие установочного файла BDE" || return 0
    
    # === 1. Путь к скрипту (для внутренних операций) ===
    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    
    local installertalsql="bdex64.exe"
    local installer_path="$script_dir/$installertalsql"  # ← Обычный путь, без экранирования
    
    # === 2. Проверка существования (используем обычный путь!) ===
    if [[ -f "$installer_path" ]]; then
        success "$installer_path существует. Продолжаем установку..."
    else
        warn "$installer_path не найден!"
        
        # === 3. Для команд, передаваемых в urun — экранируем ОТДЕЛЬНО ===
        local safe_workpath
        safe_workpath=$(printf '%q' "$script_dir")  # ← Только здесь!
        
        confirm "Для скачивания потребуется установить модуль python3-module-pip, ydiskarc tqdm. Установить модули и Скачать $installertalsql?" || return 1
        
        apt-get install -y python3-module-pip || { error "Ошибка установки python3-module-pip"; return 1; }
        urun "pip3 install ydiskarc && python3 -c 'import ydiskarc'" || { error "Ошибка установки ydiskarc"; return 1; }
        urun "pip3 install tqdm && python3 -c 'import tqdm'" || { error "Ошибка установки tqdm"; return 1; }
        
        # Здесь используем $safe_workpath, т.к. это часть команды для su -c
        urun "~/.local/bin/ydiskarc sync https://disk.yandex.ru/d/V02lQpBYE3Wzog -o $safe_workpath" || { error "ydiskarc: ошибка скачивания $installertalsql"; return 1; }
        
        # === 4. Проверка после скачивания (снова обычный путь!) ===
        if [[ ! -f "$installer_path" ]]; then
            error "Не удалось скачать $installertalsql!"
            return 1
        else
            success "Файл успешно скачан в $script_dir"
        fi
    fi
    return 0
}

copy_talsql_files(){
    confirm "Скопировать файлы Талисмана SQL из /mnt/$SERVER/out/ в ~/.talsql/drive_c/Talisman_SQL/ACenter/TalSQL и скопировать библиотеки midas.dll, gds32.dll и fbclient.dll в system32?" || return 0

    local wine_prefix="${WINEPREFIX//WINEPREFIX=/}"  # ~/.talsql
    local tal_dir="$wine_prefix/drive_c/Talisman_SQL/ACenter/TalSQL"
    local src_dir=$(find_out_directory "/mnt/$SERVER")
    local system32="$wine_prefix/drive_c/windows/system32"
    local dlls=("midas.dll" "gds32.dll" "fbclient.dll")

    # 1. Проверка исходной директории
    if [[ ! -d "$src_dir" ]]; then
        error "Директория источника не найдена: $src_dir"
        warn "Убедитесь, что шары смонтированы: mount | grep talsql"
        return 1
    fi

    # 2. Проверка целевой директории
    if [[ ! -d "$tal_dir" ]]; then
        error "Директория установки не найдена: $tal_dir"
        warn "Возможно, установка не завершена или путь отличается от C:\\Talisman_SQL"
        
        if confirm "Создать директорию $tal_dir?"; then
            # Используем безопасное экранирование пути
            if ! urun "mkdir -p $(printf '%q' "$tal_dir")"; then
                error "Не удалось создать $tal_dir (проверьте права)"
                return 1
            fi
            success "Директория создана: $tal_dir"
        else
            # Пользователь отказался создавать → нельзя продолжать
            warn "Пропуск копирования: целевая директория не создана"
            return 0
        fi
    fi

    info "Копирование файлов из $src_dir → $tal_dir"

    # 3. Копирование основных файлов (через urun, так как владелец — пользователь)
    if urun "yes | cp -rf '$src_dir'/* '$tal_dir/'"; then
        success "Файлы скопированы в $tal_dir"
    else
        error "Ошибка копирования файлов в $tal_dir"
        # Не прерываем скрипт, пробуем скопировать DLL
    fi

    # 4. Копирование DLL в system32
    info "Копирование DLL в $system32"
    local dll_errors=0
    for dll in "${dlls[@]}"; do
        local src="$src_dir/$dll"
        local dst="$system32/$dll"
        
        if [[ -f "$src" ]]; then
            if urun "yes | cp -fv '$src' '$dst'"; then
                success "   $dll → $system32"
            else
                error "   Не удалось скопировать $dll"
                ((dll_errors++))
            fi
        else
            warn "   Файл $dll не найден в $src_dir (пропускаем)"
        fi
    done

    # 5. Итоговый отчёт
    if [[ $dll_errors -eq ${#dlls[@]} ]]; then
        error "Не скопирован ни один DLL. Проверьте права и наличие файлов."
        return 1
    elif [[ $dll_errors -gt 0 ]]; then
        warn "Часть DLL не скопирована ($dll_errors из ${#dlls[@]}). Приложение может работать нестабильно."
    else
        success "Все файлы успешно скопированы."
    fi

    return 0
}

install-talsql(){
    info "Во время установки укажите папку C:\Talisman_SQL"

    confirm "Запустить установку Талисмана SQL (Reinstall_Tal3.1.52.exe)" || return 0

    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    local safe_workpath=$(printf '%q' "$script_dir")
    local installertalsql="Reinstall_Tal3.1.52.exe"
    local base_cmd="$WINEPREFIX wine $safe_workpath/$installertalsql"

    urun "$base_cmd" || return 1
}

install_designfr(){
    confirm "Запустить установку Designfr" || return 0

    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    local safe_workpath=$(printf '%q' "$script_dir")
    local installertalsql="designfr.exe"
    local base_cmd="$WINEPREFIX wine $safe_workpath/$installertalsql"

    urun "$base_cmd" || return 1
}

install_bde(){
    confirm "Запустить установку BDE" || return 0

    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    local safe_workpath=$(printf '%q' "$script_dir")
    local installertalsql="bdex64.exe"
    local base_cmd="$WINEPREFIX wine $safe_workpath/$installertalsql"

    urun "$base_cmd" || return 1
}

#===============================================================================
# Создание ярлыка на рабочем столе
#===============================================================================
create_desktop_shortcut(){
    
    # === 1. Определяем путь к рабочему столу пользователя ===
    local desktop_dir=""
    
    if [[ -d "/home/$ORIG_USER/Рабочий стол" ]]; then
        desktop_dir="/home/$ORIG_USER/Рабочий стол"
    elif [[ -d "/home/$ORIG_USER/Desktop" ]]; then
        desktop_dir="/home/$ORIG_USER/Desktop"
    fi
    
    local shortcut_path="$desktop_dir/ТалSQL.desktop"
    
    # === 2. Проверка: существует ли уже ярлык? ===
    # Проверяем от имени пользователя, так как файлы на его рабочем столе
    if [[ -f "$shortcut_path" ]]; then
        touch "$shortcut_path"
        update-desktop-database "$desktop_dir" 2>/dev/null || true
        info "Ярлык уже существует: $shortcut_path"
        return 0
    else
        confirm "Создать ярлык ТалSQL на рабочем столе?" || return 0
    fi
    
    info "Создаю ярлык: $shortcut_path"
    
    # === 3. Формируем содержимое .desktop файла ===
    # Важно: в Exec пути для Wine требуют двойного экранирования обратных слешей
    local wine_prefix="${WINEPREFIX#WINEPREFIX=}"
    local exe_path="C:\\\\Talisman_SQL\\\\ACenter\\\\TalSQL\\\\TalClient.exe"

urun "cat > '$shortcut_path' << 'DESKTOP_EOF'
[Desktop Entry]
Name=ТалSQL
Exec=env \"WINEPREFIX=$wine_prefix\" wine \"$exe_path\" \"\"
Type=Application
StartupNotify=true
Icon=D5C0_TalClient.0
StartupWMClass=talclient.exe
DESKTOP_EOF"

    # === 4. Копируем ярлык на рабочий стол от имени пользователя ===
    if [[ -f "$shortcut_path" ]]; then
        success "Ярлык создан: $shortcut_path"
        
        # === 5. Делаем ярлык исполняемым (обязательно для запуска) ===
        if urun "chmod +x '$shortcut_path'"; then
            info "Ярлык сделан исполняемым"
        fi
        
        # === 6. Меняем владельца на оригинального пользователя (если создавали из-под root) ===
        if [[ -n "$ORIG_USER" && "$(id -u)" -eq 0 ]]; then
            if chown "$ORIG_USER:$ORIG_USER" "$shortcut_path" 2>/dev/null; then
                info "Владелец изменён на $ORIG_USER"
            fi
        fi
        
        # === 7. Обновляем базу десктоп-файлов (опционально, для появления в меню) ===
        if command -v update-desktop-database &>/dev/null; then
            update-desktop-database "$desktop_dir" 2>/dev/null || true
        fi
        
    else
        error "Не удалось создать ярлык в $desktop_dir"
        rm -f "$tmp_file"
        return 1
    fi
    
    # Убираем временный файл
    rm -f "$tmp_file"
    
    # === 8. Подсказка для пользователя (если не авто-режим) ===
    if [[ "$AUTO_YES" != "true" ]]; then
        echo ""
        info "Совет: если ярлык не запускается, кликните по нему правой кнопкой → Свойства → Разрешения → Разрешить выполнение файла как программы"
    fi
    
    return 0
}

main() {
    local HAS_ERRORS=0
    show_preview
    check_root
    clear
    show_preview

    check install_wine       || $HAS_ERRORS=1
    check create-prefix      || $HAS_ERRORS=1
    check install-components || $HAS_ERRORS=1
    check mount_talsql       || $HAS_ERRORS=1
    check create_unc_links   || $HAS_ERRORS=1
    check check-talsql       || $HAS_ERRORS=1
    check install-talsql     || $HAS_ERRORS=1
    check copy_talsql_files  || $HAS_ERRORS=1
    check check_designfr     || $HAS_ERRORS=1
    check install_designfr   || $HAS_ERRORS=1
    check check_bde          || $HAS_ERRORS=1
    check install_bde        || $HAS_ERRORS=1
    create_desktop_shortcut  || $HAS_ERRORS=1
    if [[ $HAS_ERRORS -eq 0 ]]; then
        show_success
    else
        warn "Установка завершена с ошибками/пропусками. Проверьте лог: $LOG_FILE"
    fi
}

main "$@"
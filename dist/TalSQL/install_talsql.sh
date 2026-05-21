#!/bin/bash

# Не строгая проверка на ошибки (сразу выход)
set -o pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#===============================================================================
# Функции логирования и вывода
#===============================================================================
LOG_FILE="/var/log/install_talsql_$(date +%Y%m%d_%H%M%S).log"
WINEPREFIX="WINEPREFIX=~/.talsql"
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
        exec su root -c "ORIG_USER='$ORIG_USER' bash \"$(realpath "$0")\" \"$*\""
    fi
}

show_preview(){
    echo -e "${GREEN}===========================================${NC}"
    echo -e "${GREEN}        Установка Талисмана SQL            ${NC}"
    echo -e "${GREEN}Логирование:                               ${NC}"
    echo -e "${GREEN}$LOG_FILE ${NC}"
    echo -e "${GREEN}===========================================${NC}"
}

#===============================================================================
# Подтверждение действия пользователем
#===============================================================================
confirm() {
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

#===============================================================================
# Функция обнаружения и выбора шары
#===============================================================================

discover_and_select_share() {
    info "Подключение к серверу."
    local TARGET_SHARES=("out" "pochta" "talisman_sql" "talismansql" "strah")
    local ALL_DISK_SHARES=()
    
    SHARES=()  # Сброс результата при новом вызове

    # --- Ввод сервера ---
    read -p "Введите IP или имя сервера: " SERVER
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
        
        echo "$_prompt"
        for i in "${!_list[@]}"; do
            echo "   [$i] ${_list[$i]}"
        done
        echo "   [q] Выход"
        
        while true; do
            read -p "   Ваш выбор: " _choice
            _choice="${_choice,,}"
            
            if [[ "$_choice" == "q" ]]; then
                echo "Выбор отменён пользователем."
                return 1
            fi
            
            if [[ "$_choice" =~ ^[0-9]+$ ]] && (( _choice >= 0 && _choice < ${#_list[@]} )); then
                _SELECTED_ITEM="${_list[$_choice]}"  # Возврат через глобальную переменную
                echo "Выбрано: $_SELECTED_ITEM"
                return 0
            else
                echo "   Введите номер от 0 до $((${#_list[@]}-1)) или 'q' для выхода."
            fi
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
    _SELECTED_ITEM=""
    if _select_share_from_list ALL_DISK_SHARES "📋 Все доступные дисковые шары — выберите вручную:"; then
        SHARES=("$_SELECTED_ITEM")  # Записываем выбранный путь в массив
        return 0
    else
        return 1
    fi
}

mount_talsql(){
    # Константы
    local CRED_FILE="/root/.cifstalsql"      # Единый путь для credentials
    local BASE_MOUNT="/mnt/talsql"         # Базовая директория для всех шар
    local FSTAB_OPTS="noauto,x-systemd.automount,_netdev,rw,credentials=$CRED_FILE,soft,file_mode=0777,dir_mode=0777,nofail"
    
    # Запускаем обнаружение и выбор шар
    if ! discover_and_select_share; then
        echo "Операция прервана."
        return 1
    fi
    
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
        echo "guest" > "$CRED_FILE"
        chmod 600 "$CRED_FILE"
    fi
    
    # Бэкап fstab перед добавление шар
    backup "/etc/fstab"

    # --- Монтирование КАЖДОЙ шары из массива ---
    for share_unc in "${SHARES[@]}"; do
        # Извлекаем имя шары из UNC: //192.168.205.4/strah → strah
        local share_name="${share_unc##*/}"
        local mount_point="$BASE_MOUNT/$share_name"
        
        echo ""
        echo "Обработка: $share_unc → $mount_point"
        
        # 1. Создаём точку монтирования
        mkdir -p "$mount_point"
        
        # 2. Добавляем запись в /etc/fstab (если ещё нет)
        if ! grep -q "^$share_unc[[:space:]]*$mount_point" /etc/fstab 2>/dev/null; then
            echo "$share_unc $mount_point cifs $FSTAB_OPTS 0 0" | tee -a /etc/fstab >/dev/null
            echo "   $mount_point Добавлено в /etc/fstab"
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
        
        # Конвертируем путь в имя юнита: /mnt/talsql/strah → mnt-talsql-strah
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
    echo "Тест автомонта:   ls /mnt/talsql/out  # должно подмонтировать автоматически"
    return 0
}

create_unc_links() {
    confirm "Создать ссылки c шарами для Wine?"
    # 1. Если SERVER не задан, запрашиваем интерактивно
    if [[ -z "$SERVER" ]]; then
        read -rp "Введите IP или имя сервера для UNC-путей: " SERVER
        [[ -z "$SERVER" ]] && { error "Сервер не указан."; return 1; }
    fi

    local unc_dir="~/.talsql/dosdevices/unc/$SERVER"
    local mount_base="/mnt/talsql"

    # 2. Проверка, что шары действительно смонтированы
    if [[ ! -d "$mount_base" || -z "$(ls -A "$mount_base" 2>/dev/null)" ]]; then
        warn "Директория $mount_base пуста или не найдена. Шары не смонтированы?"
        return 1
    fi

    # 3. Создаём структуру UNC
    urun "mkdir -p $unc_dir" || { error "Ошибка создания $unc_dir"; return 1; }

    info "Создание UNC-ссылок для //$SERVER..."

    local count=0
    # Проходим по всем папкам в точке монтирования
    for share_path in "$mount_base"/*/; do
        [[ -d "$share_path" ]] || continue  # Пропуск, если glob не сработал

        # Извлекаем чистое имя шары (убираем / и путь)
        local share_name="${share_path%/}"
        share_name="${share_name##*/}"

        # Создаём/обновляем симлинк (-f перезапишет старую ссылку)
        # printf %q сам добавит нужные кавычки и экранирование
        local safe_path safe_dest
        safe_path=$(printf '%q' "$share_path")
        safe_dest=$(printf '%q' "$share_name")
        if urun "ln -sf $safe_path $unc_dir/$safe_dest"; then
            info "   $share_name -> $unc_dir/$share_name"
            ((count++))
        else
            error "   Ошибка создания ссылки для $share_name"
        fi
    done

    if [[ $count -eq 0 ]]; then
        warn "В $mount_base не найдено доступных папок."
        return 1
    fi

    success "Готово. Создано ссылок: $count"
    success "Теперь в Wine доступны пути: \\\\$SERVER\\<имя_шары>"
    return 0
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

    # Формируем базовую команду с правильной передачей окружения
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
        urun "$base_cmd $pkg" || { confirm "Продолжить?" || return 1; }
    done

    return 0
}

main() {
    show_preview
    check_root
    clear
    show_preview
    check install_wine
    check create-prefix
    check install-components
    check mount_talsql
    check create_unc_links
}

main "$@"
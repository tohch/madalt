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
# Глобальные константы для autofs
#===============================================================================
AUTOFUS_MASTER="/etc/auto.master"
AUTOFUS_MAP_DIR="/etc/auto.d"
AUTOFUS_MAP_FILE=""
CRED_FILE_DIR="/etc/samba/credentials"
BASE_MOUNT_ROOT="/mnt"  # Корневая точка для autofs

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
        
        local flags=""
        [[ "$AUTO_YES" == "true" ]] && flags="-y"
        
        local escaped_args=()
        for arg in "$@"; do
            escaped_args+=("$(printf '%q' "$arg")")
        done
        
        exec su root -c "ORIG_USER='$ORIG_USER' AUTO_YES='$AUTO_YES' bash \"$(realpath "$0")\" $flags ${escaped_args[*]}"
    fi
}

# Защита от дурака
check_user(){
    if [[ "$(id -u)" -eq 0 && -z $ORIG_USER ]]; then
        error "Скрипт нельзя запускать от имени root!"
        info "Выйдите из root: exit"
        info "И перезапустите скрипт под пользователем, скрипт сам запросит повышение прав."
        exit 1
    fi
}

show_preview(){
    echo -e "${GREEN}===========================================${NC}"
    echo -e "${GREEN}        Установка Талисмана SQL            ${NC}"
    echo -e "${GREEN}Этапы установки:                           ${NC}"
    echo -e "${GREEN}- Установка Wine                           ${NC}"
    echo -e "${GREEN}- Настройка сетевых папок (autofs)         ${NC}"
    echo -e "${GREEN}- Установка Талисмана SQL                  ${NC}"
    echo -e "${GREEN}- Копирование из out в TalSQL              ${NC}"
    echo -e "${GREEN}- Копирование библиотек в system32         ${NC}"
    echo -e "${GREEN}- Установка Designfr                       ${NC}"
    echo -e "${GREEN}- Установка BDE для импорта питания        ${NC}"
    echo -e "${GREEN}Логирование:                               ${NC}"
    echo -e "${GREEN}$LOG_FILE ${NC}"
    echo -e "${GREEN}Архив конфигов autofs: /root/backup_t      ${NC}"
    echo -e "${GREEN}Отвечать Да на все вопросы:                ${NC}"
    echo -e "${GREEN}./install_talsql.sh -y                     ${NC}"
    echo -e "${GREEN}===========================================${NC}"
}

show_success(){
    echo -e "${GREEN}===========================================${NC}"
    echo -e "${GREEN}Поздравляю!                                ${NC}"
    echo -e "${GREEN}Талисман SQL успешно установлен!           ${NC}"
    echo -e "${GREEN}===========================================${NC}"
}

#===============================================================================
# Подтверждение действия пользователем
#===============================================================================
confirm() {
    if [[ "$AUTO_YES" == "true" ]]; then
        return 0
    fi

    local prompt="$1"
    local response
    
    while true; do
        echo -e "${YELLOW}$prompt${NC} [Y/n]: "
        read -r response
        
        if [[ -z "$response" ]] || [[ "$response" =~ ^[YyNn]$ ]]; then
            if [[ -z "$response" ]] || [[ "$response" =~ ^[Yy]$ ]]; then
                return 0
            else
                return 1
            fi
        else
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

        "$func" "$@" 2>&1
        local status=${PIPESTATUS[0]}

        if [[ $status -eq 0 ]]; then
            if (( attempt == 1 )); then
                success "Шаг '$func' выполнен успешно"
            else
                success "Шаг '$func' выполнен успешно со $attempt-й попытки"
            fi
            return 0
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
    if [[ -z "$ORIG_USER" ]]; then
        read -rp "Введите имя пользователя для запуска: " ORIG_USER
        [[ -z "$ORIG_USER" ]] && { error "Имя пользователя не указано"; return 1; }
        if ! id "$ORIG_USER" &>/dev/null; then
            error "Пользователь '$ORIG_USER' не существует в системе"
            return 1
        fi
    fi

    local cmd="$*"
    
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
    local backup_dir="${2:-/root/backup_t}"
    
    [[ -z "$file" ]] && { echo "Не указан файл для бэкапа." >&2; return 1; }
    [[ ! -f "$file" ]] && { echo "Файл '$file' не существует." >&2; return 1; }
    [[ ! -r "$file" ]] && { echo "Нет прав на чтение '$file'." >&2; return 1; }

    local filename="${file##*/}"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local dest="$backup_dir/${filename}.${timestamp}"

    mkdir -p "$backup_dir" 2>/dev/null || { error "Не удалось создать $backup_dir" >&2; return 1; }

    if cp -p "$file" "$dest" 2>/dev/null; then
        info "Бэкап создан: $dest" >&2
        return 0
    else
        error "Бэкап '$file' не создан." >&2
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
        
        [[ "$choice" == "q" ]] && { echo "   Отменено."; return 1; }
        
        choice="${choice// /}"
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
                echo "   Номер $part вне диапазона."
                valid=false; break
            fi
            local dup=false
            for r in "${to_remove[@]}"; do [[ "$r" == "$part" ]] && { dup=true; break; }; done
            $dup || to_remove+=("$part")
        done
        
        $valid || continue
        [[ ${#to_remove[@]} -eq 0 ]] && { echo "   Введите номер или 'q'."; continue; }
        
        local -a new_shares=()
        for i in "${!SHARES[@]}"; do
            local skip=false
            for idx in "${to_remove[@]}"; do
                (( i == idx )) && { skip=true; break; }
            done
            $skip || new_shares+=("${SHARES[$i]}")
        done
        
        echo "   Будет удалено:"
        for idx in "${to_remove[@]}"; do
            echo "      • ${SHARES[$idx]}"
        done
        
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
    
    SHARES=()

    read -p "Введите IP или имя сервера (Например: 192.168.1.100): " SERVER
    [[ -z "$SERVER" ]] && { warn "Сервер не указан."; return 1; }

    if ! command -v smbclient &>/dev/null; then
        warn "Требуется пакет samba-client."
        info "   Установите: sudo apt-get install samba-client"
        return 1
    fi

    info "Сканирование шар на $SERVER..."

    local AUTH="-N"
    local RAW
    RAW=$(smbclient -L "//$SERVER" $AUTH -g 2>/dev/null)
    local auth_status=$?
    local user_anon="false"

    if [[ $auth_status -eq 0 && -n "$RAW" ]]; then
        user_anon="true"
        success "Выполнено анонимное подключение к серверу"
        confirm "Хотите оставить анонимного пользователя для подключения?" || user_anon="false"
    fi

    if [[ "$user_anon" == "false" && ( $auth_status -ne 0 || -z "$RAW" ) ]]; then
        local max_attempts=3
        local attempt=0
        local auth_success=false
        
        while (( attempt < max_attempts )) && ! $auth_success; do
            ((attempt++))
            
            if (( attempt > 1 )); then
                echo ""
                warn "Попытка #$attempt/$max_attempts"
            fi
            
            echo -e "${BLUE}=================================================${NC}"
            echo "Введите учётные данные для подключения к серверу:"
            read -p "   Логин (Enter для пропуска): " USER
            
            if [[ -z "$USER" ]]; then
                info "   Пропущено. Возвращаемся к предыдущему шагу."
                break
            fi
            
            read -sp "   Пароль: " PASS; echo
            
            AUTH="-U $USER%$PASS"
            RAW=$(smbclient -L "//$SERVER" $AUTH -g 2>&1)
            auth_status=$?
            
            if [[ $auth_status -eq 0 && -n "$RAW" ]] && \
            ! echo "$RAW" | grep -qiE "NT_STATUS_LOGON_FAILURE|access denied|permission denied"; then
                auth_success=true
                success "   Аутентификация успешна"
            else
                if echo "$RAW" | grep -qiE "NT_STATUS_LOGON_FAILURE|access denied"; then
                    error "   Неверный логин или пароль"
                elif echo "$RAW" | grep -qiE "NT_STATUS_ACCOUNT_LOCKED"; then
                    error "   Учётная запись заблокирована"
                elif echo "$RAW" | grep -qiE "NT_STATUS_ACCOUNT_DISABLED"; then
                    error "   Учётная запись отключена"
                else
                    warn "   Ошибка подключения (код: $auth_status)."
                fi
                
                if (( attempt < max_attempts )); then
                    if ! confirm "   Попробовать ещё раз?"; then
                        info "   Ввод отменён пользователем"
                        break
                    fi
                else
                    error "   Превышено максимальное количество попыток ($max_attempts)"
                fi
            fi
        done
        
        if ! $auth_success; then
            warn "   Не удалось подключиться с учётными данными."
            unset PASS
            return 1
        fi
    fi

    [[ -z "$RAW" ]] && { echo "Не удалось получить список шар."; return 1; }

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

    _select_share_from_list() {
        local -n _list=$1
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
            _choice="${choice,,}"
            
            if [[ "$_choice" == "q" ]]; then
                info "Выбор отменён пользователем."
                return 0
            fi
            
            if [[ "$_choice" == "d" ]]; then
                _remove_from_shares
                continue
            fi

            _choice="${_choice// /}"
            IFS=',' read -ra _parts <<< "$_choice"
            _selected=()
            local _valid=true
            
            for part in "${_parts[@]}"; do
                [[ -z "$part" ]] && continue
                [[ "$part" == "d" ]] && continue

                if ! [[ "$part" =~ ^[0-9]+$ ]]; then
                    warn "   '$part' — некорректный номер."
                    _valid=false; break
                fi
                
                if (( part < 0 || part >= ${#_list[@]} )); then
                    warn "   Номер $part вне диапазона."
                    _valid=false; break
                fi
                
                local is_dup=false
                for already in "${_selected[@]}"; do
                    [[ "$already" == "$part" ]] && { is_dup=true; break; }
                done
                if $is_dup; then
                    warn "   Номер $part уже выбран."
                    continue
                fi
                
                _selected+=("$part")
            done

            $valid || continue
            [[ ${#_selected[@]} -eq 0 ]] && { info "   Введите хотя бы один номер или 'q'."; continue; }

            for idx in "${_selected[@]}"; do
                local item="${_list[$idx]}"
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

    if [[ ${#SHARES[@]} -gt 0 ]]; then
        echo "Найдено ${#SHARES[@]} целевых шар:"
        for i in "${SHARES[@]}"; do echo "${i}"; done
        ! confirm "Подтвердить выбор?" || return 0
    fi

    if [[ ${#ALL_DISK_SHARES[@]} -eq 0 ]]; then
        echo "На сервере не найдено ни одной дисковой шары."
        return 1
    fi

    echo "Целевые шары (${TARGET_SHARES[*]}) не найдены."

    if _select_share_from_list ALL_DISK_SHARES "Все доступные дисковые шары — выберите вручную через запятую:"; then
        return 0
    else
        return 1
    fi
}

#===============================================================================
# === AUTOFUS-СПЕЦИФИЧНЫЕ ФУНКЦИИ ===
#===============================================================================

check_autofs_installed() {
    if ! rpm -q autofs &>/dev/null; then
        warn "autofs не установлен."
        info "Установка: apt-get install autofs"
        if confirm "Установить autofs?"; then
            if apt-get update && apt-get install -y autofs; then
                success "autofs установлен"
                return 0
            else
                error "Не удалось установить autofs"
                return 1
            fi
        else
            return 1
        fi
    fi
    return 0
}

setup_credentials_file() {
    local server_clean="${SERVER//[^a-zA-Z0-9._-]/_}"
    CRED_FILE="$CRED_FILE_DIR/autofs_talsql_${server_clean}.creds"
    
    mkdir -p "$CRED_FILE_DIR"
    
    if [[ -n "$USER" && -n "$PASS" ]]; then
        cat > "$CRED_FILE" <<EOF
username=$USER
password=$PASS
domain=
EOF
    else
        cat > "$CRED_FILE" <<EOF
username=guest
password=
guest
EOF
    fi
    chmod 600 "$CRED_FILE"
    info "Файл учётных данных: $CRED_FILE"
}

generate_map_filename() {
    local server_clean="${SERVER//[^a-zA-Z0-9._-]/_}"
    echo "/etc/auto.d/auto.talsql_${server_clean}"
}

escape_for_autofs() {
    local str="$1"
    echo "\"$str\""
}

add_to_auto_master() {
    local mount_point="$1"
    local map_file="$2"
    
    if grep -qE "^[[:space:]]*${mount_point}[[:space:]]+" "$AUTOFUS_MASTER" 2>/dev/null; then
        info "Запись для $mount_point уже есть в $AUTOFUS_MASTER"
        return 0
    fi
    
    echo "$mount_point $map_file --ghost,--timeout=60" >> "$AUTOFUS_MASTER"
    info "Добавлено в $AUTOFUS_MASTER: $mount_point -> $map_file"
}

create_autofs_map() {
    local map_file="$1"
    local mount_base="$2"
    
    mkdir -p "$(dirname "$map_file")"
    [[ -f "$map_file" ]] && backup "$map_file"
    
    if [[ ! -f "$map_file" ]]; then
        cat > "$map_file" <<EOF
# Autofs map для SMB-шар Талисман SQL: $SERVER
# Сгенерировано: $(date '+%Y-%m-%d %H:%M:%S')
# ----------------------------------------------------------------
EOF
        chmod 644 "$map_file"
    fi
    
    local autofs_opts="rw,credentials=$CRED_FILE,soft,file_mode=0777,dir_mode=0777"
    local added_count=0 skipped_count=0 updated_count=0
    
    for share_unc in "${SHARES[@]}"; do
        local share_name="${share_unc##*/}"
        local share_name_escaped=$(escape_for_autofs "$share_name")
        local share_unc_escaped=$(escape_for_autofs "$share_unc")
        
        local search_pattern="^${share_name_escaped}[[:space:]]"
        
        if grep -qE "$search_pattern" "$map_file" 2>/dev/null; then
            local existing_line=$(grep -E "$search_pattern" "$map_file" | head -n1)
            local new_line="${share_name_escaped} -fstype=cifs,$autofs_opts :$share_unc_escaped"
            
            if [[ "$existing_line" == "$new_line" ]]; then
                info "   [SKIP] $share_name: запись уже существует"
                ((skipped_count++))
            else
                info "   [UPDATE] $share_name: обновляем параметры"
                local escaped_new_line=$(printf '%s\n' "$new_line" | sed 's/[&/\]/\\&/g')
                sed -i -E "s|^${share_name_escaped}[[:space:]].*|${escaped_new_line}|" "$map_file"
                ((updated_count++))
            fi
        else
            echo "${share_name_escaped} -fstype=cifs,$autofs_opts :$share_unc_escaped" >> "$map_file"
            info "   [ADD] $share_name -> $share_unc"
            ((added_count++))
        fi
    done
    
    if (( added_count > 0 || updated_count > 0 )); then
        chmod 644 "$map_file"
        success "Map-файл обновлён: +$added_count, ~$updated_count, =$skipped_count"
    else
        info "Map-файл не изменён"
    fi
}

reload_autofs() {
    info "Перезагрузка службы autofs..."
    
    if command -v systemctl &>/dev/null; then
        systemctl enable autofs 2>/dev/null
        systemctl start autofs 2>/dev/nul
        if systemctl reload autofs 2>/dev/null || systemctl restart autofs 2>/dev/null; then
            success "autofs перезапущен через systemctl"
            return 0
        fi
    fi
    
    if command -v service &>/dev/null; then
        if service autofs reload 2>/dev/null || service autofs restart 2>/dev/null; then
            success "autofs перезапущен через service"
            return 0
        fi
    fi
    
    if pgrep -x automount >/dev/null; then
        pkill -HUP automount && success "autofs получил SIGHUP" && return 0
    fi
    
    warn "Не удалось перезагрузить autofs"
    return 1
}

test_autofs_mount() {
    local mount_point="$1"
    
    info "Тестирование autofs: $mount_point..."
    mkdir -p "$mount_point"
    
    if ls "$mount_point" &>/dev/null; then
        sleep 2
        if mountpoint -q "$mount_point" 2>/dev/null || ls "$mount_point"/* &>/dev/null; then
            success "autofs работает: $mount_point доступен"
            return 0
        fi
    fi
    
    warn "autofs не смонтировал $mount_point"
    return 1
}

#===============================================================================
# Основная функция монтирования через autofs
#===============================================================================
mount_talsql(){
    confirm "Подключится к серверу Талисмана SQL?" || return 0
    
    if ! discover_and_select_share; then
        echo "Операция прервана."
        return 1
    fi
    
    echo "Готово. Выбрано шар:"
    for s in "${SHARES[@]}"; do echo "   • $s"; done
    
    check check_autofs_installed || return 1
    setup_credentials_file
    
    local server_clean="${SERVER//[^a-zA-Z0-9._-]/_}"
    local mount_base="$BASE_MOUNT_ROOT/$server_clean"
    AUTOFUS_MAP_FILE=$(generate_map_filename)
    
    backup "$AUTOFUS_MASTER"
    [[ -f "$AUTOFUS_MAP_FILE" ]] && backup "$AUTOFUS_MAP_FILE"
    
    add_to_auto_master "$mount_base" "$AUTOFUS_MAP_FILE"
    create_autofs_map "$AUTOFUS_MAP_FILE" "$mount_base"
    reload_autofs
    test_autofs_mount "$mount_base"
    
    echo ""
    success "Настройка autofs завершена."
    echo "Проверка:   ls $mount_base  # должно смонтировать по запросу"
    echo "Статус:     systemctl status autofs"
    echo "Map-файл:   $AUTOFUS_MAP_FILE"
    return 0
}

#===============================================================================
# Создание UNC-ссылок для Wine (обновлено для autofs)
#===============================================================================
create_unc_links() {
    if [[ "$AUTO_YES" != "true" ]]; then
        confirm "Создать ссылки с шарами для Wine?" || return 0
    fi

    if [[ -z "$SERVER" ]]; then
        read -rp "Введите IP или имя сервера для UNC-путей: " SERVER
        [[ -z "$SERVER" ]] && { error "Сервер не указан."; return 1; }
    fi

    local server_clean="${SERVER//[^a-zA-Z0-9._-]/_}"
    local unc_dir="${WINEPREFIX#WINEPREFIX=}/dosdevices/unc/$SERVER"
    local mount_base="$BASE_MOUNT_ROOT/$server_clean"

    if [[ ! -d "$mount_base" ]]; then
        warn "Директория $mount_base не найдена. Пробуем активировать autofs..."
        ls "$mount_base" &>/dev/null
        sleep 2
        [[ ! -d "$mount_base" ]] && { error "Не удалось получить доступ к $mount_base"; return 1; }
    fi

    if [[ ! -d "$unc_dir" ]]; then
        urun "mkdir -p $(printf '%q' "$unc_dir")" || { error "Ошибка создания $unc_dir"; return 1; }
    fi

    info "Создание UNC-ссылок для //$SERVER..."

    local count=0 skipped=0
    
    for share_unc in "${SHARES[@]}"; do
        local share_n="${share_unc##*/}"
        local share_path="$mount_base/$share_n"
        
        [[ -d "$share_path" ]] || { 
            ls "$mount_base" &>/dev/null
            sleep 1
            [[ -d "$share_path" ]] || continue
        }

        local share_name="${share_path%/}"
        share_name="${share_name##*/}"
        local link_path="$unc_dir/$share_name"
        
        if [[ -L "$link_path" ]]; then
            local current_target=$(readlink "$link_path")
            if [[ "${current_target%/}" == "${share_path%/}" ]]; then
                info "   [SKIP] $share_name: ссылка уже существует"
                ((skipped++))
                continue
            else
                warn "   [UPDATE] $share_name: обновляем ссылку..."
                urun "rm -f $(printf '%q' "$link_path")"
            fi
        elif [[ -e "$link_path" ]]; then
            error "   [CONFLICT] $link_path существует, но не является ссылкой."
            ((skipped++))
            continue
        fi

        local cmd="ln -sf $(printf '%q' "$share_path") $(printf '%q' "$unc_dir/$share_name")"
        if urun "$cmd"; then
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
# Вспомогательная функция: поиск папки "out"
#===============================================================================
find_out_directory() {
    local base_path="$1"
    local -a candidates=()
    
    local known_patterns=("out" "Out" "OUT" "Talisman_sql/out" "Talismansql/out" "talisman_sql/out" "Talisman_SQL/out" "talismansql/out")
    for pattern in "${known_patterns[@]}"; do
        if [[ -d "$base_path/$pattern" && -n "$(ls -A "$base_path/$pattern" 2>/dev/null)" ]]; then
            echo "$base_path/$pattern"
            return 0
        fi
    done
    
    while IFS= read -r -d '' dir; do
        if [[ -n "$(ls -A "$dir" 2>/dev/null)" ]]; then
            candidates+=("$dir")
        fi
    done < <(find "$base_path" -mindepth 2 -maxdepth 2 -type d -name "out" -print0 2>/dev/null)
    
    if [[ ${#candidates[@]} -eq 0 ]]; then
        return 1
    elif [[ ${#candidates[@]} -eq 1 ]]; then
        echo "${candidates[0]}"
        return 0
    else
        echo "${candidates[0]}"
        return 0
    fi
}

#===============================================================================
# Функции установки (без изменений)
#===============================================================================
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
    for pkg in win2k8 glsl=disabled ddr=gdi dotnet452 msxml3 msxml6 msftedit corefonts tahoma \
               riched20 riched30 vb6run gdiplus vcrun2005 vcrun2008 vcrun2010 \
               vcrun2012 vcrun2013 win2k8; do
        echo "Установка: $pkg"
        local max_retries=3 attempt=0 success=false
        while [ $attempt -le $max_retries ]; do
            if urun "$base_cmd $pkg"; then
                success=true
                break
            fi
            attempt=$((attempt + 1))
            if [ $attempt -gt $max_retries ]; then
                echo "[!] Превышен лимит попыток ($max_retries) для $pkg."
                break
            fi
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
    confirm "Проверить наличие установочного файла Талисмана SQL?" || return 0
    local script_dir; script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    local installertalsql="Reinstall_Tal3.1.52.exe"
    local installer_path="$script_dir/$installertalsql"
    
    if [[ -f "$installer_path" ]]; then
        success "$installer_path существует."
    else
        warn "$installer_path не найден!"
        local safe_workpath=$(printf '%q' "$script_dir")
        confirm "Скачать $installertalsql?" || return 1
        apt-get install -y python3-module-pip || { error "Ошибка pip"; return 1; }
        urun "pip3 install ydiskarc && python3 -c 'import ydiskarc'" || { error "Ошибка ydiskarc"; return 1; }
        urun "pip3 install tqdm && python3 -c 'import tqdm'" || { error "Ошибка tqdm"; return 1; }
        urun "~/.local/bin/ydiskarc sync https://disk.yandex.ru/d/V02lQpBYE3Wzog -o $safe_workpath" || { error "Ошибка скачивания"; return 1; }
        [[ ! -f "$installer_path" ]] && { error "Не удалось скачать!"; return 1; }
        success "Файл успешно скачан."
    fi
    return 0
}

check_designfr(){
    confirm "Проверить наличие установочного файла Designfr" || return 0
    local script_dir; script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    local installertalsql="designfr.exe"
    local installer_path="$script_dir/$installertalsql"
    
    if [[ -f "$installer_path" ]]; then
        success "$installer_path существует."
    else
        warn "$installer_path не найден!"
        local safe_workpath=$(printf '%q' "$script_dir")
        confirm "Скачать $installertalsql?" || return 1
        apt-get install -y python3-module-pip || return 1
        urun "pip3 install ydiskarc && python3 -c 'import ydiskarc'" || return 1
        urun "pip3 install tqdm && python3 -c 'import tqdm'" || return 1
        urun "~/.local/bin/ydiskarc sync https://disk.yandex.ru/d/V02lQpBYE3Wzog -o $safe_workpath" || return 1
        [[ ! -f "$installer_path" ]] && { error "Не удалось скачать!"; return 1; }
        success "Файл успешно скачан."
    fi
    return 0
}

check_bde(){
    confirm "Проверить наличие установочного файла BDE" || return 0
    local script_dir; script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    local installertalsql="bdex64.exe"
    local installer_path="$script_dir/$installertalsql"
    
    if [[ -f "$installer_path" ]]; then
        success "$installer_path существует."
    else
        warn "$installer_path не найден!"
        local safe_workpath=$(printf '%q' "$script_dir")
        confirm "Скачать $installertalsql?" || return 1
        apt-get install -y python3-module-pip || return 1
        urun "pip3 install ydiskarc && python3 -c 'import ydiskarc'" || return 1
        urun "pip3 install tqdm && python3 -c 'import tqdm'" || return 1
        urun "~/.local/bin/ydiskarc sync https://disk.yandex.ru/d/V02lQpBYE3Wzog -o $safe_workpath" || return 1
        [[ ! -f "$installer_path" ]] && { error "Не удалось скачать!"; return 1; }
        success "Файл успешно скачан."
    fi
    return 0
}

copy_talsql_files(){
    confirm "Скопировать файлы Талисмана SQL?" || return 0
    local wine_prefix="${WINEPREFIX//WINEPREFIX=/}"
    local tal_dir="$wine_prefix/drive_c/Talisman_SQL/ACenter/TalSQL"
    local src_dir=$(find_out_directory "/mnt/${SERVER//[^a-zA-Z0-9._-]/_}")
    local system32="$wine_prefix/drive_c/windows/system32"
    local dlls=("midas.dll" "gds32.dll" "fbclient.dll")

    [[ ! -d "$src_dir" ]] && { error "Источник не найден: $src_dir"; return 1; }

    if [[ ! -d "$tal_dir" ]]; then
        error "Целевая директория не найдена: $tal_dir"
        if confirm "Создать директорию $tal_dir?"; then
            urun "mkdir -p $(printf '%q' "$tal_dir")" || { error "Не удалось создать $tal_dir"; return 1; }
            success "Директория создана: $tal_dir"
        else
            warn "Пропуск копирования"
            return 0
        fi
    fi

    info "Копирование: $src_dir → $tal_dir"
    urun "yes | cp -rf '$src_dir'/* '$tal_dir/'" && success "Файлы скопированы" || error "Ошибка копирования"

    info "Копирование DLL в $system32"
    local dll_errors=0
    for dll in "${dlls[@]}"; do
        local src="$src_dir/$dll" dst="$system32/$dll"
        if [[ -f "$src" ]]; then
            urun "yes | cp -fv '$src' '$dst'" && success "   $dll → $system32" || { error "   Не удалось скопировать $dll"; ((dll_errors++)); }
        else
            warn "   Файл $dll не найден в $src_dir"
        fi
    done

    [[ $dll_errors -eq ${#dlls[@]} ]] && { error "Не скопирован ни один DLL"; return 1; }
    [[ $dll_errors -gt 0 ]] && warn "Часть DLL не скопирована ($dll_errors из ${#dlls[@]})"
    success "Копирование завершено."
    return 0
}

install-talsql(){
    info "Во время установки укажите папку C:\Talisman_SQL"
    confirm "Запустить установку Талисмана SQL?" || return 0
    local script_dir; script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    local safe_workpath=$(printf '%q' "$script_dir")
    local base_cmd="$WINEPREFIX wine $safe_workpath/Reinstall_Tal3.1.52.exe"
    urun "$base_cmd" || return 1
}

install_designfr(){
    confirm "Запустить установку Designfr?" || return 0
    local script_dir; script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    local safe_workpath=$(printf '%q' "$script_dir")
    local base_cmd="$WINEPREFIX wine $safe_workpath/designfr.exe"
    urun "$base_cmd" || return 1
}

install_bde(){
    confirm "Запустить установку BDE?" || return 0
    local script_dir; script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    local safe_workpath=$(printf '%q' "$script_dir")
    local base_cmd="$WINEPREFIX wine $safe_workpath/bdex64.exe"
    urun "$base_cmd" || return 1
}

create_desktop_shortcut(){
    confirm "Проверить наличие ярлыка?" || return 0
    local desktop_dir=""
    [[ -d "/home/$ORIG_USER/Рабочий стол" ]] && desktop_dir="/home/$ORIG_USER/Рабочий стол"
    [[ -d "/home/$ORIG_USER/Desktop" ]] && desktop_dir="/home/$ORIG_USER/Desktop"
    
    local shortcut_path="$desktop_dir/ТалSQL.desktop"
    [[ -f "$shortcut_path" ]] && { touch "$shortcut_path"; info "Ярлык уже существует"; return 0; }
    confirm "Создать ярлык ТалSQL на рабочем столе?" || return 0
    
    info "Создаю ярлык: $shortcut_path"
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

    if [[ -f "$shortcut_path" ]]; then
        touch "$shortcut_path"
        success "Ярлык создан: $shortcut_path"
        urun "chmod +x '$shortcut_path'" && info "Ярлык сделан исполняемым"
        [[ -n "$ORIG_USER" && "$(id -u)" -eq 0 ]] && chown "$ORIG_USER:$ORIG_USER" "$shortcut_path" 2>/dev/null && info "Владелец изменён на $ORIG_USER"
    else
        error "Не удалось создать ярлык"
        return 1
    fi
    [[ "$AUTO_YES" != "true" ]] && echo "" && info "Совет: если ярлык не запускается, кликните ПКМ → Свойства → Разрешения → Разрешить выполнение"
    return 0
}

#===============================================================================
# Удаление настройки autofs (дополнительная функция)
#===============================================================================
cleanup_autofs() {
    if [[ -z "$SERVER" ]]; then
        read -rp "Введите сервер для удаления настройки autofs: " SERVER
        [[ -z "$SERVER" ]] && return 1
    fi
    
    local server_clean="${SERVER//[^a-zA-Z0-9._-]/_}"
    local mount_base="$BASE_MOUNT_ROOT/$server_clean"
    local map_file=$(generate_map_filename)
    
    info "Удаление настройки autofs для $SERVER..."
    
    if [[ -f "$AUTOFUS_MASTER" ]]; then
        backup "$AUTOFUS_MASTER"
        sed -i "\|^[[:space:]]*${mount_base}[[:space:]]|d" "$AUTOFUS_MASTER"
        info "Удалено из $AUTOFUS_MASTER"
    fi
    
    if [[ -f "$map_file" ]]; then
        backup "$map_file"
        rm -f "$map_file"
        info "Удалён map-файл: $map_file"
    fi
    
    if [[ -f "$CRED_FILE" ]]; then
        backup "$CRED_FILE"
        rm -f "$CRED_FILE"
        info "Удалён файл учётных данных"
    fi
    
    reload_autofs
    success "Настройка autofs для $SERVER удалена"
}

#===============================================================================
# MAIN
#===============================================================================
main() {
    local HAS_ERRORS=0
    check_user
    show_preview
    check_root
    clear
    show_preview

    check install_wine       || HAS_ERRORS=1
    check create-prefix      || HAS_ERRORS=1
    check install-components || HAS_ERRORS=1
    check mount_talsql       || HAS_ERRORS=1
    check create_unc_links   || HAS_ERRORS=1
    check check-talsql       || HAS_ERRORS=1
    check install-talsql     || HAS_ERRORS=1
    check copy_talsql_files  || HAS_ERRORS=1
    check check_designfr     || HAS_ERRORS=1
    check install_designfr   || HAS_ERRORS=1
    check check_bde          || HAS_ERRORS=1
    check install_bde        || HAS_ERRORS=1
    create_desktop_shortcut  || HAS_ERRORS=1
    
    if [[ $HAS_ERRORS -eq 0 ]]; then
        show_success
    else
        warn "Установка завершена с ошибками. Проверьте лог: $LOG_FILE"
    fi
    
    echo ""
    info "Полезные команды:"
    echo "  • Проверка autofs:    systemctl status autofs"
    echo "  • Просмотр mount:     mount | grep $SERVER"
    echo "  • Тест доступа:       ls $BASE_MOUNT_ROOT/"
    echo "  • Логи:               journalctl -u autofs -f"
    echo "  • Map-файл:           cat $AUTOFUS_MAP_FILE"
}

main "$@"
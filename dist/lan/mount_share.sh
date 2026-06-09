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
SMB_VERSION=""
while getopts "yhv:" opt; do
    case $opt in
        y) AUTO_YES=true ;;
        v) SMB_VERSION="$OPTARG" ;;
        h)  echo "-y - автоответ Да на вопросы"
            echo "-v: - выбор версии smb (-v 1 - SMB1, -v 2 - SMB2, -v 3 - SMB3)"
            echo "-h - подсказка"
            echo "Пример использования скрипта:"
            echo "chmod +x mount_share.sh"
            echo "./mount_share.sh -y -v 3"
            exit 0;;
        \?) echo "Недопустимая опция: -$OPTARG" >&2; exit 1 ;;
        :)  echo "Опция -$OPTARG требует аргумент 1,2 или 3" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

# === Валидация SMB_VERSION ===
case "$SMB_VERSION" in
    1|2|3|"") ;;  # OK
    *)
        echo "Ошибка: -v принимает только 1, 2 или 3 (получено: '$SMB_VERSION')" >&2
        exit 1
        ;;
esac

SHARES=()
UNC_DIRS=()
USER="" PASS=""
SERVER=""
SMB=""

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
LOG_FILE="/var/log/mount_share_autofs_$(date +%Y%m%d_%H%M%S).log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

info()  { echo -e "${BLUE}[INFO]${NC} $1"; log "INFO: $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; log "WARN: $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; log "ERROR: $1"; }
success(){ echo -e "${GREEN}[OK]${NC} $1"; log "OK: $1"; }

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
# Проверка прав доступа
#===============================================================================
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
        
        exec su root -c "ORIG_USER='$ORIG_USER' AUTO_YES='$AUTO_YES' SMB_VERSION='$SMB_VERSION' bash -- \"$(realpath "$0")\" $flags ${escaped_args[*]}"
    fi
}

show_preview(){
    echo -e "${GREEN}===========================================${NC}"
    echo -e "${GREEN}   Монтирование сетевых папок (autofs)    ${NC}"
    echo -e "${GREEN}Этапы работы скрипта:                      ${NC}"
    echo -e "${GREEN}- поиск сервера по IP или сетевому имени;  ${NC}"
    echo -e "${GREEN}- выбор сетевых папок;                     ${NC}"
    echo -e "${GREEN}- настройка autofs (auto.master + map);    ${NC}"
    echo -e "${GREEN}- подключение по запросу через autofs;     ${NC}"
    echo -e "${GREEN}- создания ярлыков.                        ${NC}"
    echo -e "${GREEN}Логирование:                               ${NC}"
    echo -e "${GREEN}$LOG_FILE ${NC}"
    echo -e "${GREEN}Архив конфигов: /root/backup_t             ${NC}"
    echo -e "${GREEN}Атрибуты: -h помощь;                       ${NC}"
    echo -e "${GREEN}-v 1, 2 или 3 версии smb                   ${NC}"
    echo -e "${GREEN}-y автосогласие на вопросы.                ${NC}"
    echo -e "${GREEN}Пример: ./mount_share.sh -y -v 3    ${NC}"
    echo -e "${GREEN}===========================================${NC}"
}

#===============================================================================
# Backup файлов конфигурации
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

#===============================================================================
# Попытки выполнить команду
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
# Удаление элементов из массива SHARES
#===============================================================================
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
# Обнаружение и выбор шар
#===============================================================================
discover_and_select_share() {
    info "Подключение к серверу."
    local ALL_DISK_SHARES=()
    local smbv=()

    if [[ "$SMB_VERSION" == "1" ]]; then
        SMB="vers=1.0,"
        smbv=(--option='client min protocol=NT1' --option='client max protocol=NT1')
    elif [[ "$SMB_VERSION" == "2" ]]; then
        SMB="vers=2.0,"
        smbv=(--option='client min protocol=SMB2_02' --option='client max protocol=SMB2_10')
    elif [[ "$SMB_VERSION" == "3" ]]; then
        SMB="vers=3.0,"
        smbv=(--option='client min protocol=SMB3' --option='client max protocol=SMB3_11')
    else
        SMB=""
        smbv=()
    fi

    SHARES=()

    read -p "Введите IP или имя сервера: " SERVER
    [[ -z "$SERVER" ]] && { warn "Сервер не указан."; return 1; }

    if ! command -v smbclient &>/dev/null; then
        warn "Требуется пакет samba-client."
        info "   Установите: sudo apt-get install samba-client"
        return 1
    fi

    info "Сканирование шар на $SERVER..."

    local AUTH="-N"
    local RAW
    RAW=$(smbclient -L "//$SERVER" $AUTH -g "${smbv[@]}" 2>/dev/null)
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
            RAW=$(smbclient -L "//$SERVER" $AUTH -g "${smbv[@]}" 2>&1)
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
            _choice="${_choice,,}"
            
            if [[ "$_choice" == "q" ]]; then
                info "Выбор отменён пользователем."
                return 1
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

    if _select_share_from_list ALL_DISK_SHARES "Все доступные дисковые шары — выберите вручную через запятую:"; then
        return 0
    else
        return 1
    fi
}

#===============================================================================
# === AUTOFUS-СПЕЦИФИЧНЫЕ ФУНКЦИИ ===
#===============================================================================

# Проверка и установка autofs
check_autofs_installed() {
    if ! rpm -q autofs; then
        warn "autofs не установлен или не активен."
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

# Создание/обновление файла credentials
setup_credentials_file() {
    local server_clean="${SERVER//[^a-zA-Z0-9._-]/_}"
    CRED_FILE="$CRED_FILE_DIR/autofs_${server_clean}.creds"
    
    mkdir -p "$CRED_FILE_DIR"
    
    if [[ -n "$USER" && -n "$PASS" ]]; then
        cat > "$CRED_FILE" <<EOF
username=$USER
password=$PASS
domain=
EOF
    else
        # Для анонимного доступа
        cat > "$CRED_FILE" <<EOF
username=guest
password=
guest
EOF
    fi
    chmod 600 "$CRED_FILE"
    info "Файл учётных данных: $CRED_FILE"
}

# Генерация имени map-файла для сервера
generate_map_filename() {
    local server_clean="${SERVER//[^a-zA-Z0-9._-]/_}"
    echo "/etc/auto.d/auto.${server_clean}"
}

# Экранирование строки для autofs map (пробелы -> \040)
escape_for_autofs() {
    local str="$1"
    echo "\"$str\""
}

# Добавление записи в auto.master
add_to_auto_master() {
    local mount_point="$1"
    local map_file="$2"
    
    # Проверяем, есть ли уже запись для этой точки монтирования
    if grep -qE "^[[:space:]]*${mount_point}[[:space:]]+" "$AUTOFUS_MASTER" 2>/dev/null; then
        info "Запись для $mount_point уже есть в $AUTOFUS_MASTER"
        return 0
    fi
    
    # Добавляем новую запись
    # Формат: /mnt/server_name -fstype=autofs,--ghost,--timeout=60 /etc/auto.d/auto.server
    echo "$mount_point $map_file --ghost,--timeout=60" >> "$AUTOFUS_MASTER"
    info "Добавлено в $AUTOFUS_MASTER: $mount_point -> $map_file"
}

#===============================================================================
# Создание/обновление map-файла для сервера (с проверкой дубликатов)
#===============================================================================
create_autofs_map() {
    local map_file="$1"
    local mount_base="$2"
    
    mkdir -p "$(dirname "$map_file")"
    
    # Бэкап существующего файла перед модификацией
    [[ -f "$map_file" ]] && backup "$map_file"
    
    # Если файл не существует — создаём с заголовком
    if [[ ! -f "$map_file" ]]; then
        cat > "$map_file" <<EOF
# Autofs map для SMB-шар сервера: $SERVER
# Сгенерировано: $(date '+%Y-%m-%d %H:%M:%S')
# Формат: share_name -fstype=cifs,опции ://сервер/шара
# ----------------------------------------------------------------
EOF
        chmod 644 "$map_file"
    fi
    
    # Формируем опции монтирования для autofs
    local autofs_opts="${SMB}rw,credentials=$CRED_FILE,soft,file_mode=0777,dir_mode=0777"
    
    local added_count=0
    local skipped_count=0
    local updated_count=0
    
    # Добавляем каждую шару в map-файл
    for share_unc in "${SHARES[@]}"; do
        local share_name="${share_unc##*/}"
        # Экранируем имена с пробелами
        local share_name_escaped=$(escape_for_autofs "$share_name")
        local share_unc_escaped=$(escape_for_autofs "$share_unc")
        
        # Формируем строку для поиска (начало строки: имя_шары + пробел или табуляция)
        local search_pattern="^${share_name_escaped}[[:space:]]"
        
        # Проверяем, есть ли уже запись для этой шары
        if grep -qE "$search_pattern" "$map_file" 2>/dev/null; then
            # Запись найдена — проверяем, совпадают ли опции
            local existing_line
            existing_line=$(grep -E "$search_pattern" "$map_file" | head -n1)
            local new_line="${share_name_escaped} -fstype=cifs,$autofs_opts :$share_unc_escaped"
            
            if [[ "$existing_line" == "$new_line" ]]; then
                info "   [SKIP] $share_name: запись уже существует и актуальна"
                ((skipped_count++))
            else
                # Запись есть, но опции отличаются — обновляем
                info "   [UPDATE] $share_name: обновляем параметры монтирования"
                # Используем sed для замены строки (экранируем спецсимволы)
                local escaped_new_line
                escaped_new_line=$(printf '%s\n' "$new_line" | sed 's/[&/\]/\\&/g')
                sed -i -E "s|^${share_name_escaped}[[:space:]].*|${escaped_new_line}|" "$map_file"
                ((updated_count++))
            fi
        else
            # Записи нет — добавляем новую
            echo "${share_name_escaped} -fstype=cifs,$autofs_opts :$share_unc_escaped" >> "$map_file"
            info "   [ADD] $share_name -> $share_unc"
            ((added_count++))
        fi
    done
    
    # Если файл был изменён — устанавливаем права и логируем
    if (( added_count > 0 || updated_count > 0 )); then
        chmod 644 "$map_file"
        success "Map-файл обновлён: +$added_count добавлено, ~$updated_count обновлено, =$skipped_count без изменений"
    else
        info "Map-файл не изменён: все записи уже актуальны"
    fi
    
    success "Обработка map-файла завершена: $map_file"
}

# Перезагрузка autofs
reload_autofs() {
    info "Перезагрузка службы autofs..."
    
    # Для ALT Linux используем service или systemctl
    if command -v systemctl &>/dev/null; then
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
    
    # Fallback: попытка послать SIGHUP демоному
    if pgrep -x automount >/dev/null; then
        pkill -HUP automount && success "autofs получил SIGHUP" && return 0
    fi
    
    warn "Не удалось перезагрузить autofs стандартными методами"
    return 1
}

# Проверка работы autofs
test_autofs_mount() {
    local mount_point="$1"
    
    info "Тестирование autofs: обращение к $mount_point..."
    
    # Создаём точку, если нет
    mkdir -p "$mount_point"
    
    # Обращение к директории должно триггерить autofs
    if ls "$mount_point" &>/dev/null; then
        sleep 2  # Даём время на монтирование
        if mountpoint -q "$mount_point" 2>/dev/null || ls "$mount_point"/* &>/dev/null; then
            success "autofs работает: $mount_point доступен"
            return 0
        fi
    fi
    
    warn "autofs не смонтировал $mount_point автоматически"
    return 1
}

#===============================================================================
# Основная функция монтирования через autofs
#===============================================================================
mount_share(){
    if ! discover_and_select_share; then
        echo "Операция прервана."
        return 1
    fi
    
    echo "Готово. Выбрано шар:"
    for s in "${SHARES[@]}"; do
        echo "   • $s"
    done
    
    # 1. Проверяем autofs
    check check_autofs_installed || return 1
    
    # 2. Настраиваем credentials
    setup_credentials_file
    
    # 3. Формируем пути
    local server_clean="${SERVER//[^a-zA-Z0-9._-]/_}"
    local mount_base="$BASE_MOUNT_ROOT/$server_clean"
    AUTOFUS_MAP_FILE=$(generate_map_filename)
    
    # 4. Бэкап конфигов
    backup "$AUTOFUS_MASTER"
    [[ -f "$AUTOFUS_MAP_FILE" ]] && backup "$AUTOFUS_MAP_FILE"
    
    # 5. Добавляем запись в auto.master
    add_to_auto_master "$mount_base" "$AUTOFUS_MAP_FILE"
    
    # 6. Создаём/обновляем map-файл
    create_autofs_map "$AUTOFUS_MAP_FILE" "$mount_base"
    
    # 7. Перезагружаем autofs
    reload_autofs
    
    # 8. Тестируем монтирование
    test_autofs_mount "$mount_base"
    
    echo ""
    success "Настройка autofs завершена."
    echo "Проверка:   ls $mount_base  # должно смонтировать по запросу"
    echo "Статус:     systemctl status autofs"
    echo "Логи:       tail -f /var/log/messages | grep automount"
    echo "Map-файл:   $AUTOFUS_MAP_FILE"
    return 0
}

#===============================================================================
# Создание ярлыков (без изменений, работает с уже смонтированными шарами)
#===============================================================================
create_unc_links() {
    confirm "Создать ярлыки сетевых папок для быстрого доступа?" || return 0

    if [[ -z "$SERVER" ]]; then
        read -rp "Введите IP или имя сервера для UNC-путей: " SERVER
        [[ -z "$SERVER" ]] && { error "Сервер не указан."; return 1; }
    fi

    if [[ -z "$ORIG_USER" ]]; then
        read -rp "Введите имя пользователя для запуска: " ORIG_USER
        [[ -z "$ORIG_USER" ]] && { error "Имя пользователя не указано"; return 1; }
        if ! id "$ORIG_USER" &>/dev/null; then
            error "Пользователь '$ORIG_USER' не существует в системе"
            return 1
        fi
    fi

    local unc_dir=""
    local server_clean="${SERVER//[^a-zA-Z0-9._-]/_}"
    local mount_base="$BASE_MOUNT_ROOT/$server_clean"

    info "Если нажмете ${YELLOW}n${NC} будет предложено ввести путь для ярлыков"
    if confirm "Создать ярлыки на рабочем столе?"; then 
        unc_dir="/home/$ORIG_USER/Рабочий стол"
    else
        read -p "Введите путь для создания ссылок: " unc_dir
    fi

    if [[ ! -d "$mount_base" ]]; then
        warn "Директория $mount_base не найдена. Попробуйте: ls $mount_base"
        return 1
    fi

    if [[ ! -d "$unc_dir" ]]; then
        urun "mkdir -p $(printf '%q' "$unc_dir")" || { error "Ошибка создания $unc_dir"; return 1; }
    fi

    info "Создание ссылок для //$SERVER..."

    local count=0
    local skipped=0
    
    for share_unc in "${SHARES[@]}"; do
        local share_n="${share_unc##*/}"
        local share_path="$mount_base/$share_n"
        
        [[ -d "$share_path" ]] || { 
            # Пробуем "разбудить" autofs обращением к родительской директории
            ls "$mount_base" &>/dev/null
            sleep 1
            [[ -d "$share_path" ]] || continue
        }

        local share_name="${share_path%/}"
        share_name="${share_name##*/}"
        local link_path="$unc_dir/$share_name"
        
        if [[ -L "$link_path" ]]; then
            local current_target=$(readlink "$link_path")
            current_target="${current_target%/}"
            local expected_path="${share_path%/}"

            if [[ "$current_target" == "$expected_path" ]]; then
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
        UNC_DIRS+=("$unc_dir/$share_name")

        if urun "$cmd"; then
            success "$share_name -> $share_path"
            ((count++))
        else
            error "Ошибка создания ссылки для $share_name"
        fi
    done

    if [[ $count -eq 0 && $skipped -eq 0 ]]; then
        warn "В $mount_base не найдено доступных папок."
        return 1
    fi

    success "Готово. Создано: $count, пропущено: $skipped"
    return 0
}

show_shares(){
    for share in "${SHARES[@]}"; do
        echo "${share}"
    done
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
    
    # Удаляем из auto.master
    if [[ -f "$AUTOFUS_MASTER" ]]; then
        backup "$AUTOFUS_MASTER"
        sed -i "\|^[[:space:]]*${mount_base}[[:space:]]|d" "$AUTOFUS_MASTER"
        info "Удалено из $AUTOFUS_MASTER"
    fi
    
    # Удаляем map-файл
    if [[ -f "$map_file" ]]; then
        backup "$map_file"
        rm -f "$map_file"
        info "Удалён map-файл: $map_file"
    fi
    
    # Удаляем credentials
    if [[ -f "$CRED_FILE" ]]; then
        backup "$CRED_FILE"
        rm -f "$CRED_FILE"
        info "Удалён файл учётных данных"
    fi
    
    # Перезагружаем autofs
    reload_autofs
    
    success "Настройка autofs для $SERVER удалена"
}

#===============================================================================
# MAIN
#===============================================================================
main() {
    local HAS_ERRORS=0
    show_preview
    check_root
    clear
    show_preview
    
    while true; do
        check mount_share || HAS_ERRORS=1
        check create_unc_links || HAS_ERRORS=1

        if confirm "Выйти?"; then
            show_shares
            
            if [[ $HAS_ERRORS -eq 0 ]]; then
                success "Шары успешно настроены через autofs!"
            else
                warn "Есть ошибки. Проверьте лог: $LOG_FILE"
            fi
            
            echo ""
            info "Полезные команды:"
            echo "  • Проверка autofs:    systemctl status autofs"
            echo "  • Просмотр mount:     mount | grep $SERVER"
            echo "  • Тест доступа:       ls $BASE_MOUNT_ROOT/"
            echo "  • Логи:               journalctl -u autofs -f"
            echo "  • Map-файл:           cat $AUTOFUS_MAP_FILE"

            unset PASS
            exit 0
        else
            UNC_DIRS=()
            SHARES=()
            SERVER=""
            unset PASS
            continue
        fi
    done
}

main "$@"
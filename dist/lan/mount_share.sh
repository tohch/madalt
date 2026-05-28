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
"{$SMB_VERSION:=}"
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
# Функции логирования и вывода
#===============================================================================
LOG_FILE="/var/log/mount_share_$(date +%Y%m%d_%H%M%S).log"

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
# Проверка прав доступа
#===============================================================================
# Без сбросом окружения
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
        exec su root -c "ORIG_USER='$ORIG_USER' AUTO_YES='$AUTO_YES' SMB_VERSION='$SMB_VERSION' bash -- \"$(realpath "$0")\" $flags ${escaped_args[*]}"
    fi
}

show_preview(){
    echo -e "${GREEN}===========================================${NC}"
    echo -e "${GREEN}        Монтирование сетевых папок         ${NC}"
    echo -e "${GREEN}Этапы работы скрипта:                      ${NC}"
    echo -e "${GREEN}- поиск сервера по IP или сетевому имени;  ${NC}"
    echo -e "${GREEN}- выбор сетевых папок;                     ${NC}"
    echo -e "${GREEN}- запись подключения в fstab;              ${NC}"
    echo -e "${GREEN}- подключение по запросу через cifs;       ${NC}"
    echo -e "${GREEN}- создания ярлыков.                        ${NC}"
    echo -e "${GREEN}Логирование:                               ${NC}"
    echo -e "${GREEN}$LOG_FILE ${NC}"
    echo -e "${GREEN}Архив fstab: /root/backup_t                ${NC}"
    echo -e "${GREEN}Атрибуты: -h помощь;                       ${NC}"
    echo -e "${GREEN}-v 1, 2 или 3 версии smb                   ${NC}"
    echo -e "${GREEN}-y автосогласие на вопросы.                ${NC}"
    echo -e "${GREEN}Пример для smb1: ./mount_share -y -v 1     ${NC}"
    echo -e "${GREEN}Без -v ставится smb по умолчанию (smb3)    ${NC}"
    echo -e "${GREEN}===========================================${NC}"
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

discover_and_select_share() {
    info "Подключение к серверу."
    local ALL_DISK_SHARES=()
    local smbv=()

    # === Определение параметров SMB с обходом ограничений клиента ===
    if [[ "$SMB_VERSION" == "1" ]]; then
        SMB="vers=1.0,"
        # Обходим защиту: явно разрешаем NT1 через опции клиента
        smbv=(
            --option='client min protocol=NT1'
            --option='client max protocol=NT1'
        )
    elif [[ "$SMB_VERSION" == "2" ]]; then
        SMB="vers=2.0,"
        smbv=(
            --option='client min protocol=SMB2_02'
            --option='client max protocol=SMB2_10'
        )
    elif [[ "$SMB_VERSION" == "3" ]]; then
        SMB="vers=3.0,"
        smbv=(
            --option='client min protocol=SMB3'
            --option='client max protocol=SMB3_11'
        )
    else
        # Авто-согласование (по умолчанию клиент сам выберет)
        SMB=""
        smbv=()
    fi

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
    RAW=$(smbclient -L "//$SERVER" $AUTH -g "${smbv[@]}" 2>/dev/null)
    local auth_status=$?
    local user_anon="false"

    if [[ $auth_status -eq 0 && -n "$RAW" ]]; then
        user_anon="true"
        success "Выполнено анонимное подключение к серверу"
        confirm "Хотите оставить анонимного пользователя для подключения?" || user_anon="false"
    fi
    # === Если анонимно не вышло — запрашиваем учётку с повторами ===
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
            
            # Если пользователь нажал Enter без логина — выходим из цикла
            if [[ -z "$USER" ]]; then
                info "   Пропущено. Возвращаемся к предыдущему шагу."
                break
            fi
            
            read -sp "   Пароль: " PASS; echo
            
            # Формируем аргументы авторизации
            AUTH="-U $USER%$PASS"
            
            # Пытаемся подключиться с учёткой
            RAW=$(smbclient -L "//$SERVER" $AUTH -g "${smbv[@]}" 2>&1)
            auth_status=$?
            
            # === Проверка результата ===
            # 1. Код возврата 0 И есть данные = успех
            # 2. Если в выводе есть "NT_STATUS_LOGON_FAILURE" или "access denied" = неверный пароль
            if [[ $auth_status -eq 0 && -n "$RAW" ]] && \
            ! echo "$RAW" | grep -qiE "NT_STATUS_LOGON_FAILURE|access denied|permission denied"; then
                auth_success=true
                success "   Аутентификация успешна"
            else
                # Определяем тип ошибки для понятного сообщения
                if echo "$RAW" | grep -qiE "NT_STATUS_LOGON_FAILURE|access denied"; then
                    error "   Неверный логин или пароль"
                elif echo "$RAW" | grep -qiE "NT_STATUS_ACCOUNT_LOCKED"; then
                    error "   Учётная запись заблокирована"
                elif echo "$RAW" | grep -qiE "NT_STATUS_ACCOUNT_DISABLED"; then
                    error "   Учётная запись отключена"
                else
                    warn "   Ошибка подключения (код: $auth_status). Проверьте данные или доступность сервера."
                fi
                
                # Если это не последняя попытка — спрашиваем, повторять ли
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
        
        # Если после всех попыток авторизация не удалась
        if ! $auth_success; then
            warn "   Не удалось подключиться с учётными данными. Попробуйте проверить доступность сервера."
            # Очищаем чувствительные данные
            unset PASS
            return 1
        fi
    fi

    [[ -z "$RAW" ]] && { echo "Не удалось получить список шар."; return 1; }

    # --- Парсинг вывода: собираем ВСЕ дисковые шары и отдельно ЦЕЛЕВЫЕ ---
    while IFS='|' read -r type name _; do
        [[ "$type" != "Disk" ]] && continue
        [[ -z "$name" ]] && continue
        
        ALL_DISK_SHARES+=("//$SERVER/$name")
        
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

    if _select_share_from_list ALL_DISK_SHARES "Все доступные дисковые шары — выберите вручную через запятую (Например: 1,2,3):"; then
        return 0
    else
        return 1
    fi
}

mount_share(){
    # Константы
    local CRED_FILE="/root/.cifs${SERVER}"      # Единый путь для credentials

    # Запускаем обнаружение и выбор шар
    if ! discover_and_select_share; then
        echo "Операция прервана."
        return 1
    fi
    
    local FSTAB_OPTS="${SMB}noauto,x-systemd.automount,_netdev,rw,credentials=$CRED_FILE,soft,file_mode=0777,dir_mode=0777,nofail"
    
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
    success "Все шары обработаны."
    echo "Проверка:   mount | grep $SERVER"
    echo "Статус юнитов:   systemctl list-units | grep $SERVER"
    echo "Тест автомонта:   ls /mnt/$SERVER  # должно подмонтировать автоматически"
    return 0
}

create_unc_links() {
    confirm "Создать ярлыки сетевых папок для быстрого доступа?" || return 0

    # 1. Если SERVER не задан, запрашиваем интерактивно
    if [[ -z "$SERVER" ]]; then
        read -rp "Введите IP или имя сервера для UNC-путей (Например: 192.168.1.100): " SERVER
        [[ -z "$SERVER" ]] && { error "Сервер не указан."; return 1; }
    fi

    # Раскрываем ~ в пути, чтобы не создавать ссылки в /root/
    local unc_dir=""
    local mount_base="/mnt/$SERVER"

    info "Если нажмете ${YELLOW}n${NC} будет предложено ввести путь для ярлыков"
    if confirm "Создать ярлыки на рабочем столе?"; then 
        unc_dir="/home/$ORIG_USER/Рабочий стол"
    else
        read -p "Введите путь для создания ссылок: " unc_dir
    fi

    # 2. Проверка, что шары действительно смонтированы
    if [[ ! -d "$mount_base" || -z "$(ls -A "$mount_base" 2>/dev/null)" ]]; then
        warn "Директория $mount_base пуста или не найдена. Шары не смонтированы?"
        return 1
    fi

    # 3. Создаём структуру UNC (проверяем существование перед созданием)
    if [[ ! -d "$unc_dir" ]]; then
        urun "mkdir -p $(printf '%q' "$unc_dir")" || { error "Ошибка создания $unc_dir"; return 1; }
    fi

    info "Создание ссылок для //$SERVER..."

    local count=0
    local skipped=0
    
    # Проходим по всем папкам в точке монтирования
    for share_f in "${SHARES[@]}"; do
        local share_n="${share_f##*/}"
        local share_path="$mount_base/$share_n"
        echo "$share_path"
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
            current_target="${current_target%/}"
            local expected_path="${share_path%/}"

            # Сравниваем с желаемым путём (нормализуем для сравнения)
            if [[ "$current_target" == "$expected_path" ]]; then
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

main() {
    local HAS_ERRORS=0
    show_preview
    check_root
    clear
    show_preview
    while true; do
        check mount_share || $HAS_ERRORS=1
        check create_unc_links || $HAS_ERRORS=1

        if confirm "Выйти?"; then
            show_shares
            
            if [[ $HAS_ERRORS -eq 0 ]]; then
                success "Шары успешно подключены!"
            else
                warn "Есть ошибки в подключении. Проверьте лог: $LOG_FILE"
            fi

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
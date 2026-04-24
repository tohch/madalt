#!/bin/bash
#===============================================================================
# Скрипт обновления ALT Linux СП 10 до версии 10.2
# Предназначен для рабочей станции на базе ALT SP 10
# Запускать от имени root или через sudo
#===============================================================================

#===============================================================================
# Проверка прав доступа
#===============================================================================
check_root() {
    if [ "$(id -u)" -ne 0 ]; then      
        echo "[!] Требуются права root. Введите пароль:"
        exec su - root -c "bash \"$(realpath "$0")\" \"$@\""
    fi
}

set -o pipefail
LOG_FILE="/var/log/altsp_upgrade_$(date +%Y%m%d_%H%M%S).log"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#===============================================================================
# Глобальные переменные (заполняются в init)
#===============================================================================
CURRENT_KERNEL=""
AVAILABLE_KERNEL=""
CURRENT_MM=""
AVAILABLE_MM=""
CURRENT_VERSION=""
AVAILABLE_VERSION=""

#===============================================================================
# Функции логирования и вывода
#===============================================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

info()  { echo -e "${BLUE}[INFO]${NC} $1"; log "INFO: $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; log "WARN: $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; log "ERROR: $1"; }
success(){ echo -e "${GREEN}[OK]${NC} $1"; log "OK: $1"; }

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
# Инициализация данных
#===============================================================================
init() {
    info "Инициализация данных..."
    CURRENT_KERNEL=$(uname -r)
    
    local available_list
    available_list=$(update-kernel -l 2>/dev/null) || true
    
    AVAILABLE_VERSION=$(echo "$available_list" | grep -oE '[0-9]+\.[0-9]+[-._a-zA-Z0-9]*' | head -n 1)
    AVAILABLE_KERNEL=$(echo "$available_list" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    CURRENT_MM=$(echo "$CURRENT_KERNEL" | grep -oE '^[0-9]+\.[0-9]+')
    AVAILABLE_MM=$(echo "$AVAILABLE_KERNEL" | grep -oE '^[0-9]+\.[0-9]+')
    CURRENT_VERSION=$(echo "$CURRENT_KERNEL" | grep -oE '[0-9]+\.[0-9]+[-._a-zA-Z0-9]*' | head -n 1)    


    if [[ -z "$AVAILABLE_VERSION" ]]; then
        warn "Не удалось получить список доступных ядер."
    else
	    local current_version_branch=$(rpm --eval='%_priority_distbranch' 2>/dev/null)
		info "Текущая версия ядра: $CURRENT_MM"
		info "Текущая ветка репозитория: $current_version_branch"
        info "Доступная версия ядра в репозитории: $AVAILABLE_MM"
    fi
}

#===============================================================================
# Закомментировать строку в файле, если она ещё не закомментирована
# Аргументы: $1 - путь к файлу, $2 - строка для поиска (без # в начале)
#===============================================================================
comment_line_if_active() {
    local file="$1"
    local search_pattern="$2"
	local backup_dir="/root/backup_t"
    
	mkdir -p "$backup_dir"
	
	local filename="${file##*/}"
    local backup="${backup_dir}/${filename}.bak.$(date +%Y%m%d_%H%M%S)"
	
    # Проверка существования файла
    if [[ ! -f "$file" ]]; then
        warn "Файл не найден: $file"
        return 1
    fi
    
    # Проверка: уже закомментирована или отсутствует?
    if grep -q "^[[:space:]]*#[[:space:]]*${search_pattern}" "$file" 2>/dev/null; then
        info "Уже закомментировано: $search_pattern в $file"
        return 0
    fi
    
    # Проверка: есть ли активная строка?
    if ! grep -q "^[[:space:]]*${search_pattern}" "$file" 2>/dev/null; then
        info "Строка не найдена (или уже изменена): $search_pattern в $file"
        return 0
    fi
    
    # Создаём бэкап
    if ! cp -p "$file" "$backup" 2>/dev/null; then
        error "Не удалось создать бэкап: $backup"
        return 1
    fi
    info "Бэкап $file создан: $backup"
    
    # Комментируем ТОЛЬКО незакомментированные строки (начинающиеся не с #)
    # Используем расширенный regex для точного совпадения начала строки
    if sed -i -E "s|^([[:space:]]*)(${search_pattern})|\1# \2|" "$file" 2>/dev/null; then
        success "Закомментировано: $search_pattern в $file"
        return 0
    else
        error "Ошибка при редактировании $file"
        # Восстанавливаем бэкап при ошибке
        mv -f "$backup" "$file" 2>/dev/null
        return 1
    fi
}

#===============================================================================
# Отключение CDROM-репозиториев и монтирований
#===============================================================================
disable_cdrom_sources() {
    if confirm "Отключить диск с установщиком Альт?"; then
        info "Отключение CDROM-источников..."
        
		local backup_dir="/root/backup_t"
		local name_bakup_fstab="fstab.bak.$(date +%Y%m%d_%H%M%S)"
        # 1. /etc/fstab — строка с /dev/sr0
        if grep -q '^[^#].*/media/ALTLinux' /etc/fstab 2>/dev/null; then
		    mkdir -p "$backup_dir"
            cp -p /etc/fstab "$backup_dir/$name_bakup_fstab" || warn "Бэкап fstab не создан"
			info "Бэкап /etc/fstab создан: $backup_dir/$name_bakup_fstab"
            sed -i '/\/media\/ALTLinux/s/^/# /' /etc/fstab
            success "CDROM в /etc/fstab закомментирован"
        else
            info "CDROM в /etc/fstab уже отключён или отсутствует"
        fi
    
        # 2. /etc/apt/sources.list.d/sources.list — rpm cdrom:...
        comment_line_if_active \
            "/etc/apt/sources.list.d/sources.list" \
            "rpm cdrom:\\[ALT SP Workstation 11100-01 x86_64 build 2023-05-28\\]/ ALTLinux main"
    
        # Обновляем индексы, если меняли sources.list
        if [[ -f "/etc/apt/sources.list.d/sources.list" ]]; then
            apt-get update >> "$LOG_FILE" 2>&1 && success "Индексы APT обновлены"
        fi
	else
	    info "Отменена отключения диска с установщиком Альт"
		return 1
    fi
	return 0
}

#================================================================================
# Функция перезагрузки
#================================================================================
reboot_system() {
    # Перезагрузка
    if confirm "Выполнить перезагрузку?"; then
        info "Система будет перезагружена."
        reboot
        exit 0
    fi
}

#===============================================================================
# Настройка репозиториев ALT SP 10 (c10f, HTTP)
#===============================================================================
setup_sp10_repositories() {
    init
	
    local repo_file="/etc/apt/sources.list.d/altsp.list"
    
    info "Настройка репозиториев ALT SP 10 (c10f, HTTP)..."
    
    # Резервная копия существующего файла
    if [[ -f "$repo_file" ]]; then
	    mkdir -p /root/backup_t/
        cp "$repo_file" "/root/backup_t/altsp.list.bak.$(date +%Y%m%d_%H%M%S)"
        info "Резервная копия сохранена: /root/backup_t/altsp.list.bak.*"
    fi
    
    # Записываем конфигурацию репозиториев
    cat > "$repo_file" << 'EOF'
# update.altsp.su (IVK, Moscow)

# ALT Certified 10
#rpm [cert8] ftp://update.altsp.su/pub/distributions/ALTLinux c10f/branch/x86_64 classic gostcrypto
#rpm [cert8] ftp://update.altsp.su/pub/distributions/ALTLinux c10f/branch/x86_64-i586 classic
#rpm [cert8] ftp://update.altsp.su/pub/distributions/ALTLinux c10f/branch/noarch classic

rpm [cert8] http://update.altsp.su/pub/distributions/ALTLinux c10f/branch/x86_64 classic gostcrypto
rpm [cert8] http://update.altsp.su/pub/distributions/ALTLinux c10f/branch/x86_64-i586 classic
rpm [cert8] http://update.altsp.su/pub/distributions/ALTLinux c10f/branch/noarch classic
EOF
    
    if [[ $? -eq 0 ]]; then
        success "Репозитории настроены: $repo_file"
        return 0
    else
        error "Не удалось записать конфигурацию репозиториев"
        return 1
    fi
}

#===============================================================================
# Обновление системы: apt-repo, update, dist-upgrade, clean
#===============================================================================
update_system_packages() {
    init
	
    info "Начало обновления системы..."
    
    # 1. Обновление списка репозиториев через apt-repo
    info "Выполнение apt-repo..."
    if ! apt-repo 2>&1 | tee -a "$LOG_FILE"; then
        warn "apt-repo завершился с предупреждениями (это может быть нормально)"
    fi
    
    # 2. Обновление индексов пакетов
    info "Выполнение apt-get update..."
    local max_retries=3
    local retry=0
    
    while [[ $retry -lt $max_retries ]]; do
        if apt-get update 2>&1 | tee -a "$LOG_FILE"; then
            success "Индексы пакетов обновлены"
            break
        else
            ((retry++))
            if [[ $retry -lt $max_retries ]]; then
                warn "Ошибка apt-get update. Повтор #$retry через 10 секунд..."
                sleep 10
            else
                error "Не удалось обновить индексы после $max_retries попыток"
                return 1
            fi
        fi
    done
    
    # 3. Полное обновление пакетов (dist-upgrade)
    info "Выполнение apt-get dist-upgrade..."
    if confirm "Выполнить полный апгрейд пакетов на c10f (apt-get dist-upgrade)?"; then
        if apt-get dist-upgrade -y 2>&1 | tee -a "$LOG_FILE"; then
            success "Обновление пакетов завершено"
        else
            error "Ошибка при выполнении apt-get dist-upgrade"
            return 1
        fi
    else
        warn "Обновление пакетов пропущено по запросу пользователя"
    fi
    
    # 4. Очистка кэша
    info "Очистка кэша APT..."
    apt-get clean 2>&1 | tee -a "$LOG_FILE"
    success "Кэш APT очищен"
    
    return 0
}

#===============================================================================
# Комбинированная функция: настройка репозиториев + обновление
#===============================================================================
setup_and_update_s10() {
    init
	
    if confirm "перейти на ветку c10f?"; then
        info "Запуск настройки репозиториев и обновления системы..."
    
        if ! setup_sp10_repositories; then
            error "Не удалось настроить репозитории. Прерывание."
            return 1
        fi
    
        if ! update_system_packages; then
            error "Ошибка при обновлении системы"
            return 1
        fi
    
        success "Настройка репозиториев и обновление системы завершены"
        return 0
	fi
	
	info "Пропуск перехода на c10f"
	return 0
}

#===============================================================================
# Проверка совпадения мажорной/минорной версии ядра
#===============================================================================
check_major_minor() {
    if [[ -z "$CURRENT_MM" || -z "$AVAILABLE_MM" ]]; then
        warn "Версии ядер не инициализированы. Проверка отменена."
        return 1
    fi
    
    info "Сравнение серий: текущая ($CURRENT_MM) → доступная ($AVAILABLE_MM)"
    
    if [[ "$CURRENT_MM" == "$AVAILABLE_MM" ]]; then
        success "Серия ядра совпадает"
        return 0
    else
        info "Серия ядра отличается (доступно обновление до $AVAILABLE_MM)"
        return 1
    fi
}

#===============================================================================
# Вывод информации о ядрах
#===============================================================================
show_versions_kernel() {
    info "Текущее ядро:   $CURRENT_KERNEL"
    [[ -n "$AVAILABLE_VERSION" ]] && info "Доступное ядро: $AVAILABLE_VERSION"
}

#===============================================================================
# Проверка необходимости действий при смене серии ядра
#===============================================================================
show_check_update_kernel() {
    # Используем уже готовую функцию проверки, чтобы не дублировать логику
    if check_major_minor; then
        success "==============================================================="
        success "  Обновление до ALT Linux СП 10.2 завершено!"
        success "  Рекомендуется проверить:"
        success "    • Версию системы: cat /etc/altlinux-release"
        success "    • Версию ядра: uname -r"
        success "    • Работу критических служб"
        success "==============================================================="
    else 
        warn "Обнаружена смена серии ядра ($CURRENT_MM → $AVAILABLE_MM)"
        warn "Обновление не выполнено (требуется ручное обновление ядра)"
    fi
    return 0
}

#===============================================================================
# Пост-обновление: очистка и фиксация состояния
#===============================================================================
post_update_cleanup() {
    info "Выполнение пост-обновления..."
    
    if command -v remove-old-kernels &> /dev/null; then
        if remove-old-kernels >> "$LOG_FILE" 2>&1; then
            success "Старые ядра удалены"
        else
            warn "Ошибка удаления старых ядер"
        fi
    fi
    
    apt-get clean >> "$LOG_FILE" 2>&1
    rm -f /etc/rpm/macros.d/priority_distbranch
    success "Временные файлы макросов удалены"
    
    info "Обновление индексов пакетов..."
    if apt-get update >> "$LOG_FILE" 2>&1; then
        success "Индексы пакетов обновлены"
    fi
    
    if command -v integalert &> /dev/null; then
        if confirm "Зафиксировать новое состояние системы для integalert?"; then		
            integalert fix 2>&1 | tee -a "$LOG_FILE"
            success "Состояние системы зафиксировано"
        fi
    fi
}

#===============================================================================
# Обработка VirtualBox
#===============================================================================
handle_virtualbox() {
    local vb_pkgs
    vb_pkgs=$(rpm -qa --queryformat '%{NAME}\n' | grep -i virtualbox) || true
    
    if [[ -n "$vb_pkgs" ]]; then
        info "Обнаружен VirtualBox: $(echo $vb_pkgs | tr '\n' ' ')"
        warn "Внимание: после смены серии ядра VirtualBox может перестать работать!"
        
        if confirm "Удалить VirtualBox и связанные пакеты?"; then
            info "Удаление пакетов..."
            if apt-get remove -y $vb_pkgs >> "$LOG_FILE" 2>&1; then
                success "VirtualBox удалён"
                echo -e "${YELLOW}Для установки новой версии: apt-get install virtualbox${NC}"
            else
                error "Ошибка удаления VirtualBox"
            fi
        fi
    fi
}


#===============================================================================
# Настройка репозиториев (ВСЕГДА HTTP)
#===============================================================================
setup_repositories() {
    local repo_file="/etc/apt/sources.list.d/altsp.list"
	
    info "Настройка репозиториев (протокол: HTTP)..."
    
    # Резервная копия исходного файла
    if [[ -f "$repo_file" ]]; then
		mkdir -p /root/backup_t/
        cp "$repo_file" "/root/backup_t/altsp.list.bak.$(date +%Y%m%d_%H%M%S)"
        info "Создана резервная копия: /root/backup_t/altsp.list.bak.*"
    fi
    
    # Формирование содержимого файла репозиториев (только HTTP)
    cat > "$repo_file" << 'EOF'
# update.altsp.su (IVK, Moscow)

# ALT Certified 10.2
#rpm [cert8] ftp://update.altsp.su/pub/distributions/ALTLinux c10f2/branch/x86_64 classic gostcrypto
#rpm [cert8] ftp://update.altsp.su/pub/distributions/ALTLinux c10f2/branch/x86_64-i586 classic
#rpm [cert8] ftp://update.altsp.su/pub/distributions/ALTLinux c10f2/branch/noarch classic

rpm [cert8] http://update.altsp.su/pub/distributions/ALTLinux c10f2/branch/x86_64 classic gostcrypto
rpm [cert8] http://update.altsp.su/pub/distributions/ALTLinux c10f2/branch/x86_64-i586 classic
rpm [cert8] http://update.altsp.su/pub/distributions/ALTLinux c10f2/branch/noarch classic
EOF
    
	if apt-get update 2>&1 | tee -a "$LOG_FILE"; then
        success "Индексы обновлены"             
    fi
	
    success "Репозитории настроены: $repo_file"
}

#===============================================================================
# Переключение на ветку 10.2 (c10f2)
#===============================================================================
switch_branch() {
    if confirm "Переключиться на ветку c10f2?"; then
	    
		setup_repositories
        
		local macro_file="/etc/rpm/macros.d/priority_distbranch"
    
        info "Переключение на ветку c10f2 (10.2)..."
    
        # Создание директории если не существует
        mkdir -p /etc/rpm/macros.d/
    
        # Запись приоритета ветки
        echo '%_priority_distbranch c10f2' > "$macro_file"
    
        # Проверка применения
        local current_branch=$(rpm --eval='%_priority_distbranch' 2>/dev/null)
        if [[ "$current_branch" == "c10f2" ]]; then
            success "Ветка успешно переключена на: $current_branch"
        else
            error "Не удалось переключить ветку! Текущее значение: $current_branch"
            return 1
        fi
	fi
}

#===============================================================================
# Обработка integalert / OSEC (с проверкой минорной версии через update-kernel -l)
#===============================================================================
handle_integalert() {
    init
	
    info "Проверка конфигурации integalert и доступных обновлений ядра..."

    # Миграция ТОЛЬКО при смене минорной серии
    if ! check_major_minor; then
		if confirm "Выполнить миграцию настроек старого сканера целостности (OSEC)?"; then
            warn "Выполняется миграция настроек старого сканера целостности (OSEC)..."

            local integalert_old
            integalert_old="/root/integalert_old"
            if ! mkdir -p "$integalert_old"; then
                error "Не удалось создать директорию бэкапа: $integalert_old"
                return 1
            fi

            local osec_files=(integalert integalert_fix alterator-pipe.conf run-osec pipe.conf)
            local moved_count=0
            
			for file in "${osec_files[@]}"; do
                if [[ -f "$integalert_old/$file" || -e "$integalert_old/$file" || -L "$integalert_old/$file" ]]; then
                    warn "Бэкап $integalert_old не пуст"
					warn "В нем уже находится $file"
					warn "Значит миграция (OSEC) уже выполнялась"
					warn "Отмена миграции"
					info "Если вы уверены в своих действиях, то выполните:"
					info "mv $integalert_old /root/integalert_old_2"
					info "И повторите попытку"
					return 1
                fi
            done
			
            for file in "${osec_files[@]}"; do
                if [[ -f "/etc/osec/$file" || -e "/etc/osec/$file" || -L "/etc/osec/$file" ]]; then
                    if mv "/etc/osec/$file" "$integalert_old/" 2>&1 | tee -a "$LOG_FILE"; then
                        moved_count=$((moved_count + 1))
                    else
                        warn "Не удалось переместить /etc/osec/$file"
                    fi
                fi
            done

            if [[ $moved_count -gt 0 ]]; then
            success "Перемещено файлов: $moved_count. Настройки сохранены в $integalert_old"
            else
                warn "Файлы конфигурации OSEC не найдены в /etc/osec"
            fi
        else
            info "Серия ядра не изменилась ($CURRENT_MM), миграция OSEC не требуется"
        fi
	else
        info "Миграция сканера целостности (OSEC) не требуется"
	fi
}

#===============================================================================
# Обновление системы
#===============================================================================
update_system() {
    if confirm "Выполнить апгрейд системы на c10f2 (apt-get update dist-upgrade)?"; then
        local max_retries=3
        local retry=0
    
        info "Начало обновления системы..."
    
        # Обновление индексов репозиториев apt-repo
    
        while [[ $retry -lt $max_retries ]]; do
            info "Попытка #$((retry+1)) обновления индексов..."
        
            if apt-get update 2>&1 | tee -a "$LOG_FILE"; then
                success "Индексы обновлены"
                break
            else
                ((retry++))
                if [[ $retry -lt $max_retries ]]; then
                    warn "Ошибка обновления. Повтор через 10 секунд..."
                    sleep 10
                else
                    error "Не удалось обновить индексы после $max_retries попыток"
                    return 1
                fi
            fi
        done
    
        apt-get dist-upgrade -y 2>&1 | tee -a "$LOG_FILE"
        success "Обновление пакетов завершено"
    
        # Очистка кэша
        apt-get clean
        info "Кэш APT очищен"
	else
	    info "Апгрейд системы c10f2 отменен"
	fi
}

#===============================================================================
# Проверка обновления ядра
#===============================================================================
check_update_kernel() {
    init
    info "Проверка версии ядра..."
    info "Доступная версия ядра: $AVAILABLE_KERNEL"
	
    local after_update_kernel
    after_update_kernel=$(
        update-kernel -l 2>/dev/null | 
        grep '\[default\]' | 
        grep -o 'kernel-image[^ ]*' | 
        awk -F'-' '{print $(NF-1)}'
    )
    local current_kernel
    current_kernel=$(echo "$after_update_kernel" | cut -d. -f1,2)
    info "Версия ядра по умолчание после update-kernel: $after_update_kernel"
    
    if [[ "$current_kernel" == "$AVAILABLE_MM" ]]; then
        success "Ядро $current_kernel успешно установлено в загрузчик по умолчанию"
        return 0
    else
		warn "Ядро не обновилось!"
	    return 1
	fi
}

#===============================================================================
# Обновление ядра через kernel-updat -t
#===============================================================================
update_kernel_t() {
    init
    warn "Запуск принудительного обновления: update-kernel -t $AVAILABLE_MM"
        
    if confirm "Обновить принудительно ядро до $AVAILABLE_MM?"; then
        if update-kernel -t "$AVAILABLE_MM" 2>&1 | tee -a "$LOG_FILE"; then
                success "Ядро серии $AVAILABLE_MM успешно установлено."
				reboot_system
        else
            error "Ошибка при установке ядра серии $AVAILABLE_MM"
            return 1
        fi
	fi
}

#===============================================================================
# Обновление ядра
#===============================================================================
update_kernel() {
    init
    info "Обновление ядра системы..."
	
	if ! check_major_minor; then
	
	    if confirm "Обновить ядро до $AVAILABLE_KERNEL?"; then
            update-kernel 2>&1 | tee -a "$LOG_FILE"
        
	        # Стандартное обновление ядра
            if [ $? -eq 0 ]; then
                success "Команда update-kernel выполнена"
            else
                warn "update-kernel завершился с предупреждениями"
            fi
	
	        if ! check_update_kernel; then
	    	    update_kernel_t
	        fi
			
	        info "После перезагрузки запустите скрипт заново и выберите пункт 2 для завершения."
            # Перезагрузка
            if confirm "Выполнить перезагрузку для применения обновлений ядра?"; then
                success "Система будет перезагружена. После входа в систему продолжите скрипт."
                reboot
                exit 0
            fi
	    fi
	else
	    info "Обновление не требуется"
	fi
}

show_label_check() {
    echo -e "${GREEN}===============================================================${NC}"
    echo -e "${GREEN}  Проверка и фиксация обновления ALT Linux СП 10 → 10.2${NC}"
    echo -e "${GREEN}  Логирование: $LOG_FILE${NC}"
    echo -e "${GREEN}===============================================================${NC}"
}

#===============================================================================
# Безопасный выход из скрипта (без рекурсии!)
#===============================================================================
try_exit() {
    success "Скрипт завершил работу."
    if confirm "Выйти из скрипта?"; then
        info "Выход..."
        exit 0
    else
        info "Скрипт завершил работу. Вы можете продолжить работу в терминале."
        exit 0
    fi
}

#===============================================================================
# ФУНКЦИЯ МЕНЮ
#===============================================================================
kernel_management_menu() {
    warn "Перед началом убедитесь, что:"
    echo "         • Выполнен бэкап важных данных"
    echo "         • Есть доступ к интернету"
    echo "         • Достаточно места на диске (/ и /boot)"
    echo "         • Система работает стабильно"
    echo "ИНСТРУКЦИЯ: "
	echo "1. Запустите скрипт → выберите: 1) Обновить ядро до 10.2"
	echo "2. После перезагрузки запустите скрипт СНОВА → выберите: 2) Проверить..."
	echo ""
    while true; do
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}       Управление ядром системы         ${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}1) Обновить ядро до 10.2"
        echo -e "${GREEN}2) Проверить и зафиксировать обновленное ядро"
        echo -e "${GREEN}3) Выход"
        echo -e "${GREEN}========================================${NC}"
        
        read -r -p "Выберите действие (1-3): " choice
        
        case "$choice" in
            1)
			    disable_cdrom_sources
				
	            # Этап 0: Обновление с10
                setup_and_update_s10
	
                # Этап 1: Подготовка
                switch_branch
    
                # Этап 2: обрабатываем миграцию OSEC при смене минорной серии ядра
                handle_integalert
	
                # Этап 3: Обновление
                update_system
	
                # Этап 4: Ядро и перезагрузка
                update_kernel
                # Скрипт прервётся на reboot, продолжение после входа в систему
                ;;
            2)
			    init
                show_label_check    
                show_versions_kernel
                post_update_cleanup
                handle_virtualbox
                show_check_update_kernel
				try_exit
                ;;
            3)
                echo "Выход из меню."
                return 0
                ;;
            *)
                echo -e "${YELLOW}Ошибка: Неверный выбор. Введите 1, 2 или 3.${NC}"
                ;;
        esac
        
        read -r -s -n 1 -p "Нажмите любую клавишу для возврата в меню..."
        echo
    done
}

#===============================================================================
# Основная функция
#===============================================================================
main() {
    clear
	echo -e "${GREEN}===============================================================${NC}"
    echo -e "${GREEN}  Скрипт обновления ALT Linux СП 10 → 10.2${NC}"
    echo -e "${GREEN}  Логирование: $LOG_FILE${NC}"
    echo -e "${GREEN}===============================================================${NC}" 
	
    check_root
    
    kernel_management_menu
}

# Запуск
main "$@"

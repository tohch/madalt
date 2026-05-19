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

        # Запуск функции с логированием stdout и stderr
        "$func" "$@" 2>&1 | tee -a "$LOG_FILE"
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
    su "$ORIG_USER" -c "$*" || return 1
    success "$* выполнен успешно"
    return 0
}

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
install_wine(){
    confirm "Установить Wine?" || return 1

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
    confirm "Создать Префикс .talsql?" || return 1
    urun "WINEPREFIX=~/.talsql" "WINEARCH=win32" "wineboot" || return 1
    return 0
}

main() {
    show_preview
    check_root
    clear
    show_preview
    check install_wine
    check create-prefix
}

main "$@"
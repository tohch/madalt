#!/bin/bash

# Не строгая проверка на ошибки (сразу выход)
set -o pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

LOG_FILE="/home/$USER/.cache/tal2.0/install_tal2.0_$(date +%Y%m%d_%H%M%S).log"
# === Обработка флагов запуска ===
AUTO_YES=false
SMB_VERSION="${SMB_VERSION:-}"
while getopts "yhv:" opt; do
    case $opt in
        y) AUTO_YES=true ;;
        v) SMB_VERSION="$OPTARG" ;;
        h)  echo "-y - автоответ Да на вопросы"
            echo "-v: - выбор версии smb (-v 1 - SMB1, -v 2 - SMB2, -v 3 - SMB3)"
            echo "-h - подсказка"
            echo "Пример использования скрипта:"
            echo "chmod +x ./install_tal2.0.sh"
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

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

info()  { echo -e "${BLUE}[INFO]${NC} $1"; log "INFO: $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; log "WARN: $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; log "ERROR: $1"; }
success(){ echo -e "${GREEN}[OK]${NC} $1"; log "OK: $1"; }

show_preview(){
    echo -e "${GREEN}===========================================${NC}"
    echo -e "${GREEN}        Установка Талисмана 2.0            ${NC}"
    echo -e "${GREEN}Этапы установки:                           ${NC}"
    echo -e "${GREEN}- Установка Wine                           ${NC}"
    echo -e "${GREEN}- Настройка сетевых папок (autofs)         ${NC}"
    echo -e "${GREEN}- Установка Талисмана 2.0                  ${NC}"
    echo -e "${GREEN}- Установка BDE                            ${NC}"
    echo -e "${GREEN}Логирование:                               ${NC}"
    echo -e "${GREEN}$LOG_FILE ${NC}"
    echo -e "${GREEN}Архив конфигов autofs: /root/backup_t      ${NC}"
    echo -e "${GREEN}Отвечать Да на все вопросы:                ${NC}"
    echo -e "${GREEN}Подключиться по SMB1                       ${NC}"
    echo -e "${GREEN}./install_tal2.0.sh -v 1                   ${NC}"
    echo -e "${GREEN}===========================================${NC}"
}

show_success(){
    info "Запустите BDE Admin через ярлык на рабочем столе"
    info "Настройте BDE: "
    echo "Native"
    echo "   PARADOX"
    echo "       NET DIR: z:\mnt\tal\talisman_all"
    echo "       LANGDRIVER: Pdox ANSI Cyrilic"
    echo "   DBASE"
    echo "       LANGDRIVER: dBASE RUS cp866"
    echo "System"
    echo "   INIT"
    echo "       LANGDRIVER: Pdox ANSI Cyrilic"
    echo "       LOCAL SHARE: TRUE"
    echo "       SHAREDMEMLOCATION: 3000"
    echo "   Formats"
    echo "       Date"
    echo "           FOURDIGITYER: TRUE"
    echo "           LEADINGZEROD: TRUE"
    echo "           LEAINGZEROM: TRUE"
    echo "           YEARBIASED: TRUE "
    echo ""           
    info "В Талисмане 2.0 путь до базы указывайте как: Z:\mnt\<сервер>\<база>"
    echo -e "${GREEN}===========================================${NC}"
    echo -e "${GREEN}Поздравляю!                                ${NC}"
    echo -e "${GREEN}Талисман 2.0 успешно установлен!           ${NC}"
    echo -e "${GREEN}===========================================${NC}"
    success "Скрипт выполнился успешно."
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
# === mount_share-СПЕЦИФИЧНЫЕ ФУНКЦИИ ===
#===============================================================================

check_mount_share_installed() {
    confirm "Установить mount_share?" || return 0
    if ! ls /usr/bin/mount_share &>/dev/null; then
        warn "mount_share не установлен."
        info "Установка: apt-get install mount_share"
        if confirm "Установить mount_share?"; then
            mkdir -p ~/altlinux/dist/lan
            wget -O ~/altlinux/dist/lan/mount-share-1.0-alt1.noarch.rpm https://github.com/tohch/madalt/releases/download/madalt/mount-share-1.0-alt1.noarch.rpm
            info "Введите пароль root"
            if su - -c "chmod +x /home/$USER/altlinux/dist/lan/mount-share-1.0-alt1.noarch.rpm; apt-get install -y /home/$USER/altlinux/dist/lan/mount-share-1.0-alt1.noarch.rpm"; then
                success "mount_share установлен"
                return 0
            else
                error "Не удалось установить mount_share"
                return 1
            fi
        else
            return 1
        fi
    fi
    return 0
}

#===============================================================================
# Функции установки wine
#===============================================================================
install_wine(){
    confirm "Установить Wine?" || return 0
    if ! rpm -q i586-wine &>/dev/null || ! rpm -q winetricks &>/dev/null || ! rpm -q wine-mono-8.1.0 &>/dev/null; then
        warn "mount_share не установлен."
        info "Установка: apt-get install wine"
        info "Введите пароль root"
        if su - -c "apt-get update; apt-get install -y i586-wine winetricks wine-mono-8.1.0"; then
            success "Wine установлен"
            return 0
        else
            error "Не удалось установить Wine"
            return 1
        fi
    fi
    return 0
}

#===============================================================================
# Функции виртуального интерфейса
#===============================================================================
set_virtual_lan(){
    confirm "Установить виртуальный интерфейс?" || return 0
    local mac_address
    read -p "Введите MAC адрес сервера Талисман 2.0 ( например: 00:C0:26:AB:F7:92 ): " mac_address
    if [ -z "$mac_address" ]; then
        mac_address="00:C0:26:AB:F7:92"
    fi
    info "Введите пароль от root"
    if su - -c "nmcli connection add type dummy ifname veth0 connection.id veth0 ethernet.cloned-mac-address $mac_address ipv4.method manual ipv4.addresses 172.31.10.100/24 && nmcli connection up veth0 && nmcli device status && ip addr show veth0"; then
        success "Виртуальный интерфейс установлен"
        return 0
    else
        error "Не удалось установить Виртуальный интерфейс"
        return 1
    fi
}

#===============================================================================
# Проверка файлов перед установкой
#===============================================================================
check-installer(){
    confirm "Проверить наличие установочного файла $1?" || return 0
    local script_dir; script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    local installer="$1"
    local installer_path="$script_dir/$installer"
    
    if [[ -f "$installer_path" ]]; then
        success "$installer_path существует."
    else
        warn "$installer_path не найден!"
        local safe_workpath=$(printf '%q' "$script_dir")
        confirm "Скачать $installer?" || return 1
        if ! rpm -q python3-module-pip; then
            info "Введите пароль от root"
            su - -c "apt-get install -y python3-module-pip" || { error "Ошибка pip"; return 1; }
        fi
        pip3 install ydiskarc && python3 -c 'import ydiskarc' || { error "Ошибка ydiskarc"; return 1; }
        pip3 install tqdm && python3 -c 'import tqdm' || { error "Ошибка tqdm"; return 1; }
        ~/.local/bin/ydiskarc sync https://disk.yandex.ru/d/odan8KCiqVlK1Q -o $safe_workpath || { error "Ошибка скачивания"; return 1; }
        [[ ! -f "$installer_path" ]] && { error "Не удалось скачать!"; return 1; }
        success "Файл успешно скачан."
    fi
    return 0
}

#===============================================================================
# Создать префикс
#===============================================================================
create-prefix(){
    confirm "Создать Префикс .talbde?" || return 0
    WINEPREFIX=/home/"$USER"/.talbde WINEARCH=win32 wineboot -i || return 1
    success "Префикс успешно создан"
    return 0
}

#===============================================================================
# Установить дополнительные компоненты
#===============================================================================
install-components(){
    confirm "Установить дополнительные компоненты?" || return 0
    for pkg in win2k8 glsl=disabled ddr=gdi dotnet452 msxml3 msxml6 msftedit corefonts tahoma \
               riched20 riched30 vb6run gdiplus vcrun2005 vcrun2008 vcrun2010 \
               vcrun2012 vcrun2013; do
        echo "Установка: $pkg"
        local max_retries=3 attempt=0 success=false
        while [ $attempt -le $max_retries ]; do
            if WINEPREFIX=/home/"$USER"/.talbde winetricks -q $pkg; then
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

# Защита от дурака
check_user(){
    if [[ "$(id -u)" -eq 0 && -z $ORIG_USER ]]; then
        error "Скрипт нельзя запускать от имени root!"
        info "Выйдите из root: exit"
        info "И перезапустите скрипт под пользователем, скрипт сам запросит повышение прав."
        exit 1
    fi
}

do_mount_share(){
    confirm "Запустить mount_share?" || return 0
    local option_v
    if [ "$SMB_VERSION" -ne 0 ]; then
        option_v="-v${SMB_VERSION}"
    fi
    mount_share "$option_v" || return 1
    return 0
}

#===============================================================================
# Установка дистрибутива
#===============================================================================
install(){
    confirm "Установить $1?" || return 0
    local script_dir; script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    local safe_workpath=$(printf '%q' "$script_dir")
    WINEPREFIX=/home/"$USER"/.talbde wine "$safe_workpath/$1" || return 1
}

#===============================================================================
# MAIN
#===============================================================================

main(){
    local HAS_ERRORS=0
    check_user
    mkdir -p "/home/$USER/.cache/tal2.0"
    show_preview
    check check_mount_share_installed  || HAS_ERRORS=1
    check do_mount_share               || HAS_ERRORS=1
    check install_wine                 || HAS_ERRORS=1
    create-prefix                      || HAS_ERRORS=1
    install-components                 || HAS_ERRORS=1
    set_virtual_lan                    || HAS_ERRORS=1
    check-installer "bdex64.exe"       || HAS_ERRORS=1
    check-installer "setup_tal2.0.exe" || HAS_ERRORS=1
    install "bdex64.exe"               || HAS_ERRORS=1
    install "setup_tal2.0.exe"         || HAS_ERRORS=1
    if [[ $HAS_ERRORS -eq 0 ]]; then
        show_success
    else
        warn "Установка завершена с ошибками. Проверьте лог: $LOG_FILE"
    fi
}

main "$@"
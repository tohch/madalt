#!/bin/bash

set -e

# === Проверка прав и авто-перезапуск ===
if [ "$(id -u)" -ne 0 ]; then
    # Сохраняем имя текущего пользователя ДО перехода в root
    CURRENT_USER=$(whoami)
    
    echo "[!] Требуются права root. Введите пароль:"
    # Передаём переменную в команду су-пользователя
    exec su - root -c "CURRENT_USER='$CURRENT_USER' bash '$(realpath "$0")' $*"
fi

# === Теперь мы root, используем переданное имя ===
# Если переменная не передана — используем запасное значение
NAME="${CURRENT_USER:-user}"
SERVER="192.168.205.254"

echo "Запуск от имени root, целевой пользователь: $NAME"

# === Запрос учётных данных у пользователя ===
echo "=== Введите учётные данные для сетевых ресурсов ==="

if [[ ! -t 0 ]]; then
    echo "[!!] Ошибка: скрипт требует интерактивного запуска" >&2
    exit 1
fi

# Ресурс 1: 192.168.205.254 (TAL)
echo "Подсказка: userbuh-gla" 
read -p "Username для 192.168.205.254 (TAL): " USERNAME
read -s -p "Password для $USERNAME: " PASSWORD
echo  # перевод строки после скрытого ввода
# Проверка, что поля не пустые
if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
    echo "[!!] Ошибка: имя пользователя и пароль не могут быть пустыми" >&2
    exit 1
fi

echo "[✓] Учётные данные приняты"
# === Конец ввода ===

mkdir -p /mnt/"$SERVER"

create_link() {
    local target="$1"
    local link="$2"
    
    if [[ -L "$link" ]]; then
        # Ссылка уже существует — проверяем, куда указывает
        if [[ "$(readlink -f "$link")" == "$(readlink -f "$target")" ]]; then
            echo "[✓] Ссылка уже верна: $link"
            return 0
        else
            echo "[!] Ссылка $link указывает неверно, обновляю..."
            ln -sfn "$target" "$link"
        fi
    elif [[ -e "$link" ]]; then
        # Существует, но это не ссылка (файл или папка!)
        echo "[!!] Ошибка: $link существует, но это не символическая ссылка" >&2
        return 1
    else
        # Ссылки нет — создаём
        ln -s "$target" "$link"
    fi
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

    mkdir -p "$backup_dir" 2>/dev/null || { echo "Не удалось создать $backup_dir" >&2; return 1; }

    if cp -p "$file" "$dest" 2>/dev/null; then
        echo "Бэкап создан: $dest" >&2
        return 0
    else
        echo "Бэкап '$file' не создан." >&2
        return 1
    fi
}

AUTOFUS_MASTER="/etc/auto.master"
# Добавление записи в auto.master
add_to_auto_master() {
    local mount_point="$1"
    local map_file="$2"
    
    # Проверяем, есть ли уже запись для этой точки монтирования
    if grep -qE "^[[:space:]]*${mount_point}[[:space:]]+" "$AUTOFUS_MASTER" 2>/dev/null; then
        echo "Запись для $mount_point уже есть в $AUTOFUS_MASTER"
        return 0
    fi
    
    # Добавляем новую запись
    # Формат: /mnt/auto/server_name -fstype=autofs,--ghost,--timeout=60 /etc/auto.d/auto.server
    echo "$mount_point $map_file --ghost,--timeout=60" >> "$AUTOFUS_MASTER"
    echo "Добавлено в $AUTOFUS_MASTER: $mount_point -> $map_file"
}

#===============================================================================
# Создание/обновление map-файла для сервера (с проверкой дубликатов)
#===============================================================================
create_autofs_map() {
    local map_file="$1"
    
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
    local autofs_opts="trash -fstype=cifs,vers=1.0,rw,credentials=/root/.cifs${SERVER},nobrl,soft,file_mode=0777,dir_mode=0777 ://192.168.205.254/trash
mail -fstype=cifs,vers=1.0,rw,credentials=/root/.cifs${SERVER},nobrl,soft,file_mode=0777,dir_mode=0777 ://192.168.205.254/mail
mailout -fstype=cifs,vers=1.0,rw,credentials=/root/.cifs${SERVER},nobrl,soft,file_mode=0777,dir_mode=0777 ://192.168.205.254/mailout
scan -fstype=cifs,vers=1.0,rw,credentials=/root/.cifs${SERVER},nobrl,soft,file_mode=0777,dir_mode=0777 ://192.168.205.254/scan"

        
    # Проверяем, есть ли уже запись для этой шары
    if grep -qE "$autofs_opts" "$map_file" 2>/dev/null; then
        echo "Запись уже существует. Пропускаю добавление!"
    else
        # Записи нет — добавляем новую
        echo "$autofs_opts" >> "$map_file"
        echo "$autofs_opts добавлен в $map_file"
    fi
    echo "Конфигурация создана."
}

CRED_FILE="/root/.cifs${SERVER}"
cat > "$CRED_FILE" <<EOF
username=${USERNAME}
password=${PASSWORD}
domain=RCBUSO
EOF
chmod 600 "$CRED_FILE"


 # 6. Создаём/обновляем map-файл
create_autofs_map "/etc/auto.d/auto.$SERVER"

add_to_auto_master "/mnt/$SERVER" "/etc/auto.d/auto.$SERVER"

create_link "/mnt/$SERVER/trash" "/home/$NAME/Рабочий стол/Общая папка"
create_link "/mnt/$SERVER/mail" "/home/$NAME/Рабочий стол/Почта"
create_link "/mnt/$SERVER/mailout" "/home/$NAME/Рабочий стол/Отправить Почту"
create_link "/mnt/$SERVER/scan" "/home/$NAME/Рабочий стол/Скан"


# === Применяем изменения и активируем автомонтирование ===
echo "[✓] Включаю autofs..."
echo "[✓] Активирую autofs..."
echo "[✓] Перезапускаю autofs..."
systemctl enable autofs
systemctl start autofs
systemctl restart autofs


echo ""
echo "========================================"
echo "[✓] Настройка завершена!"
echo "    Сетевые ресурсы подключатся автоматически"
echo "    при первом обращении к папкам."
echo "========================================"

# Очищаем пароли из памяти
unset PASSWORD USERNAME




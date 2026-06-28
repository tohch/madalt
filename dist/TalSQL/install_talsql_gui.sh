#!/bin/bash

# Проверяем наличие yad
if ! command -v yad &> /dev/null; then
    if command -v zenity &> /dev/null; then
        zenity --error --text="Для работы GUI необходим пакет yad.\nУстановите его: sudo apt-get install yad (или sudo dnf install yad)" --width=300
    else
        echo "Для работы GUI необходим пакет yad."
        echo "Установите его: sudo apt-get install yad"
        read -p "Нажмите Enter для выхода..."
    fi
    exit 1
fi

# Определяем текущего пользователя (даже при su -)
CURRENT_USER="${SUDO_USER:-$USER}"
if [[ "$CURRENT_USER" == "root" ]]; then
    # Пробуем получить из переменных окружения su/sudo
    CURRENT_USER="${LOGNAME:-${USER}}"
    [[ "$CURRENT_USER" == "root" ]] && CURRENT_USER=""
fi

# Функция проверки имени пользователя
validate_user() {
    local name="$1"
    
    # Пустое имя
    if [[ -z "$name" ]]; then
        echo "Имя пользователя не может быть пустым"
        return 1
    fi
    
    # Длина
    if [[ ${#name} -gt 32 ]]; then
        echo "Имя пользователя слишком длинное (макс. 32 символа)"
        return 1
    fi
    
    # Формат: буквы/цифры/_/-, не начинается с - или цифры
    if [[ ! "$name" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
        echo "Недопустимые символы в имени пользователя.\nРазрешены: a-z, 0-9, _, -"
        return 1
    fi
    
    # Не root
    if [[ "$name" == "root" ]]; then
        echo "Нельзя устанавливать для пользователя root"
        return 1
    fi
    
    # Проверка существования в системе
    if ! id "$name" &>/dev/null; then
        echo "Пользователь '$name' не существует в системе"
        return 1
    fi
    
    return 0
}

# Цикл запроса имени пользователя
while true; do
    TARGET_USER=$(yad --title="Имя пользователя" \
        --form --center --width=350 \
        --borders=10 \
        --text="Введите имя пользователя, для которого устанавливается Талисман SQL:" \
        --field="Имя пользователя:":FLD "$CURRENT_USER" \
        --button="gtk-cancel:1" \
        --button="Далее:0" 2>/dev/null)
    
    RET=$?
    if [ $RET -ne 0 ]; then
        exit 0
    fi
    
    TARGET_USER="${TARGET_USER%|}"
    TARGET_USER=$(echo "$TARGET_USER" | tr '[:upper:]' '[:lower:]' | xargs)  # в нижний регистр, trim
    
    # Проверяем имя
    ERROR_MSG=$(validate_user "$TARGET_USER")
    if [[ $? -eq 0 ]]; then
        break  # всё ок, выходим из цикла
    fi
    
    # Показываем ошибку и повторяем
    yad --error --title="Ошибка" \
        --text="$ERROR_MSG" \
        --width=350 --center 2>/dev/null
    
    CURRENT_USER="$TARGET_USER"  # подставим введённое, чтобы можно было исправить
done

TARGET_USER="${TARGET_USER%|}"

if [[ -z "$TARGET_USER" ]]; then
    yad --error --text="Не указано имя пользователя!" --width=300 2>/dev/null
    exit 1
fi

# Второй диалог - остальные поля с предзаполненным путём
FORM_DATA=$(yad --title="Установка Талисман SQL" \
    --form --center --width=480 --height=280 \
    --field="Путь к префиксу Wine:":FLD "/home/$TARGET_USER/.talsql" \
    --field="IP или имя сервера:":FLD "" \
    --field="Логин (опционально):":FLD "" \
    --field="Пароль (опционально):":H "" \
    --button="gtk-cancel:1" \
    --button="Установить:0" 2>/dev/null)

RET=$?
if [ $RET -ne 0 ]; then
    exit 0
fi

# Парсим вывод yad (разделитель |)
IFS='|' read -r PREFIX_PATH SERVER LOGIN PASS <<< "$FORM_DATA"

# Убираем завершающий разделитель
PREFIX_PATH="${PREFIX_PATH%|}"
SERVER="${SERVER%|}"
LOGIN="${LOGIN%|}"
PASS="${PASS%|}"

# Проверка обязательных полей
if [[ -z "$TARGET_USER" ]]; then
    yad --error --text="Не указано имя пользователя!" --width=300 2>/dev/null || { echo "Отмена"; exit 1; }
fi

if [[ -z "$PREFIX_PATH" ]]; then
    yad --error --text="Не указан путь к префиксу Wine!" --width=300 2>/dev/null || { echo "Отмена"; exit 1; }
fi

if [[ -z "$SERVER" ]]; then
    yad --error --text="Не указан IP или имя сервера!" --width=300 2>/dev/null || { echo "Отмена"; exit 1; }
fi

# Проверяем существование домашнего каталога пользователя
if [[ ! -d "/home/$TARGET_USER" ]]; then
    yad --error --text="Домашний каталог пользователя $TARGET_USER не найден:\n/home/$TARGET_USER" --width=400 2>/dev/null || { echo "Отмена"; exit 1; }
fi

# Ищем графический терминал для вывода процесса установки
TERM_CMD=""
TERM_ARGS=""

if command -v gnome-terminal &> /dev/null; then
    TERM_CMD="gnome-terminal"
    TERM_ARGS="--"
elif command -v konsole &> /dev/null; then
    TERM_CMD="konsole"
    TERM_ARGS="-e"
elif command -v xfce4-terminal &> /dev/null; then
    TERM_CMD="xfce4-terminal"
    TERM_ARGS="-x"
elif command -v mate-terminal &> /dev/null; then
    TERM_CMD="mate-terminal"
    TERM_ARGS="-x"
elif command -v lxterminal &> /dev/null; then
    TERM_CMD="lxterminal"
    TERM_ARGS="-e"
elif command -v xterm &> /dev/null; then
    TERM_CMD="xterm"
    TERM_ARGS="-e"
else
    yad --error --text="Не найден графический терминал!\nУстановите gnome-terminal, konsole или xterm." --width=300
    exit 1
fi

# Определяем путь к основному скрипту
SCRIPT_PATH="/usr/local/bin/install_talsql"
if [[ ! -x "$SCRIPT_PATH" ]]; then
    # Если установлен в другом месте, ищем рядом с GUI-обёрткой
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SCRIPT_PATH="$SCRIPT_DIR/install_talsql"
fi

if [[ ! -x "$SCRIPT_PATH" ]]; then
    yad --error --text="Не найден основной скрипт установки:\n$SCRIPT_PATH" --width=400
    exit 1
fi

# Формируем команду запуска
RUN_CMD="env CUSTOM_WINEPREFIX=\"$PREFIX_PATH\" \
              CUSTOM_SERVER=\"$SERVER\" \
              CUSTOM_USER=\"$LOGIN\" \
              CUSTOM_PASS=\"$PASS\" \
              CUSTOM_ORIG_USER=\"$TARGET_USER\" \
              CUSTOM_PATH_EXE=\"/usr/local/share/talsql-installer/\" \
          bash -c \"\\\"$SCRIPT_PATH\\\" -y; echo ''; echo '=== Установка завершена ==='; echo 'Нажмите Enter для закрытия окна...'; read\""

# Запускаем основной скрипт БЕЗ sudo - скрипт сам запросит права через su
if [ -t 1 ]; then
    eval "$RUN_CMD"
else
    $TERM_CMD $TERM_ARGS bash -c "$RUN_CMD"
fi
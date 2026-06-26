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

# Показываем форму для ввода данных
FORM_DATA=$(yad --title="Установка Талисман SQL" \
    --form --center --width=480 --height=280 \
    --field="Путь к префиксу Wine:":FLD "$HOME/.talsql" \
    --field="IP или имя сервера:":FLD "" \
    --field="Логин (опционально):":FLD "" \
    --field="Пароль (опционально):":H "" \
    --button="gtk-cancel:1" \
    --button="Установить:0")

RET=$?
if [ $RET -ne 0 ]; then
    exit 0
fi

# Парсим вывод yad (разделитель |)
IFS='|' read -r PREFIX_PATH SERVER USER PASS <<< "$FORM_DATA"

# Убираем завершающий разделитель (yad добавляет | в конце)
PREFIX_PATH="${PREFIX_PATH%|}"
SERVER="${SERVER%|}"
USER="${USER%|}"
PASS="${PASS%|}"

# Проверка обязательных полей
if [[ -z "$PREFIX_PATH" ]]; then
    yad --error --text="Не указан путь к префиксу Wine!" --width=300
    exit 1
fi

if [[ -z "$SERVER" ]]; then
    yad --error --text="Не указан IP или имя сервера!" --width=300
    exit 1
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
SCRIPT_PATH="/usr/local/bin/install_talsql.sh"
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
              CUSTOM_USER=\"$USER\" \
              CUSTOM_PASS=\"$PASS\" \
              CUSTOM_PATH_EXE=\"/usr/local/share/talsql-installer/\" \
          bash -c \"\\\"$SCRIPT_PATH\\\" -y; echo ''; echo '=== Установка завершена ==='; echo 'Нажмите Enter для закрытия окна...'; read\""

# Запускаем основной скрипт БЕЗ sudo - скрипт сам запросит права через su
if [ -t 1 ]; then
    eval "$RUN_CMD"
else
    $TERM_CMD $TERM_ARGS bash -c "$RUN_CMD"
fi


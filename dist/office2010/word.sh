#!/bin/sh
# Открывает DOC/DOCX в MS Word 2010 через Wine
# FIX: обходит проверку симлинков, меняет CWD на реальную папку

# === ОКРУЖЕНИЕ ===
export DISPLAY="${DISPLAY:-:0}"
if [ -z "$XAUTHORITY" ]; then
    [ -f "$HOME/.Xauthority" ] && export XAUTHORITY="$HOME/.Xauthority"
    [ -f "/run/user/$(id -u)/gdm/Xauthority" ] && export XAUTHORITY="/run/user/$(id -u)/gdm/Xauthority"
fi

WPREFIX="/home/$USER/.office2010"
WINWORD_PATH="C:\\Program Files\\Microsoft Office\\Office14\\WINWORD.EXE"

[ -z "$1" ] && exit 0

INPUT="${1#file://}"

# 1. ВСЕГДА превращаем симлинк в реальный абсолютный путь
REAL_PATH=$(readlink -f "$INPUT" 2>/dev/null) || REAL_PATH="$INPUT"
[ ! -f "$REAL_PATH" ] && exit 1

# 2. КЛЮЧЕВОЙ ФИКС: меняем рабочую директорию на папку РЕАЛЬНОГО файла
# Word создаст ~$*.docx и кэш там же, а не в папке с симлинком
cd "$(dirname "$REAL_PATH")" || exit 1

# 3. Преобразуем путь для Wine
WIN_PATH=$(WINEPREFIX="$WPREFIX" winepath -w "$REAL_PATH" 2>/dev/null) || WIN_PATH="$REAL_PATH"

# 4. Запуск
if WINEPREFIX="$WPREFIX" wine tasklist /fi "IMAGENAME eq WINWORD.EXE" 2>/dev/null | grep -q WINWORD; then
    # Word уже работает — пробуем открыть в том же экземпляре
    WINEPREFIX="$WPREFIX" wine "$WINWORD_PATH" /reuse "$WIN_PATH"
else
    # Первый запуск
    WINEPREFIX="$WPREFIX" wine "$WINWORD_PATH" "$WIN_PATH"
fi

exit 0
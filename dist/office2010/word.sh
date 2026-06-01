#!/bin/sh
# Открывает DOC/DOCX в MS Word 2010 через Wine по двойному клику
# Корректно обрабатывает симлинки, пробелы, кириллицу и file:// URI

WPREFIX="/home/$USER/.office2010"
WINWORD_PATH="C:\\Program Files\\Microsoft Office\\Office14\\WINWORD.EXE"

# Файловый менеджер передаёт путь в $1. Если аргумента нет — выходим
[ -z "$1" ] && exit 0

# Убираем префикс file:// (некоторые менеджеры его добавляют)
INPUT="${1#file://}"

# Разрешаем символические ссылки и относительные пути
# ~/Desktop/server -> /mnt/server, ../файл.docx -> полный путь
REAL_PATH=$(readlink -f "$INPUT" 2>/dev/null) || REAL_PATH="$INPUT"

# Проверяем, что файл существует
[ ! -f "$REAL_PATH" ] && exit 1

# Преобразуем Linux-путь в Windows-формат для Wine
# Если winepath падает (редко), передаём путь как есть (Z:\ подхватит)
WIN_PATH=$(WINEPREFIX="$WPREFIX" winepath -w "$REAL_PATH" 2>/dev/null) || WIN_PATH="$REAL_PATH"

# Запускаем Word. exec заменяет процесс sh процессом wine (экономит ресурсы)
WINEPREFIX="$WPREFIX" wine "$WINWORD_PATH" "$WIN_PATH"

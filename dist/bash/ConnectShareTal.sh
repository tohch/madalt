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

# Ресурс 2: 192.168.205.4 (TALSQL)
echo "Подсказка: administr-mir"
read -p "Username для 192.168.205.4 (TALSQL): " USERNAMETALSQL
read -s -p "Password для $USERNAMETALSQL: " PASSWORDTALSQL
echo
if [[ -z "$USERNAMETALSQL" || -z "$PASSWORDTALSQL" ]]; then
    echo "[!!] Ошибка: имя пользователя и пароль не могут быть пустыми" >&2
    exit 1
fi

echo "[✓] Учётные данные приняты"
# === Конец ввода ===

mkdir -p /mnt/tal/trash
mkdir -p /mnt/tal/mail
mkdir -p /mnt/tal/mailout
mkdir -p /mnt/tal/scan
mkdir -p /mnt/tal/talisman_bde
mkdir -p /mnt/talsql/strah
mkdir -p /mnt/talsql/out
mkdir -p /mnt/talsql/pochta
mkdir -p /home/"$NAME"/.talsql/dosdevices/unc/192.168.205.4

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

create_link "/mnt/tal/trash" "/home/$NAME/Рабочий стол/Общая папка"
create_link "/mnt/tal/mail" "/home/$NAME/Рабочий стол/Почта"
create_link "/mnt/tal/mailout" "/home/$NAME/Рабочий стол/Отправить Почту"
create_link "/mnt/tal/scan" "/home/$NAME/Рабочий стол/Скан"
create_link "/mnt/talsql/strah" "/home/$NAME/.talsql/dosdevices/unc/192.168.205.4/strah"
create_link "/mnt/talsql/out" "/home/$NAME/.talsql/dosdevices/unc/192.168.205.4/out"
create_link "/mnt/talsql/pochta" "/home/$NAME/.talsql/dosdevices/unc/192.168.205.4/pochta"

CRED_FILE="/root/.usermnt"
cat > "$CRED_FILE" <<EOF
username=${USERNAME}
password=${PASSWORD}
domain=RCBUSO
EOF
chmod 600 "$CRED_FILE"

CRED_FILE_TALSQL="/root/.cifsmnt"
cat > "$CRED_FILE_TALSQL" <<EOF
username=${USERNAMETALSQL}
password=${PASSWORDTALSQL}
domain=RCBUSO
EOF
chmod 600 "$CRED_FILE_TALSQL"

FSTAB_ENTRY="//192.168.205.254/trash /mnt/tal/trash cifs vers=1.0,noauto,x-systemd.automount,_netdev,rw,credentials=/root/.usermnt,nobrl,soft,file_mode=0777,dir_mode=0777,nofail 0 0
//192.168.205.254/mail /mnt/tal/mail cifs vers=1.0,noauto,x-systemd.automount,_netdev,rw,credentials=/root/.usermnt,nobrl,soft,file_mode=0777,dir_mode=0777,nofail 0 0
//192.168.205.254/mailout /mnt/tal/mailout cifs vers=1.0,noauto,x-systemd.automount,_netdev,rw,credentials=/root/.usermnt,nobrl,soft,file_mode=0777,dir_mode=0777,nofail 0 0
//192.168.205.254/scan /mnt/tal/scan cifs vers=1.0,noauto,x-systemd.automount,_netdev,rw,credentials=/root/.usermnt,nobrl,soft,file_mode=0777,dir_mode=0777,nofail 0 0
//192.168.205.254/talisman_bde /mnt/tal/talisman_bde cifs vers=1.0,noauto,x-systemd.automount,_netdev,rw,credentials=/root/.usermnt,nobrl,soft,nofail 0 0
//192.168.205.4/strah /mnt/talsql/strah cifs noauto,x-systemd.automount,_netdev,rw,credentials=/root/.cifsmnt,nobrl,soft,file_mode=0777,dir_mode=0777,nofail 0 0
//192.168.205.4/out /mnt/talsql/out cifs noauto,x-systemd.automount,_netdev,rw,credentials=/root/.cifsmnt,nobrl,soft,file_mode=0777,dir_mode=0777,nofail 0 0
//192.168.205.4/pochta /mnt/talsql/pochta cifs noauto,x-systemd.automount,_netdev,rw,credentials=/root/.cifsmnt,nobrl,soft,nofail 0 0"

if ! grep -qF "$FSTAB_ENTRY" /etc/fstab; then
	echo "$FSTAB_ENTRY" >> /etc/fstab
else
	echo "[!] Запись уже существует в /etc/fstab"
fi

# === Применяем изменения и активируем автомонтирование ===
echo "[✓] Обновляю конфигурацию systemd..."
systemctl daemon-reload

echo "[✓] Активирую юниты автомонтирования..."
# Список всех automount-юнитов, которые мы добавили в fstab
for unit in mnt-tal-{trash,mail,mailout,scan,talisman_bde}.automount \
            mnt-talsql-{strah,out,pochta}.automount; do
    
    # Запускаем юнит (переводит в состояние active/waiting)
    if systemctl start "$unit" 2>/dev/null; then
        echo "  [✓] $unit → ожидает обращения"
    else
        echo "  [!] $unit → не удалось активировать (проверьте логи)" >&2
    fi
done

echo ""
echo "========================================"
echo "[✓] Настройка завершена!"
echo "    Сетевые ресурсы подключатся автоматически"
echo "    при первом обращении к папкам."
echo "========================================"

# Очищаем пароли из памяти
unset PASSWORD PASSWORDTALSQL USERNAME USERNAMETALSQL




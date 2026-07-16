#!/bin/bash

# Скрипт для расшаривания принтера с Альт СП 8 для Windows 10
# Версия 2.0: Улучшенное определение IP-адреса

if [ "$EUID" -ne 0 ]; then
    echo "Ошибка: скрипт требует прав root"
    echo "Запустите: su - и затем выполните скрипт"
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_header() { echo -e "\n${GREEN}========================================${NC}\n${GREEN}$1${NC}\n${GREEN}========================================${NC}\n"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }

print_header "РАСШАРИВАНИЕ ПРИНТЕРА С АЛЬТ СП 8 ДЛЯ WINDOWS 10"

# ============ ШАГ 1: Поиск принтеров ============
print_header "ШАГ 1: Имеющиеся принтеры"
echo "Список установленных принтеров:"
echo "--------------------------------"

PRINTERS=$(lpstat -p 2>/dev/null | grep -Ei "^(принтер|printer)" | awk '{print $2}')

if [ -z "$PRINTERS" ]; then
    print_error "Принтеры не найдены!"
    echo "Убедитесь, что принтер подключен и настроен в системе."
    exit 1
fi

PRINTER_ARRAY=($PRINTERS)
for i in "${!PRINTER_ARRAY[@]}"; do
    PRINTER_NAME=${PRINTER_ARRAY[$i]}
    PRINTER_STATUS=$(lpstat -p "$PRINTER_NAME" 2>/dev/null | grep -Eio "свободен|занят|отключен|idle|busy|disabled" | head -1)
    echo "$((i+1)). $PRINTER_NAME ($PRINTER_STATUS)"
done
echo ""
print_success "Найдено принтеров: ${#PRINTER_ARRAY[@]}"

# ============ ШАГ 2: Настройка конфига CUPS ============
print_header "ШАГ 2: Настройка конфигурации CUPS"
CUPS_CONF="/etc/cups/cupsd.conf"
CUPS_CONF_BACKUP="/etc/cups/cupsd.conf.backup.$(date +%Y%m%d_%H%M%S)"

echo "Создание резервной копии конфига..."
cp "$CUPS_CONF" "$CUPS_CONF_BACKUP"
print_success "Бэкап создан: $CUPS_CONF_BACKUP"

if grep -q "^Listen localhost:631" "$CUPS_CONF"; then
    echo "Изменение Listen для доступа из сети..."
    sed -i 's/^Listen localhost:631/Listen 0.0.0.0:631/' "$CUPS_CONF"
    print_success "Listen изменен на 0.0.0.0:631"
elif grep -q "^Port 631" "$CUPS_CONF"; then
    print_warning "Port 631 уже настроен, пропускаем"
else
    print_warning "Не найдена директива Listen или Port"
fi

if ! grep -q "<Location /printers>" "$CUPS_CONF"; then
    echo "Добавление блока <Location /printers>..."
    sed -i '/<\/Location>/,/<Location \/admin>/{
        /<\/Location>/a\
\
<Location /printers>\
  Order allow,deny\
  Allow @LOCAL\
</Location>
    }' "$CUPS_CONF"
    print_success "Блок <Location /printers> добавлен"
else
    print_warning "Блок <Location /printers> уже существует"
fi

if ! grep -A 3 "<Location />" "$CUPS_CONF" | grep -q "Allow @LOCAL"; then
    echo "Добавление Allow @LOCAL в основной блок..."
    sed -i '/<Location \/>/,/<\/Location>/{
        /Order allow,deny/a\
  Allow @LOCAL
    }' "$CUPS_CONF"
    print_success "Allow @LOCAL добавлен в основной блок"
else
    print_success "Allow @LOCAL уже присутствует"
fi

# ============ ШАГ 3: Перезапуск и проверка ============
print_header "ШАГ 3: Перезапуск служб и проверка настроек"
echo "Перезапуск службы CUPS..."
systemctl restart cups

if [ $? -eq 0 ]; then
    print_success "Служба CUPS перезапущена"
else
    print_error "Ошибка перезапуска CUPS"
    exit 1
fi

sleep 2
if systemctl is-active --quiet cups; then
    print_success "Служба CUPS активна"
else
    print_error "Служба CUPS не активна!"
    systemctl status cups --no-pager
    exit 1
fi

echo "Проверка прослушивания порта 631..."
if ss -tlnp 2>/dev/null | grep -q ":631"; then
    print_success "Порт 631 слушается"
    ss -tlnp 2>/dev/null | grep ":631" | awk '{print "  " $4}'
else
    print_error "Порт 631 не слушается!"
    exit 1
fi

echo "Проверка фаервола..."
if command -v iptables &> /dev/null; then
    if iptables -L INPUT -n 2>/dev/null | grep -q "dpt:631.*ACCEPT"; then
        print_success "Порт 631 разрешен в iptables"
    else
        print_warning "Порт 631 не найден в правилах iptables. Добавляем правило..."
        iptables -I INPUT -p tcp --dport 631 -j ACCEPT
        service iptables save 2>/dev/null
        print_success "Правило добавлено и сохранено"
    fi
elif command -v firewall-cmd &> /dev/null; then
    if firewall-cmd --query-port=631/tcp 2>/dev/null | grep -q "yes"; then
        print_success "Порт 631 разрешен в firewalld"
    else
        print_warning "Открываем порт 631 в firewalld..."
        firewall-cmd --permanent --add-port=631/tcp
        firewall-cmd --reload
        print_success "Порт 631 открыт"
    fi
fi

# ============ ШАГ 4: Финальная информация ============
print_header "ШАГ 4: Информация для подключения с Windows 10"

# НАДЕЖНОЕ ОПРЕДЕЛЕНИЕ IP-АДРЕСА
# Берем первый глобальный IPv4 адрес, исключая 127.0.0.1
IP_ADDRESS=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n 1)

# Резервный вариант, если первый не сработал
if [ -z "$IP_ADDRESS" ]; then
    IP_ADDRESS=$(hostname -I | awk '{print $1}')
fi

# Если всё равно пусто, сообщаем пользователю
if [ -z "$IP_ADDRESS" ]; then
    IP_ADDRESS="ВАШ_IP_АДРЕС_(укажите_вручную)"
    print_warning "Не удалось автоматически определить IP-адрес. Укажите его вручную."
else
    print_success "Автоматически определен IP-адрес: $IP_ADDRESS"
fi

HOSTNAME=$(hostname)

echo -e "\n${GREEN}Настройки завершены успешно!${NC}\n"
echo "Доступные принтеры для подключения:"
echo "===================================="

for PRINTER_NAME in "${PRINTER_ARRAY[@]}"; do
    echo ""
    echo -e "${YELLOW}Принтер: $PRINTER_NAME${NC}"
    echo "Скопируйте эту строку в Windows:"
    echo -e "${GREEN}  http://$IP_ADDRESS:631/printers/$PRINTER_NAME${NC}"
    echo "Альтернативный вариант (IPP):"
    echo "  ipp://$IP_ADDRESS:631/printers/$PRINTER_NAME"
done

echo ""
echo "===================================="
echo -e "${GREEN}Инструкция для Windows 10:${NC}"
echo "===================================="
echo "1. Пуск → Параметры → Устройства → Принтеры и сканеры"
echo "2. 'Добавить принтер или сканер'"
echo "3. 'Необходимый принтер отсутствует в списке'"
echo "4. Выберите 'Выбрать общий принтер по имени'"
echo "5. Вставьте URL (зеленую строку) из списка выше"
echo "6. Нажмите 'Далее' и выберите драйвер принтера"
echo ""
echo "===================================="
echo -e "${GREEN}Веб-интерфейс CUPS:${NC}"
echo "===================================="
echo "Откройте в браузере: http://$IP_ADDRESS:631"
echo ""
print_success "Настройка завершена! Можно подключаться с Windows 10."
SCRIPT_EOF

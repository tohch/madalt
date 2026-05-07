#!/usr/bin/env python3

#журнал уведомлений (только для xfce4)
#apt-get install xfce4-notifyd
#apt-get install xfce4-notification-plugin
#Панель-Добавить новый элемент-Модуль оповещений
#Настройка оповещения-Журннал-Записывать оповещения в жрунал-всегда
#Если в журнал не сохраняется, то настроить xfce-notifyd
#find /usr -name "xfce4-notifyd" 2>/dev/null
#sudo ln -s /usr/lib64/xfce4/notifyd/xfce4-notifyd /usr/bin/xfce4-notifyd
#Добавить в атозагрузку Сеансы и запуск-Автозапуск приложений-Добавить
#Команда: xfce4-notifyd

import socket
import subprocess
import os
import threading
import time
import re
from datetime import datetime

PORT = 5555
BATCH_DELAY = 2.0  # Ждать 2 секунды перед показом уведомления
DURATION_NOTIFY = '60000' # 60 секунд

# Окружение для уведомлений
env = os.environ.copy()
env['DISPLAY'] = os.environ.get('DISPLAY', ':0')
env['DBUS_SESSION_BUS_ADDRESS'] = f"unix:path=/run/user/{os.getuid()}/bus"

# Буфер для сообщений
messages = []
lock = threading.Lock()
timer = None
PATTERNS = [
    (r'Создан.*\[In\] UP.*\.sql.*', 'Поступил UP'),
    (r'Удален.*\[In\] UP.*\.sql.*', 'Репликация завершена'),
    (r'.*\[Down\].*DOWN.*\.sql.*', 'Обработан DOWN'),
	(r'.*\[.*\d\.\d\d\].*', 'Почта')
]
PATTERNS_INN = [
	(r'.*2331013928.*', 'Ейская РЦБ'),
	(r'.*2331012353.*', 'Ейский КЦРИ'),
    (r'.*2331012265.*', 'Ейский МРЦ'),
    (r'.*2331009400.*', 'Ейский КЦСОН'),
    (r'.*2306021361.*', 'Ейский СРЦН'),
    (r'.*2331012280.*', 'Камышеватский СРЦН'),
    (r'.*2306021065.*', 'Ейский ДДИ'),
    (r'.*2361018440.*', 'УСЗН в Ейском р-не'),
    (r'.*2306014452.*', 'Ейский ПНИ'),
    (r'.*2331005902.*', 'Камышеватский ДИПИ')
]

def get_text(text, separator=" - "):
	for pattern, name in PATTERNS_INN:
		if re.search(pattern, text):
			return f"{text}{separator}{name}"
	return text

def get_composite_text(texts, separator="\n"):
	message_list = []	
	for text in texts:
		m = get_text(text)
		message_list.append(f"{m}")
	return separator.join(message_list)

def get_title(text):
    for pattern, title in PATTERNS:
        if re.search(pattern, text):
            return title
    return 'Уведомление'

def get_composite_title(texts, separator=' + '):
    titles = []
    seen = set()  # Для отслеживания уже добавленных заголовков
    
    for text in texts:
        title = get_title(text)
        if title and title not in seen:
            titles.append(title)
            seen.add(title)  # Добавляем в множество для проверки уникальности
    
    time_str = datetime.now().strftime('%H:%M')
    return f"{separator.join(titles)} {time_str}" if titles else f'Уведомление {time_str}'

def send_notification():
    """Отправляет накопленные сообщения одним уведомлением"""
    global messages, timer
    
    with lock:
        if not messages:
            return
        
        # Формируем текст уведомления
        if len(messages) == 1:
            title = get_composite_title(messages)
            text = get_text(messages[0])
        else:
            title = get_composite_title(messages)
            text = get_composite_text(messages)
        
        # Очищаем буфер
        messages = []
    
    # Показываем уведомление (вне блока lock, чтобы не блокировать прием)
    subprocess.Popen(['notify-send', '-t', DURATION_NOTIFY, '-u', 'normal', title, text], env=env)
    timer = None

def schedule_notification():
    """Планирует отправку уведомления через BATCH_DELAY секунд"""
    global timer
    
    with lock:
        if timer is not None:
            timer.cancel()
        
        # Запускаем таймер заново
        timer = threading.Timer(BATCH_DELAY, send_notification)
        timer.start()

def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('0.0.0.0', PORT))
    
    print(f"Слушаю порт {PORT} (агрегация {BATCH_DELAY} сек)...", flush=True)
    
    try:
        while True:
            data, addr = sock.recvfrom(4096)
            msg = data.decode('utf-8', errors='ignore').strip()
            
            if msg:
                with lock:
                    messages.append(msg)
                    print(f"Получено: {msg}", flush=True)
                
                # Перезапускаем таймер ожидания
                schedule_notification()
                
    except KeyboardInterrupt:
        print("\nОстановлено.")
        if timer:
            timer.cancel()
        sock.close()

if __name__ == "__main__":
    main()

#!/bin/bash

# AltCor Installer для Ubuntu 22.04+
# Apache + Nginx + PHP + MariaDB + Redis + LibreOffice

# --- Константы ---
APP_NAME="AltCor"
APP_VERSION="1.0"
DEFAULT_INSTALL_DIR="/opt/Altcor"
TEMP_DIR="/tmp/altcor_install"
LOG_FILE="/var/log/altcor_install.log"
SOURCE_DIR=$(dirname "$(realpath "$0")")/src

# --- Переменные ---
generated_password=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c12)
local_ip=$(hostname -I | awk '{print $1}')
[ -z "$local_ip" ] && local_ip="127.0.0.1"

# --- Функции ---

function log {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

function error_exit {
    log "ОШИБКА: $1"
    whiptail --title "Ошибка установки" --msgbox "$1" 12 60
    exit 1
}

function install_dependencies {
    log "Установка зависимостей..."
    
    # Устанавливаем переменную для автоматического принятия изменений
    export DEBIAN_FRONTEND=noninteractive
    
    # Обновление пакетов (игнорируем предупреждение о Label)
    apt-get update -yq 2>&1 | grep -v "изменил значение поля «Label»" | tee -a "$LOG_FILE"
    [ ${PIPESTATUS[0]} -ne 0 ] && error_exit "Ошибка обновления пакетов"
    
    # Основные зависимости
    local base_packages=(
        apache2
        nginx
        mariadb-server
        redis-server
        libreoffice
        libreoffice-writer
        libreoffice-calc
        libreoffice-headless
        software-properties-common
        whiptail
        unoconv
    )
    
    apt-get install -yq "${base_packages[@]}" | tee -a "$LOG_FILE"
    [ ${PIPESTATUS[0]} -ne 0 ] && error_exit "Ошибка установки основных пакетов"

    # Добавляем PPA для PHP (игнорируем предупреждение)
    add-apt-repository -y ppa:ondrej/php 2>&1 | grep -v "изменил значение поля «Label»" | tee -a "$LOG_FILE"
    
    # Повторное обновление (игнорируем предупреждение)
    apt-get update -yq 2>&1 | grep -v "изменил значение поля «Label»" | tee -a "$LOG_FILE"
    [ ${PIPESTATUS[0]} -ne 0 ] && error_exit "Ошибка обновления после добавления PPA"
    
    # PHP и модули
    local php_packages=(
        php8.2
        php8.2-fpm
        php8.2-mysql
        php8.2-curl
        php8.2-mbstring
        php8.2-xml
        php8.2-zip
        php8.2-gd
        libapache2-mod-php8.2
    )
    
    apt-get install -yq "${php_packages[@]}" | tee -a "$LOG_FILE"
    [ ${PIPESTATUS[0]} -ne 0 ] && error_exit "Ошибка установки PHP"
}

function configure_libreoffice {
    log "Настройка LibreOffice..."
    
    # Создаем службу для LibreOffice
    cat > /etc/systemd/system/altcor-libreoffice.service <<EOF
[Unit]
Description=AltCor LibreOffice Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/soffice --headless --nologo --nofirststartwizard --accept="socket,host=127.0.0.1,port=2002;urp;"
User=www-data
Group=www-data
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable altcor-libreoffice
    systemctl start altcor-libreoffice
}

function stop_services {
    log "Остановка служб..."
    
    systemctl stop apache2 nginx mariadb redis php*-fpm altcor-libreoffice 2>/dev/null
    pkill -9 apache2 nginx mysqld redis-server php-fpm soffice 2>/dev/null
}

function install_components {
    local install_dir="$1"
    log "Установка компонентов в $install_dir..."
    
    # Проверка папки src
    if [ ! -d "$SOURCE_DIR" ]; then
        error_exit "Папка с исходными файлами не найдена: $SOURCE_DIR\n\nСоздайте папку 'src' рядом со скриптом и поместите туда:\n- Apache24/\n- PHP/\n- LibreOffice/"
    fi
    
    # Создание структуры каталогов
    mkdir -p "$install_dir" || error_exit "Не удалось создать директорию установки"
    
    # Копирование компонентов с проверкой
    local components=("Apache24" "PHP" "LibreOffice")
    for comp in "${components[@]}"; do
        if [ -d "$SOURCE_DIR/$comp" ]; then
            cp -R "$SOURCE_DIR/$comp" "$install_dir/" || error_exit "Ошибка копирования $comp"
        else
            log "Предупреждение: компонент $comp отсутствует в src/"
        fi
    done
    
    # Права доступа
    chown -R www-data:www-data "$install_dir"
    chmod -R 755 "$install_dir"
}

function configure_apache {
    local install_dir="$1"
    log "Настройка Apache..."
    
    # Отключаем стандартный сайт
    a2dissite 000-default.conf 2>/dev/null
    
    # Конфиг AltCor
    cat > /etc/apache2/sites-available/altcor.conf <<EOF
<VirtualHost *:80>
    ServerName $local_ip
    DocumentRoot $install_dir/Apache24/htdocs
    
    <Directory $install_dir/Apache24/htdocs>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/altcor_error.log
    CustomLog \${APACHE_LOG_DIR}/altcor_access.log combined
    
    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php8.2-fpm.sock|fcgi://localhost"
    </FilesMatch>
</VirtualHost>
EOF

    # Включаем конфигурацию
    a2ensite altcor.conf && a2enmod rewrite proxy_fcgi || error_exit "Ошибка настройки Apache"
    
    # Настройка PHP
    if [ -f "$install_dir/PHP/php.ini" ]; then
        cp "$install_dir/PHP/php.ini" /etc/php/8.2/fpm/php.ini
        cp "$install_dir/PHP/php.ini" /etc/php/8.2/apache2/php.ini
    fi
    
    systemctl restart apache2 php8.2-fpm
}

function configure_mariadb {
    log "Настройка MariaDB..."
    
    # Временный запуск MariaDB без пароля
    systemctl stop mariadb
    mysqld_safe --skip-grant-tables &
    sleep 5
    
    # Установка пароля root
    mysql -uroot <<EOF
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '$generated_password';
FLUSH PRIVILEGES;
EOF

    # Остановка временного сервера
    mysqladmin -uroot -p"$generated_password" shutdown
    systemctl start mariadb
    
    # Создаем БД и пользователя
    mysql -uroot -p"$generated_password" <<EOF
CREATE DATABASE IF NOT EXISTS ALTCor;
CREATE USER IF NOT EXISTS 'altcor'@'localhost' IDENTIFIED BY '$generated_password';
GRANT ALL PRIVILEGES ON ALTCor.* TO 'altcor'@'localhost';
FLUSH PRIVILEGES;
EOF
}

function setup_services {
    log "Настройка автозагрузки сервисов..."
    
    local services=(
        apache2
        nginx
        mariadb
        redis-server
        php8.2-fpm
        altcor-libreoffice
    )
    
    for service in "${services[@]}"; do
        systemctl enable "$service" || log "Предупреждение: не удалось включить $service"
        systemctl restart "$service" || log "Предупреждение: не удалось запустить $service"
    done
    
    # Настройка cron для artisan
    if [ -f "$INSTALL_DIR/Apache24/htdocs/artisan" ]; then
        (crontab -l 2>/dev/null; echo "* * * * * cd $INSTALL_DIR/Apache24/htdocs && /usr/bin/php artisan schedule:run >> /dev/null 2>&1") | crontab -
    fi
}

function create_db_config {
    local install_dir="$1"
    local config_file="$install_dir/Apache24/htdocs/db_config.php"
    
    mkdir -p "$(dirname "$config_file")"
    
    cat > "$config_file" <<EOF
<?php
define('DB_HOST', 'localhost');
define('DB_USER', 'altcor');
define('DB_PASS', '$generated_password');
define('DB_NAME', 'ALTCor');
define('DB_SOCKET', '/var/run/mysqld/mysqld.sock');
define('LIBREOFFICE_PATH', '/usr/bin/soffice');
define('UNOCONV_PATH', '/usr/bin/unoconv');
EOF

    chown www-data:www-data "$config_file"
    chmod 640 "$config_file"
}

# --- Главный процесс установки ---

# Проверка прав root
[ "$(id -u)" -ne 0 ] && error_exit "Требуются права root. Запустите скрипт с sudo!"

# Инициализация
umask 022
mkdir -p "$TEMP_DIR"
touch "$LOG_FILE"

# Диалог выбора директории
INSTALL_DIR=$(whiptail --title "Выбор папки установки" \
                      --inputbox "Укажите папку для установки AltCor:" \
                      10 60 "$DEFAULT_INSTALL_DIR" \
                      3>&1 1>&2 2>&3) || error_exit "Установка отменена"

[ -z "$INSTALL_DIR" ] && error_exit "Не указана папка установки"

# Подтверждение установки
whiptail --title "Подтверждение установки" \
         --yesno "Будут установлены:\n\n- Apache + Nginx\n- PHP 8.2\n- MariaDB\n- Redis\n- LibreOffice\n\nВ директорию: $INSTALL_DIR\n\nПродолжить?" \
         15 60 || error_exit "Установка отменена"

# Прогресс установки
{
    echo 5; install_dependencies
    echo 15; configure_libreoffice
    echo 25; stop_services
    echo 35; install_components "$INSTALL_DIR"
    echo 55; configure_apache "$INSTALL_DIR"
    echo 75; configure_mariadb
    echo 85; setup_services
    echo 95; create_db_config "$INSTALL_DIR"
    echo 100
} | whiptail --gauge "Идет установка AltCor..." 6 60 0

# Завершение
whiptail --title "Установка завершена" \
         --msgbox "AltCor успешно установлен!\n\nДоступен по адресу: http://$local_ip\n\nДанные MySQL:\n- Логин root: $generated_password\n- Логин altcor: $generated_password\n\nLibreOffice настроен как служба" \
         16 60

# Открытие в браузере
if command -v xdg-open >/dev/null; then
    xdg-open "http://$local_ip" &
fi
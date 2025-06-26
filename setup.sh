#!/bin/bash

# AltCor Installer для Ubuntu 22.04+
# Nginx + PHP + MariaDB + Redis + LibreOffice

# --- Константы ---
APP_NAME="AltCor"
APP_VERSION="1.0"
DEFAULT_INSTALL_DIR="/opt/altcor"
TEMP_DIR="/tmp/altcor_install"
LOG_FILE="/var/log/altcor_install.log"
SOURCE_DIR=$(dirname "$(realpath "$0")")/src

# --- Инициализация ---

# Сохраняем текущую конфигурацию apt
APT_CONFIG_BACKUP=$(mktemp)
grep -v '^APT::Get::' /etc/apt/apt.conf.d/* > "$APT_CONFIG_BACKUP" 2>/dev/null || true

# Устанавливаем тихий режим для apt
echo 'APT::Get::Assume-Yes "true";
APT::Get::HideAutoRemove "true";
APT::Get::Show-Upgraded "false";
APT::Get::Silent "true";
APT::Get::quiet "true";
Dpkg::Progress-Fancy "0";
Acquire::http::No-Cache "true";
Acquire::Languages "none";' > /etc/apt/apt.conf.d/99altcor-install

# --- Переменные ---
generated_password=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c12)

# --- Функции ---

function log {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

function error_exit {
    log "ОШИБКА: $1"
    whiptail --title "Ошибка установки" --msgbox "$1" 12 60
    exit 1
}

function cleanup {
    # Восстановление конфигурации apt при выходе
    if [ -f "$APT_CONFIG_BACKUP" ]; then
        cat "$APT_CONFIG_BACKUP" > /etc/apt/apt.conf.d/99altcor-install
        rm -f "$APT_CONFIG_BACKUP"
    fi
}
trap cleanup EXIT

function install_dependencies {
    log "Установка зависимостей..."
    
    # Принудительно неинтерактивный режим
    export DEBIAN_FRONTEND=noninteractive
    
    # Обновление пакетов (с таймаутом)
    timeout 5m sudo apt-get update -yq 2>&1 | tee -a "$LOG_FILE" || {
        log "Предупреждение: apt-get update занял слишком много времени. Продолжаем..."
    }
    
    # Основные пакеты
    local base_packages=(
        nginx
        mariadb-server
        redis-server
        software-properties-common
        libnss3-tools
        libfontconfig1
        libxrender1
        libxext6
        libx11-6
    )
    
    # Установка с повторением при ошибке
    for attempt in {1..3}; do
        if sudo apt-get install -yq "${base_packages[@]}" 2>&1 | tee -a "$LOG_FILE"; then
            break
        fi
        log "Попытка $attempt не удалась. Повторяем через 5 сек..."
        sleep 5
    done
    
    # Добавляем PPA только если не было ошибок
    if [ $? -eq 0 ]; then
        sudo add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1
        sudo apt-get update -yq 2>&1 | tee -a "$LOG_FILE"
    else
        error_exit "Не удалось установить базовые пакеты."
    fi
    
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
        php8.2-intl
    )
    
    sudo apt-get install -yq "${php_packages[@]}" 2>&1 | tee -a "$LOG_FILE" || {
        error_exit "Ошибка установки PHP."
    }
}

function configure_libreoffice {
    log "Настройка LibreOffice в headless режиме..."
    
    # Останавливаем все существующие процессы LibreOffice
    pkill -9 soffice 2>/dev/null || true
    
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
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable altcor-libreoffice
    systemctl start altcor-libreoffice
}

function stop_services {
    log "Остановка служб..."
    
    systemctl stop nginx mariadb redis php*-fpm altcor-libreoffice 2>/dev/null
    pkill -9 nginx mysqld redis-server php-fpm soffice 2>/dev/null
}

function install_components {
    local install_dir="$1"
    log "Установка компонентов в $install_dir..."
    
    if [ ! -d "$SOURCE_DIR" ]; then
        error_exit "Папка с исходными файлами не найдена: $SOURCE_DIR\n\nСоздайте папку 'src' рядом со скриптом и поместите туда файлы сайта."
    fi
    
    mkdir -p "$install_dir" || error_exit "Не удалось создать директорию установки"
    cp -R "$SOURCE_DIR/"* "$install_dir/" || error_exit "Ошибка копирования файлов сайта"
    
    chown -R www-data:www-data "$install_dir"
    chmod -R 755 "$install_dir"
}

function configure_nginx {
    local install_dir="$1"
    log "Настройка Nginx..."
    
    rm -f /etc/nginx/sites-enabled/default
    
    cat > /etc/nginx/sites-available/altcor <<EOF
server {
    listen 80;
    server_name localhost;
    root $install_dir;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/altcor /etc/nginx/sites-enabled/
    nginx -t || error_exit "Ошибка конфигурации Nginx"
    systemctl restart nginx
}

function configure_mariadb {
    log "Настройка MariaDB..."
    
    systemctl stop mariadb
    mysqld_safe --skip-grant-tables &
    sleep 5
    
    mysql -uroot <<EOF
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '$generated_password';
FLUSH PRIVILEGES;
EOF

    mysqladmin -uroot -p"$generated_password" shutdown
    systemctl start mariadb
    
    mysql -uroot -p"$generated_password" <<EOF
CREATE DATABASE IF NOT EXISTS altcor;
CREATE USER IF NOT EXISTS 'altcor'@'localhost' IDENTIFIED BY '$generated_password';
GRANT ALL PRIVILEGES ON altcor.* TO 'altcor'@'localhost';
FLUSH PRIVILEGES;
EOF
}

function setup_services {
    log "Настройка автозагрузки сервисов..."
    
    local services=(
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
}

function create_db_config {
    local install_dir="$1"
    local config_file="$install_dir/db_config.php"
    
    if [ -f "$install_dir/index.php" ]; then
        cat > "$config_file" <<EOF
<?php
define('DB_HOST', 'localhost');
define('DB_USER', 'altcor');
define('DB_PASS', '$generated_password');
define('DB_NAME', 'altcor');
define('DB_SOCKET', '/var/run/mysqld/mysqld.sock');
define('LIBREOFFICE_PATH', '/usr/bin/soffice');
define('UNOCONV_PATH', '/usr/bin/unoconv');
EOF

        chown www-data:www-data "$config_file"
        chmod 640 "$config_file"
    fi
}

# --- Главный процесс установки ---

[ "$(id -u)" -ne 0 ] && error_exit "Требуются права root. Запустите скрипт с sudo!"

umask 022
mkdir -p "$TEMP_DIR"
touch "$LOG_FILE"

# Красивое оформление
whiptail --title "Установка $APP_NAME" --msgbox "Добро пожаловать в установку $APP_NAME $APP_VERSION\n\nЭтот мастер установит все необходимые компоненты." 12 60

INSTALL_DIR=$(whiptail --title "Выбор папки установки" \
                      --inputbox "Укажите папку для установки $APP_NAME:" \
                      10 60 "$DEFAULT_INSTALL_DIR" \
                      3>&1 1>&2 2>&3) || error_exit "Установка отменена"

[ -z "$INSTALL_DIR" ] && error_exit "Не указана папка установки"

whiptail --title "Подтверждение установки" \
         --yesno "Будут установлены:\n\n- Nginx\n- PHP 8.2\n- MariaDB\n- Redis\n- LibreOffice (headless)\n\nВ директорию: $INSTALL_DIR\n\nПродолжить?" \
         15 60 || error_exit "Установка отменена"

{
    echo 10; install_dependencies >/dev/null 2>&1
    echo 20; configure_libreoffice >/dev/null 2>&1
    echo 30; stop_services >/dev/null 2>&1
    echo 40; install_components "$INSTALL_DIR" >/dev/null 2>&1
    echo 60; configure_nginx "$INSTALL_DIR" >/dev/null 2>&1
    echo 70; configure_mariadb >/dev/null 2>&1
    echo 80; setup_services >/dev/null 2>&1
    echo 90; create_db_config "$INSTALL_DIR" >/dev/null 2>&1
    echo 100
} | whiptail --gauge "Идет установка $APP_NAME..." 6 60 0

whiptail --title "Установка завершена" \
         --msgbox "$APP_NAME успешно установлен!\n\nДоступен по адресу: http://localhost\n\nДанные MySQL:\n- Логин root: $generated_password\n- Логин altcor: $generated_password\n\nLibreOffice работает в headless режиме\n\nПодробности в логе: $LOG_FILE" \
         16 60
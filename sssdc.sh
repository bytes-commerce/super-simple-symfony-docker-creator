#!/usr/bin/env bash

# ----------------------------------------------------------------------------
# Symfony Docker Creator
# A simple, intuitive, and robust script to spin up Symfony with Docker
# ----------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# Default configuration
WEBSERVER=apache          # "apache" or "nginx"
PHP_IMAGE="php:apache"   # Must match FPM variant for nginx
DOMAIN="www.symfony.local"
HTTP_PORT=1337
HTTPS_PORT=1338
DB_PORT=5555
DB_IMAGE="mariadb:11.2.2"
SYMFONY_VERSION="^7.2"
XDEBUG_ENABLED=true
FORCE=false

# Paths
SCRIPT_NAME="${0##*/}"
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
DOCKER_DIR="./docker"
SRC_DIR="./src"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  echo "[INFO] $*"
}

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]
Options:
  --webserver <apache|nginx>   Webserver (default: $WEBSERVER)
  --php <image>               PHP Docker image (default: $PHP_IMAGE)
  --domain <domain>           Local domain (default: $DOMAIN)
  --port-http <port>          HTTP port mapping (default: $HTTP_PORT)
  --port-https <port>         HTTPS port mapping (default: $HTTPS_PORT)
  --db-port <port>            Database port mapping (default: $DB_PORT)
  --db-image <image>          Database image (default: $DB_IMAGE)
  --symfony <version>         Symfony version (default: $SYMFONY_VERSION)
  --[no-]xdebug               Enable or disable Xdebug (default: enabled)
  --force                     Overwrite existing project files
  --install                   Install script to /usr/local/bin
  --update                    Self-update from GitHub
  -h, --help                  Show this help and exit
EOF
  exit 1
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
while (( "$#" )); do
  case "$1" in
    --webserver)   shift; WEBSERVER=${1,,} ;;  # lowercase
    --php)         shift; PHP_IMAGE=$1 ;;
    --domain)      shift; DOMAIN=$1 ;;
    --port-http)   shift; HTTP_PORT=$1 ;;
    --port-https)  shift; HTTPS_PORT=$1 ;;
    --db-port)     shift; DB_PORT=$1 ;;
    --db-image)    shift; DB_IMAGE=$1 ;;
    --symfony)     shift; SYMFONY_VERSION=$1 ;;
    --xdebug)      XDEBUG_ENABLED=true ;;
    --no-xdebug)   XDEBUG_ENABLED=false ;;
    --force)       FORCE=true ;;
    --install)     INSTALL=true ;;
    --update)      UPDATE=true ;;
    -h|--help)     usage ;;
    *)             die "Unknown option: $1" ;;
  esac
  shift
done

# ----------------------------------------------------------------------------
# Self-install or update
# ----------------------------------------------------------------------------
GITHUB_RAW_URL="https://raw.githubusercontent.com/bytes-commerce/super-simple-symfony-docker-creator/master/sssdc.sh"
if [ "${INSTALL:-false}" = true ]; then
  sudo install -m 0755 "$SCRIPT_PATH" /usr/local/bin/symfony-docker-creator
  log "Installed as /usr/local/bin/symfony-docker-creator"
  exit 0
fi

if [ "${UPDATE:-false}" = true ]; then
  curl -fsSL "$GITHUB_RAW_URL" -o "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
  log "Updated script from GitHub"
  exit 0
fi

# ----------------------------------------------------------------------------
# Prerequisites
# ----------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "Docker is required."
command -v docker-compose >/dev/null 2>&1 || log "Using 'docker compose' subcommand"

# ----------------------------------------------------------------------------
# Clean or initialize project structure
# ----------------------------------------------------------------------------
if [ -f docker-compose.yml ] || [ -d "$SRC_DIR" ]; then
  if [ "$FORCE" = true ]; then
    log "Removing existing project files..."
    rm -rf docker-compose.yml "$DOCKER_DIR" "$SRC_DIR"
  else
    die "Project already initialized. Use --force to overwrite."
  fi
fi

# Create directories
mkdir -p "$DOCKER_DIR/php/etc" "$SRC_DIR"

# ----------------------------------------------------------------------------
# Generate SSL certificates
# ----------------------------------------------------------------------------
generate_ssl() {
  echo "Generating SSL certificates..."
  local cert_dir="$1"
  local name="$2"
  mkdir -p "$cert_dir"
  openssl req -x509 -nodes -days 365 \
    -subj "/C=DE/ST=Berlin/O=Local/CN=$DOMAIN" \
    -addext "subjectAltName=DNS:$DOMAIN" \
    -newkey rsa:4096 \
    -keyout "$cert_dir/${name}.key" \
    -out "$cert_dir/${name}.crt"
}

# ----------------------------------------------------------------------------
# Dockerfile for PHP
# ----------------------------------------------------------------------------
cat > "$DOCKER_DIR/php/Dockerfile" <<EOF
FROM $PHP_IMAGE

# Common env
ENV APP_ENV=dev
ENV TZ=Europe/Berlin
ENV PHP_IDE_CONFIG="serverName=$DOMAIN"
ENV XDEBUG_CONFIG="client_host=host.docker.internal"

# Install packages & extensions
RUN apt-get update && apt-get install -y --no-install-recommends \
    git vim gpg gpg-agent zlib1g-dev libicu-dev \
    libpng-dev libjpeg62-turbo-dev libfreetype6-dev \
    zip libzip-dev unzip dnsutils curl openssl \
  && docker-php-ext-configure gd --with-jpeg --with-freetype \
  && docker-php-ext-install pdo_mysql intl zip exif calendar bcmath pcntl gd opcache \
  && pecl install apcu \
  && docker-php-ext-enable apcu \
  && apt-get purge -y zlib1g-dev libicu-dev libpng-dev libfreetype6-dev libjpeg62-turbo-dev \
  && rm -rf /var/lib/apt/lists/*

# Xdebug if enabled
EOF
if [ "$XDEBUG_ENABLED" = true ]; then
  cat >> "$DOCKER_DIR/php/Dockerfile" <<EOF
RUN pecl install xdebug \
  && docker-php-ext-enable xdebug
EOF
fi
cat >> "$DOCKER_DIR/php/Dockerfile" <<EOF

# Enable Apache modules
RUN a2enmod rewrite headers ssl socache_shmcb

# Copy Apache vhost configuration
COPY etc/apache.conf /etc/apache2/sites-enabled/000-default.conf

# Composer
COPY --from=composer:latest /usr/bin/composer /usr/local/bin/composer

WORKDIR /var/www/html

# SSL certificates (self-signed)
RUN mkdir -p /etc/ssl/private /etc/ssl/certs
EOF
# Generate cert for PHP (apache)
generate_ssl "$DOCKER_DIR/php" "selfsigned"
cat >> "$DOCKER_DIR/php/Dockerfile" <<EOF
# Copy generated certs
COPY selfsigned.crt /etc/ssl/certs/selfsigned.crt
COPY selfsigned.key /etc/ssl/private/selfsigned.key

EXPOSE 80 443

CMD ["apache2-foreground"]
EOF

# ----------------------------------------------------------------------------
# Dockerfile and config for webserver (nginx only)
# ----------------------------------------------------------------------------
if [ "$WEBSERVER" = "nginx" ]; then
  [[ "$PHP_IMAGE" == *fpm* ]] || die "NGINX requires a PHP-FPM image."
  mkdir -p "$DOCKER_DIR/webserver/conf.d"
  cat > "$DOCKER_DIR/webserver/Dockerfile" <<EOF
FROM nginx:latest

RUN apt-get update && apt-get install -y openssl \
  && rm -rf /var/lib/apt/lists/*

# SSL
RUN mkdir -p /etc/ssl/private /etc/ssl/certs
EOF
  generate_ssl "$DOCKER_DIR/webserver" "nginx-selfsigned"
  cat >> "$DOCKER_DIR/webserver/Dockerfile" <<EOF
COPY ./nginx-selfsigned.crt /etc/ssl/certs/nginx-selfsigned.crt
COPY ./nginx-selfsigned.key /etc/ssl/private/nginx-selfsigned.key

COPY ./conf.d/default.conf /etc/nginx/conf.d/default.conf

EXPOSE 80 443
CMD ["nginx", "-g", "daemon off;"]
EOF

  cat > "$DOCKER_DIR/webserver/conf.d/default.conf" <<EOF
upstream php-fpm { server php:9000; }

server {
  listen 80;
  listen 443 ssl http2;
  server_name $DOMAIN;
  root /var/www/html/public;

  ssl_certificate     /etc/ssl/certs/nginx-selfsigned.crt;
  ssl_certificate_key /etc/ssl/private/nginx-selfsigned.key;

  location / {
    try_files \$uri /index.php\$is_args\$args;
  }

  location ~ ^/index\\.php(/|$) {
    fastcgi_pass php-fpm;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    internal;
  }

  error_log /var/log/nginx/error.log;
  access_log /var/log/nginx/access.log;
}
EOF
fi

# ----------------------------------------------------------------------------
# Dockerfile and config for webserver (nginx only)
# ----------------------------------------------------------------------------
if [ "$WEBSERVER" = "nginx" ]; then
  # Ensure FPM image
  [[ "$PHP_IMAGE" == *fpm* ]] || die "NGINX requires a PHP-FPM image."
  cat > "$DOCKER_DIR/webserver/Dockerfile" <<EOF
FROM nginx:latest

RUN apt-get update && apt-get install -y openssl \
  && rm -rf /var/lib/apt/lists/*

# SSL
RUN mkdir -p /etc/ssl/private /etc/ssl/certs
EOF
  generate_ssl "$DOCKER_DIR/webserver" "nginx-selfsigned"
  cat >> "$DOCKER_DIR/webserver/Dockerfile" <<EOF
COPY ./nginx-selfsigned.crt /etc/ssl/certs/nginx-selfsigned.crt
COPY ./nginx-selfsigned.key /etc/ssl/private/nginx-selfsigned.key

COPY ./conf.d/default.conf /etc/nginx/conf.d/default.conf

EXPOSE 80 443
CMD ["nginx", "-g", "daemon off;"]
EOF

  # Default site
  cat > "$DOCKER_DIR/webserver/conf.d/default.conf" <<EOF
upstream php-fpm { server php:9000; }

server {
  listen 80;
  listen 443 ssl http2;
  server_name $DOMAIN;
  root /var/www/html/public;

  ssl_certificate     /etc/ssl/certs/nginx-selfsigned.crt;
  ssl_certificate_key /etc/ssl/private/nginx-selfsigned.key;

  location / {
    try_files \$uri /index.php\$is_args\$args;
  }

  location ~ ^/index\.php(/|$) {
    fastcgi_pass php-fpm;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    internal;
  }

  error_log /var/log/nginx/error.log;
  access_log /var/log/nginx/access.log;
}
EOF
fi

# ----------------------------------------------------------------------------
# Apache config (inside PHP image)
# ----------------------------------------------------------------------------
if [ "$WEBSERVER" = "apache" ]; then
  cat > "$DOCKER_DIR/php/etc/apache.conf" <<EOF
<VirtualHost *:80>
  ServerName $DOMAIN
  DocumentRoot /var/www/html/public
  <Directory /var/www/html/public>
    AllowOverride All
    Require all granted
  </Directory>
</VirtualHost>

<VirtualHost *:443>
  ServerName $DOMAIN
  DocumentRoot /var/www/html/public
  SSLEngine on
  SSLCertificateFile /etc/ssl/certs/selfsigned.crt
  SSLCertificateKeyFile /etc/ssl/private/selfsigned.key
  Header always set Strict-Transport-Security "max-age=15768000"
</VirtualHost>
EOF
fi

# ----------------------------------------------------------------------------
# Generate docker-compose.yml
# ----------------------------------------------------------------------------
cat > docker-compose.yml <<EOF
services:
  php:
    build:
      context: ./docker/php
    volumes:
      - ./src:/var/www/html
    ports:
      - "$HTTP_PORT:80"
      - "$HTTPS_PORT:443"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    restart: always
    environment:
      - APP_ENV=dev
      - APP_DEBUG=1
      - XDEBUG_CONFIG="client_host=host.docker.internal"
      - PHP_IDE_CONFIG="serverName=$DOMAIN"
EOF

if [ "$WEBSERVER" = "nginx" ]; then
  cat >> docker-compose.yml <<EOF
  web:
    build:
      context: ./docker/webserver
    depends_on:
      - php
    ports:
      - "$HTTP_PORT:80"
      - "$HTTPS_PORT:443"
    restart: always
EOF
fi

cat >> docker-compose.yml <<EOF
  database:
    image: $DB_IMAGE
    environment:
      MYSQL_ROOT_PASSWORD: database
      MYSQL_DATABASE: database
      MYSQL_USER: database
      MYSQL_PASSWORD: database
    ports:
      - "$DB_PORT:3306"
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      retries: 5

  mailer:
    image: schickling/mailcatcher
    ports:
      - "1380:1080"
      - "1325:1025"
EOF

# ----------------------------------------------------------------------------
# PHP ini
# ----------------------------------------------------------------------------
cat > "$DOCKER_DIR/php/etc/php.ini" <<EOF
[PHP]
memory_limit = 2G
upload_max_filesize = 512M
post_max_size = 512M
max_execution_time = 300
error_reporting = E_ALL
display_errors = On
date.timezone = "Europe/Berlin"
EOF

# ----------------------------------------------------------------------------
# Bootstrap Symfony
# ----------------------------------------------------------------------------
docker compose down -v
COMPOSE_BAKE=true docker compose build --pull
docker compose stop
docker compose up -d

log "Waiting for web service to be healthy..."
sleep 5

# Create Symfony skeleton
if ! curl -fs "http://localhost:$HTTP_PORT" | grep -q "Welcome to Symfony"; then
  log "Installing Symfony $SYMFONY_VERSION..."
  docker compose exec php bash -lc \
    "composer create-project symfony/skeleton:$SYMFONY_VERSION . --no-interaction"
  log "Installing common packages"
  docker compose exec php bash -lc \
    "composer require webmozart/assert symfony/apache-pack symfony/security-bundle symfony/uid symfony/translation symfony/config symfony/web-link symfony/yaml twig/extra-bundle easycorp/easyadmin-bundle --no-interaction"
  log "Installing Dev packages"
  docker compose exec php bash -lc \
    "composer require symfony/maker-bundle phpunit/phpunit phpstan/phpstan phpstan/phpstan-webmozart-assert symplify/easy-coding-standard symfony/web-profiler-bundle symfony/debug-bundle doctrine/doctrine-fixtures-bundle seec/phpunit-consecutive-params --dev --no-interaction"
fi

echo "Symfony Docker setup complete! Browse to https://localhost:$HTTPS_PORT"

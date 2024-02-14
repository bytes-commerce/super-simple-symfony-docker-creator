#!/usr/bin/env bash

set -e

_self="${0##*/}"

function usage() {
  echo "Usage: symfony-docker-creator [options]"
  echo "Options:"
  echo "  --webserver <webserver>  The webserver to use. Default is apache."
  echo "  --php <php>              The PHP image to use. Default is php:apache."
  echo "  --port <port>            The port to use for the webserver. Default is 1337."
  echo "  --port-https <port>      The port to use for the webserver. Default is 1338."
  echo "  --database <database>    The database to use. Default is mariadb:11.2.2."
  echo "  --domain <domain>        The domain to use. Default is www.symfony.local."
  echo "  --xdebug                 Enable xdebug. Default is true."
  echo "  --symfony <version>      The Symfony version to use. Default is 7.0.*."
  echo "  --force                  Force deletion of existing files."
  echo "  --install                Install this script to /usr/local/bin. Execute with sudo!."
  exit 1
}

webserver="apache"
php="php:apache"
domain="www.symfony.local"
port_http=1337
port_https=1338
database=mariadb:11.2.2
force=false
xdebug=true
symfony="7.0.*"

# Check if Docker Compose is installed
if ! command -v docker &> /dev/null
then
    echo "docker could not be found. Please install Docker first."
    exit 1
fi

scriptDir=$(realpath $(dirname $0))
shaExisting=sha256sum $scriptDir/$_self

echo $scriptDir/$_self
echo shaExisting


while [ "$#" -gt 0 ]; do
    case "$1" in
        --webserver)
            webserver="$2"
            shift 2
            ;;
        --php)
            php="$2"
            shift 2
            ;;
        --port)
            port_http="$2"
            shift 2
            ;;
        --port-https)
          port_https="$2"
          shift 2
          ;;
        --database)
          database="$2"
          shift 2
          ;;
        --domain)
            domain="$2"
            shift 2
            ;;
        --xdebug)
            xdebug=true
            shift 1
            ;;
        --symfony)
            symfony="$2"
            shift 2
            ;;
        --force)
            force=true
            shift 1
            ;;
        --install)
            sudo chmod +x sssdc.sh
            sudo cp sssdc.sh /usr/local/bin/symfony-docker-creator
            echo "Installed. You can use this script with symfony-docker-creator now."
            exit 1
            ;;
        *)
            usage
            ;;
    esac
done


generate_docker_compose() {
    local port_mapping=$port_mapping
    local forceDeletion=$force
    local localDomain=$domain

    if [ $forceDeletion == true ]; then
        rm -rf docker-compose.yml ./docker/php ./docker/webserver ./src ./src/.*
    fi

    if [ -f "docker-compose.yml" ]; then
        echo "Project seems initialized! Please use --force to overwrite all existing files in this directory with a fresh copy."
        exit 1
    fi
    if [ -f "src/public/index.php" ]; then
        echo "Project seems initialized! Please use --force to overwrite all existing files in this directory with a fresh copy."
        exit 1
    fi


    mkdir -p ./docker/php/etc
    touch ./docker/php/Dockerfile
    touch ./docker/php/etc/php.ini


echo "Creating PHP Dockerfile"
cat <<EOF >> ./docker/php/Dockerfile
FROM $php

ENV PHP_IDE_CONFIG="serverName=website"
ENV BASE_DIR /var/www
ENV SYMFONY_DIR \${BASE_DIR}/html

RUN docker-php-ext-install pdo_mysql
RUN pecl install apcu
RUN pecl install xdebug \\
    && docker-php-ext-enable xdebug

RUN apt-get update && apt-get install -y --no-install-recommends \\
    git \\
    vim \\
    gpg \\
    gpg-agent \\
    zlib1g-dev \\
    libjpeg-dev \\
    libicu-dev \\
		libpng-dev \\
		libfreetype6-dev \\
		libjpeg62-turbo-dev \\
    zip \\
		libzip-dev \\
    unzip \\
    dnsutils \\
    curl \\
    openssl

RUN docker-php-ext-enable opcache
RUN docker-php-ext-configure zip
RUN docker-php-ext-install \\
    intl \\
    zip \\
		exif \\
		pdo \\
		pdo_mysql \\
    calendar \\
    bcmath \\
    pcntl

RUN docker-php-ext-configure gd \\
    --with-jpeg=/usr/include/ \\
    --with-freetype=/usr/include/

RUN docker-php-ext-install gd

RUN apt-get purge -y \\
		zlib1g-dev \\
		libicu-dev \\
		libpng-dev \\
		libfreetype6-dev \\
		libjpeg62-turbo-dev \\
		libmcrypt-dev

ADD ./etc/php.ini /usr/local/etc/php/php.ini

COPY --from=composer:latest /usr/bin/composer /usr/local/bin/composer

RUN usermod -u 1000 www-data
RUN mkdir /.composer && chown -R 1000:1000 /.composer && chmod 775 /.composer
RUN export PATH="\$PATH:\${SYMFONY_DIR}/vendor/bin:bin"
RUN export PATH="\$PATH:\${SYMFONY_DIR}/bin:bin"
RUN export PATH="\$PATH:/.composer/vendor/bin"

WORKDIR \${SYMFONY_DIR}
RUN chown -R www-data:1000 \${BASE_DIR}
EOF

    touch docker-compose.yml
    echo "version: '3.9'" >> docker-compose.yml
    echo "" >> docker-compose.yml
    echo "services:" >> docker-compose.yml

    if [ -n "$webserver" ]; then

        mkdir -p ./docker/webserver/conf.d

        if [[ "$webserver" == *"nginx"* ]]; then
          if [[ $php != *"fpm"* ]]; then
              echo "The webserver is set to $webserver, so the php image must contain fpm."
              exit 1
          fi
          cat <<EOF >> docker-compose.yml
    php:
      build: ./docker/php
      volumes:
          - ./src:/var/www/html
      extra_hosts:
        - "host.docker.internal:host-gateway"
      restart: on-failure

    webserver:
      build: ./docker/webserver
      ports:
          - "$port_http:80"
          - "$port_https:443"
      volumes:
          - ./docker/webserver/conf.d/:/etc/nginx/conf.d/
          - ./src:/var/www/html
      restart: always
EOF

          cat <<EOF >> ./docker/webserver/Dockerfile
FROM $webserver

RUN apk add --no-cache openssl nano git curl bash

RUN openssl req -x509 \\
  -nodes \\
  -days 365 \\
  -subj "/C=CA/ST=QC/O=Company, Inc./CN=$localDomain" \\
  -addext "subjectAltName=DNS:$localDomain" \\
  -newkey rsa:4096 \\
  -keyout /etc/ssl/private/nginx-selfsigned.key \\
  -out /etc/ssl/certs/nginx-selfsigned.crt;

COPY ./conf.d/default.conf /etc/nginx/conf.d/default.conf
RUN rm -rf /etc/nginx/mime.types
COPY ./mime.types /etc/nginx/mime.types

CMD ["nginx", "-g", "daemon off;"]
EOF
          cat <<EOF >> ./docker/webserver/mime.types
types {
    text/html                                        html htm shtml;
    text/css                                         css;
    text/xml                                         xml;
    image/gif                                        gif;
    image/jpeg                                       jpeg jpg;
    application/javascript                           mjs js;
    application/atom+xml                             atom;
    application/rss+xml                              rss;

    text/mathml                                      mml;
    text/plain                                       txt;
    text/vnd.sun.j2me.app-descriptor                 jad;
    text/vnd.wap.wml                                 wml;
    text/x-component                                 htc;

    image/png                                        png;
    image/svg+xml                                    svg svgz;
    image/tiff                                       tif tiff;
    image/vnd.wap.wbmp                               wbmp;
    image/webp                                       webp;
    image/x-icon                                     ico;
    image/x-jng                                      jng;
    image/x-ms-bmp                                   bmp;

    font/woff                                        woff;
    font/woff2                                       woff2;

    application/java-archive                         jar war ear;
    application/json                                 json;
    application/mac-binhex40                         hqx;
    application/msword                               doc;
    application/pdf                                  pdf;
    application/postscript                           ps eps ai;
    application/rtf                                  rtf;
    application/vnd.apple.mpegurl                    m3u8;
    application/vnd.google-earth.kml+xml             kml;
    application/vnd.google-earth.kmz                 kmz;
    application/vnd.ms-excel                         xls;
    application/vnd.ms-fontobject                    eot;
    application/vnd.ms-powerpoint                    ppt;
    application/vnd.oasis.opendocument.graphics      odg;
    application/vnd.oasis.opendocument.presentation  odp;
    application/vnd.oasis.opendocument.spreadsheet   ods;
    application/vnd.oasis.opendocument.text          odt;
    application/vnd.openxmlformats-officedocument.presentationml.presentation
                                                     pptx;
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
                                                     xlsx;
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
                                                     docx;
    application/vnd.wap.wmlc                         wmlc;
    application/x-7z-compressed                      7z;
    application/x-cocoa                              cco;
    application/x-java-archive-diff                  jardiff;
    application/x-java-jnlp-file                     jnlp;
    application/x-makeself                           run;
    application/x-perl                               pl pm;
    application/x-pilot                              prc pdb;
    application/x-rar-compressed                     rar;
    application/x-redhat-package-manager             rpm;
    application/x-sea                                sea;
    application/x-shockwave-flash                    swf;
    application/x-stuffit                            sit;
    application/x-tcl                                tcl tk;
    application/x-x509-ca-cert                       der pem crt;
    application/x-xpinstall                          xpi;
    application/xhtml+xml                            xhtml;
    application/xspf+xml                             xspf;
    application/zip                                  zip;

    application/octet-stream                         bin exe dll;
    application/octet-stream                         deb;
    application/octet-stream                         dmg;
    application/octet-stream                         iso img;
    application/octet-stream                         msi msp msm;

    audio/midi                                       mid midi kar;
    audio/mpeg                                       mp3;
    audio/ogg                                        ogg;
    audio/x-m4a                                      m4a;
    audio/x-realaudio                                ra;

    video/3gpp                                       3gpp 3gp;
    video/mp2t                                       ts;
    video/mp4                                        mp4;
    video/mpeg                                       mpeg mpg;
    video/quicktime                                  mov;
    video/webm                                       webm;
    video/x-flv                                      flv;
    video/x-m4v                                      m4v;
    video/x-mng                                      mng;
    video/x-ms-asf                                   asx asf;
    video/x-ms-wmv                                   wmv;
    video/x-msvideo                                  avi;
}
EOF

          cat <<EOF >> ./docker/webserver/conf.d/default.conf
upstream php {
    server php:9000;
}

server {
    listen 80 default_server;
    listen 443 ssl http2 default_server;
    ssl_certificate /etc/ssl/certs/nginx-selfsigned.crt;
    ssl_certificate_key /etc/ssl/private/nginx-selfsigned.key;
    server_name $localDomain;
    root /var/www/html/public;

    gzip on;
    gzip_vary on;
    gzip_min_length 10240;
    gzip_proxied expired no-cache no-store private auth;
    gzip_types application/octet-stream text/plain text/css text/xml text/javascript application/x-javascript application/xml application/javascript;
    gzip_disable "MSIE [1-6]\.";
    client_max_body_size 16M;

    proxy_read_timeout 36000;
    proxy_connect_timeout 36000;
    proxy_send_timeout 36000;

    location / {
        root /var/www/html/public;
        try_files \$uri /index.php\$is_args\$args;
    }

    location ~ ^/index\\.php(/|$) {
        fastcgi_pass php;
        fastcgi_split_path_info ^(.+\\.php)(/.*)$;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT \$realpath_root;
        internal;
    }

     location ~ \\.php$ {
        return 404;
    }

    error_log /dev/stderr debug;
    access_log /dev/stdout;
}

EOF
        fi

        if [[ "$webserver" == *"apache"* ]]; then
          mkdir -p ./docker/php/etc/
          touch ./docker/php/etc/apache.conf
          cat <<EOF >> ./docker/php/etc/apache.conf
SetEnvIf X-Forwarded-Proto https HTTPS=on
<VirtualHost *:80>
        ServerName $localDomain
        ServerAdmin admin@localhost
        DocumentRoot /var/www/html/public
        SetEnvIf Authorization "(.*)" HTTP_AUTHORIZATION=\$1

        <Directory /var/www/html/public>
            AllowOverride None
            Order Allow,Deny
            Allow from All
            <IfModule mod_rewrite.c>
                RewriteEngine On
                RewriteCond %{REQUEST_FILENAME} !-f
                RewriteRule ^(.*)$ index.php [QSA,L]
            </IfModule>
        </Directory>

        ErrorLog ${APACHE_LOG_DIR}/error.log
        CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
<VirtualHost *:443>
    ServerName $localDomain
    RewriteEngine on
    RewriteCond %{HTTP:Authorization} ^(.*)
    RewriteRule .* - [e=HTTP_AUTHORIZATION:%1]
    DocumentRoot /var/www/html/public
    SSLEngine on
    SSLCertificateFile /etc/ssl/certs/selfsigned.crt
    SSLCertificateKeyFile /etc/ssl/certs/selfsigned.key
    RequestHeader set X-Forwarded-Proto "https"
    Header always set Strict-Transport-Security "max-age=15768000"
</VirtualHost>

SSLProtocol all -SSLv3
SSLCipherSuite ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA:ECDHE-RSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-RSA-AES256-SHA256:DHE-RSA-AES256-SHA:ECDHE-ECDSA-DES-CBC3-SHA:ECDHE-RSA-DES-CBC3-SHA:EDH-RSA-DES-CBC3-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA256:AES256-SHA256:AES128-SHA:AES256-SHA:DES-CBC3-SHA:!DSS
SSLHonorCipherOrder on
SSLUseStapling on
SSLStaplingResponderTimeout 5
SSLStaplingReturnResponderErrors off
SSLStaplingCache shmcb:/var/run/ocsp(128000)
EOF
          cat <<EOF >> ./docker/php/Dockerfile
RUN openssl req -x509 \\
  -nodes \\
  -days 365 \\
  -subj "/C=CA/ST=QC/O=Company, Inc./CN=$localDomain" \\
  -addext "subjectAltName=DNS:$localDomain" \\
  -newkey rsa:4096 \\
  -sha256 \\
  -keyout /etc/ssl/certs/selfsigned.key \\
  -out /etc/ssl/certs/selfsigned.crt;

COPY ./etc/apache.conf /etc/apache2/sites-enabled/000-default.conf
ENV USERNAME=www-data
ENV GROUPNAME=www-data
RUN groupmod -g 1000 www-data
RUN a2enmod rewrite \\
  && a2enmod headers \\
  && a2enmod socache_shmcb
EOF
          cat <<EOF >> docker-compose.yml
    php:
      build: ./docker/php
      volumes:
          - ./src:/var/www/html
      extra_hosts:
        - "host.docker.internal:host-gateway"
      ports:
        - "$port_http:80"
        - "$port_https:443"
      restart: always
EOF
        # remove the webserver folder, its not going to be used in the apache package.
        rm -rf ./docker/webserver
        fi
    fi

cat <<EOF >> ./docker/php/etc/php.ini
magic_quotes_gpc = Off;
register_globals = Off;
file_uploads = On;
default_charset	= UTF-8;
memory_limit = 4G;
max_execution_time = 36000;
upload_max_filesize = 999M;
post_max_size = 999M;
safe_mode = Off;
mysql.connect_timeout = 20;
allow_url_fopen = true;
display_errors = 1;
error_reporting = E_ALL;
date.timezone = "Europe/Berlin"
pm.max_children = 25
EOF

if [[ "$xdebug" == true ]]; then
    cat <<EOF >> ./docker/php/etc/php.ini
    xdebug.idekey=PHPSTORM
    xdebug.max_nesting_level = 2048
    xdebug.mode=debug
    xdebug.client_port=9000
    xdebug.client_host=host.docker.internal
    xdebug.start_with_request=yes
    xdebug.discover_client_host=0
    xdebug.show_error_trace=1
EOF
fi
    cat <<EOF >> docker-compose.yml

    database:
        image: $database
        environment:
            MYSQL_ROOT_PASSWORD: root
            MYSQL_DATABASE: root
            MYSQL_USER: root
            MYSQL_PASSWORD: root
        ports:
            - "1336:3306"
        restart: always
        healthcheck:
          test: "/usr/bin/mysql --user=$MYSQL_USER --password=$MYSQL_PASSWORD --execute \"SHOW databases;\""
          timeout: 5s
          interval: 5s
          retries: 12

    mailer:
      image: schickling/mailcatcher
      ports:
        - "1380:1080"
        - "1325:1025"

EOF

mkdir -p src/public
touch src/public/index.php
cat <<EOF > src/public/index.php
<?php
echo "Setup okay, installing Symfony now.";
EOF

docker compose down
docker compose build
docker compose up -d
sleep 3
curl -s http://localhost:"$port_http" | grep "Setup okay, installing Symfony now." || (echo "The curl request to localhost did not return the expected response. Something went wrong." && exit 1)
rm -rf src/public/index.php
docker compose exec php bash -c "yes | composer create-project symfony/skeleton:$symfony dummy && mv dummy/* ./ && mv dummy/.* ./ && rm -rf dummy"
docker compose exec php bash -c "yes | composer require symfony/apache-pack symfony/security-bundle symfony/uid symfony/translation symfony/config symfony/web-link symfony/yaml twig/extra-bundle "
docker compose exec php bash -c "yes | composer require symfony/maker-bundle webmozart/assert phpunit/phpunit phpstan/phpstan phpstan/phpstan-webmozart-assert symplify/easy-coding-standard symfony/web-profiler-bundle symfony/debug-bundle doctrine/doctrine-fixtures-bundle seec/phpunit-consecutive-params --dev"
docker compose exec php bash -c "chown -R 1000:1000 ."
}

generate_docker_compose

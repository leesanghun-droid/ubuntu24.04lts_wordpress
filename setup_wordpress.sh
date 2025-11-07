#!/usr/bin/env bash
set -euo pipefail

umask 022

# --------- Defaults ---------
SITE_DIR="showdeck"
DB_NAME="wpdb"
DB_USER="wpuser"
DB_PASS=""
DOMAIN="_"
ADMIN_EMAIL=""
WANT_SSL=0

# --------- Parse Args ---------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site) SITE_DIR="$2"; shift 2;;
    --db-name) DB_NAME="$2"; shift 2;;
    --db-user) DB_USER="$2"; shift 2;;
    --db-pass) DB_PASS="$2"; shift 2;;
    --domain) DOMAIN="$2"; shift 2;;
    --ssl) WANT_SSL=1; shift;;
    --email) ADMIN_EMAIL="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

log() { echo -e "\033[1;32m==>\033[0m $*"; }
die(){ echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "sudo 로 실행해주세요."

[[ -z "$DB_PASS" ]] && DB_PASS="$(tr -dc 'A-Za-z0-9!@#$%^&*()-_=+' </dev/urandom | head -c 16)"

# --------- System Setup ---------
log "시스템 업데이트"
apt update
DEBIAN_FRONTEND=noninteractive apt -y upgrade
apt -y install unzip curl wget ufw nginx mariadb-server php-fpm php-mysql php-xml php-curl php-zip php-mbstring php-gd php-intl

log "방화벽 설정"
ufw allow OpenSSH || true
ufw allow 80 || true
ufw allow 443 || true
ufw --force enable || true

log "PHP-FPM 소켓 자동 탐색"
PHP_SOCK="$(ls /run/php/php*-fpm.sock | head -n 1)"

log "DB / 계정 생성"
mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
DROP USER IF EXISTS '${DB_USER}'@'localhost';
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

log "DB 연결 테스트 → DB_HOST 결정"
if mysql -h 127.0.0.1 -u "$DB_USER" -p"$DB_PASS" -e "SELECT 1" >/dev/null 2>&1; then
  DB_HOST="127.0.0.1"
else
  DB_HOST="localhost"
fi
log "선택된 DB_HOST: $DB_HOST"

log "워드프레스 다운로드"
mkdir -p /var/www
cd /var/www
if [[ ! -d "$SITE_DIR" ]]; then
  curl -LO https://wordpress.org/latest.zip
  unzip -q latest.zip
  rm -f latest.zip
  mv wordpress "$SITE_DIR"
fi

log "권한 설정"
chown -R www-data:www-data "/var/www/${SITE_DIR}"
find "/var/www/${SITE_DIR}" -type d -exec chmod 755 {} \;
find "/var/www/${SITE_DIR}" -type f -exec chmod 644 {} \;
install -d -o www-data -g www-data -m 775 "/var/www/${SITE_DIR}/wp-content/uploads"

log "Nginx 서버 블록 생성"
NGINX_AVAIL="/etc/nginx/sites-available/${SITE_DIR}"

cat > "$NGINX_AVAIL" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    root /var/www/${SITE_DIR};
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
    }
}
EOF

ln -sfn "$NGINX_AVAIL" "/etc/nginx/sites-enabled/${SITE_DIR}"
rm -f /etc/nginx/sites-enabled/default || true
nginx -t && systemctl reload nginx

log "wp-config.php 설정"
cd "/var/www/${SITE_DIR}"
[[ -f wp-config.php ]] || cp wp-config-sample.php wp-config.php

sed -i "s/define( 'DB_NAME'.*/define( 'DB_NAME', '${DB_NAME}' );/" wp-config.php
sed -i "s/define( 'DB_USER'.*/define( 'DB_USER', '${DB_USER}' );/" wp-config.php
sed -i "s/define( 'DB_PASSWORD'.*/define( 'DB_PASSWORD', '${DB_PASS}' );/" wp-config.php
sed -i "s/define( 'DB_HOST'.*/define( 'DB_HOST', '${DB_HOST}' );/" wp-config.php

curl -s https://api.wordpress.org/secret-key/1.1/salt/ >> wp-config.php

echo "define('FS_METHOD', 'direct');" >> wp-config.php

chown www-data:www-data wp-config.php
chmod 640 wp-config.php

# ---- Optional SSL ----
if [[ $WANT_SSL -eq 1 ]]; then
  [[ -z "$ADMIN_EMAIL" ]] && die "--ssl 사용 시 --email <이메일> 필요"
  apt -y install certbot python3-certbot-nginx
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL"
fi

PUB_IP="$(curl -s ifconfig.me)"
log "설치 완료!"
echo "-----------------------------------------"
echo "접속: http://${DOMAIN:-$PUB_IP}/"
echo "사이트 경로: /var/www/${SITE_DIR}"
echo "DB: $DB_NAME / $DB_USER / $DB_PASS"
echo "-----------------------------------------"

#!/usr/bin/env bash
set -euo pipefail

# === Defaults (변경 가능) ===
SITE_DIR="showdeck"
DB_NAME="wpdb"
DB_USER="wpuser"
DB_PASS=""         # --db-pass 로 넘기거나 실행 중 입력
DOMAIN="_"         # nginx server_name (도메인 없으면 _)
PHP_SOCK="/run/php/php8.3-fpm.sock"

# === Args ===
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site)      SITE_DIR="${2}"; shift 2;;
    --db-name)   DB_NAME="${2}"; shift 2;;
    --db-user)   DB_USER="${2}"; shift 2;;
    --db-pass)   DB_PASS="${2}"; shift 2;;
    --domain)    DOMAIN="${2}"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

if [[ -z "${DB_PASS}" ]]; then
  read -rsp "DB 비밀번호 입력(화면 표시 안됨): " DB_PASS
  echo
fi

echo "==> 시스템 업데이트 & 기본 도구"
sudo apt update
sudo apt -y upgrade
sudo apt -y install unzip curl htop git ufw

echo "==> 방화벽(UFW) 설정"
sudo ufw allow OpenSSH
sudo ufw allow 80
sudo ufw allow 443
echo "y" | sudo ufw enable || true
sudo ufw status || true

echo "==> Nginx 설치"
sudo apt -y install nginx
sudo systemctl enable --now nginx

echo "==> MariaDB 설치"
sudo apt -y install mariadb-server
sudo systemctl enable --now mariadb

echo "==> PHP(FPM) 설치"
sudo apt -y install php-fpm php-mysql php-xml php-curl php-zip php-mbstring php-gd php-intl
sudo systemctl restart php8.3-fpm

echo "==> 워드프레스용 DB/계정 생성"
# root는 unix_socket로 접속 가능(ubuntu 24.04 기본)
sudo mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
  DEFAULT CHARACTER SET utf8mb4
  COLLATE utf8mb4_general_ci;
DROP USER IF EXISTS '${DB_USER}'@'localhost';
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

echo "==> 워드프레스 다운로드"
sudo mkdir -p /var/www
cd /var/www
if [[ -d "${SITE_DIR}" ]]; then
  echo "폴더 /var/www/${SITE_DIR} 이미 존재. 계속 진행합니다."
else
  sudo curl -LO https://wordpress.org/latest.zip
  sudo unzip -q latest.zip
  sudo rm -f latest.zip
  sudo mv wordpress "${SITE_DIR}"
fi

echo "==> 권한 설정"
sudo chown -R www-data:www-data "/var/www/${SITE_DIR}"
sudo find "/var/www/${SITE_DIR}" -type d -exec chmod 755 {} \;
sudo find "/var/www/${SITE_DIR}" -type f -exec chmod 644 {} \;

echo "==> Nginx 서버블록 생성"
NGINX_AVAIL="/etc/nginx/sites-available/${SITE_DIR}"
sudo tee "${NGINX_AVAIL}" > /dev/null <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};

    root /var/www/${SITE_DIR};
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
    }

    # 업로드 제한 등이 필요하면 아래 주석 해제
    # client_max_body_size 64m;
}
NGINX

sudo ln -sf "${NGINX_AVAIL}" "/etc/nginx/sites-enabled/${SITE_DIR}"
# 기본 welcome 페이지 제거
sudo rm -f /etc/nginx/sites-enabled/default || true
sudo nginx -t
sudo systemctl reload nginx

echo "==> wp-config.php 생성/수정"
cd "/var/www/${SITE_DIR}"
if [[ ! -f wp-config.php ]]; then
  sudo cp wp-config-sample.php wp-config.php
fi

# 보안 SALT 자동 삽입
SALT_BLOCK="$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)"
sudo awk -v dbn="${DB_NAME}" -v dbu="${DB_USER}" -v dbp="${DB_PASS}" '
  BEGIN{ done=0 }
  {
    if($0 ~ /define\(.DB_NAME./){ print "define( '\''DB_NAME'\'', '\''" dbn "'\'' );" }
    else if($0 ~ /define\(.DB_USER./){ print "define( '\''DB_USER'\'', '\''" dbu "'\'' );" }
    else if($0 ~ /define\(.DB_PASSWORD./){ print "define( '\''DB_PASSWORD'\'', '\''" dbp "'\'' );" }
    else if($0 ~ /define\(.DB_HOST./){ print "define( '\''DB_HOST'\'', '\''localhost'\'' );" }
    else if($0 ~ /define\(.DB_CHARSET./){ print "define( '\''DB_CHARSET'\'', '\''utf8mb4'\'' );" }
    else if(!done && $0 ~ /Authentication Unique Keys and Salts/){
      print $0
      print "'"${SALT_BLOCK//$'\n'/'\n'}"'"
      # 다음 기본 키/솔트 줄들은 건너뛰도록 플래그만
    } else if($0 ~ /define\(.AUTH_KEY.|define\(.SECURE_AUTH_KEY.|define\(.LOGGED_IN_KEY.|define\(.NONCE_KEY.|define\(.AUTH_SALT.|define\(.SECURE_AUTH_SALT.|define\(.LOGGED_IN_SALT.|define\(.NONCE_SALT./){
      # skip
    } else { print $0 }
  }
' wp-config.php | sudo tee wp-config.php.new > /dev/null

# FS_METHOD 추가(플러그인/테마 직접 쓰기)
if ! sudo grep -q "FS_METHOD" wp-config.php.new; then
  echo "define( 'FS_METHOD', 'direct' );" | sudo tee -a wp-config.php.new > /dev/null
fi
sudo mv wp-config.php.new wp-config.php
sudo chown www-data:www-data wp-config.php
sudo chmod 640 wp-config.php

# 업로드 디렉터리 보장
sudo -u www-data mkdir -p "/var/www/${SITE_DIR}/wp-content/uploads"

echo
echo "=== 완료! ========================================="
echo "브라우저에서 접속:  http://서버_IP/"
echo "Nginx server_name:  ${DOMAIN}"
echo "사이트 경로:        /var/www/${SITE_DIR}"
echo "DB:                 ${DB_NAME} (user: ${DB_USER})"
echo "==================================================="
EOF
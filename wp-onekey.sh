#!/usr/bin/env bash
set -euo pipefail

umask 022

# --------- Defaults ---------
SITE_DIR="showdeck"
DB_NAME="wpdb"
DB_USER="wpuser"
DB_PASS=""
DOMAIN="_"                    # 없으면 '_' (기본 페이지)
ADMIN_EMAIL=""                # --ssl 시 필수
WANT_SSL=0

# --------- Args ---------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site)      SITE_DIR="${2}"; shift 2;;
    --db-name)   DB_NAME="${2}"; shift 2;;
    --db-user)   DB_USER="${2}"; shift 2;;
    --db-pass)   DB_PASS="${2}"; shift 2;;
    --domain)    DOMAIN="${2}"; shift 2;;
    --ssl)       WANT_SSL=1; shift 1;;
    --email)     ADMIN_EMAIL="${2}"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

# --------- Helpers ---------
log() { echo -e "\033[1;32m==>\033[0m $*"; }
warn(){ echo -e "\033[1;33m[!]\033[0m $*"; }
die(){ echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

require_root(){
  if [[ "$(id -u)" -ne 0 ]]; then
    die "root 권한이 필요합니다. sudo 로 실행하세요."
  fi
}

gen_pass(){
  tr -dc 'A-Za-z0-9!@#$%^&*()-_=+' </dev/urandom | head -c 20
}

detect_php_sock(){
  local candidates=(
    "/run/php/php8.3-fpm.sock"
    "/run/php/php8.2-fpm.sock"
    "/var/run/php/php8.3-fpm.sock"
    "/var/run/php/php8.2-fpm.sock"
  )
  for s in "${candidates[@]}"; do
    [[ -S "$s" ]] && echo "$s" && return 0
  done
  local v
  v="$(php -v 2>/dev/null | awk 'NR==1{print $2}' | cut -d'.' -f1-2 || true)"
  if [[ -n "${v:-}" && -S "/run/php/php${v}-fpm.sock" ]]; then
    echo "/run/php/php${v}-fpm.sock"; return 0
  fi
  echo "/run/php/php8.3-fpm.sock"
}

need_cmd(){
  command -v "$1" >/dev/null 2>&1 || die "필요 명령어가 없습니다: $1"
}

retry(){
  # retry <times> <sleep> <cmd...>
  local -r tries="$1"; shift
  local -r wait="$1"; shift
  local i=1
  while true; do
    if "$@"; then return 0; fi
    if (( i >= tries )); then return 1; fi
    sleep "$wait"
    ((i++))
  done
}

mysql_try(){
  # mysql_try <host> <user> <pass> <sql>
  local host="$1" user="$2" pass="$3" sql="$4"
  MYSQL_PWD="$pass" mysql -h "$host" -u "$user" -e "$sql" >/dev/null 2>&1
}

choose_db_host(){
  # 실제 접속 가능한 DB_HOST 자동 선택: 127.0.0.1 우선, 실패시 localhost
  if mysql_try "127.0.0.1" "$DB_USER" "$DB_PASS" "SELECT 1;"; then
    echo "127.0.0.1"
  elif mysql_try "localhost" "$DB_USER" "$DB_PASS" "SELECT 1;"; then
    echo "localhost"
  else
    echo ""  # 실패
  fi
}

# --------- Begin ---------
require_root

[[ -z "$DB_PASS" ]] && DB_PASS="$(gen_pass)" && warn "DB_PASS 미지정 → 랜덤 생성: $DB_PASS"
if [[ $WANT_SSL -eq 1 && -z "$ADMIN_EMAIL" ]]; then
  die "--ssl 사용 시 --email <관리자메일>도 필요합니다."
fi

log "시스템 업데이트 및 기본 도구"
apt update
DEBIAN_FRONTEND=noninteractive apt -y upgrade
apt -y install unzip curl wget htop git ufw ca-certificates gnupg lsb-release

log "방화벽(UFW) 설정"
ufw allow OpenSSH || true
ufw allow 80 || true
ufw allow 443 || true
ufw --force enable || true
ufw status || true

log "Nginx 설치"
apt -y install nginx
systemctl enable --now nginx

log "MariaDB 설치"
apt -y install mariadb-server
systemctl enable --now mariadb

log "PHP(FPM) + MySQL 모듈 설치"
apt -y install php-fpm php-mysql php-xml php-curl php-zip php-mbstring php-gd php-intl
if systemctl list-units | grep -q php8.3-fpm; then
  systemctl restart php8.3-fpm
elif systemctl list-units | grep -q php8.2-fpm; then
  systemctl restart php8.2-fpm
else
  systemctl restart php*-fpm || true
fi

PHP_SOCK="$(detect_php_sock)"
log "PHP-FPM 소켓: $PHP_SOCK"

log "워드프레스용 DB/계정 생성"
mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
  DEFAULT CHARACTER SET utf8mb4
  COLLATE utf8mb4_general_ci;
DROP USER IF EXISTS '${DB_USER}'@'localhost';
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

# ---- DB 접속 테스트로 DB_HOST 결정 ----
log "DB 접속 검사로 DB_HOST 자동 결정"
CHOSEN_DB_HOST="$(choose_db_host || true)"
if [[ -z "${CHOSEN_DB_HOST}" ]]; then
  # 추가 힌트 출력
  warn "DB 접속 실패: 127.0.0.1 / localhost 모두 실패"
  warn "mariadb 상태 확인: systemctl status mariadb"
  die  "DB 연결 불가. 비밀번호/서비스 상태를 확인하세요."
fi
log "선택된 DB_HOST: ${CHOSEN_DB_HOST}"

log "워드프레스 다운로드/배치"
install -d -m 755 /var/www
cd /var/www
if [[ -d "${SITE_DIR}" && -f "${SITE_DIR}/wp-settings.php" ]]; then
  warn "/var/www/${SITE_DIR} 에 워드프레스가 이미 존재. 덮어쓰지 않고 계속합니다."
else
  rm -f latest.zip
  (curl -L https://wordpress.org/latest.zip -o latest.zip || wget -O latest.zip https://wordpress.org/latest.zip)
  unzip -q latest.zip
  rm -f latest.zip
  [[ -d "${SITE_DIR}" ]] && rm -rf "${SITE_DIR}"
  mv wordpress "${SITE_DIR}"
fi

log "권한 설정"
chown -R www-data:www-data "/var/www/${SITE_DIR}"
find "/var/www/${SITE_DIR}" -type d -exec chmod 755 {} \;
find "/var/www/${SITE_DIR}" -type f -exec chmod 644 {} \;
install -d -o www-data -g www-data -m 775 "/var/www/${SITE_DIR}/wp-content/uploads"

log "Nginx 서버블록 생성"
NGINX_AVAIL="/etc/nginx/sites-available/${SITE_DIR}"

# 기본 서버 여부 결정
LISTEN_DEFAULT=""
SERVER_NAME_LINE="server_name ${DOMAIN};"
if [[ "$DOMAIN" == "_" ]]; then
  LISTEN_DEFAULT=" default_server"
  SERVER_NAME_LINE="server_name _;"
fi

cat > "${NGINX_AVAIL}" <<NGINX
server {
    listen 80${LISTEN_DEFAULT};
    ${SERVER_NAME_LINE}

    root /var/www/${SITE_DIR};
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
        # 문제가 생기면 아래 라인 주석 해제:
        # fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
    }

    # 업로드 한도(필요시 주석 해제)
    # client_max_body_size 64m;

    # (선택) 기본 gzip
    gzip on;
    gzip_types text/plain text/css application/json application/javascript application/xml+rss application/xml text/javascript;
}
NGINX

ln -sfn "${NGINX_AVAIL}" "/etc/nginx/sites-enabled/${SITE_DIR}"
rm -f /etc/nginx/sites-enabled/default || true
nginx -t
systemctl reload nginx

log "wp-config.php 생성/수정"
cd "/var/www/${SITE_DIR}"
if [[ ! -f wp-config.php ]]; then
  cp wp-config-sample.php wp-config.php
fi

# SALT 재시도 포함
SALT_BLOCK="$(retry 3 1 curl -fs https://api.wordpress.org/secret-key/1.1/salt/ || true)"

awk -v dbn="${DB_NAME}" -v dbu="${DB_USER}" -v dbp="${DB_PASS}" -v dbh="${CHOSEN_DB_HOST}" -v salt="${SALT_BLOCK//$'\n'/'\n'}" '
  BEGIN{ injected=0 }
  {
    if($0 ~ /define\(.DB_NAME./){ print "define( '\''DB_NAME'\'', '\''" dbn "'\'' );" }
    else if($0 ~ /define\(.DB_USER./){ print "define( '\''DB_USER'\'', '\''" dbu "'\'' );" }
    else if($0 ~ /define\(.DB_PASSWORD./){ print "define( '\''DB_PASSWORD'\'', '\''" dbp "'\'' );" }
    else if($0 ~ /define\(.DB_HOST./){ print "define( '\''DB_HOST'\'', '\''" dbh "'\'' );" }
    else if($0 ~ /define\(.DB_CHARSET./){ print "define( '\''DB_CHARSET'\'', '\''utf8mb4'\'' );" }
    else if(!injected && $0 ~ /Authentication Unique Keys and Salts/){
      print $0
      if(length(salt)>0){ print salt }
      injected=1
    } else if($0 ~ /define\(.AUTH_KEY.|define\(.SECURE_AUTH_KEY.|define\(.LOGGED_IN_KEY.|define\(.NONCE_KEY.|define\(.AUTH_SALT.|define\(.SECURE_AUTH_SALT.|define\(.LOGGED_IN_SALT.|define\(.NONCE_SALT./){
      if(injected){ next } else { print $0 }
    } else { print $0 }
  }
' wp-config.php > wp-config.php.new

grep -q "FS_METHOD" wp-config.php.new || echo "define( 'FS_METHOD', 'direct' );" >> wp-config.php.new

mv wp-config.php.new wp-config.php
chown www-data:www-data wp-config.php
chmod 640 wp-config.php

# ---- Optional: SSL ----
if [[ $WANT_SSL -eq 1 ]]; then
  log "Certbot(SSL) 설치 및 발급"
  apt -y install certbot python3-certbot-nginx
  if [[ "$DOMAIN" == "_" ]]; then
    die "--ssl 을 쓰려면 --domain 에 실제 도메인을 넣어야 합니다."
  fi
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL" || die "Certbot 실패(도메인/DNS 확인 필요)"
  systemctl reload nginx
fi

# ---- Quick health checks ----
PHP_OK=0
if php -m | grep -qiE 'mysqli|pdo_mysql'; then PHP_OK=1; fi

DB_PING_OK=0
if mysql_try "${CHOSEN_DB_HOST}" "$DB_USER" "$DB_PASS" "SHOW DATABASES;"; then DB_PING_OK=1; fi

PUB_IPv4="$(curl -s https://ipinfo.io/ip || true)"

log "설치 완료!"
echo "------------------------------------------------------------"
echo " 사이트 URL:        http://${DOMAIN:-_}   (도메인 없으면: http://${PUB_IPv4})"
echo " 웹 루트:           /var/www/${SITE_DIR}"
echo " Nginx 블록:        /etc/nginx/sites-available/${SITE_DIR}"
echo " DB 접속:           ${DB_NAME} / ${DB_USER} / ${DB_PASS}"
echo " DB 호스트:         ${CHOSEN_DB_HOST}"
echo " 관리자 페이지:     http://${DOMAIN:-$PUB_IPv4}/wp-admin/  (설치 마법사 진행)"
if [[ $WANT_SSL -eq 1 ]]; then
  echo " SSL:               발급됨 (Let's Encrypt, 자동갱신)"
fi
echo " 방화벽:            UFW(22,80,443 허용)"
echo " PHP-FPM 소켓:      ${PHP_SOCK}"
echo "------------------------------------------------------------"
echo "진단 요약:"
echo " - PHP mysql 모듈:  $([[ $PHP_OK -eq 1 ]] && echo OK || echo '없음(php-mysql 필요)')"
echo " - DB ping:         $([[ $DB_PING_OK -eq 1 ]] && echo OK || echo '실패(DB_HOST/비번/서비스 확인)')"

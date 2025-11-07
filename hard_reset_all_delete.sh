# === 설정 ===
SITE_DIR="showdeck"
SITE="/var/www/${SITE_DIR}"
DB_NAME="wpdb"
DB_USER="wpuser"
DB_PASS="qpdg88"        # 원하는 비번
DB_HOST="127.0.0.1"     # TCP 권장 (소켓 꼬임 방지)

# === 백업 (필수 권장) ===
TS="$(date +%Y%m%d_%H%M%S)"
sudo tar -C /var/www -czf "/root/wp_files_${SITE_DIR}_${TS}.tar.gz" "${SITE_DIR}" 2>/dev/null || true
sudo mysqldump -u root "${DB_NAME}" > "/root/wp_db_${DB_NAME}_${TS}.sql" 2>/dev/null || true

# === 삭제(주의) ===
sudo rm -rf "${SITE}"

sudo mysql <<SQL
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
DROP USER IF EXISTS '${DB_USER}'@'localhost';
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

# === 재설치 ===
sudo mkdir -p /var/www && cd /var/www
curl -LO https://wordpress.org/latest.zip
sudo apt -y install unzip >/dev/null
sudo unzip -q latest.zip && sudo rm latest.zip
sudo mv wordpress "${SITE_DIR}"

# DB 재생성/권한
sudo mysql <<SQL
CREATE DATABASE \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

# wp-config 세팅
cd "${SITE}"
sudo cp wp-config-sample.php wp-config.php
sudo sed -i "s/define( 'DB_NAME'.*/define( 'DB_NAME', '${DB_NAME}' );/" wp-config.php
sudo sed -i "s/define( 'DB_USER'.*/define( 'DB_USER', '${DB_USER}' );/" wp-config.php
sudo sed -i "s/define( 'DB_PASSWORD'.*/define( 'DB_PASSWORD', '${DB_PASS}' );/" wp-config.php
sudo sed -i "s/define( 'DB_HOST'.*/define( 'DB_HOST', '${DB_HOST}' );/" wp-config.php
curl -s https://api.wordpress.org/secret-key/1.1/salt/ | sudo tee -a wp-config.php >/dev/null
echo "define('FS_METHOD','direct');" | sudo tee -a wp-config.php >/dev/null

# 권한
sudo chown -R www-data:www-data "${SITE}"
sudo find "${SITE}" -type d -exec sudo chmod 755 {} \;
sudo find "${SITE}" -type f -exec sudo chmod 644 {} \;
sudo install -d -o www-data -g www-data -m 775 "${SITE}/wp-content/uploads"

# 서비스 리로드
sudo systemctl reload nginx
sudo systemctl restart mariadb
sudo systemctl restart php8.3-fpm || sudo systemctl restart php8.2-fpm || true

echo "완전 초기화 완료 → 브라우저에서 새로 설치 진행: http://서버IP/"

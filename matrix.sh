#!/bin/bash

read -p "请输入 域名: " server_domain
read -p "请输入 IP: " server_IP
# read -p "请输入 email: " my_email
passwd_matrix=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 26)
passwd_psycopg2=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 26)
passwd_turnserver=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 26)

echo $server_domain > /home/domain.txt
echo "域名已写入 /home/domain.txt"

apt install -y lsb-release wget apt-transport-https coturn
wget -O /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/matrix-org.list

# 安装PostgreSQL 数据库
apt install -y postgresql postgresql-contrib
systemctl enable postgresql
systemctl start postgresql

# 切换到postgres系统用户并添加synapse数据库、新建用户synapse_user
su - postgres << EOF
psql << SQL
-- Create the database with specified parameters
CREATE DATABASE synapse ENCODING 'UTF8' LC_COLLATE='C' LC_CTYPE='C' template=template0;
-- Create the user with the generated secure password
CREATE USER synapse_user WITH PASSWORD '$passwd_psycopg2';
-- Change the owner of the database to the newly created user
ALTER DATABASE synapse OWNER TO synapse_user;
-- Grant all privileges on the database to the user
GRANT ALL PRIVILEGES ON DATABASE synapse TO synapse_user;
\q
SQL
EOF
sleep 10

# 设置 Synapse server_name 为 server_domain，避免交互式配置
echo "matrix-synapse matrix-synapse/server-name string $server_domain" | debconf-set-selections
# 设置 DEBIAN_FRONTEND 环境变量为 noninteractive，避免交互提示
export DEBIAN_FRONTEND=noninteractive
apt update && apt install -y matrix-synapse-py3
sleep 10

# 配置 /etc/matrix-synapse/homeserver.yaml
cat << EOF > /etc/matrix-synapse/homeserver.yaml
server_name: "$server_domain"
public_baseurl: "https://$server_domain/"
pid_file: "/var/run/matrix-synapse.pid"
listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['::1', '127.0.0.1']
    resources:
      - names: [client, federation]
        compress: false
tls_certificate_path: /etc/letsencrypt/live/$server_domain/fullchain.pem
tls_private_key_path: /etc/letsencrypt/live/$server_domain/privkey.pem
database:
  name: "psycopg2"
  args:
    user: "synapse_user"
    password: "$passwd_psycopg2"
    database: "synapse"
    host: "localhost"
    cp_min: 5
    cp_max: 10
log_config: "/etc/matrix-synapse/log.yaml"
media_store_path: /var/lib/matrix-synapse/media
signing_key_path: "/etc/matrix-synapse/homeserver.signing.key"
trusted_key_servers:
  - server_name: "matrix.org"
max_avatar_size: 10M
max_upload_size: 500M
password_config:
  enabled: true  # 默认 true，确保未设置为 false（否则禁用本地密码功能，包括修改）
registration_shared_secret: "$passwd_matrix"
enable_registration: true
enable_registration_captcha: true
# 无需电子邮件或 recaptcha 验证即可注册（其实不推荐）
# enable_registration_without_verification: true

# 填入你在 Google 申请的 Site Key (网站密钥)
recaptcha_public_key: "6LeoeBksAAAAAB6etQfHAgd5ZkZHqWhyFNoCUdJH"
# 填入你在 Google 申请的 Secret Key (密钥)
recaptcha_private_key: "6LeoeBksAAAAAHPvGPGn1E5R1zZXXzh9Sjg2akZ-"
# 验证 API 地址，通常保持默认即可
recaptcha_siteverify_api: "https://www.google.com/recaptcha/api/siteverify"

# -------------------------------------------------------------------------
# WebRTC/VoIP STUN/TURN 配置
# -------------------------------------------------------------------------
# 告诉客户端去哪里找 STUN/TURN 服务器
# 你的 TURN 服务器同时提供 STUN 服务
turn_uris:
    # 必须提供 UDP 和 TCP 两种传输方式
    - "turn:'$server_domain':3478?transport=udp"
    - "turn:'$server_domain':3478?transport=tcp"
    
# 【关键】必须与 coturn 配置中的 static-auth-secret 保持一致！
turn_shared_secret: "'$passwd_turnserver'"

# 动态密码有效期 (毫秒)
turn_user_lifetime: 86400000 # 24 小时

EOF

# 配置/etc/turnserver.conf
cat << EOF > /etc/turnserver.conf
# 确保文件是干净的，注释掉所有默认示例配置，添加以下关键行：

# 监听地址 (通常是服务器的公共 IP 或 0.0.0.0)
listening-ip=0.0.0.0

# 监听端口
listening-port=3478

# 外部 IP (如果服务器有多个 IP，请指定公网 IP)
external-ip=$server_IP

# 证书配置 (可选，但推荐)
# use-auth-secret 是关键，它允许 Synapse 动态生成用户名和密码
use-auth-secret
static-auth-secret=$passwd_turnserver  # 必须与 homeserver.yaml 中的 turn_shared_secret 相同！
realm=$server_domain

# 转发端口范围 (用于媒体流中继，范围越大越好)
min-port=49152
max-port=65535

# 启用 STUN 和 TURN 服务
stuns-port=3478
turns-port=3478

EOF
systemctl enable coturn
systemctl start coturn

# 先安装nginx并配置webroot验证，避免端口冲突
apt install -y nginx

# 创建用于certbot验证的目录
mkdir -p /var/www/certbot

# 先配置一个临时的nginx服务器块用于获取证书
cat << EOF > /etc/nginx/sites-available/matrix-temp
server {
    listen 80;
    server_name $server_domain;
    
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    
    location / {
        return 404;
    }
}
EOF

ln -sf /etc/nginx/sites-available/matrix-temp /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx

# 安装certbot并使用webroot方式获取证书
apt install -y certbot python3-certbot-nginx

# 使用webroot方式获取初始证书
certbot certonly --webroot -w /var/www/certbot -d $server_domain --email liuxt2@hku-szh.org --agree-tos --non-interactive

# 配置 Nginx
cat << EOF > /etc/nginx/sites-available/matrix
# /etc/nginx/sites-available/matrix
server {
    listen 80;
    server_name $server_domain;  # 替换为你的域名

    # ACME挑战用于证书续期
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # 强制所有HTTP流量重定向到HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $server_domain;  # 替换为你的域名

    # 设置SSL证书路径（让Nginx使用Let's Encrypt证书）
    ssl_certificate /etc/letsencrypt/live/$server_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$server_domain/privkey.pem;

    # 安全性相关的设置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'HIGH:!aNULL:!MD5';
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    # HSTS头
    add_header Strict-Transport-Security "max-age=63072000" always;

    location / {
        proxy_pass http://127.0.0.1:8008;  # 将流量转发到Synapse的8008端口
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        # 关键配置：设置允许的最大上传大小
        # 建议设置为 100M 或更高，根据你的需求
        client_max_body_size 500M;
    }

    # 保留ACME挑战路径用于续期
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
}
EOF

# 启用正式配置
ln -sf /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/matrix-temp
systemctl reload nginx

# 设置自动续期
# 测试续期（不实际安装）
echo "测试证书续期..."
certbot renew --dry-run

# 设置定时任务自动续期
(crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet --post-hook \"systemctl reload nginx\"") | crontab -

systemctl enable matrix-synapse
systemctl start matrix-synapse

echo "安装完成！证书自动续期已配置。"
echo "系统将在10秒后重启..."
sleep 10
reboot

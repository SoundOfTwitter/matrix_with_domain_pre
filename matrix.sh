#!/bin/bash

read -p "请输入 域名: " server_domain
read -p "请输入 email: " my_email
passwd_matrix=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 26)
passwd_psycopg2=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 26)

apt install -y lsb-release wget apt-transport-https
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
enable_registration: true
password_config:
  enabled: true  # 默认 true，确保未设置为 false（否则禁用本地密码功能，包括修改）
# 无需电子邮件或 recaptcha 验证即可注册（其实不推荐）
enable_registration_without_verification: true
registration_shared_secret: "$passwd_matrix"

EOF

apt install -y certbot python3-certbot-nginx
certbot --nginx -d $server_domain --email $my_email --agree-tos --non-interactive

apt install -y nginx

# 配置 Nginx
cat << EOF > /etc/nginx/sites-available/matrix
# /etc/nginx/sites-available/matrix
server {
    listen 80;
    server_name $server_domain;  # 替换为你的域名
    location ~ /.well-known/acme-challenge/ {
        allow all;
        root /var/lib/letsencrypt/;
    }

    # 强制所有HTTP流量重定向到HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $server_domain;  # 替换为你的域名

    # 设置SSL证书路径（让Nginx使用Let's Encrypt证书）
    ssl_certificate /etc/letsencrypt/live/$server_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$server_domain/privkey.pem;

    # 安全性相关的设置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'HIGH:!aNULL:!MD5';
    ssl_prefer_server_ciphers on;

    location / {
        proxy_pass http://127.0.0.1:8008;  # 将流量转发到Synapse的8008端口
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

EOF

ln -s /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/
systemctl restart nginx
systemctl enable matrix-synapse
systemctl start matrix-synapse
reboot

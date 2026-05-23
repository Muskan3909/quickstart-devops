#!/usr/bin/env bash
# setup-gateway.sh — nginx reverse proxy on gateway-vm
# Proxies to engine-vm:3111 (the iii-http worker).
# Terraform injects ${engine_ip} via templatefile().
set -euo pipefail
LOG=/var/log/quickstart-setup.log
exec > >(tee -a "$LOG") 2>&1
echo "[$(date)] === setup-gateway.sh starting ==="

ENGINE_IP="${engine_ip}"

apt-get update -qq
apt-get install -y -qq nginx

cat > /etc/nginx/sites-available/quickstart << NGINX
upstream iii_engine {
    server $${ENGINE_IP}:3111;
    keepalive 16;
}

server {
    listen 80 default_server;
    server_name _;

    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;

    location /healthz {
        return 200 '{"status":"ok"}';
        add_header Content-Type application/json;
    }

    location / {
        proxy_pass         http://iii_engine;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   Connection        "";
        proxy_read_timeout 150s;
        proxy_send_timeout 30s;
    }
}
NGINX

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/quickstart /etc/nginx/sites-enabled/quickstart
nginx -t
systemctl enable nginx
systemctl restart nginx

echo "[$(date)] === setup-gateway.sh done ==="

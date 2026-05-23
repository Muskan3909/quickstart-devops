#!/usr/bin/env bash
# setup-engine.sh — bootstraps the iii engine on engine-vm
set -euo pipefail
LOG=/var/log/quickstart-setup.log
exec > >(tee -a "$LOG") 2>&1
echo "[$(date)] === setup-engine.sh starting ==="

apt-get update -qq
apt-get install -y -qq curl ca-certificates git

# Install the REAL iii CLI (not npm — that installs an unrelated package)
curl -fsSL https://install.iii.dev/iii/main/install.sh | sh
export PATH="/root/.local/bin:$PATH"
echo "iii version: $(iii --version)"

# Clone quickstart to get the correct config
git clone https://github.com/Alchemyst-ai/hiring.git /opt/hiring
mkdir -p /opt/quickstart
cp -r /opt/hiring/may-2026/devops/quickstart/* /opt/quickstart/
mkdir -p /opt/quickstart/data

# Fix config.yaml:
# 1. Change iii-http host to 0.0.0.0 (nginx on gateway-vm proxies to this)
# 2. Remove inference-worker and caller-worker entries (they run on separate VMs)
# 3. Increase default_timeout to 120s for CPU inference
python3 -c "
import re, sys
txt = open('/opt/quickstart/config.yaml').read()
txt = re.sub(r'host: 127\.0\.0\.1', 'host: 0.0.0.0', txt)
txt = re.sub(r'default_timeout: \d+', 'default_timeout: 120000', txt)
# Remove the worker_path entries (inference-worker and caller-worker blocks)
txt = re.sub(r'\s*- name: inference-worker\s*worker_path:.*', '', txt)
txt = re.sub(r'\s*- name: caller-worker\s*worker_path:.*', '', txt)
open('/opt/quickstart/config.yaml', 'w').write(txt)
print('Config updated OK')
"

cat > /etc/systemd/system/iii-engine.service << 'SVC'
[Unit]
Description=iii engine (WebSocket RPC broker + HTTP API)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment="PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
WorkingDirectory=/opt/quickstart
ExecStart=/root/.local/bin/iii --config /opt/quickstart/config.yaml
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable iii-engine
systemctl start iii-engine

echo "[$(date)] === setup-engine.sh done ==="

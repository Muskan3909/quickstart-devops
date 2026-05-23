#!/usr/bin/env bash
# setup-caller-worker.sh — bootstraps TypeScript caller-worker on caller-vm
set -euo pipefail
LOG=/var/log/quickstart-setup.log
exec > >(tee -a "$LOG") 2>&1
echo "[$(date)] === setup-caller-worker.sh starting ==="

apt-get update -qq
apt-get install -y -qq curl ca-certificates git

# Node.js 20
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y -qq nodejs

# Clone the actual quickstart worker files
git clone https://github.com/Alchemyst-ai/hiring.git /opt/hiring
WORKER_DIR=/opt/quickstart/workers/caller-worker
mkdir -p "$WORKER_DIR/src"
cp -r /opt/hiring/may-2026/devops/quickstart/workers/caller-worker/* "$WORKER_DIR/"

cd "$WORKER_DIR"
npm install --quiet

cat > /etc/systemd/system/caller-worker.service << SVC
[Unit]
Description=iii caller-worker (TypeScript)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$WORKER_DIR
Environment="III_URL=ws://10.0.1.10:49134"
ExecStart=/usr/bin/npm run dev
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable caller-worker
systemctl start caller-worker

echo "[$(date)] === setup-caller-worker.sh done ==="

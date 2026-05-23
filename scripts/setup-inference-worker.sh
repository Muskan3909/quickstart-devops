#!/usr/bin/env bash
# setup-inference-worker.sh — bootstraps Python inference-worker on inference-vm
set -euo pipefail
LOG=/var/log/quickstart-setup.log
exec > >(tee -a "$LOG") 2>&1
echo "[$(date)] === setup-inference-worker.sh starting ==="

apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv build-essential cmake curl git ca-certificates

# Clone the actual quickstart worker files
git clone https://github.com/Alchemyst-ai/hiring.git /opt/hiring
WORKER_DIR=/opt/quickstart/workers/inference-worker
mkdir -p "$WORKER_DIR"

# Use the corrected inference_worker.py (llama-cpp-python + correct SDK import)
cat > "$WORKER_DIR/inference_worker.py" << 'PY'
import os
from llama_cpp import Llama
from iii import register_worker, InitOptions

# Connect to the iii engine on engine-vm via WebSocket
iii = register_worker(
    os.environ.get("III_URL", "ws://10.0.1.10:49134"),
    InitOptions(worker_name="inference-worker"),
)

MODEL_PATH = os.environ.get("MODEL_PATH", "/opt/models/gemma-3-270m-it-Q4_K_M.gguf")
print("Loading model...")
llm = Llama(
    model_path=MODEL_PATH,
    n_ctx=2048,
    n_threads=int(os.environ.get("LLM_THREADS", "2")),
    verbose=False,
)
print("Model loaded.")

def run_inference_handler(payload):
    messages = payload.get("messages", [])
    if not messages:
        return {"error": "no messages provided"}
    out = llm.create_chat_completion(
        messages=messages,
        max_tokens=int(payload.get("max_tokens", 512)),
        temperature=float(payload.get("temperature", 0.7)),
    )
    return out["choices"][0]["message"]["content"]

iii.register_function("inference::run_inference", run_inference_handler)
print("Inference worker started - listening for calls")
PY

cat > "$WORKER_DIR/requirements.txt" << 'REQ'
iii-sdk==0.11.0
llama-cpp-python
REQ

# Python venv — install with sudo to avoid permission issues
python3 -m venv /opt/venv/inference
sudo /opt/venv/inference/bin/pip install --quiet iii-sdk==0.11.0 llama-cpp-python

# Download the model (Q4_K_M — ~240MB, fast to download, fast on CPU)
mkdir -p /opt/models
MODEL_FILE=/opt/models/gemma-3-270m-it-Q4_K_M.gguf
if [ ! -f "$MODEL_FILE" ]; then
    echo "[$(date)] Downloading model (~240MB)..."
    curl -L --retry 5 --retry-delay 3 \
        "https://huggingface.co/lmstudio-community/gemma-3-270m-it-GGUF/resolve/main/gemma-3-270m-it-Q4_K_M.gguf" \
        -o "$MODEL_FILE"
    echo "[$(date)] Model download complete."
fi

cat > /etc/systemd/system/inference-worker.service << SVC
[Unit]
Description=iii inference-worker (Python / gemma-3-270m-it Q4)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$WORKER_DIR
Environment="III_URL=ws://10.0.1.10:49134"
Environment="MODEL_PATH=/opt/models/gemma-3-270m-it-Q4_K_M.gguf"
Environment="LLM_THREADS=2"
ExecStart=/opt/venv/inference/bin/python inference_worker.py
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable inference-worker
systemctl start inference-worker

echo "[$(date)] === setup-inference-worker.sh done ==="

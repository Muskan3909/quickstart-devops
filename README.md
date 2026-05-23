# Quickstart — Distributed Inference Deployment

> Deploys the [Alchemyst AI quickstart](https://github.com/Alchemyst-ai/hiring/tree/main/may-2026/devops/quickstart) across **four GCP VMs** in a private subnet. A Python worker hosts `gemma-3-270m-it` (GGUF Q4) via `llama-cpp-python`; a TypeScript worker fans HTTP requests into that RPC and returns JSON. Only the gateway VM has a public IP.

---

## Architecture

```
 PUBLIC INTERNET
       │
       │  HTTP :80
       ▼
┌─────────────────────────────────────────────────────────────────┐
│                    quickstart-vpc  (10.0.1.0/24)                │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  gateway-vm  │  10.0.1.13  │  PUBLIC IP: 34.10.75.30     │   │
│  │  nginx reverse proxy                                     │   │
│  └───────────────────────┬──────────────────────────────────┘   │
│                          │ proxy_pass :3111                     │
│                          ▼                                      │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  engine-vm  │  10.0.1.10                                 │   │
│  │  iii engine  ── WebSocket broker  :49134                 │   │
│  │  iii-http   ── REST API           :3111                  │   │
│  └────────────┬─────────────────────────┬───────────────────┘   │
│               │ WebSocket RPC           │ WebSocket RPC         │
│               ▼                         ▼                       │
│  ┌─────────────────┐       ┌──────────────────────────────┐     │
│  │  caller-vm      │       │  inference-vm                │     │
│  │  10.0.1.12      │       │  10.0.1.11                   │     │
│  │  TypeScript     │       │  Python worker               │     │
│  │  caller-worker  │       │  gemma-3-270m-it Q4          │     │
│  │                 │       │  via llama-cpp-python        │     │
│  └─────────────────┘       └──────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────┘
```

### Firewall Rules

| Rule | Protocol | Ports | Source | Target |
|---|---|---|---|---|
| `internal` | TCP/UDP/ICMP | all | `10.0.1.0/24` | all VMs |
| `gateway-http` | TCP | 80, 443 | `0.0.0.0/0` | gateway-vm only |
| `iap-ssh` | TCP | 22 | `35.235.240.0/20` | all VMs |

> ⚠️ No VM except `gateway-vm` has a public IP.

---

## RPC Call Flow

```
POST /v1/chat/completions
  │
  ▼  nginx  ──────────────────────────── gateway-vm
  │
  ▼  http::run_inference_over_http ────── engine-vm :3111  (iii-http)
  │
  ▼  WebSocket RPC via iii engine
  │
  ▼  inference::get_response ─────────── caller-vm  (TypeScript)
  │
  ▼  WebSocket RPC via iii engine
  │
  ▼  inference::run_inference ─────────── inference-vm  (Python)
  │
  ▼  llama-cpp-python → gemma-3-270m-it Q4_K_M
  │
  ◄── JSON response ──────────────────────────────────────────────
```

---

## VM Inventory

| VM | Internal IP | Instance Type | Role |
|---|---|---|---|
| `engine-vm` | `10.0.1.10` | e2-small | iii engine (WS broker) + iii-http (REST :3111) |
| `inference-vm` | `10.0.1.11` | e2-standard-2 | Python inference worker + gemma-3-270m-it Q4 |
| `caller-vm` | `10.0.1.12` | e2-small | TypeScript caller worker |
| `gateway-vm` | `10.0.1.13` + **34.10.75.30** | e2-micro | nginx public reverse proxy |

---

## API Reference

### `POST /v1/chat/completions`

**Request**

```json
{
  "messages": [
    { "role": "system", "content": "You are a helpful assistant." },
    { "role": "user",   "content": "What is 2+2?" }
  ]
}
```

**Response**

```json
{
  "result": {
    "0": "4",
    "success": "You've connected two workers and they're interoperating seamlessly..."
  }
}
```

### ✅ Working curl command (tested)

```bash
curl -s -X POST http://34.10.75.30/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"What is 2+2? Answer in one word"}]}' \
  --max-time 120
```

**Actual response received:**

```json
{
  "result": {
    "0": "2",
    "1": "\n",
    "success": "You've connected two workers and they're interoperating seamlessly, now let's add a few more workers to expand this project's functionality."
  }
}
```

### Health check

```bash
curl http://34.10.75.30/healthz
# {"status":"ok"}
```

---

## Repository Structure

```
quickstart-devops/
├── terraform/
│   ├── main.tf                     VPC, subnet, NAT, firewall rules, 4 VMs
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── scripts/
│   ├── setup-engine.sh             Startup script for engine-vm
│   ├── setup-inference-worker.sh   Startup script for inference-vm
│   ├── setup-caller-worker.sh      Startup script for caller-vm
│   └── setup-gateway.sh            Startup script for gateway-vm
├── workers/
│   ├── inference-worker/
│   │   ├── inference_worker.py     Python RPC function (inference::run_inference)
│   │   └── requirements.txt
│   └── caller-worker/
│       └── src/worker.ts           TypeScript HTTP + relay functions
├── systemd/
│   ├── iii-engine.service
│   ├── inference-worker.service
│   └── caller-worker.service
└── README.md
```

---

## Deploy from Scratch

### Prerequisites

- [Terraform ≥ 1.5](https://developer.hashicorp.com/terraform/install)
- [gcloud CLI](https://cloud.google.com/sdk/docs/install) authenticated
- GCP project with billing enabled

### 1 — Enable APIs

```bash
gcloud services enable compute.googleapis.com iap.googleapis.com \
  --project=YOUR_PROJECT_ID
```

### 2 — Configure

```bash
git clone https://github.com/Muskan3909/quickstart-devops.git
cd quickstart-devops/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars → set project_id = "YOUR_PROJECT_ID"
```

### 3 — Provision

```bash
terraform init
terraform apply   # type 'yes' when prompted
```

Terraform prints the gateway public IP when done.

### 4 — Wait for startup scripts

```bash
# Monitor inference VM (slowest — builds llama-cpp + downloads model ~5 min)
gcloud compute ssh inference-vm --tunnel-through-iap --zone us-central1-a \
  -- 'sudo journalctl -u inference-worker -f'
# Wait for: "Inference worker started - listening for calls"
```

### 5 — Test

```bash
curl -s -X POST http://$(cd terraform && terraform output -raw gateway_public_ip)/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Hello!"}]}' \
  --max-time 120
```

### 6 — Tear down

```bash
terraform destroy
```

---

## Debugging

```bash
# SSH to any VM (no public IP needed — uses Google IAP)
gcloud compute ssh engine-vm    --tunnel-through-iap --zone us-central1-a
gcloud compute ssh inference-vm --tunnel-through-iap --zone us-central1-a
gcloud compute ssh caller-vm    --tunnel-through-iap --zone us-central1-a
gcloud compute ssh gateway-vm   --tunnel-through-iap --zone us-central1-a

# Check service status
sudo systemctl status iii-engine        # on engine-vm
sudo systemctl status inference-worker  # on inference-vm
sudo systemctl status caller-worker     # on caller-vm
sudo systemctl status nginx             # on gateway-vm

# Stream logs
sudo journalctl -u iii-engine -f
sudo journalctl -u inference-worker -f
sudo journalctl -u caller-worker -f

# Test internal connectivity (bypasses nginx)
curl -s http://10.0.1.10:3111/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"ping"}]}' --max-time 120
```

---

## Lessons Learned During Deployment

These are real issues encountered — documented for reproducibility.

| Issue | Wrong approach | Correct approach |
|---|---|---|
| iii CLI install | `npm install -g iii` (wrong package) | `curl -fsSL https://install.iii.dev/iii/main/install.sh \| sh` |
| Python SDK import | `from iii_sdk import` | `from iii import` (package is `iii-sdk`, module is `iii`) |
| nginx proxy target | `caller-vm:3111` | `engine-vm:3111` (iii-http runs inside the engine) |
| Config format | `server:` block | `workers:` only (v0.12.0 format) |
| GGUF inference | `transformers` (>60s/req on CPU) | `llama-cpp-python` (5-15s/req on CPU) |
| Engine URL env var | `III_ENGINE_URL` | `III_URL` |

---

## Production Hardening

**Network**
- Add TLS via a managed GCP HTTPS Load Balancer or Certbot on gateway-vm. Traffic is currently plain HTTP.
- Add Cloud Armor rate limiting to prevent inference CPU exhaustion from a single client.
- Enable VPC Flow Logs for audit trail of all subnet traffic.
- Restrict IAP SSH to specific service accounts or VPN range.

**Secrets**
- Move HuggingFace tokens and API keys into Secret Manager; inject at runtime via the VM service account.
- Pin the GGUF model to a SHA-256 checksum and verify on download.

**Reliability**
- Add a second `inference-vm` behind an internal TCP load balancer — the iii engine round-robins across multiple workers registering the same function.
- Use managed Redis (Memorystore) for the `iii-state` worker instead of the default file-based store.

**Observability**
- The iii engine exposes Prometheus metrics on port 9464 — scrape with Cloud Monitoring.
- Add a `request-id` header at nginx and propagate through the RPC chain for cross-VM log correlation.

---

## What I Would Do Differently for a 100× Larger Model

A 100× larger model (~27B parameters, ~15GB at Q4) exceeds the RAM and compute of any free-tier VM, making CPU inference impractical.

**Hardware** — Switch `inference-vm` to a GPU instance (`a2-highgpu-1g`, A100 40GB on GCP). For 70B+ models, use multi-GPU with tensor parallelism. Preemptible instances cut cost by 60–80%.

**Serving** — Replace `llama-cpp-python` with **vLLM**, which implements PagedAttention for efficient GPU KV-cache management and continuous batching. vLLM ships an OpenAI-compatible HTTP server so the caller-worker interface stays identical.

**Model storage** — Store weights on GCS and mount with Cloud Storage FUSE, or pre-bake a persistent disk snapshot. This eliminates the multi-minute re-download on every reprovisioning.

**Autoscaling** — Use a GCP Managed Instance Group for the inference tier with custom Prometheus metrics (GPU utilization, RPC queue depth) driving autoscaling. Scale to zero overnight and pre-warm before business hours.

**Cost** — An A100 40GB costs ~$3.50/hr on-demand, ~$1.20/hr preemptible — roughly $850–2,500/month depending on uptime strategy.

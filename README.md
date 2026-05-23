# Quickstart — Distributed Inference Deployment

Deploys the [Alchemyst AI quickstart](https://github.com/Alchemyst-ai/hiring/tree/main/may-2026/devops/quickstart)
across four GCP VMs in a private subnet. A Python worker hosts `gemma-3-270m-it` (GGUF Q4) via
`llama-cpp-python`; a TypeScript worker fans HTTP requests into that RPC and returns JSON.
Only the gateway VM has a public IP.

---

## Architecture

```
                    ┌──────────────────────────────────────────────────────────┐
  PUBLIC INTERNET   │               quickstart-vpc  (10.0.1.0/24)             │
                    │                                                          │
  ┌──────────┐ :80  │  ┌─────────────────────────────────────────────────┐    │
  │  Client  │─────►│  │ gateway-vm   10.0.1.13   PUBLIC IP: 34.10.75.30 │    │
  └──────────┘      │  │ nginx reverse proxy                             │    │
                    │  └────────────────────┬────────────────────────────┘    │
                    │                       │ proxy_pass :3111                 │
                    │                       ▼                                  │
                    │  ┌────────────────────────────────────────────────┐      │
                    │  │ engine-vm   10.0.1.10                          │      │
                    │  │ iii engine  WebSocket :49134                   │      │
                    │  │ iii-http    REST API  :3111                    │      │
                    │  └──────┬─────────────────────────┬──────────────┘      │
                    │         │ WebSocket RPC            │ WebSocket RPC       │
                    │         ▼                          ▼                     │
                    │  ┌──────────────┐      ┌────────────────────────┐        │
                    │  │ caller-vm    │      │ inference-vm           │        │
                    │  │ 10.0.1.12   │      │ 10.0.1.11              │        │
                    │  │ TypeScript  │      │ Python worker          │        │
                    │  │ caller-     │      │ gemma-3-270m-it Q4     │        │
                    │  │ worker      │      │ via llama-cpp-python   │        │
                    │  └──────────────┘      └────────────────────────┘        │
                    └──────────────────────────────────────────────────────────┘

  Firewall rules:
  • internal  — all TCP/UDP within 10.0.1.0/24
  • gateway   — TCP :80/:443 from 0.0.0.0/0 to gateway-vm only
  • iap-ssh   — TCP :22 from 35.235.240.0/20 (Google IAP) to all VMs
  • No VM except gateway-vm has a public IP
```

### RPC call flow

```
POST /v1/chat/completions
  │
  ▼  nginx (gateway-vm)
  │
  ▼  iii-http worker — http::run_inference_over_http  [engine-vm :3111]
  │
  ▼  WebSocket RPC via iii engine
  │
  ▼  inference::get_response  [caller-vm — TypeScript]
  │
  ▼  WebSocket RPC via iii engine
  │
  ▼  inference::run_inference  [inference-vm — Python]
  │
  ▼  llama-cpp-python → gemma-3-270m-it Q4_K_M
  │
  ◄── JSON response ──────────────────────────────────
```

---

## VM inventory

| VM | Internal IP | Type | Role |
|---|---|---|---|
| `engine-vm` | 10.0.1.10 | e2-small | iii engine (WS broker) + iii-http (REST :3111) |
| `inference-vm` | 10.0.1.11 | e2-standard-2 | Python inference worker + gemma model |
| `caller-vm` | 10.0.1.12 | e2-small | TypeScript caller worker |
| `gateway-vm` | 10.0.1.13 + **34.10.75.30** | e2-micro | nginx public reverse proxy |

---

## API

### `POST /v1/chat/completions`

**Request**
```json
{
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user",   "content": "What is 2+2?"}
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

### curl command (working, tested)

```bash
curl -s -X POST http://34.10.75.30/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"What is 2+2? Answer in one word"}]}' \
  --max-time 120
```

**Actual response received:**
```json
{"result":{"0":"2","1":"\n","success":"You've connected two workers and they're interoperating seamlessly, now let's add a few more workers to expand this project's functionality."}}
```

### Health check

```bash
curl http://34.10.75.30/healthz
# {"status":"ok"}
```

---

## Repository layout

```
quickstart-devops/
├── terraform/
│   ├── main.tf                    VPC, subnet, NAT, firewall rules, 4 VMs
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── scripts/
│   ├── setup-engine.sh            Startup script for engine-vm
│   ├── setup-inference-worker.sh  Startup script for inference-vm
│   ├── setup-caller-worker.sh     Startup script for caller-vm
│   └── setup-gateway.sh           Startup script for gateway-vm
├── workers/
│   ├── inference-worker/
│   │   ├── inference_worker.py    Python RPC function
│   │   └── requirements.txt
│   └── caller-worker/
│       └── src/worker.ts          TypeScript HTTP + relay functions
├── systemd/
│   ├── iii-engine.service
│   ├── inference-worker.service
│   └── caller-worker.service
└── README.md
```

---

## Deploy from scratch

### Prerequisites

- Terraform ≥ 1.5
- `gcloud` CLI authenticated (`gcloud auth login`)
- GCP project with billing enabled

### 1 — Enable APIs

```bash
gcloud services enable compute.googleapis.com iap.googleapis.com \
  --project=YOUR_PROJECT_ID
```

### 2 — Clone and configure

```bash
git clone <YOUR_REPO_URL>
cd quickstart-devops/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set project_id = "YOUR_PROJECT_ID"
```

### 3 — Provision infrastructure

```bash
terraform init
terraform apply   # type 'yes' when prompted
```

Terraform prints the gateway public IP when done.

### 4 — Wait for VM startup scripts

The startup scripts run automatically on first boot:

```bash
# Engine, caller, gateway: ~3 minutes
# Inference: ~5 minutes (builds llama-cpp-python + downloads model)

# Monitor inference VM (the slowest):
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
# SSH to any VM via IAP (no public IP needed)
gcloud compute ssh engine-vm    --tunnel-through-iap --zone us-central1-a
gcloud compute ssh inference-vm --tunnel-through-iap --zone us-central1-a
gcloud compute ssh caller-vm    --tunnel-through-iap --zone us-central1-a
gcloud compute ssh gateway-vm   --tunnel-through-iap --zone us-central1-a

# Check service status
sudo systemctl status iii-engine       # engine-vm
sudo systemctl status inference-worker # inference-vm
sudo systemctl status caller-worker    # caller-vm
sudo systemctl status nginx            # gateway-vm

# Stream logs
sudo journalctl -u iii-engine -f
sudo journalctl -u inference-worker -f
sudo journalctl -u caller-worker -f

# Test internal connectivity (from gateway-vm)
curl -s http://10.0.1.10:3111/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"ping"}]}' --max-time 120
```

---

## Lessons learned during deployment

These are real issues hit during deployment — documented for reproducibility:

**1. iii CLI installs via shell script, not npm.**
`npm install -g iii` installs a completely unrelated package (v0.1.6).
The correct install is:
```bash
curl -fsSL https://install.iii.dev/iii/main/install.sh | sh
```

**2. The Python SDK imports as `iii`, not `iii_sdk`.**
`pip install iii-sdk==0.11.0` installs correctly, but the importable module
is `iii`, not `iii_sdk`. Use `from iii import register_worker, InitOptions`.

**3. iii config.yaml format.**
The engine config only accepts `workers:` and `modules:` at the top level.
The `server:` block used in earlier docs does not exist in v0.12.0.

**4. Workers connect to remote engine via `III_URL` env var.**
`III_URL=ws://10.0.1.10:49134` on each worker VM is all that's needed to
point workers at the remote engine. Workers connect over WebSocket and
register their functions automatically.

**5. nginx proxies to engine-vm:3111, not caller-vm.**
The HTTP API is served by the `iii-http` built-in worker running inside
the iii engine process. nginx on gateway-vm proxies to `engine-vm:3111`.

**6. Use llama-cpp-python for GGUF inference, not transformers.**
`transformers` loads GGUF via PyTorch which is extremely slow on CPU
(>60s per request). `llama-cpp-python` with the same GGUF file runs
inference in 5-15s on an e2-standard-2.

---

## Production hardening

**Network**
- Add TLS: use a managed GCP HTTPS load balancer in front of gateway-vm, or
  install Certbot on gateway-vm for Let's Encrypt. Traffic is currently HTTP.
- Add Cloud Armor rate limiting on the load balancer to prevent inference
  CPU exhaustion from a single client.
- Enable VPC Flow Logs and route to Cloud Logging for audit trail of all
  east-west subnet traffic.
- Restrict IAP SSH to specific service accounts or a VPN range rather than
  all of `35.235.240.0/20`.

**Secrets**
- Move HuggingFace tokens and any API keys into Secret Manager; inject at
  runtime via the VM service account. Nothing sensitive should appear in
  startup scripts or Terraform files.
- Pin the GGUF model file to a SHA-256 checksum and verify on download to
  prevent supply-chain tampering.

**Reliability**
- The inference-worker is a single point of failure. Add a second
  inference-vm behind an internal TCP load balancer. The iii engine
  round-robins across multiple workers registering the same function.
- Set `StartLimitBurst` and `StartLimitIntervalSec` in the systemd unit to
  prevent a crash loop from consuming quota.
- Use a managed Redis (Memorystore) for the `iii-state` worker instead of
  the default file-based store.

**Observability**
- The iii engine exposes Prometheus metrics on port 9464. Scrape with
  a Cloud Monitoring Prometheus setup and alert on RPC error rate and
  invocation queue depth.
- Add a `request-id` header at nginx and propagate it through the RPC chain
  so logs from all four VMs can be correlated per request.

---

## What I would do differently for a 100× larger model

A 100× larger model (~27B parameters, ~15GB Q4) exceeds both the RAM and
compute of any free-tier VM and makes CPU inference impractical.

**Hardware**
Switch inference-vm to a GPU instance: `a2-highgpu-1g` (A100 40GB) on GCP
fits a 27B Q4 model comfortably. For 70B+ models, use multi-GPU with tensor
parallelism. Spot/preemptible instances cut cost by 60-80% with a simple
restart policy.

**Serving**
Replace `llama-cpp-python` with **vLLM**, which implements PagedAttention
for efficient GPU KV-cache management and continuous batching for high
throughput. vLLM ships an OpenAI-compatible HTTP server, so the caller-worker
interface stays identical.

**Model storage**
Store weights on a GCS bucket and mount with Cloud Storage FUSE, or
pre-bake a persistent disk snapshot. This eliminates the multi-minute
re-download on every reprovisioning.

**Autoscaling**
Use a GCP Managed Instance Group for inference-vm with custom Prometheus
metrics (GPU utilization, RPC queue depth) driving autoscaling. Scale to
zero overnight and pre-warm on a schedule before business hours.

**Cost estimate**
An A100 40GB on GCP costs ~$3.50/hr on-demand, ~$1.20/hr preemptible.
A 27B Q4 model at moderate traffic fits on one A100, making the inference
tier ~$850-2500/month depending on uptime strategy.
#   q u i c k s t a r t - d e v o p s  
 
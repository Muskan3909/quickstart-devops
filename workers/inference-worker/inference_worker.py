"""
inference-worker — Python worker for the iii RPC mesh.

Registered function:  inference::run_inference
  Input:  { "messages": [{"role": "user", "content": "..."}, ...] }
  Output: "<model reply string>"

Key lessons:
  - iii-sdk installs as PyPI package 'iii-sdk' but imports as 'iii' (not 'iii_sdk')
  - Use llama-cpp-python for GGUF inference, not transformers (10x faster on CPU)
  - Set III_URL env var to point at the remote engine WebSocket
"""
import os
from llama_cpp import Llama
from iii import register_worker, InitOptions

# Connect to the iii engine via WebSocket (engine-vm private IP)
iii = register_worker(
    os.environ.get("III_URL", "ws://10.0.1.10:49134"),
    InitOptions(worker_name="inference-worker"),
)

MODEL_PATH = os.environ.get("MODEL_PATH", "/opt/models/gemma-3-270m-it-Q4_K_M.gguf")
print(f"Loading model from {MODEL_PATH}...")
llm = Llama(
    model_path=MODEL_PATH,
    n_ctx=2048,
    n_threads=int(os.environ.get("LLM_THREADS", "2")),
    verbose=False,
)
print("Model loaded.")


def run_inference_handler(payload: dict):
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

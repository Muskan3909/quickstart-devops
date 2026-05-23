output "gateway_public_ip" {
  value = google_compute_address.gateway_external.address
}

output "api_endpoint" {
  value = "http://${google_compute_address.gateway_external.address}/v1/chat/completions"
}

output "ssh_commands" {
  value = {
    engine    = "gcloud compute ssh engine-vm    --tunnel-through-iap --zone ${var.zone}"
    inference = "gcloud compute ssh inference-vm --tunnel-through-iap --zone ${var.zone}"
    caller    = "gcloud compute ssh caller-vm    --tunnel-through-iap --zone ${var.zone}"
    gateway   = "gcloud compute ssh gateway-vm   --tunnel-through-iap --zone ${var.zone}"
  }
}

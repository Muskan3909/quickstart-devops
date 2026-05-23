terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# ── VPC & Subnet ─────────────────────────────────────────────────────────────

resource "google_compute_network" "vpc" {
  name                    = "quickstart-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "private" {
  name                     = "quickstart-private"
  ip_cidr_range            = "10.0.1.0/24"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true
}

# ── Cloud NAT (private VMs pull packages without public IPs) ─────────────────

resource "google_compute_router" "router" {
  name    = "quickstart-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "quickstart-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# ── Firewall Rules ────────────────────────────────────────────────────────────

resource "google_compute_firewall" "internal" {
  name    = "quickstart-internal"
  network = google_compute_network.vpc.name
  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
  source_ranges = ["10.0.1.0/24"]
}

resource "google_compute_firewall" "iap_ssh" {
  name    = "quickstart-iap-ssh"
  network = google_compute_network.vpc.name
  allow { protocol = "tcp"; ports = ["22"] }
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["iap-ssh"]
}

resource "google_compute_firewall" "gateway_http" {
  name    = "quickstart-gateway-http"
  network = google_compute_network.vpc.name
  allow { protocol = "tcp"; ports = ["80", "443"] }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["gateway"]
}

# ── Static IPs ────────────────────────────────────────────────────────────────

resource "google_compute_address" "engine_internal" {
  name         = "engine-internal"
  subnetwork   = google_compute_subnetwork.private.id
  address_type = "INTERNAL"
  address      = "10.0.1.10"
  region       = var.region
}

resource "google_compute_address" "inference_internal" {
  name         = "inference-internal"
  subnetwork   = google_compute_subnetwork.private.id
  address_type = "INTERNAL"
  address      = "10.0.1.11"
  region       = var.region
}

resource "google_compute_address" "caller_internal" {
  name         = "caller-internal"
  subnetwork   = google_compute_subnetwork.private.id
  address_type = "INTERNAL"
  address      = "10.0.1.12"
  region       = var.region
}

resource "google_compute_address" "gateway_internal" {
  name         = "gateway-internal"
  subnetwork   = google_compute_subnetwork.private.id
  address_type = "INTERNAL"
  address      = "10.0.1.13"
  region       = var.region
}

resource "google_compute_address" "gateway_external" {
  name   = "gateway-external"
  region = var.region
}

# ── VM: engine-vm ─────────────────────────────────────────────────────────────

resource "google_compute_instance" "engine" {
  name         = "engine-vm"
  machine_type = "e2-small"
  zone         = var.zone
  tags         = ["iap-ssh", "engine"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 20
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.private.id
    network_ip = google_compute_address.engine_internal.address
  }

  metadata = {
    startup-script = file("${path.module}/../scripts/setup-engine.sh")
  }

  service_account { scopes = ["cloud-platform"] }
}

# ── VM: inference-vm ──────────────────────────────────────────────────────────

resource "google_compute_instance" "inference" {
  name         = "inference-vm"
  machine_type = "e2-standard-2"
  zone         = var.zone
  tags         = ["iap-ssh", "inference-worker"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 30
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.private.id
    network_ip = google_compute_address.inference_internal.address
  }

  metadata = {
    startup-script = file("${path.module}/../scripts/setup-inference-worker.sh")
  }

  service_account { scopes = ["cloud-platform"] }
}

# ── VM: caller-vm ─────────────────────────────────────────────────────────────

resource "google_compute_instance" "caller" {
  name         = "caller-vm"
  machine_type = "e2-small"
  zone         = var.zone
  tags         = ["iap-ssh", "caller-worker"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 20
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.private.id
    network_ip = google_compute_address.caller_internal.address
  }

  metadata = {
    startup-script = file("${path.module}/../scripts/setup-caller-worker.sh")
  }

  service_account { scopes = ["cloud-platform"] }
}

# ── VM: gateway-vm ────────────────────────────────────────────────────────────

resource "google_compute_instance" "gateway" {
  name         = "gateway-vm"
  machine_type = "e2-micro"
  zone         = var.zone
  tags         = ["iap-ssh", "gateway"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 10
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.private.id
    network_ip = google_compute_address.gateway_internal.address
    access_config {
      nat_ip = google_compute_address.gateway_external.address
    }
  }

  metadata = {
    startup-script = templatefile("${path.module}/../scripts/setup-gateway.sh", {
      engine_ip = google_compute_address.engine_internal.address
    })
  }

  service_account { scopes = ["cloud-platform"] }
}

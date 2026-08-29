resource "google_compute_network" "main" {
  name                    = "inference-net"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "main" {
  name                     = "inference-subnet"
  ip_cidr_range            = "10.10.0.0/24"
  region                   = var.region
  network                  = google_compute_network.main.id
  private_ip_google_access = true
}

# The ONLY ingress rule. A custom-mode VPC has an implied deny-all ingress, so
# everything not listed here -- the Kubernetes API on 6443, Envoy's NodePort,
# Grafana -- is unreachable from the internet. Those all ride SSH port-forwards
# inside this one session, which is why no second rule is ever needed.
resource "google_compute_firewall" "ssh" {
  name        = "inference-allow-ssh"
  network     = google_compute_network.main.name
  description = "SSH from the operator's address only. Nothing else may enter."

  source_ranges = [var.allowed_ssh_cidr]
  target_tags   = [local.network_tag]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

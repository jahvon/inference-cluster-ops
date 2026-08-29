variable "project_id" {
  type        = string
  description = "GCP project to deploy into."
}

variable "region" {
  type        = string
  description = "Region for regional resources. Must have L4 capacity and quota."
  default     = "us-central1"
}

variable "zone" {
  type        = string
  description = "Zone for the instance and its disks. Must be inside var.region."
  default     = "us-central1-a"
}

variable "instance_name" {
  type        = string
  description = "Name of the inference VM. Also prefixes its disks."
  default     = "inference-node"
}

variable "use_spot" {
  type        = bool
  description = <<-EOT
    Spot (preemptible) vs on-demand.

    Changing this REPLACES the instance -- provisioning_model is ForceNew in the
    provider, not an in-place edit. The boot disk is destroyed; the data disk is a
    separate resource and survives, and it now holds the container image store as
    well as weights and k3s state, so a rebuild re-pulls nothing. `make up SPOT=...`
    warns before doing this. Spot and on-demand also draw on separate GPU quotas.
  EOT
  default     = true
}

variable "running" {
  type        = bool
  description = "The on/off switch. false stops the VM (disks still billed), true starts it."
  default     = true
}

variable "boot_disk_gb" {
  type        = number
  description = "Boot disk size. OS only -- treated as disposable. Images and cluster state live on the data disk."
  default     = 60

  validation {
    condition     = var.boot_disk_gb >= 50
    error_message = "The DLVM image needs at least 50GB."
  }
}

variable "data_disk_gb" {
  type        = number
  description = <<-EOT
    Data disk, mounted at /opt/data. Survives instance replacement, so toggling
    use_spot re-downloads nothing. Holds four things:

      /opt/data/huggingface   model weights
      /opt/data/k3s           k3s state AND the containerd image store
      /opt/data/storage       local-path PVCs (Prometheus TSDB, Grafana)

    Sized against what actually lands here: ~10GB of vLLM image, a 20Gi
    Prometheus volume, ~1GB of weights, and a few GB of k3s state and other
    images -- roughly 35GB in use, so 100 leaves about 3x headroom.

    This disk is your idle cost floor. It bills whether the VM is running or
    not, and pd-balanced is not free-tier eligible (the Always Free 30GB
    allowance is pd-standard only).
  EOT
  default     = 100
}

variable "image_family" {
  type        = string
  description = <<-EOT
    Deep Learning VM image family (project deeplearning-platform-release). Ships
    the NVIDIA driver and the container toolkit that k3s needs to detect the
    nvidia container runtime.

    These families are retired as they age -- cu128/nvidia-570 was withdrawn and
    a 404 at plan time is what that looks like. List the current ones with:

      gcloud compute images list --project deeplearning-platform-release \
        --no-standard-images --format='value(family)'

    A newer driver runs older CUDA runtimes, so if vLLM fails with a CUDA version
    error, move this FORWARD rather than pinning vLLM back.
  EOT
  default     = "common-cu129-ubuntu-2204-nvidia-580"
}

variable "k3s_version" {
  type        = string
  description = <<-EOT
    Pinned k3s release (INSTALL_K3S_VERSION). Pinned rather than "latest" so a
    rebuild is reproducible; must be >= v1.30 for --default-runtime.
  EOT
  default     = "v1.35.8+k3s1"
}

# --- access -----------------------------------------------------------------
# Plain SSH, deliberately: no IAP, no mesh VPN, no account dependency a reviewer
# does not already have. See README "Design decisions".

variable "allowed_ssh_cidr" {
  type        = string
  description = <<-EOT
    The ONLY source range allowed to reach port 22. Everything else -- including
    every NodePort -- is closed by the VPC's implied deny-all ingress.

    Deliberately has no default: a wrong-by-omission 0.0.0.0/0 is the exact failure
    this variable exists to prevent. Run `make my-ip` to get the value to paste.
  EOT

  validation {
    condition     = can(cidrhost(var.allowed_ssh_cidr, 0))
    error_message = "allowed_ssh_cidr must be a CIDR block, e.g. 203.0.113.4/32. Run 'make my-ip'."
  }
}

variable "ssh_user" {
  type        = string
  description = "Login name on the node. Arbitrary -- metadata ssh-keys creates it."
  default     = "ops"
}

variable "ssh_public_key_path" {
  type        = string
  description = "Public key installed via instance metadata. Its private half is what the Makefile's SSH_KEY points at."
  default     = "~/.ssh/id_ed25519.pub"
}

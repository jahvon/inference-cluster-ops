locals {
  provisioning_model = var.use_spot ? "SPOT" : "STANDARD"
  network_tag        = "inference-node"
  data_mount         = "/opt/data"

  # One machine type, deliberately. This is an experimentation box: a single L4
  # is what the workload is sized for, and G2 fixes the GPU count by machine
  # type anyway. Moving up means editing these two lines and the hourly rate in
  # outputs.tf.
  machine_type = "g2-standard-8" # 1x L4, 8 vCPU, 32GB
  gpu_count    = 1
}

data "google_compute_image" "dlvm" {
  family  = var.image_family
  project = "deeplearning-platform-release"
}

# Standalone so it outlives the instance. Toggling use_spot replaces the VM and
# destroys the boot disk; weights, k3s state, and the container image store here
# are untouched.
resource "google_compute_disk" "data" {
  name = "${var.instance_name}-data"
  type = "pd-balanced"
  zone = var.zone
  size = var.data_disk_gb

  labels = {
    component = "inference"
    contents  = "data"
  }
}

resource "google_compute_instance" "inference" {
  name         = var.instance_name
  machine_type = local.machine_type
  zone         = var.zone
  tags         = [local.network_tag]

  # The cost switch. Terraform owns it rather than `gcloud start/stop` so state
  # never drifts and `make status` can trust what it reads back.
  desired_status = var.running ? "RUNNING" : "TERMINATED"

  # G2 presets the L4, so this looks redundant -- it is not. Provider >= 7.9.0
  # reconciles preset-GPU families against config and will destroy/recreate the
  # instance if the block is absent.
  guest_accelerator {
    type  = "nvidia-l4"
    count = local.gpu_count
  }

  scheduling {
    on_host_maintenance = "TERMINATE" # mandatory for every GPU VM: no live migration
    automatic_restart   = !var.use_spot
    preemptible         = var.use_spot
    provisioning_model  = local.provisioning_model

    # STOP, not DELETE: a preemption should cost you the VM, not the disks.
    instance_termination_action = var.use_spot ? "STOP" : null
  }

  boot_disk {
    auto_delete = true

    initialize_params {
      image = data.google_compute_image.dlvm.self_link
      size  = var.boot_disk_gb
      type  = "pd-balanced"
    }
  }

  attached_disk {
    source      = google_compute_disk.data.id
    device_name = "data" # -> /dev/disk/by-id/google-data
    mode        = "READ_WRITE"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id

    # Ephemeral external IP. Carries egress (image + weight pulls) AND inbound SSH.
    # Ephemeral, not reserved: a reserved address bills while UNattached, which is
    # precisely when this box is stopped -- the state it spends most of its life in.
    # The cost is that the IP changes across stop/start, so everything reads it from
    # the vm_ip output rather than caching it.
    access_config {}
  }

  metadata = {
    # Metadata keys, not OS Login: OS Login derives the username from the IAM
    # identity, which makes `ssh <user>@<ip>` something you have to look up. A
    # predictable login name is the whole point of the SSH-only access model.
    ssh-keys = "${var.ssh_user}:${file(pathexpand(var.ssh_public_key_path))}"
  }

  metadata_startup_script = templatefile("${path.module}/startup.sh.tftpl", {
    k3s_version = var.k3s_version
    data_mount  = local.data_mount
  })

  service_account {
    email  = google_service_account.inference.email
    scopes = ["cloud-platform"]
  }

  labels = {
    component = "inference"
  }

  depends_on = [google_project_service.apis]
}

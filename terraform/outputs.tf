locals {
  # Rough list price for a g2-standard-8 including its L4, USD/hour.
  # Good enough to keep the burn rate visible in `flow show status`; not
  # billing-accurate.
  hourly_rate  = 0.85 * (var.use_spot ? 0.88 : 1.0)
  disk_gb      = var.boot_disk_gb + var.data_disk_gb
  idle_monthly = local.disk_gb * 0.10 # pd-balanced, USD/GB/month
}

output "project_id" {
  value = var.project_id
}

output "zone" {
  value = var.zone
}

output "instance_name" {
  value = google_compute_instance.inference.name
}

output "current_status" {
  description = "Live instance status. TERMINATED means stopped -- either by you or by preemption."
  value       = google_compute_instance.inference.current_status
}

output "provisioning_model" {
  description = "SPOT or STANDARD. Changing it replaces the instance."
  value       = local.provisioning_model
}

output "vm_ip" {
  description = <<-EOT
    The node's external IP -- how you SSH in. EPHEMERAL: it changes on every
    stop/start, so read it from here rather than caching it. Empty while stopped.
    Only port 22 is reachable, and only from var.allowed_ssh_cidr.
  EOT
  value       = try(google_compute_instance.inference.network_interface[0].access_config[0].nat_ip, "")
}

output "ssh_user" {
  description = "Login name on the node, installed via instance metadata."
  value       = var.ssh_user
}

output "hourly_rate_estimate" {
  description = "Approximate USD/hour while RUNNING."
  value       = format("$%.2f/hr (%s)", local.hourly_rate, local.provisioning_model)
}

output "idle_monthly_estimate" {
  description = "Approximate USD/month while stopped -- disks only. This is your floor until you destroy."
  value       = format("$%.2f/mo for %dGB of disk", local.idle_monthly, local.disk_gb)
}

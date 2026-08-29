resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
  ])

  service = each.value

  # Leave APIs enabled on destroy: other things in the project may depend on them
  disable_on_destroy = false
}

resource "google_service_account" "inference" {
  account_id   = "inference-node"
  display_name = "vLLM inference node"
  description  = "Runtime identity for the GPU inference VM"
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.inference.email}"
}

resource "google_project_iam_member" "monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.inference.email}"
}

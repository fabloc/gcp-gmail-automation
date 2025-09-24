# -------------------------------------------------------------------
# Data Sources
# -------------------------------------------------------------------

# Get project data, including the project number
data "google_project" "project" {
  project_id = var.project_id
}

# Get the default compute service account, used by Eventarc
data "google_compute_default_service_account" "default" {
  project = var.project_id
}

# -------------------------------------------------------------------
# 0. Datastore Database
# (Replaces the App Engine resource)
# -------------------------------------------------------------------

resource "google_firestore_database" "datastore" {

  project     = var.project_id
  name        = "(default)" # Required name for the default database
  location_id = var.region
  type        = "DATASTORE_MODE" # This sets it to Datastore
}

# -------------------------------------------------------------------
# 1. Cloud Storage Bucket
# -------------------------------------------------------------------

resource "google_storage_bucket" "email_storage" {

  project  = var.project_id
  name     = "${data.google_project.project.number}-email-storage"
  uniform_bucket_level_access = true
  public_access_prevention = "enforced"
  soft_delete_policy {
    retention_duration_seconds = 604800 # 7 days
  }
  location = var.region # Explicitly regional
}

# -------------------------------------------------------------------
# 2. Pub/Sub Topic
# -------------------------------------------------------------------

resource "google_pubsub_topic" "gmail_watch" {

  project = var.project_id
  name    = "gmail-watch"

  # Constrains message storage to your region
  message_storage_policy {
    allowed_persistence_regions = [var.region]
  }
}

resource "google_pubsub_topic_iam_member" "member" {
  project = var.project_id
  topic = google_pubsub_topic.gmail_watch.name
  role = "roles/pubsub.publisher"
  member = "serviceAccount:gmail-api-push@system.gserviceaccount.com"
}

# -------------------------------------------------------------------
# 3. Service Account & IAM
# -------------------------------------------------------------------

resource "google_service_account" "cloud_run_sa" {

  project      = var.project_id
  account_id   = "email-automation-cloud-run-sa"
  display_name = "Email Automation Cloud Run SA"
}

# Associate the required roles to the service account
resource "google_project_iam_member" "cloud_run_sa_roles" {
  depends_on = [google_service_account.cloud_run_sa]

  for_each = toset([
    "roles/datastore.user",
    "roles/storage.objectUser",
    "roles/secretmanager.secretAccessor",
    "roles/iam.serviceAccountTokenCreator", # Assuming "Accessor" meant "Creator"
    "roles/logging.logWriter"
  ])

  project = var.project_id
  role    = each.key
  member  = google_service_account.cloud_run_sa.member
}

resource "google_service_account" "eventarc_sa" {

  project      = var.project_id
  account_id   = "email-automation-eventarc-sa"
  display_name = "Email Automation Eventarc SA"
}

# Associate the required roles to the service account
resource "google_project_iam_member" "eventarc_sa_roles" {
  depends_on = [google_service_account.eventarc_sa]

  for_each = toset([
    "roles/eventarc.eventReceiver",
    "roles/run.invoker"
  ])

  project = var.project_id
  role    = each.key
  member  = google_service_account.eventarc_sa.member
}

# -------------------------------------------------------------------
# 4. Service Account Key & Secret Manager
# -------------------------------------------------------------------

# Create the service account key in-memory
resource "google_service_account_key" "sa_key" {
  depends_on = [google_service_account.cloud_run_sa]

  service_account_id = google_service_account.cloud_run_sa.name
}

# Create the secret container
resource "google_secret_manager_secret" "sa_key_secret" {

  project   = var.project_id
  secret_id = "dwd-service-account-key"

  replication {
    # Explicitly regional replication
    auto {}
  }
}

# Add the key data as a version to the secret
resource "google_secret_manager_secret_version" "sa_key_secret_version" {
  secret      = google_secret_manager_secret.sa_key_secret.id
  secret_data = base64decode(google_service_account_key.sa_key.private_key)
}

# -------------------------------------------------------------------
# 5. Cloud Run Service
# -------------------------------------------------------------------

resource "google_cloud_run_v2_service" "email_automation" {
  depends_on = [
    google_secret_manager_secret_version.sa_key_secret_version,
    google_storage_bucket.email_storage,
    google_firestore_database.datastore
  ]

  project  = var.project_id
  location = var.region
  name     = "email-automation-service"
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  deletion_protection = false

  template {
    # Run as the SA we created so the app has the right permissions
    service_account = google_service_account.cloud_run_sa.email

    # Set scaling configuration
    max_instance_request_concurrency = 1
    scaling {
      max_instance_count = 1
    }

    containers {
      image = "europe-west1-docker.pkg.dev/${var.project_id}/${var.artifact_registry_repo}/${var.service_name}"

      env {
        name  = "GCS_BUCKET"
        value = google_storage_bucket.email_storage.name
      }
      env {
        name  = "MONITORED_EMAIL_ADDRESS"
        value = var.target_email_address
      }
      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }

      # Define the volume mount
      volume_mounts {
        name       = "secret-key-volume"
        mount_path = "/etc/secrets" # Mount the directory
      }
    }

    # Define the volume source (the secret)
    volumes {
      name = "secret-key-volume"
      secret {
        secret = google_secret_manager_secret.sa_key_secret.secret_id
        items {
          version = "latest"
          path    = "key.json" # This creates the file "key.json" at the mount path
        }
      }
    }
  }
}

# -------------------------------------------------------------------
# 6. Eventarc Trigger
# -------------------------------------------------------------------

# Create the Eventarc trigger
resource "google_eventarc_trigger" "gmail_watch_trigger" {
  depends_on = [
    google_project_iam_member.eventarc_sa_roles
  ]

  project  = var.project_id
  location = var.region
  name     = "gmail-watch-trigger"

  service_account = google_service_account.eventarc_sa.email

  # Match Pub/Sub messages
  matching_criteria {
    attribute = "type"
    value     = "google.cloud.pubsub.topic.v1.messagePublished"
  }

  # Define the destination (Cloud Run)
  destination {
    cloud_run_service {
      service = google_cloud_run_v2_service.email_automation.name
      region  = var.region
    }
  }

  # Define the source (Pub/Sub)
  transport {
    pubsub {
      topic = google_pubsub_topic.gmail_watch.id
    }
  }
}

# -------------------------------------------------------------------
# 7. Cloud Scheduler for Weekly Cron
# -------------------------------------------------------------------

# 7a. Create a dedicated service account for the scheduler
resource "google_service_account" "scheduler_sa" {

  project      = var.project_id
  account_id   = "email-automation-scheduler-sa"
  display_name = "Email Automation Scheduler SA"
}

# 7b. Give the scheduler SA permission to invoke the Cloud Run service
resource "google_cloud_run_service_iam_member" "scheduler_invoker" {
  depends_on = [google_cloud_run_v2_service.email_automation]

  project  = var.project_id
  location = var.region
  service  = google_cloud_run_v2_service.email_automation.name
  role     = "roles/run.invoker"
  member   = google_service_account.scheduler_sa.member
}

# 7c. Create the weekly cron job
resource "google_cloud_scheduler_job" "renew_job" {
  depends_on = [google_cloud_run_service_iam_member.scheduler_invoker]

  project   = var.project_id
  region    = var.region
  name      = "renew-gmail-push-permissions"
  schedule  = "0 0 * * 1" # Every Monday at 9:00 AM
  time_zone = "Etc/UTC"

  http_target {
    # Call the Cloud Run service URL + the specific endpoint
    uri = "${google_cloud_run_v2_service.email_automation.uri}/renew_gmail_push_permissions"

    # I'm assuming POST is correct. You can change this to "GET" if needed.
    http_method = "POST"

    # Authenticate as the scheduler service account
    oidc_token {
      service_account_email = google_service_account.scheduler_sa.email
      audience              = google_cloud_run_v2_service.email_automation.uri
    }
  }
}
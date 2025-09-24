output "cloud_run_service_url" {
  description = "The URL of the deployed Cloud Run service."
  value       = google_cloud_run_v2_service.email_automation.uri
}

output "storage_bucket_name" {
  description = "The name of the created Cloud Storage bucket."
  value       = google_storage_bucket.email_storage.name
}

output "pubsub_topic_name" {
  description = "The name of the created Pub/Sub topic."
  value       = google_pubsub_topic.gmail_watch.name
}

output "application_service_account_email" {
  description = "The email of the service account for the application."
  value       = google_service_account.cloud_run_sa.email
}

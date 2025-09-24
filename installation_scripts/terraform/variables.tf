variable "project_id" {
  description = "The GCP project ID to deploy resources into."
  type        = string
}

variable "region" {
  description = "The GCP region for resources like Cloud Run and Eventarc."
  type        = string
  default     = "europe-west1"
}

variable "target_email_address" {
  description = "The email address the application will monitor."
  type        = string
  sensitive   = true
}

variable "artifact_registry_repo" {
  description = "Name of the Artifact Registry Repository where the Image to deploy in Cloud Run is stored."
  type        = string
  sensitive   = true
}

variable "service_name" {
  description = "The name of the Cloud Run service."
  type        = string
  sensitive   = true
}
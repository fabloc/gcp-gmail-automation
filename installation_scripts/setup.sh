#!/bin/bash
#
# Performs an automated installation of the Customer Data Platform
# Modify the Globals variables prior to running this script
#################################

# Global variables
#################################
PROJECT_ID="email-tests-472712"                             # ID of the project where you want to deploy
REGION="europe-west1"                                       # Name of the region
AUTH_USER="admin@fabienlocquet.altostrat.com"               # User that will run the application
ARTIFACT_REGISTRY_REPO="email-automation-gcr"               # Name of the Artifact Registry Repository
TARGET_EMAIL_ADDRESS="admin@fabienlocquet.altostrat.com"    # Name of the email to manager
SERVICE_NAME="email-automation-service"                     # Name of the Cloud Run Service
#################################


# do not modify below here

function check_if_project_id_is_setup() {
    if [ -z "$PROJECT_ID" ]; then
        echo "Error: You must configure your PROJECT_ID."
        exit 1
    fi
}


function check_gcloud_authentication() {
    # Check if the user is authenticated with gcloud
    local AUTHENTICATED_USER=$(gcloud auth list --format="value(account)" --filter="status:ACTIVE")

    if [ -z "$AUTHENTICATED_USER" ]; then
    echo "No authenticated user found. Please authenticate using 'gcloud auth login'."
    exit 1
    else
    echo "Authenticated user is: $AUTHENTICATED_USER"
    fi
}

function check_gcp_project() {
# Check if the project exists
local PROJECT_NAME=$(gcloud projects describe ${PROJECT_ID//\"} --format="value(name)")

 if [ -z "$PROJECT_NAME" ]; then
   echo "Project $PROJECT_ID does not exist."
   exit 1
 else
   echo "Project $PROJECT_ID exists."
 fi

 # Check if the environment is configured for the project
 local CONFIGURED_PROJECT_ID=$(gcloud config get-value project 2>/dev/null)

 if [ "$CONFIGURED_PROJECT_ID" != "$PROJECT_ID" ]; then
   echo "Current environment is not configured for project $PROJECT_ID. Please run 'gcloud config set project $PROJECT_ID'."
   exit 1
 else
   echo "Environment is configured for project $PROJECT_ID."
 fi
}


function check_gcp_constraints() {
 local CONSTRAINTS=(
   "iam.disableServiceAccountKeyCreation"
   "iam.allowedPolicyMemberDomains"
 )


 for CONSTRAINT in "${CONSTRAINTS[@]}"
 do
   local CONSTRAINT_STATUS=$(gcloud alpha resource-manager org-policies describe --effective --project=$PROJECT_ID $CONSTRAINT | sed 's/booleanPolicy: {}/ALLOW/' | grep -E 'constraint:|ALLOW' | awk '/ALLOW/ {print "allowed"}')


   if [ -z "$CONSTRAINT_STATUS" ]; then
     echo "Constraint $CONSTRAINT not found or not configured for this project."
     echo "Please ensure that the $CONSTRAINT constraint is authorized."
     exit 1
   elif [ "$CONSTRAINT_STATUS" = "allowed" ]; then
     echo "Constraint $CONSTRAINT is allowed."
   else
     echo "Constraint $CONSTRAINT is not allowed."
     echo "Please ensure that the $CONSTRAINT constraint is authorized."
     exit 1
   fi
 done
}

# Running checks before deploy
echo ""
echo "Running pre-checks"
echo ""
check_if_project_id_is_setup

# Check authentication
echo "***** Checking authentication with gcloud *****"
check_gcloud_authentication

# Check project configuration
echo "***** Checking project configuration *****"
check_gcp_project

# Check project constraints
echo "***** Checking project constraints *****"
check_gcp_constraints


# Enabling the services
gcloud services enable artifactregistry.googleapis.com cloudbuild.googleapis.com run.googleapis.com compute.googleapis.com
gcloud services enable servicenetworking.googleapis.com cloudresourcemanager.googleapis.com gmail.googleapis.com cloudscheduler.googleapis.com

# Create cloud_run_sa service account
gcloud iam service-accounts create email-automation-cloud-run-sa \
    --display-name="Email Automation Cloud Run SA" \
    --project=$PROJECT_ID

# The following steps are required to configure domain-wide delegation for the service account.
# This allows the service account to access user data across your Google Workspace domain.
#
# 1. Get the service account's unique ID:
CLIENT_ID=$(gcloud iam service-accounts describe email-automation-cloud-run-sa@$PROJECT_ID.iam.gserviceaccount.com --project=$PROJECT_ID --format='value(oauth2ClientId)')

# 2. Authorize the service account in the Google Workspace Admin console:
#    a. Go to your Google Workspace Admin console (admin.google.com).
#    b. Navigate to "Security" > "Access and data control" > "API controls".
#    c. In the "Domain-wide delegation" section, click "Manage Domain-wide delegation".
#    d. Click "Add new".
#    e. In the "Client ID" field, enter the following Client ID:
#       $CLIENT_ID
#    f. In the "OAuth Scopes" field, enter the following scopes:
#       https://www.googleapis.com/auth/gmail.readonly,https://www.googleapis.com/auth/gmail.modify
#    g. Click "Authorize".

echo "--------------------------------------------------------------------------------"
echo "Domain-wide delegation configuration required."
echo "Please follow the instructions in the setup.sh script to authorize the service account."
echo "Service Account Client ID: $CLIENT_ID"
echo "--------------------------------------------------------------------------------"

read -p "Press [Enter] key to continue after you have configured domain-wide delegation..."

cp -f variables.auto.tfvars.tmpl terraform/variables.auto.tfvars

# Updating the Project and Location details in app config and override files
sed -i "s|project_id = \"\"|project_id = \"${PROJECT_ID}\"|" terraform/variables.auto.tfvars
sed -i "s|region = \"\"|region = \"${REGION}\"|" terraform/variables.auto.tfvars
sed -i "s|artifact_registry_repo = \"\"|artifact_registry_repo = \"${ARTIFACT_REGISTRY_REPO}\"|" terraform/variables.auto.tfvars
sed -i "s|service_name = \"\"|service_name = \"${SERVICE_NAME}\"|" terraform/variables.auto.tfvars
sed -i "s|target_email_address = \"\"|target_email_address = \"${TARGET_EMAIL_ADDRESS}\"|" terraform/variables.auto.tfvars

# Starting Configuration
echo "***** Create a new Artifact Repository for our webapp *****"
gcloud artifacts repositories create "$ARTIFACT_REGISTRY_REPO" --location="$REGION" --repository-format=Docker > /dev/null
echo "***** Repository created *****"

echo "***** Setup artefact docker authentication *****"
gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet > /dev/null

echo "***** Build WebApp Docker image *****"
cd ..
gcloud builds submit --tag "$REGION-docker.pkg.dev/$PROJECT_ID/$ARTIFACT_REGISTRY_REPO/$SERVICE_NAME" > /dev/null

echo "***** Checking Terraform Installation *****"
if ! command -v terraform version &> /dev/null
then
    echo "Terraform is not installed, please install it and try again."
    exit 1
else
    echo "Terraform executable found"
fi

echo "***** Initialize Terraform *****"
cd installation_scripts/terraform
terraform init

echo "***** Deploying Infrastructure using Terraform *****"
terraform apply -auto-approve

echo "***** Cloud RUN URL *****"
APP_URL=$(gcloud run services describe $SERVICE_NAME --region="$REGION" --format="value(status.url)")
echo $APP_URL
import base64
import json
import sys
import os
import re
import time
import logging
from flask import Flask, request, jsonify
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
import google.auth
from google.cloud import datastore
from google.cloud import storage
import google.cloud.logging
from google.oauth2 import service_account

# Detect if running in Cloud Run
IN_CLOUD_RUN = 'K_SERVICE' in os.environ

def setup_logging():
    """Sets up logging to console for local development
    or to Google Cloud Logging when running in Cloud Run.
    """
    # Get the root logger
    logger = logging.getLogger()
    logger.setLevel(logging.INFO)  # Set the desired default log level

    # Remove any existing handlers to prevent duplicate logging
    for handler in logger.handlers[:]:
        logger.removeHandler(handler)

    if IN_CLOUD_RUN:
        print("Running in Cloud Run, setting up Cloud Logging.")
        # Instantiate the Cloud Logging client
        client = google.cloud.logging.Client()
        # Attaches the Cloud Logging handler to the root Python logger
        # This will send logs to Cloud Logging
        client.setup_logging(log_level=logging.INFO)
        print("Cloud Logging handler attached.")
    else:
        print("Running locally, setting up console logging.")
        # Configure a console handler to print logs to stdout
        console_handler = logging.StreamHandler(sys.stdout)
        # Optional: Add a formatter for more readable console logs
        formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
        console_handler.setFormatter(formatter)
        logger.addHandler(console_handler)
        print("Console logging handler added.")

# Call the setup function at the start of your application
setup_logging()

# Get a logger instance for the current module
logger = logging.getLogger(__name__)

# --- Configuration ---
TARGET_USER_EMAIL = os.getenv("MONITORED_EMAIL_ADDRESS")

PROJECT_ID = os.getenv("GOOGLE_CLOUD_PROJECT")
SCOPES = ['https://www.googleapis.com/auth/gmail.readonly']
BUCKET_NAME = os.getenv("GCS_BUCKET")
KEY_FILE_PATH = "/etc/secrets/key.json" # Path where secret is mounted
TOPIC_NAME = "gmail-watch"

# --- Initialize Clients ---
try:
    datastore_client = datastore.Client(project=PROJECT_ID)
except Exception as e:
    logger.error(f"Error initializing Datastore Client: {e}")
    datastore_client = None

try:
    storage_client = storage.Client(project=PROJECT_ID)
except Exception as e:
    logger.error(f"Error initializing Storage Client: {e}")
    storage_client = None

# --- Datastore Key ---
DATASTORE_KIND = "GmailSyncStateRun"
DATASTORE_KEY = f"last_history_id_{TARGET_USER_EMAIL}"

app = Flask(__name__)

# --- Gmail Helper Functions ---
def get_gmail_service(user_email):
    """Creates and returns a Gmail API service object with delegation."""
    try:
        if not os.path.exists(KEY_FILE_PATH):
            raise FileNotFoundError(f"Secret file not found at {KEY_FILE_PATH}")

        credentials = service_account.Credentials.from_service_account_file(
            KEY_FILE_PATH, scopes=SCOPES
        )
        delegated_credentials = credentials.with_subject(user_email)
        service = build('gmail', 'v1', credentials=delegated_credentials)
        return service
    except Exception as e:
        logger.error(f"Error creating Gmail service for {user_email}: {e}")
        return None

def get_message(service, user_id, msg_id):
    """Gets a specific message."""
    try:
        message = service.users().messages().get(userId=user_id, id=msg_id, format='full').execute()
        return message
    except HttpError as error:
        logger.error(f"An error occurred while getting message {msg_id}: {error}")
        return None

def get_attachment(service, user_id, msg_id, attachment_id):
    """Gets and decodes a specific attachment."""
    try:
        attachment = service.users().messages().attachments().get(
            userId=user_id, messageId=msg_id, id=attachment_id).execute()
        data = attachment.get('data')
        if data:
            return base64.urlsafe_b64decode(data.encode('UTF-8'))
        return None
    except HttpError as error:
        logger.error(f"An error occurred while getting attachment {attachment_id}: {error}")
        return None

# --- GCS Helper Functions ---
def sanitize_filename(filename):
    """Removes or replaces characters that are not safe for GCS object names."""
    if not filename:
        return "unnamed_attachment"
    sani = re.sub(r'[^a-zA-Z0-9_.-]', '_', filename)
    sani = re.sub(r'_+', '_', sani)
    sani = sani.strip('_.-')
    return sani if sani else "attachment"

def upload_to_gcs(bucket_name, destination_blob_name, data, content_type=None):
    """Uploads data to a GCS bucket."""
    if not storage_client:
        logger.error("Error: Storage client not initialized.")
        return False
    try:
        bucket = storage_client.bucket(bucket_name)
        blob = bucket.blob(destination_blob_name)
        blob.upload_from_string(data, content_type=content_type)
        logger.info(f"Successfully uploaded to gs://{bucket_name}/{destination_blob_name}")
        return True
    except Exception as e:
        logger.error(f"Error uploading to GCS gs://{bucket_name}/{destination_blob_name}: {e}")
        return False

# --- Datastore Helper Functions ---
def get_last_history_id():
    """Retrieves the last saved historyId from Datastore."""
    if not datastore_client: return None
    key = datastore_client.key(DATASTORE_KIND, DATASTORE_KEY)
    entity = datastore_client.get(key)
    return entity['historyId'] if entity else None

def save_last_history_id(history_id):
    """Saves the latest historyId to Datastore."""
    if not datastore_client: return
    key = datastore_client.key(DATASTORE_KIND, DATASTORE_KEY)
    entity = datastore.Entity(key=key)
    entity.update({'historyId': int(history_id)})
    datastore_client.put(entity)
    logger.info(f"Saved last historyId to Datastore: {history_id}")

# --- Main Processing Function ---
def process_new_mail(service, current_history_id_from_pubsub):
    if not datastore_client:
        raise RuntimeError("Datastore client not initialized.")

    last_processed_history_id = get_last_history_id()

    if not last_processed_history_id:
        logger.info(f"No last historyId found in Datastore. Initializing with: {current_history_id_from_pubsub}")
        save_last_history_id(current_history_id_from_pubsub)
        logger.info("First run for this user. History ID stored. Skipping email scan.")
        return # Finish processing for this invocation

    start_history_id = int(last_processed_history_id)
    current_history_id = int(current_history_id_from_pubsub)

    if current_history_id <= start_history_id:
        logger.info(f"Received historyId {current_history_id} <= last processed {start_history_id}. Skipping.")
        return

    logger.info(f"Processing history from {start_history_id} to {current_history_id}")

    try:
        history = service.users().history().list(
            userId=TARGET_USER_EMAIL,
            startHistoryId=start_history_id
        ).execute()
    except HttpError as error:
        logger.error(f"Error fetching history: {error}")
        raise error

    new_history_id = history.get('historyId', start_history_id)
    changes = history.get('history', [])

    if not changes:
        logger.info(f"No new changes in history range.")
        if int(new_history_id) > start_history_id:
             save_last_history_id(new_history_id)
        return

    message_ids = set()
    for change in changes:
        messages_added = change.get('messagesAdded', [])
        for msg_added in messages_added:
            msg = msg_added.get('message', {})
            if msg and 'id' in msg and 'INBOX' in msg.get('labelIds', []):
                message_ids.add(msg['id'])

    if not message_ids:
        logger.info(f"No new INBOX messages in history changes.")
    else:
        logger.info(f"New message IDs to process: {message_ids}")
        for msg_id in message_ids:
            message = get_message(service, TARGET_USER_EMAIL, msg_id)
            if message:
                payload = message.get('payload', {})
                logger.info(f"  Processing Message ID: {msg_id}")
                parts = payload.get('parts', [])
                if parts:
                    for i, part in enumerate(parts):
                        filename = part.get('filename')
                        if filename:
                            content_type = part.get('mimeType', 'application/octet-stream')
                            logger.info(f"    Attachment: {filename} ({content_type})")
                            body = part.get('body', {})
                            attachment_id = body.get('attachmentId')
                            if attachment_id:
                                try:
                                    attachment_data = get_attachment(service, TARGET_USER_EMAIL, msg_id, attachment_id)
                                    if attachment_data:
                                        sane_filename = sanitize_filename(filename)
                                        destination_blob_name = f"{msg_id}/{i}_{sane_filename}"
                                        upload_to_gcs(BUCKET_NAME, destination_blob_name, attachment_data, content_type)
                                except Exception as e:
                                    logger.info(f"Error fetching/uploading attachment {filename}: {e}")

    save_last_history_id(new_history_id)
    logger.info(f"Finished processing. Updated history to {new_history_id}")

# --- Pub/Sub Push Endpoint ---
@app.route('/', methods=['POST'])
def process_pubsub_push():
    """Handles Pub/Sub push requests."""
    if not datastore_client or not storage_client:
        logger.error("Clients not initialized")
        return "", 500

    envelope = request.get_json()
    if not envelope:
        logger.error("Bad Request: invalid Pub/Sub message format")
        return "", 400

    pubsub_message = envelope.get('message')
    if not pubsub_message:
        logger.error("Bad Request: invalid Pub/Sub message format")
        return "", 400

    logger.info(f"Received Pub/Sub message: {pubsub_message.get('messageId')}")

    try:
        if 'data' in pubsub_message:
            data_b64 = pubsub_message['data']
            data_str = base64.b64decode(data_b64).decode('utf-8')
            notification = json.loads(data_str)

            email_address = notification.get('emailAddress')
            history_id = notification.get('historyId')

            if email_address != TARGET_USER_EMAIL:
                logger.info(f"Notification is for a different email: {email_address}, ignoring.")
                return "", 204

            logger.info(f"Received notification for {email_address}, Triggering History ID: {history_id}")

            service = get_gmail_service(TARGET_USER_EMAIL)
            if not service:
                return jsonify({"error": "Failed to get Gmail service"}), 500

            process_new_mail(service, history_id)
            return "", 204 # ACK success
        else:
            logger.error("Bad Request: no data in Pub/Sub message")
            return "", 400

    except json.JSONDecodeError:
        logger.error("Bad Request: could not decode JSON data")
        return "", 400
    except Exception as e:
        logger.error(f"Error processing message: {e}")
        return "", 500

# --- Activate Gmail Notifications ---
@app.route('/renew_gmail_push_permissions', methods=['POST'])
def renew_gmail_push_permissions():
    logger.info("Activating Gmail push notification permissions...")
    try:
        service = get_gmail_service(TARGET_USER_EMAIL)
        if not service:
            return jsonify({"error": "Failed to get Gmail service"}), 500

        request = {
            'labelIds': ['INBOX'],
            'topicName': f"projects/{PROJECT_ID}/topics/{TOPIC_NAME}",
            'labelFilterBehavior': 'INCLUDE'
        }

        service.users().watch(userId=TARGET_USER_EMAIL, body=request).execute()
        logger.info("Successfully renewed Gmail push notification permissions")
        return f"Gmail push notification permissions renewed for topic {TOPIC_NAME} for the next 7 days", 200

    except Exception as e:
        logger.error(f"Error processing message: {e}")
        return "", 500

# --- Stop Gmail Notifications ---
@app.route('/revoke_gmail_push_permissions', methods=['POST'])
def revoke_gmail_push_permissions():
    logger.info("Revoking Gmail push notification permissions")
    try:
        service = get_gmail_service(TARGET_USER_EMAIL)
        if not service:
            return jsonify({"error": "Failed to get Gmail service"}), 500

        service.users().stop(userId=TARGET_USER_EMAIL).execute()
        logger.info("Successfully revoked Gmail push notification permissions")
        return f"Gmail push notification permissions revoked", 200

    except Exception as e:
        logger.error(f"Error processing message: {e}")
        return "", 500

logger.info(f"Initial activation of push Notifications from Gmail to Pub/Sub topic {TOPIC_NAME}. It should be re-activated every week at most")
renew_gmail_push_permissions()

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 8080))
    app.run(debug=True, host='0.0.0.0', port=port)

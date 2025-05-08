#!/bin/bash

# This script deploys a gRPC backend to Cloud Run and configures a Global HTTPS Load Balancer
# with a Serverless Network Endpoint Group (NEG) to route traffic to the Cloud Run service.
# It also includes the creation of a global static IP address and a managed SSL certificate.

# IMPORTANT:
# The user or service account executing this script must have the necessary IAM permissions.
# These typically include roles like Cloud Run Invoker, Compute Instance Admin,Compute Load Balancer Admin
# Compute Network Admin. For production environments, apply the principle of least privilege.

# --- Project and Service Variables ---
export PROJECT_ID="saxenaishita-apgx-test-00"  # Your Google Cloud Project ID
export REGION="asia-south2"                  # Cloud Run and Load Balancer Region
export SERVICENAME="grpc-backend-apigee-3"   # Name of your Cloud Run Service

# --- gRPC Backend Specifics ---
export pythonfilename="greeter_server.py" # Main Python server file (e.g., greeter.py or greeter_server.py)

# --- Load Balancer Components Variables ---
export IP_NAME="glb-apgx-ext-ip-3"             # Name for the Global Static IP Address
export CERT_NAME="ssl-cert-apgx-grpc-3"          # Name for the Managed SSL Certificate
#export CUSTOM_DOMAIN="your.custom.domain.com" # <<< IMPORTANT: REPLACE WITH YOUR ACTUAL DOMAIN >>>
export NEG_NAME="grpc-neg-cloudrun-$SERVICENAME" # Name for the Serverless NEG
export BACKEND_SERVICE_NAME="lb-grpc-backendservice-$SERVICENAME" # Name for the Backend Service
export URL_MAP_NAME="lb-grpc-urlmap-$SERVICENAME"          # Name for the URL Map
export TARGET_PROXY_NAME="lb-grpc-target-https-proxy-$SERVICENAME" # Name for the Target HTTPS Proxy
export FORWARDING_RULE_NAME="lb-grpc-frontend-https-$SERVICENAME" # Name for the Global HTTPS Forwarding Rule
export SA_NAME="apigee-sa-client"
export CUSTOM_AUDIENCE="foo"   

# --- Prerequisites Checks ---
echo "--- Performing Prerequisites Checks ---"

if [ -z "$PROJECT_ID" ]; then
  echo "Error: PROJECT_ID variable is not set. Please set it before running the script."
  exit 1
fi

if [ -z "$REGION" ]; then
  echo "Error: REGION variable is not set. Please set it before running the script."
  exit 1
fi

# if [ "$CUSTOM_DOMAIN" == "your.custom.domain.com" ]; then
#   echo "Error: CUSTOM_DOMAIN variable is not set. Please replace 'your.custom.domain.com' with your actual domain."
#   exit 1
# fi

# Set gcloud project for convenience
echo "Setting gcloud project to $PROJECT_ID..."
gcloud config set project "$PROJECT_ID"

# Check if jq is installed (useful for parsing JSON output if needed, though not strictly used heavily here)
if ! command -v jq &> /dev/null; then
  echo "Warning: 'jq' command is not found. It's a useful tool for parsing JSON, but not strictly required for this script."
fi

echo "--- Environment Variables Confirmed ---"
echo "PROJECT_ID: $PROJECT_ID"
echo "REGION: $REGION"
echo "SERVICENAME: $SERVICENAME"
echo "pythonfilename: $pythonfilename"
echo "CUSTOM_AUDIENCE: $CUSTOM_AUDIENCE"
echo "IP_NAME: $IP_NAME"
echo "CERT_NAME: $CERT_NAME"
echo "CUSTOM_DOMAIN: $CUSTOM_DOMAIN"
echo "NEG_NAME: $NEG_NAME"
echo "BACKEND_SERVICE_NAME: $BACKEND_SERVICE_NAME"
echo "URL_MAP_NAME: $URL_MAP_NAME"
echo "TARGET_PROXY_NAME: $TARGET_PROXY_NAME"
echo "FORWARDING_RULE_NAME: $FORWARDING_RULE_NAME"
echo ""

# --- Cloud Run Deployment ---
echo "--- Deploying gRPC Backend to Cloud Run ---"

# Clone the gRPC repository if it doesn't exist
echo "Checking for gRPC repository 'grpc-backend'..."
if [ ! -d "grpc-backend" ]; then
  git clone https://github.com/grpc/grpc.git grpc-backend
  echo "Cloned gRPC repository."
else
  echo "grpc-backend directory already exists. Skipping clone."
fi
echo ""

# Navigate to the helloworld example directory
echo "Navigating to the example directory: grpc-backend/examples/python/helloworld..."
# Ensure we are in the correct base directory if the script is run multiple times
cd "$(dirname "$0")" || exit # Go to script's directory first
cd grpc-backend/examples/python/helloworld || { echo "Error: helloworld directory not found. Exiting."; exit 1; }
echo ""

# Create the Procfile for the entrypoint
echo "Creating Procfile..."
cat <<EOF > Procfile
web: python3 $pythonfilename
EOF
echo "Procfile created: web: python3 $pythonfilename"
echo ""

# Create the requirements.txt file
echo "Creating requirements.txt (with grpcio and protobuf)..."
cat <<EOF > requirements.txt
grpcio
protobuf
EOF
echo "requirements.txt created."
echo ""

# Deploy the gRPC backend to Cloud Run
echo "Initiating Cloud Run deployment for service: $SERVICENAME in region: $REGION..."
gcloud run deploy "$SERVICENAME" --allow-unauthenticated \
  --port 50051 \
  --timeout 3600 \
  --region="$REGION" \
  --quiet \
  --source=. \
  --project="$PROJECT_ID" \
  --add-custom-audiences="$CUSTOM_AUDIENCE"
echo ""

# Get the Cloud Run service URL
echo "Retrieving Cloud Run service URL..."
CLOUD_RUN_SERVICE_URL=$(gcloud run services describe "$SERVICENAME" \
  --region "$REGION" \
  --format 'value(status.url)' \
  --project="$PROJECT_ID")
echo ""

if [ -z "$CLOUD_RUN_SERVICE_URL" ]; then
  echo "Error: Failed to retrieve Cloud Run service URL. Load Balancer setup cannot proceed."
  exit 1
fi
echo "Cloud Run service URL: $CLOUD_RUN_SERVICE_URL"
echo ""

# --- Configure Global HTTPS Load Balancer for Cloud Run ---
echo "--- Configuring Global HTTPS Load Balancer ---"

# 1. Create a global static IP address
echo "Creating global static IP address: $IP_NAME..."
if ! gcloud compute addresses describe "$IP_NAME" --global --project="$PROJECT_ID" &> /dev/null; then
SERVICE_ACCOUNT="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
 gcloud compute addresses create "$IP_NAME" --ip-version=IPV4 --global --project="$PROJECT_ID" --impersonate-service-account="$SERVICE_ACCOUNT"
else
 echo "Global static IP address '$IP_NAME' already exists. Continuing."
fi
echo ""

# Get the IP address for reference and DNS configuration
IP=$(gcloud compute addresses describe "$IP_NAME" --format="get(address)" --global --project="$PROJECT_ID")
if [ -z "$IP" ]; then
 echo "Error: Failed to retrieve IP address for '$IP_NAME'."
 exit 1
else
echo "Global static IP address: '$IP' ."
fi
echo ""
export CUSTOM_DOMAIN="$IP.nip.io"
echo "Setting CUSTOM_DOMAIN to: $CUSTOM_DOMAIN"
echo ""

# 2.  Create a TLS certificate

echo "Creating TLS certificate: $CERT_NAME for domain: $CUSTOM_DOMAIN"
if ! gcloud compute ssl-certificates describe "$CERT_NAME" --global --project="$PROJECT_ID" &> /dev/null; then
 gcloud compute ssl-certificates create "$CERT_NAME" --domains="$CUSTOM_DOMAIN" --global --project="$PROJECT_ID"
else
 echo "TLS certificate '$CERT_NAME' already exists. Continuing."
fi
echo ""

# 3. Create a Serverless Network Endpoint Group (NEG) for the Cloud Run service
echo "Creating Serverless NEG: $NEG_NAME for Cloud Run service: $SERVICENAME..."
if ! gcloud compute network-endpoint-groups describe "$NEG_NAME" --region="$REGION" --project="$PROJECT_ID" &> /dev/null; then
  gcloud compute network-endpoint-groups create "$NEG_NAME" \
    --network-endpoint-type=SERVERLESS \
    --cloud-run-service="$SERVICENAME" \
    --region="$REGION" \
    --project="$PROJECT_ID"
else
  echo "Global Serverless NEG '$NEG_NAME' already exists. Skipping creation."
fi
echo ""

# 4. Create a Backend Service
echo "Creating backend service: $BACKEND_SERVICE_NAME..."
# For gRPC over HTTP/2, use HTTP2 protocol
if ! gcloud compute backend-services describe "$BACKEND_SERVICE_NAME" --global --project="$PROJECT_ID" &> /dev/null; then
  gcloud compute backend-services create "$BACKEND_SERVICE_NAME" \
    --load-balancing-scheme=EXTERNAL_MANAGED \
    --global \
    --project="$PROJECT_ID"
  echo "Adding backend (Serverless NEG $NEG_NAME) to service: $BACKEND_SERVICE_NAME..."
  gcloud compute backend-services add-backend "$BACKEND_SERVICE_NAME" \
    --global \
    --network-endpoint-group="$NEG_NAME" \
    --network-endpoint-group-region="$REGION" \
    --project="$PROJECT_ID"
else
  echo "Global backend service '$BACKEND_SERVICE_NAME' already exists. Skipping creation."
fi
echo ""

# 5. Create a URL Map
echo "Creating URL map: $URL_MAP_NAME..."
if ! gcloud compute url-maps describe "$URL_MAP_NAME" --global --project="$PROJECT_ID" &> /dev/null; then
  gcloud compute url-maps create "$URL_MAP_NAME" \
    --default-service "$BACKEND_SERVICE_NAME" \
    --global \
    --project="$PROJECT_ID"
else
  echo "Global URL map '$URL_MAP_NAME' already exists. Skipping creation."
fi
echo ""

# 6. Create a Target HTTPS Proxy
echo "Creating target HTTPS proxy: $TARGET_PROXY_NAME..."
if ! gcloud compute target-https-proxies describe "$TARGET_PROXY_NAME" --global --project="$PROJECT_ID" &> /dev/null; then
  gcloud compute target-https-proxies create "$TARGET_PROXY_NAME" \
    --global \
    --ssl-certificates "$CERT_NAME" \
    --global-ssl-certificates \
    --url-map "$URL_MAP_NAME" \
    --global-url-map \
    --project="$PROJECT_ID"
else
  echo "Global target HTTPS proxy '$TARGET_PROXY_NAME' already exists. Skipping creation."
fi
echo ""

# 7. Create a Global Forwarding Rule (HTTPS)
echo "Creating global HTTPS forwarding rule: $FORWARDING_RULE_NAME..."
if ! gcloud compute forwarding-rules describe "$FORWARDING_RULE_NAME" --global --project="$PROJECT_ID" &> /dev/null; then
  gcloud compute forwarding-rules create "$FORWARDING_RULE_NAME" \
    --load-balancing-scheme=EXTERNAL_MANAGED \
    --network-tier=PREMIUM \
    --address="$IP_NAME" \
    --target-https-proxy="$TARGET_PROXY_NAME" \
    --ports=443 \
    --global \
    --project="$PROJECT_ID"
else
  echo "Global HTTPS forwarding rule '$FORWARDING_RULE_NAME' already exists. Skipping creation."
fi
echo ""

# --- Final Outputs ---
echo ""
echo "--- Deployment and Load Balancer Setup Complete ---"
echo "Your Cloud Run Service URL: $CLOUD_RUN_SERVICE_URL"

# Get the IP address of the forwarding rule
FORWARDING_RULE_IP=$(gcloud compute forwarding-rules describe "$FORWARDING_RULE_NAME" \
  --global \
  --format="get(IPAddress)" \
  --project="$PROJECT_ID")

if [ -z "$FORWARDING_RULE_IP" ]; then
  echo "Could not retrieve Load Balancer IP address. Check the forwarding rule status."
else
  echo "Load Balancer IP Address (HTTPS): $FORWARDING_RULE_IP"
  echo "Point your custom domain '$CUSTOM_DOMAIN' to this IP address in your DNS settings."
  echo "Note: DNS propagation and Load Balancer provisioning (especially SSL certificate) can take several minutes."
  echo "Ensure your gRPC client is configured for HTTP/2 and connects to the Load Balancer's IP or domain on port 443."
fi


echo ""
echo "Cleanup commands (run these if you want to remove the created resources):"
echo "gcloud compute forwarding-rules delete $FORWARDING_RULE_NAME --global --quiet --project=$PROJECT_ID"
echo "gcloud compute target-https-proxies delete $TARGET_PROXY_NAME --global --quiet --project=$PROJECT_ID"
echo "gcloud compute url-maps delete $URL_MAP_NAME --global --quiet --project=$PROJECT_ID"
echo "gcloud compute backend-services delete $BACKEND_SERVICE_NAME --global --quiet --project=$PROJECT_ID"
echo "gcloud compute network-endpoint-groups delete $NEG_NAME --region="$REGION" --quiet --project=$PROJECT_ID"
echo "gcloud compute ssl-certificates delete $CERT_NAME --global --quiet --project=$PROJECT_ID"
echo "gcloud compute addresses delete $IP_NAME --global --quiet --project=$PROJECT_ID"
echo "gcloud run services delete $SERVICENAME --region=$REGION --quiet --project=$PROJECT_ID"
echo "rm -rf grpc-backend"

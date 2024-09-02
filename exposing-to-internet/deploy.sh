#!/bin/bash

# Copyright 2023 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

if [ -z "$PROJECT" ]; then
  echo "Error: No PROJECT variable set" >&2
  exit 1
fi

if [ -z "$NETWORK" ]; then
  echo "Error: No NETWORK variable set" >&2
  exit 1
fi

if [ -z "$SUBNET" ]; then
  echo "Error: No SUBNET variable set" >&2
  exit 1
fi

if ! [ -x "$(command -v jq)" ]; then
  echo "Error: jq command is not on your PATH" >&2
  exit 1
fi

function wait_for_operation() {
  local op_name="$1"
  local timeout=600  # 10 minutes
  local elapsed=0

  while [ "$elapsed" -lt "$timeout" ]; do
    STATE="$(apigeecli operations get -o "$PROJECT" -n "$op_name" -t "$TOKEN" | jq --raw-output '.metadata.state')"
    if [ "$STATE" = "FINISHED" ]; then
      echo
      return
    fi
    echo -n .
    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "Error: Operation $op_name did not complete in time" >&2
  exit 1
}

echo "Installing apigeecli"
curl -s https://raw.githubusercontent.com/apigee/apigeecli/main/downloadLatest.sh | bash
export PATH=$PATH:$HOME/.apigeecli/bin

TOKEN="$(gcloud auth print-access-token)"

# Get Apigee instance information
INSTANCE_JSON=$(apigeecli instances list -o "$PROJECT" -t "$TOKEN")
INSTANCE_NAME=$(echo "$INSTANCE_JSON" | jq --raw-output '.instances[0].name')
REGION=$(echo "$INSTANCE_JSON" | jq --raw-output '.instances[0].location')
SERVICE_ATTACHMENT=$(echo "$INSTANCE_JSON" | jq --raw-output '.instances[0].serviceAttachment')
ENVIRONMENT_NAME="sample-environment"
ENVIRONMENT_GROUP_NAME="sample-environment-group"

# Create and attach a sample Apigee environment
echo -n "Creating environment..."
OPERATION=$(apigeecli environments create -o "$PROJECT" -e "$ENVIRONMENT_NAME" -d PROXY -p PROGRAMMABLE -t "$TOKEN" | jq --raw-output '.name' | awk -F/ '{print $4}')
wait_for_operation "$OPERATION"

echo -n "Attaching environment to instance (may take a few minutes)..."
OPERATION=$(apigeecli instances attachments attach -o "$PROJECT" -e "$ENVIRONMENT_NAME" -n "$INSTANCE_NAME" -t "$TOKEN" | jq --raw-output '.name' | awk -F/ '{print $4}')
wait_for_operation "$OPERATION"

# Enable APIs
gcloud services enable compute.googleapis.com --project="$PROJECT" --quiet

# Reserve an IP address for the Load Balancer
echo "Reserving load balancer IP address..."
gcloud compute addresses create sample-apigee-vip --ip-version=IPV4 --global --project "$PROJECT" --quiet
RUNTIME_IP=$(gcloud compute addresses describe sample-apigee-vip --format="get(address)" --global --project "$PROJECT" --quiet)
RUNTIME_HOST_ALIAS="$ENVIRONMENT_GROUP_NAME".$(echo "$RUNTIME_IP" | tr '.' '-').nip.io

# Create a sample Apigee environment group and attach the environment
echo -n "Creating environment group..."
OPERATION=$(apigeecli envgroups create -o "$PROJECT" -d "$RUNTIME_HOST_ALIAS" -n "$ENVIRONMENT_GROUP_NAME" -t "$TOKEN" | jq --raw-output '.name' | awk -F/ '{print $4}')
wait_for_operation "$OPERATION"

echo -n "Attaching environment to group..."
OPERATION=$(apigeecli envgroups attach -o "$PROJECT" -e "$ENVIRONMENT_NAME" -n "$ENVIRONMENT_GROUP_NAME" -t "$TOKEN" | jq --raw-output '.name' | awk -F/ '{print $4}')
wait_for_operation "$OPERATION"

# Create a Google managed SSL certificate
echo "Creating SSL certificate..."
gcloud compute ssl-certificates create sample-apigee-ssl-cert \
  --domains="$RUNTIME_HOST_ALIAS" --project "$PROJECT" --quiet

# Create a global Load Balancer
echo "Creating external load balancer..."

# Create a PSC NEG
gcloud compute network-endpoint-groups create sample-apigee-neg \
  --network-endpoint-type=private-service-connect \
  --psc-target-service="$SERVICE_ATTACHMENT" \
  --region="$REGION" \
  --network="$NETWORK" \
  --subnet="$SUBNET" \
  --project="$PROJECT" --quiet

# Create a backend service and add the NEG
gcloud compute backend-services create sample-apigee-backend \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --protocol=HTTPS \
  --global --project="$PROJECT" --quiet

gcloud compute backend-services add-backend sample-apigee-backend \
  --network-endpoint-group=sample-apigee-neg \
  --network-endpoint-group-region="$REGION" \
  --global --project="$PROJECT" --quiet

# Create a Load Balancing URL map
gcloud compute url-maps create sample-apigee-urlmap \
  --default-service sample-apigee-backend --project="$PROJECT" --quiet

# Create a Load Balancing target HTTPS proxy
gcloud compute target-https-proxies create sample-apigee-https-proxy \
  --url-map sample-apigee-urlmap \
  --ssl-certificates sample-apigee-ssl-cert --project="$PROJECT" --quiet

# Create a global forwarding rule
gcloud compute forwarding-rules create sample-apigee-https-lb-rule \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --network-tier=PREMIUM \
  --address=sample-apigee-vip --global \
  --target-https-proxy=sample-apigee-https-proxy --ports=443 --project="$PROJECT" --quiet

echo -n "Waiting for certificate provisioning to complete (may take some time)..."
while true; do
  TLS_STATUS="$(gcloud compute ssl-certificates describe sample-apigee-ssl-cert --format=json --project "$PROJECT" --quiet | jq -r '.managed.status')"
  if [ "$TLS_STATUS" = "ACTIVE" ]; then
    break
  fi
  echo -n .
  sleep 10
done

# Pause to allow TLS setup to complete
sleep 30

echo "Installing dependencies and running tests..."
npm install
npm run test

echo "# To send an EXTERNAL test request, execute the following commands:"
echo "

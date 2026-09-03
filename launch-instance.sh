#!/usr/bin/env bash
# Retries launching the Always Free VM.Standard.A1.Flex instance across
# all three availability domains. Safe to run repeatedly (idempotent) —
# it checks whether the instance already exists before trying anything.
set -uo pipefail

INSTANCE_NAME="zetaforge-llm"

# Availability domain names — replace <AD-PREFIX> with your tenancy's
# prefix, e.g. "LvBe" (shown on the Placement screen when you created
# the instance in the console: "LvBe:US-CHICAGO-1-AD-1").
ADS=(
  "${AD_PREFIX}:${AD_REGION}-AD-1"
  "${AD_PREFIX}:${AD_REGION}-AD-2"
  "${AD_PREFIX}:${AD_REGION}-AD-3"
)

# --- Skip if it's already running (makes this safe to run on a cron/schedule) ---
EXISTING_STATE=$(oci compute instance list \
  --compartment-id "$OCI_COMPARTMENT_ID" \
  --display-name "$INSTANCE_NAME" \
  --query "data[0].\"lifecycle-state\"" --raw-output 2>/dev/null)

if [ -n "$EXISTING_STATE" ] && [ "$EXISTING_STATE" != "null" ] && [ "$EXISTING_STATE" != "TERMINATED" ]; then
  echo "Instance already exists with state: $EXISTING_STATE — nothing to do."
  exit 0
fi

# --- Try each AD in turn ---
for AD in "${ADS[@]}"; do
  echo "=== Trying $AD ==="

  OUTPUT=$(oci compute instance launch \
    --compartment-id "$OCI_COMPARTMENT_ID" \
    --availability-domain "$AD" \
    --shape "VM.Standard.A1.Flex" \
    --shape-config '{"ocpus":2,"memoryInGBs":12}' \
    --display-name "$INSTANCE_NAME" \
    --subnet-id "$OCI_SUBNET_ID" \
    --assign-public-ip true \
    --image-id "$OCI_IMAGE_ID" \
    --ssh-authorized-keys-file <(printf '%s' "$OCI_SSH_PUBLIC_KEY") \
    --wait-for-state RUNNING \
    --wait-interval-seconds 15 \
    2>&1)
  STATUS=$?

  if [ $STATUS -eq 0 ]; then
    PUBLIC_IP=$(oci compute instance list-vnics \
      --compartment-id "$OCI_COMPARTMENT_ID" \
      --instance-id "$(oci compute instance list \
        --compartment-id "$OCI_COMPARTMENT_ID" \
        --display-name "$INSTANCE_NAME" \
        --query "data[0].id" --raw-output)" \
      --query "data[0].\"public-ip\"" --raw-output 2>/dev/null)

    echo "SUCCESS in $AD — public IP: $PUBLIC_IP"
    curl -s \
      -H "Title: ZetaForge LLM VM is up" \
      -d "Launched successfully in $AD. Public IP: $PUBLIC_IP" \
      "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null
    exit 0
  else
    echo "$OUTPUT" | grep -iE "capacity|limit|error|out of host" || echo "$OUTPUT" | tail -3
  fi
done

echo "All availability domains out of capacity this round."
exit 1

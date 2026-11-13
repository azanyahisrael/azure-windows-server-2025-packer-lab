#!/usr/bin/env bash
set -euo pipefail

image_id=${1:?Expected an exact gallery version resource ID.}
region=${2:?Expected the Azure build region.}
vm=${3:?Expected a unique validation VM name.}
rg=${PKR_VAR_build_resource_group:?Expected the Azure build resource group.}
subnet=${AZURE_VALIDATION_SUBNET_ID:?Set AZURE_VALIDATION_SUBNET_ID.}
nic="${vm}-nic"
disk="${vm}-os"

# The attempt-scoped names identify exactly which disposable resources are safe to delete.
for resource in "Microsoft.Compute/virtualMachines/$vm" "Microsoft.Compute/disks/$disk" "Microsoft.Network/networkInterfaces/$nic"; do
  resource_type=${resource%/*}
  resource_name=${resource##*/}
  existing=$(az resource list -g "$rg" --resource-type "$resource_type" --name "$resource_name" --query '[0].id' -o tsv)
  if [[ -n $existing ]]; then
    echo 'A validation resource already exists for this attempt.' >&2
    exit 1
  fi
done

cleanup() {
  local failed=0
  az vm delete -g "$rg" -n "$vm" --yes -o none || failed=1
  az network nic delete -g "$rg" -n "$nic" -o none || failed=1
  az disk delete -g "$rg" -n "$disk" --yes -o none || failed=1
  return "$failed"
}
trap 'status=$?; cleanup || echo "Validation cleanup needs review in the Azure build resource group." >&2; exit "$status"' EXIT

az network nic create -g "$rg" -n "$nic" -l "$region" --subnet "$subnet" -o none
password="Aa7!$(openssl rand -hex 24)"
printf '::add-mask::%s\n' "$password"
az vm create -g "$rg" -n "$vm" -l "$region" --image "$image_id" --os-type windows \
  --size "${PKR_VAR_vm_size:-Standard_D2s_v4}" --nics "$nic" --nic-delete-option Detach \
  --os-disk-name "$disk" --os-disk-delete-option Detach \
  --admin-username imagevalidator --admin-password "$password" -o none
unset password

agent_ready=
for ((attempt=0; attempt<40; attempt++)); do
  agent_ready=$(az vm get-instance-view -g "$rg" -n "$vm" \
    --query "instanceView.vmAgent.statuses[?code=='ProvisioningState/succeeded'].code | [0]" -o tsv)
  if [[ -n $agent_ready ]]; then break; fi
  sleep 15
done
if [[ -z $agent_ready ]]; then
  echo 'The validation VM guest agent did not become ready.' >&2
  exit 1
fi
inputs=$(jq -cn --arg validation_rg "$rg" --arg validation_vm "$vm" \
  --arg audit_script "$RUNNER_TEMP/image-drift.ps1" '{$validation_rg, $validation_vm, $audit_script}')
ansible-playbook -i localhost, scripts/check-image-drift.yml --extra-vars "$inputs"

trap - EXIT
cleanup

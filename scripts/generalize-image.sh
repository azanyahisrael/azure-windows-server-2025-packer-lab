#!/usr/bin/env bash
set -euo pipefail

: "${PKR_VAR_build_resource_group:?Set the build resource group.}"
: "${PKR_VAR_build_vm_name:?Set a unique build VM name.}"

args=(-g "$PKR_VAR_build_resource_group" --vm-name "$PKR_VAR_build_vm_name" --name prepare-image)
az vm run-command create "${args[@]}" --async-execution false --timeout-in-seconds 1800 \
  --script "$(cat scripts/generalize.ps1)" -o none
result=$(az vm run-command show "${args[@]}" --expand instanceView --query instanceView -o json)
if ! jq -e '.executionState == "Succeeded" and .exitCode == 0 and (.output | contains("IMAGE_GENERALIZED"))' \
  <<< "$result" >/dev/null; then
  jq -r '.error // "Image generalization did not return success."' <<< "$result" >&2
  exit 1
fi

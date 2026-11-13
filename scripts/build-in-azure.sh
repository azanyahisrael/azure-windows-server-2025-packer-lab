#!/usr/bin/env bash
set -euo pipefail

: "${PKR_VAR_build_resource_group:?Set AZURE_BUILD_RG in the image-build-Azure-Packman-lab environment.}"
: "${BUILD_MODE:?Choose lab or candidate.}"
export PKR_VAR_hardening_script_path="${PKR_VAR_hardening_script_path:-Harden-V2.ps1}"
if [[ ! -f $PKR_VAR_hardening_script_path ]]; then
  printf 'Missing hardening script: %s\n' "$PKR_VAR_hardening_script_path" >&2
  exit 1
fi

if [[ $BUILD_MODE == candidate ]]; then
  : "${APPROVED_BASE_VERSION:?Set AZURE_BASE_VERSION to an approved Marketplace image version.}"
  : "${AZURE_VALIDATION_SUBNET_ID:?Set AZURE_VALIDATION_SUBNET_ID.}"
  if [[ ! $APPROVED_BASE_VERSION =~ ^[0-9]+(\.[0-9]+){2}$ ]]; then
    echo 'AZURE_BASE_VERSION must be an exact Marketplace version.' >&2
    exit 1
  fi
fi
region=$(az group show -n "$PKR_VAR_build_resource_group" --query location -o tsv)
urn="MicrosoftWindowsServer:WindowsServer:2025-datacenter-g2:${APPROVED_BASE_VERSION:-latest}"
base_version=$(az vm image show --location "$region" --urn "$urn" --query name -o tsv)
if [[ ! $base_version =~ ^[0-9]+(\.[0-9]+){2}$ ]]; then
  echo 'Could not resolve an exact Windows Server 2025 Marketplace version.' >&2
  exit 1
fi
export PKR_VAR_base_version="$base_version"

runner_ip=$(curl -4 --fail --silent --show-error --retry 2 --max-time 15 https://api.ipify.org)
if [[ ! $runner_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo 'Could not determine the build runner IPv4 address.' >&2
  exit 1
fi
export PKR_VAR_runner_cidr="$runner_ip/32"
printf '::add-mask::%s\n' "$runner_ip"

case "$BUILD_MODE" in
  lab) ;;
  candidate)
    : "${AZURE_GALLERY_RG:?Set AZURE_GALLERY_RG.}"
    : "${AZURE_GALLERY_NAME:?Set AZURE_GALLERY_NAME.}"
    : "${AZURE_IMAGE_DEFINITION:?Set AZURE_IMAGE_DEFINITION.}"

    version="1.$GITHUB_RUN_NUMBER.$GITHUB_RUN_ATTEMPT"
    name_hash=$(printf '%s/%s/%s' "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" | sha256sum)
    export PKR_VAR_build_vm_name="bld${name_hash:0:10}"
    PKR_VAR_candidate=$(jq -cn \
      --arg resource_group "$AZURE_GALLERY_RG" --arg gallery "$AZURE_GALLERY_NAME" \
      --arg definition "$AZURE_IMAGE_DEFINITION" --arg version "$version" \
      '{resource_group:$resource_group, gallery:$gallery, definition:$definition, version:$version}')
    export PKR_VAR_candidate
    gallery_args=(-g "$AZURE_GALLERY_RG" --gallery-name "$AZURE_GALLERY_NAME"
      --gallery-image-definition "$AZURE_IMAGE_DEFINITION")
    az sig image-definition show "${gallery_args[@]}" -o none
    az network vnet subnet show --ids "$AZURE_VALIDATION_SUBNET_ID" -o none
    pwsh -NoProfile -File scripts/New-DriftPayload.ps1 \
      -BaselinePath "$PKR_VAR_hardening_script_path" -OutputPath "$RUNNER_TEMP/image-drift.ps1"
    ;;
  *) echo 'Unknown Azure build mode.' >&2; exit 1 ;;
esac

packer init .
packer validate .

# Public workflow logs carry outcomes rather than raw Azure resource IDs and VM addresses.
build_log=$(mktemp)
trap 'rm -f "$build_log"' EXIT
if ! packer build -color=false . >"$build_log" 2>&1; then
  echo 'Packer build failed. Check the Azure Activity Log for deployment errors.'
  grep -Eo 'QuotaExceeded|SkuNotAvailable|AuthorizationFailed|RequestDisallowedByPolicy|context deadline exceeded|WinRM connection timeout' \
    "$build_log" | sort -u || true
  grep -Eo '[0-9]+ controls require readback checks|Windows Update to notify before installing|LGPO.zip did not match the pinned SHA-256|CIS 2\.3\.7\.3|CIS 18\.10\.90\.2\.1' \
    "$build_log" | sort -u || true
  exit 1
fi
if ! grep -Fq 'HARDENING_CHECKS_PASSED' "$build_log"; then
  echo 'The build did not report a successful pre-capture check.' >&2
  exit 1
fi

printf '### Windows Server image build\n\n' >> "$GITHUB_STEP_SUMMARY"
printf 'Marketplace base version: %s\n\n' "$base_version" >> "$GITHUB_STEP_SUMMARY"
baseline_hash=$(sha256sum -- "$PKR_VAR_hardening_script_path")
printf 'Hardening script SHA-256: `%s`\n\n' "${baseline_hash%% *}" >> "$GITHUB_STEP_SUMMARY"
printf 'Patch delays in days: routine %s, critical %s.\n\n' \
  "${PKR_VAR_routine_patch_delay_days:-7}" "${PKR_VAR_critical_patch_delay_days:-3}" >> "$GITHUB_STEP_SUMMARY"
printf 'Level 1 hardening and pre-capture checks passed on the build VM.\n\n' >> "$GITHUB_STEP_SUMMARY"
if [[ $BUILD_MODE == candidate ]]; then
  version_args=("${gallery_args[@]}" --gallery-image-version "$version")
  candidate=$(az sig image-version show "${version_args[@]}" -o json)
  if ! jq -e '.provisioningState == "Succeeded" and .publishingProfile.excludeFromLatest == true' \
    <<< "$candidate" >/dev/null; then
    echo 'Expected a captured gallery candidate excluded from latest.' >&2
    exit 1
  fi
  image_id=$(jq -er '.id | select(endswith("/versions/" + $version))' --arg version "$version" <<< "$candidate")
  printf 'Captured gallery candidate %s.\n\n' "$version" >> "$GITHUB_STEP_SUMMARY"
  if ! bash scripts/verify-image.sh "$image_id" "$region" "chk${name_hash:0:10}"; then
    printf 'Post-capture verification failed. Candidate remains excluded from latest.\n' >> "$GITHUB_STEP_SUMMARY"
    exit 1
  fi
  printf 'Ansible drift checks passed on a fresh VM booted from %s.\n\n' "$version" >> "$GITHUB_STEP_SUMMARY"
  if [[ ${PROMOTE_IMAGE:-false} == true ]]; then
    az sig image-version update "${version_args[@]}" --set publishingProfile.excludeFromLatest=false -o none
    printf 'Version %s is now eligible for latest.\n' "$version" >> "$GITHUB_STEP_SUMMARY"
  else
    printf 'Candidate remains excluded from latest.\n' >> "$GITHUB_STEP_SUMMARY"
  fi
else
  printf 'Lab run completed without capturing a gallery image.\n' >> "$GITHUB_STEP_SUMMARY"
fi

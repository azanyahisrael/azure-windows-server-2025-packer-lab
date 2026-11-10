#!/usr/bin/env bash
set -euo pipefail

: "${PKR_VAR_build_resource_group:?Set AZURE_BUILD_RG in the image-build environment.}"
: "${BUILD_MODE:?Choose lab or candidate.}"

region=$(az group show -n "$PKR_VAR_build_resource_group" --query location -o tsv)
urn="MicrosoftWindowsServer:WindowsServer:2025-datacenter-g2:latest"
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
  exit 1
fi
if ! grep -Fq 'HARDENING_CHECKS_PASSED' "$build_log"; then
  echo 'The build did not report both hardening checks.' >&2
  exit 1
fi

printf '### Windows Server lab checks passed\n\n' >> "$GITHUB_STEP_SUMMARY"
printf 'Marketplace base version: %s\n\n' "$base_version" >> "$GITHUB_STEP_SUMMARY"
printf 'Public firewall logging and Process Creation auditing verified on the build VM.\n\n' >> "$GITHUB_STEP_SUMMARY"
if [[ $BUILD_MODE == candidate ]]; then
  excluded=$(az sig image-version show "${gallery_args[@]}" --gallery-image-version "$version" \
    --query publishingProfile.excludeFromLatest -o tsv)
  if [[ $excluded != true ]]; then
    echo 'Expected the gallery candidate to be excluded from latest.' >&2
    exit 1
  fi
  printf 'Gallery candidate %s is excluded from latest. Boot and review it before release.\n' \
    "$version" >> "$GITHUB_STEP_SUMMARY"
else
  printf 'Lab run completed without capturing a gallery image.\n' >> "$GITHUB_STEP_SUMMARY"
fi

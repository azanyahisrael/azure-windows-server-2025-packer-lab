packer {
  required_version = ">= 1.14.0"

  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "= 2.6.5"
    }
    windows-update = {
      source  = "github.com/rgl/windows-update"
      version = "= 0.18.5"
    }
  }
}

variable "runner_cidr" {
  type = string
}

variable "build_resource_group" {
  type    = string
  default = "rg-packer-lab"
}

variable "vm_size" {
  type    = string
  default = "Standard_D2s_v4"
}

variable "base_version" {
  type    = string
  default = "latest"
}

variable "build_vm_name" {
  type    = string
  default = ""
}

variable "hardening_script_path" {
  type    = string
  default = "Harden-V2.ps1"
}

variable "routine_patch_delay_days" {
  type    = number
  default = 7
  validation {
    condition     = var.routine_patch_delay_days >= 3 && floor(var.routine_patch_delay_days) == var.routine_patch_delay_days
    error_message = "The routine patch delay must be a whole number of days, at least 3."
  }
}

variable "critical_patch_delay_days" {
  type    = number
  default = 3
  validation {
    condition     = contains([1, 2, 3], var.critical_patch_delay_days)
    error_message = "The critical patch delay must be 1, 2, or 3 days."
  }
}

variable "expedited_kbs" {
  type    = list(string)
  default = []
  validation {
    condition     = alltrue([for kb in var.expedited_kbs : can(regex("^KB[0-9]+$", kb))])
    error_message = "Write expedited KBs as KB followed by digits."
  }
}

locals {
  expedited_kb_ids = [for kb in var.expedited_kbs : format("'%s'", trimprefix(kb, "KB"))]
  expedited_filter = length(var.expedited_kbs) == 0 ? "$false" : "(@($_.KBArticleIDs | Where-Object { $_ -in @(${join(", ", local.expedited_kb_ids)}) }).Count -gt 0)"
  patch_date       = "[datetime]::SpecifyKind($_.LastDeploymentChangeTime, [DateTimeKind]::Utc)"
}

variable "candidate" {
  type = object({
    resource_group = string
    gallery        = string
    definition     = string
    version        = string
  })
  default = null
}

source "azure-arm" "win2025" {
  use_azure_cli_auth        = true
  build_resource_group_name = var.build_resource_group
  vm_size                   = var.vm_size
  temp_compute_name         = var.build_vm_name
  skip_create_image         = var.candidate == null

  os_type         = "Windows"
  image_publisher = "MicrosoftWindowsServer"
  image_offer     = "WindowsServer"
  image_sku       = "2025-datacenter-g2"
  image_version   = var.base_version

  allowed_inbound_ip_addresses = [var.runner_cidr]
  communicator                 = "winrm"
  winrm_username               = "packerbuild"
  winrm_use_ssl                = true
  winrm_use_ntlm               = true
  winrm_insecure               = true # The temporary certificate is self-signed.

  shared_gallery_image_version_exclude_from_latest = true
  dynamic "shared_image_gallery_destination" {
    for_each = var.candidate == null ? [] : [var.candidate]
    content {
      resource_group = shared_image_gallery_destination.value.resource_group
      gallery_name   = shared_image_gallery_destination.value.gallery
      image_name     = shared_image_gallery_destination.value.definition
      image_version  = shared_image_gallery_destination.value.version
    }
  }
}

build {
  sources = ["source.azure-arm.win2025"]

  provisioner "powershell" {
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) { throw 'Expected a workgroup VM.' }",
      "Write-Output 'Packer reached the Windows workgroup VM.'",
    ]
  }

  provisioner "powershell" {
    script                   = "${path.root}/scripts/Initialize-ImageBuild.ps1"
    elevated_user            = "SYSTEM"
    elevated_password        = ""
    elevated_execute_command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{{ .Path }}\""
    timeout                  = "15m"
  }

  provisioner "windows-update" {
    search_criteria = "IsInstalled=0 and IsHidden=0 and Type='Software'"
    filters = [
      "exclude: -not $_.LastDeploymentChangeTime -or $_.LastDeploymentChangeTime -lt [datetime]'2000-01-01'",
      "include: ($_.MsrcSeverity -eq 'Critical' -or ${local.expedited_filter}) -and (${local.patch_date} -le [DateTime]::UtcNow.AddDays(-${var.critical_patch_delay_days}))",
      "exclude: $_.BrowseOnly",
      "include: ${local.patch_date} -le [DateTime]::UtcNow.AddDays(-${var.routine_patch_delay_days})",
    ]
    restart_timeout = "30m"
    timeout         = "2h"
  }

  provisioner "powershell" {
    script                   = "${path.root}/${var.hardening_script_path}"
    elevated_user            = "SYSTEM"
    elevated_password        = ""
    elevated_execute_command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{{ .Path }}\" -Profile L1 -Apply -ExcludeControl 18.10.94.2.2 -LgpoPath \"%ProgramFiles%/CIS Image Build/LGPO.exe\""
    timeout                  = "30m"
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  provisioner "powershell" {
    script                   = "${path.root}/scripts/Finalize-ImageBuild.ps1"
    elevated_user            = "SYSTEM"
    elevated_password        = ""
    elevated_execute_command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{{ .Path }}\""
    timeout                  = "15m"
  }

  provisioner "shell-local" {
    command = var.candidate == null ? "echo Lab checks complete." : "bash scripts/generalize-image.sh"
    timeout = "35m"
  }
}

packer {
  required_version = ">= 1.14.0"

  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "= 2.6.5"
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
    script            = "harden.ps1"
    elevated_user     = "SYSTEM"
    elevated_password = ""
  }

  provisioner "shell-local" {
    command = var.candidate == null ? "echo Lab checks complete." : "bash scripts/generalize-image.sh"
    timeout = "35m"
  }
}

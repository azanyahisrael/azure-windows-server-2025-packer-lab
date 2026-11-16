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
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = "~> 1.1"
    }
  }
}

variable "build_resource_group" {
  type    = string
  default = "rg-packer-lab"
}

variable "gallery_resource_group" {
  type    = string
  default = "rg-packer-images"
}

variable "gallery_name" {
  type    = string
  default = "packerLabImages"
}

variable "image_definition" {
  type    = string
  default = "windows-server-2025-lab"
}

variable "image_version" {
  type    = string
  default = "0.0.1"
}

variable "vm_size" {
  type    = string
  default = "Standard_D2s_v4"
}

# When set, only this address can reach WinRM on the build VM.
variable "runner_ip" {
  type    = string
  default = ""
}

source "azure-arm" "win2025" {
  use_azure_cli_auth        = true
  build_resource_group_name = var.build_resource_group
  vm_size                   = var.vm_size

  # The newest Windows Server 2025 image Microsoft publishes.
  os_type         = "Windows"
  image_publisher = "MicrosoftWindowsServer"
  image_offer     = "WindowsServer"
  image_sku       = "2025-datacenter-g2"

  communicator                 = "winrm"
  winrm_username               = "packerbuild"
  winrm_use_ssl                = true
  winrm_use_ntlm               = true
  winrm_insecure               = true # The temporary certificate is self-signed.
  allowed_inbound_ip_addresses = var.runner_ip == "" ? null : [var.runner_ip]

  shared_image_gallery_destination {
    resource_group = var.gallery_resource_group
    gallery_name   = var.gallery_name
    image_name     = var.image_definition
    image_version  = var.image_version
  }
}

build {
  sources = ["source.azure-arm.win2025"]

  # 1. Patch.
  provisioner "windows-update" {}

  # 2. Harden with the CIS Level 1 script.
  provisioner "powershell" {
    script = "${path.root}/scripts/Get-Lgpo.ps1"
  }

  provisioner "powershell" {
    script                   = "${path.root}/Harden-V2.ps1"
    elevated_user            = "SYSTEM"
    elevated_password        = ""
    elevated_execute_command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{{ .Path }}\" -Profile L1 -Apply -LgpoPath C:\\LGPO\\LGPO.exe"
    timeout                  = "30m"
  }

  provisioner "windows-restart" {
    restart_timeout = "15m"
  }

  # 3. Configure with Ansible.
  provisioner "ansible" {
    playbook_file = "${path.root}/ansible/configure.yml"
    user          = "packerbuild"
    use_proxy     = false
    extra_arguments = [
      "-e", "ansible_winrm_transport=ntlm",
      "-e", "ansible_winrm_server_cert_validation=ignore",
    ]
  }

  # 4. Generalize, then Packer captures the VM into the gallery. The scheduled task
  # deletes the build account the first time a VM made from this image starts.
  provisioner "powershell" {
    inline = [
      "schtasks.exe /Create /TN RemoveBuildUser /RU SYSTEM /SC ONSTART /F /TR 'cmd.exe /c net user packerbuild /delete & schtasks.exe /Delete /TN RemoveBuildUser /F'",
      "while ((Get-Service RdAgent).Status -ne 'Running') { Start-Sleep 5 }",
      "while ((Get-Service WindowsAzureGuestAgent).Status -ne 'Running') { Start-Sleep 5 }",
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /generalize /oobe /quiet /quit /mode:vm",
      "while ((Get-ItemProperty HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Setup\\State).ImageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { Start-Sleep 10 }",
    ]
    timeout = "30m"
  }
}

# Azure Windows Server 2025 Image Lab

Every Monday, GitHub Actions builds a patched, CIS-hardened Windows Server 2025 image and publishes it to an Azure Compute Gallery. Anything deployed from the gallery's `latest` version is at most a week old.

~~~mermaid
flowchart LR
    Base["Newest Marketplace image"] --> Patch["Windows Update"]
    Patch --> Harden["CIS Level 1 script"]
    Harden --> Configure["Ansible playbook"]
    Configure --> Sysprep["Sysprep"]
    Sysprep --> Gallery["New gallery version"]
~~~

## Why I built it this way

Every server I deploy starts from the same patched, CIS-hardened, versioned image. The image is built from code, so nobody hardens a server by hand.

| Tool | Why I picked it |
| --- | --- |
| Packer | Turns the image into code. One file creates a temporary VM from Microsoft's Marketplace image, runs every step, captures the result and deletes the VM. Every build comes out the same. |
| CIS Level 1 script | Hardens the image to a published standard, so I can say what the image meets and prove it. |
| Ansible | Enforces my own settings after hardening, such as automatic Windows updates. A playbook describes the end state, so it is safe to re-run and can later check deployed VMs. |
| Azure Compute Gallery | Stores each build as a numbered version. Deployments ask for `latest`, and I can roll back if a build is bad. |
| GitHub Actions | Rebuilds the image every week with nobody involved. It signs in to Azure with OIDC, so no Azure password is stored in GitHub. |
| zizmor | Scans the pipeline itself, because a pipeline that can create Azure resources needs protecting too. |

On cost: this does not beat Microsoft's standard Marketplace image, which has no image fee. It avoids the hourly software fee on pre-hardened Marketplace images, and it saves the time of patching and hardening each VM after it is deployed.

## What went wrong and how I fixed it

| What happened | Cause | Fix |
| --- | --- | --- |
| The build failed after Windows Update with only "Packer build failed" in the log. | A wrapper script hid the Packer output and printed a fixed list of known errors. This one was not on the list. | Removed the wrapper. The workflow now prints the full Packer log. |
| The pipeline had grown to 14 files with lab and candidate modes, a validation VM and a drift audit, and no run had ever published an image. | Too many stages were added before the basic build worked end to end. | Cut it back to one template, one playbook, one helper script and one workflow. |
| Images were set to notify before installing updates, not to install them. | The build excluded CIS control 18.10.94.2.2, which is the control that turns on automatic installs. | Removed the exclusion. The CIS script applies it and Ansible enforces it. |
| Packer stopped with "shared_image_gallery_destination must be specified". | The three gallery variables were never added to the GitHub environment. Earlier runs never published, so nothing had needed them. | Added `AZURE_GALLERY_RG`, `AZURE_GALLERY_NAME` and `AZURE_IMAGE_DEFINITION`. |
| Packer got `403 AuthorizationFailed` reading the gallery. | The variables pointed at a second resource group that did not exist and that the service principal had no role on. | Put the gallery in the build resource group, where the service principal already has Contributor. |
| The portal rejected the gallery name. | I typed a resource group style name with hyphens. Gallery names allow only letters, numbers, underscores and periods. | Named it `packerLabImages`. |
| Packer got `404 ResourceNotFound` for the image definition. | The gallery existed but had no image definition inside it. | Created `windows-server-2025-lab` as Windows, Generalized, Gen 2, Trusted launch supported. |

## What is in the repo

| File | Purpose |
| --- | --- |
| [windowsserver2025.pkr.hcl](windowsserver2025.pkr.hcl) | The whole build, top to bottom. |
| [ansible/configure.yml](ansible/configure.yml) | Settings enforced after hardening. Today it keeps automatic Windows updates on. |
| [scripts/Get-Lgpo.ps1](scripts/Get-Lgpo.ps1) | Downloads Microsoft's LGPO.exe for the hardening script. |
| [scripts/Show-HardeningLog.ps1](scripts/Show-HardeningLog.ps1) | Prints each CIS control's result in the build log, and again if any step fails. |
| [.github/workflows/windows-image.yml](.github/workflows/windows-image.yml) | Validates every push and scans the workflow with zizmor. Builds on Mondays and on **Run workflow**. |

The CIS script, `Harden-V2.ps1`, is private. The workflow downloads it from Azure Blob Storage and checks its SHA-256 before Packer runs.

## How the image stays fresh

A gallery image is a snapshot, so it cannot patch itself. Two things keep it current.

1. The weekly build starts from Microsoft's newest Marketplace image, installs every available update, and publishes a new version. The gallery's `latest` then points at it.
2. The CIS baseline sets Windows Update to install automatically every day, and the Ansible playbook enforces that setting, so a VM made from the image keeps patching itself.

## Setup

The build job runs in the GitHub environment **image-build-Azure-Packman-lab** and signs in to Azure with OIDC.

| Kind | Name | Value |
| --- | --- | --- |
| Secret | AZURE_CLIENT_ID | Application (client) ID of the app registration |
| Secret | AZURE_TENANT_ID | Directory (tenant) ID |
| Secret | AZURE_SUBSCRIPTION_ID | Lab subscription ID |
| Variable | AZURE_BUILD_RG | Resource group for the temporary build VM |
| Variable | AZURE_GALLERY_RG | Resource group of the Compute Gallery |
| Variable | AZURE_GALLERY_NAME | Compute Gallery name |
| Variable | AZURE_IMAGE_DEFINITION | Image definition name |
| Variable | BASELINE_STORAGE_ACCOUNT | Storage account holding `Harden-V2.ps1` |
| Variable | BASELINE_CONTAINER | Its container |
| Variable | BASELINE_BLOB | Its blob name |
| Variable | BASELINE_SHA256 | SHA-256 of the reviewed script |

The app's service principal needs these roles.

| Role | Scope |
| --- | --- |
| Contributor | The build resource group, which also holds the gallery |
| Storage Blob Data Reader | The baseline container |

The federated credential on the app registration must match the environment name. [GitHub OIDC for Azure](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-azure)

Create the gallery and a **Windows, generalized, x64, Gen2** image definition once, in the build resource group. Gallery names cannot contain hyphens.

~~~powershell
$region = az group show -n 'rg-packer-lab' --query location -o tsv
az sig create -g 'rg-packer-lab' --gallery-name 'packerLabImages' -l $region -o none
az sig image-definition create -g 'rg-packer-lab' --gallery-name 'packerLabImages' --gallery-image-definition 'windows-server-2025-lab' --publisher PortfolioLab --offer WindowsServer2025 --sku Workgroup --os-type Windows --os-state Generalized --hyper-v-generation V2 --features SecurityType=TrustedLaunchSupported -o none
~~~

## Run it

Go to **Actions → Windows Server image → Run workflow**. Untick **Apply CIS hardening** for a test build that checks everything except hardening. A test version is kept out of `latest`, so nothing deploys it by accident. Each run publishes version `1.0.<run number>`. The full Packer log is in the build step, so a failed run shows the exact error.

To run it from your own machine, install Packer, Azure CLI, Ansible and `pywinrm`, put `Harden-V2.ps1` next to the template, then run the build. Ansible needs Linux, macOS or WSL.

~~~bash
az login
packer init .
packer build .
~~~

Old gallery versions are not deleted automatically. Each one costs storage, so remove the ones you no longer deploy.

## Next

1. Security scanning of the image before a version is published. The workflow file itself is already scanned by [zizmor](https://docs.zizmor.sh/audits/).
2. Monitoring for VMs deployed from the image.

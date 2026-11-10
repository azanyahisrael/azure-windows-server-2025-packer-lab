# Azure Windows Server 2025 Image Lab

This lab uses Packer to provision a standalone Windows Server 2025 Datacenter Gen2 VM in Azure. It includes PowerShell checks for two hardening settings and a GitHub Actions workflow with separate paths for validating code, running the lab, and capturing a versioned Azure Compute Gallery candidate.

## Tools used

| Tool | How it was used |
| --- | --- |
| HashiCorp Packer and HCL | Defined the Windows Marketplace base image, temporary VM, and provisioning steps. |
| PowerShell and WinRM | Checked that the VM was in a workgroup. The hardening script sets and reads back firewall logging and process creation auditing. |
| Azure CLI, Azure Portal, and Azure Activity Log | Looked up Marketplace image versions and investigated deployment failures and VM-family quotas. |
| GitHub Actions | Ran template validation and provides a manual job for Azure builds. |
| Microsoft Entra ID and Azure RBAC | Configured OIDC federation for the GitHub environment and scoped the service principal's build permissions to the lab resource group. |

## What was verified

| Stage | Result |
| --- | --- |
| Azure VM provisioning | A local Packer run booted Windows Server 2025 in East US using **Standard_D2s_v4**. |
| Windows connection | WinRM connected and the inline PowerShell check confirmed a workgroup VM. |
| Cleanup | Packer removed the temporary VM, disk, network resources and Key Vault. The lab resource group remained available for future builds. |
| Updated project | Packer validation passed locally for lab and candidate modes. The GitHub Actions workflow passed actionlint, and the PowerShell and Bash scripts passed syntax checks. |
| GitHub Actions | The push-triggered validation job passed. The Azure build job is enabled for manual runs on the default branch. [Validation run](https://github.com/azanyahisrael/azure-windows-server-2025-packer-lab/actions/runs/42889574371) |
| Next verification | Run the updated provisioner from GitHub Actions in Azure, then capture and boot a gallery candidate. |

The initial Azure run exercised connectivity and cleanup. This version adds explicit readback for Public-profile firewall connection logging and successful Process Creation auditing. The full **CIS Windows Server 2025 Stand-alone Level 1** policy and a CIS-CAT assessment are future milestones. [CIS Windows Server benchmarks](https://www.cisecurity.org/benchmark/microsoft_windows_server)

## Build flow

~~~mermaid
flowchart LR
    PR["Pull request or push"] --> Validate["Packer and script validation"]
    Manual["Manual GitHub Actions run"] --> Validate
    Validate -->|Manual run on default branch| Login["Azure login via OIDC"]
    Login --> Base["Resolve latest Marketplace version"]
    Base --> VM["Temporary Windows build VM"]
    VM --> Checks["Apply and verify two hardening settings"]
    Checks -->|Lab mode| Cleanup["Clean up temporary resources"]
    Checks -->|Candidate mode| Generalize["Remove build access and run Sysprep"]
    Generalize --> Gallery["Versioned Azure Compute Gallery candidate"]
    Gallery --> Cleanup
~~~

| File | Purpose |
| --- | --- |
| [windowsserver2025.pkr.hcl](windowsserver2025.pkr.hcl) | Configures the Azure base image, temporary VM and Packer provisioners. |
| [harden.ps1](harden.ps1) | Applies the two controls and fails the build if the readback is unexpected. |
| [.github/workflows/windows-image.yml](.github/workflows/windows-image.yml) | Validates changes and offers a manual Azure build through OIDC. |
| [scripts/build-in-azure.sh](scripts/build-in-azure.sh) | Resolves the Marketplace version and runner IP, starts Packer and writes a public-safe summary. |
| [scripts/generalize.ps1](scripts/generalize.ps1) | Removes temporary build access and prepares Windows for capture via Azure VM Run Command. |

## Run the lab from Windows PowerShell

Install [Packer](https://developer.hashicorp.com/packer/install) and [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-windows?pivots=winget). Use Packer 1.14 or later. This project was checked with Packer 1.16.2 and pins the Azure plugin to 2.6.5.

Run these commands from the repository folder. Replace the subscription placeholder and use a lab resource group in a region where the selected size has at least two available vCPUs.

~~~powershell
az login
az account set --subscription '<your-lab-subscription>'
az account show --query name -o tsv

$env:PKR_VAR_build_resource_group = 'rg-packer-lab'
az group show --name $env:PKR_VAR_build_resource_group --query location -o tsv

$publicIp = (Invoke-RestMethod 'https://api.ipify.org?format=json' -ErrorAction Stop).ip
$env:PKR_VAR_runner_cidr = "$publicIp/32"

packer init .
packer validate .
~~~

After validation passes, run `packer build .` in the same window. This creates temporary Azure resources that can incur usage charges. Look for the workgroup message followed by `HARDENING_CHECKS_PASSED`. In lab mode, Packer ends with cleanup and reports that no artifacts were created.

For a reproducible local build, set `PKR_VAR_base_version` to a specific version. The GitHub Actions run resolves `latest` once in the build region, passes the exact version to Packer and records it in the run summary. [Azure Marketplace image lookup](https://learn.microsoft.com/en-us/cli/azure/vm/image?view=azure-cli-latest#az-vm-image-show)

## Connect GitHub Actions to Azure

Create the GitHub environment **image-build** under **Settings → Environments**. Under **Deployment branches and tags**, choose **Selected branches and tags** and allow only the default branch, `main`. The validation job uses read-only repository permissions. The manual build job requests an OIDC token through the `image-build` environment. [GitHub OIDC for Azure](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-azure)

1. In the lab tenant, create a single-tenant **App registration**. Entra creates its service principal, which appears under **Enterprise applications**. Copy the **Application (client) ID** and **Directory (tenant) ID** from the registration's Overview page. [Microsoft Entra app registration](https://learn.microsoft.com/en-us/entra/identity-platform/howto-create-service-principal-portal)
2. On the app registration, go to **Certificates & secrets → Federated credentials → Add credential**. Select **GitHub Actions deploying Azure resources**. Set the organization to the GitHub repository owner's username or organization name and enter the repository name. Use the GitHub owner and repository IDs when prompted. Select **Environment** and enter `image-build`.
3. In the Azure portal, open the dedicated build resource group and go to **Access control (IAM) → Add role assignment**. Assign **Contributor** to the app's service principal at that resource group. [Azure role assignments](https://learn.microsoft.com/en-us/entra/identity-platform/howto-create-service-principal-portal#assign-a-role-to-the-application)

For a public repository, the GitHub API returns the numeric IDs used by the form. `owner.id` is the **Organization ID** field, including for a personal repository. `id` is the **Repository ID**. Check the generated **Subject identifier** against the repository's OIDC subject format. New GitHub.com repositories use the owner and repository IDs in the subject. [GitHub OIDC subject formats](https://docs.github.com/en/actions/reference/security/oidc#immutable-subject-claims)

~~~powershell
$repo = Invoke-RestMethod 'https://api.github.com/repos/<owner>/<repository>'
$repo.owner.id
$repo.id
"repo:$($repo.owner.login)@$($repo.owner.id)/$($repo.name)@$($repo.id):environment:image-build"
~~~

In the **image-build** environment, add these secrets and variables:

| Kind | Name | Value |
| --- | --- | --- |
| Secret | AZURE_CLIENT_ID | Application (client) ID from the app registration |
| Secret | AZURE_TENANT_ID | Directory (tenant) ID from the app registration |
| Secret | AZURE_SUBSCRIPTION_ID | Subscription ID for the Azure lab subscription |
| Variable | AZURE_BUILD_RG | The existing lab resource group, such as `rg-packer-lab` |

Go to **Actions → Windows Server image lab → Run workflow**, choose the default branch, and select **lab** for the first run. The hosted runner resolves its public IPv4 for the temporary WinRM allowlist. The lab uses a temporary self-signed WinRM certificate, with server certificate verification disabled in Packer. The public workflow summary reports check results without publishing the raw Packer log. Use the Azure Activity Log to see detailed deployment errors. [Azure Packer builder](https://developer.hashicorp.com/packer/integrations/hashicorp/azure/latest/components/builder/arm)

## Capture a gallery candidate

Create a **Windows, generalized, x64, Gen2** image definition in an Azure Compute Gallery. The example keeps the gallery in the build region and uses a separate resource group. Give the workflow identity read access at gallery scope and write access at image-definition scope.

~~~powershell
$region = az group show -n 'rg-packer-lab' --query location -o tsv
$principalId = az ad sp show --id '<application-client-id>' --query id -o tsv
$galleryRg = 'rg-packer-images'
$gallery = 'packerLabImages'
$definition = 'windows-server-2025-lab'

az group create -n $galleryRg -l $region -o none
az sig create -g $galleryRg --gallery-name $gallery -l $region -o none
$galleryId = az sig show -g $galleryRg --gallery-name $gallery --query id -o tsv
$definitionId = az sig image-definition create -g $galleryRg --gallery-name $gallery --gallery-image-definition $definition --publisher PortfolioLab --offer WindowsServer2025 --sku Workgroup --os-type Windows --os-state Generalized --hyper-v-generation V2 --features SecurityType=TrustedLaunchSupported --query id -o tsv

az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role Reader --scope $galleryId -o none
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role Contributor --scope $definitionId -o none
~~~

Add three more variables to **image-build**:

| Variable | Value |
| --- | --- |
| AZURE_GALLERY_RG | `$galleryRg` |
| AZURE_GALLERY_NAME | `$gallery` |
| AZURE_IMAGE_DEFINITION | `$definition` |

Run the workflow again with **candidate**. Azure VM Run Command uses the Guest Agent to remove the temporary build account and HTTPS WinRM listener, then runs Sysprep. Packer publishes the image as `1.<run-number>.<run-attempt>` and excludes it from `latest`. Deploy a test VM using the exact candidate version, confirm that the guest starts, and recheck the hardening before approving that image for use. [Azure managed Run Command](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/run-command-managed) · [Azure gallery version management](https://learn.microsoft.com/en-us/azure/virtual-machines/update-image-resources)

## Troubleshooting from the lab

| Symptom | What resolved it |
| --- | --- |
| PowerShell could not find `packer` or `az` | Installed the matching Windows CLI and reopened PowerShell so it could pick up the new PATH. |
| Azure returned `InvalidTemplateDeployment` | Looked up the tracking ID in the Azure Activity Log and read the inner `QuotaExceeded` error. |
| East US DSv5 family quota was zero | Checked available VM-family quotas and switched to `Standard_D2s_v4` after preflight validation. |
| Quotas showed an empty table | Registered `Microsoft.Compute` and `Microsoft.Quota` for the lab subscription. |
| Only the WinRM test appeared in the log | The script had been saved with a `.txt` suffix and the template only had the inline test. This project includes the correctly named `harden.ps1` and a second provisioner wired to it. |
| The GitHub run was green, but Azure showed no VM | The run's event was `push` and the build job was skipped. Use **Run workflow** in `lab` mode to start an Azure build. **Re-run jobs** repeats the original event. |
| The federation form asked for an Organization ID | For a personal repository, use the GitHub account's numeric owner ID. The GitHub repository API returns it in `owner.id`. |
| The local lab finished with no artifact | Lab mode stops after provisioning and cleanup. Candidate mode adds generalization and image capture. |

For the full CIS profile, obtain the licensed **Windows Server 2025 Stand-alone v2.0.0 Level 1 Build Kit**, review the GPO settings and integrate them in the provisioning phase. Verify the resulting image with CIS-CAT Pro and document any manual settings and exceptions before promoting it. [CIS Build Kit FAQ](https://www.cisecurity.org/cis-securesuite/cis-securesuite-build-kit-content/build-kits-faq)

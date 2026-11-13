# Azure Windows Server 2025 Image Lab

Packer builds a Windows Server 2025 Datacenter Gen2 image in Azure. GitHub Actions can run a temporary lab build or capture a new Azure Compute Gallery version. For a gallery build, Ansible checks a fresh VM booted from the exact version before the workflow can promote it.

## Tools used

| Tool | How it was used |
| --- | --- |
| HashiCorp Packer and HCL | Defined the Windows Marketplace base image, temporary VM, and provisioning steps. |
| PowerShell and WinRM | Applies the reviewed Level 1 baseline and checks Windows Update policy on the temporary build VM. |
| Azure CLI, Azure Portal, and Azure Activity Log | Looked up Marketplace image versions and investigated deployment failures and VM-family quotas. |
| GitHub Actions | Validates the template and starts Azure builds manually or on a daily schedule when enabled. |
| Ansible and Azure VM Run Command | Checks the booted candidate from the CI runner through the Azure guest agent. The test VM has no public IP. |
| Microsoft Entra ID and Azure RBAC | Configured OIDC federation for the GitHub environment and scoped the service principal's build permissions to the lab resource group. |

## Prior lab verification

| Stage | Result |
| --- | --- |
| Azure VM provisioning | A local Packer run booted Windows Server 2025 in East US using **Standard_D2s_v4**. |
| Windows connection | WinRM connected and the inline PowerShell check confirmed a workgroup VM. |
| Cleanup | Packer removed the temporary VM, disk, network resources and Key Vault. The lab resource group remained available for future builds. |
| Updated project | Packer validation passed locally for lab and candidate modes. The GitHub Actions workflow passed actionlint, and the PowerShell and Bash scripts passed syntax checks. |
| GitHub Actions | The push-triggered validation job passed. The Azure build job is enabled for manual runs on the default branch. [Validation run](https://github.com/azanyahisrael/azure-windows-server-2025-packer-lab/actions/runs/42889574371) |
| Next verification | Run the updated workflow in candidate mode and review the Ansible audit before enabling scheduled builds. |

The initial Azure run exercised connectivity and cleanup. The updated workflow applies the reviewed script derived from the Windows Server 2025 Stand-alone v2.0.0 Level 1 baseline. Its post-capture audit reads machine registry policy, active firewall settings, account policy, user rights and advanced auditing. Per-user settings, manual assessments and the four settings that need organization-specific account names or sign-in text are outside this audit. A separate check verifies the documented Windows Update exception. [CIS Windows Server benchmarks](https://www.cisecurity.org/benchmark/microsoft_windows_server)

## Build flow

~~~mermaid
flowchart LR
    PR["Pull request or push"] --> Validate["Packer and script validation"]
    Manual["Manual or enabled daily run"] --> Validate
    Validate --> Login["Azure login via OIDC"]
    Login --> Base["Select Windows Marketplace base"]
    Base --> VM["Temporary Windows build VM"]
    VM --> Checks["Install eligible patches, apply Level 1 and reboot"]
    Checks -->|Lab mode| Cleanup["Clean up temporary resources"]
    Checks -->|Candidate mode| Generalize["Remove build access and run Sysprep"]
    Generalize --> Gallery["Capture version excluded from latest"]
    Gallery --> Drift["Boot exact version and run Ansible audit"]
    Drift -->|Passed and promotion requested| Promote["Include the version in latest"]
    Drift -->|Drift detected or audit failed| Failed["Fail run and keep candidate excluded"]
~~~

| File | Purpose |
| --- | --- |
| [windowsserver2025.pkr.hcl](windowsserver2025.pkr.hcl) | Configures the Azure base image, temporary VM and Packer provisioners. |
| [.github/workflows/windows-image.yml](.github/workflows/windows-image.yml) | Validates changes and runs the build through Azure OIDC. |
| [scripts/build-in-azure.sh](scripts/build-in-azure.sh) | Builds, calls post-capture verification and gates gallery promotion. |
| [scripts/generalize.ps1](scripts/generalize.ps1) | Removes temporary build access and prepares Windows for capture via Azure VM Run Command. |
| [scripts/verify-image.sh](scripts/verify-image.sh) | Boots the captured version on a private subnet, starts Ansible and deletes the test resources. |
| [scripts/check-image-drift.yml](scripts/check-image-drift.yml) | Runs the guest audit and fails the pipeline if the result is missing or reports drift. |

## Run the lab from Windows PowerShell

Install [Packer](https://developer.hashicorp.com/packer/install) and [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-windows?pivots=winget). Use Packer 1.14 or later. This project was checked with Packer 1.16.2 and pins the Azure plugin to 2.6.5.

Run these commands from the repository folder, where your reviewed `Harden-V2.ps1` sits next to `windowsserver2025.pkr.hcl`. Git ignores the local baseline. Replace the subscription placeholder and use a lab resource group in a region where the selected size has at least two available vCPUs.

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

For a reproducible local build, set `PKR_VAR_base_version` to a specific version. Gallery candidate runs require a reviewed `AZURE_BASE_VERSION` because Packer's patch delays only apply to updates it installs. A Windows Marketplace image may already contain newer patches. The workflow records the exact base version in its summary. [Azure Marketplace image lookup](https://learn.microsoft.com/en-us/cli/azure/vm/image?view=azure-cli-latest#az-vm-image-show)

## Connect GitHub Actions to Azure

Open the GitHub environment **image-build-Azure-Packman-lab** under **Settings → Environments**. Under **Deployment branches and tags**, the environment allows the default branch, `main`. The validation job uses read-only repository permissions. The build job requests an OIDC token through this environment. [GitHub OIDC for Azure](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-azure)

1. In the lab tenant, create a single-tenant **App registration**. Entra creates its service principal, which appears under **Enterprise applications**. Copy the **Application (client) ID** and **Directory (tenant) ID** from the registration's Overview page. [Microsoft Entra app registration](https://learn.microsoft.com/en-us/entra/identity-platform/howto-create-service-principal-portal)
2. On the app registration, go to **Certificates & secrets → Federated credentials → Add credential**. Select **GitHub Actions deploying Azure resources**. Set the organization to the GitHub repository owner's username or organization name and enter the repository name. Use the GitHub owner and repository IDs when prompted. Select **Environment** and enter `image-build-Azure-Packman-lab`.
3. In the Azure portal, open the dedicated build resource group and go to **Access control (IAM) → Add role assignment**. Assign **Contributor** to the app's service principal at that resource group. [Azure role assignments](https://learn.microsoft.com/en-us/entra/identity-platform/howto-create-service-principal-portal#assign-a-role-to-the-application)

For a public repository, the GitHub API returns the numeric IDs used by the form. `owner.id` is the **Organization ID** field, including for a personal repository. `id` is the **Repository ID**. Check the generated **Subject identifier** against the repository's OIDC subject format. New GitHub.com repositories use the owner and repository IDs in the subject. [GitHub OIDC subject formats](https://docs.github.com/en/actions/reference/security/oidc#immutable-subject-claims)

~~~powershell
$repo = Invoke-RestMethod 'https://api.github.com/repos/<owner>/<repository>'
$repo.owner.id
$repo.id
"repo:$($repo.owner.login)@$($repo.owner.id)/$($repo.name)@$($repo.id):environment:image-build-Azure-Packman-lab"
~~~

The **image-build-Azure-Packman-lab** environment has these secrets and variables.

| Kind | Name | Value |
| --- | --- | --- |
| Secret | AZURE_CLIENT_ID | Application (client) ID from the app registration |
| Secret | AZURE_TENANT_ID | Directory (tenant) ID from the app registration |
| Secret | AZURE_SUBSCRIPTION_ID | Subscription ID for the Azure lab subscription |
| Variable | AZURE_BUILD_RG | The existing lab resource group, such as `rg-packer-lab` |

Store the reviewed `Harden-V2.ps1` in a private Azure Blob container reachable from the GitHub runner. Grant the workflow identity **Storage Blob Data Reader** on that container. From the repository folder, an operator with blob write permission can upload the script under a name derived from its hash. Set `BASELINE_STORAGE_ACCOUNT`, `BASELINE_CONTAINER`, `BASELINE_BLOB`, and `BASELINE_SHA256` in **image-build-Azure-Packman-lab** to the corresponding values. When you approve a revised baseline, upload it under its new name and update the blob name and hash together. [Authorize Azure CLI access to Blob Storage](https://learn.microsoft.com/en-us/azure/storage/blobs/authorize-data-operations-cli)

~~~powershell
$account = '<storage-account>'
$container = '<private-container>'
$hash = (Get-FileHash .\Harden-V2.ps1 -Algorithm SHA256).Hash.ToLowerInvariant()
$blob = "Harden-V2-$hash.ps1"
az storage blob upload --auth-mode login --account-name $account --container-name $container --name $blob --file .\Harden-V2.ps1 --overwrite false -o none
~~~

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

Add these variables to **image-build-Azure-Packman-lab**.

| Variable | Value |
| --- | --- |
| AZURE_GALLERY_RG | `$galleryRg` |
| AZURE_GALLERY_NAME | `$gallery` |
| AZURE_IMAGE_DEFINITION | `$definition` |
| AZURE_BASE_VERSION | Exact approved Marketplace version available in the build region |
| AZURE_VALIDATION_SUBNET_ID | Full resource ID of a lab subnet in the build region with outbound HTTPS for the Azure VM agent |

The workflow identity needs permission to read and join the validation subnet. The existing Contributor assignment covers a subnet inside the build resource group. For a subnet in another resource group, grant the identity access there, scoped to the lab subnet or virtual network as appropriate. Azure Run Command needs a working guest agent and outbound HTTPS. [Azure VM Run Command networking](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/run-command)

Run **candidate** with **promote** unchecked for the first end-to-end test. Packer captures `1.<run-number>.<run-attempt>` excluded from `latest`. The pipeline boots that exact version and runs the Ansible playbook, then deletes the test resources. A failed audit leaves the version excluded. A passing manual run promotes the version if **promote** was selected. This affects new deployments that resolve the gallery definition's `latest` version. [Azure gallery version management](https://learn.microsoft.com/en-us/azure/virtual-machines/update-image-resources)

## Schedule image updates

Set the **repository** Actions variable `ENABLE_SCHEDULED_IMAGE_BUILDS` to `true` to enable the daily run at 09:17 UTC on the default branch. A scheduled run builds a new version and makes it eligible for `latest` after the audit passes. GitHub environment approval rules, if configured, still apply. [GitHub Actions scheduled workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)

The **image-build-Azure-Packman-lab** environment can override `ROUTINE_PATCH_DELAY_DAYS` (default 7), `CRITICAL_PATCH_DELAY_DAYS` (default 3, allowed 1–3), and `EXPEDITED_KBS` (a JSON list such as `["KB1234567"]`). The Windows Update Agent catalog date is used to evaluate delay. The Windows Update exception sets the VM to notify before installation. Superseded updates and patches already included in the approved Marketplace base are subject to the update catalog and base image contents.

When CIS publishes a benchmark revision, review the changes before updating the baseline script and its pinned hash. Future builds use the reviewed revision. The post-capture audit checks the image before release. Ongoing compliance checks on VMs already deployed have their own trigger and inventory.

## Troubleshooting from the lab

| Symptom | What resolved it |
| --- | --- |
| PowerShell could not find `packer` or `az` | Installed the matching Windows CLI and reopened PowerShell so it could pick up the new PATH. |
| Azure returned `InvalidTemplateDeployment` | Looked up the tracking ID in the Azure Activity Log and read the inner `QuotaExceeded` error. |
| East US DSv5 family quota was zero | Checked available VM-family quotas and switched to `Standard_D2s_v4` after preflight validation. |
| Quotas showed an empty table | Registered `Microsoft.Compute` and `Microsoft.Quota` for the lab subscription. |
| Only the WinRM test appeared in the initial lab log | The script had been saved with a `.txt` suffix. The current template loads the reviewed `Harden-V2.ps1` from the repository folder. |
| The GitHub run was green, but Azure showed no VM | A `push` validates the code. Use **Run workflow** to start an Azure build. **Re-run jobs** repeats the original event. |
| The federation form asked for an Organization ID | For a personal repository, use the GitHub account's numeric owner ID. The GitHub repository API returns it in `owner.id`. |
| The local lab finished with no artifact | Lab mode stops after provisioning and cleanup. Candidate mode adds generalization and image capture. |

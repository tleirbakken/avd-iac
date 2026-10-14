<#
.SYNOPSIS
    Setter opp GitHub OIDC mot Azure for avd-iac. Idempotent – trygt å kjøre flere ganger.

.DESCRIPTION
    Oppretter:
      - Resource group for identiteter
      - id-gh-avd-iac-plan  (FIC: environment dev-plan) → custom role "Bicep What-If Operator - avd-iac"
      - id-gh-avd-iac-dev   (FIC: environment dev)      → Contributor
      - GitHub environments dev-plan og dev (dev: kun main)
      - GitHub variables: AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID (repo), AZURE_CLIENT_ID (per environment)
    Ingen secrets opprettes noe sted.

.EXAMPLE
    ./scripts/Setup-Oidc.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -GitHubRepo norva24/avd-iac
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string]$GitHubRepo,                       # "org/repo" – case-sensitivt i FIC-subject

    [string]$Location = 'norwayeast',
    [string]$IdentityResourceGroup = 'rg-avd-iac-identity'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true   # PS 7.3+: feil i az/gh stopper scriptet

$issuer         = 'https://token.actions.githubusercontent.com'
$scope          = "/subscriptions/$SubscriptionId"
$whatIfRoleName = 'Bicep What-If Operator - avd-iac'

# environment-navn i GitHub → navn på managed identity i Azure
$identities = [ordered]@{
    'dev-plan' = 'id-gh-avd-iac-plan'
    'dev'      = 'id-gh-avd-iac-dev'
}

function Write-Step([string]$Text) { Write-Host "`n== $Text ==" -ForegroundColor Cyan }

# -----------------------------------------------------------------------------
Write-Step 'Kontekst'
az account set --subscription $SubscriptionId
$tenantId = az account show --query tenantId -o tsv
$who      = az account show --query user.name -o tsv
Write-Host "Azure:  $who  tenant=$tenantId  sub=$SubscriptionId"
$repoName = gh repo view $GitHubRepo --json nameWithOwner -q .nameWithOwner
if ($repoName -cne $GitHubRepo) {
    throw "Repo-navn må matche nøyaktig (case-sensitivt). GitHub sier '$repoName', du ga '$GitHubRepo'."
}
Write-Host "GitHub: $repoName"

# -----------------------------------------------------------------------------
Write-Step 'Managed identities og federated credentials'
az group create -n $IdentityResourceGroup -l $Location --tags Workload=avd-iac ManagedBy=Setup-Oidc -o none

$result = @{}
foreach ($envName in $identities.Keys) {
    $miName = $identities[$envName]
    $mi = az identity create -n $miName -g $IdentityResourceGroup -l $Location -o json | ConvertFrom-Json
    $result[$envName] = $mi

    $ficName = "gh-$envName"
    $subject = "repo:${GitHubRepo}:environment:$envName"
    $exists  = az identity federated-credential list --identity-name $miName -g $IdentityResourceGroup `
                 --query "length([?name=='$ficName'])" -o tsv
    if ($exists -eq '0') {
        az identity federated-credential create -n $ficName --identity-name $miName -g $IdentityResourceGroup `
            --issuer $issuer --subject $subject --audiences 'api://AzureADTokenExchange' -o none
    }
    Write-Host ("  {0,-20} clientId={1}" -f $miName, $mi.clientId)
    Write-Host ("  {0,-20} subject={1}" -f '', $subject)
}

# -----------------------------------------------------------------------------
Write-Step 'Custom role for what-if'
$roleExists = az role definition list --name $whatIfRoleName --custom-role-only true --query 'length(@)' -o tsv
if ($roleExists -eq '0') {
    $def = @{
        Name             = $whatIfRoleName
        Description      = 'Lese og kjøre validate/what-if. Kan ikke endre ressurser.'
        Actions          = @(
            '*/read'
            'Microsoft.Resources/deployments/validate/action'
            'Microsoft.Resources/deployments/whatIf/action'
        )
        NotActions       = @()
        AssignableScopes = @($scope)
    }
    $tmp = New-TemporaryFile
    try {
        $def | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding utf8
        az role definition create --role-definition "@$tmp" -o none
    }
    finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    Write-Host "  Opprettet: $whatIfRoleName. Venter 30 s på replikering ..."
    Start-Sleep -Seconds 30
}
else {
    Write-Host "  Finnes: $whatIfRoleName"
}

# -----------------------------------------------------------------------------
Write-Step 'Rolletildelinger'
# Nye service principals bruker tid på å replikere i Entra – derfor retry
function Grant-Role([string]$PrincipalId, [string]$Role, [string]$Label) {
    for ($i = 1; $i -le 8; $i++) {
        try {
            $count = az role assignment list --assignee $PrincipalId --role $Role --scope $scope --query 'length(@)' -o tsv
            if ($count -ne '0') { Write-Host "  $Label har '$Role'"; return }
            az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type ServicePrincipal `
                --role $Role --scope $scope -o none
            Write-Host "  $Label → '$Role'"
            return
        }
        catch {
            if ($i -eq 8) { throw }
            Write-Host "  ${Label}: forsøk $i feilet (replikering), venter 15 s ..." -ForegroundColor Yellow
            Start-Sleep -Seconds 15
        }
    }
}

Grant-Role -PrincipalId $result['dev-plan'].principalId -Role $whatIfRoleName -Label 'plan'
Grant-Role -PrincipalId $result['dev'].principalId      -Role 'Contributor'   -Label 'dev'

# -----------------------------------------------------------------------------
Write-Step 'GitHub environments'
'{}' | gh api -X PUT "repos/$GitHubRepo/environments/dev-plan" --input - | Out-Null
Write-Host '  dev-plan (ingen begrensning – brukes av PR-jobber)'

'{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' |
    gh api -X PUT "repos/$GitHubRepo/environments/dev" --input - | Out-Null
$branches = gh api "repos/$GitHubRepo/environments/dev/deployment-branch-policies" --jq '.branch_policies[].name'
if (@($branches) -notcontains 'main') {
    '{"name":"main","type":"branch"}' |
        gh api -X POST "repos/$GitHubRepo/environments/dev/deployment-branch-policies" --input - | Out-Null
}
Write-Host '  dev (kun main)'

# -----------------------------------------------------------------------------
Write-Step 'GitHub variables (ikke secrets)'
gh variable set AZURE_TENANT_ID       --repo $GitHubRepo --body $tenantId
gh variable set AZURE_SUBSCRIPTION_ID --repo $GitHubRepo --body "$SubscriptionId"
gh variable set AZURE_CLIENT_ID       --repo $GitHubRepo --env dev-plan --body $result['dev-plan'].clientId
gh variable set AZURE_CLIENT_ID       --repo $GitHubRepo --env dev      --body $result['dev'].clientId

$secrets = gh secret list --repo $GitHubRepo --json name -q '.[].name'
if ($secrets) { Write-Warning "Repoet har secrets: $($secrets -join ', ')" }
else          { Write-Host '  Ingen repository secrets ✔' }

Write-Host "`nFerdig. Vent 5 minutter på RBAC-propagering før du kjører workflowen." -ForegroundColor Green

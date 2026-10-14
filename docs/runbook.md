# avd-iac – runbook for i kveld

**Mål:** Et fungerende Bicep-prosjekt på GitHub som validerer, forhåndsviser (what-if) og deployer til Azure med OIDC, uten secrets.

**Ferdig når:**
- [ ] PR mot `main` gir grønn **Validate** + **What-if**, og what-if vises som kommentar på PR-en
- [ ] Merge til `main` gir grønn **Deploy dev**, og Storage Account finnes i `rg-avd-iac-dev`
- [ ] Ny kjøring viser kun `NoChange` (idempotent)
- [ ] Repoet og GitHub har **null secrets**

**Merking i dokumentet**

| Merke | Betyr |
|---|---|
| 🖥️ **TERMINAL** | Kjør selv i PowerShell 7 (VS Code-terminal) |
| 🤖 **CLAUDE CODE** | Gi prompten til Claude Code |
| 🌐 **GITHUB** | Gjøres i nettleseren på github.com |
| ✅ **SJEKK** | Verifiser før du går videre |

**Tidsplan (ca. 75 min)**

| # | Steg | Hvor | Tid |
|---|---|---|---|
| 1 | Forutsetninger | 🖥️ | 5 |
| 2 | Opprett repo | 🖥️ | 2 |
| 3 | Lag filene | 🤖 | 10 |
| 4 | Lokal validering og what-if | 🖥️ | 10 |
| 5 | Første push | 🖥️ | 3 |
| 6 | OIDC-oppsett | 🖥️ | 10 |
| 7 | Kontroller GitHub-oppsett | 🌐 | 5 |
| 8 | Første PR (plan) | 🖥️ + 🌐 | 10 |
| 9 | Branch-ruleset | 🌐 | 5 |
| 10 | Merge og deploy | 🌐 + 🖥️ | 10 |
| 11 | Idempotens-test | 🌐 | 5 |

---

## 0. Arkitektur i én tabell

| Hendelse | Jobber | GitHub environment | Azure-identitet | Rettighet |
|---|---|---|---|---|
| PR mot `main` | Validate → What-if | `dev-plan` | `id-gh-avd-iac-plan` | Custom role: `*/read` + validate + what-if |
| Push/merge til `main` | Validate → What-if → Deploy | `dev-plan` → `dev` | `id-gh-avd-iac-dev` | Contributor på subscription |

**Hvorfor to identiteter:** Hvem som helst som lager en PR kan endre workflow-fila i sin branch. Federated credential for `dev` matcher kun subject `repo:<org>/<repo>:environment:dev`, og environment `dev` tillater kun `main`. En PR kan dermed aldri få et token som kan skrive.

**Terraform → Bicep, det viktigste:**

| Terraform | Bicep/ARM | Forskjell |
|---|---|---|
| `plan` | `az deployment sub what-if` | Ingen låst plan. Kan ha "støy" (falske endringer). |
| `apply` | `az deployment sub create` | **Incremental mode:** Fjerner du en ressurs fra koden, blir den *stående* i Azure. |
| state-fil | ingen | Azure er sannheten. Deployment Stacks gir sletting/drift-beskyttelse senere. |
| `validate` | `az bicep build`/`lint` (syntaks) + `az deployment sub validate` (preflight mot Azure) | Preflight fanger opptatte navn, policy-deny og kvote. |

---

## 1. Forutsetninger 🖥️ TERMINAL

```powershell
$PSVersionTable.PSVersion   # 7.3 eller nyere
az version                  # 2.60 eller nyere
az bicep install            # eller: az bicep upgrade
az bicep version
gh --version
gh auth status              # innlogget med konto som kan lage repo i org-en
git --version
```

Sett variablene du bruker gjennom hele økta:

```powershell
$SUB  = '<test-subscription-id>'
$ORG  = '<github-org-eller-bruker>'
$REPO = 'avd-iac'
$GH   = "$ORG/$REPO"          # case-sensitivt – må matche GitHub nøyaktig
```

**Krav:**

| Hva | Hvorfor |
|---|---|
| **Owner** (eller Contributor + User Access Administrator) på test-subscription. Aktiver PIM **nå**. | Custom role og rolletildelinger |
| **Admin** på GitHub-repoet | Environments, variables, rulesets |
| GitHub-plan: **Team/Enterprise** hvis repoet er **privat** i en org. Free støtter ikke environment-branch-policy og rulesets på private repoer. | Beskyttelse av `dev`. Alternativ for i kveld: offentlig testrepo, eller repo på personlig Pro-konto. |

✅ **SJEKK:** `az account show` viser riktig tenant, og `gh auth status` viser riktig konto.

---

## 2. Opprett repo 🖥️ TERMINAL

```powershell
cd ~/source        # eller der du har repoer
gh repo create $GH --private --clone --description "Bicep + GitHub Actions for AVD"
cd $REPO
git branch -M main
```

✅ **SJEKK:** `git remote -v` peker på `github.com/$GH`.

---

## 3. Lag filene 🤖 CLAUDE CODE

1. Lagre **denne fila** som `docs/runbook.md` i repoet.
2. Start Claude Code i repo-roten (`claude`).
3. Gi denne prompten:

```text
Les docs/runbook.md. Opprett alle filene i "Vedlegg A" med nøyaktig det innholdet
som står der, og med samme stier. Ikke endre innhold eller legg til filer.

Når filene er opprettet:
1. Kjør: az bicep lint --file main.bicep
2. Kjør: az bicep build --file main.bicep --stdout   (forkast output til null-device for din shell)
3. Kjør: az bicep build-params --file environments/dev.bicepparam --stdout   (samme)
4. Vis meg `git status` og en kort oppsummering.

Ikke kjør git commit, git push, az deployment create, az role, az identity eller gh-kommandoer.
```

4. Les gjennom det Claude Code har laget. Særlig `.github/workflows/deploy-bicep.yml` og `scripts/Setup-Oidc.ps1`.

✅ **SJEKK:** Alle tre Bicep-kommandoene er uten feil og varsler. `git status` viser 11 filer (10 fra vedlegget + `docs/runbook.md`).

> **Tips:** `CLAUDE.md` gir Claude Code kontekst og regler for resten av prosjektet, for eksempel at den skal spørre før den endrer Azure eller GitHub.

---

## 4. Lokal validering og what-if 🖥️ TERMINAL

Dette beviser at malen fungerer mot Azure **før** pipelinen blandes inn. Deploy lokalt ikke. La pipelinen gjøre første deploy, så rettighetene testes.

```powershell
az login --tenant <tenant-id>
az account set --subscription $SUB

# Preflight – fanger opptatt storage-navn, policy-deny, kvote
az deployment sub validate `
  --location norwayeast `
  --parameters environments/dev.bicepparam `
  --output table

# What-if – "terraform plan"
az deployment sub what-if `
  --location norwayeast `
  --parameters environments/dev.bicepparam
```

**Forventet what-if:**
```
+ Microsoft.Resources/resourceGroups/rg-avd-iac-dev
+ Microsoft.Storage/storageAccounts/stavdiacdev<13 tegn>
```

✅ **SJEKK:** Begge er grønne. Feiler noe her, er feilen i malen eller tenant-policy, ikke i pipelinen. Løs det før du går videre (se [Feilsøking](#feilsøking)).

---

## 5. Første push 🖥️ TERMINAL

```powershell
git add .
git commit -m "Initial Bicep-struktur med CI/CD-workflow"
git push -u origin main
```

🌐 Åpne `https://github.com/$GH/actions`.

**Forventet:**

| Jobb | Status | Hvorfor |
|---|---|---|
| Validate | ✅ | Trenger ikke Azure |
| What-if | ❌ | OIDC er ikke satt opp ennå. **Det er riktig.** |
| Deploy dev | ⏭️ | Hoppes over fordi What-if feilet |

---

## 6. OIDC-oppsett 🖥️ TERMINAL

Les gjennom `scripts/Setup-Oidc.ps1` først. Den er idempotent, så du kan kjøre den på nytt ved feil.

```powershell
./scripts/Setup-Oidc.ps1 -SubscriptionId $SUB -GitHubRepo $GH
```

**Det scriptet gjør, i rekkefølge:**

| # | Handling | Hvor |
|---|---|---|
| 1 | Oppretter `rg-avd-iac-identity` | Azure |
| 2 | Oppretter `id-gh-avd-iac-plan` og `id-gh-avd-iac-dev` (user-assigned MI) | Azure |
| 3 | Federated credential på hver: `repo:<org>@<orgId>/<repo>@<repoId>:environment:dev-plan` og `...:environment:dev` (ID-ene hentes fra `gh api`) | Azure |
| 4 | Custom role *Bicep What-If Operator - avd-iac* (`*/read`, `validate`, `whatIf`) | Azure |
| 5 | plan → custom role, dev → Contributor, begge på subscription | Azure |
| 6 | Environments `dev-plan` (åpen) og `dev` (kun `main`) | GitHub |
| 7 | Variables `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` (repo) og `AZURE_CLIENT_ID` (per env) | GitHub |
| 8 | Sjekker at repoet har null secrets | GitHub |

⏱️ **Vent 5 minutter** etterpå (RBAC-propagering).

✅ **SJEKK:**
```powershell
az identity federated-credential list --identity-name id-gh-avd-iac-dev -g rg-avd-iac-identity --query "[].subject" -o tsv
az role assignment list --scope "/subscriptions/$SUB" --query "[?principalType=='ServicePrincipal'].{role:roleDefinitionName, principal:principalName}" -o table
```

---

## 7. Kontroller GitHub-oppsett 🌐 GITHUB

**Settings → Environments**

| Environment | Skal ha |
|---|---|
| `dev-plan` | Variable `AZURE_CLIENT_ID` = clientId til `id-gh-avd-iac-plan`. Ingen deployment branch-begrensning. |
| `dev` | Variable `AZURE_CLIENT_ID` = clientId til `id-gh-avd-iac-dev`. **Deployment branches and tags → Selected branches → `main`** |

**Settings → Secrets and variables → Actions**
- **Variables**-fanen: `AZURE_TENANT_ID` og `AZURE_SUBSCRIPTION_ID` på repo-nivå
- **Secrets**-fanen: **tom**

**Settings → Actions → General → Workflow permissions**
- *Read repository contents* er ok. Workflowen gir selv `pull-requests: write` til What-if-jobben.
- Er innstillingen grået ut av org-policy, og PR-kommentaren feiler med 403: be org-admin tillate det, eller fjern kommentar-steget. What-if havner uansett i job summary.

**Valgfritt i kveld:** `dev` → *Required reviewers*. Hopp over hvis du tester alene, siden *Prevent self-review* blokkerer deg.

---

## 8. Første PR (plan) 🖥️ TERMINAL + 🌐 GITHUB

```powershell
git checkout -b test/first-pr
```

🤖 **CLAUDE CODE:**
```text
Legg til taggen Owner: 'torgeir' i tags-objektet i main.bicep.
Kjør lint og build etterpå. Ikke commit.
```

🖥️
```powershell
git diff
git commit -am "Test: legg til Owner-tag"
git push -u origin test/first-pr
gh pr create --fill --base main
gh pr checks --watch
```

🌐 Åpne PR-en.

✅ **SJEKK:**
- **Validate** ✅ og **What-if** ✅
- PR-en har en kommentar **"What-if (dev)"** som viser `+ Create` på RG og Storage Account
- **Deploy dev** vises ikke eller er hoppet over. Riktig, siden PR-er aldri deployer.

> **Merk:** PR-en viser *«This branch was successfully deployed»*. Det betyr **ikke** at noe er deployet til Azure. GitHub registrerer hver jobb med `environment:` som en «deployment». Her er det What-if-jobben mot `dev-plan`.

---

## 9. Branch-ruleset 🌐 GITHUB

Status checks kan først velges etter at de har kjørt én gang. Derfor gjøres dette etter steg 8.

**Settings → Rules → Rulesets → New ruleset → New branch ruleset**

| Felt | Verdi |
|---|---|
| Ruleset name | `protect-main` |
| Enforcement status | **Active** |
| Bypass list | **Tom.** Legger du til *Repository admin*, slipper du selv forbi alle regler (du er admin på eget repo). |
| Target branches | **Add target → Include default branch** |
| ☑ Restrict deletions | på |
| ☑ Require a pull request before merging | på. *Required approvals*: `0` alene, `1` hvis dere er to |
| ☑ Require status checks to pass | på. **Add checks:** `Validate` og `What-if` (velg navnet uten `Bicep CI/CD/`-prefiks, source *GitHub Actions*). ☑ *Require branches to be up to date* |
| ☑ Block force pushes | på |

**Create.**

✅ **SJEKK:** `git push origin main` direkte fra en lokal endring skal nå avvises.

```powershell
git checkout main
git commit --allow-empty -m "test: direkte push skal avvises"
git push origin main          # forventet: GH013 ... ! [remote rejected]
git reset --hard origin/main  # fjern den lokale test-commiten
```

Står det *«Bypassed rule violations»* og pushen går gjennom, er du på bypass-lista. Fjern den i rulesetet og test på nytt. Den tomme commiten som slapp gjennom, er ufarlig (ingen filer, paths-filteret trigger ingen kjøring) og kan bli liggende.

---

## 10. Merge og deploy 🌐 GITHUB + 🖥️ TERMINAL

🌐 Står det *«This branch is out-of-date with the base branch»* på PR-en (f.eks. etter testcommiten i steg 9), klikk **Update branch** og vent på grønne checks. Alternativt: `gh pr update-branch <branch>`.

🌐 På PR-en: **pila ▾ ved Merge pull request → Squash and merge → Confirm**, og deretter **Delete branch**.

🖥️
```powershell
git checkout main
git pull
gh run watch          # velg kjøringen fra push til main
```

**Forventet:** Validate ✅ → What-if ✅ → **Deploy dev** ✅

✅ **SJEKK:**
```powershell
az resource list -g rg-avd-iac-dev -o table
az group show -n rg-avd-iac-dev --query tags
az deployment sub list --query "[?starts_with(name,'deploy-')].{name:name, state:properties.provisioningState, ts:properties.timestamp}" -o table
```

Taggen `Owner: torgeir` skal finnes på RG-en.

---

## 11. Idempotens-test 🌐 GITHUB

**Actions → Bicep CI/CD → Run workflow → main → Run workflow**

Eller fra terminalen: `gh workflow run "Bicep CI/CD" --ref main` og `gh run watch`.

✅ **SJEKK:** What-if viser kun `= NoChange` (eventuelt `* Ignore`), og Deploy dev er grønn uten endringer. What-if-outputen ligger i kjøringens **Summary** under «What-if (dev)».

🎉 **Ferdig.** Kryss av sjekklisten øverst.

---

## Feilsøking

| Feilmelding / symptom | Årsak | Løsning |
|---|---|---|
| `AADSTS700213: No matching federated identity record found for presented assertion subject 'repo:X/Y:environment:dev-plan'` | Subject i FIC matcher ikke det GitHub sender. Org/repo er **case-sensitivt**. | Sammenlign med `az identity federated-credential list --identity-name id-gh-avd-iac-plan -g rg-avd-iac-identity --query "[].subject"`. Kjør `Setup-Oidc.ps1` på nytt med riktig `-GitHubRepo`. |
| `AADSTS700213 ... subject 'repo:X@12345/Y@67890:environment:...'` | GitHub sender subject med uforanderlige ID-er for eier og repo (beskytter mot at et slettet repo gjenopprettes med samme navn). FIC laget med `repo:X/Y:...` matcher ikke. | `Setup-Oidc.ps1` bygger subject fra `gh api repos/X/Y` og oppdaterer eksisterende FIC. Kjør scriptet på nytt. Eksakt subject står i `azure/login`-loggen under *subject claim*. |
| `AADSTS700213 ... subject 'repo:X/Y:pull_request'` eller `...:ref:refs/heads/...` | Jobben mangler `environment:` | Alle jobber som logger inn må ha `environment:` satt |
| `No subscriptions found for ...` i azure/login | RBAC er ikke propagert | Vent 5 minutter, *Re-run failed jobs* |
| Preflight/what-if: `AuthorizationFailed ... perform action '.../write'` på ressursene i malen | Standard `validation-level` (`Provider`) krever skrive-RBAC for alle ressurser i malen. Plan-identiteten er bevisst read-only. | Bruk `--validation-level ProviderNoRbac` på `validate` og `what-if` i Plan-jobben (allerede i workflowen). Da sjekkes kun lese-RBAC. **Ikke** legg write-actions i custom role. |
| What-if: `AuthorizationFailed ... does not have authorization to perform action 'X'` (ikke write) | Custom role mangler en lese-/validerings-action | Legg action `X` til i `Actions`-lista i `Setup-Oidc.ps1`, oppdater rollen (`az role definition update --role-definition "@fil.json"`), og noter den. Den må inn i AVD-bootstrapen senere. **Ikke** gi plan-identiteten Contributor. |
| Preflight: `StorageAccountAlreadyTaken` | Navnet er tatt globalt (svært usannsynlig med `uniqueString`) | Endre `workload` i `main.bicep` |
| Preflight/deploy: `RequestDisallowedByPolicy` | Tenant-policy (ALZ) nekter noe | Policy-navnet står i feilen. Tilpass modulen, eller be om unntak for test-sub. |
| Preflight feiler på nested deployment til RG som ikke finnes | Første kjøring, før RG-en finnes | Sjelden for subscription-scope. Hvis det skjer: fjern `Preflight-validering`-steget midlertidig, deploy én gang, og legg det tilbake. |
| **Deploy dev** står som *Waiting* | Required reviewers på `dev` | Godkjenn i Actions-kjøringen, eller fjern reviewers |
| **Deploy dev** feiler med *Branch "x" is not allowed to deploy to dev* | Kjørt fra annen branch enn `main` | Riktig oppførsel. Kjør fra `main`. |
| PR-kommentar: `Resource not accessible by integration` (403) | Org begrenser `GITHUB_TOKEN` | Se steg 7, eller slett kommentar-steget |
| PR blir stående på *Expected — Waiting for status to be reported* | Required check-navn matcher ikke jobbnavn | Navnene skal være eksakt `Validate` og `What-if` |
| `az role definition create`: *role with the same name already exists* | Custom role finnes i en annen subscription i tenanten | Endre `$whatIfRoleName` i scriptet |
| `git push`: *Bypassed rule violations* – push til `main` går gjennom | Du står på rulesetets bypass-liste | Fjern *Repository admin* fra Bypass list i `protect-main` |
| `git push -u origin <branch>`: *src refspec <branch> does not match any* | Branchen ble aldri laget (`git checkout -b` feilet/ble hoppet over), så commiten havnet på lokal `main` | `git branch <branch>` → `git reset --hard origin/main` → `git checkout <branch>` → push på nytt |
| Annotasjon: *Node.js 20 is deprecated* | Gamle major-versjoner av actions | Bruk `actions/checkout@v7` og `azure/login@v3` (Node 24) |
| Windows: `'length' is not recognized` eller `-o was unexpected at this time` | `az` er en batch-fil (`az.cmd`). PowerShell 7 sender `--query` uten anførselstegn når verdien ikke har mellomrom, og cmd.exe tolker da pipe **og parenteser** selv. | Unngå `\|` og `( )` i `--query`. Hent lista (`"[?name=='x'].name"`) og sjekk om resultatet er tomt i PowerShell (`if (-not $r)`). |

---

## Etter i kveld – neste steg

1. **`prod`-environment** med egen identitet, egen subscription, required reviewers og `environments/prod.bicepparam`.
2. **AVD-moduler:** bytt `storage-account.bicep` med `monitoring.bicep` og `network.bicep` fra `norva24-avd-iac.zip`. Behold workflow og identiteter som de er.
3. **Deployment Stacks** når flere ressurser er på plass. Det gir sletting av fjernede ressurser og deny settings.
4. **Opprydding av test** (når du vil): `az group delete -n rg-avd-iac-dev --yes`. Behold `rg-avd-iac-identity`.

---

## Vedlegg A – filer

Opprett nøyaktig disse filene (steg 3). Alle er bygget og lintet uten feil eller varsler (Bicep 0.48). Workflowen er sjekket med actionlint, og PowerShell-scriptet er syntakssjekket.

> **Merk (2026-10-14):** Vedlegget viser utgangspunktet. Filene i repoet er fasit. Etter første gjennomkjøring er disse rettet: `Setup-Oidc.ps1` (az.cmd-quoting og subject med ID-er), `deploy-bicep.yml` (`ProviderNoRbac` og action-versjoner for Node 24). Se [Feilsøking](#feilsøking).

### `CLAUDE.md`

```markdown
# avd-iac – kontekst for Claude Code

Bicep-prosjekt med GitHub Actions for NORVA24. Fundament for AVD per oppkjøpt selskap (én subscription per selskap).

## Konvensjoner
- `main.bicep` har `targetScope = 'subscription'` og oppretter selv resource groups. Ingen klikk-ops.
- Moduler i `modules/` tar `location` og `tags` som parametre. Ingen hardkodede navn – bruk `uniqueString()` der navn må være globalt unike.
- Parameterfiler: `environments/<env>.bicepparam`.
- API-versjoner: ikke eldre enn 730 dager (linteren varsler).
- Norsk i kommentarer og dokumentasjon, engelsk i kode og ressursnavn.

## Sikkerhet
- Ingen secrets i repoet eller i GitHub. Azure-innlogging kun via OIDC (federated credentials på managed identities).
- GitHub-verdier (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`) er *variables*, ikke secrets.
- `dev-plan`-identiteten kan kun lese og kjøre what-if. `dev`-identiteten har Contributor og kan kun brukes fra `main`.

## Arbeidsregler for Claude Code
- Kjør gjerne: `az bicep build`, `az bicep lint`, `az bicep build-params`, `az deployment sub what-if`, `az deployment sub validate`, `git status/diff`.
- **Spør før** du kjører: `az deployment sub create`, `az role ...`, `az identity ...`, `gh api -X PUT/POST`, `gh variable set`, `git push`, eller noe som endrer Azure eller GitHub.
- Etter hver endring i `.bicep`: kjør `az bicep lint` og `az bicep build --stdout` (send output til null-device – `/dev/null` i bash, `$null` i PowerShell).
```

### `.gitignore`

```gitignore
# Bicep build-output
main.json
modules/*.json
environments/*.json

# Lokale filer
*.local.bicepparam
*.local.json
.env

# Editor/OS
.vscode/*
!.vscode/extensions.json
.DS_Store
Thumbs.db
```

### `bicepconfig.json`

```json
{
  "analyzers": {
    "core": {
      "enabled": true,
      "rules": {
        "no-unused-params": { "level": "error" },
        "no-unused-vars": { "level": "error" },
        "no-hardcoded-env-urls": { "level": "error" },
        "secure-parameter-default": { "level": "error" },
        "outputs-should-not-contain-secrets": { "level": "error" },
        "use-recent-api-versions": { "level": "warning" }
      }
    }
  }
}
```

### `main.bicep`

```bicep
targetScope = 'subscription'

@description('Miljønavn. Styrer RG-navn, tags og storage-navn.')
@allowed(['dev', 'prod'])
param environment string

param location string = 'norwayeast'

@description('Kort prefiks for workload, inngår i ressursnavn.')
param workload string = 'avdiac'

var tags = {
  Workload: 'AVD'
  Environment: environment
  ManagedBy: 'Bicep'
  Repo: 'avd-iac'
}

resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-avd-iac-${environment}'
  location: location
  tags: tags
}

module storage 'modules/storage-account.bicep' = {
  name: 'storage-${environment}'
  scope: rg
  params: {
    namePrefix: 'st${workload}${environment}'
    location: location
    tags: tags
  }
}

output resourceGroupName string = rg.name
output storageAccountName string = storage.outputs.name
output storageAccountId string = storage.outputs.id
```

### `modules/storage-account.bicep`

```bicep
@description('Prefiks for navnet. Resten fylles med uniqueString – gir globalt unikt, deterministisk navn.')
@minLength(3)
param namePrefix string

param location string = resourceGroup().location
param tags object = {}

// Maks 24 tegn, kun små bokstaver og tall
var name = take('${toLower(namePrefix)}${uniqueString(resourceGroup().id)}', 24)

resource storage 'Microsoft.Storage/storageAccounts@2025-06-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Disabled'
  }
}

output name string = storage.name
output id string = storage.id
```

### `environments/dev.bicepparam`

```bicep
using '../main.bicep'

param environment = 'dev'
```

### `.github/workflows/deploy-bicep.yml`

````yaml
name: Bicep CI/CD

on:
  pull_request:
    branches: [main]
    # Ingen paths-filter på PR: required status checks blir ellers hengende som "pending"
  push:
    branches: [main]
    paths:
      - 'main.bicep'
      - 'modules/**'
      - 'environments/**'
      - 'bicepconfig.json'
      - '.github/workflows/deploy-bicep.yml'
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: bicep-${{ github.ref }}
  cancel-in-progress: false

env:
  LOCATION: norwayeast
  PARAMS: environments/dev.bicepparam

jobs:
  validate:
    name: Validate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Bicep lint, build og build-params
        run: |
          az bicep install
          az bicep lint --file main.bicep
          az bicep build --file main.bicep --stdout > /dev/null
          az bicep build-params --file "$PARAMS" --stdout > /dev/null

  plan:
    name: What-if
    needs: validate
    runs-on: ubuntu-latest
    environment: dev-plan          # read-only identitet
    permissions:
      contents: read
      id-token: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v4

      - uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - name: Preflight-validering
        run: |
          az deployment sub validate \
            --name "plan-$GITHUB_RUN_ID" \
            --location "$LOCATION" \
            --parameters "$PARAMS" \
            --output none

      - name: What-if
        run: |
          set -o pipefail
          az deployment sub what-if \
            --name "plan-$GITHUB_RUN_ID" \
            --location "$LOCATION" \
            --parameters "$PARAMS" \
            2>&1 | sed -r 's/\x1B\[[0-9;]*[mK]//g' | tee whatif.txt
          { echo '## What-if (dev)'; echo '```'; cat whatif.txt; echo '```'; } >> "$GITHUB_STEP_SUMMARY"

      - name: What-if som PR-kommentar
        if: github.event_name == 'pull_request'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          { echo '### What-if (dev)'; echo '```'; head -c 60000 whatif.txt; echo '```'; } > comment.md
          gh pr comment "${{ github.event.pull_request.number }}" --body-file comment.md

  deploy:
    name: Deploy dev
    needs: plan
    if: github.ref == 'refs/heads/main' && github.event_name != 'pull_request'
    runs-on: ubuntu-latest
    environment: dev               # kun main, Contributor-identitet
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: actions/checkout@v4

      - uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - name: Deploy
        run: |
          az deployment sub create \
            --name "deploy-$GITHUB_RUN_ID" \
            --location "$LOCATION" \
            --parameters "$PARAMS" \
            --query properties.outputs -o json
````

### `scripts/Setup-Oidc.ps1`

```powershell
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
```

### `README.md`

````markdown
# avd-iac

Bicep + GitHub Actions for Azure-infrastruktur. Fundament for AVD-plattformen til NORVA24.

## Flyt

| Hendelse | Jobber | Identitet |
|---|---|---|
| Pull request mot `main` | Validate → What-if (kommentar på PR) | `id-gh-avd-iac-plan` (kun les + what-if) |
| Merge/push til `main` | Validate → What-if → Deploy | `id-gh-avd-iac-dev` (Contributor, kun fra `main`) |

Innlogging skjer via OIDC (federated credentials). Det finnes ingen secrets i repoet eller i GitHub.

## Lokalt

```powershell
az bicep lint --file main.bicep
az deployment sub what-if --location norwayeast --parameters environments/dev.bicepparam
```

## Struktur

```
main.bicep                     # targetScope = subscription, oppretter RG
modules/storage-account.bicep  # testressurs
environments/dev.bicepparam
bicepconfig.json               # linter-regler
scripts/Setup-Oidc.ps1         # én-gangs OIDC-oppsett (idempotent)
.github/workflows/deploy-bicep.yml
```
````

### `.vscode/extensions.json`

```json
{ "recommendations": ["ms-azuretools.vscode-bicep", "github.vscode-github-actions", "ms-vscode.powershell"] }
```

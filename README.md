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

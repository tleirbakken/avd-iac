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

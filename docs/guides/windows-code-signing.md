# Windows code signing for ca-bootstrap

The release workflow (`.github/workflows/release.yml`) Authenticode-signs the
two Windows binaries (`windows/amd64`, `windows/arm64`) before publishing. This
removes the SmartScreen **"Windows protected your PC — unknown publisher"**
warning that unsigned binaries trigger on a fresh laptop.

Signing is **optional and gated**: if the signing secret isn't configured, the
release still builds and publishes, just unsigned (the workflow emits a warning).
So you can cut releases today and turn signing on the moment the cert lands.

---

## TL;DR — what the workflow expects

Two GitHub Actions **secrets** on this repo (or its environment):

| Secret | What it is |
| --- | --- |
| `WINDOWS_CERT_BASE64` | Your code-signing certificate **+ private key**, as a password-protected `.pfx`, base64-encoded to a single line. |
| `WINDOWS_CERT_PASSWORD` | The password protecting that `.pfx`. |

The `Sign Windows binary` step decodes the PFX to a temp file, runs `signtool
sign … /fd SHA256 /tr http://timestamp.digicert.com /td SHA256`, verifies with
`signtool verify /pa`, then deletes the PFX.

---

## Step 1 — Decide which certificate

> **Read this first — it determines whether the PFX path below even works.**

Code-signing certificates come in two grades:

- **OV (Organization Validation)** — cheaper, ~1–3 day issuance. SmartScreen
  reputation is *earned over time / download volume*; early downloads may still
  warn until reputation accrues.
- **EV (Extended Validation)** — pricier, stricter vetting. Gets **immediate**
  SmartScreen reputation (no warning from the first download). Best for a
  user-facing bootstrap tool.

**Important industry change (since June 2023):** per CA/Browser Forum rules,
both OV and EV code-signing private keys must be generated on **FIPS 140-2
hardware** — a USB token or a cloud HSM. That means most newly-issued certs
**cannot be exported to a `.pfx`**, so the `WINDOWS_CERT_BASE64` path below only
applies to:

- a certificate issued **before** that rule and still file-exportable, **or**
- an **internal/self-signed** cert (fine for testing the pipeline, but it won't
  clear SmartScreen on other machines), **or**
- a provider that offers **cloud-based signing** (see [Step 5, cloud
  alternative](#step-5--alternative-cloud-signing-recommended-for-production)).

If you're buying a brand-new EV/OV cert for production, **skip to Step 5** — the
cloud path is almost certainly what you need. Use the PFX path (Steps 2–4) for a
self-signed test run or a legacy exportable cert.

Buy from a recognized CA (DigiCert, Sectigo, SSL.com, GlobalSign). Issue it to
**ChannelAssist Inc.** — the publisher name users will see.

---

## Step 2 — Get the certificate into a `.pfx`

If your CA gave you a `.pfx`/`.p12` directly, you already have it — note the
password and go to Step 3.

If the cert is installed in your Windows certificate store (and is marked
exportable):

```powershell
# List your code-signing certs to find the thumbprint:
Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Format-List Subject, Thumbprint, NotAfter

# Export it (cert + private key) to a password-protected PFX:
$pw = Read-Host -AsSecureString "PFX password"
Export-PfxCertificate -Cert Cert:\CurrentUser\My\<THUMBPRINT> `
  -FilePath .\ca-bootstrap-codesign.pfx -Password $pw
```

### (Test only) generate a self-signed cert to exercise the pipeline

This proves the workflow signs and verifies end-to-end. It will **not** satisfy
SmartScreen on other machines — it's for validating the plumbing only.

```powershell
$cert = New-SelfSignedCertificate -Type CodeSigningCert `
  -Subject "CN=ChannelAssist Inc. (TEST — do not ship)" `
  -CertStoreLocation Cert:\CurrentUser\My `
  -KeyExportPolicy Exportable -KeyUsage DigitalSignature
$pw = ConvertTo-SecureString "test-password" -AsPlainText -Force
Export-PfxCertificate -Cert "Cert:\CurrentUser\My\$($cert.Thumbprint)" `
  -FilePath .\test-codesign.pfx -Password $pw
```

---

## Step 3 — Base64-encode the PFX

GitHub secrets are text, so encode the binary `.pfx` to one base64 line:

```powershell
# Windows (PowerShell)
[Convert]::ToBase64String([IO.File]::ReadAllBytes(".\ca-bootstrap-codesign.pfx")) |
  Set-Content -NoNewline .\cert.b64
```

```bash
# macOS / Linux
base64 -i ca-bootstrap-codesign.pfx | tr -d '\n' > cert.b64
```

`cert.b64` now holds the value for the `WINDOWS_CERT_BASE64` secret.

---

## Step 4 — Add the GitHub secrets

You need **admin** on `ChannelAssist/ca-bootstrap`.

**UI:** Repo → *Settings* → *Secrets and variables* → *Actions* → *New
repository secret*. Add:
- `WINDOWS_CERT_BASE64` → paste the contents of `cert.b64`
- `WINDOWS_CERT_PASSWORD` → the PFX password

**CLI** (don't leave the secret on disk or in shell history afterward):

```bash
gh secret set WINDOWS_CERT_BASE64 --repo ChannelAssist/ca-bootstrap < cert.b64
gh secret set WINDOWS_CERT_PASSWORD --repo ChannelAssist/ca-bootstrap   # prompts, no echo
```

Then shred the local copies: `rm cert.b64 *.pfx`.

> **Tighter blast radius (recommended):** put these on a GitHub **Environment**
> named `release` (with required reviewers) instead of plain repo secrets, and
> add `environment: release` to the `build` job. Then signing can only happen on
> an approved release run.

That's it — the next `vX.Y.Z` tag push signs automatically.

---

## Step 5 — Alternative: cloud signing (recommended for production)

For a modern token-bound EV/OV cert, you don't hold a `.pfx` at all — the key
lives in an HSM and you sign via the provider's API/action. Cleanest fit for a
Microsoft-stack org:

**Azure Trusted Signing** (~$10/month, Microsoft-operated HSM). Replace the
`Sign Windows binary` step with:

```yaml
      - name: Sign Windows binary (Azure Trusted Signing)
        if: matrix.goos == 'windows'
        uses: azure/trusted-signing-action@v0
        with:
          azure-tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          azure-client-id: ${{ secrets.AZURE_CLIENT_ID }}
          azure-client-secret: ${{ secrets.AZURE_CLIENT_SECRET }}
          endpoint: https://eus.codesigning.azure.net/
          trusted-signing-account-name: <account>
          certificate-profile-name: <profile>
          files-folder: ${{ github.workspace }}
          files-folder-filter: exe
```

DigiCert **KeyLocker** and SSL.com **eSigner** offer equivalent GitHub Actions.
If you go this route, delete the PFX-based step and the two `WINDOWS_CERT_*`
secrets become unused.

---

## Verifying a signed release

On a Windows machine, after downloading the released `.exe`:

```powershell
Get-AuthenticodeSignature .\ca-bootstrap_<tag>_windows_amd64.exe |
  Format-List Status, SignerCertificate
# Status should be 'Valid'; SignerCertificate subject should be ChannelAssist Inc.
```

Right-click → *Properties* → *Digital Signatures* tab also shows the signer and
timestamp.

---

## Security notes

- **Never commit** the `.pfx`, its base64, or the password. `.gitignore` already
  ignores `/dist/`, but keep certs out of the repo tree entirely.
- The workflow writes the PFX only to `$RUNNER_TEMP` and deletes it after
  signing; secrets are masked in logs by Actions.
- Rotate the cert before expiry (`NotAfter`); the **timestamp** countersignature
  (`/tr`) keeps already-signed binaries valid after the cert expires.
- Prefer the `release` **Environment** + required reviewers so a compromised PR
  can't reach the signing secret.

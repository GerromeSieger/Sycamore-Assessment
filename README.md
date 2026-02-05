# Sycamore DevOps Assessment - Secure CI/CD Pipeline

This repository demonstrates a secure CI/CD pipeline with vulnerability scanning using GitHub Actions and Trivy.

## Repository Structure

```
.
├── README.md                    # This file
├── .github/workflows/main.yml   # GitHub Actions workflow
├── Dockerfile                   # Secure Dockerfile (Node 22 Alpine)
├── Dockerfile.vulnerable        # Vulnerable Dockerfile (Node 14 - for demonstration)
├── index.js                     # Application source
├── package.json                 # Dependencies
├── .dockerignore                # Docker ignore rules
└── .gitignore                   # Git ignore rules
```

---

## Pipeline Overview

The CI/CD pipeline builds and scans two Docker images to demonstrate security gate functionality:

| Image | Base | Scan Threshold | Expected Result |
|-------|------|----------------|-----------------|
| Secure | `node:22-alpine` | CRITICAL only | **PASS** |
| Vulnerable | `node:14-alpine` | HIGH + CRITICAL | **FAIL** |

### Workflow Jobs

1. **scan-vulnerable**: Builds and scans `Dockerfile.vulnerable`
   - Uses `node:14-alpine` (EOL with known CVEs)
   - Scans for HIGH and CRITICAL vulnerabilities
   - Expected to fail (demonstrates security gate blocking vulnerable images)
   - Has `continue-on-error: true` so workflow continues

2. **build-scan-push**: Builds, scans, and pushes the secure image
   - Uses `node:22-alpine` with updated packages
   - Scans for CRITICAL vulnerabilities only
   - Pushes to GitHub Container Registry on success

---

## Dockerfile Comparison

### Secure Dockerfile

| Practice | Implementation | Why |
|----------|----------------|-----|
| Latest base image | `node:22-alpine` | Newest security patches |
| Package updates | `apk update && apk upgrade` | Patches OS vulnerabilities |
| Non-root user | `USER nodejs` | Limits container escape impact |
| Production deps only | `npm install --omit=dev` | Smaller attack surface |
| Health check | `HEALTHCHECK` instruction | Container orchestrator awareness |

### Vulnerable Dockerfile

| Anti-Pattern | Implementation | Risk |
|--------------|----------------|------|
| Old base image | `node:14-alpine` | EOL, known CRITICAL CVEs |
| Runs as root | No `USER` directive | Full container access if compromised |
| All dependencies | `npm install` | Dev dependencies in production |
| No health check | Missing `HEALTHCHECK` | No liveness monitoring |

---

## Security Scanning Configuration

```yaml
# Vulnerable image - strict scanning
severity: 'HIGH,CRITICAL'
exit-code: '1'
ignore-unfixed: true

# Secure image - CRITICAL only
severity: 'CRITICAL'
exit-code: '1'
ignore-unfixed: true
```

**Rationale:**
- `ignore-unfixed: true` - Don't fail on vulnerabilities without available patches
- Different severity thresholds demonstrate that even a "secure" image may have some HIGH vulnerabilities, but should never have unfixed CRITICAL ones
- SARIF output uploads results to GitHub Security tab for visibility

---

## Local Testing

```bash
# Build the secure image
docker build -t sycamore-api:secure -f Dockerfile .

# Build the vulnerable image
docker build -t sycamore-api:vulnerable -f Dockerfile.vulnerable .

# Scan with Trivy locally
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy image --severity CRITICAL sycamore-api:secure

docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy image --severity HIGH,CRITICAL sycamore-api:vulnerable

# Run the application
docker run -p 3000:3000 sycamore-api:secure
curl http://localhost:3000/
```

---

## Why Trivy?

| Aspect | Trivy | Alternatives |
|--------|-------|--------------|
| Cost | Free, open-source | Snyk/others have limited free tiers |
| Setup | Single GitHub Action, no account | Often requires API tokens |
| Speed | Fast, runs locally | Some require API calls |
| Coverage | OS + Library + IaC + Secrets | Often limited scope |
| GitHub Integration | Native SARIF support | Varies |

---

## Pipeline Results

After running the workflow, you should see:

- **scan-vulnerable job**: Fails with HIGH/CRITICAL vulnerabilities found in `node:14-alpine`
- **build-scan-push job**: Passes and pushes the secure image to `ghcr.io/<owner>/sycamore-assessment:latest`

Scan reports are uploaded as artifacts and retained for 30 days.

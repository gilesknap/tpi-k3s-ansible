# Grafana OAuth credentials

This directory contains the SealedSecret for Grafana's native GitHub OAuth login.

## Create the secret

1. Create a GitHub OAuth App at https://github.com/settings/developers
   - Homepage URL: `https://grafana.<your-domain>`
   - Callback URL: `https://grafana.<your-domain>/login/generic_oauth`

2. Create and seal the secret:
   ```bash
   kubectl create secret generic grafana-oauth \
     --namespace monitoring \
     --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_ID=YOUR_GITHUB_CLIENT_ID \
     --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=YOUR_GITHUB_CLIENT_SECRET \
     --dry-run=client -o yaml | \
   kubeseal --controller-name sealed-secrets --controller-namespace kube-system -o yaml > \
     grafana-oauth-secret.yaml
   ```

3. Commit and push the SealedSecret file.

Note: The secret keys are injected as environment variables into the Grafana pod
via `envFromSecrets`. The `grafana.ini` config references them as
`$__env{GF_AUTH_GENERIC_OAUTH_CLIENT_ID}` and
`$__env{GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET}`.

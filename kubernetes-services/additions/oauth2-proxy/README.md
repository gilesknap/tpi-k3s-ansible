# oauth2-proxy credentials

This directory should contain a SealedSecret with your OAuth provider credentials.

## Create the secret

1. Create a GitHub OAuth App at https://github.com/settings/developers
   - Homepage URL: `https://oauth2.<your-domain>`
   - Callback URL: `https://oauth2.<your-domain>/oauth2/callback`

2. Generate a cookie secret:
   ```bash
   python3 -c 'import os,base64; print(base64.b64encode(os.urandom(32)).decode())'
   ```

3. Create and seal the secret:
   ```bash
   kubectl create secret generic oauth2-proxy-credentials \
     --namespace oauth2-proxy \
     --from-literal=client-id=YOUR_GITHUB_CLIENT_ID \
     --from-literal=client-secret=YOUR_GITHUB_CLIENT_SECRET \
     --from-literal=cookie-secret=YOUR_GENERATED_COOKIE_SECRET \
     --dry-run=client -o yaml | \
   kubeseal --controller-name sealed-secrets --controller-namespace kube-system -o yaml > \
     oauth2-proxy-secret.yaml
   ```

4. Commit and push the SealedSecret file.

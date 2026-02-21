### Viewing the Echo Test Service

The echo service at **https://echo.gkcluster.org** returns compact JSON by default. To view it pretty-printed in your browser, install the [JSON Formatter](https://chromewebstore.google.com/detail/json-formatter/bcjindcccaagfpapjjmafapmmgkkhgoa) Chrome extension — it automatically pretty-prints and syntax-highlights JSON responses.

---

### Uninstalling longhorn

```bash
# change to true
kubectl -n longhorn-system edit settings.longhorn.io deleting-confirmation-flag
helm uninstall -n longhorn-system longhorn
```

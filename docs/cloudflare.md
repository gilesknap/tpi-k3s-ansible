# How to set up Cloudflare Origin Certificate in a namespace
This will need doing for any public facing service that you want to secure with a Cloudflare Origin Certificate.

See below to create .cloudflare folder contents

- from outside the devcontainer
- cd ~/.cloudflare
- podman ps # and note the name of the devcontainer e.g. compassionate_kare
- podman cp compassionate_kare:'/root/.kube/config' ~/.kube
- kubectl create secret tls tls-cloudflare --cert=cert.crt --key=private.key --namespace default
- done.

UPDATE: it looks like a let's encrypt cert also works as an origin certificate so the above is no longer necessary!


# Cloudflare Certificate Management

- buy a DNS name (gkcluster.org)
- create an A record with echo.gkcluster.org pointing to your server's IP
  - idea being that I don't want to route everything as I'll want local only for dashboard.gkcluster.org etc.
  - BUT is this secure? can someone still go direct to the IP, bypass the DNS and add a host header?
  - my router is set to only allow 443,80 to the server.
  - cloudflare does not expose my IP as it is proxied.
  - Do I also need firewalld to block traffic not proxied through cloudflare? Or is that overkill?
- probably need to auto update that IP with https://dnsomatic.com/
- Go to TLS/SSL -> Origin Server -> Create Certificate -> Select the domain -> Create Certificate
- Download the certificate and key
- kubectl create secret tls tls-cloudflare --cert=cert.crt --key=private.key --namespace default
  - for each namespace, you need to create a secret

- ADD CA ROOT? https://askubuntu.com/a/94861/931676 not sure if this is needed? NO the problem is that the Origin Certificate is only designed for the connection between Cloudflare and the origin server. It is not designed to be used as a client certificate for the connection between the client and my server. So its no use for internal connections.
- may be useful? https://www.digitalocean.com/community/tutorials/how-to-host-a-website-using-cloudflare-and-nginx-on-ubuntu-18-04
- If thinking of exposing dash then see this https://blog.heptio.com/on-securing-the-kubernetes-dashboard-16b09b1b7aca
- and this https://vmwire.com/2022/02/07/running-kubernetes-dashboard-with-signed-certificates/

ingress then looks like this (for the echo service and subdomain):
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echo-ingress
  namespace: default
  annotations:
    kubernetes.io/tls-acme: "true"
spec:
  ingressClassName: nginx
  # ADD TLS #2
  tls:
    # Replace the domain below with your domain accordingly.
    - hosts:
        - echo.gkcluster.org
      secretName: tls-cloudflare
  rules:
    # Replace the domain below with your domain accordingly.
    - host: echo.gkcluster.org
      http:
        paths:
          - pathType: Prefix
            path: /
            backend:
              service:
                name: echo-service
                port:
                  number: 80
```
## notes

This can get to the echo service - try to use commands like this to test the theory that attackers can bypass the DNS and go direct to the IP:
```bash
curl "Host: echo.gkcluster.org" https://echo.gkcluster.org
```

# this fails which I think is good?
```bash
# curl --insecure "Host: echo.gkcluster.org" https://90.243.208.136                                                                [9:59:09]
curl: (3) URL using bad/illegal format or missing URL
<html>
<head><title>404 Not Found</title></head>
<body>
<center><h1>404 Not Found</h1></center>
<hr><center>nginx</center>
</body>
</html>
```

NOTE: an ingress made by the dashboard helm chart looks like this:
```yaml
Name:             kubernetes-dashboard
Labels:           app.kubernetes.io/instance=kubernetes-dashboard
                  app.kubernetes.io/managed-by=Helm
                  app.kubernetes.io/part-of=kubernetes-dashboard
                  helm.sh/chart=kubernetes-dashboard-7.10.0
Namespace:        kubernetes-dashboard
Address:
Ingress Class:    nginx
Default backend:  <default>
TLS:
  kubernetes-dashboard-certs terminates gkcluster.org,localhost
Rules:
  Host           Path  Backends
  ----           ----  --------
  gkcluster.org
                 /dashboard(/|$)(.*)   kubernetes-dashboard-kong-proxy:443 (10.42.2.54:8443)
  localhost
                 /dashboard(/|$)(.*)   kubernetes-dashboard-kong-proxy:443 (10.42.2.54:8443)
Annotations:     cert-manager.io/issuer: selfsigned
                 meta.helm.sh/release-name: kubernetes-dashboard
                 meta.helm.sh/release-namespace: kubernetes-dashboard
                 nginx.ingress.kubernetes.io/backend-protocol: HTTPS
                 nginx.ingress.kubernetes.io/rewrite-target: /$2
                 nginx.ingress.kubernetes.io/ssl-passthrough: true
                 nginx.ingress.kubernetes.io/ssl-redirect: true
Events:
  Type    Reason             Age   From                       Message
  ----    ------             ----  ----                       -------
  Normal  Sync               3s    nginx-ingress-controller   Scheduled for sync
  Normal  CreateCertificate  3s    cert-manager-ingress-shim  Successfully created Certificate "kubernetes-dashboard-certs"
  ```
and in yaml
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    cert-manager.io/issuer: selfsigned
    meta.helm.sh/release-name: kubernetes-dashboard
    meta.helm.sh/release-namespace: kubernetes-dashboard
    nginx.ingress.kubernetes.io/backend-protocol: HTTPS
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
  creationTimestamp: "2025-01-04T14:34:10Z"
  generation: 1
  labels:
    app.kubernetes.io/instance: kubernetes-dashboard
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: kubernetes-dashboard
    helm.sh/chart: kubernetes-dashboard-7.10.0
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
  resourceVersion: "140247"
  uid: c867ba91-fcb0-4d4d-9bfa-15976fb5a3a0
spec:
  ingressClassName: nginx
  rules:
  - host: gkcluster.org
    http:
      paths:
      - backend:
          service:
            name: kubernetes-dashboard-kong-proxy
            port:
              number: 443
        path: /dashboard(/|$)(.*)
        pathType: ImplementationSpecific
  - host: localhost
    http:
      paths:
      - backend:
          service:
            name: kubernetes-dashboard-kong-proxy
            port:
              number: 443
        path: /dashboard(/|$)(.*)
        pathType: ImplementationSpecific
  tls:
  - hosts:
    - gkcluster.org
    - localhost
    secretName: kubernetes-dashboard-certs
status:
  loadBalancer:
    ingress:
    - ip: 192.168.1.81
    - ip: 192.168.1.82
    - ip: 192.168.1.83
    - ip: 192.168.1.91
    - ip: 192.168.1.92
 ```
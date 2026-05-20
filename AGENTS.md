# AGENTS.md

Guidance for AI agents working in this GitOps repo.

## Purpose

This repo declaratively manages all workloads on a single-node k3s cluster at `danilenko.io`. ArgoCD reconciles cluster state from `main`.

## Stack

| Concern        | Tool                     | Notes                                                                      |
|----------------|--------------------------|----------------------------------------------------------------------------|
| Cluster        | k3s                      | Single node, public IP `173.249.33.165`                                    |
| GitOps         | ArgoCD                   | App-of-apps pattern, see `argocd/app-of-apps.yaml`                         |
| Ingress        | **Traefik**              | k3s built-in. Class name = `traefik`. NOT nginx.                           |
| TLS            | cert-manager             | ClusterIssuer `letsencrypt-prod` (HTTP-01 via traefik)                     |
| Secrets        | Sealed Secrets (Bitnami) | Controller in `kube-system`. Commit sealed YAML to git.                    |
| HTTPS redirect | Traefik Middleware       | `default-redirect-https@kubernetescrd` (see `redirect-http-to-https.yaml`) |
| Storage        | local-path (k3s default) | Use `local-path-retain` StorageClass for PVCs that must survive deletion   |
| DNS            | External (provider)      | All `*.danilenko.io` -> `173.249.33.165`                                   |

## Repo layout

```
<app-name>/
  Chart.yaml          # Helm chart, version 1.0.0, appVersion = upstream image tag
  values.yaml         # App config
  templates/          # Manifests (deployment, service, ingress, sealed-secret)
argocd/
  app-of-apps.yaml    # Root ArgoCD Application watching applications/
  applications/<app>.yaml  # One Application per app, targets path=<app>
cluster-issuer.yaml          # cert-manager ClusterIssuer
redirect-http-to-https.yaml  # Traefik Middleware (cluster-wide)
```

Each app = self-contained Helm chart. Add new app: create dir + chart + register in `argocd/applications/`.

## Conventions

### Ingress

Always Traefik. Use this annotation set (copy from `londo/templates/ingress.yaml`):

```yaml
annotations:
  cert-manager.io/cluster-issuer: letsencrypt-prod
  traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
  traefik.ingress.kubernetes.io/router.middlewares: default-redirect-https@kubernetescrd
```

When wrapping an upstream Helm chart that exposes ingress directly (e.g. `loki-stack/grafana`), set `ingressClassName: traefik` in the subchart values — NOT `nginx` (chart defaults often assume nginx). Also pass the full annotation set, otherwise the ingress binds only to the `web` entrypoint (HTTP, port 80) and HTTPS will not work:

```yaml
annotations:
  cert-manager.io/cluster-issuer: letsencrypt-prod
  traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
  traefik.ingress.kubernetes.io/router.middlewares: default-redirect-https@kubernetescrd
```

### Sealed Secrets

- Generate plaintext secret w/ `kubectl create secret ... --dry-run=client -o yaml`
- Pipe to `kubeseal --controller-namespace kube-system -o yaml`
- Commit the `SealedSecret` manifest under `<app>/templates/sealed-secret.yaml`
- Reference by `secretName` value (see existing apps for pattern)
- For subcharts: key names in the secret must match what subchart expects (e.g. Grafana wants `admin-user`/`admin-password`)

### Storage

- Default `local-path` deletes PV when PVC deleted
- For data that must persist across `helm uninstall` / re-sync: use `storageClassName: local-path-retain`
- Existing PVCs cannot change StorageClass — only set for new ones

### ArgoCD Application template

Copy from `argocd/applications/calibre-web.yaml`. Always include:

```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - CreateNamespace=true
    - PrunePropagationPolicy=orphan
```

Add `ServerSideApply=true` for charts with large CRDs/annotations (e.g. loki-stack).

### Subchart dependencies

When wrapping upstream charts via `Chart.yaml` `dependencies:`, ArgoCD runs `helm dependency build` automatically on sync. Do NOT need to commit `charts/` tarballs or run `helm dependency update` locally unless rendering offline.

### Versioning

- Chart `version`: `1.0.0` (rarely bumped, internal)
- `appVersion`: matches upstream image tag, used as default for `image.tag` when value empty
- For apps with custom-built images (e.g. `londo`), commits in this repo named `Deploy <name>:<version>` -- update `appVersion` + corresponding values

## When adding a new app

1. Create `<app>/Chart.yaml`, `values.yaml`, `templates/`
2. Reuse ingress template from an existing app, swap host + service name
3. If secrets needed: seal them, commit `templates/sealed-secret.yaml`
4. Create `argocd/applications/<app>.yaml`
5. Add DNS `A` record `<app>.danilenko.io -> 173.249.33.165` externally
6. push to branch → create PR → ArgoCD picks up via app-of-apps

## Antipatterns / gotchas

- **Do not** assume `ingressClassName: nginx`. This cluster has only `traefik`.
- **Do not** commit plaintext `Secret` manifests. Always seal.
- **Do not** run `helm install`/`kubectl apply` manually for tracked apps -- ArgoCD will revert. Edit values, commit, push.
- **Do not** delete a namespace to "clean up" -- `selfHeal` plus `local-path-retain` may leave orphaned PVs.
- Traefik ingress `ADDRESS` empty = wrong `ingressClassName` (likely set to `nginx`).
- Grafana/Prometheus/Loki upstream charts default to nginx-style ingress -- override.
- Helm-rendered `StatefulSet.spec.volumeClaimTemplates` always shows OutOfSync in ArgoCD because k8s strips `apiVersion`/`kind` from the stored template. Fix via `ignoreDifferences` on the Application (see `argocd/applications/loki.yaml`).

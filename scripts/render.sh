#!/usr/bin/env bash
#
# Renderiza a manifiestos planos todo lo que este repo aplicaría al clúster.
#
#   Uso:  ./scripts/render.sh <directorio-salida>
#
# Existe para una razón concreta: el PR enseña Kustomize y una versión de chart,
# no los objetos que acaban en el clúster. Un bump de `targetRevision: 10.2.2`
# a 10.3.0 es un diff de una línea en el PR y puede ser cualquier cosa en el
# apiserver —incluido un cambio sobre el propio controller que ejecuta el sync.
#
# El job `render-diff` de .github/workflows/validar.yml ejecuta esto sobre la
# rama base y sobre la rama del PR y publica la diferencia. Es el patrón de "rendered manifests"
# hecho a mano; el día que el source hydrator de Argo CD sea GA, esto sobra.
#
set -euo pipefail

SALIDA="${1:?Uso: $0 <directorio-salida>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if command -v kustomize >/dev/null 2>&1; then
  KUSTOMIZE=(kustomize build)
else
  KUSTOMIZE=(kubectl kustomize)
fi

mkdir -p "${SALIDA}"

# --- 1. El plano de control: lo que reconcilia la root-app ------------------
# Incluye los AppProject, las Application de cada workload y la Application del
# motor.
"${KUSTOMIZE[@]}" "${REPO_ROOT}/overlays/prod" > "${SALIDA}/01-plano-de-control.yaml"

# --- 2. El motor: el chart de Argo CD con los valores de este repo ----------
# La Application de overlays/prod/argo-cd solo declara "chart X versión Y con
# estos valores". Lo que realmente se aplica es esto, y es donde se ve si un
# bump de versión toca el controller, el RBAC o los CRDs.
CHART_VERSION="$(
  awk '/chart: argo-cd/ {f=1} f && /targetRevision:/ {print $2; exit}' \
    "${REPO_ROOT}/overlays/prod/argo-cd.yaml"
)"
[[ -n "${CHART_VERSION}" ]] || { echo "No se pudo leer la versión del chart" >&2; exit 1; }
echo "==> chart argo-cd ${CHART_VERSION}"

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null 2>&1

helm template argo-cd argo/argo-cd \
  --version "${CHART_VERSION}" \
  --namespace argocd \
  --include-crds \
  --values "${REPO_ROOT}/config/argo-cd/values.yaml" \
  > "${SALIDA}/02-motor-argocd.yaml"

echo "==> Renderizado en ${SALIDA}"
wc -l "${SALIDA}"/*.yaml

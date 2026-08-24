#!/usr/bin/env bash
#
# Arranque del motor GitOps en un clúster desde cero.
#
# Es el único procedimiento imperativo del proyecto y se ejecuta UNA vez en la
# vida del clúster. A partir de la fase 3, todo cambio es un Pull Request.
#
#   Uso:  ./scripts/install.sh
#
#   Variables opcionales (si no se dan, se piden por consola):
#     GIT_USER    usuario de la credencial de lectura del repo
#     GIT_TOKEN   la credencial (deploy token, deploy key o PAT de solo lectura)
#
# Idempotente: se puede reejecutar sin romper nada.
#
set -euo pipefail

CHART_VERSION="10.2.2"   # -> Argo CD v3.4.6. Debe coincidir con
                         #    overlays/prod/argo-cd.yaml
NAMESPACE="argocd"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Una credencial por repo. El arranque solo necesita UNA: la del repo de
# plataforma, que es el que lee la root-app. La de cada workload se añade
# después con `scripts/credenciales.sh anadir`, cuando ese workload existe.
#
# Debe coincidir con el repoURL de bootstrap/root-app.yaml; lo
# comprueba scripts/validar-coherencia.py.
PLATFORM_REPO="https://github.com/teo-devops/Argo-cd-Labs.git"
PLATFORM_SECRET="repo-argo-cd"

echo "==> Contexto de kubectl: $(kubectl config current-context)"
read -rp "    ¿Continuar sobre este clúster? [y/N] " ok
[[ "$ok" == "y" || "$ok" == "Y" ]] || { echo "Abortado."; exit 1; }

# --- Fase 0: el namespace y la credencial del repo de plataforma ------------
# Este Secret NO puede estar en Git y no es un olvido: Argo CD lo necesita para
# clonar el repo donde estaría el fichero que lo contendría. Ningún esquema de
# cifrado en Git resolvería esa dependencia circular, y por eso lo crea el
# bootstrap. Sin él, la root-app se queda en `sync: Unknown` con
# `[ComparisonError] failed to list refs` — y con `health: Healthy`, que es
# justo lo que hace que el fallo pase desapercibido si solo se mira esa columna.
echo "==> Fase 0: namespace y credencial del repo de plataforma"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

if kubectl -n "${NAMESPACE}" get secret "${PLATFORM_SECRET}" >/dev/null 2>&1 \
   && [[ -z "${GIT_TOKEN:-}" ]]; then
  echo "    El Secret ${PLATFORM_SECRET} ya existe y no se ha pasado GIT_TOKEN: se conserva."
else
  echo "    Repo: ${PLATFORM_REPO}"
  if [[ -z "${GIT_USER:-}" ]]; then
    read -rp "    Usuario de la credencial de lectura: " GIT_USER
  fi
  if [[ -z "${GIT_TOKEN:-}" ]]; then
    read -rsp "    Credencial de SOLO LECTURA (no se muestra): " GIT_TOKEN
    echo
  fi
  [[ -n "${GIT_USER}" && -n "${GIT_TOKEN}" ]] || {
    echo "    ERROR: usuario y token son obligatorios." >&2; exit 1;
  }

  # `create --dry-run=client -o yaml | apply` en vez de un heredoc: kubectl se
  # encarga de codificar el token, que puede traer cualquier carácter.
  kubectl -n "${NAMESPACE}" create secret generic "${PLATFORM_SECRET}" \
    --from-literal=type=git \
    --from-literal=url="${PLATFORM_REPO}" \
    --from-literal=username="${GIT_USER}" \
    --from-literal=password="${GIT_TOKEN}" \
    --dry-run=client -o yaml \
    | kubectl apply -f -

  # La etiqueta es lo que hace que Argo CD lo interprete como credencial y no
  # como un Secret cualquiera. `repository` = una URL exacta, un Secret por repo.
  kubectl -n "${NAMESPACE}" label secret "${PLATFORM_SECRET}" \
    argocd.argoproj.io/secret-type=repository --overwrite >/dev/null

  echo "    Credencial instalada."
fi

# --- Fase 1: el motor -------------------------------------------------------
# `helm template | kubectl apply` en lugar de `helm install`: el estado del
# release no se guarda en el clúster, porque el dueño de Argo CD pasa a ser el
# propio Argo CD en la fase 3, no Helm. Instalarlo con `helm install` dejaría
# dos gestores compitiendo por los mismos objetos.
echo "==> Fase 1: instalando Argo CD ${CHART_VERSION} desde el chart oficial"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

helm template argo-cd argo/argo-cd \
  --version "${CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --include-crds \
  --values "${REPO_ROOT}/config/argo-cd/values.yaml" \
  | kubectl apply --server-side --force-conflicts -f -

# --- Fase 2: esperar a los CRDs --------------------------------------------
# Aplicar un CRD y un recurso de ese CRD en la misma operación es una carrera:
# el apiserver puede no haber establecido el tipo cuando kubectl intenta crear
# la Application. Por eso el arranque no puede ser un solo comando.
echo "==> Fase 2: esperando a que los CRDs queden establecidos"
kubectl wait --for=condition=Established --timeout=120s \
  crd/applications.argoproj.io \
  crd/appprojects.argoproj.io \
  crd/applicationsets.argoproj.io

kubectl -n "${NAMESPACE}" rollout status deploy/argocd-repo-server --timeout=300s

# --- Fase 3: encender el reconciliador -------------------------------------
# Los AppProject se adelantan aquí porque la root-app declara `project: platform`
# y una Application con un proyecto inexistente queda en error permanente.
# En cuanto la root-app sincroniza, toma posesión de estos mismos objetos.
echo "==> Fase 3: aplicando AppProjects y root-app"
kubectl apply -k "${REPO_ROOT}/bootstrap"

cat <<'EOF'

==> Motor GitOps arrancado.

    A partir de aquí NO se ejecuta ningún comando más para el plano de
    control: todo cambio es un PR.

    Comprobar el estado:
      kubectl -n argocd get applications

    Contraseña inicial de admin:
      kubectl -n argocd get secret argocd-initial-admin-secret \
        -o jsonpath='{.data.password}' | base64 -d; echo

    Cada workload nuevo necesita su propia credencial de repo:
      ./scripts/credenciales.sh estado     <- qué falta
      ./scripts/credenciales.sh anadir     <- añadirla

    Los Secret de cada workload NO se declaran en Git: se crean directamente
    en su namespace, después del primer sync.

    Todo lo operativo está en docs/operar.md.

EOF

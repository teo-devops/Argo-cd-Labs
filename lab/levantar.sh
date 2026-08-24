#!/usr/bin/env bash
#
# Levanta el laboratorio: un clúster kind con el plano de control REAL de este
# repo, sirviéndose a sí mismo desde un Gitea local que hace de forja.
#
#   Uso:  ./lab/levantar.sh          (~5 min la primera vez)
#         ./lab/destruir.sh          para borrarlo
#
# ESTO NO ES PRODUCCIÓN. Ver lab/README.md.
#
# La idea: se espeja este repo en Gitea reescribiendo SOLO las URLs y el
# dominio. Todo lo demás —values, AppProjects, Applications, install.sh— es
# byte a byte lo que se aplicaría en gitops-prod. Si el laboratorio arranca, el
# plano de control es correcto; si falla, habría fallado también en producción.
#
set -euo pipefail

CLUSTER="gitops-lab"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="${REPO_ROOT}/lab"
MIRROR="$(mktemp -d)"
trap 'rm -rf "${MIRROR}"' EXIT

GITEA_USER="demo"
GITEA_PASS="demo1234"
GITEA_SVC="http://gitea.gitea.svc:3000"
CHARTS_SVC="http://charts.charts.svc"

# Contraseña de `admin` en la UI de Argo CD DEL LABORATORIO. Fija, para no tener
# que ir a buscarla al `argocd-initial-admin-secret` —que argocd-server regenera
# en cada instalación— cada vez que se levanta el clúster.
#
#   ARGOCD_PASS='otra' ./lab/levantar.sh    para cambiarla
#
# Se inyecta REESCRIBIENDO EL ESPEJO, igual que las URLs, y por el mismo motivo
# por el que el laboratorio reescribe y no parchea: en `config/argo-cd/values.yaml`
# NO hay ninguna contraseña, ni la habrá. Este repo es público y ese fichero es
# el que se aplica en producción; una contraseña de admin ahí sería exactamente
# lo que este repo dice que no se hace (ver docs/gestion-secretos-lite.md).
ARGOCD_USER="admin"
ARGOCD_PASS="${ARGOCD_PASS:-admin1234}"

# Debe coincidir con `targetRevision` de overlays/prod/argo-cd.yaml. Se lee de
# ahí para que no haya un tercer sitio donde la versión pueda divergir.
# Versión y repo del chart salen de la Application del motor, que es donde ya
# están. El laboratorio no repite ningún dato del plano de control: lo lee.
CHART_VERSION="$(python3 -c "import yaml,sys; print([f['targetRevision'] for f in yaml.safe_load(open(sys.argv[1]))['spec']['sources'] if f.get('chart')][0])" \
  "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/overlays/prod/argo-cd.yaml")"
URL_CHARTS="$(python3 -c "import yaml,sys; print([f['repoURL'] for f in yaml.safe_load(open(sys.argv[1]))['spec']['sources'] if f.get('chart')][0])" \
  "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/overlays/prod/argo-cd.yaml")"

INGRESS_NGINX="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/kind/deploy.yaml"

# Imágenes de la INFRAESTRUCTURA del laboratorio: el motor, la forja, el
# ingress. Se precargan porque en redes que interceptan TLS containerd no puede
# hacer pull aunque el host sí pueda.
IMAGENES=(
  quay.io/argoproj/argocd:v3.4.6
  ghcr.io/dexidp/dex:v2.45.1
  ecr-public.aws.com/docker/library/redis:8.2.3-alpine
  registry.k8s.io/ingress-nginx/controller:v1.12.1
  registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.5.2
  gitea/gitea:1.23
)

# Las de las SEMILLAS se leen de las propias semillas, no se repiten aquí.
# Escribirlas a mano es lo que hacía que añadir un arquetipo nuevo dejara su
# imagen sin precargar, y el síntoma —`Init:ImagePullBackOff` con la Application
# en `Degraded`— no dice en ningún sitio que falte un `kind load`.
mapfile -t -O "${#IMAGENES[@]}" IMAGENES < <(
  grep -rhoE '^\s*(-\s*)?image:\s*\S+' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workload/seeds" \
    | sed -E 's|^\s*(-\s*)?image:\s*||' | sort -u
)

paso() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# ingress-nginx registra un webhook que valida cada Ingress. Entre que su pod
# está Ready y que el servidor de admisión acepta conexiones pasan unos
# segundos, y en ese hueco crear un Ingress falla con `connection refused`.
# No hay una condición fiable que esperar: se reintenta el apply, que es la
# única señal que de verdad dice si el webhook está operativo.
aplicar() {
  local fichero="$1" i
  for i in $(seq 1 40); do
    kubectl apply -f "${fichero}" >/dev/null 2>&1 && return 0
    sleep 3
  done
  kubectl apply -f "${fichero}"   # último intento, ya con el error a la vista
}

# --- 1. El clúster ----------------------------------------------------------
paso "Clúster kind '${CLUSTER}'"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  echo "    ya existe; se reutiliza"
else
  kind create cluster --name "${CLUSTER}" --image kindest/node:v1.34.0 \
    --config "${LAB}/kind.yaml"
fi

# GUARDA: a partir de aquí se aplican manifiestos. Si el contexto no es de kind,
# se aborta. Es lo único que separa un laboratorio de un accidente en producción.
CTX="$(kubectl config current-context)"
[[ "${CTX}" == "kind-${CLUSTER}" ]] || {
  echo "ABORTADO: el contexto es '${CTX}', se esperaba 'kind-${CLUSTER}'." >&2
  exit 1
}
echo "    contexto: ${CTX}"

# --- 2. Imágenes ------------------------------------------------------------
# Se precargan en el nodo: en redes que interceptan TLS, containerd no puede
# hacer pull aunque el host sí pueda.
paso "Precargando imágenes en el nodo"
for img in "${IMAGENES[@]}"; do
  docker image inspect "$img" >/dev/null 2>&1 || {
    echo "    descargando $img"; docker pull -q "$img" >/dev/null; }
  kind load docker-image --name "${CLUSTER}" "$img" >/dev/null 2>&1
  echo "    ✓ $img"
done

# --- 3. ingress-nginx -------------------------------------------------------
# Se le quitan los digests: `kind load` casa por tag, y una imagen referenciada
# por `tag@sha256:...` no la satisface aunque esté en el nodo.
paso "ingress-nginx"
curl -fsSL "${INGRESS_NGINX}" \
  | sed -E 's|(image: registry\.k8s\.io/[^@]+)@sha256:[a-f0-9]+|\1|' \
  | kubectl apply -f - >/dev/null
kubectl -n ingress-nginx wait --for=condition=Ready pod \
  -l app.kubernetes.io/component=controller --timeout=300s >/dev/null

# El pod Ready NO basta: ingress-nginx registra un webhook de admisión que
# valida cada Ingress, y hasta que su Service tiene endpoints, crear un Ingress
# falla con "connection refused". Esperar a los endpoints es la señal real.
for _ in $(seq 1 60); do
  [[ -n "$(kubectl -n ingress-nginx get endpoints ingress-nginx-controller-admission \
             -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)" ]] && break
  sleep 3
done
echo "    listo (webhook de admisión incluido)"

# --- 4. Gitea, haciendo de forja --------------------------------------------
paso "Gitea"
aplicar "${LAB}/plataforma/gitea.yaml"
kubectl -n gitea rollout status deploy/gitea --timeout=300s >/dev/null

POD_GITEA="$(kubectl -n gitea get pod -l app=gitea -o jsonpath='{.items[0].metadata.name}')"

# El usuario puede existir ya si se reutiliza el clúster; solo entonces se
# ignora el error. Un fallo por cualquier otro motivo debe verse.
if kubectl -n gitea exec -i "${POD_GITEA}" -- \
     sh -c "su git -c 'gitea admin user list' | grep -qw ${GITEA_USER}" 2>/dev/null; then
  echo "    usuario ${GITEA_USER}: ya existía"
else
  kubectl -n gitea exec -i "${POD_GITEA}" -- sh -c \
    "su git -c 'gitea admin user create --username ${GITEA_USER} --password ${GITEA_PASS} --email ${GITEA_USER}@lab.local --admin --must-change-password=false'"
fi

# Crea un repo en Gitea. Se usa para el plano de control y para el repo de cada
# workload que este declare; el laboratorio no conoce ningún nombre de antemano.
crear_repo() {
  local repo="$1" codigo
  codigo="$(kubectl -n gitea exec -i "${POD_GITEA}" -- \
    curl -s -o /dev/null -w '%{http_code}' \
    -u "${GITEA_USER}:${GITEA_PASS}" -X POST -H 'Content-Type: application/json' \
    -d "{\"name\":\"${repo}\",\"private\":false,\"auto_init\":false,\"default_branch\":\"main\"}" \
    http://localhost:3000/api/v1/user/repos)"
  case "${codigo}" in
    201) echo "    repo ${repo}: creado" ;;
    409) echo "    repo ${repo}: ya existía" ;;
    *)   echo "ABORTADO: creando el repo ${repo}, Gitea devolvió HTTP ${codigo}" >&2; exit 1 ;;
  esac
}
crear_repo plano-control

# --- 4b. Repositorio de charts local ----------------------------------------
# El chart se descarga en el HOST (donde la red sí funciona) y se sirve dentro
# del clúster. Sin esto, en cualquier red que intercepte TLS el repo-server no
# puede bajarlo y la Application del motor se queda en `Unknown` con un x509.
paso "Repositorio de charts local"
CHART_DIR="$(mktemp -d)"
helm repo add argo "${URL_CHARTS}" >/dev/null 2>&1 || true
helm repo update argo >/dev/null 2>&1
helm pull argo/argo-cd --version "${CHART_VERSION}" -d "${CHART_DIR}" >/dev/null
helm repo index "${CHART_DIR}" --url "${CHARTS_SVC}" >/dev/null
echo "    chart argo-cd ${CHART_VERSION} descargado en el host"

aplicar "${LAB}/plataforma/charts.yaml"
kubectl -n charts rollout status deploy/charts --timeout=180s >/dev/null
POD_CHARTS="$(kubectl -n charts get pod -l app=charts -o jsonpath='{.items[0].metadata.name}')"
kubectl -n charts cp "${CHART_DIR}/index.yaml" "${POD_CHARTS}:/usr/share/nginx/html/index.yaml"
kubectl -n charts cp "${CHART_DIR}/argo-cd-${CHART_VERSION}.tgz" \
  "${POD_CHARTS}:/usr/share/nginx/html/argo-cd-${CHART_VERSION}.tgz"
rm -rf "${CHART_DIR}"
echo "    servido en ${CHARTS_SVC}"

# --- 5. Espejo de ESTE repo, con las URLs reescritas ------------------------
# Solo cambian cuatro cadenas. Todo lo demás es idéntico a producción, que es
# lo que hace que el laboratorio pruebe algo.
paso "Espejando el plano de control en Gitea"
git -C "${REPO_ROOT}" ls-files -z | tar --null -T - -cf - | tar -xf - -C "${MIRROR}"

# Nada se escribe a fuego: la URL del repo de plataforma y el dominio de la UI
# se leen del propio espejo. Si mañana cambian, el laboratorio los sigue.
URL_PLATAFORMA="$(python3 -c "import yaml,sys; print(yaml.safe_load(open(sys.argv[1]))['spec']['source']['repoURL'])" \
  "${MIRROR}/bootstrap/root-app.yaml")"
DOMINIO="$(python3 -c "import yaml,sys; print(yaml.safe_load(open(sys.argv[1]))['global']['domain'])" \
  "${MIRROR}/config/argo-cd/values.yaml")"
echo "    plataforma: ${URL_PLATAFORMA}"
echo "    dominio UI: ${DOMINIO} -> argocd.localhost"

# Reemplazo LITERAL en todo el espejo. Con `sed` habría que escapar puntos y
# barras de cada URL, y un escape mal puesto pasa desapercibido.
reemplazar() {   # <viejo> <nuevo> [subdirectorio del espejo]
  python3 - "${MIRROR}/${3:-}" "$1" "$2" <<'PY'
import os, sys
raiz, viejo, nuevo = sys.argv[1], sys.argv[2], sys.argv[3]
for base, _, ficheros in os.walk(raiz):
    if ".git" in base.split(os.sep):
        continue
    for f in ficheros:
        ruta = os.path.join(base, f)
        try:
            texto = open(ruta, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue
        if viejo in texto:
            open(ruta, "w", encoding="utf-8").write(texto.replace(viejo, nuevo))
PY
}

reemplazar "http://${DOMINIO}" "http://argocd.localhost:8088"
reemplazar "${DOMINIO}" "argocd.localhost"
reemplazar "${URL_PLATAFORMA}" "${GITEA_SVC}/${GITEA_USER}/plano-control.git"

# Pasada 2, SOLO sobre overlays/: el repo de charts pasa a ser el local.
#
# Se deja fuera `scripts/install.sh` a propósito. Ese script corre en el HOST,
# donde `charts.charts.svc` no resuelve; tiene que seguir apuntando al repo
# público, que desde el host sí funciona. Quien necesita la URL interna es el
# repo-server, y esa está en overlays/.
reemplazar "${URL_CHARTS}" "${CHARTS_SVC}" overlays

# Pasada 3: contraseña fija de admin, SOLO en el espejo.
#
# El chart espera un hash bcrypt en `configs.secret.argocdServerAdminPassword`.
# Al declararlo, argocd-server ya NO genera `argocd-initial-admin-secret`: la
# contraseña pasa a ser esta y deja de cambiar entre instalaciones.
#
# El hash se calcula aquí y no se escribe en el repo: aunque sea una contraseña
# de laboratorio y pública, un hash de admin commiteado invita a copiarlo a un
# sitio donde sí importe.
paso "Contraseña fija de admin en el espejo"
HASH_ARGOCD="$(python3 -c '
import bcrypt, sys
print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(rounds=10)).decode())
' "${ARGOCD_PASS}")" || {
  echo "ABORTADO: no se pudo calcular el hash bcrypt. Falta el módulo python3 'bcrypt':" >&2
  echo "          pip install bcrypt   (o apt install python3-bcrypt)" >&2
  exit 1
}
reemplazar "    createSecret: true" \
"    createSecret: true

    # --- INYECTADO POR lab/levantar.sh, NO EXISTE EN EL REPO -----------------
    # Contraseña fija de admin para el laboratorio. En el repo real este bloque
    # no está y no debe estar: la contraseña de produccion la genera el chart en
    # argocd-initial-admin-secret y se cambia tras el primer login.
    argocdServerAdminPassword: '${HASH_ARGOCD}'"
echo "    admin / ${ARGOCD_PASS}"

publicar() {   # <directorio> <repo> <mensaje>
  git -C "$1" init -q -b main
  git -C "$1" -c user.email=lab@lab.local -c user.name=Laboratorio add -A
  git -C "$1" -c user.email=lab@lab.local -c user.name=Laboratorio commit -q -m "$3"
  kubectl -n gitea port-forward svc/gitea 3001:3000 >/dev/null 2>&1 &
  local pf=$!; sleep 3
  # `--force` a propósito, y es lo correcto aquí: el espejo se regenera DESDE
  # CERO en cada ejecución (mktemp + git init), así que su historial no
  # desciende del que ya está en Gitea y un push normal sale rechazado por
  # non-fast-forward en cuanto se reutiliza el clúster. Eso rompía el caso de
  # uso principal del laboratorio —probar un cambio y volver a levantarlo—,
  # que solo funcionaba sobre un clúster recién creado.
  #
  # El espejo es la fuente de verdad y Gitea solo lo sirve; aquí no hay
  # historial que preservar. En un repo de verdad esto no se hace.
  git -C "$1" push -q --force \
    "http://${GITEA_USER}:${GITEA_PASS}@localhost:3001/${GITEA_USER}/$2.git" main
  kill "${pf}" 2>/dev/null || true
  wait "${pf}" 2>/dev/null || true
}

# --- 5b. Los workloads, descubiertos del propio plano de control ------------
# El laboratorio NO conoce ningún workload de antemano: los lee de
# `overlays/prod/apps/` del espejo. Si mañana el plano de control declara otro,
# aparece aquí sin tocar nada. Si deja de declarar uno, desaparece.
paso "Workloads declarados por el plano de control"
mapfile -t WORKLOADS < <(python3 - "${MIRROR}" <<'PY'
import glob, os, sys, yaml
raiz = sys.argv[1]
for f in sorted(glob.glob(os.path.join(raiz, "overlays/prod/apps/*.yaml"))):
    if os.path.basename(f) == "kustomization.yaml":
        continue
    doc = yaml.safe_load(open(f, encoding="utf-8")) or {}
    if doc.get("kind") != "Application":
        continue
    spec = doc.get("spec") or {}
    # `source` (una fuente) o `sources` (varias). De las multi-source interesa
    # la del repo del workload, no la del chart público.
    fuentes = spec.get("sources") or ([spec["source"]] if spec.get("source") else [])
    propias = [f for f in fuentes if isinstance(f, dict) and not f.get("chart")]
    url = propias[0].get("repoURL") if propias else None
    # Qué semilla sembrar. Si la Application no lo dice, el arquetipo por
    # defecto; el laboratorio sigue sin conocer ningún workload de antemano.
    anotaciones = (doc.get("metadata") or {}).get("annotations") or {}
    arquetipo = anotaciones.get("argo-cd-labs.dev/arquetipo", "stateless")
    if url:
        # <nombre>  <url original>  <repo en Gitea>  <arquetipo>
        print(doc["metadata"]["name"], url,
              os.path.basename(url).removesuffix(".git"), arquetipo)
PY
)
[[ "${#WORKLOADS[@]}" -gt 0 ]] || { echo "ABORTADO: el plano de control no declara ningún workload." >&2; exit 1; }

for w in "${WORKLOADS[@]}"; do
  read -r nombre url repo arquetipo <<<"${w}"
  echo "    ${nombre}  ->  ${repo}  (${arquetipo})"
  crear_repo "${repo}"
  # Se apunta su URL al Gitea del laboratorio, en el espejo entero: la usan
  # tanto la Application como el `sourceRepos` de su AppProject.
  reemplazar "${url}" "${GITEA_SVC}/${GITEA_USER}/${repo}.git"
done

echo "    comprobando que el espejo sigue siendo coherente…"
python3 "${MIRROR}/scripts/validar-coherencia.py"

publicar "${MIRROR}" plano-control "Plano de control (espejo del repo real)"
echo "    plano-control publicado"

# Cada repo de workload se siembra con la semilla de SU arquetipo. Al
# laboratorio no le importa qué despliega ese workload en producción, solo que
# el ciclo Git -> Argo CD -> clúster se vea de principio a fin y que las
# propiedades del arquetipo —que un Job sea inmutable, que un volumen sobreviva
# al pod— se puedan probar aquí antes que allí.
paso "Sembrando el repo de cada workload"
for w in "${WORKLOADS[@]}"; do
  read -r nombre url repo arquetipo <<<"${w}"
  ORIGEN="${LAB}/workload/seeds/${arquetipo}"
  if [[ ! -d "${ORIGEN}" ]]; then
    echo "ABORTADO: el workload '${nombre}' declara el arquetipo '${arquetipo}'," >&2
    echo "          y no existe lab/workload/seeds/${arquetipo}/." >&2
    echo "          Arquetipos disponibles: $(cd "${LAB}/workload/seeds" && echo *)" >&2
    exit 1
  fi
  SEED="$(mktemp -d)"
  cp -r "${ORIGEN}/." "${SEED}/"
  # Un hostname por workload. Con dos workloads del mismo arquetipo, el
  # `demo.localhost` de la semilla haría que el Ingress se lo quedase uno de
  # los dos y el otro fallase sin decir por qué.
  find "${SEED}" -type f -name '*.yaml' -exec \
    sed -i "s|demo\.localhost|${nombre}.localhost|g" {} +
  publicar "${SEED}" "${repo}" "Contenido de laboratorio v1 (${arquetipo})"
  rm -rf "${SEED}"
  echo "    ${repo} sembrado desde seeds/${arquetipo}"
done

# --- 6. El bootstrap REAL, desde el espejo ----------------------------------
paso "Bootstrap (scripts/install.sh del espejo, sin modificar)"
echo "y" | GIT_USER="${GITEA_USER}" GIT_TOKEN="${GITEA_PASS}" \
  "${MIRROR}/scripts/install.sh" 2>&1 | grep -E "^==>|Credencial|created|configured"

# Con la contraseña fijada por el chart, argocd-server ya no genera
# `argocd-initial-admin-secret`. Pero si el clúster se reutiliza puede quedar el
# de una ejecución anterior, con una contraseña que ya NO sirve: quien lo lea se
# lleva un valor que no funciona y no hay nada que se lo diga. Se borra.
kubectl -n argocd delete secret argocd-initial-admin-secret --ignore-not-found >/dev/null 2>&1 || true

# --- 7. Credenciales de los repos de workload -------------------------------
# El bootstrap solo crea la del plano de control, igual que en producción. Aquí
# se añade una por workload, que es lo que haría `credenciales.sh anadir`.
paso "Credenciales de los repos de workload"
for w in "${WORKLOADS[@]}"; do
  read -r nombre url repo arquetipo <<<"${w}"
  kubectl -n argocd create secret generic "repo-${repo}" \
    --from-literal=type=git \
    --from-literal=url="${GITEA_SVC}/${GITEA_USER}/${repo}.git" \
    --from-literal=username="${GITEA_USER}" \
    --from-literal=password="${GITEA_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n argocd label secret "repo-${repo}" \
    argocd.argoproj.io/secret-type=repository --overwrite >/dev/null
  echo "    repo-${repo}"
done

# --- 8. Esperar a que el árbol converja -------------------------------------
paso "Esperando a que la root-app despliegue el árbol"
for _ in $(seq 1 40); do
  pendientes=0
  for w in "${WORKLOADS[@]}"; do
    read -r nombre _ _ _ <<<"${w}"
    [[ "$(kubectl -n argocd get application "${nombre}" \
            -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)" \
       == "Synced/Healthy" ]] || pendientes=1
  done
  [[ "${pendientes}" -eq 0 ]] && break
  sleep 15
done
kubectl -n argocd get applications \
  -o custom-columns='APPLICATION:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

cat <<EOF

==> Laboratorio listo.

    Argo CD   http://argocd.localhost:8088    ${ARGOCD_USER} / ${ARGOCD_PASS}
    Gitea     http://gitea.localhost:8088     ${GITEA_USER} / ${GITEA_PASS}
EOF

# Un hostname por workload, y solo los arquetipos que publican algo por HTTP.
for w in "${WORKLOADS[@]}"; do
  read -r nombre url repo arquetipo <<<"${w}"
  case "${arquetipo}" in
    stateless|stateful)
      printf '    %-9s http://%s.localhost:8088   (%s)\n' \
        "${nombre}" "${nombre}" "${arquetipo}" ;;
    *)
      printf '    %-9s sin HTTP — mira los logs:  kubectl -n %s logs -l job-name=trabajo\n' \
        "${nombre}" "${nombre}" ;;
  esac
done

cat <<EOF

    Prueba el ciclo: en Gitea, abre el repo de cualquier workload, edita
    overlays/prod/ cambiando v1 por v2, commitea, y míralo en Argo CD.

    Para probar los otros arquetipos, da de alta un workload nuevo y vuelve a
    levantar el laboratorio — no hay que tocar nada de lab/:
      python3 scripts/alta-workload.py mi-job \\
        https://github.com/teo-devops/workload-mi-job.git --arquetipo batch

    La contraseña de Argo CD es fija y no cambia entre ejecuciones. Para usar
    otra:  ARGOCD_PASS='la-que-quieras' ./lab/levantar.sh

    Para destruirlo:  ./lab/destruir.sh
EOF

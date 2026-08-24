#!/usr/bin/env bash
#
# Credenciales que Argo CD necesita para leer los repos Git.
#
#   Uso:  ./scripts/credenciales.sh [--contexto <ctx>] [--si] <subcomando>
#
#     estado    Qué repos declara este plano de control y cuáles tienen ya
#               credencial en el clúster. Empieza siempre por aquí.
#     anadir    Crear o rotar la credencial de un repo (pregunta cuál).
#     admin     Contraseña de admin de la UI.
#     probar    ¿Consigue Argo CD leer los repos? Diagnóstico cuando algo falla.
#
#   Opciones:
#     --contexto <ctx>  Contexto de kubectl sobre el que actuar (o ARGOCD_CONTEXTO).
#                       Por defecto, el contexto activo.
#     --si              No preguntar antes de escribir. Para uso no interactivo.
#
# CONTEXTO: todo esto escribe en UN clúster, el del contexto de kubectl. El
# contexto se anuncia en la cabecera y se comprueba ANTES de pedir nada: tener
# tecleado un token y descubrir entonces que el clúster era otro es la forma
# más cara de equivocarse, porque el token ya no se puede volver a leer.
#
# MODELO: una credencial por repo. Un Secret de tipo `repository` casa con UNA
# url exacta. Añadir un workload = añadir su credencial con `anadir`.
#
# Esto NO gestiona los Secret de cada workload (los que usan sus pods): esos se
# crean con `kubectl` en su namespace. Ver docs/gestion-secretos-lite.md.
#
set -euo pipefail

NAMESPACE="argocd"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CONTEXTO="${ARGOCD_CONTEXTO:-}"
ASUMIR_SI=0
KUBECTL=(kubectl)

uso() {
  sed -n '3,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- contexto de kubectl ----------------------------------------------------

contexto_kubectl() {
  if [[ -n "${CONTEXTO}" ]]; then
    echo "${CONTEXTO}"
  else
    kubectl config current-context 2>/dev/null || true
  fi
}

apiserver() {
  local ctx="$1"
  kubectl config view --minify --context "${ctx}" \
    -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true
}

listar_contextos() {
  echo "         Contextos disponibles:"
  kubectl config get-contexts -o name 2>/dev/null | sed 's/^/           /'
}

# Solo se llama cuando el contexto activo no tiene Argo CD: la pregunta que uno
# se hace en ese momento es "¿en cuál estaba?", y responderla cuesta un sondeo
# corto a cada contexto.
contextos_con_argocd() {
  local actual encontrados=() c
  actual="$(contexto_kubectl)"
  echo "         Sondeando los demás contextos (2s cada uno)..."
  while read -r c; do
    [[ "$c" == "${actual}" ]] && continue
    if kubectl --context "$c" --request-timeout=2s \
         get namespace "${NAMESPACE}" -o name >/dev/null 2>&1; then
      encontrados+=("$c")
    fi
  done < <(kubectl config get-contexts -o name 2>/dev/null)

  if (( ${#encontrados[@]} )); then
    echo "         Sí tienen namespace ${NAMESPACE}:  ${encontrados[*]}"
  else
    echo "         Ningún otro contexto alcanzable tiene namespace ${NAMESPACE}."
  fi
}

# Cabecera común: título + a qué clúster se está hablando, y aborta si ese
# clúster no es uno donde tenga sentido seguir.
iniciar() {
  local titulo="$1" ctx err
  ctx="$(contexto_kubectl)"

  printf '== %s %s\n' "${titulo}" \
    "$(printf '=%.0s' $(seq 1 $(( 63 - ${#titulo} > 3 ? 63 - ${#titulo} : 3 ))))"

  if [[ -z "${ctx}" ]]; then
    echo >&2
    echo "  ERROR: kubectl no tiene ningún contexto seleccionado." >&2
    listar_contextos >&2
    echo "         Elige uno:  kubectl config use-context <nombre>" >&2
    exit 1
  fi

  printf '   clúster: contexto «%s» — %s\n\n' "${ctx}" "$(apiserver "${ctx}")"

  if ! err="$("${KUBECTL[@]}" get namespace "${NAMESPACE}" -o name 2>&1)"; then
    if [[ "${err}" == *NotFound* || "${err}" == *"not found"* ]]; then
      echo "  ERROR: el contexto «${ctx}» no tiene namespace ${NAMESPACE}:" >&2
      echo "         ahí no hay ningún Argo CD que configurar." >&2
      contextos_con_argocd >&2
    else
      echo "  ERROR: no se puede hablar con el apiserver del contexto «${ctx}»." >&2
      echo "         ${err%%$'\n'*}" >&2
      listar_contextos >&2
    fi
    echo >&2
    echo "         Cambia de contexto, o fíjalo solo para esta ejecución:" >&2
    echo "           $0 --contexto <nombre> <subcomando>" >&2
    exit 1
  fi
}

# Confirmación antes de escribir. Va SIEMPRE antes de pedir usuario y token.
confirmar_escritura() {
  local que="$1" respuesta
  (( ASUMIR_SI )) && return 0
  read -rp "  Vas a escribir ${que} en «$(contexto_kubectl)». ¿Continuar? [s/N] " respuesta
  [[ "${respuesta}" =~ ^[sSyY]$ ]] || { echo "  Abortado. No se ha escrito nada."; exit 1; }
}

# --- repos declarados en el plano de control --------------------------------
# Salida: "<url>\t<nombre-de-secret-sugerido>\t<fichero-que-lo-declara>"
# Se ignoran los repositorios de charts públicos: no llevan credencial.
repos_declarados() {
  python3 - "$REPO_ROOT" <<'PY'
import glob, os, re, sys, yaml

raiz = sys.argv[1]
vistos = {}
for patron in ("overlays/prod/projects/*.yaml", "overlays/prod/apps/*.yaml",
                "overlays/prod/argo-cd/*.yaml"):
    for ruta in sorted(glob.glob(os.path.join(raiz, patron))):
        if os.path.basename(ruta) == "kustomization.yaml":
            continue
        doc = yaml.safe_load(open(ruta, encoding="utf-8")) or {}
        spec = doc.get("spec") or {}
        urls = list(spec.get("sourceRepos") or [])
        if spec.get("source"):
            urls.append(spec["source"].get("repoURL"))
        for s in spec.get("sources") or []:
            urls.append(s.get("repoURL"))
        for u in urls:
            if u and u.endswith(".git"):
                vistos.setdefault(u, os.path.relpath(ruta, raiz))

for url, origen in sorted(vistos.items()):
    # El nombre sugerido para el Secret sale del nombre del repo, pero un
    # nombre de Secret es un subdominio RFC 1123: minusculas, digitos, '.' y
    # '-'. Un repositorio admite ademas '_', y ahi se rompe:
    #
    #   .../scenarios/k8s/k8s_v0.10.git  ->  repo-k8s_v0.10
    #
    # que el apiserver RECHAZA al crearlo. El fallo no aparece al listar, sino
    # al final de `anadir`, con el token ya tecleado.
    #
    # Solo afecta al nombre SUGERIDO. La correspondencia real es por url
    # exacta, y de eso se ocupa secret_de(), asi que saneas el nombre sin
    # perder de vista ningun Secret que ya exista.
    base = re.sub(r"[^a-z0-9.-]", "-", os.path.basename(url)[:-4].lower()).strip("-.")
    print(f"{url}\trepo-{base}\t{origen}")
PY
}

# Nombre del Secret que ya cubre esa url exacta, si existe.
secret_de() {
  local url="$1"
  "${KUBECTL[@]}" -n "${NAMESPACE}" get secret \
    -l argocd.argoproj.io/secret-type=repository -o json 2>/dev/null \
  | python3 -c "
import base64, json, sys
url = sys.argv[1]
for s in json.load(sys.stdin).get('items', []):
    d = s.get('data') or {}
    if 'url' in d and base64.b64decode(d['url']).decode().rstrip('/') == url.rstrip('/'):
        print(s['metadata']['name'])
        break
" "$url"
}

# Credenciales en el clúster cuya url no declara ya nadie: sobras de un repo
# renombrado o retirado. No rompen nada, pero al rotar despistan.
credenciales_sin_repo() {
  local declaradas
  declaradas="$(repos_declarados | cut -f1)"
  "${KUBECTL[@]}" -n "${NAMESPACE}" get secret \
    -l argocd.argoproj.io/secret-type=repository -o json 2>/dev/null \
  | python3 -c "
import base64, json, sys
declaradas = {u.rstrip('/') for u in sys.argv[1].split() if u}
for s in json.load(sys.stdin).get('items', []):
    d = s.get('data') or {}
    if 'url' not in d:
        continue
    url = base64.b64decode(d['url']).decode()
    if url.rstrip('/') not in declaradas:
        print(f\"{s['metadata']['name']}\t{url}\")
" "${declaradas}"
}

cmd_estado() {
  iniciar "Repos que este plano de control quiere leer"

  local faltan=0 total=0
  while IFS=$'\t' read -r url sugerido origen; do
    total=$((total + 1))
    local existente
    existente="$(secret_de "$url")"
    if [[ -n "${existente}" ]]; then
      local usuario
      usuario="$("${KUBECTL[@]}" -n "${NAMESPACE}" get secret "${existente}" \
                  -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)"
      printf "  [OK]    %s\n          Secret %s (usuario %s)\n" "$url" "$existente" "${usuario:-?}"
    else
      faltan=$((faltan + 1))
      printf "  [FALTA] %s\n          declarado en %s -> Secret sugerido: %s\n" \
             "$url" "$origen" "$sugerido"
    fi
  done < <(repos_declarados)

  echo
  if [[ "${faltan}" -eq 0 ]]; then
    echo "  Los ${total} repos tienen credencial."
    echo "  [OK] dice que hay Secret, no que el token valga: eso lo dice  $0 probar"
  else
    echo "  Faltan ${faltan} de ${total}. Añádelas con:  $0 anadir"
    echo "  Sin credencial, su Application se queda en 'failed to list refs'"
    echo "  con health Healthy — verde por fuera y parada por dentro."
  fi

  local sobras
  sobras="$(credenciales_sin_repo)"
  if [[ -n "${sobras}" ]]; then
    echo
    echo "  Credenciales que ya no reclama ningún repo declarado:"
    while IFS=$'\t' read -r nombre url; do
      printf "    %s  ->  %s\n" "$nombre" "$url"
    done <<< "${sobras}"
    echo "  Si el repo se renombró o se retiró, sobran:"
    echo "    kubectl -n ${NAMESPACE} delete secret <nombre>"
  fi
}

cmd_anadir() {
  iniciar "Añadir o rotar la credencial de un repo"

  echo "En la forja, en el repositorio correspondiente:"
  echo "  Settings > Repository > Deploy tokens > Add token"
  echo "    Usuario : argocd"
  echo "    Scope   : read_repository   <- solo ese"
  echo
  echo "  El usuario que se pide abajo es el del DEPLOY TOKEN (el que escribiste"
  echo "  en ese formulario), no tu correo. Con el usuario equivocado"
  echo "  el Secret se crea igual y el fallo aparece luego, en la Application,"
  echo "  como 'HTTP Basic: Access denied'."
  echo

  local urls=() nombres=() i=1
  while IFS=$'\t' read -r url sugerido _; do
    local existente
    existente="$(secret_de "$url")"
    urls+=("$url")
    nombres+=("${existente:-$sugerido}")
    printf "  %d) %s  %s\n" "$i" "$url" "$([[ -n "$existente" ]] && echo '(ya tiene: rotar)' || echo '(FALTA)')"
    i=$((i + 1))
  done < <(repos_declarados)

  [[ "${#urls[@]}" -gt 0 ]] || { echo "  No hay repos declarados."; exit 1; }

  echo
  read -rp "  Número del repo: " n
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#urls[@]} )) || {
    echo "  ERROR: elige un número entre 1 y ${#urls[@]}." >&2; exit 1;
  }

  local url="${urls[$((n - 1))]}" nombre="${nombres[$((n - 1))]}"
  echo "  Repo  : ${url}"
  echo "  Secret: ${nombre}"
  confirmar_escritura "el Secret ${nombre}"

  local usuario token
  read -rp "  Usuario del deploy token: " usuario
  read -rsp "  Token (no se muestra): " token; echo
  [[ -n "${usuario}" && -n "${token}" ]] || {
    echo "  ERROR: usuario y token son obligatorios." >&2; exit 1;
  }

  "${KUBECTL[@]}" -n "${NAMESPACE}" create secret generic "${nombre}" \
    --from-literal=type=git \
    --from-literal=url="${url}" \
    --from-literal=username="${usuario}" \
    --from-literal=password="${token}" \
    --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

  "${KUBECTL[@]}" -n "${NAMESPACE}" label secret "${nombre}" \
    argocd.argoproj.io/secret-type=repository --overwrite >/dev/null

  cat <<EOF

  Listo, en el contexto «$(contexto_kubectl)». Argo CD la recoge sin reiniciar
  nada; si en un minuto sigue fallando:
    kubectl -n ${NAMESPACE} rollout restart deploy/argocd-repo-server

  Comprueba con:  $0 probar
  Crear el Secret no prueba que el token valga: eso solo se ve ahí.

  Guarda el token también en el almacén de contraseñas del equipo: en el
  clúster no se puede volver a leer, y si se pierde hay que emitir otro.
EOF
}

cmd_admin() {
  iniciar "Contraseña de admin de la UI"

  if "${KUBECTL[@]}" -n "${NAMESPACE}" get secret argocd-initial-admin-secret >/dev/null 2>&1; then
    echo -n "  "
    "${KUBECTL[@]}" -n "${NAMESPACE}" get secret argocd-initial-admin-secret \
      -o jsonpath='{.data.password}' | base64 -d; echo
    cat <<EOF

  Es la contraseña INICIAL. Cámbiala y borra ese Secret:
    argocd account update-password
    kubectl -n ${NAMESPACE} delete secret argocd-initial-admin-secret

  La UI:  http://argocd.192-168-1-100.nip.io
EOF
  else
    cat <<EOF
  No existe 'argocd-initial-admin-secret': normalmente significa que ya se
  cambió la contraseña. Para resetearla:
    kubectl -n ${NAMESPACE} patch secret argocd-secret \\
      -p '{"data":{"admin.password":null,"admin.passwordMtime":null}}'
    kubectl -n ${NAMESPACE} rollout restart deploy/argocd-server
EOF
  fi
}

cmd_probar() {
  iniciar "¿Consigue Argo CD leer los repos?"

  local apps
  apps="$("${KUBECTL[@]}" -n "${NAMESPACE}" get applications -o name 2>/dev/null || true)"
  [[ -n "${apps}" ]] || { echo "  No hay ninguna Application todavía."; return 0; }

  # Se imprimen SYNC y HEALTH juntas a propósito: con una credencial ausente o
  # equivocada, health sigue en Healthy y solo sync delata el problema.
  "${KUBECTL[@]}" -n "${NAMESPACE}" get applications \
    -o custom-columns='APPLICATION:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

  # La pista sobre credenciales solo se imprime si hay algo que explicar. Un
  # diagnóstico que suelta el mismo texto cuando todo va bien enseña a no
  # leerlo.
  local errores
  errores="$("${KUBECTL[@]}" -n "${NAMESPACE}" get applications -o json | python3 -c "
import json, sys
for a in json.load(sys.stdin)['items']:
    for c in (a.get('status', {}).get('conditions') or []):
        if 'Error' in c.get('type', ''):
            print(f\"  {a['metadata']['name']}: [{c['type']}] {c.get('message','')[:240]}\")
")"

  echo
  if [[ -z "${errores}" ]]; then
    echo "-- Sin errores: Argo CD lee todos los repos declarados."
    return 0
  fi

  echo "-- Errores --"
  echo "${errores}"
  echo
  echo "  Los dos fallos de credencial se parecen y no se arreglan igual:"
  echo
  echo "  'failed to list refs' a secas  => NO hay Secret para esa url exacta."
  echo "                                    Mira:  $0 estado"
  echo "  'HTTP Basic: Access denied'    => SÍ hay Secret, pero no vale para ese"
  echo "                                    repo: usuario que no es el del deploy"
  echo "                                    token, token caducado, sin"
  echo "                                    read_repository, o de otro proyecto."
  echo "                                    Rótalo:  $0 anadir"
}

# --- despacho ---------------------------------------------------------------

SUBCOMANDO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --contexto|-c)        CONTEXTO="${2:?--contexto necesita el nombre de un contexto}"; shift 2 ;;
    --contexto=*)         CONTEXTO="${1#*=}"; shift ;;
    --si|-s)              ASUMIR_SI=1; shift ;;
    -h|--help|help|ayuda) uso; exit 0 ;;
    -*)                   echo "ERROR: opción desconocida: $1" >&2; echo >&2; uso >&2; exit 1 ;;
    *)                    [[ -z "${SUBCOMANDO}" ]] || { echo "ERROR: sobra el argumento '$1'." >&2; exit 1; }
                          SUBCOMANDO="$1"; shift ;;
  esac
done

[[ -n "${CONTEXTO}" ]] && KUBECTL=(kubectl --context "${CONTEXTO}")

# `anadir` y `añadir` valen las dos: el comando se escribe en castellano y
# obligar a teclearlo mal es una trampa que se pisa una vez por sesión.
case "${SUBCOMANDO}" in
  estado)        cmd_estado ;;
  anadir|añadir) cmd_anadir ;;
  admin)         cmd_admin ;;
  probar)        cmd_probar ;;
  "")            uso; exit 1 ;;
  *)             echo "ERROR: subcomando desconocido: ${SUBCOMANDO}" >&2; echo >&2; uso >&2; exit 1 ;;
esac

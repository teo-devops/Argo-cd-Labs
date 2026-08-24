#!/usr/bin/env bash
#
# Borra el clúster del laboratorio. No toca nada más.
#
#   Uso:  ./lab/destruir.sh
#
set -euo pipefail

CLUSTER="gitops-lab"

kind get clusters 2>/dev/null | grep -qx "${CLUSTER}" || {
  echo "No existe el clúster '${CLUSTER}'. Nada que borrar."
  exit 0
}

echo "Se va a borrar el clúster kind '${CLUSTER}' y todo su contenido."
read -rp "¿Continuar? [y/N] " ok
[[ "${ok}" == "y" || "${ok}" == "Y" ]] || { echo "Abortado."; exit 1; }

kind delete cluster --name "${CLUSTER}"
echo "Borrado. Las imágenes siguen en la caché de Docker, así que volver a"
echo "levantarlo con ./lab/levantar.sh es rápido y no necesita red."

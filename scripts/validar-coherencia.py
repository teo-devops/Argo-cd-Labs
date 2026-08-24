#!/usr/bin/env python3
"""Comprueba que cada workload es coherente entre sus dos ficheros.

El alta de un workload es copiar-pegar-sustituir en
`overlays/prod/projects/<x>.yaml` y `overlays/prod/apps/<x>.yaml`. El error
probable de ese procedimiento es un nombre sin sustituir: un namespace, un repo
o un `project` que no casan entre los dos ficheros. Argo CD lo detecta —rechaza el sync— pero lo detecta en el clúster,
después del merge, con el workload ya dado de alta y sin desplegar.

Esto lo detecta en el PR, que es donde cuesta un minuto arreglarlo.

    Uso:  python3 scripts/validar-coherencia.py
    Sale con código 1 si hay alguna incoherencia.
"""

from __future__ import annotations

import pathlib
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("Falta PyYAML:  pip install pyyaml")

RAIZ = pathlib.Path(__file__).resolve().parent.parent
DIR_PROYECTOS = RAIZ / "overlays" / "prod" / "projects"
DIR_APPS = RAIZ / "overlays" / "prod" / "apps"
DIR_SEEDS = RAIZ / "lab" / "workload" / "seeds"
INSTALL_SH = RAIZ / "scripts" / "install.sh"
APP_MOTOR = RAIZ / "overlays" / "prod" / "argo-cd.yaml"
SERVIDOR_ESPERADO = "https://kubernetes.default.svc"

# Los arquetipos válidos NO se listan aquí: son los que el laboratorio sabe
# sembrar. Derivarlos del directorio evita que la lista y las semillas
# diverjan, que es el fallo que dejaría a `levantar.sh` cayendo al arquetipo
# por defecto en silencio.
ARQUETIPOS = frozenset(
    d.name for d in DIR_SEEDS.iterdir() if d.is_dir()
) if DIR_SEEDS.is_dir() else frozenset()

# Marcadores de `plantillas/`. Si alguno llega a overlays/, el alta se quedó a
# medias: el fichero es sintácticamente válido y Argo CD crearía un AppProject
# llamado literalmente NOMBRE.
MARCADORES = ("NOMBRE", "REPO_URL", "DESCRIPCION", "GRUPO", "ARQUETIPO",
              "CAMBIAME")

# Proyectos que no describen un workload y por tanto no tienen Application
# homónima en overlays/prod/apps.
PROYECTOS_DE_PLATAFORMA = {"platform"}

errores: list[str] = []


def error(msg: str) -> None:
    errores.append(msg)


def cargar(ruta: pathlib.Path) -> dict:
    with ruta.open(encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


def recursos_de(kustomization: pathlib.Path) -> set[str]:
    return set(cargar(kustomization).get("resources", []))


def ficheros_yaml(directorio: pathlib.Path) -> list[pathlib.Path]:
    return sorted(
        p for p in directorio.glob("*.yaml") if p.name != "kustomization.yaml"
    )


def fuentes_de(spec: dict) -> list[dict]:
    """Las fuentes de una Application, venga en `source` o en `sources`."""
    if spec.get("sources"):
        return [f for f in spec["sources"] if isinstance(f, dict)]
    if spec.get("source"):
        return [spec["source"]]
    return []


def escalares(nodo) -> "list[str]":
    """Todas las cadenas de un documento YAML, a cualquier profundidad."""
    if isinstance(nodo, str):
        return [nodo]
    if isinstance(nodo, dict):
        return [s for k, v in nodo.items() for s in escalares(k) + escalares(v)]
    if isinstance(nodo, list):
        return [s for v in nodo for s in escalares(v)]
    return []


def comprobar_marcadores_de_plantilla() -> None:
    """Ningún marcador de `plantillas/` puede sobrevivir en `overlays/`.

    `alta-workload.py` los sustituye todos, pero el alta también se puede hacer
    a mano copiando la plantilla, y ahí se olvida uno. El resultado es YAML
    válido —Argo CD crearía un AppProject llamado literalmente `NOMBRE`— así
    que ni el parser ni Kustomize lo detectan.

    Se mira el VALOR, no el texto del fichero: los comentarios de estos
    manifiestos están en castellano y llenos de mayúsculas, y buscar sobre el
    texto convierte cualquier frase enfática en un falso positivo.
    """
    for directorio in (DIR_PROYECTOS, DIR_APPS):
        for ruta in ficheros_yaml(directorio):
            for valor in escalares(cargar(ruta)):
                for marcador in MARCADORES:
                    if re.search(rf"(?<![\w-]){marcador}(?![\w-])", valor):
                        error(f"{ruta.relative_to(RAIZ)}: queda el marcador "
                              f"{marcador!r} de plantillas/ en el valor "
                              f"{valor!r}. El alta está a medias.")


def comprobar_version_del_chart() -> None:
    """La versión del chart está escrita en dos sitios y deben coincidir.

    `install.sh` la usa para el `helm template` del arranque; `argo-cd.yaml`
    para el régimen estacionario. Si divergen, el clúster nace con una versión
    de Argo CD y Argo CD se reinstala a sí mismo con otra en cuanto sincroniza
    —sin que nadie lo pida y sin que el diff del PR lo enseñe.
    """
    m = re.search(r'^CHART_VERSION="([^"]+)"', INSTALL_SH.read_text(encoding="utf-8"),
                  re.MULTILINE)
    if not m:
        error(f"{INSTALL_SH.relative_to(RAIZ)}: no se encuentra CHART_VERSION")
        return
    version_script = m.group(1)

    fuentes = (cargar(APP_MOTOR).get("spec", {}) or {}).get("sources", []) or []
    chart = next((s for s in fuentes if s.get("chart") == "argo-cd"), None)
    if chart is None:
        error(f"{APP_MOTOR.relative_to(RAIZ)}: no hay ninguna source con "
              f"chart 'argo-cd'")
        return
    version_app = chart.get("targetRevision")

    if version_script != version_app:
        error(f"versión del chart argo-cd divergente: install.sh dice "
              f"{version_script!r} y {APP_MOTOR.relative_to(RAIZ)} dice "
              f"{version_app!r}. El clúster arrancaría con una versión y se "
              f"reinstalaría con otra en el primer sync.")


def comprobar_repo_de_plataforma() -> None:
    """`install.sh` crea la credencial del repo que lee la root-app.

    Si esas dos URLs divergen, el bootstrap instala una credencial para un repo
    y la root-app intenta clonar otro: queda en `failed to list refs` con
    `health: Healthy`, que es el fallo que peor se ve.
    """
    m = re.search(r'^PLATFORM_REPO="([^"]+)"', INSTALL_SH.read_text(encoding="utf-8"),
                  re.MULTILINE)
    if not m:
        error(f"{INSTALL_SH.relative_to(RAIZ)}: no se encuentra PLATFORM_REPO")
        return

    root_app = RAIZ / "bootstrap" / "root-app.yaml"
    url_root = ((cargar(root_app).get("spec") or {}).get("source") or {}).get("repoURL")

    if m.group(1) != url_root:
        error(f"PLATFORM_REPO de install.sh ({m.group(1)!r}) no coincide con el "
              f"repoURL de {root_app.relative_to(RAIZ)} ({url_root!r}). El "
              f"bootstrap crearía la credencial de un repo distinto del que "
              f"lee la root-app.")


def main() -> int:
    comprobar_version_del_chart()
    comprobar_repo_de_plataforma()
    comprobar_marcadores_de_plantilla()

    recursos_proyectos = recursos_de(DIR_PROYECTOS / "kustomization.yaml")
    recursos_apps = recursos_de(DIR_APPS / "kustomization.yaml")

    # --- Un AppProject por fichero, y todos declarados en su kustomization ---
    proyectos: dict[str, dict] = {}
    for ruta in ficheros_yaml(DIR_PROYECTOS):
        doc = cargar(ruta)
        if doc.get("kind") != "AppProject":
            error(f"{ruta.relative_to(RAIZ)}: se esperaba kind AppProject, "
                  f"encontrado {doc.get('kind')!r}")
            continue
        nombre = doc.get("metadata", {}).get("name")
        if nombre != ruta.stem:
            error(f"{ruta.relative_to(RAIZ)}: metadata.name es {nombre!r} pero "
                  f"el fichero se llama {ruta.stem!r}")
        if ruta.name not in recursos_proyectos:
            error(f"overlays/prod/projects/kustomization.yaml: falta {ruta.name}; el "
                  f"AppProject existe en el repo pero no se aplica")
        proyectos[nombre] = doc

    # --- Una Application por fichero, coherente con su AppProject -----------
    workloads_con_app: set[str] = set()
    for ruta in ficheros_yaml(DIR_APPS):
        doc = cargar(ruta)
        rel = ruta.relative_to(RAIZ)
        if doc.get("kind") != "Application":
            error(f"{rel}: se esperaba kind Application, encontrado "
                  f"{doc.get('kind')!r}")
            continue

        nombre = doc.get("metadata", {}).get("name")
        if nombre != ruta.stem:
            error(f"{rel}: metadata.name es {nombre!r} pero el fichero se "
                  f"llama {ruta.stem!r}")
        if ruta.name not in recursos_apps:
            error(f"overlays/prod/apps/kustomization.yaml: falta {ruta.name}; la "
                  f"Application existe en el repo pero no se aplica")

        spec = doc.get("spec", {})
        proyecto = spec.get("project")
        workloads_con_app.add(proyecto)

        if proyecto == "default":
            error(f"{rel}: project 'default' no restringe nada. Cada workload "
                  f"necesita su propio AppProject.")
            continue
        if proyecto in PROYECTOS_DE_PLATAFORMA:
            error(f"{rel}: project {proyecto!r} es de plataforma; un workload "
                  f"no debe usarlo (tiene permisos cluster-scoped).")
            continue
        if proyecto != nombre:
            error(f"{rel}: project es {proyecto!r} pero la Application se "
                  f"llama {nombre!r}. El modelo es 1 workload = 1 AppProject "
                  f"homónimo.")
        if proyecto not in proyectos:
            error(f"{rel}: project {proyecto!r} no existe en projects/. La "
                  f"Application quedaría en error permanente.")
            continue

        pspec = proyectos[proyecto].get("spec", {})

        # Todos los repos de la Application deben estar permitidos por el
        # AppProject.
        #
        # `source` (una fuente) y `sources` (varias) son excluyentes en Argo CD,
        # y aquí se aceptan las dos. El multi-source es el patrón "chart de
        # terceros + mis valores en mi repo", que el propio motor usa en
        # overlays/prod/argo-cd.yaml; leer solo `source` hacía que un workload
        # con esa forma se rechazase con `repoURL None no está en sourceRepos`,
        # un mensaje que no explica la causa.
        fuentes = fuentes_de(spec)
        if not fuentes:
            error(f"{rel}: no declara ni `source` ni `sources`.")
        permitidos = pspec.get("sourceRepos", [])
        for fuente in fuentes:
            repo = fuente.get("repoURL")
            if repo not in permitidos:
                error(f"{rel}: repoURL {repo!r} no está en sourceRepos de "
                      f"overlays/prod/projects/{proyecto}.yaml ({permitidos}). "
                      f"Argo CD rechazaría el sync.")

        # Un workload lee de UN repositorio (el modelo es 1 workload = 1 repo).
        # Que use varias fuentes es legítimo —un chart público más su repo—,
        # pero solo una puede ser suya: si hay dos repos de código propio, son
        # dos workloads o el AppProject está de más.
        repos_git = {f.get("repoURL") for f in fuentes if not f.get("chart")}
        if len(repos_git) > 1:
            error(f"{rel}: declara {len(repos_git)} repositorios Git de código "
                  f"({sorted(repos_git)}). El modelo es 1 workload = 1 repo; "
                  f"las fuentes adicionales solo pueden ser charts públicos.")

        # El arquetipo es opcional, pero si está tiene que ser uno de los que el
        # laboratorio sabe sembrar; si no, `levantar.sh` caería al de por
        # defecto en silencio y probarías otra cosa de la que crees.
        arquetipo = (doc.get("metadata", {}).get("annotations") or {}).get(
            "argo-cd-labs.dev/arquetipo")
        if arquetipo is not None and arquetipo not in ARQUETIPOS:
            error(f"{rel}: arquetipo {arquetipo!r} desconocido. Los que el "
                  f"laboratorio sabe sembrar son {sorted(ARQUETIPOS)} "
                  f"(ver lab/workload/seeds/ y docs/arquetipos.md).")

        # El namespace debe estar permitido, y sin comodines.
        destino = spec.get("destination", {})
        ns = destino.get("namespace")
        servidor = destino.get("server")
        destinos = pspec.get("destinations", [])
        casa = any(
            d.get("namespace") == ns and d.get("server") == servidor
            for d in destinos
        )
        if not casa:
            error(f"{rel}: destino {servidor}/{ns} no está en destinations de "
                  f"overlays/prod/projects/{proyecto}.yaml ({destinos}).")
        if any(d.get("namespace") == "*" for d in destinos):
            error(f"overlays/prod/projects/{proyecto}.yaml: destinations con comodín '*'. "
                  f"Un workload debe estar confinado a un namespace exacto.")
        if servidor != SERVIDOR_ESPERADO:
            error(f"{rel}: destination.server es {servidor!r}; se esperaba "
                  f"{SERVIDOR_ESPERADO!r} mientras haya un solo clúster.")

        # El namespace lo crea Argo CD; si no, el repo tendría que declararlo
        # y necesitaría permisos cluster-scoped.
        opciones = (spec.get("syncPolicy") or {}).get("syncOptions") or []
        if "CreateNamespace=true" not in opciones:
            error(f"{rel}: falta CreateNamespace=true en syncOptions. Sin él "
                  f"el namespace no se crea y el repo no puede declararlo.")

        # Un workload solo puede crear un recurso cluster-scoped: Namespace,
        # y porque `CreateNamespace=true` lo exige (el primer sync falla sin
        # él). Cualquier otra entrada aquí abre permisos que nadie ha pedido.
        permitido = [{"group": "", "kind": "Namespace"}]
        whitelist = pspec.get("clusterResourceWhitelist")
        if whitelist != permitido:
            error(f"overlays/prod/projects/{proyecto}.yaml: clusterResourceWhitelist debe ser "
                  f"exactamente {permitido} (solo Namespace, que "
                  f"`CreateNamespace=true` necesita). Encontrado: {whitelist}")

    # --- AppProjects de workload sin Application: alta a medias -------------
    for nombre in proyectos:
        if nombre in PROYECTOS_DE_PLATAFORMA:
            continue
        if nombre not in workloads_con_app:
            error(f"overlays/prod/projects/{nombre}.yaml: AppProject sin Application en "
                  f"overlays/prod/apps/. El alta está a medias.")

    if errores:
        print(f"✗ {len(errores)} incoherencia(s):\n", file=sys.stderr)
        for e in errores:
            print(f"  - {e}", file=sys.stderr)
        return 1

    print(f"✓ {len(workloads_con_app)} workload(s) coherentes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

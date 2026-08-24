#!/usr/bin/env python3
"""Genera los dos ficheros de alta de un workload a partir de `plantillas/`.

    Uso:  python3 scripts/alta-workload.py <nombre> <repo-url> [opciones]

    Opciones:
      --arquetipo   stateless | batch | stateful   (por defecto: stateless)
      --descripcion una línea para el AppProject
      --grupo       grupo del proveedor de identidad que lo opera
      --dry-run     escribe a stdout en vez de crear ficheros

Lo que hace:
  1. copia `plantillas/workload-appproject.yaml`  -> overlays/prod/projects/<nombre>.yaml
  2. copia `plantillas/workload-application.yaml` -> overlays/prod/apps/<nombre>.yaml
  3. añade cada fichero a su `kustomization.yaml`
  4. ejecuta `validar-coherencia.py` sobre el resultado

Lo que NO hace, a propósito:
  - No habla con la API de GitHub/GitLab: no crea el repo, ni el deploy token,
    ni la credencial en el clúster. Eso lo hace una persona, y `credenciales.sh`
    la ayuda. Un script que crea repos y tokens es un portal interno con otro
    nombre, y este plano de control vale precisamente porque las decisiones que
    importan son visibles en un diff.
  - No autogenera nada que no puedas escribir a mano en dos minutos: el
    resultado es EXACTAMENTE la plantilla con los marcadores sustituidos, para
    que el diff del PR siga siendo lo que se revisa.

El AppProject generado hay que LEERLO antes de abrir el PR. Es el objeto que
define los límites de privilegio del workload; que lo haya escrito un script no
lo exime de revisión.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

RAIZ = pathlib.Path(__file__).resolve().parent.parent
PLANTILLAS = RAIZ / "plantillas"
DIR_PROYECTOS = RAIZ / "overlays" / "prod" / "projects"
DIR_APPS = RAIZ / "overlays" / "prod" / "apps"

ARQUETIPOS = ("stateless", "batch", "stateful")

# El nombre es a la vez nombre de AppProject, de Application, de namespace y de
# fichero. El más restrictivo de los cuatro es el namespace: RFC 1123.
RX_NOMBRE = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")

# Cierre del bloque de cabecera de la plantilla: son instrucciones de uso, no
# forman parte del manifiesto y no deben acabar en overlays/.
RX_SEPARADOR = re.compile(r"^# =+$")


def renderizar(plantilla: pathlib.Path, valores: dict[str, str]) -> str:
    lineas = plantilla.read_text(encoding="utf-8").splitlines(keepends=True)

    # Descartar la cabecera de uso: del primer separador al segundo, inclusive.
    separadores = [i for i, l in enumerate(lineas) if RX_SEPARADOR.match(l.rstrip())]
    if len(separadores) >= 2:
        lineas = lineas[separadores[1] + 1:]
    texto = "".join(lineas)

    for marcador, valor in valores.items():
        texto = texto.replace(marcador, valor)
    return texto


def anadir_a_kustomization(kustomization: pathlib.Path, entrada: str) -> bool:
    """Inserta `- <entrada>` en el bloque `resources:`, en orden alfabético.

    `platform.yaml` queda siempre el primero: no es un workload, es la
    plataforma, y leerlo arriba del todo dice eso sin necesidad de comentario.
    """
    lineas = kustomization.read_text(encoding="utf-8").splitlines()
    try:
        inicio = lineas.index("resources:")
    except ValueError:
        sys.exit(f"{kustomization}: no tiene bloque `resources:`")

    fin = inicio + 1
    while fin < len(lineas) and lineas[fin].startswith("  - "):
        fin += 1

    entradas = [l[4:].strip() for l in lineas[inicio + 1:fin]]
    if entrada in entradas:
        return False
    entradas.append(entrada)
    entradas.sort(key=lambda e: (e != "platform.yaml", e))

    lineas[inicio + 1:fin] = [f"  - {e}" for e in entradas]
    kustomization.write_text("\n".join(lineas) + "\n", encoding="utf-8")
    return True


def main() -> int:
    p = argparse.ArgumentParser(
        description="Da de alta un workload a partir de las plantillas.")
    p.add_argument("nombre", help="nombre del workload = AppProject = namespace")
    p.add_argument("repo_url", help="URL exacta del repo del workload, con .git")
    p.add_argument("--arquetipo", choices=ARQUETIPOS, default="stateless")
    p.add_argument("--descripcion", default=None)
    p.add_argument("--grupo", default=None)
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    nombre = args.nombre
    if not RX_NOMBRE.match(nombre):
        sys.exit(f"Nombre inválido: {nombre!r}. Debe ser un nombre de namespace "
                 f"válido (RFC 1123): minúsculas, dígitos y '-'.")
    if not args.repo_url.endswith(".git"):
        sys.exit(f"El repo debe terminar en '.git': {args.repo_url!r}. La "
                 f"credencial de Argo CD casa por URL EXACTA.")

    destino_proyecto = DIR_PROYECTOS / f"{nombre}.yaml"
    destino_app = DIR_APPS / f"{nombre}.yaml"
    for d in (destino_proyecto, destino_app):
        if d.exists() and not args.dry_run:
            sys.exit(f"Ya existe {d.relative_to(RAIZ)}. El alta ya está hecha, "
                     f"o el nombre está cogido.")

    valores = {
        "NOMBRE": nombre,
        "REPO_URL": args.repo_url,
        "ARQUETIPO": args.arquetipo,
        "DESCRIPCION": args.descripcion or f"{nombre}, confinado a su namespace homónimo.",
        "GRUPO": args.grupo or f"CAMBIAME/{nombre}",
    }

    proyecto = renderizar(PLANTILLAS / "workload-appproject.yaml", valores)
    app = renderizar(PLANTILLAS / "workload-application.yaml", valores)

    if args.dry_run:
        # El `---` no es decoración: sin él los dos manifiestos son un único
        # documento YAML con las claves duplicadas, y un parser se queda con el
        # último en silencio. CI valida esta salida, así que tiene que ser un
        # stream de dos documentos de verdad.
        print(f"---\n# overlays/prod/projects/{nombre}.yaml")
        print(proyecto)
        print(f"---\n# overlays/prod/apps/{nombre}.yaml")
        print(app)
        return 0

    destino_proyecto.write_text(proyecto, encoding="utf-8")
    destino_app.write_text(app, encoding="utf-8")
    anadir_a_kustomization(DIR_PROYECTOS / "kustomization.yaml", f"{nombre}.yaml")
    anadir_a_kustomization(DIR_APPS / "kustomization.yaml", f"{nombre}.yaml")

    print(f"✓ overlays/prod/projects/{nombre}.yaml")
    print(f"✓ overlays/prod/apps/{nombre}.yaml")
    print("✓ ambos añadidos a su kustomization.yaml\n")

    validador = RAIZ / "scripts" / "validar-coherencia.py"
    codigo = subprocess.run([sys.executable, str(validador)]).returncode

    print(f"""
Queda por hacer, y no lo hace este script:

  1. LEER `overlays/prod/projects/{nombre}.yaml`. Define los límites de
     privilegio del workload; que lo haya escrito un script no lo exime de
     revisión.
     Si no pasaste `--grupo`, el validador de arriba está fallando a propósito:
     queda un `CAMBIAME/{nombre}` que hay que sustituir por el grupo real. Es
     la única decisión que el script no puede tomar por ti.
  2. Crear el repo del workload con un `overlays/prod/kustomization.yaml`
     dentro. Ese path es lo único que este plano de control le impone.
  3. Añadir la credencial de lectura de ese repo:
       ./scripts/credenciales.sh anadir
  4. Si el workload necesita un Secret PARA ARRANCAR —un Job, o una imagen de
     registry privado— créalo ANTES de mergear. Ver docs/arquetipos.md.
  5. Probarlo en el laboratorio antes de producción:
       ./lab/levantar.sh
  6. Abrir el PR con los dos ficheros y revisar el diff renderizado que
     publica CI.
""")
    return codigo


if __name__ == "__main__":
    sys.exit(main())

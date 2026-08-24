# Argo CD Labs — un plano de control GitOps multi-tenant

Este repositorio es un **plano de control de Argo CD**: define qué workloads
existen en un clúster Kubernetes, de qué repositorio Git se lee cada uno y en
qué namespace puede escribir. Nada más, y eso es lo que lo hace fiable.

Es la versión pública y desidentificada de un plano de control que gestiona
infraestructura real sobre un clúster bare-metal en producción. La
configuración de los workloads reales no está aquí; el plano de control sí,
entero, con sus decisiones y sus renuncias documentadas.

**Trae un laboratorio reproducible**: `./lab/levantar.sh` levanta este mismo
plano de control en un `kind` de tu portátil, con Gitea haciendo de forja, de
cero a `root-app`. No es una versión simplificada — ejecuta el mismo
`scripts/install.sh` que se ejecutaría en producción.

Aquí no hay Dockerfiles, ni lógica de CI de aplicación, ni manifiestos de
workload. Los manifiestos de cada workload viven en **su propio repositorio**;
este solo declara la frontera y el enlace.

Es agnóstico al contenido —un workload puede traer Kustomize, Helm o YAML
plano— y agnóstico al tipo de carga: una API, un job de entrenamiento, un
pipeline o una herramienta interna se dan de alta igual. Lo que cambia entre
ellos está en [docs/arquetipos.md](docs/arquetipos.md).

## Estructura del repositorio

| Carpeta | Qué contiene |
|---|---|
| `overlays/prod/` | **Todo lo que se aplica al clúster.** `kustomization.yaml` es lo que reconcilia la `root-app` |
| `overlays/prod/projects/<nombre>.yaml` | Un **AppProject** por workload — la frontera de aislamiento |
| `overlays/prod/apps/<nombre>.yaml` | Una **Application** por workload — el enlace con su repositorio |
| `overlays/prod/argo-cd.yaml` | Argo CD instalándose a sí mismo |
| `config/argo-cd/values.yaml` | Configuración de Argo CD — fuente **única**, la leen el bootstrap y el propio Argo CD |
| `bootstrap/` | Lo que siembra el arranque: los AppProject y la `root-app` |
| `plantillas/` | Los dos ficheros neutros de los que se parte para dar de alta un workload |
| `scripts/` | `install.sh`, el alta de workloads y las herramientas de validación, render y credenciales |
| `lab/` | **Laboratorio en kind.** Desechable, aislado, no llega a producción |
| `docs/` | Documentación y flujos operativos |
| `AGENTS.md` | Instrucciones para asistentes de IA que trabajen sobre este repo: el modelo, las decisiones tomadas y lo que **no** deben proponer |

Dos reglas de colocación, que responden dónde va cualquier fichero nuevo:

1. **Lo que se aplica al clúster vive bajo `overlays/<entorno>/`**, y ese
   directorio no referencia nada por encima de sí mismo.
2. **Lo ejecutable vive en `scripts/`.** Ningún manifiesto convive con un script.

`config/` no se llama `base/` porque no es una base de Kustomize: nada la
parchea, y Kustomize ni siquiera lee lo que hay dentro.

El modelo es **1 workload = 1 namespace = 1 AppProject = 1 Application = 1 repo**.
Dar de alta un workload son dos ficheros aquí y un Pull Request:

```bash
python3 scripts/alta-workload.py mi-workload \
  https://github.com/mi-org/workload-mi-workload.git \
  --arquetipo stateless --grupo mi-org/mi-equipo
```

Genera los dos ficheros a partir de `plantillas/`, los añade a su
`kustomization.yaml` y valida la coherencia. No habla con la API de la forja:
crear el repo, el token y la credencial son decisiones de una persona.

### Qué cuenta como "un workload"

La unidad es el **límite de despliegue y de propiedad**, no el binario ni el
grafo de llamadas:

> **Si dos componentes se despliegan y fallan juntos, son un workload.**

Por eso `wiki-demo` —una herramienta interna y la base de datos que solo ella
usa— es **uno**: un namespace, un AppProject, una Application y un repo con
subcarpetas por componente.

Lo que la regla **no** dice es que dos workloads no puedan hablarse. El
AppProject restringe de qué repo se lee y en qué namespace se escribe; no
controla el tráfico de red, y este repo no despliega `NetworkPolicy`. Un
servicio compartido es su propio workload y otros lo consumen por red:
[docs/arquetipos.md §4](docs/arquetipos.md).

## Cómo iniciar (bootstrapping)

Requisitos: `kubectl`, `helm`, acceso al clúster (`kubeconfig` configurado) y una
**credencial de solo lectura** sobre **este** repo — un deploy token, un deploy
key o un PAT con permiso de lectura, según la forja. Cada repo lleva la suya;
las de los workloads se añaden después.

> ¿Solo quieres verlo funcionar? No hace falta ningún clúster ni ninguna
> credencial: `./lab/levantar.sh` monta todo en un `kind` local. Empieza por
> [lab/README.md](lab/README.md).

```bash
./scripts/install.sh
```

Es **el único procedimiento imperativo del ciclo normal**. Pide confirmación del
contexto y encadena cuatro fases: crear el namespace y la credencial del repo,
instalar el motor con `helm template`, esperar a que los CRDs queden
establecidos, y aplicar los AppProjects y la `root-app`. Es idempotente.

Una vez desplegado:
- Argo CD queda instalado en el clúster.
- Argo CD detecta el objeto `root-app` y, a partir de ese momento, **se gestiona a sí mismo** leyendo desde `overlays/prod`.
- Cualquier cambio posterior se hace mediante **Pull Request** a este repositorio.

Argo CD se instala desde su **chart oficial** (`argoproj/argo-helm`), no desde el
`install.yaml` de upstream: configurar SSO, RBAC o réplicas son valores en
`config/argo-cd/values.yaml` en lugar de parches contra un manifiesto de 20.000
líneas.

## Acceso a las UIs

### En el laboratorio (kind)

Todo se sirve por el puerto **8088** del host, que `lab/kind.yaml` mapea al
Ingress del clúster. `./lab/levantar.sh` imprime estos mismos enlaces al
terminar, con la contraseña ya resuelta.

| Servicio | URL | Credenciales |
|---|---|---|
| **Argo CD** | http://argocd.localhost:8088 | `admin` / `admin1234` |
| **Gitea** (hace de forja) | http://gitea.localhost:8088/demo | `demo` / `demo1234` |
| **Cada workload** | `http://<workload>.localhost:8088` | — |

Los workloads de ejemplo, con el laboratorio levantado, quedan en
http://api-demo.localhost:8088 y http://wiki-demo.localhost:8088. **Un
hostname por workload**, no uno compartido: si dos publicaran el mismo host, el
Ingress se lo quedaría uno y el otro fallaría en silencio.

`*.localhost` resuelve a `127.0.0.1` en la práctica totalidad de sistemas y
navegadores, así que no hace falta tocar `/etc/hosts`.

La contraseña del laboratorio es **fija y no cambia entre ejecuciones**, para no
tener que ir a buscarla cada vez. Para usar otra:

```bash
ARGOCD_PASS='la-que-quieras' ./lab/levantar.sh
```

`levantar.sh` la inyecta como hash bcrypt **en el espejo**, no en el repo:
`config/argo-cd/values.yaml` no contiene ninguna contraseña, porque es el
fichero que se aplica en producción.

### En un clúster real

El host de la UI lo fija **`global.domain` en `config/argo-cd/values.yaml`**, y
tiene que coincidir con `configs.cm.url` del mismo fichero — están en el mismo
sitio a propósito, porque desincronizarlos rompe las redirecciones de login. El
valor que trae el repo es un ejemplo con `nip.io`; cámbialo por el tuyo en el
mismo PR:

```yaml
global:
  domain: argocd.<tu-dominio>        # config/argo-cd/values.yaml
configs:
  cm:
    url: http://argocd.<tu-dominio>  # la misma, exacta
```

```bash
# Contraseña inicial de admin, tras el primer arranque
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

> ⚠️ **Hoy es `http://`, sin TLS y sin SSO.** La contraseña de `admin` viaja en
> claro. Es aceptable en una red interna de confianza y no lo es en ninguna otra:
> antes de exponer esta UI, monta TLS y SSO. Quién puede entrar, las tres fases
> de acceso (solo `admin` → cuentas locales → SSO) y cómo se cambia la
> contraseña inicial: [docs/operar.md](docs/operar.md), "Entrar a la UI".

Si la UI no carga, el diagnóstico paso a paso está en
[docs/operar.md](docs/operar.md), "Si la UI no carga".

## Comprobaciones antes de abrir un PR

```bash
python3 scripts/validar-coherencia.py      # los dos ficheros del workload casan
./scripts/render.sh /tmp/render            # qué objetos cambian de verdad
```

Las dos las ejecuta CI en cada PR (`.github/workflows/validar.yml`). La segunda es la que
sustituye al antiguo ritual de "primer sync manual y reviso el diff en la UI
durante una semana": el PR enseña Kustomize y una versión de chart, no los
objetos que acaban en el apiserver, y esa revisión se hace mejor **antes** del
merge que pagando una semana sin `selfHeal`.

## Operar

Todas las tareas del día a día —entrar a la UI, dar de alta un workload, crear
un secreto, rotar una credencial, qué mirar cuando algo falla— están en
**[docs/operar.md](docs/operar.md)**. Empieza por ahí si vas a operar esto.

Los tres comandos que más se usan:

```bash
./scripts/credenciales.sh estado    # ¿tienen credencial todos los repos?
./scripts/credenciales.sh probar    # ¿consigue Argo CD leerlos?
./scripts/render.sh /tmp/render     # ¿qué cambia de verdad en el clúster?
```

## Estado del proyecto

Validado sobre un clúster `kind` limpio:

- ✅ `install.sh` de cero a `root-app`, y reejecutable sin efectos secundarios
- ✅ Argo CD operativo
- ✅ Autogestión vía chart: Argo CD renderiza su propio chart desde el clúster
- ✅ Frontera `destinations`: una Application que apunta fuera de su namespace es rechazada con `InvalidSpecError`
- ✅ Frontera `sourceRepos`: una Application que apunta a otro repo es rechazada igual

Cosas que hay que saber para operarlo, no defectos:

- ⚠️ **Sin notificaciones.** `notifications.enabled: false`: nadie te avisa de un sync fallido. Mirar es parte de la operación.
- ⚠️ **Sin SSO y sin TLS.** La UI está en `http://argocd.192-168-1-100.nip.io` con la cuenta `admin`, y la contraseña viaja en claro. Añadir más personas sin SSO son cuentas locales; los roles ya están definidos para que eso no obligue a rehacer nada. Ver [docs/operar.md](docs/operar.md), "Quién puede entrar".
- ⚠️ **Sin `NetworkPolicy`, `ResourceQuota` ni `LimitRange`.** El aislamiento de este repo es de **tiempo de despliegue**; en runtime no hay restricción. Cada workload se autolimita si quiere.
- ⚠️ **El AppProject es una frontera dentro de Argo CD, no de RBAC de Kubernetes**: el controller aplica con cluster-admin.
- ⚠️ **CA de la red corporativa en los nodos.** Si los nodos no confían en la CA que intercepta TLS, los `docker pull` fallan con `x509: certificate signed by unknown authority`. Ocurre en containerd aunque el host sí confíe.

Fuera del alcance de este repo, **a propósito y con motivo**:

| Fuera | Por qué, y qué lo metería dentro |
|---|---|
| **ApplicationSet** | Genera `Application`, no `AppProject`, y el AppProject no se autogenera a propósito: ahorraría un fichero de dos. Entraría con ~8-10 workloads del **mismo** arquetipo, o con multi-clúster — y entonces uno por arquetipo, nunca uno global |
| **Cifrado de secretos** (SOPS, Sealed Secrets) | El modelo manual basta mientras un workload tolere arrancar sin su secreto. Deja de bastar en cuanto reconstruir el clúster desde Git sea un requisito. Ver [docs/arquetipos.md §5](docs/arquetipos.md) |
| **Image Updater, Kargo** | La CI del repo del workload commitea el tag nuevo a su propio repo. Entrarían con promoción entre entornos o rollback por versión |
| **Multi-clúster** | `validar-coherencia.py` afirma hoy un solo `destination.server`. Un segundo entorno sería `overlays/staging/`, que la estructura ya admite |
| **Backup y restauración** | Lo lleva Velero, a nivel de clúster |
| **Alta disponibilidad, source hydrator** | No han hecho falta |

Versiones ancladas: chart `argo-cd` **10.2.2** (Argo CD **v3.4.6**). El chart va
por detrás de las releases de upstream; se sigue su `appVersion` y no se fuerza
el tag de imagen. La versión aparece en dos sitios —`scripts/install.sh`
y `overlays/prod/argo-cd.yaml`— y CI comprueba que no diverjan.

## Documentación

* [**Operar**](docs/operar.md): el runbook. Tareas concretas, paso a paso. **Empieza por aquí si vas a usarlo.**
* [Aislamiento multi-workload](docs/aislamiento-multi-workload.md): el modelo y por qué está montado así. Empieza por aquí si vas a modificarlo.
* [**Arquetipos de workload**](docs/arquetipos.md): qué rompe según el tipo de carga —jobs, servicios, workloads con estado, servicios compartidos— y cómo se resuelve. Empieza por aquí si vas a dar de alta algo que no sea un servicio corriente.
* [Gestión de secretos](docs/gestion-secretos-lite.md): las dos capas de secretos y la regla de durabilidad.
* [Instalación declarativa (App of Apps)](docs/instalacion-declarativa-argocd.md): arquitectura de arranque y orden de reconciliación.
* [**Laboratorio en kind**](lab/README.md): levanta este mismo plano de control en un clúster desechable, con Gitea haciendo de forja. Para aprender y para probar cambios antes de mergearlos.

## Gestión de secretos

**No hay cifrado de secretos en Git.** Simplificación deliberada de la primera
iteración: sin Sealed Secrets, sin `kubeseal`, sin SOPS.

Los `Secret` de un workload se crean **directamente en su namespace con
`kubectl`, tras el primer sync**, y no se declaran en ningún repositorio. Como
Argo CD nunca los ve declarados, no los gestiona ni los poda: no hacen falta
`ignoreDifferences` ni exclusiones.

> **Ningún valor de secreto se commitea en ningún repositorio, ni en claro ni
> cifrado.** El valor vive en el clúster y en el almacén de contraseñas del
> equipo, y en ningún tercer sitio — y tiene que estar en el almacén *antes* de
> crearlo en el clúster.

Procedimiento, comandos exactos y la separación respecto a los secretos de
operación de Argo CD (las credenciales `repo-*` y `argocd-secret`, de otra capa
y no cambian): [docs/gestion-secretos-lite.md](docs/gestion-secretos-lite.md).

## Licencia

Copyright 2026 Mateo Gil.

Distribuido bajo la **Licencia Apache 2.0**. El texto completo está en
[LICENSE](LICENSE); el resumen operativo es que puedes usarlo, modificarlo y
redistribuirlo, incluso comercialmente, conservando el aviso de copyright y
dejando constancia de los cambios.

Se publica **tal cual y sin garantía**. Es un plano de control que gestiona
infraestructura real, no una plantilla genérica: si lo llevas a un clúster tuyo,
levántalo antes en el laboratorio y lee
[docs/aislamiento-multi-workload.md](docs/aislamiento-multi-workload.md) para
entender qué aísla y —más importante— qué no.

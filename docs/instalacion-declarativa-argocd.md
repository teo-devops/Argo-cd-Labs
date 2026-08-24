# Instalación declarativa de Argo CD (App of Apps)

Arquitectura de inicialización del clúster `gitops-prod`. El objetivo es un
despliegue declarativo: un script para encender el motor una sola vez, y a
partir de ahí todo llega por reconciliación desde Git.

---

## 1. Estructura

```text
.
├── config/
│   └── argo-cd/values.yaml           # config de Argo CD: fuente ÚNICA
├── overlays/
│   └── prod/                         # <- TODO lo que se aplica al clúster
│       ├── kustomization.yaml        #    el punto de entrada de la root-app
│       ├── argo-cd.yaml              #    Argo CD instalándose a sí mismo (wave -2)
│       ├── projects/                 #    un AppProject por workload (wave 0)
│       └── apps/                     #    una Application por workload (wave 1)
├── bootstrap/
│   ├── kustomization.yaml            # AppProjects + root-app (fase 3)
│   └── root-app.yaml
└── scripts/
    ├── install.sh                    # el arranque, en cuatro fases (0-3)
    ├── validar-coherencia.py
    ├── render.sh
    └── credenciales.sh
```

Dos reglas de colocación, y explican dónde va cada fichero nuevo:

1. **Todo lo que se aplica al clúster vive bajo `overlays/<entorno>/`**, y ese
   directorio no referencia nada por encima de sí mismo. El contenido de un
   entorno se lee de un solo sitio.
2. **Todo lo ejecutable vive en `scripts/`.** Ningún manifiesto convive con un
   script.

`config/` no se llama `base/` a propósito: en Kustomize, una *base* es algo que
un overlay parchea, y aquí no hay tal cosa. Solo contiene los valores de Helm
del motor, que Kustomize ni siquiera lee — los consumen `helm template` y la
Application multi-source.

`overlays/prod/kustomization.yaml` es la pieza que cierra el circuito: la
root-app apunta a ese directorio, y ese directorio agrega el motor, los
AppProjects y las Applications. Sin ese fichero la root-app renderiza vacío y
queda *Synced* gestionando cero recursos — un fallo silencioso, porque el
estado en la UI es verde.

---

## 2. Argo CD se instala con su chart oficial

`overlays/prod/argo-cd.yaml` es una `Application` **multi-source**:

```yaml
sources:
  - repoURL: https://argoproj.github.io/argo-helm
    chart: argo-cd
    targetRevision: 10.2.2          # -> Argo CD v3.4.6
    helm:
      valueFiles:
        - $values/config/argo-cd/values.yaml
  - repoURL: 'https://github.com/teo-devops/Argo-cd-Labs.git'
    targetRevision: main
    ref: values
```

La segunda fuente no despliega nada: existe solo para que `$values` resuelva a
este repo. Es lo que permite que **el bootstrap y el estado estacionario lean el
mismo fichero de valores** en lugar de mantener dos copias divergentes.

### Por qué el chart y no el `install.yaml`

Configurar Argo CD con el manifiesto de upstream obliga a parchear con JSON6902
contra un fichero de ~20.000 líneas. Con el chart, lo mismo son valores:

```yaml
configs:
  rbac:
    policy.default: ''
    scopes: "[groups]"
  cm:
    dex.config: |
      connectors: [...]
controller:
  replicas: 2
```

Esa diferencia se nota justo cuando hace falta: SSO, RBAC, HA e ingress son
precisamente lo que hay que configurar en producción.

**Contrapartida real:** el chart va por detrás de las releases de Argo CD. El
chart 10.2.2 trae Argo CD v3.4.6, mientras que upstream ya publicó v3.5.0. Se
sigue el `appVersion` del chart y no se fuerza el tag de imagen: mezclar
manifiestos de una versión con binarios de otra es una fuente de fallos sutiles.

### Versión anclada, nunca flotante

`targetRevision: 10.2.2` es un valor fijo. Con un rango o un comodín, el mismo
commit del repo produciría despliegues distintos según el día y —peor— una
release nueva se autoaplicaría sin PR sobre el propio controller que ejecuta el
sync. Subir de versión es editar esa línea y abrir un PR.

### `prune: false` sobre el motor

```yaml
syncPolicy:
  automated:
    selfHeal: true    # revierte cualquier `kubectl edit`
    prune: false      # pero nunca borra
```

Podar el motor debe ser un acto humano deliberado. Un render que salga corto no
puede llevarse por delante al reconciliador que tendría que arreglarlo.

Esta política diferenciada solo es posible porque el motor tiene su propia
`Application`. Cuando todo colgaba de la root-app había que elegir una única
política para el motor y los workloads, y cualquiera de las dos era incorrecta
para la mitad del árbol.

### El `prune: false` no protege del camino que importa: por eso, sin finalizer

Hay un agujero en ese razonamiento que conviene tener explícito. La `root-app`
lleva `prune: true`, y **uno de los objetos que poda es esta misma
Application**. Si un cambio en `overlays/prod/kustomization.yaml` dejase de
emitir `argo-cd.yaml`, la root-app la borraría — y con el finalizer
`resources-finalizer.argocd.argoproj.io`, ese borrado **arrastraría en cascada
toda la instalación de Argo CD**.

El `prune: false` de arriba no interviene en ese camino: no se poda el
contenido, **se borra el dueño**. Y `PruneLast=true` cambia el orden, no el
desenlace.

Por eso `overlays/prod/argo-cd.yaml` es la única Application de este
repo **sin finalizer**. Con esa quita, el mismo accidente deja los objetos de
Argo CD huérfanos y funcionando: se recupera reponiendo el fichero, no
reinstalando el clúster. Es el fallo seguro que se buscaba desde el principio.

---

## 3. Sin gestor de secretos en el bootstrap

El motor GitOps que instala este bootstrap es **solo Argo CD**. No hay Sealed
Secrets, ni SOPS, ni External Secrets: es una simplificación deliberada de la
primera iteración.

La consecuencia para el arranque es que **el bootstrap no instala ningún
componente adicional**: `install.sh` levanta Argo CD y nada más.

Los secretos se reparten en dos capas que no se gestionan igual:

- **Operación de Argo CD** (`repo-*`, `argocd-secret`): se crean en el clúster.
  Una credencial por repo: la del repo de plataforma la crea la fase 0 de
  `install.sh`, y la de cada workload se añade después con
  `scripts/credenciales.sh anadir`. No pueden estar en Git ni cifradas, porque
  Argo CD las necesita para clonar el repo donde estaría el fichero.
- **Workload**: se crean con `kubectl` en el namespace del workload, después de
  su primer sync, y nunca se declaran en ningún repositorio.

Procedimiento completo, comandos exactos y la regla de durabilidad en
[gestion-secretos-lite.md](gestion-secretos-lite.md).

---

## 4. Bootstrapping

```bash
./scripts/install.sh
```

El script pide confirmación del contexto de `kubectl` y ejecuta cuatro fases,
numeradas 0 a 3. Es
idempotente y se ejecuta **una vez en la vida del clúster** —salvo en los
ensayos de recuperación, que es la única forma de saber si funciona de verdad.

Pide la credencial de lectura por consola, o la toma de `GIT_USER` y
`GIT_TOKEN` si están en el entorno.

| Fase | Qué hace | Por qué está separada |
|---|---|---|
| 0 | Namespace `argocd` y la credencial del repo de plataforma | Dependencia circular: ver abajo |
| 1 | `helm template ... \| kubectl apply --server-side` | Instala el motor cuando Argo CD todavía no existe |
| 2 | `kubectl wait --for=condition=Established` | Los CRDs deben estar establecidos antes de crear un CR |
| 3 | `kubectl apply -k bootstrap` | AppProjects y root-app: enciende la reconciliación |

**Por qué la fase 0 y por qué esa credencial no puede estar en Git:** Argo CD
necesita la credencial para clonar el repo **donde estaría el fichero que la
contiene**. Ningún esquema de cifrado en Git resolvería esa dependencia
circular, y por eso lo crea el bootstrap y no la reconciliación.

El bootstrap crea **solo esa**: es la única que necesita para arrancar. La
credencial de cada workload se añade cuando ese workload existe, con
`scripts/credenciales.sh anadir`.

Sin ella, el síntoma es traicionero: la root-app se queda en `sync: Unknown` con
`[ComparisonError] failed to list refs` **y `health: Healthy`**. Mirar solo la
columna de health hace creer que el clúster está bien.

**Por qué `helm template | kubectl apply` y no `helm install`:** con `helm
install`, el estado del release queda guardado en el clúster y Helm se considera
dueño de esos objetos. En la fase 3 el dueño pasa a ser Argo CD. Dos gestores
compitiendo por los mismos recursos producen conflictos difíciles de
diagnosticar. Con `helm template` solo se materializan manifiestos, sin dejar
release.

**Por qué `--server-side` es obligatorio:** los CRDs de Argo CD superan el
límite de 262144 bytes de la anotación
`kubectl.kubernetes.io/last-applied-configuration` que usa el apply clásico. Sin
la bandera, el comando falla con *"metadata.annotations: Too long"*.

**Por qué la fase 3 incluye los AppProject:** la root-app declara
`project: platform`. Una `Application` que referencia un proyecto inexistente
queda en error permanente. Al sincronizar, la root-app toma posesión de esos
mismos objetos vía `overlays/prod` → `overlays/prod/projects/`; el bootstrap solo los adelanta.

A partir de la fase 3 no se vuelve a ejecutar ningún comando.

---

## 5. Orden de reconciliación

| Wave | Qué |
|---|---|
| -2 | La Application de Argo CD y los CRDs |
| 0 | AppProjects (`overlays/prod/projects/`) |
| 1 | Applications de workload (`overlays/prod/apps/`) |

Las sync-waves fijan el orden con independencia del orden de las listas en los
`kustomization.yaml`. Argo CD espera a que cada wave esté *Healthy* antes de
lanzar la siguiente.

> **Consecuencia que conviene conocer antes de subir de versión.** Una
> `Application` hija tiene health propio, y la del motor está en la wave `-2`.
> Mientras esté `Degraded` o `Unknown` —por ejemplo porque el chart nuevo no
> renderiza, o porque falta la credencial del repo— **las waves 0 y 1 no llegan
> a crearse**. No es que "el motor esté raro": es que nada del árbol avanza,
> incluidos workloads que no tienen nada que ver con el cambio.
>
> Por eso un bump de `targetRevision` del chart se revisa con el diff
> renderizado (`scripts/render.sh`) antes de mergear, y no después.

---

## 6. Traspasos de propiedad: la trampa de reorganizar el árbol

Regla general que hay que tener presente cada vez que se mueva algo entre
`Application`, no solo en el caso histórico que la motivó: **cuando un objeto
cambia de Application dueña, hay una ventana en la que la vieja deja de
reclamarlo y la nueva todavía no lo ha adoptado.** Si la vieja tiene `prune`
activo, lo borra en esa ventana.

El caso que lo hizo evidente aquí fue mover los ~50 objetos de Argo CD desde la
`root-app` —que los renderizaba directamente— a su propia `Application`.

Procedimiento en un clúster vivo: poner `prune: false` en la Application que
cede la propiedad, aplicar el cambio, **verificar que la adopción ha ocurrido**
(los objetos aparecen bajo la nueva Application) y solo entonces restaurar la
poda.

En un clúster nuevo el problema no existe: `install.sh` instala directamente la
versión final.

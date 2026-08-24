# Laboratorio en kind

> ## ⚠️ Esto NO es producción y NO forma parte del despliegue de `gitops-prod`.
>
> Nada de este directorio llega al clúster real. La `root-app` de producción
> solo lee `overlays/prod/`, y ahí no se referencia `lab/` en ningún sitio.

Un clúster desechable donde el plano de control **real** de este repo se
despliega contra un Gitea local que hace de forja. Sirve para dos cosas:

- **Aprender GitOps** viendo el ciclo completo, sin tocar producción.
- **Probar un cambio del plano de control** —un bump del chart, un valor nuevo,
  un workload dado de alta— antes de mergearlo.

```bash
./lab/levantar.sh     # ~5 min la primera vez
./lab/destruir.sh
```

---

## Lo que hace que esto sirva de algo

El laboratorio **espeja este repo tal cual** y solo reescribe URLs:

| Producción | Laboratorio |
|---|---|
| El repo de plataforma en la forja | `gitea.gitea.svc:3000/demo/plano-control.git` |
| El repo de cada workload | `gitea.gitea.svc:3000/demo/<workload>.git` |
| `argocd.192-168-1-100.nip.io` | `argocd.localhost` |
| `argoproj.github.io/argo-helm` | `charts.charts.svc` (solo en `overlays/`) |
| Contraseña de admin generada por el chart | Una **fija**, inyectada en el espejo |

Esa última es la única reescritura que no es una URL, y merece explicación:
en producción la contraseña inicial la genera `argocd-server` en
`argocd-initial-admin-secret` y se cambia tras el primer login. En el
laboratorio eso significa una contraseña distinta cada vez que levantas el
clúster, así que `levantar.sh` calcula un hash bcrypt y lo inyecta como
`configs.secret.argocdServerAdminPassword` **en el espejo**.

**En `config/argo-cd/values.yaml` no hay ninguna contraseña, ni la habrá**: ese
fichero es el que se aplica en producción y este repo es público.

**El laboratorio no conoce ningún workload de antemano.** Los descubre leyendo
`overlays/prod/apps/` del espejo: por cada Application crea su repo en Gitea, lo
siembra, reescribe su URL y le añade su credencial. Si mañana el plano de
control declara otro workload, aparece aquí sin tocar nada de `lab/`.

**Ni siquiera conoce su tipo.** Qué contenido siembra en cada repo lo dice la
propia Application, en la anotación `argo-cd-labs.dev/arquetipo`; el laboratorio
busca la semilla correspondiente en `lab/workload/seeds/` y usa `stateless` si
la anotación falta. Añadir un arquetipo nuevo es un directorio más ahí, y
`validar-coherencia.py` deriva de ese directorio los valores que acepta — así la
lista y las semillas no pueden divergir.

Todo lo demás —`config/argo-cd/values.yaml`, los AppProject, las Applications,
`scripts/install.sh`— es **byte a byte** lo que se aplicaría en `gitops-prod`.
El laboratorio no ejecuta una versión simplificada del bootstrap: ejecuta el
bootstrap.

De ahí su valor: **si el laboratorio arranca, el plano de control es correcto; si
falla, habría fallado igual en producción.** Así se encontró que
`CreateNamespace=true` no esquiva el `clusterResourceWhitelist`.

Para que el espejo no se convierta en una copia divergente, `levantar.sh`
ejecuta `validar-coherencia.py` **sobre el espejo** antes de publicarlo.

---

## Qué levanta

| | |
|---|---|
| **Argo CD** | http://argocd.localhost:8088 — `admin` / `admin1234` (fija; `ARGOCD_PASS='otra' ./lab/levantar.sh` la cambia) |
| **Gitea** | http://gitea.localhost:8088/demo — `demo` / `demo1234` |
| **Workloads** | http://&lt;workload&gt;.localhost:8088 — uno por cada workload que publique HTTP |

Un hostname por workload, y no uno compartido: dos workloads del mismo
arquetipo con el mismo host harían que el Ingress se lo quedase uno y el otro
fallase en silencio. `levantar.sh` reescribe el host de la semilla antes de
sembrar.

Repos en Gitea:

- **`plano-control`** — el espejo de este repo. Lo lee la `root-app`.
- **Uno por workload** — hacen de repo de workload. Cada uno se siembra con la
  semilla de **su arquetipo**. **No reproducen lo que ese workload despliega en
  producción**, solo su forma y las propiedades que hay que poder probar:

  | Semilla | Qué monta | Qué te deja probar |
  |---|---|---|
  | `stateless` | Deployment + Service + Ingress | El ciclo completo y `selfHeal` |
  | `stateful` | PVC + Deployment + Service + Ingress | Que el volumen sobrevive al pod, y `Prune=false` |
  | `batch` | Job con `Replace=true` | Que un Job es inmutable, y que borrarlo con `selfHeal` lo re-ejecuta |

  Qué rompe en cada arquetipo y por qué: [docs/arquetipos.md](../docs/arquetipos.md).

El árbol que verás en Argo CD es el de producción:

```
root-app                 (lee plano-control)
├── argo-cd              (el motor, gestionándose a sí mismo)
├── AppProject platform
├── AppProject <workload>
└── <workload>           (lee su repo) → lo que traiga su arquetipo
```

---

## El ejercicio

1. Abre **Gitea** → el repo de cualquier workload → `overlays/prod/index.html`.
2. Edita: cambia `<h1>v1</h1>` por `<h1>v2</h1>`. Commitea.
3. En **Argo CD** → esa Application → **REFRESH**. Pasa a `OutOfSync`; en
   **DIFF** ves exactamente qué cambia.
4. Espera o pulsa **SYNC**. Recarga http://&lt;workload&gt;.localhost:8088 → pone `v2`.

Nunca tocaste el clúster. Solo Git.

**Prueba también `selfHeal`:**

```bash
kubectl --context kind-gitops-lab -n <workload> scale deploy/web --replicas=3
```

En segundos vuelve a 1. Git manda, y lo que hagas a mano se revierte.

**Prueba un arquetipo que no esté declarado.** Da de alta un workload nuevo y
vuelve a levantar; no hay que tocar nada de `lab/`:

```bash
python3 scripts/alta-workload.py mi-job \
  https://github.com/teo-devops/workload-mi-job.git \
  --arquetipo batch --grupo teo-devops/mi-equipo
./lab/levantar.sh
```

Luego borra el Job a mano y mira lo que pasa:

```bash
kubectl --context kind-gitops-lab -n mi-job delete job trabajo
```

Vuelve a correr. Con `selfHeal`, borrar un recurso declarado es pedir que se
recree — en un Deployment eso es lo que quieres; en un entrenamiento de un
modelo, no. Es más barato descubrirlo aquí.

---

## Por qué está en `lab/` y no en `overlays/kind/`

Sería lo natural en la estructura, y por eso mismo sería la trampa: parecería un
entorno hermano de `overlays/prod/`. No lo es. Tres consecuencias prácticas de
tenerlo fuera:

1. `overlays/prod/kustomization.yaml` nunca lo referencia, así que **no puede
   llegar a producción** por reconciliación.
2. `validar-coherencia.py` solo inspecciona `overlays/prod/`. Si el laboratorio
   viviera dentro, sus objetos de mentira tendrían que cumplir las invariantes
   de producción o habría que meter excepciones en el validador — que es por
   donde se cuelan las confusiones.
3. Un `grep lab/` basta para saber si algo es de juguete.

**La salvaguarda que de verdad importa** está en `levantar.sh`: aborta si el
contexto de `kubectl` no es `kind-gitops-lab`. Es lo único que separa un
laboratorio de un accidente.

---

## Salvedades

- `lab/workload/seeds/` contiene manifiestos de aplicación, y este repo declara
  no tenerlos. Es deliberado: son **datos de siembra de un clúster desechable**,
  no workloads de producción. Vivir en `lab/` es lo que lo hace inequívoco.
- **El arquetipo `stateless` con HPA no es testeable aquí**: kind no trae
  `metrics-server`, así que el autoscaler nunca escala y la pelea entre HPA y
  `selfHeal` que describe [docs/arquetipos.md §1.1](../docs/arquetipos.md) no se
  reproduce. Es la única propiedad de un arquetipo que hoy no se puede probar en
  el laboratorio; arreglarlo es instalar `metrics-server` en `levantar.sh`, y no
  se ha hecho porque todavía no ha hecho falta.
- Gitea usa SQLite sobre un `emptyDir`: se pierde con el clúster, a propósito.
- Las contraseñas (`demo1234`) están en claro en el script. Es un laboratorio
  local sin datos; que sean triviales es intencionado.
- `ingress-nginx` se descarga en cada `levantar.sh` (hace falta red la primera
  vez). Se le quitan los digests de las imágenes porque `kind load` casa por
  tag, no por digest.
- **El chart de Argo CD se sirve desde dentro del clúster** (`lab/plataforma/charts.yaml`).
  `levantar.sh` lo descarga en el host y lo copia a un nginx. Sin eso, en una red
  que intercepte TLS el repo-server no puede bajarlo y el motor se queda en
  `Unknown` con un `x509: certificate signed by unknown authority`. La forma de
  la Application no cambia —`repoURL` + `chart` + `targetRevision`—: solo la URL.
  `scripts/install.sh` queda fuera de esa reescritura porque corre en el host,
  donde el Service del clúster no resuelve.
- Si levantas este laboratorio **con otro clúster kind en marcha**, sube el
  límite de inotify o `kube-proxy` entrará en CrashLoopBackOff con *too many
  open files*:
  ```bash
  sudo sysctl -w fs.inotify.max_user_instances=512
  ```

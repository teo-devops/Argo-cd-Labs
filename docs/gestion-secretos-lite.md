# Gestión de secretos

Simplificación deliberada de la primera iteración: **no hay cifrado de secretos
en Git**. Ni Sealed Secrets, ni `kubeseal`, ni SOPS, ni External Secrets.

Hay **dos capas de secretos** en este clúster y no se gestionan igual. Confundir
una con otra es el error que este documento existe para evitar.

| Capa | Quién los consume | Se crean | ¿En Git? |
|---|---|---|---|
| Operación de Argo CD | El propio Argo CD, para poder clonar y arrancar | `install.sh` y `scripts/credenciales.sh` | Nunca |
| Workload | Los pods de un workload | `kubectl` contra su namespace, tras el primer sync | Nunca |

La regla común, que no cambia para ninguna de las dos:

> **Ningún valor de secreto se commitea en ningún repositorio, ni en claro ni
> cifrado.**

---

## a) Secretos que Argo CD necesita para operar

Son los que Argo CD usa para hacer su trabajo. No tienen nada que ver con los de
la sección (b), que son los que usan los pods de un workload.

| Secret | Namespace | Tipo | Para qué | Cómo se crea |
|---|---|---|---|---|
| `repo-<nombre>` | `argocd` | `repository` | Clonar **un** repo Git. Uno por repo | Fase 0 de `install.sh` (el de plataforma) y `scripts/credenciales.sh anadir` (los demás) |
| `argocd-secret` | `argocd` | Opaco | Contraseña de admin, server signature key y, cuando entre el SSO, el `clientSecret` de Dex | Lo genera el chart (`configs.secret.createSecret: true`) |
| `argocd-initial-admin-secret` | `argocd` | Opaco | Contraseña inicial de admin | Lo genera `argocd-server` en el primer arranque |

### Una credencial por repo

Cada repo Git tiene **su propia credencial de lectura y su propio Secret**.
Argo CD lo modela con un Secret de tipo `repository`: casa con **una url
exacta**.

```yaml
metadata:
  name: repo-wiki-demo
  labels:
    argocd.argoproj.io/secret-type: repository   # <- una url exacta
data:
  type: git
  url: https://github.com/teo-devops/workload-wiki-demo.git
  username: argocd
  password: <credencial de solo lectura>
```

Cómo se emite depende de la forja, pero la regla es la misma: **solo lectura,
limitada a ese repositorio**.

> - **GitHub**: una deploy key de solo lectura sobre ese repo, o un
>   fine-grained PAT limitado a él con `Contents: read`.
> - **GitLab**: Settings › Repository › Deploy tokens › Add token, usuario
>   `argocd`, scope `read_repository` y nada más.

No uses una credencial personal de alcance amplio: ata el clúster a una persona
—cuando rote su token o se vaya, deja de reconciliar— y, si se filtra, se filtra
el catálogo entero en vez de un repositorio.

El **usuario** del Secret es el de la credencial, no tu correo. Con el usuario
equivocado el Secret se crea igual y el fallo sale después, en la Application,
como `HTTP Basic: Access denied`.

**Consecuencia: dar de alta un workload incluye añadir su credencial.** Es un
paso más, y a cambio cada repo tiene su token: se revoca uno sin tocar los
demás, y un token filtrado expone un repo, no todos.

Toda la gestión pasa por un comando:

```bash
./scripts/credenciales.sh estado    # qué repos declara el plano de control y cuáles tienen credencial
./scripts/credenciales.sh anadir    # crear o rotar la de uno
./scripts/credenciales.sh probar    # ¿consigue Argo CD leerlos?
```

`estado` lee los `repoURL` declarados en este repo y los cruza con los Secret
del clúster, así que dice exactamente qué falta. Es la comprobación que evita
el caso desagradable: dar de alta un workload y descubrir que falta su
credencial por un `failed to list refs` en producción.

### Caducidad

Si el deploy token lleva fecha de caducidad, el día que expire **ese repo deja
de reconciliar** —con `health: Healthy`, que es lo que lo hace difícil de ver—.
Anota la fecha donde el equipo mire y rota con `credenciales.sh anadir`, que no
requiere reinstalar nada.

### Por qué la credencial del repo de plataforma no puede estar en Git

No es una preferencia, es una dependencia circular: **Argo CD necesita esa
credencial para clonar el repo donde estaría el fichero que la contiene.**
Ningún esquema de cifrado en Git resuelve eso. Por eso la crea el bootstrap y no
la reconciliación.

Si falta, el síntoma engaña: la `root-app` queda en `sync: Unknown` con
`[ComparisonError] failed to list refs` **y `health: Healthy`**. Mirando solo la
columna de health, el clúster parece sano.

Las credenciales de repo y `argocd-initial-admin-secret` están excluidas del
aviso de recursos huérfanos en `overlays/prod/projects/platform.yaml`
(`orphanedResources.ignore`): existen legítimamente sin estar en Git, y sin la
exclusión el aviso estaría siempre encendido —un aviso que nunca se apaga no
avisa de nada—. `argocd-secret` no necesita exclusión: lo emite el chart, así
que la `Application` del motor sí lo declara y no es huérfano.

---

## b) Secretos de cada workload

### El flujo

Los `Secret` de un workload **se crean directamente en su namespace, con
`kubectl`, después del primer sync**. No se declaran en el repo del workload ni
en este ni en ningún otro.

El orden importa: el namespace lo crea Argo CD con `CreateNamespace=true` al
sincronizar la `Application`, así que **antes del primer sync el namespace no
existe** y el `kubectl create secret` falla.

Esto funciona porque un pod al que le falta su Secret entra en
`CrashLoopBackOff` y **se recupera solo** en cuanto el Secret aparece. La
ventana entre el primer sync y el `kubectl create secret` es ruido, no daño.

> ⚠️ **Dos casos invierten este orden**, y en ellos hay que crear el namespace y
> el Secret **antes de mergear la Application**:
>
> - **Un workload efímero.** Un `Job` sin su Secret agota su `backoffLimit` y
>   queda en `BackoffLimitExceeded`: a diferencia de un Deployment, **no
>   reintenta** cuando el Secret aparece.
> - **Una imagen de registry privado.** `imagePullSecrets` hace falta antes del
>   primer pod.
>
> ```bash
> kubectl create namespace <workload>
> kubectl -n <workload> create secret generic <nombre> --from-literal=...
> ```
>
> Crear el namespace a mano no choca con `CreateNamespace=true`: Argo CD lo
> adopta y le pone sus etiquetas en el primer sync. Ver
> [arquetipos.md §5](arquetipos.md).

```bash
# 1. Esperar a que Argo CD haya creado el namespace
kubectl get namespace wiki-demo

# 2. Crear el Secret
kubectl -n wiki-demo create secret generic wiki-db \
  --from-literal=db-password='<valor>' \
  --from-literal=db-user='<valor>'

# 3. Comprobar (sin volcar los valores)
kubectl -n wiki-demo get secret wiki-db \
  -o jsonpath='{.data}' | tr ',' '\n'
```

Para credenciales de registry:

```bash
kubectl -n wiki-demo create secret docker-registry registry \
  --docker-server=ghcr.io \
  --docker-username='<usuario-o-deploy-token>' \
  --docker-password='<token>'
```

Para actualizar un valor existente, `create ... --dry-run=client -o yaml |
kubectl apply -f -` es idempotente:

```bash
kubectl -n wiki-demo create secret generic wiki-db \
  --from-literal=db-password='<valor-nuevo>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

> Evita pasar el valor en la línea de comandos si el historial del shell te
> preocupa: `--from-file=db-password=/ruta/al/fichero` lee de disco, y
> `read -rs` lo pide sin eco.

### Por qué esto no interfiere con Argo CD

Argo CD reconcilia **lo que está declarado en Git**. Un `Secret` que nunca
aparece en ningún manifiesto es, para Argo CD, un objeto que no existe:

- **No lo gestiona.** No forma parte del árbol de ningún `Application`.
- **No lo poda.** `prune` solo borra recursos que Argo CD dejó de ver *habiendo
  estado declarados*. Este nunca lo estuvo.
- **No genera `OutOfSync`.** No hay diff posible contra un manifiesto que no
  existe.

**No hace falta `ignoreDifferences`, ni `Prune=false`, ni exclusiones de
recursos.** Si en algún momento parece que hace falta, es señal de que el Secret
se ha declarado en Git por error.

El único efecto visible es el aviso de recursos huérfanos
(`orphanedResources: warn` en el AppProject del workload): Argo CD marcará esos
Secret como presentes en el namespace y no declarados. **Es correcto y
esperado** — el aviso está en modo `warn`, nunca borra, y en este modelo es
ruido conocido, no un fallo.

### Rotar un secreto no reinicia los pods

Actualizar el `Secret` no toca los pods que ya lo tienen montado: siguen con el
valor viejo hasta que se reinician. Argo CD no interviene aquí —el `Secret` no
está en su árbol—, así que no hay nada que se dé cuenta por ti.

```bash
kubectl -n wiki-demo rollout restart deployment/<nombre>
```

### La regla de durabilidad

> **El valor de un secreto de workload vive en exactamente dos sitios: el
> clúster y el almacén de contraseñas del equipo.**

No hay un tercero. En particular, no hay copia en un repositorio, ni en un
ticket, ni en un canal de chat, ni en el historial de un shell.

La consecuencia práctica: **antes de crear un `Secret` en el clúster, el valor
tiene que estar ya en el almacén de contraseñas.** Si solo vive en el clúster,
un `kubectl delete namespace` lo pierde y no hay de dónde reponerlo.

La durabilidad frente a pérdida del clúster la cubre **Velero**, a nivel de
plataforma. No se gestiona desde este repositorio.

### Lo que se pierde con esta simplificación, dicho claro

Con este modelo, **el repo del workload no es la fuente de verdad completa de su
estado desplegado**. Un `git revert` no restituye un secreto, y un clúster
reconstruido desde cero no converge del todo sin un paso manual: recrear los
Secret. Es el precio consciente de no tener cifrado en Git, y es asumible
mientras el número de secretos sea pequeño y el equipo, uno.

Si algún día Git tiene que ser también la fuente de verdad del *valor* de los
secretos, ahí es donde entrarían Sealed Secrets o External Secrets Operator.
Hasta entonces, no.

---

## Qué NO hacer

- ❌ Declarar un `Secret` en el repo del workload, aunque sea con valores de
  ejemplo o placeholders. Argo CD lo aplicaría y sobrescribiría el real.
- ❌ Poner valores en un `ConfigMap` "porque no es un Secret".
- ❌ Commitear un `.env`, un `values-prod.yaml` con credenciales, o un fichero
  de kubeconfig.
- ❌ Usar `kubectl edit secret` para rotar: no queda constancia de quién ni
  cuándo. Usa el `create --dry-run | apply` de arriba y anota la rotación donde
  el equipo lleve ese registro.

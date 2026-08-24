# Operar este clúster

Runbook de tareas concretas. Si buscas *por qué* está montado así, eso está en
[aislamiento-multi-workload.md](aislamiento-multi-workload.md); aquí solo está
el *cómo*.

Todo asume `kubectl` apuntando a `gitops-prod` y estar en la raíz del repo.
`credenciales.sh` anuncia en su cabecera sobre qué contexto está actuando y se
planta si ese contexto no tiene Argo CD; para fijarlo sin cambiar el contexto
activo, `--contexto <nombre>`.

---

## Entrar a la UI

**http://argocd.192-168-1-100.nip.io**

Mismo patrón que el resto de UIs internas del clúster (Grafana, Hubble,
Longhorn): un host por servicio bajo `*.nip.io`, servido en `/` por
ingress-nginx sobre la IP de MetalLB. El `nip.io` resuelve solo, sin DNS
interno.

Usuario `admin`, y la contraseña:

```bash
./scripts/credenciales.sh admin
```

> **Sin TLS**, igual que las demás UIs de administración: la contraseña viaja
> en claro por la red del clúster. Para añadirlo, lo mismo que en el resto —
> anotación `cert-manager.io/cluster-issuer` y `tls: true`. El reto HTTP-01
> funciona porque `nip.io` es resoluble públicamente.

### La CLI `argocd`

```bash
argocd login argocd.192-168-1-100.nip.io --plaintext --username admin
```

`--plaintext` porque el ingress no hace TLS. Al servirse en `/` no hacen falta
`--grpc-web-root-path` ni banderas de subpath.

---

## Quién puede entrar

Esta es la parte que hay que entender antes de dar acceso a nadie más.

**El diseño está pensado para no rehacerse:** los roles se definen una vez en
`config/argo-cd/values.yaml` y dar acceso a alguien es **añadir una línea `g,`**
que ata un sujeto a un rol. Lo único que cambia entre fases es qué es ese
sujeto: una cuenta local o un grupo del proveedor OIDC.

### Fase 1 — hoy: solo `admin`

Una cuenta compartida con acceso total. Correcto mientras haya un operador.

Lo importante de la configuración actual es lo que **no** tiene:

```yaml
policy.default: ''      # <- vacío A PROPÓSITO
```

`policy.default` se aplica a **todo** usuario autenticado y ese acceso **no se
puede recortar después con una regla `deny`**. Si aquí pusiera `role:readonly`,
el primer desarrollador que entrara vería las Applications de **todos** los
workloads — justo lo que el AppProject por workload existe para impedir.

Vacío significa: quien no tiene un rol explícito no ve nada. `admin` no se ve
afectado, su acceso no depende de esta política.

### Fase 2 — varias personas, sin SSO

Cuentas **locales**. Es el escalón intermedio y aguanta bien 2-5 personas. Dos
sitios, ambos en `config/argo-cd/values.yaml`, un solo PR:

```yaml
configs:
  cm:
    accounts.mateo: login          # 1. crear la cuenta
  rbac:
    policy.csv: |
      g, mateo, role:plataforma    # 2. darle un rol
```

Y ponerle contraseña, que no pasa por Git:

```bash
argocd account update-password --account mateo \
  --current-password <la-de-admin> --new-password <la-suya>
```

Roles ya definidos: `role:plataforma` (opera todo, sin `exec` en pods) y
`role:observador` (solo mirar).

Para dar acceso a **un solo workload**, no hace falta tocar `policy.csv`: se
ata la persona al rol `developer` que su AppProject ya declara en
`overlays/prod/projects/<workload>.yaml`:

```
g, ana, proj:wiki-demo:developer
```

Ana ve y sincroniza `wiki-demo`, y no ve ningún otro workload. Ahí es donde
el AppProject por workload deja de ser teoría.

Cuando haya al menos una cuenta con rol de plataforma, apaga la cuenta
compartida:

```yaml
configs:
  cm:
    admin.enabled: "false"
```

### Fase 3 — SSO vía OIDC

**Cuándo dar el salto:** una cuenta local **no puede pertenecer a grupos**, así
que cada persona necesita su propia línea en `policy.csv`. Con tres se lleva
bien; con diez, y con altas y bajas, es cuando compensa el SSO.

Hace falta una OAuth Application en el proveedor de identidad —el ejemplo
comentado usa GitLab— y descomentar el bloque `dex.config`
de `values.yaml`. A partir de ahí las líneas `g,` pasan a apuntar a grupos:

```
g, teo-devops/plataforma, role:plataforma
g, teo-devops/wiki-demo, proj:wiki-demo:developer
```

**Los roles y sus permisos no cambian.** Solo cambia el sujeto. Y el bloque
`groups:` de cada AppProject, hoy inerte, se activa solo: es lo que estaba
esperando un proveedor que emitiera el claim `groups`.

### Si la UI no carga

| Síntoma | Causa |
|---|---|
| Redirecciones infinitas (`ERR_TOO_MANY_REDIRECTS`) | `server.insecure` no está en `true`: nginx habla HTTP contra un backend que responde HTTPS |
| 404 de nginx | El Ingress no casa. `kubectl -n argocd get ingress argocd-server` y comprueba el host |
| El nombre no resuelve | `nip.io` necesita salida DNS. Comprueba `getent hosts argocd.192-168-1-100.nip.io` |
| Login redirige a un sitio que no existe | `configs.cm.url` no es la URL exacta que tecleas |
| Entras pero no ves ninguna Application | Correcto si tu usuario no tiene rol: `policy.default` está vacío a propósito |

`global.domain` y `configs.cm.url` **se cambian siempre en el mismo PR**:
desincronizarlas rompe el login.

---

## Dar de alta un workload

Son tres cosas, en este orden. Ninguna se salta.

**0. Antes de nada: ¿de qué tipo es?** Un servicio que converge y se queda no
necesita nada especial. Un trabajo que termina, un workload con estado o algo
que consuma un servicio compartido, sí — y lo que necesita está en
[arquetipos.md](arquetipos.md). Leerlo antes cuesta cinco minutos; descubrirlo
después cuesta un sync fallido que no se parece a un error de configuración.

**1. Dos ficheros en este repo, por PR.**

```bash
python3 scripts/alta-workload.py <nuevo> <url-del-repo>.git \
  --arquetipo stateless --grupo <org>/<equipo>
```

Genera los dos ficheros desde `plantillas/`, los añade a su `kustomization.yaml`
y ejecuta el validador. **Lee el AppProject que ha generado antes de abrir el
PR**: define los límites de privilegio del workload, y que lo haya escrito un
script no lo exime de revisión.

A mano es exactamente lo mismo, si lo prefieres:

```bash
cp plantillas/workload-appproject.yaml   overlays/prod/projects/<nuevo>.yaml
cp plantillas/workload-application.yaml  overlays/prod/apps/<nuevo>.yaml
# sustituir los marcadores en los dos, y añadirlos a su kustomization.yaml
python3 scripts/validar-coherencia.py     # comprueba que los dos casan
```

No se parte de `overlays/prod/apps/wiki-demo.yaml`: es un **ejemplo**, y
sus comentarios hablan de un dominio que no es el tuyo.

**2. La credencial de su repo**, o Argo CD no puede clonarlo:

```bash
./scripts/credenciales.sh estado      # dirá [FALTA] el repo nuevo
./scripts/credenciales.sh anadir
```

**3. Sus Secret**, *después* del primer sync — antes el namespace no existe:

```bash
kubectl get namespace <nuevo>                      # tiene que existir ya
kubectl -n <nuevo> create secret generic <nombre> \
  --from-literal=<clave>='<valor>'
```

> **Dos casos invierten este orden**, y hay que crear el namespace y el Secret
> **antes** de mergear: un workload efímero (un Job agota reintentos y no vuelve
> cuando el Secret aparece) y una imagen de registry privado
> (`imagePullSecrets` hace falta antes del primer pod). Ver
> [arquetipos.md §5](arquetipos.md).

Detalle y reglas de los secretos: [gestion-secretos-lite.md](gestion-secretos-lite.md).

**Y antes de mergear, pruébalo en el laboratorio.** `./lab/levantar.sh` descubre
el workload nuevo del propio plano de control y le siembra un repo con la
semilla de su arquetipo. No hay que tocar nada de `lab/`.

---

## Añadir o rotar la credencial de un repo

Una credencial por repo, de **solo lectura** y con el alcance más estrecho que
permita la forja:

> - **GitHub**: una deploy key de solo lectura sobre ese repositorio, o un
>   fine-grained PAT limitado a él con permiso `Contents: read`.
> - **GitLab**: Settings › Repository › Deploy tokens › Add token, usuario
>   `argocd`, scope `read_repository` y nada más.
>
> Nunca una credencial de organización ni de usuario con acceso a todo: si se
> filtra, se filtra un repositorio, no el catálogo entero.

Y en el clúster:

```bash
./scripts/credenciales.sh anadir      # sirve igual para crear que para rotar
```

Guarda el token también en el almacén de contraseñas del equipo: del clúster no
se puede volver a leer.

---

## Cambiar un secreto de un workload

```bash
kubectl -n <workload> create secret generic <nombre> \
  --from-literal=<clave>='<valor-nuevo>' \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n <workload> rollout restart deployment/<nombre>
```

El `rollout restart` es obligatorio: actualizar el Secret **no** reinicia los
pods, que siguen con el valor viejo montado.

---

## Subir de versión Argo CD

La versión está en dos sitios y CI comprueba que no diverjan:

1. `targetRevision` en `overlays/prod/argo-cd.yaml`
2. `CHART_VERSION` en `scripts/install.sh`

Cámbialos en el mismo PR y **mira el diff renderizado antes de aprobar**:

```bash
./scripts/render.sh /tmp/render
```

Es lo único que enseña qué cambia de verdad en el clúster; el PR solo enseña un
número de versión. El job `render-diff` de CI publica ese diff automáticamente.

> Si el chart nuevo no renderiza, la Application del motor se queda `Degraded`
> **y ningún workload avanza**, porque está en la wave anterior. No es que "el
> motor esté raro": es que se para todo.

---

## Cuando algo falla

Empieza siempre por aquí:

```bash
./scripts/credenciales.sh probar
```

Imprime SYNC y HEALTH juntas a propósito, porque el fallo más común se esconde
si solo miras una.

| Lo que ves | Qué es |
|---|---|
| `SYNC: Unknown` + `HEALTH: Healthy` + `failed to list refs` a secas | No hay Secret para esa url exacta. → `credenciales.sh estado` |
| ...y además `HTTP Basic: Access denied` | El Secret existe pero no vale para ese repo: el usuario no es el del deploy token, el token caducó, le falta `read_repository` o es de otro proyecto. → `credenciales.sh anadir` para rotarlo |
| `InvalidSpecError` | La Application apunta a un repo o namespace que su AppProject no permite. Los tres campos deben casar; `validar-coherencia.py` lo detecta antes del merge |
| `SYNC: Synced` y 0 recursos | Un `kustomization.yaml` que renderiza vacío. Verde y sin hacer nada |
| Pod en `CreateContainerConfigError` | Le falta un `Secret`. Normal tras el primer sync de un workload: créalo |
| Recurso no permitido en el proyecto | El manifiesto trae `Role`/`RoleBinding`, que el AppProject bloquea |

Logs del motor:

```bash
kubectl -n argocd logs statefulset/argocd-application-controller --tail=100
kubectl -n argocd logs deploy/argocd-repo-server --tail=100
```

**No hay notificaciones**: nadie te avisa. Mirar es parte de la operación.

---

## Dar de baja un workload

PR que retira sus dos ficheros y sus dos líneas de los `kustomization.yaml`.

Al borrarse la Application, su finalizer **borra el namespace y todo lo que hay
dentro**: pods, volúmenes y los Secret que creaste a mano. No lo devuelve Git.

Antes de mergear ese PR, confirma que hay copia de lo que haga falta.

---

## Recuperar Argo CD

El plano de control entero está en Git, así que la recuperación es reejecutar
el bootstrap contra un clúster limpio:

```bash
./scripts/install.sh
./scripts/credenciales.sh estado     # añadir las credenciales que falten
```

Después hay que **recrear a mano los `Secret` de cada workload**: no están en
Git, y sin ellos los pods se quedan en `CreateContainerConfigError` aunque las
Application digan `Synced`. Sus valores tienen que estar en el almacén de
contraseñas del equipo — esa es la única copia fuera del clúster.

El respaldo de los datos del clúster (volúmenes incluidos) lo lleva **Velero**,
a nivel de plataforma. No se gestiona desde este repo.

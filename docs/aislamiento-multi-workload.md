# Aislamiento multi-workload en gitops-prod

Cómo conviven varios workloads independientes en un mismo clúster, gestionados
de forma centralizada por Argo CD y operados exclusivamente por Pull Request.

**Alcance:** Argo CD y el flujo de trabajo con los repos. Es agnóstico al
contenido de los workloads —Kustomize, Helm o YAML plano, lo que traiga cada
repo— y no cubre la configuración de red del clúster.

> **Alcance real del aislamiento, dicho pronto.** Todo lo que describe este
> documento es aislamiento de **tiempo de despliegue**: quién escribe qué en
> Git y qué manifiestos acepta Argo CD. En **runtime** no hay ninguna
> restricción: no existe ninguna `NetworkPolicy` en el clúster, así que todos
> los pods se hablan y el namespace `argocd` es alcanzable desde cualquiera.
> "Un workload no habla con otro" es una convención del equipo, no un control
> técnico. Convertirlo en control es añadir NetworkPolicies default-deny, y no
> entra en esta iteración.

---

## 1. El modelo

```text
1 workload = 1 namespace = 1 AppProject = 1 Application = 1 repo Git
```

| Workload | Namespace | AppProject | Application | Repo | Arquetipo |
|---|---|---|---|---|---|
| api-demo | `api-demo` | `overlays/prod/projects/api-demo.yaml` | `overlays/prod/apps/api-demo.yaml` | `workload-api-demo.git` | `stateless` |
| wiki-demo | `wiki-demo` | `overlays/prod/projects/wiki-demo.yaml` | `overlays/prod/apps/wiki-demo.yaml` | `workload-wiki-demo.git` | `stateful` |

Los dos son EJEMPLOS, y son deliberadamente distintos entre sí: uno es una API
stateless de un solo componente y el otro un workload de dos componentes con
estado en disco. Tienen la misma forma en este repo porque la frontera no
depende del tipo de carga. Lo que sí
cambia entre ellos está en [arquetipos.md](arquetipos.md).

Cada workload es autocontenido: no referencia nada fuera de su namespace y no
puede escribir fuera de él. Dos ficheros en este repo y un repo propio.

> **El namespace no lo aísla todo.** Aísla objetos, pero **no paths ni
> hostnames de Ingress**: el controller es uno solo para todo el clúster. Dos
> workloads que publiquen la misma ruta colisionan, y nginx resuelve el empate
> por antigüedad del objeto, en silencio y sin error en ningún sitio. La
> convención es que cada workload cuelgue sus rutas de un prefijo propio. Esto
> no lo puede comprobar este repo, que no ve rutas: lo comprueba el gate del
> repo de cada workload.

Este repo contiene **solo el plano de control**: quién existe, qué puede leer y
dónde puede escribir. Los manifiestos de cada workload viven en su propio repo.

### 1.1 Qué cuenta como "un workload"

La unidad de aislamiento es el **límite de despliegue y de propiedad**, no el
binario, ni el proceso, ni el grafo de llamadas.

> **La regla: si dos componentes se despliegan y fallan juntos, son un
> workload.** Si no, son dos.

`wiki-demo` —una herramienta interna y la base de datos que solo ella usa— es
**un** workload, no dos. Se despliegan juntos, se versionan juntos,
fallan juntos y los mantiene el mismo equipo. Partirlos habría triplicado la
ceremonia a cambio de un aislamiento inejercitable.

**Esta regla decía antes "si dos componentes tienen que hablarse".** Se cambió a
propósito, porque era más estricta de lo que este modelo controla de verdad y
prohibía cosas que ni son peligrosas ni están prohibidas:

- El AppProject restringe **de qué repo se lee** y **en qué namespace se
  escribe**. Cruzar eso es un `InvalidSpecError`, y sigue sin ser negociable.
- El AppProject **no restringe el tráfico de red**, y este repo no despliega
  `NetworkPolicy` (ver README). Nunca controló quién habla con quién.

La diferencia importa en cuanto hay más de un tipo de workload. Con la regla
antigua, un servicio compartido —un almacenamiento de objetos, un motor de
workflows, un warehouse que consumen tres pipelines— no tenía sitio: o se
duplicaba dentro de cada workload, o se violaba la regla. Con la regla nueva, un
servicio compartido es **su propio workload**, con su namespace, su AppProject y
su repo como cualquier otro; lo único excepcional es que otros lo alcancen por
red. El invariante 1:1:1:1:1 no se toca.

Cómo distinguir un servicio compartido de un componente interno, con criterios
concretos: [arquetipos.md §4](arquetipos.md).

Los componentes internos de un workload (su base de datos, su caché, su
observabilidad) colapsan al mismo namespace. El cómo vive en
el repo del workload: es él quien decide qué agrega, no este repo.

---

## 2. Por qué Applications planas y no un ApplicationSet

Un `ApplicationSet` genera N `Application` desde una plantilla única. Compensa
cuando hay muchas instancias de la **misma forma**: mismo layout de repo, mismo
ciclo de vida, parámetros que solo cambian en el nombre.

No compensa aquí, y conviene tenerlo claro para no reintroducirlo:

- **Hoy hay un solo workload.** Un generador para producir una instancia es
  maquinaria pura. Este argumento se cae solo el día que haya varias, así que
  los dos siguientes son los que de verdad sostienen la decisión.
- Se espera que los workloads sean **heterogéneos** —repos distintos, layouts
  distintos, unos con Kustomize y otros con Helm—, porque el modelo permite a
  cada equipo elegir el suyo. Una plantilla única los obligaría a converger a
  una forma común, que es lo contrario de lo que se busca.
- El coste real es peor que el aparente: un fichero de parámetros por workload
  **más** la maquinaria del ApplicationSet (generator, `goTemplate`,
  `templatePatch` para las variantes), para producir un objeto `Application` de
  30 líneas que se puede escribir directamente.
- Un `Application` plano se lee, se diffea y se depura sin renderizar nada.

Cuando una familia de workloads sí sea repetitiva —diez instancias del mismo
chart, por ejemplo— se añade un `ApplicationSet` en `overlays/prod/apps/` junto a estos
ficheros. Los dos patrones conviven sin rehacer nada.

---

## 3. Cómo aísla el AppProject

El AppProject es un **firewall de despliegue dentro de Argo CD**: define qué
manifiestos acepta Argo CD en nombre de ese workload. Cinco restricciones, en
`overlays/prod/projects/wiki-demo.yaml`.

> **Precisión importante, que no es un tecnicismo.** El AppProject filtra *qué
> manifiestos acepta Argo CD*, **no con qué privilegios los aplica**. El
> `argocd-application-controller` aplica todo con su ServiceAccount, que es
> cluster-admin. Es una frontera de política a nivel de Argo CD, **no una
> frontera de RBAC de Kubernetes**: no hay defensa en profundidad detrás de esa
> validación. La pieza que lo convertiría en frontera real es *impersonation*,
> beta desde Argo CD 3.5 y no adoptada aquí: beta en la ruta de aplicación del
> único clúster productivo no es donde conviene estar.
>
> Con un operador y workloads internos, el riesgo residual es aceptable.
> Conviene saberlo, no descubrirlo.

### 3.1 `sourceRepos` — de dónde puede leer

```yaml
sourceRepos:
  - 'https://github.com/teo-devops/workload-wiki-demo.git'
```

Un solo repo. Si una `Application` de este proyecto apuntase al repo de otro
workload, Argo CD rechaza el sync antes de renderizar nada.

### 3.2 `destinations` — dónde puede escribir

```yaml
destinations:
  - server: 'https://kubernetes.default.svc'
    namespace: wiki-demo
```

Un namespace exacto, sin comodín. Cualquier manifiesto del repo que declare
otro namespace hace fallar el sync **completo** con un error explícito. No se
despliega parcialmente.

### 3.3 `clusterResourceWhitelist` — solo `Namespace`

```yaml
clusterResourceWhitelist:
  - group: ''
    kind: Namespace
```

El workload no puede crear `CRD`, `ClusterRole`, `ClusterRoleBinding` ni
`PersistentVolume`. `Namespace` sí, y **no es opcional**.

> **Esto se descubrió probándolo, y la versión anterior de este documento
> afirmaba lo contrario.** Decía que `CreateNamespace=true` daba el namespace
> "sin abrir permisos cluster-scoped". Es falso en Argo CD 3.4: el namespace se
> crea como una tarea **PreSync** que se valida contra el proyecto, así que con
> la lista vacía el **primer sync falla**:
>
> ```
> resource :Namespace is not permitted in project wiki-demo
> ```

### 3.4 El precio de esa entrada, dicho sin adornos

`destinations` **no filtra recursos cluster-scoped**, porque no tienen namespace
que comparar. Con `Namespace` permitido, el repo del workload puede declarar
**cualquier** namespace, no solo el suyo — incluido el de otro workload, del que
pasaría a ser dueño. Con `prune: true`, retirarlo de su Git borraría el
namespace ajeno **y todo su contenido**.

Verificado en un clúster real: un manifiesto con un namespace ajeno se aplica y
Argo CD no lo impide; la Application sigue `Synced/Healthy`.

Se acepta a propósito mientras los repos de workload sean de confianza. Lo que
sostiene la frontera aquí **es una regla de proceso, no un control técnico**:

> **El repo del workload no declara ningún objeto `Namespace`.**

Igual que no declara `Secret`. El AppProject no puede hacerla cumplir; lo que sí
puede es hacerla visible — cualquier `Namespace` en el repo de un workload
aparece en el diff renderizado de su PR.

**La señal de que se ha incumplido** es un namespace que nadie esperaba en
`kubectl get ns`. Merece la pena mirarlo de vez en cuando.

**La salida, si un workload deja de ser de confianza:** que plataforma cree los
namespaces desde este repo y se retiren tanto la entrada del whitelist como
`CreateNamespace=true`. Es un fichero más por workload y devuelve la frontera al
terreno técnico.

### 3.5 `namespaceResourceBlacklist` — solo RBAC

```yaml
namespaceResourceBlacklist:
  - group: rbac.authorization.k8s.io
    kind: Role
  - group: rbac.authorization.k8s.io
    kind: RoleBinding
```

Un workload no se concede permisos de API a sí mismo. Eso sigue bloqueado.

**`ResourceQuota`, `LimitRange` y `NetworkPolicy` se retiraron de esta lista**,
y merece la pena entender por qué, porque antes estaban.

Prohibírselos al workload solo produce gobierno si plataforma los emite en su
lugar. Plataforma no los emite. El efecto neto de la lista anterior no era
"plataforma controla los límites", era **"nadie tiene límites"**, documentado
como si fuera un control. Es la peor combinación posible: el riesgo intacto y
la sensación de haberlo cubierto.

Decisión tomada: **cada workload se autolimita si quiere**, dentro de su propio
namespace, y eso queda visible en el diff de su repo. Plataforma los recuperaría
el día que haya un workload que no sea de confianza plena o un segundo equipo
con acceso al clúster; hoy no es el caso.

> **Consecuencia práctica al portar charts de terceros.** Con `Role` y
> `RoleBinding` bloqueados, cualquier chart que traiga su propio RBAC —y son
> muchos: bases de datos, operadores, herramientas internas— **no sincroniza**. El error no dirá "quita el
> blacklist", dirá que el recurso no está permitido en el proyecto. Es una
> tarde perdida si se descubre en caliente. Cuando pase: o plataforma crea ese
> `Role` a mano, o se decide abrir el blacklist para ese workload.

### 3.6 `roles` — quién lo opera en la UI

> ⚠️ **INACTIVO hoy.** Este bloque solo surte efecto con Dex conectado a
> un proveedor OIDC, y `dex.config` está comentado en `config/argo-cd/values.yaml`. Sin un
> proveedor OIDC que emita el claim `groups`, estas políticas **no se aplican a
> nadie**. El acceso real hoy es la cuenta `admin` en
> `http://argocd.192-168-1-100.nip.io`.
>
> Con `policy.default: ''` nadie más ve nada hasta que se le dé un rol
> explícito. Para dar acceso a este workload **sin** SSO se ata una cuenta
> local a este mismo rol desde `policy.csv`
> (`g, ana, proj:wiki-demo:developer`), y el día que entre el SSO cambia el
> sujeto, no el rol. Ver [operar.md](operar.md), "Quién puede entrar".
>
> Para un equipo de una persona eso es adecuado; lo que no es adecuado es creer
> que existe un control de acceso por equipo que todavía no existe.

Cuando el SSO entre, mapea a grupos del proveedor de identidad vía OIDC. El equipo de
wiki-demo sincroniza y ve logs de su workload, y no ve ningún otro:

```yaml
roles:
  - name: developer
    policies:
      - p, proj:wiki-demo:developer, applications, sync, wiki-demo/*, allow
    groups:
      - teo-devops/wiki-demo
```

---

## 4. Orden de aplicación

`overlays/prod` agrega todo y las sync-waves fijan el orden, sin depender del
orden de las listas:

| Wave | Qué | Dónde |
|---|---|---|
| -2 | La `Application` del motor (Argo CD vía su chart) | `overlays/prod/argo-cd` |
| 0 | AppProjects | `overlays/prod/projects/` |
| 1 | Applications de workload | `overlays/prod/apps/` |

Los AppProject van antes que las Applications: una `Application` que referencia
un proyecto inexistente queda en error permanente.

El motor tiene su propia `Application`, separada de los workloads. Eso es lo que
permite darles **políticas de poda distintas** sin que una decisión valga para
todo el árbol: el motor va con `prune: false` de forma permanente —podarlo debe
ser un acto humano deliberado—, mientras que en un workload `prune` nace
apagado y se enciende por PR cuando se ha estabilizado (§5). Cuando todo colgaba
de la `root-app` había que elegir una sola política, y cualquiera de las dos era
incorrecta para la mitad del árbol.

---

## 5. Política de sync

Las Applications nacen con `selfHeal` activado y `prune` desactivado:

```yaml
syncPolicy:
  automated:
    selfHeal: true
    prune: false
```

Activar `prune: true` es un PR de una línea sobre `overlays/prod/apps/<workload>.yaml`,
cuando el workload se ha estabilizado, y queda en el historial de Git.

### Por qué ya no hay "primera semana de sync manual"

El modelo anterior creaba las Applications **sin** `automated` y las mantenía
así una semana, para que alguien revisara el primer diff renderizado en la UI
antes de aplicarlo.

El coste de eso no era el PR extra: era **una semana sin `selfHeal` por cada
workload**, justo la propiedad que más se quiere en un clúster donde se admite
que puede haber `kubectl` clandestino (por algo hay `orphanedResources: warn`).

Y la razón por la que hacía falta mirar la UI era que **el PR enseña Kustomize y
Helm, no los objetos que acaban en el apiserver**. Eso ahora lo resuelve el job
`render-diff` de CI, que renderiza la rama base y la del PR y publica la
diferencia **antes** del merge. Es la misma revisión, antes, y sin pagar una
semana de reconciliación por ella.

`prune` sigue naciendo apagado por un motivo distinto y que se mantiene: durante
la estabilización, un render que salga corto no debe llevarse por delante
recursos vivos.

---

## 6. Alta de un workload nuevo

Dos PRs, en dos repos. La separación es deliberada: quién existe en el clúster
lo aprueba plataforma; qué contiene el workload lo aprueba su equipo.

> **Sobre los revisores, con honestidad.** Mientras el equipo de infraestructura
> sea una persona, "dos revisores distintos" no existe: es self-merge en el repo
> de plataforma, o un rubber stamp de alguien que no conoce este repo. Lo que sí
> está operativo y aporta valor íntegro es lo otro —**rama protegida, PR
> obligatorio, historial**— que es auditoría y funciona igual con self-merge.
>
> La estructura de dos repos está montada para el día que haya un segundo
> equipo con permiso de merge en el suyo. Hasta entonces, el control real lo
> ejercen el job `validar` de CI y el diff renderizado, no una segunda firma.

### PR 1 — este repo (el plano de control)

0. Mirar de qué **arquetipo** es el workload ([arquetipos.md](arquetipos.md)).
   No cambia estos dos ficheros casi nunca, pero sí cambia lo que su repo tiene
   que traer y en qué orden se crean sus secretos.
1. Generar los dos ficheros desde `plantillas/`:

   ```bash
   python3 scripts/alta-workload.py <nuevo> <url>.git \
     --arquetipo <arquetipo> --grupo <org>/<equipo>
   ```

   Los añade a los dos `kustomization.yaml` y ejecuta el validador. A mano es lo
   mismo: copiar las dos plantillas y sustituir los marcadores.
2. **Leer el AppProject generado.** Define los límites de privilegio del
   workload; el script no decide nada por ti ahí.
3. PR contra `main`. CI comprueba automáticamente:
   - `scripts/validar-coherencia.py` — que los dos ficheros casan entre sí
     (nombre, `project`, `repoURL` —también con `sources` múltiples—, namespace,
     `CreateNamespace=true`, y que el `clusterResourceWhitelist` sea exactamente
     `Namespace` y nada más), que no queda ningún marcador de plantilla sin
     sustituir, que el arquetipo declarado existe, que ningún AppProject se
     queda sin Application ni al revés, y que la versión del chart de Argo CD es
     la misma en `install.sh` y en `argo-cd.yaml`. El error probable de un alta
     es un nombre sin sustituir, y esto lo detecta **antes** del merge en lugar
     de dejarlo en un `InvalidSpecError` en el clúster después.
   - `render-diff` — qué objetos cambian de verdad en el apiserver.

Al mergear, la root-app reconcilia y aparecen el AppProject y la Application
**sin que nadie toque Argo CD**.

Se puede ejecutar la validación en local antes de abrir el PR:

```bash
python3 scripts/validar-coherencia.py
./scripts/render.sh /tmp/render && less /tmp/render/01-plano-de-control.yaml
```

### PR 2 — repo del workload

1. Manifiestos en el layout que prefiera el equipo (Kustomize, Helm o YAML
   plano), sin ningún objeto `Namespace` **y sin ningún `Secret`**.
2. Los `Secret` se crean directamente en el namespace del workload con
   `kubectl`, **después del primer sync** —antes, el namespace todavía no
   existe—. No se declaran en este repo ni en el del workload.
   Procedimiento exacto en [gestion-secretos-lite.md](gestion-secretos-lite.md).
3. PR contra `main`. Revisor: equipo del workload.

El único `kubectl` de todo el procedimiento es el del paso 2, y es deliberado:
los secretos no pasan por Git en esta iteración. Nada más del estado del
workload se toca a mano — todo lo demás llega por reconciliación.

---

## 7. Baja de un workload

Un PR que retira las dos entradas de los `kustomization.yaml` y los dos
ficheros. El finalizer `resources-finalizer.argocd.argoproj.io` de la
`Application` hace que, al borrarla, Argo CD elimine también sus recursos —
incluido el namespace y todo su contenido.

Es destructivo y no reversible por Git. Lo que se pierde y **no** está en el
repo:

- los datos de los volúmenes — los respalda Velero a nivel de plataforma, no
  este repo, así que confírmalo con quien lo opere;
- **los `Secret` del namespace**, que en este modelo no viven en ningún
  repositorio (§10). Reponerlos exige que sus valores estén en el almacén de
  contraseñas del equipo, que es justo la regla del §10.

Ese PR necesita constancia explícita de que se ha hecho copia de lo que haga
falta. Esa constancia es el único control que hay.

---

## 8. Configuración del lado de la forja

Este modelo no depende de ninguna forja en concreto —solo necesita una URL de
repositorio y una credencial de lectura— pero sí depende de que estén montadas
estas cinco cosas, se llamen como se llamen en la tuya:

- **Un repo por workload**, más este repo de plataforma. El repo de CI de cada
  componente sigue aparte: construye y publica imágenes, y nunca despliega.
- **Protección de rama en `main`** con Pull Request obligatorio, en todos los
  repos. Es el control de seguridad real: quien puede mergear en el repo de
  plataforma decide qué existe en el clúster.
- **Una credencial de solo lectura por repo**, con el alcance más estrecho que
  permita la forja —una deploy key de solo lectura o un token limitado a ese
  repositorio, nunca una credencial de organización—. La del repo de plataforma
  la consume la fase 0 de `scripts/install.sh`; las demás se añaden con
  `scripts/credenciales.sh anadir` al dar de alta cada workload.
- **SSO de Argo CD vía OIDC.** ⚠️ Todavía no montado; hasta entonces el bloque
  `roles` de cada AppProject (§3.6) es inerte. `config/argo-cd/values.yaml`
  lleva un conector de Dex comentado como ejemplo.
- **Webhook de la forja hacia Argo CD** en cada repo, para sync casi instantáneo
  en lugar del polling por defecto de 3 minutos.

### Separación de responsabilidades

| Sistema | Responsabilidad | Nunca hace |
|---|---|---|
| CI de la forja | Build, test, publicación de imagen | Desplegar; conocer credenciales del clúster |
| Repo de workload | Declarar el estado deseado del workload | Contener Dockerfiles o lógica de build |
| Este repo | Declarar qué workloads existen y sus fronteras | Contener manifiestos de aplicación |
| Argo CD | Reconciliar, dar visibilidad de diffs y rollback | Construir nada |

### Puntos de decisión humana, por diseño

| Situación | Punto manual | Se automatiza cuando… |
|---|---|---|
| Alta de workload | PR en este repo | Nunca — es la concesión de una frontera |
| Revisión del cambio | Leer el diff renderizado en el PR | Nunca — pero el render sí está automatizado (`render-diff`) |
| Activar `prune` | PR de una línea | Cuando el workload se ha estabilizado |
| Cambio de secreto | `kubectl` contra el namespace del workload | Nunca — requiere acción humana explícita y no pasa por Git |
| Rollback | Decidir revert vs fix directo | Nunca — un criterio automático es más arriesgado que el fallo |
| Baja de workload | PR + confirmación de backup | Nunca — es destructivo e irreversible por Git |

---

## 9. Rollback

El repo del workload es la fuente de verdad de **sus manifiestos**, así que un
revert devuelve esos manifiestos a un estado previamente probado.

No es la fuente de verdad de todo su estado desplegado, y conviene tenerlo
presente antes de confiar en un revert: los `Secret` no están en Git (§10) y el
estado con vida propia —datos, volúmenes, migraciones— tampoco (ver la salvedad
al final de esta sección). Un revert no toca ninguno de los dos.

1. Argo CD marca el recurso *Degraded* o el sync falla; la UI muestra el diff y
   el estado del recurso.
2. **Causa clara** (error de configuración): PR de corrección directa.
3. **Causa no clara**: revert del último commit en el repo del workload.
4. Si tras el nuevo sync el recurso no vuelve a *Healthy*, el problema no está
   en el manifiesto — investigar logs del pod fuera de Argo CD.

Salvedad importante: el revert **no** deshace estado que no vive en Git —
migraciones de base de datos, contenido de volúmenes, datos sembrados por Jobs
de inicialización. Cuando un workload tenga estado de ese tipo, documentarlo en
su propio repo.

---

## 10. Gestión de secretos

**No hay cifrado de secretos en Git.** Es una simplificación deliberada de la
primera iteración: sin Sealed Secrets, sin `kubeseal`, sin SOPS.

Los `Secret` de un workload se crean **directamente en su namespace con
`kubectl`, después del primer sync**, y no se declaran en ningún repositorio.
El procedimiento completo, los comandos exactos y la separación respecto a los
secretos de operación de Argo CD están en
[gestion-secretos-lite.md](gestion-secretos-lite.md).

Lo que hay que retener aquí:

- El repo del workload **no contiene ningún objeto `Secret`**, igual que no
  contiene ningún `Namespace`.
- Como Argo CD nunca ve esos Secret declarados, **no los gestiona ni los poda**.
  No hacen falta `ignoreDifferences` ni exclusiones; si parecen hacer falta, es
  que algún Secret se ha declarado en Git por error.
- El aviso de `orphanedResources: warn` marcará esos Secret como no declarados.
  Es correcto y esperado: el modo `warn` nunca borra.
- **El valor vive en el clúster y en el almacén de contraseñas del equipo, y en
  ningún tercer sitio.** Debe estar en el almacén *antes* de crearlo en el
  clúster.

Consecuencia que conviene tener presente: con este modelo el repo del workload
ya **no es la fuente de verdad completa** de su estado desplegado. Un revert no
restituye un secreto, y un clúster reconstruido desde cero necesita un paso
manual para recrearlos.

Una nota operativa que se mantiene: **cambiar un `Secret` no reinicia los
pods**. Rotas una credencial con `kubectl`, el `Secret` queda actualizado y el
pod sigue con el valor viejo montado hasta que se reinicia. Tras rotar, forzar
el rollout:

```bash
kubectl -n wiki-demo rollout restart deployment/<nombre>
```

# Arquetipos de workload

Este plano de control es agnóstico al contenido: le da igual si un workload es
una API, un entrenamiento de un modelo, un pipeline o una herramienta interna.
La frontera —un namespace, un AppProject, un repo— es la misma para todos.

Lo que **no** es igual es lo que rompe. Las reglas por defecto de este repo
—`selfHeal: true`, `prune: false`, secretos creados a mano tras el primer sync—
se escribieron con un tipo de carga en la cabeza: componentes de larga vida que
convergen y se quedan. Aplicadas a un trabajo que termina, o a un chart de
terceros, producen fallos que no se parecen a un error de configuración.

Este documento es la lista de esos fallos, por arquetipo. Casi todos se
resuelven **en el repo del workload**, no aquí; los que no, están marcados.

> El arquetipo se declara en la Application con la anotación
> `argo-cd-labs.dev/arquetipo`. No cambia nada en producción: sirve para que
> `lab/levantar.sh` siembre la semilla correcta y puedas tropezarte con todo
> esto en un kind desechable. Ver [lab/README.md](../lab/README.md).

Los nombres siguen la terminología estándar de Kubernetes, y cada uno se
corresponde con el tipo de objeto que lo caracteriza:

| Arquetipo | Objeto típico | Qué es | Semilla del laboratorio |
|---|---|---|---|
| `stateless` | `Deployment` | Converge y se queda: APIs, webs, workers | `lab/workload/seeds/stateless/` |
| `batch` | `Job` / `CronJob` | Corre, termina y no vuelve: jobs, entrenamientos | `lab/workload/seeds/batch/` |
| `stateful` | `StatefulSet` + `PVC` | Tiene volúmenes o bases de datos que sobreviven a los pods | `lab/workload/seeds/stateful/` |
| *consumidor de servicio compartido* | — | Habla con algo que vive en otro namespace | — (es un patrón, no una forma) |

Un workload puede ser de más de uno a la vez —una API con su base de datos es
`stateful`— y entonces se declara **el que más restricciones impone**, porque el
arquetipo solo decide con qué se prueba en el laboratorio. El orden de
prioridad, de más restrictivo a menos: `batch` → `stateful` → `stateless`.

---

## 1. `stateless` — servicio que converge y se queda

El arquetipo por defecto y el que menos sorpresas da. Un Deployment, su Service,
su Ingress, quizá un HPA.

### 1.1 `selfHeal` pelea con el autoscaler

Si el Deployment declara `replicas: 3` y además hay un HPA, cada vez que el HPA
escale, Argo CD verá desviación y lo revertirá. El resultado es un servicio que
oscila y una Application que nunca queda `Synced` del todo.

**La salida limpia: no declarar `replicas` en el manifiesto.** Kubernetes deja
el campo a lo que diga el HPA y Argo CD no tiene nada que comparar.

Solo si el manifiesto viene de un chart de terceros que lo declara y no se puede
quitar, hace falta el plan B, y **este sí toca el plano de control** —es uno de
los dos únicos casos en que un arquetipo modifica la Application:

```yaml
# en overlays/prod/apps/<nombre>.yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
```

### 1.2 Imagen nueva

No hay Image Updater ni Kargo, a propósito (ver README, "Estado del proyecto").
`targetRevision: main` significa "desplegar al mergear", y quien mueve el tag es
**la CI del repo del workload**, que commitea la etiqueta nueva a su propio
repositorio. El plano de control no se entera y no tiene por qué.

Ese commit es el registro de qué versión corre y desde cuándo. Si acabas
necesitando promoción entre entornos o rollback por versión, ahí es donde Kargo
empieza a pagarse — no antes.

### 1.3 Imagen de registry privado

`imagePullSecrets` necesita que el Secret exista **antes del primer pod**, y el
modelo de este repo dice que los secretos se crean *después* del primer sync.
Aquí ese orden se invierte. Un Deployment lo perdona —los pods quedan en
`ImagePullBackOff` hasta que aparece el Secret— pero es ruido evitable: créalo
antes de mergear. Ver §5.

---

## 2. `batch` — trabajo que corre, termina y no vuelve

El que peor encaja con las reglas por defecto. Tres trampas, y las tres son
específicas de este arquetipo.

### 2.1 Un Job es inmutable

Cambiar la imagen o el comando de un Job existente y sincronizar da:

```
Job.batch "trabajo" is invalid: spec.template: field is immutable
```

y la Application se queda en `SyncFailed` permanente. No es un error transitorio
y los reintentos no lo arreglan.

Hay **dos salidas, y no son intercambiables**. La pregunta que las separa es
*¿este trabajo debe correr en cada sync, o solo cuando cambia?*

**a) Solo cuando cambia** — un entrenamiento, una carga de datos puntual. En el
repo del workload y **solo sobre el Job**:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Replace=true
```

Argo CD lo borra y lo recrea en vez de parchearlo. Ponerlo en `syncOptions` de
la Application lo aplicaría a **todos** los recursos del workload, que casi
nunca es lo que se quiere.

**b) En cada sync** — una migración de esquema, un `seed` idempotente. Entonces
el Job no es un recurso: es un **hook**.

```yaml
metadata:
  annotations:
    argocd.argoproj.io/hook: PreSync          # o PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
```

Un hook queda fuera del cálculo de sync normal, así que ni `prune` ni `selfHeal`
lo tocan — y con eso desaparecen también §2.2 y §2.3. Si dudas entre las dos,
mira si volver a ejecutar el trabajo sin que haya cambiado nada es inofensivo:
si lo es, es un hook.

### 2.2 Con `selfHeal`, borrar el Job equivale a re-ejecutarlo

Argo CD ve que falta un recurso declarado y lo recrea en el siguiente ciclo. En
un Deployment eso es exactamente lo que quieres; aquí significa que un
`kubectl delete job` para "limpiar" **vuelve a lanzar el trabajo**.

No hay nada que arreglar: es el comportamiento correcto de `selfHeal` aplicado a
un objeto que no debería ser permanente. Lo que hay es que saberlo.

### 2.3 `ttlSecondsAfterFinished` + `selfHeal` = bucle de ejecución

Es lo primero que uno añade para que los Jobs terminados no se acumulen, y con
`selfHeal` activo crea un ciclo cerrado: el TTL borra el Job → Argo CD lo recrea
→ el Job corre otra vez → el TTL lo borra. Para un entrenamiento sobre GPU eso
se nota en la factura antes que en la UI.

**Si necesitas que no se acumulen**, la salida no es un TTL: es que cada revisión
traiga un Job con **nombre distinto** —derivado del tag de la imagen o de un
hash del contenido— y activar `prune: true` en la Application cuando el workload
se haya estabilizado. Así el Job viejo desaparece porque deja de estar
declarado, no porque un controlador lo borre por debajo.

### 2.4 Prefiere `CronJob` a `Job`

Un `CronJob` es un objeto **duradero** que engendra los efímeros. Encaja con
GitOps sin ninguna de las tres salvedades anteriores: es inmutable en lo que
importa, `selfHeal` lo mantiene y nada lo borra por debajo. Si el trabajo es
recurrente, no hay discusión.

### 2.5 Un Job no perdona que falte un Secret

Esta es la que de verdad rompe el modelo de secretos de este repo, y no la
resuelve una anotación.

El Job arranca en el primer sync, antes de que nadie haya podido crear el
Secret. Agota su `backoffLimit`, queda en `BackoffLimitExceeded`, y ahí se
queda: a diferencia de un Deployment, **no reintenta cuando el Secret aparece**.

**El secreto se crea ANTES de mergear la Application.** Ver §5.

---

## 3. `stateful` — volúmenes y bases de datos

Estructuralmente es el arquetipo más parecido al caso de uso que originó este
repo, y por eso el que menos fricción da. Dos cosas.

### 3.1 Todo PVC lleva `Prune=false` desde el primer commit

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
```

Hoy la Application nace con `prune: false` global, así que no cambia nada. El
día que alguien active `prune: true` —un PR de una línea— esta anotación es lo
único que separa "he renombrado el StatefulSet" de "he borrado el volumen".

Ponerla el día que se activa el prune es tarde: para entonces nadie recuerda
cuáles eran los PVC que importaban.

### 3.2 `ReadWriteOnce` obliga a `strategy: Recreate`

Con un PVC `ReadWriteOnce`, dos pods no pueden montar el volumen a la vez. Con
`RollingUpdate` el pod nuevo se queda en `Pending` esperando un volumen que el
viejo no suelta, y el síntoma —un rollout colgado— no dice por qué.

### 3.3 Copias de seguridad

Fuera del alcance de este repo: las lleva Velero a nivel de clúster. Lo que sí
es responsabilidad del workload es **etiquetar** sus PVC para que la política de
Velero los recoja. Acuérdate al dar de alta uno, no cuando haga falta restaurar.

---

## 4. Consumidor de un servicio compartido

No es una forma de workload: es una relación entre dos. Merece sección porque
es donde una regla de este repo se lee más restrictiva de lo que es.

La regla dice: **si dos componentes se despliegan y fallan juntos, son un
workload.** La versión antigua decía "si dos componentes tienen que hablarse",
y eso era más estricto de lo que el AppProject controla de verdad:

- El AppProject restringe **de qué repo se lee** (`sourceRepos`) y **en qué
  namespace se escribe** (`destinations`).
- **No** restringe el tráfico de red. No hay `NetworkPolicy` (ver README).

Así que un workload **puede** consumir por red un Service de otro namespace, y
eso no viola ninguna frontera técnica. Lo que hay que decidir a mano es si esa
dependencia es legítima:

| Es un servicio compartido | Es un componente del mismo workload |
|---|---|
| Tiene su propio ciclo de vida y versión | Se versiona con el resto |
| Sobrevive a que el consumidor se dé de baja | Muere con él |
| Lo consumen varios workloads, o podría | Solo lo usa este |
| Su contrato es una API estable | Sus interfaces cambian con cada release |

Si es lo primero, es **su propio workload**, con su namespace, su AppProject y
su repo, como cualquier otro. El invariante 1:1:1:1:1 no se toca: lo excepcional
es solo que otros lo alcancen por red.

Si es lo segundo, va dentro del mismo workload. `wiki-demo` trae su propia base
de datos por esta razón, no por casualidad: solo la usa él, se despliega con él
y muere con él.

**Lo que este modelo sigue prohibiendo** es que un workload **escriba** en el
namespace de otro. Eso lo rechaza Argo CD con `InvalidSpecError`, y no es
negociable.

---

## 5. Secretos: cuándo el orden por defecto no vale

El modelo del repo es: primer sync, luego `kubectl create secret` en el namespace
que Argo CD acaba de crear ([gestion-secretos-lite.md](gestion-secretos-lite.md)).
Funciona porque un Deployment sin su Secret entra en `CrashLoopBackOff` y se
recupera solo en cuanto aparece.

**Ese orden se invierte cuando el workload no puede arrancar sin el secreto:**

- un `batch`: el Job agota reintentos y no vuelve (§2.5);
- una imagen de registry privado: `imagePullSecrets` hace falta antes del primer
  pod (§1.3).

En esos dos casos, el alta tiene un paso previo: crear el namespace y el Secret
**antes** de mergear la Application.

```bash
kubectl create namespace <workload>
kubectl -n <workload> create secret generic <nombre> --from-literal=...
```

Crear el namespace a mano no choca con `CreateNamespace=true`: Argo CD lo
adopta, y `managedNamespaceMetadata` le pone sus etiquetas en el primer sync.

La regla de durabilidad no cambia y no se negocia: **ningún valor de secreto se
commitea en ningún repositorio, ni en claro ni cifrado**, y tiene que estar en el
almacén de contraseñas del equipo *antes* de crearlo en el clúster.

---

## Lo que sigue sin decidir

Igual que SSO, TLS y `NetworkPolicy`, esto está pendiente **a propósito**, no
olvidado. Se decide cuando un workload real lo exija, no antes.

**RBAC de charts de terceros.** El AppProject bloquea `Role` y `RoleBinding`:
un workload no se concede permisos de API a sí mismo. Casi cualquier chart
público —bases de datos, operadores, herramientas internas— trae los suyos y
fallará el sync hasta que plataforma cree ese Role a mano.

El argumento para abrirlo: un `Role` es *namespaced*, y un `RoleBinding` solo
surte efecto dentro de su namespace, así que el workload no puede escalar fuera
de su frontera — y el controller de Argo CD ya aplica como cluster-admin dentro
de ese namespace. El riesgo marginal es casi nulo y el coste de mantenerlo
cerrado es trabajo imperativo, que es justo lo que este repo existe para
eliminar.

**Se decide cuando llegue el primer workload que lo necesite de verdad**, y en
ese PR, no en abstracto.

**Recursos cluster-scoped más allá de `Namespace`.** Un `PersistentVolume`
estático (bare-metal, NFS) o un CRD están hoy prohibidos, y `validar-coherencia.py`
lo comprueba. Casi siempre, necesitar uno significa que ese recurso pertenece a
**plataforma**, no al workload — un motor de workflows es plataforma, no un
pipeline. Si algún día no es así, la excepción se declara y se revisa en el PR.

**Límites de runtime.** No hay `ResourceQuota` ni `LimitRange`: el aislamiento de
este repo es de tiempo de despliegue. Con workloads del mismo equipo eso era una
simplificación razonable. Con arquetipos heterogéneos compartiendo nodos —un
entrenamiento junto a una API— es el primer control de runtime que se va a
echar de menos, y probablemente el primero que haya que añadir.

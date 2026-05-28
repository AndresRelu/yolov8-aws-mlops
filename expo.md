# Guía de exposición — Cloud Data IA Project

Este documento explica, con palabras simples, todos los servicios y decisiones
técnicas del proyecto. Está pensado para que puedas exponerlo aunque el oyente
no sepa nada de AWS.

---

## 1. Los buckets S3 y su finalidad

**¿Qué es un bucket S3?**
Un bucket es como una carpeta gigante en la nube (AWS S3 = Simple Storage
Service). No tiene límite de tamaño, los archivos se guardan con cifrado
automático y se puede controlar quién puede leer o escribir.

El proyecto crea **5 buckets**, cada uno con un propósito distinto:

| Bucket | Nombre lógico | Para qué sirve |
|--------|--------------|----------------|
| `raw` | `kitti-ml-project-raw-<cuenta>` | Datos tal como llegan: las imágenes KITTI y los archivos `.txt` de etiquetas sin tocar |
| `curated` | `kitti-ml-project-curated-<cuenta>` | Datos ya limpios y convertidos a Parquet + dataset YOLO listo para entrenar |
| `input` | `kitti-ml-project-input-<cuenta>` | Imágenes que el usuario sube para pedir predicciones desde el frontend |
| `model-artifacts` | `kitti-ml-project-model-artifacts-<cuenta>` | Scripts de SageMaker empaquetados, resultados del entrenamiento y el modelo `.pt` |
| `frontend` | `kitti-ml-project-frontend-<cuenta>` | El sitio web estático (HTML, JS, CSS) que se sirve al navegador |

> Los nombres tienen el ID de cuenta al final porque S3 exige que los nombres
> sean únicos en todo AWS, no solo en tu cuenta.

Todos los buckets tienen:
- **Versionado activado**: si sobreescribes un archivo accidentalmente, AWS
  guarda la versión anterior.
- **Cifrado AES-256**: los datos en reposo están cifrados por defecto.
- **Bloqueo de acceso público**: nadie fuera de AWS puede abrirlos directamente.

---

## 2. Las Lambdas y qué hace cada una

**¿Qué es una Lambda?**
Una Lambda es una función de código que AWS ejecuta solo cuando la llaman. No
hay servidor encendido esperando; AWS lo arranca, corre el código y lo apaga.
Solo pagas por los milisegundos que tardó en ejecutarse.

El proyecto tiene **4 Lambdas**:

### `kitti-prepare-yolo-dataset`
- **Cuándo se ejecuta**: en el paso 3 del pipeline de Step Functions.
- **Qué hace**: lee los archivos `.txt` de KITTI del bucket `curated` y los
  convierte al formato YOLO (un `.txt` por imagen con coordenadas normalizadas
  entre 0 y 1). Organiza las imágenes en carpetas `train/` y `val/` dentro del
  bucket `curated`.
- **Por qué Lambda y no Glue**: la preparación del dataset YOLO es lógica de
  Python puro (bucle de archivos, cálculos simples). No necesita Spark. Una
  Lambda de 256 MB y 60 segundos de timeout es suficiente y cuesta céntimos.

### `kitti-training-results-notifier`
- **Cuándo se ejecuta**: al final del pipeline, después de que SageMaker
  termina de entrenar.
- **Qué hace**: lee las métricas del entrenamiento (precisión, recall, mAP),
  genera una URL prefirmada (un enlace temporal que expira en 7 días) al modelo
  guardado en S3, y publica un mensaje SNS con el resumen del entrenamiento.
- **Por qué es útil**: en lugar de entrar a la consola de AWS a buscar los
  resultados, te llega un correo con todo el resumen.

### `kitti-rest-api-handler` (en el módulo `ai-inference`)
- **Cuándo se ejecuta**: cada vez que alguien hace `POST /predict` en la API.
- **Qué hace**: recibe la imagen (en base64, como binario o como referencia a
  S3), la envía al endpoint de SageMaker, recibe los bounding boxes detectados
  y devuelve el JSON con las detecciones al cliente.
- **Por qué Lambda aquí**: la Lambda actúa de puente entre API Gateway y
  SageMaker. API Gateway no puede llamar a SageMaker directamente; necesita una
  Lambda como intermediaria.

### `kitti-retraining-trigger` (archivo vacío, diseñado pero no implementado)
- **Qué haría**: cada vez que llega una imagen nueva al bucket `raw`,
  incrementaría un contador en SSM Parameter Store. Si el contador llega a 500
  imágenes y pasaron más de 3 días desde el último entrenamiento, dispararía
  automáticamente un nuevo ciclo de Step Functions para reentrenar el modelo.

---

## 3. Glue: Crawler, Job y Data Catalog

### ¿Qué es AWS Glue?
Glue es el servicio de ETL (Extract, Transform, Load) de AWS. ETL significa:
extraer datos de algún lugar, transformarlos (limpiarlos, cambiar su formato) y
cargarlos en otro lugar.

### El Crawler: `kitti-labels-crawler`
Un **Crawler** es un robot que AWS Glue manda a explorar tus buckets S3.
Su único trabajo es mirar los archivos que hay ahí y decirle al sistema
"encontré archivos `.txt` con esta estructura de columnas". Con esa información
actualiza el **Data Catalog** (ver sección siguiente).

En el proyecto: el crawler apunta a `s3://<raw>/labels/` y descubre la
estructura de los archivos de etiquetas KITTI.

### El Job: `kitti-clean-labels-job`
Un **Glue Job** es el programa que realmente transforma los datos. Corre con
**Apache Spark** bajo el capó, lo que significa que puede procesar millones de
filas en paralelo usando varios nodos de cómputo.

Lo que hace el job en este proyecto:
1. Lee todos los `.txt` de etiquetas KITTI del bucket `raw`.
2. Parsea cada línea: extrae clase, coordenadas del bounding box, etc.
3. Filtra clases irrelevantes (`DontCare`, `Misc`).
4. Calcula métricas del bounding box (ancho, alto, área, centro en píxeles).
5. Escribe el resultado en formato **Parquet** en el bucket `curated`.
6. Manda métricas personalizadas a CloudWatch.

### ¿Qué es Parquet?
Es un formato de archivo columnar (como una tabla de base de datos comprimida).
Es mucho más eficiente que CSV o texto plano para consultas analíticas: ocupa
menos espacio y se lee más rápido.

---

## 4. Glue Data Catalog

**¿Qué es?**
El Data Catalog es la "biblioteca de metadatos" de AWS. Guarda el esquema
(nombres de columnas, tipos de datos) de tus datasets, sin guardar los datos
en sí. Es como el índice de una biblioteca: te dice dónde está cada libro y
cómo está organizado, pero no guarda los libros.

En el proyecto se crea la base de datos `kitti_catalog`. El Crawler la rellena
automáticamente con las tablas que descubre en S3. Otros servicios (Glue Job,
Athena si se quisiera añadir) pueden consultarla para saber qué columnas
existen sin tener que leer los archivos físicos.

---

## 5. ¿Qué es SageMaker y qué es un SageMaker Endpoint?

### SageMaker en general
SageMaker es el servicio de Machine Learning de AWS. Se encarga de:
- Provisionar la máquina (CPU/GPU) que entrenará el modelo.
- Ejecutar el código de entrenamiento en un contenedor Docker gestionado por
  AWS.
- Guardar el modelo entrenado en S3.
- Desplegar ese modelo para que pueda recibir peticiones en tiempo real.

### Training Job: `kitti-yolov8-training-<modo>`
Cuando Terraform (o Step Functions) lanza un **Training Job**:
1. AWS arranca una instancia EC2 (en este proyecto `ml.t2.medium` o
   `ml.g4dn.xlarge` con GPU).
2. Descarga el contenedor PyTorch oficial de AWS ECR.
3. Descarga el dataset YOLO del bucket `curated`.
4. Ejecuta `train.py` con los hiperparámetros configurados (epochs, batch,
   imgsz, etc.).
5. Guarda el modelo resultante (`model.tar.gz`) en el bucket
   `model-artifacts`.
6. Apaga la instancia. Ya no cobra.

### SageMaker Endpoint: `kitti-yolov8-endpoint`
Un **Endpoint** es una URL de inferencia en tiempo real. Una vez desplegado:
- AWS mantiene una instancia encendida con el modelo cargado en memoria.
- Cualquier petición HTTP a esa URL recibe una respuesta con las predicciones
  en milisegundos.
- **Importante**: el endpoint cobra mientras está encendido, aunque no reciba
  peticiones. Por eso el proyecto lo deja como opcional y avisa que se debe
  apagar después de la demo.

La cadena completa es:  
`train.py entrena → model.tar.gz en S3 → SageMaker Model → Endpoint Config → Endpoint activo`

---

## 6. API Gateway

**¿Qué es?**
API Gateway es el "portero" de la API. Es el punto de entrada público que
recibe peticiones HTTP del mundo exterior y las dirige al servicio correcto
(en este caso, a la Lambda).

En el proyecto se crea una **REST API** con dos rutas:

| Ruta | Método | API Key | Qué hace |
|------|--------|---------|----------|
| `/predict` | POST | Sí, obligatoria | Envía una imagen y recibe detecciones |
| `/health` | GET | No | Comprueba si el endpoint de SageMaker está vivo |

API Gateway también gestiona:
- **Throttling**: máximo 2 peticiones por segundo (burst de 5). Evita que
  alguien abuse del endpoint.
- **Quota**: máximo 1.000 peticiones al mes.
- **CORS**: permite que el frontend (que corre en un dominio diferente) llame
  a la API sin que el navegador lo bloquee.

---

## 7. Cómo se logra HTTPS

El frontend es un sitio estático en S3. S3 por sí solo no da HTTPS ni un
dominio bonito. Para resolverlo se usa **Amazon CloudFront**.

**¿Qué es CloudFront?**
Es la CDN (red de distribución de contenido) de AWS. Tiene más de 400 puntos
de presencia en el mundo. Cuando un usuario pide `index.html`, CloudFront lo
sirve desde el nodo más cercano a él.

Cómo se logra HTTPS en este proyecto:
1. El bucket S3 de frontend tiene **todo el acceso público bloqueado**.
   Nadie puede acceder directamente.
2. CloudFront tiene un **Origin Access Control (OAC)**: un permiso especial
   firmado que solo CloudFront puede usar para leer del bucket S3.
3. CloudFront termina el HTTPS hacia el usuario con un certificado TLS
   gestionado por AWS (sin costo extra). La política
   `viewer_protocol_policy = "redirect-to-https"` hace que cualquier petición
   HTTP se redirige automáticamente a HTTPS.
4. Se añaden cabeceras de seguridad: `Strict-Transport-Security`, `X-Frame-Options: DENY`,
   `X-XSS-Protection`, etc.

Resultado: el usuario solo puede acceder por HTTPS a través de CloudFront.
El bucket S3 nunca queda expuesto.

---

## 8. CloudWatch y cómo se aplica aquí

**¿Qué es CloudWatch?**
CloudWatch es el sistema de observabilidad de AWS. Hace tres cosas:
- **Logs**: guarda registros de texto de lo que hacen los servicios.
- **Métricas**: números que cambian en el tiempo (latencia, errores, duración).
- **Alarmas**: reglas del tipo "si esta métrica supera X, haz Y".

En el proyecto:

### Log Groups (grupos de logs)
Se crean grupos de logs para las tres Lambdas (`api_handler`,
`prepare_yolo`, `training_results_notifier`) y para Step Functions. Retención
de 7 días para no acumular costo.

### Métricas personalizadas
El Glue Job manda métricas al namespace `KittiMLProject/DataEngineering`:
- `TotalImagesProcessed`
- `TotalAnnotationsProcessed`
La Lambda `prepare_yolo` manda al namespace `KittiMLProject/Storage`:
- `CuratedObjectCount`, `YoloTrainImages`, `YoloValImages`

### Alarmas
- **`kitti-sagemaker-5xx-rate-high`**: si el endpoint de SageMaker devuelve al
  menos un error 5XX en 5 minutos, se dispara. Acción: publicar en el topic SNS
  (ver sección 9), lo que manda un correo de aviso.
- **Alarma manual recomendada**: `kitti-sagemaker-endpoint-still-running`,
  para alertar si el endpoint lleva 6 horas encendido sin peticiones (coste
  innecesario).

### Dashboard: `kitti-ml-dashboard`
Un panel visual en la consola de AWS con 5 gráficas:
1. Duración del Glue Job.
2. Conteo de objetos YOLO en curated.
3. Latencia y errores del SageMaker Endpoint.
4. Tráfico y errores de API Gateway.
5. Invocaciones, errores y duración de la Lambda de la API.

---

## 9. SNS y cómo se aplica aquí

**¿Qué es SNS?**
SNS (Simple Notification Service) es el sistema de notificaciones pub/sub de
AWS. Funciona así: alguien **publica** un mensaje en un "topic" (canal) y
todos los que están **suscritos** a ese topic lo reciben.

En el proyecto se crea **un único topic**: `kitti-detections`.

### ¿Hay SNS al propio sistema y al usuario?

**Sí, el mismo topic sirve para ambos casos:**

| Quién publica | En qué momento | Quién recibe |
|---------------|---------------|--------------|
| `training_results_notifier` (Lambda) | Al terminar el entrenamiento | El correo configurado en `notification_email` → **el desarrollador/usuario** |
| Step Functions | Si cualquier paso falla | El mismo correo → **el desarrollador** |
| CloudWatch Alarm | Si el endpoint devuelve errores 5XX | El mismo correo → **el desarrollador** |

Hay solo un topic, pero cumple dos roles: notifica al sistema en caso de fallos
(observabilidad interna) y notifica al usuario con los resultados del
entrenamiento (comunicación hacia afuera). Con SNS se pueden añadir más
suscriptores sin cambiar el código: otro correo, un webhook, una cola SQS, etc.

---

## 10. PySpark en el proyecto: ¿no debería ser solo imágenes?

Esta es una pregunta clave y la respuesta requiere entender qué datos maneja
el proyecto.

**El dataset KITTI tiene dos partes:**
1. **Imágenes** (`.png`, ~12 GB): fotos desde el coche.
2. **Etiquetas** (`.txt`, unos pocos MB): un archivo de texto por imagen con
   las anotaciones (clase del objeto, coordenadas del bounding box, etc.).

**PySpark (Glue Job) solo procesa las etiquetas, no las imágenes.**

Las etiquetas son texto tabular: cada línea es una fila con 15 columnas
separadas por espacios. Eso sí es un ETL clásico:
- Leer miles de archivos `.txt`.
- Parsear cada línea como una fila de una tabla.
- Filtrar clases irrelevantes.
- Calcular campos derivados (centro del bbox, área).
- Escribir en Parquet para consultas eficientes.

Las imágenes nunca pasan por Glue. Van directamente de S3 `raw` a SageMaker
durante el entrenamiento (las lee `train.py` con OpenCV/PIL), y durante la
inferencia las manda el usuario a la API.

**Resumen**: Sí se puede hacer ETL en este proyecto porque hay datos tabulares
(las etiquetas). Glue no toca las imágenes porque no es necesario transformarlas;
SageMaker las consume directamente.

---

## 11. Objetivo de cada carpeta en `/modules`

Los módulos son la forma en que Terraform divide la infraestructura en
responsabilidades. Cada módulo es una carpeta independiente que agrupa recursos
relacionados y puede recibir variables de entrada y devolver outputs.

```
terraform/modules/
├── storage/         ← Los 5 buckets S3, versionado, cifrado, políticas de acceso
├── data-eng/        ← Glue: IAM role, Crawler, Job, Data Catalog
├── ai-inference/    ← SageMaker (training + endpoint) + Lambda API + API Gateway + API Key
├── frontend/        ← Bucket frontend, CloudFront distribution, assets estáticos
├── orchestration/   ← Step Functions, SNS, Lambdas del pipeline (prepare_yolo, notifier)
└── observability/   ← CloudWatch log groups, alarmas, dashboard
```

**¿Por qué dividir así?**
- Claridad: sabes exactamente en qué módulo buscar si algo falla.
- Encapsulamiento: cada módulo solo conoce sus propios recursos. Le pasas
  variables (como el nombre del bucket raw) y devuelve outputs (como el ARN
  del topic SNS).
- Reutilización: si en otro proyecto necesitas la misma estructura de storage,
  copias ese módulo.

---

## 12. Cómo entra IAM en el proyecto

**¿Qué es IAM?**
IAM (Identity and Access Management) es el sistema de permisos de AWS. La
regla de oro es: **ningún servicio puede hacer nada a menos que IAM lo autorice
explícitamente**.

En el proyecto cada servicio tiene su propio rol IAM con permisos mínimos
(principio de mínimo privilegio):

| Rol | Quién lo asume | Qué puede hacer |
|-----|---------------|-----------------|
| `KittiGlueRole` | AWS Glue | Leer de `raw`, escribir en `curated`, escribir logs en CloudWatch |
| `KittiSageMakerRole` | AWS SageMaker | Leer de `curated`, leer/escribir en `model-artifacts`, bajar imágenes de ECR, escribir logs |
| `KittiPrepareYoloLambdaRole` | Lambda `prepare_yolo` | Leer de `raw` y `curated`, mandar métricas a CloudWatch |
| `KittiTrainingResultsLambdaRole` | Lambda `training_notifier` | Leer/escribir en `model-artifacts`, publicar en SNS, describir Training Jobs |
| `KittiRestApiLambdaRole` | Lambda `api_handler` | Invocar el SageMaker Endpoint, leer de `input` y `raw`, escribir logs |
| `KittiStepFunctionsRole` | AWS Step Functions | Iniciar Glue Crawler/Job, invocar Lambdas, crear Training Jobs, actualizar Endpoint, publicar en SNS |

**¿Cómo funciona "asumir un rol"?**
Cuando Glue necesita leer un archivo de S3, AWS verifica: "¿el rol que tiene
Glue tiene permiso `s3:GetObject` sobre ese bucket?" Si la política dice que sí,
la operación se permite. Si no está en la política, AWS la deniega aunque el
servicio intente hacerlo.

Terraform crea todos estos roles y políticas automáticamente. Sin IAM, ningún
servicio podría comunicarse con otro.

---

## 13. Por qué se pide API Key en `/predict` y cómo entra en el proyecto

### Por qué se pide
El endpoint de SageMaker cuesta dinero por cada inferencia. Sin protección,
cualquier persona que descubra la URL podría hacer miles de peticiones y
generar un gasto inesperado. La API Key es una primera barrera de control:
solo quien tenga la clave puede llamar a `/predict`.

Además, como la API Key está vinculada a un **Usage Plan**, Terraform configura:
- Máximo **2 peticiones por segundo** (rate limit).
- Burst de **5 peticiones**.
- Cuota de **1.000 peticiones al mes**.

Si alguien intenta abusar, API Gateway rechaza las peticiones de más con un
`429 Too Many Requests` antes de que lleguen a Lambda o SageMaker.

### Cómo se genera la API Key
1. Terraform crea el recurso `aws_api_gateway_api_key` con `enabled = true`.
   AWS genera automáticamente un string alfanumérico aleatorio (la clave).
2. Se crea un `aws_api_gateway_usage_plan` que asocia la API y el stage (`dev`)
   con los límites de throttling y quota.
3. Se crea un `aws_api_gateway_usage_plan_key` que vincula la API Key al
   Usage Plan.
4. El método `POST /predict` tiene `api_key_required = true`.

Para obtener el valor de la clave después de `terraform apply`:
```bash
terraform output api_key_value
# o desde la consola AWS → API Gateway → API Keys → kitti-ml-rest-api-key → Show
```

### Cómo se usa en las peticiones
El cliente (el frontend o Postman) debe incluir la cabecera:
```
x-api-key: <valor-de-la-clave>
```
Si la cabecera falta o el valor es incorrecto, API Gateway devuelve `403 Forbidden`
sin llegar a la Lambda.

---

## 14. Por qué se repite `main.tf`, `variables.tf`, `outputs.tf` en cada módulo

Esta es una pregunta de arquitectura Terraform, no de AWS.

Terraform no tiene un sistema de "importar" como Python o JavaScript. Cada
módulo es una unidad completamente autónoma. Para que un módulo reciba datos
del exterior y los devuelva, necesita declarar explícitamente qué acepta y
qué devuelve. De ahí la triada obligatoria:

| Archivo | Qué contiene | Analogía |
|---------|-------------|----------|
| `main.tf` | Los recursos reales que se crean en AWS | El cuerpo de una función |
| `variables.tf` | Las entradas del módulo (lo que necesita saber de fuera) | Los parámetros de una función |
| `outputs.tf` | Los valores que el módulo expone para que otros módulos los usen | El `return` de una función |

**Ejemplo concreto**: el módulo `storage` crea los buckets y en `outputs.tf`
devuelve `raw_bucket_arn`. El módulo `data-eng` recibe ese ARN en su
`variables.tf` como `raw_bucket_arn` y lo usa en la política IAM de Glue.
El módulo `ai-inference` lo recibe también para que SageMaker pueda leer de él.

Que el patrón se repita en cada carpeta es intencionado: garantiza que cada
módulo sea independiente y comprensible por sí solo.

---

## 15. Cómo funciona Step Functions (el pipeline completo)

**¿Qué es Step Functions?**
Step Functions es el orquestador de AWS. Piénsalo como un diagrama de flujo
ejecutable: defines estados (pasos) y transiciones (flechas). AWS se encarga
de ejecutar cada paso en orden, manejar errores y reintentos, y hacer esperas
sin consumir cómputo.

El pipeline `kitti-ml-pipeline` tiene estos pasos en orden:

```
[1] StartGlueCrawler
      │  Lanza el Crawler para catalogar los labels en raw/
      ↓
[2] WaitForCrawler → GetCrawlerStatus → CrawlerFinishedChoice
      │  Espera 30s, consulta el estado, vuelve a esperar si sigue corriendo
      ↓
[3] RunGlueJob
      │  Lanza el Job de Spark (ETL: txt → Parquet). Espera a que termine.
      ↓
[4] PrepareYOLODataset (Lambda)
      │  Convierte Parquet → formato YOLO. Crea carpetas train/ val/ en curated.
      ↓
[5] BuildTrainingNames (Pass)
      │  Genera nombres únicos para el Training Job, Model, Endpoint Config
      ↓
[6] StartSageMakerTraining
      │  Lanza el Training Job. Espera (puede tardar 20-60 min).
      ↓
[7] NotifyTrainingResults (Lambda)
      │  Manda correo con métricas y URL del modelo
      ↓
[8] DeployEndpointChoice
      │  ¿Se debe desplegar el endpoint?
      ├── No → FinalSuccess (fin)
      └── Sí → [9] CreateSageMakerModel → CreateEndpointConfig → UpdateEndpoint
                    │  Despliega el modelo en el endpoint en tiempo real
                    ↓
               [10] FinalSuccess

En cualquier paso con error:
      → NotifyFailure (publica en SNS) → Fail
```

Cada estado de tipo `Task` llama a un servicio de AWS y espera su respuesta.
Los estados de tipo `Wait` hacen una pausa sin consumir cómputo. El estado
`Choice` es como un `if`.

El archivo `workflow.json` define esta máquina de estados. Terraform lo lee
con `templatefile()` y sustituye los ARNs, nombres y parámetros reales antes
de subirlo a AWS.

---

## 16. La "temporalidad" de cada componente

Una pregunta clave en costes y arquitectura es: **¿cuándo está encendido cada servicio?**

| Servicio | ¿Cuándo existe/corre? | ¿Cuándo cuesta? |
|----------|----------------------|----------------|
| **Buckets S3** | Siempre (desde `terraform apply`) | Solo por GB almacenados y peticiones |
| **Glue Crawler** | Solo mientras cataloga (~1-2 min por ejecución) | Por DPU-hora durante la ejecución |
| **Glue Job** | Solo mientras procesa los datos (~5-10 min) | Por DPU-hora durante la ejecución |
| **Lambda (todas)** | Arranca en ms, vive mientras procesa | Por ms de ejecución y GB de RAM |
| **SageMaker Training Job** | Solo mientras entrena (20-60 min) | Por hora de instancia durante el entrenamiento |
| **SageMaker Endpoint** | **Siempre encendido** desde que se despliega | **Por hora de instancia, 24/7** — ¡APAGARLO después de la demo! |
| **API Gateway** | Siempre disponible (serverless) | Solo por petición recibida |
| **CloudFront** | Siempre disponible (CDN global) | Por GB transferidos y peticiones |
| **Step Functions** | Solo durante la ejecución del pipeline | Por transición de estado |
| **SNS** | Siempre disponible | Solo por mensaje publicado |
| **CloudWatch Logs** | Siempre disponible | Por GB ingestados y retenidos |
| **CloudWatch Alarms** | Siempre monitorizando | Por alarma activa al mes |
| **IAM Roles** | Siempre existen | Sin costo |

### El flujo temporal del proyecto completo:

```
Día 0: terraform apply
  └── Se crean buckets, roles IAM, Glue catalog, API Gateway,
      CloudFront, SNS, Lambda, CloudWatch. Todo listo pero "dormido".

Día 1: se sube el dataset KITTI
  └── upload_kitti.py copia imágenes y labels al bucket raw. S3 cobra.

Día 1 (continúa): se ejecuta Step Functions
  ├── Glue Crawler corre ~2 min y se apaga.
  ├── Glue Job corre ~10 min con Spark y se apaga.
  ├── Lambda prepare_yolo corre ~1 min y se apaga.
  └── SageMaker Training Job corre ~30-60 min y se apaga.
      → Correo con resultados via SNS.

Día 1 (si se despliega endpoint):
  └── SageMaker Endpoint se enciende → COBRA POR HORA.

Día 2: demo
  └── Usuario sube imagen → CloudFront → API Gateway → Lambda → Endpoint → detecciones.

Después de la demo: terraform destroy (o apagar endpoint manualmente)
  └── Se destruye todo. Deja de cobrar.
```

---

*Documento generado para la exposición del proyecto Cloud Data IA — Mayo 2026.*


storage/ — Crea las carpetas gigantes (buckets S3) donde vive todo. Sin esto, nada más puede existir.

data-eng/ — Crea las herramientas que limpian los datos. El Crawler los examina, el Job de Glue los transforma y los deja listos para entrenar.

ai-inference/ — Crea todo lo relacionado con el modelo: lo entrena con SageMaker, lo despliega como endpoint, y monta la API (/predict, /health) con Lambda y API Gateway para que el mundo pueda usarlo.

frontend/ — Publica la página web. Sube el HTML/CSS/JS a S3 y lo sirve por CloudFront con HTTPS.

orchestration/ — Crea el "director de orquesta" (Step Functions) que une todo el pipeline en orden: Glue → Lambda → SageMaker → notificación. También crea el canal de correos (SNS).

observability/ — Crea los "ojos" del sistema: logs, métricas, dashboard y alarmas en CloudWatch para saber si algo falla o va lento.


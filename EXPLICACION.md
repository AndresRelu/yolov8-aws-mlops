# EXPLICACION COMPLETA DEL PROYECTO

Este documento explica el proyecto completo desde el punto de vista de codigo,
infraestructura en AWS, flujo de datos y exposicion. La idea es que puedas
contarle a alguien, paso a paso, que hace cada pieza, como se conecta con las
demas y que deberias revisar en AWS Console durante una demo.

El proyecto principal vive en:

```text
cloud-data-ia-project/
```

Los archivos `instrucciones.md` y `PLAN.md` en la raiz son el contexto de
planeacion. El codigo real esta en `cloud-data-ia-project/`.

## 1. Resumen ejecutivo

Este proyecto construye una arquitectura MLOps end-to-end en AWS para entrenar
y servir un modelo YOLOv8 de deteccion de objetos sobre el dataset KITTI.

En palabras simples:

1. Se toma el dataset KITTI, que trae imagenes de carretera y archivos `.txt`
   con cajas delimitadoras.
2. Se sube el dataset crudo a S3.
3. AWS Glue lee las etiquetas crudas, las limpia, las convierte a Parquet y
   manda metricas a CloudWatch.
4. Un script prepara el dataset en formato YOLOv8, con carpetas `images/train`,
   `images/val`, `labels/train`, `labels/val` y un `kitti.yaml`.
5. SageMaker entrena YOLOv8 usando ese dataset desde S3.
6. SageMaker guarda el modelo entrenado como `model.tar.gz` en S3.
7. SageMaker Endpoint carga el modelo y responde predicciones.
8. API Gateway expone una API REST publica con `/health` y `/predict`.
9. Una Lambda recibe las peticiones HTTP, valida la imagen y llama al endpoint
   de SageMaker.
10. Un frontend web estatico, publicado en S3 + CloudFront, usa la camara del
    navegador, manda imagenes a la API y dibuja las detecciones.
11. Step Functions orquesta el pipeline de crawler, Glue, validacion de dataset,
    entrenamiento, publicacion de resultados y actualizacion opcional del
    endpoint.
12. CloudWatch centraliza logs, metricas, dashboard y alarma.
13. SNS manda correos de notificacion para resultados y fallas.

La frase para explicar el proyecto en una exposicion:

> Es un pipeline MLOps en AWS creado con Terraform. S3 funciona como data lake,
> Glue transforma etiquetas KITTI a datos curados, SageMaker entrena y sirve
> YOLOv8, API Gateway + Lambda exponen inferencia HTTP, un frontend consume la
> API, Step Functions orquesta el ciclo de entrenamiento y CloudWatch/SNS dan
> observabilidad y alertas.

## 2. Arquitectura de alto nivel

Diagrama conceptual:

```text
Dataset KITTI local
   |
   | scripts/upload_kitti.py
   v
S3 raw bucket
   |-- images/*.png
   |-- labels/*.txt
   |
   | Glue Crawler
   v
Glue Catalog Database
   |
   | Glue Job: src/glue/clean_data.py
   v
S3 curated bucket
   |-- labels_parquet/
   |-- yolo_dataset/
        |-- images/train/
        |-- images/val/
        |-- labels/train/
        |-- labels/val/
        |-- kitti.yaml
   |
   | SageMaker Training Job
   v
S3 model-artifacts bucket
   |-- sagemaker/source/sourcedir.tar.gz
   |-- training-output/<job>/output/model.tar.gz
   |-- training-results/<job>/results.png
   |-- training-results/<job>/results.csv
   |
   | SageMaker Model + Endpoint
   v
SageMaker real-time endpoint
   ^
   |
Lambda api_handler.py
   ^
   |
API Gateway REST API
   ^
   |
Frontend S3 + CloudFront
```

Orquestacion:

```text
Step Functions
   -> StartGlueCrawler
   -> Wait/GetCrawlerStatus
   -> RunGlueJob
   -> PrepareYOLODataset Lambda
   -> Create SageMaker Training Job
   -> Training Results Notifier Lambda
   -> Optional CreateModel/CreateEndpointConfig/UpdateEndpoint
   -> SNS success/failure email
```

Observabilidad:

```text
CloudWatch Logs
CloudWatch Metrics
CloudWatch Dashboard
CloudWatch Alarm
SNS email notification
```

## 3. Servicios de AWS usados y por que

### S3

S3 es el almacenamiento central. El proyecto usa varios buckets con roles
distintos:

- `raw`: datos originales de KITTI, sin transformar.
- `curated`: datos procesados, Parquet y dataset YOLO.
- `input`: imagenes que se pueden usar como entrada para inferencia por API.
- `model-artifacts`: codigo empaquetado de SageMaker, modelos y resultados.
- `frontend`: archivos estaticos del frontend web.

S3 se usa porque SageMaker, Glue, Lambda y Terraform se integran de manera
natural con S3. En MLOps real, S3 suele funcionar como data lake y repositorio
de artefactos.

### Glue

Glue se usa para la fase de data engineering:

- El Crawler explora los archivos crudos.
- El Catalog Database registra metadata.
- El Glue Job ejecuta PySpark para parsear y limpiar etiquetas.

La razon tecnica es que Glue permite procesar datos distribuidos sin levantar
manualmente servidores Spark.

### SageMaker

SageMaker se usa para:

- Ejecutar el entrenamiento en un contenedor administrado de PyTorch.
- Guardar el resultado del entrenamiento en S3.
- Crear un modelo desplegable.
- Publicar un endpoint real-time.

El proyecto usa YOLOv8 mediante `ultralytics`, dentro de SageMaker Script Mode.
Esto significa que AWS pone el contenedor y el proyecto pone los scripts
`train.py` e `inference.py`.

### Lambda

Lambda se usa como capa de pegamento:

- `api_handler.py`: recibe requests HTTP desde API Gateway y llama SageMaker.
- `prepare_yolo_handler.py`: valida que el dataset YOLO exista antes de
  entrenar.
- `training_results_notifier.py`: extrae `results.png` y `results.csv` del
  `model.tar.gz`, los sube a S3 y manda links por SNS.

Lambda es util porque son tareas cortas, event-driven y sin servidor.

### API Gateway

API Gateway publica una REST API con:

- `GET /health`
- `POST /predict`

No se expone SageMaker directamente a internet. La API publica es API Gateway,
y Lambda se encarga de validar payloads, CORS, API key y transformacion de la
respuesta.

### CloudFront

CloudFront sirve el frontend por HTTPS. El bucket S3 del frontend queda privado
y CloudFront accede con Origin Access Control.

Esto es importante porque los navegadores requieren HTTPS para algunas APIs
modernas y porque es mejor no dejar publico el bucket.

### Step Functions

Step Functions da un pipeline visual y auditable. Permite ver cada estado:

- crawler
- Glue job
- preparacion/verificacion YOLO
- training job
- publicacion de resultados
- despliegue del endpoint

Tambien maneja errores con `Catch` y manda notificaciones SNS.

### CloudWatch

CloudWatch concentra:

- Logs de Lambda.
- Logs de Glue.
- Logs de SageMaker.
- Metricas custom del ETL.
- Dashboard.
- Alarma de errores 5XX de SageMaker.

### SNS

SNS manda correos. En este proyecto se usa para:

- Avisar exito/falla del pipeline.
- Mandar links firmados a resultados de entrenamiento.
- Recibir alarmas de CloudWatch.

### IAM

IAM define que puede hacer cada servicio. Cada modulo Terraform crea roles
especificos:

- `KittiGlueRole`
- `KittiSageMakerRole`
- `KittiApiLambdaRole`
- `KittiPrepareYoloLambdaRole`
- `KittiTrainingResultsLambdaRole`
- `KittiStepFunctionsRole`

La idea es least privilege: cada servicio solo tiene permisos sobre los buckets,
endpoints o recursos que necesita.

## 4. Estructura real del repositorio

```text
cloud-data-ia-project/
  frontend/
    index.html
    app.js
    styles.css
    README.md

  scripts/
    upload_kitti.py
    package_sagemaker_source.sh
    tf-plan.sh
    tf-apply.sh
    verify-stack.sh
    setup_localstack.sh
    deploy.sh

  src/
    glue/
      clean_data.py

    lambda/
      api_handler.py
      prepare_yolo_handler.py
      training_results_notifier.py
      handler.py
      retraining_trigger.py

    sagemaker/
      train.py
      inference.py
      prepare_yolo_dataset.py
      requirements.txt

    step_functions/
      workflow.json

  terraform/
    main.tf
    variables.tf
    outputs.tf
    terraform.tfvars
    modules/
      storage/
      data-eng/
      ai-inference/
      frontend/
      orchestration/
      observability/
    resultados_kitti/
    tfplan

  build/
    sagemaker_source/

  README.md
```

Notas importantes sobre el estado real:

- `cloud-data-ia-project/README.md` esta vacio.
- `src/lambda/handler.py` esta vacio. En el plan era la Lambda de inferencia
  por evento S3, pero en el codigo funcional la inferencia se hace por API
  Gateway usando `api_handler.py`.
- `src/lambda/retraining_trigger.py` esta vacio. En el plan era la Lambda para
  reentrenamiento automatico por volumen de datos, pero en este snapshot no esta
  implementada.
- `scripts/setup_localstack.sh` y `scripts/deploy.sh` estan vacios.
- `terraform/tfplan`, `.terraform/`, `build/` y `terraform/resultados_kitti/`
  son artefactos generados o auxiliares, no la fuente principal de logica.
- `terraform/resultados_kitti/best.pt` parece ser un peso local de modelo ya
  entrenado o exportado.

Esto no arruina la exposicion, pero conviene explicarlo con claridad:

> La ruta funcional actual de inferencia es API Gateway + Lambda
> `api_handler.py` + SageMaker Endpoint. La Lambda vacia `handler.py` era para
> una variante event-driven con S3 input que quedo como placeholder.

## 5. Terraform raiz

Archivo:

```text
cloud-data-ia-project/terraform/main.tf
```

Este archivo es el punto de entrada de la infraestructura. Terraform lee este
archivo y desde aqui llama a todos los modulos.

### 5.1 Bloque `terraform`

Define:

- Version minima de Terraform: `>= 1.8`.
- Provider `aws`.
- Provider `archive`.
- Backend remoto S3 para guardar el estado.

El backend configurado es:

```text
bucket = kitti-terraform-state-840584084071
key    = cloud-data-ia-project/terraform.tfstate
region = us-east-1
```

Esto significa que el archivo de estado de Terraform no queda solo local, sino
en S3. El estado es importante porque Terraform necesita saber que recursos ya
creo y como se llaman en AWS.

Punto para explicar al profesor:

> Terraform no consulta solamente el codigo; tambien compara el codigo contra
> el estado remoto. Por eso existe un backend S3. Si se borra el state sin
> cuidado, Terraform puede perder la relacion con recursos ya creados.

### 5.2 Provider AWS

El provider usa:

```text
region = var.aws_region
```

Por defecto la region viene de `variables.tf` y es `us-east-1`.

Tambien aplica tags por defecto:

```text
Project
Environment
ManagedBy = Terraform
```

Esto sirve para identificar recursos en AWS Console y para buenas practicas de
cost allocation.

### 5.3 Modulos llamados desde raiz

La raiz declara estos modulos:

1. `storage`
2. `data-eng`
3. `frontend`
4. `ai-inference`
5. `orchestration`
6. `observability`

La conexion entre modulos ocurre mediante outputs y variables.

Ejemplo:

- `module.storage` crea los buckets.
- `module.storage.raw_bucket_arn` se pasa a `module.data-eng`.
- `module.data-eng.glue_job_name` se pasa a `module.orchestration`.
- `module.ai-inference.sagemaker_role_arn` se pasa a `module.orchestration`.
- `module.frontend.cloudfront_origin` se usa para configurar CORS de API
  Gateway.

Ese es el corazon de IaC:

```text
un modulo crea un recurso
otro modulo necesita su nombre o ARN
Terraform conecta ambos usando outputs
```

### 5.4 Locals principales

Archivo:

```text
cloud-data-ia-project/terraform/variables.tf
```

Terraform obtiene el account id:

```text
data "aws_caller_identity" "current" {}
```

Luego construye nombres globalmente unicos:

```text
kitti-ml-project-raw-${account_id}
kitti-ml-project-curated-${account_id}
kitti-ml-project-input-${account_id}
kitti-ml-project-model-artifacts-${account_id}
kitti-ml-project-frontend-${account_id}
```

Esto resuelve un problema real de S3: los nombres de buckets son globales, no
solo por cuenta. Si otra persona ya tomo `kitti-ml-project-raw`, fallaria. Con
el account id, el nombre es mucho mas probable que sea unico.

### 5.5 Variables importantes

En `variables.tf`:

- `notification_email`: correo que recibe SNS. No tiene default y es obligatorio.
- `mode`: `sample` o `full`.
- `epochs`: por defecto 100.
- `training_image_size`: por defecto 640.
- `training_batch_size`: por defecto 8.
- `yolo_model`: por defecto `yolov8m.pt`.
- `training_instance_type`: por defecto `ml.g4dn.xlarge`.
- `endpoint_instance_type`: por defecto `ml.g4dn.xlarge`.
- `deploy_sagemaker_endpoint`: permite crear o no el endpoint.
- `api_stage_name`: por defecto `dev`.
- `api_cors_origin`: si no se especifica, se usa el dominio CloudFront.

En `terraform.tfvars` actualmente:

```text
notification_email = "andresukilopez@gmail.com"
mode               = "full"
epochs             = 100
yolo_model         = "yolov8m.pt"
training_instance_type    = "ml.g4dn.xlarge"
endpoint_instance_type    = "ml.g4dn.xlarge"
deploy_sagemaker_endpoint = true
```

Explicacion:

- El plan original hablaba mucho de YOLOv8n por costo.
- El Terraform actual esta configurado para YOLOv8m, 100 epocas y GPU
  `ml.g4dn.xlarge`.
- Eso es mas serio para resultados, pero tambien mas caro que una prueba
  minima.

### 5.6 Outputs

Archivo:

```text
cloud-data-ia-project/terraform/outputs.tf
```

Los outputs imprimen informacion util despues de `terraform apply`:

- URIs de buckets.
- URL del frontend.
- dominio CloudFront.
- nombre/ARN del endpoint.
- URL base de API Gateway.
- API key id.
- ARN de Step Functions.
- ARN de SNS.
- nombre del dashboard.
- parametros de entrenamiento.

Estos outputs son muy importantes para la demo. Por ejemplo:

```bash
terraform -chdir=terraform output -raw frontend_url
terraform -chdir=terraform output -raw api_base_url
terraform -chdir=terraform output -raw api_key_id
```

## 6. Modulo `storage`

Ruta:

```text
cloud-data-ia-project/terraform/modules/storage/
```

Este modulo crea los buckets base del proyecto.

### 6.1 Buckets creados

En `main.tf` se crean:

- `aws_s3_bucket.raw`
- `aws_s3_bucket.curated`
- `aws_s3_bucket.input`
- `aws_s3_bucket.model_artifacts`

Cada bucket tiene:

- `force_destroy = true`
- tags del proyecto

`force_destroy = true` significa que Terraform puede borrar el bucket aunque
tenga objetos dentro. Es comodo para desarrollo, pero en produccion se usaria
con mucho mas cuidado.

### 6.2 Versionado

Se habilita versioning en los cuatro buckets.

Esto permite mantener versiones anteriores de objetos. Por ejemplo, si se sube
otra version de un label o un modelo, S3 puede conservar el historial.

### 6.3 Encriptacion

Todos los buckets usan SSE-S3:

```text
sse_algorithm = AES256
```

Esto significa que S3 cifra los objetos en reposo con llaves administradas por
AWS.

### 6.4 Bloqueo publico

Todos los buckets bloquean acceso publico:

- `block_public_acls`
- `block_public_policy`
- `ignore_public_acls`
- `restrict_public_buckets`

Esto es una buena practica porque los datos y modelos no deben quedar publicos.

### 6.5 Lifecycle del bucket raw

Solo el bucket raw tiene lifecycle:

- Mueve objetos a Glacier despues de 90 dias.
- Aborta multipart uploads incompletos despues de 7 dias.

Explicacion:

> Raw contiene datos originales que pueden ocupar bastante espacio. Despues de
> un tiempo se pueden archivar para bajar costo. Los multipart incompletos se
> limpian para no pagar basura acumulada.

### 6.6 Outputs

El modulo exporta ARNs:

- `raw_bucket_arn`
- `curated_bucket_arn`
- `input_bucket_arn`
- `model_artifacts_bucket_arn`

Otros modulos usan estos ARNs para crear politicas IAM con scope especifico.

## 7. Modulo `data-eng`

Ruta:

```text
cloud-data-ia-project/terraform/modules/data-eng/
```

Este modulo crea la parte de data engineering con Glue.

### 7.1 Glue Catalog Database

Recurso:

```text
aws_glue_catalog_database.kitti_catalog
```

Nombre:

```text
kitti_catalog
```

Este database es donde Glue puede registrar metadata de tablas y archivos.

### 7.2 IAM Role de Glue

Recurso:

```text
aws_iam_role.glue_role
```

Nombre:

```text
KittiGlueRole
```

Trust policy:

```text
glue.amazonaws.com
```

Esto permite que el servicio AWS Glue asuma ese role.

### 7.3 Politica de Glue

La politica permite:

- Leer bucket raw.
- Escribir/leer/borrar en bucket curated.
- Leer scripts desde model artifacts.
- Escribir logs en CloudWatch.
- Mandar metricas a CloudWatch.

Tambien se adjunta la policy administrada:

```text
AWSGlueServiceRole
```

Esa policy da permisos base que Glue normalmente necesita.

### 7.4 Subida del script `clean_data.py`

Terraform sube este archivo:

```text
src/glue/clean_data.py
```

a:

```text
s3://<model-artifacts-bucket>/glue-scripts/clean_data.py
```

Esto se hace con:

```text
aws_s3_object.clean_data_script
```

Glue necesita que el script este en S3 para ejecutarlo.

### 7.5 Glue Crawler

Recurso:

```text
aws_glue_crawler.kitti_labels_crawler
```

Nombre:

```text
kitti-labels-crawler
```

Ruta objetivo:

```text
s3://<raw-bucket>/labels/
```

El Crawler inspecciona los labels `.txt` de KITTI. En consola se ve en AWS Glue,
seccion Crawlers.

### 7.6 Glue Job

Recurso:

```text
aws_glue_job.clean_kitti_labels
```

Nombre:

```text
kitti-clean-labels-job
```

Config:

- Glue version `4.0`
- Worker type `G.1X`
- `number_of_workers = 2`
- Script en S3: `glue-scripts/clean_data.py`

Argumentos:

```text
--RAW_LABELS_PATH=s3://<raw-bucket>/labels/
--CURATED_OUTPUT_PATH=s3://<curated-bucket>/labels_parquet/
```

Conexion:

```text
raw labels en S3
   -> Glue Job ejecuta clean_data.py
   -> Parquet limpio en curated/labels_parquet/
   -> metricas custom a CloudWatch
```

## 8. Codigo `src/glue/clean_data.py`

Este archivo es el ETL de etiquetas KITTI.

Ruta:

```text
cloud-data-ia-project/src/glue/clean_data.py
```

### 8.1 Entrada

Recibe argumentos de Glue:

- `JOB_NAME`
- `RAW_LABELS_PATH`
- `CURATED_OUTPUT_PATH`

Los pasa Terraform desde el Glue Job.

### 8.2 Inicializacion

Crea:

- `SparkContext`
- `GlueContext`
- `spark_session`
- `Job`

Esto es el arranque normal de un Glue Job PySpark.

### 8.3 Lectura de archivos

Lee todos los `.txt` como texto:

```text
spark.read.text(RAW_LABELS_PATH)
```

Luego agrega `file_path` con `input_file_name()`. Eso sirve para saber de que
archivo salio cada linea.

### 8.4 Extraccion de `image_id`

Usa regex para sacar el ID:

```text
000001.txt -> 000001
```

Ese `image_id` es el puente entre:

- `labels/000001.txt`
- `images/000001.png`

### 8.5 Parseo del formato KITTI

Cada linea KITTI tiene:

```text
class truncated occluded alpha x1 y1 x2 y2 h w l x y z ry
```

El script separa por espacios y crea columnas:

- `image_id`
- `class_name`
- `truncated`
- `occluded`
- `alpha`
- `x1`
- `y1`
- `x2`
- `y2`
- `height`
- `width`
- `length`
- `x`
- `y`
- `z`
- `rotation_y`

### 8.6 Filtro de clases

Conserva:

- `Car`
- `Pedestrian`
- `Cyclist`
- `Van`
- `Truck`

Descarta clases fuera de esa lista, como `DontCare` o `Misc`.

### 8.7 Calculo de bounding boxes

Calcula:

- `bbox_width = x2 - x1`
- `bbox_height = y2 - y1`
- `bbox_area = bbox_width * bbox_height`
- `center_x_pixels`
- `center_y_pixels`

Importante:

El Glue Job no normaliza a YOLO todavia. Solo calcula centros y tamanos en
pixeles. La normalizacion real necesita ancho y alto de cada imagen, y eso se
hace despues en `prepare_yolo_dataset.py`.

### 8.8 Escritura Parquet

Escribe en:

```text
s3://<curated-bucket>/labels_parquet/
```

Modo:

```text
overwrite
```

Esto permite re-ejecutar el job sin duplicar datos.

### 8.9 Metricas CloudWatch

Envia metricas custom al namespace:

```text
KittiMLProject/DataEngineering
```

Metricas:

- `ProcessedImages`
- `FailedImages`
- `ProcessedAnnotations`
- `AvgFileSize`

En AWS Console:

```text
CloudWatch -> Metrics -> Custom namespaces -> KittiMLProject/DataEngineering
```

## 9. Script `scripts/upload_kitti.py`

Este script sube el dataset KITTI local a S3 raw.

Ruta:

```text
cloud-data-ia-project/scripts/upload_kitti.py
```

### 9.1 Entrada local esperada

El argumento `--dataset-root` debe apuntar a una carpeta que tenga:

```text
image_2/
label_2/
```

Por ejemplo:

```text
data/raw/kitti/training/
```

### 9.2 Salida en S3

Sube:

```text
image_2/000001.png -> s3://<raw-bucket>/images/000001.png
label_2/000001.txt -> s3://<raw-bucket>/labels/000001.txt
```

Esta organizacion es clave porque:

- Glue lee `labels/`.
- `prepare_yolo_dataset.py` busca imagenes en `images/<image_id>.png`.

### 9.3 Validacion de pares

Por cada imagen, busca su label:

```text
000001.png necesita 000001.txt
```

Si falta la etiqueta, omite la imagen.

### 9.4 Modo sample

Con:

```bash
python scripts/upload_kitti.py --sample --sample-size 100 ...
```

sube solo una muestra. Esto sirve para pruebas baratas antes de procesar todo
KITTI.

### 9.5 Optimizaciones

El script usa:

- `ThreadPoolExecutor` para subidas paralelas.
- `TransferConfig` para multipart upload.
- `botocore.config.Config` con reintentos adaptativos.
- `tqdm` para barra de progreso.
- Comparacion de tamanos para no re-subir archivos que ya existen.

### 9.6 Comando ejemplo

```bash
AWS_PROFILE=kitti-ml python scripts/upload_kitti.py \
  --dataset-root data/raw/kitti/training \
  --raw-bucket kitti-ml-project-raw-840584084071 \
  --sample \
  --sample-size 100 \
  --profile kitti-ml \
  --region us-east-1
```

Para dataset completo, se quita `--sample`.

## 10. Preparacion del dataset YOLO

Archivo:

```text
cloud-data-ia-project/src/sagemaker/prepare_yolo_dataset.py
```

Este script convierte la salida curada de Glue a formato YOLOv8.

### 10.1 Entrada

Lee Parquet desde:

```text
s3://<curated-bucket>/labels_parquet/
```

Tambien lee imagenes desde:

```text
s3://<raw-bucket>/images/
```

### 10.2 Por que se necesita

KITTI y YOLO usan formatos diferentes.

KITTI:

```text
class truncated occluded alpha x1 y1 x2 y2 h w l x y z ry
```

YOLO:

```text
class_id center_x center_y width height
```

Pero YOLO exige que `center_x`, `center_y`, `width` y `height` esten
normalizados entre 0 y 1 usando el tamano real de la imagen.

### 10.3 Mapeo de clases

El script usa:

```text
Car        -> 0
Pedestrian -> 1
Cyclist    -> 2
Van        -> 3
Truck      -> 4
```

### 10.4 Split train/val

Hace split 80/20:

```text
80% train
20% val
```

Con semilla fija `42`, para que el resultado sea reproducible.

### 10.5 Lectura de dimensiones reales

Para cada imagen:

1. Descarga el objeto de S3.
2. Abre la imagen con PIL.
3. Obtiene `img_w` e `img_h`.
4. Normaliza los bounding boxes.

Esto es mejor que asumir una resolucion fija, porque KITTI puede tener
variaciones de tamano.

### 10.6 Salida

Escribe en:

```text
s3://<curated-bucket>/yolo_dataset/
```

Con estructura:

```text
yolo_dataset/
  images/train/*.png
  images/val/*.png
  labels/train/*.txt
  labels/val/*.txt
  kitti.yaml
```

### 10.7 `kitti.yaml`

El archivo `kitti.yaml` le dice a Ultralytics donde estan las carpetas y cuales
son las clases.

Para SageMaker se crea con:

```text
path: /opt/ml/input/data/dataset
train: images/train
val: images/val
names:
  0: Car
  1: Pedestrian
  2: Cyclist
  3: Van
  4: Truck
```

Esa ruta `path` coincide con la ruta donde SageMaker monta el canal de datos.

### 10.8 Comando ejemplo

```bash
python src/sagemaker/prepare_yolo_dataset.py \
  --raw-bucket kitti-ml-project-raw-840584084071 \
  --curated-bucket kitti-ml-project-curated-840584084071 \
  --sample-size 100 \
  --region us-east-1 \
  --profile kitti-ml
```

Para full dataset, se quita `--sample-size` o se usa un valor mayor.

### 10.9 Importante sobre Step Functions

En el estado actual del repo, Step Functions no ejecuta este script completo.
La Lambda `prepare_yolo_handler.py` solo valida que el dataset YOLO ya exista
en S3 y cuenta objetos.

Entonces el orden correcto es:

```text
1. Glue crea labels_parquet/
2. Se ejecuta prepare_yolo_dataset.py para crear yolo_dataset/
3. Step Functions puede validar y entrenar
```

Si el profesor pregunta:

> La preparacion pesada del dataset YOLO esta en un script Python separado
> porque leer muchas imagenes y convertir todo el dataset puede exceder los
> limites de Lambda. La Lambda del pipeline valida que el dataset ya este
> preparado y emite metricas.

## 11. Modulo `ai-inference`

Ruta:

```text
cloud-data-ia-project/terraform/modules/ai-inference/
```

Este modulo es grande porque incluye dos bloques principales:

1. SageMaker training/model/endpoint.
2. API Gateway + Lambda REST API.

### 11.1 Locals de imagenes Docker

El modulo elige imagenes ECR de PyTorch segun la instancia:

- Si `training_instance_type == ml.g4dn.xlarge`, usa imagen GPU.
- Si no, usa imagen CPU.

Lo mismo para inferencia:

- `ml.g4dn.xlarge` usa imagen PyTorch GPU.
- Otra instancia usa imagen PyTorch CPU.

Esto permite cambiar instancia sin cambiar todo el codigo.

### 11.2 IAM Role de SageMaker

Role:

```text
KittiSageMakerRole
```

Trust:

```text
sagemaker.amazonaws.com
```

Permisos:

- Leer curated dataset.
- Leer/escribir model artifacts.
- Logs y metricas CloudWatch.
- Leer imagenes ECR necesarias para contenedores.

### 11.3 Empaquetado de codigo SageMaker

Terraform usa `archive_file` para crear:

```text
build/sourcedir.tar.gz
```

Incluye:

- `train.py`
- `inference.py`
- `requirements.txt`

Luego lo sube a:

```text
s3://<model-artifacts-bucket>/sagemaker/source/sourcedir.tar.gz
```

Ese archivo es lo que SageMaker Script Mode usa como codigo fuente.

### 11.4 SageMaker Training Job

Recurso:

```text
aws_sagemaker_training_job.kitti_yolov8_training
```

Nombre:

```text
kitti-yolov8-training-${mode}
```

Canal de datos:

```text
channel_name = dataset
s3_uri       = s3://<curated-bucket>/yolo_dataset/
```

SageMaker monta ese canal dentro del contenedor en:

```text
/opt/ml/input/data/dataset/
```

Por eso `train.py` busca:

```text
/opt/ml/input/data/dataset/kitti.yaml
```

Salida:

```text
s3://<model-artifacts-bucket>/training-output/
```

Hiperparametros:

- `mode`
- `epochs`
- `imgsz`
- `batch`
- `model`
- `sagemaker_program=train.py`
- `sagemaker_submit_directory=s3://.../sourcedir.tar.gz`

### 11.5 Espera del artefacto de entrenamiento

El recurso:

```text
terraform_data.wait_for_training_artifact
```

ejecuta AWS CLI local para:

1. Esperar a que termine el training job.
2. Confirmar que el estado sea `Completed`.
3. Revisar que exista:

```text
s3://<model-artifacts-bucket>/training-output/<training-job>/output/model.tar.gz
```

Esto es importante porque el modelo y endpoint dependen de que el training job
haya terminado y el artefacto exista.

Punto fino para explicar:

> Terraform normalmente crea recursos, pero un training job es un proceso largo.
> Aqui se uso `terraform_data` con `local-exec` para esperar a que el artefacto
> exista antes de crear el modelo y endpoint.

### 11.6 SageMaker Model

Recurso:

```text
aws_sagemaker_model.kitti_model
```

Se crea solo si:

```text
deploy_sagemaker_endpoint = true
```

Usa:

- Imagen de inferencia PyTorch.
- `model_data_url` apuntando a `model.tar.gz`.
- Variables de entorno para decirle a SageMaker que use `inference.py`.

### 11.7 Endpoint Configuration

Recurso:

```text
aws_sagemaker_endpoint_configuration.kitti_endpoint_config
```

Define:

- Modelo a servir.
- Instancia de inferencia.
- Numero de instancias iniciales.
- Variante `AllTraffic`.

### 11.8 SageMaker Endpoint

Recurso:

```text
aws_sagemaker_endpoint.kitti_endpoint
```

Nombre:

```text
kitti-yolov8-endpoint
```

Este endpoint cobra mientras este prendido, aunque nadie lo use. Para una demo
hay que destruirlo si ya no se necesita.

### 11.9 Lambda REST API

El mismo modulo crea:

```text
aws_lambda_function.rest_api_handler
```

Nombre:

```text
kitti-rest-api-handler
```

Codigo:

```text
src/lambda/api_handler.py
```

Variables de entorno:

- `SAGEMAKER_ENDPOINT_NAME`
- `ALLOWED_IMAGE_BUCKETS`
- `DEFAULT_CONFIDENCE_THRESHOLD`
- `MAX_IMAGE_BYTES`
- `CORS_ORIGIN`

Esta Lambda es el puente:

```text
API Gateway -> Lambda -> SageMaker Runtime -> SageMaker Endpoint
```

### 11.10 API Gateway

Crea una REST API:

```text
kitti-ml-rest-api
```

Recursos:

- `/health`
- `/predict`

Metodos:

- `GET /health`, sin API key.
- `POST /predict`, requiere API key.
- `OPTIONS /predict`, para CORS.

Integracion:

```text
AWS_PROXY hacia kitti-rest-api-handler
```

Esto significa Lambda proxy integration: API Gateway manda casi todo el evento
HTTP a Lambda y Lambda regresa `statusCode`, `headers` y `body`.

### 11.11 API Key y Usage Plan

Terraform crea:

- `kitti-ml-rest-api-key`
- `kitti-ml-rest-api-usage-plan`

Limites:

- `burst_limit = 5`
- `rate_limit = 2`
- `quota = 1000 por mes`

Esto protege de llamadas accidentales. Aunque API Gateway sea barato, cada
request puede llamar al endpoint de SageMaker.

## 12. Codigo `src/sagemaker/train.py`

Este script corre dentro del contenedor de entrenamiento de SageMaker.

### 12.1 Argumentos

Recibe:

- `--mode`
- `--epochs`
- `--imgsz`
- `--batch`
- `--model`
- `--model-dir`
- `--output-data-dir`

SageMaker convierte los hyperparameters de Terraform en argumentos CLI.

### 12.2 Ruta del dataset

Busca:

```text
/opt/ml/input/data/dataset/kitti.yaml
```

Esto coincide con:

```text
channel_name = dataset
```

en Terraform.

### 12.3 Carga de modelo base

Usa:

```text
YOLO(args.model)
```

Actualmente el default en Terraform es:

```text
yolov8m.pt
```

Antes el plan mencionaba `yolov8n.pt`, que es mas barato y ligero. El codigo
actual esta listo para cualquiera mientras se pase en variable.

### 12.4 Entrenamiento

Llama:

```text
model.train(...)
```

Parametros clave:

- `data=dataset_yaml`
- `epochs`
- `imgsz`
- `batch`
- `project=args.output_data_dir`
- `name=kitti_train`
- `plots=True`

Ultralytics guarda resultados en:

```text
/opt/ml/output/kitti_train/
```

### 12.5 Metricas

Extrae de `results.results_dict`:

- precision
- recall
- mAP50
- mAP50-95

Las imprime en logs. En SageMaker/CloudWatch se pueden revisar en los logs del
training job.

### 12.6 Empaquetado del modelo

Busca:

```text
/opt/ml/output/kitti_train/weights/best.pt
```

Lo copia a:

```text
/opt/ml/model/best.pt
```

Todo lo que quede en `/opt/ml/model` SageMaker lo empaqueta como:

```text
model.tar.gz
```

### 12.7 Resultados visuales

Copia a `/opt/ml/model/evaluation/`:

- `results.png`
- `results.csv`

Luego `training_results_notifier.py` puede encontrarlos dentro de
`model.tar.gz`.

### 12.8 Codigo de inferencia dentro del modelo

Crea:

```text
/opt/ml/model/code/inference.py
/opt/ml/model/code/requirements.txt
```

Esto ayuda a que el modelo desplegado tenga el codigo necesario para servir
predicciones.

## 13. Codigo `src/sagemaker/inference.py`

Este archivo define como SageMaker Endpoint carga el modelo, interpreta entradas
y regresa salidas.

SageMaker espera funciones con nombres especiales:

- `model_fn`
- `input_fn`
- `predict_fn`
- `output_fn`

### 13.1 `model_fn(model_dir)`

Busca:

```text
best.pt
```

en el directorio del modelo y carga:

```text
YOLO(model_path)
```

Si no existe, falla con `FileNotFoundError`.

### 13.2 `input_fn(request_body, content_type)`

Acepta:

- JSON con `image_base64`
- `image/png`
- `image/jpeg`
- `application/octet-stream`

Convierte la imagen a PIL RGB.

Esto permite que el endpoint reciba imagenes desde Lambda de forma flexible.

### 13.3 `predict_fn(input_data, model)`

Llama:

```text
model.predict(input_data, conf=DEFAULT_CONFIDENCE)
```

Luego extrae:

- clase
- confianza
- bounding box `xyxy`

Regresa:

```json
{
  "detections": [
    {
      "class_id": 0,
      "class_name": "Car",
      "confidence": 0.91,
      "bbox": [x1, y1, x2, y2]
    }
  ]
}
```

### 13.4 `output_fn(prediction, accept)`

Regresa JSON si el cliente acepta:

- `application/json`
- `*/*`

## 14. Codigo `src/lambda/api_handler.py`

Esta Lambda atiende la API REST.

Ruta:

```text
cloud-data-ia-project/src/lambda/api_handler.py
```

### 14.1 Clientes boto3

Crea clientes:

- S3
- SageMaker
- SageMaker Runtime

SageMaker Runtime es el cliente que realmente invoca el endpoint:

```text
sagemaker-runtime.invoke_endpoint
```

### 14.2 Variables de entorno

Requiere:

- `SAGEMAKER_ENDPOINT_NAME`

Opcionales:

- `ALLOWED_IMAGE_BUCKETS`
- `DEFAULT_CONFIDENCE_THRESHOLD`
- `MAX_IMAGE_BYTES`
- `CORS_ORIGIN`

Terraform las define en el modulo `ai-inference`.

### 14.3 Logging estructurado

Tiene una funcion:

```text
log(level, event, **fields)
```

que imprime JSON. Esto hace que CloudWatch Logs sea mas facil de filtrar.

Ejemplo conceptual:

```json
{
  "level": "INFO",
  "event": "api_prediction_completed",
  "source": "json-base64",
  "detections": 3
}
```

### 14.4 CORS

La funcion `response()` siempre agrega headers:

- `Access-Control-Allow-Origin`
- `Access-Control-Allow-Headers`
- `Access-Control-Allow-Methods`

Esto permite que el frontend en CloudFront llame a API Gateway desde el
navegador.

### 14.5 `/health`

Si recibe:

```text
GET /health
```

llama:

```text
sagemaker.describe_endpoint
```

y regresa:

- status ok
- nombre del endpoint
- estado del endpoint

Ejemplo:

```json
{
  "status": "ok",
  "service": "kitti-rest-api",
  "endpoint_name": "kitti-yolov8-endpoint",
  "endpoint_status": "InService"
}
```

### 14.6 `/predict`

Si recibe:

```text
POST /predict
```

puede aceptar:

1. Imagen base64 en JSON.
2. Referencia S3 con `s3_bucket` y `s3_key`.
3. Body binario si API Gateway lo manda como base64 y content type de imagen.

Despues:

1. Valida threshold de confianza.
2. Valida tamano maximo de imagen.
3. Si viene S3, valida que el bucket este permitido.
4. Invoca SageMaker Endpoint.
5. Normaliza la respuesta.
6. Filtra por confianza.
7. Construye resumen humano.
8. Devuelve JSON.

### 14.7 Resumen de detecciones

La funcion `summarize()` agrupa por clase.

Ejemplo:

```text
Detectados: 3 Car, 1 Pedestrian con confianza >0.7
```

Esto es util para la UI y para explicar el resultado sin leer todo el JSON.

### 14.8 Seguridad de la API key

La Lambda no valida manualmente la API key. Eso lo hace API Gateway porque el
metodo `POST /predict` tiene:

```text
api_key_required = true
```

Si no mandas header `x-api-key`, API Gateway bloquea antes de llegar a Lambda.

## 15. Codigo `src/lambda/prepare_yolo_handler.py`

Esta Lambda se usa dentro de Step Functions.

Su nombre en AWS:

```text
kitti-prepare-yolo-dataset
```

### 15.1 Que hace realmente

No convierte el dataset. Verifica que ya exista:

```text
s3://<curated-bucket>/yolo_dataset/kitti.yaml
```

Cuenta objetos:

- imagenes train
- imagenes val
- labels train
- labels val

Y manda metricas a CloudWatch:

Namespace:

```text
KittiMLProject/Storage
```

Metricas:

- `CuratedObjectCount`
- `YoloTrainImages`
- `YoloValImages`

### 15.2 Salida a Step Functions

Regresa:

- `mode`
- `sample_size`
- `deploy_endpoint`
- `raw_bucket`
- `curated_bucket`
- `dataset_s3_uri`
- `dataset_yaml`
- conteos de train/val

Step Functions usa esta salida para saber:

- si debe desplegar endpoint
- donde esta el dataset
- si el dataset esta completo

## 16. Codigo `src/lambda/training_results_notifier.py`

Esta Lambda procesa resultados del entrenamiento.

Nombre en AWS:

```text
kitti-training-results-notifier
```

### 16.1 Entrada

Recibe desde Step Functions:

- `training_job_name`
- `model_artifact_s3_uri`

Si no recibe URI explicita, puede llamar `describe_training_job` para encontrar
el artifact.

### 16.2 Descarga del modelo

Descarga:

```text
model.tar.gz
```

desde el bucket model artifacts.

### 16.3 Extraccion de resultados

Busca dentro del tar:

- `results.png`
- `results.csv`

Preferentemente en:

```text
evaluation/results.png
evaluation/results.csv
```

Si no estan exactamente ahi, intenta encontrarlos por nombre.

### 16.4 Re-subida a S3

Los sube a:

```text
s3://<model-artifacts-bucket>/training-results/<training-job-name>/results.png
s3://<model-artifacts-bucket>/training-results/<training-job-name>/results.csv
```

### 16.5 Links firmados

Genera presigned URLs con expiracion de:

```text
604800 segundos = 7 dias
```

Esto permite abrir resultados privados de S3 desde el correo sin hacer publico
el bucket.

### 16.6 SNS

Publica un correo con:

- training job
- URI del model artifact
- link a `results.png`
- link a `results.csv`

## 17. Archivos Lambda vacios

### 17.1 `src/lambda/handler.py`

Esta vacio.

Segun el plan, este archivo iba a ser una Lambda disparada por S3 cuando se
subiera una imagen al bucket input:

```text
S3 input image -> Lambda handler.py -> SageMaker Endpoint -> SNS
```

Pero el Terraform actual no crea esa Lambda de inferencia event-driven. La ruta
funcional actual es:

```text
Frontend/Postman -> API Gateway -> api_handler.py -> SageMaker Endpoint
```

### 17.2 `src/lambda/retraining_trigger.py`

Esta vacio.

Segun el plan, este archivo iba a contar nuevas etiquetas en raw y disparar
Step Functions cuando hubiera suficientes datos nuevos.

En el estado actual, el reentrenamiento automatico por threshold no esta
implementado en codigo, aunque el `PLAN.md` lo describe como objetivo.

Como explicarlo:

> El proyecto ya tiene la orquestacion principal con Step Functions. El
> reentrenamiento automatico por volumen de nuevos labels quedo identificado en
> el plan, pero el archivo Lambda esta como placeholder en este snapshot.

## 18. Step Functions

Archivo:

```text
cloud-data-ia-project/src/step_functions/workflow.json
```

Terraform lo carga con:

```text
templatefile(...)
```

desde el modulo:

```text
terraform/modules/orchestration/
```

### 18.1 Estados principales

El workflow empieza en:

```text
StartGlueCrawler
```

Luego sigue:

1. `StartGlueCrawler`
2. `WaitForCrawler`
3. `GetCrawlerStatus`
4. `CrawlerFinishedChoice`
5. `RunGlueJob`
6. `PrepareYOLODataset`
7. `BuildTrainingNames`
8. `StartSageMakerTraining`
9. `PublishTrainingResults`
10. `DeployEndpointChoice`
11. `CreateSageMakerModel`
12. `CreateEndpointConfig`
13. `UpdateSageMakerEndpoint`
14. `NotifySuccess`
15. `NotifyFailure`

### 18.2 Crawler

`StartGlueCrawler` llama:

```text
arn:aws:states:::aws-sdk:glue:startCrawler
```

Luego espera 30 segundos y consulta estado con:

```text
glue:getCrawler
```

Cuando el crawler esta `READY`, avanza.

### 18.3 Glue Job

`RunGlueJob` usa integracion sync:

```text
arn:aws:states:::glue:startJobRun.sync
```

Eso significa que Step Functions espera a que termine el Glue Job antes de
pasar al siguiente estado.

### 18.4 PrepareYOLODataset

Invoca:

```text
kitti-prepare-yolo-dataset
```

Esta Lambda valida que el dataset YOLO exista.

### 18.5 BuildTrainingNames

Crea nombres dinamicos con UUID para:

- training job
- model
- endpoint config

Esto evita choques de nombre en ejecuciones repetidas.

Ejemplo conceptual:

```text
kitti-yolov8-training-full-<uuid>
kitti-yolov8-model-full-<uuid>
kitti-y8-epc-full-<uuid>
```

### 18.6 StartSageMakerTraining

Usa integracion sync:

```text
arn:aws:states:::sagemaker:createTrainingJob.sync
```

Esto crea un training job y Step Functions espera a que termine.

Le pasa:

- imagen Docker de entrenamiento
- role de SageMaker
- S3 dataset
- output S3
- instancia
- hyperparameters

### 18.7 PublishTrainingResults

Invoca:

```text
kitti-training-results-notifier
```

Esta Lambda extrae resultados del `model.tar.gz`, los sube a S3 y manda links
por SNS.

### 18.8 DeployEndpointChoice

Si:

```text
deploy_endpoint = true
```

continua con despliegue.

Si es false, salta a `NotifySuccess`.

Esto ayuda a ahorrar costo cuando solo quieres entrenar pero no dejar endpoint
prendido.

### 18.9 CreateModel, CreateEndpointConfig, UpdateEndpoint

Estos estados hacen el despliegue:

```text
model.tar.gz -> SageMaker Model -> Endpoint Config -> Update Endpoint
```

El endpoint ya existe o se espera que exista. `UpdateEndpoint` cambia la config
del endpoint para apuntar al modelo nuevo.

### 18.10 Catch y errores

Los estados criticos tienen:

```json
"Catch": [
  {
    "ErrorEquals": ["States.ALL"],
    "ResultPath": "$.error",
    "Next": "NotifyFailure"
  }
]
```

Si algo falla, Step Functions manda a `NotifyFailure`, que publica un correo en
SNS con el error.

## 19. Modulo `orchestration`

Ruta:

```text
terraform/modules/orchestration/
```

Este modulo crea:

- SNS topic `kitti-detections`
- suscripcion email
- Lambda `kitti-prepare-yolo-dataset`
- Lambda `kitti-training-results-notifier`
- log group de Step Functions
- IAM role de Step Functions
- state machine `kitti-ml-pipeline`

### 19.1 SNS topic

Aunque se llama `kitti-detections`, en la practica se usa tambien para:

- notificaciones de pipeline
- training results
- alarmas de observability

### 19.2 IAM de Step Functions

`KittiStepFunctionsRole` puede:

- iniciar y consultar Glue Crawler
- iniciar y consultar Glue Job
- invocar Lambdas del pipeline
- crear training jobs, modelos y endpoint configs
- actualizar endpoint
- publicar SNS
- hacer `iam:PassRole` solo hacia `KittiSageMakerRole`
- crear logs necesarios para Step Functions

El permiso `iam:PassRole` es fundamental porque Step Functions crea training
jobs, pero SageMaker necesita recibir su propio role de ejecucion.

## 20. Modulo `frontend`

Ruta:

```text
terraform/modules/frontend/
```

Este modulo publica el frontend estatico.

### 20.1 Bucket frontend

Crea:

```text
kitti-ml-project-frontend-<account_id>
```

con:

- versioning
- SSE-S3
- public access block
- website configuration

Aunque tiene website configuration, el acceso principal y seguro es CloudFront.

### 20.2 Assets subidos

Sube:

- `index.html`
- `app.js`
- `styles.css`

con content type correcto y cache control.

### 20.3 CloudFront Origin Access Control

Crea OAC:

```text
aws_cloudfront_origin_access_control.frontend
```

CloudFront firma requests hacia S3. El bucket no queda publico.

### 20.4 Cache policies

Hay dos politicas:

- `static_assets`: TTL 300 segundos para HTML/JS/CSS.
- `runtime_config`: TTL 0 para `config.js`.

`config.js` no se debe cachear fuerte porque contiene URL actual de API Gateway
y datos de runtime.

### 20.5 Security headers

CloudFront agrega:

- content type options
- frame options DENY
- referrer policy
- HSTS
- XSS protection

### 20.6 Bucket policy

Permite `s3:GetObject` solamente al servicio CloudFront, condicionado al ARN de
la distribucion.

### 20.7 `config.js` generado en raiz

En `terraform/main.tf` se crea:

```text
aws_s3_object.frontend_runtime_config
```

Contenido:

```javascript
window.KITTI_CONFIG = {
  apiBaseUrl: "...",
  environment: "...",
  sagemakerEndpointName: "...",
  cloudfrontDistribution: "..."
};
```

Este archivo conecta el frontend con la API real.

## 21. Frontend

Ruta:

```text
cloud-data-ia-project/frontend/
```

### 21.1 `index.html`

Define la UI:

- campo API URL
- campo API key
- slider de confianza
- boton Camara
- boton Health
- boton Predict
- video de camara
- canvas overlay para bounding boxes
- panel de resultados
- JSON raw de respuesta

Carga:

```html
<script src="./config.js"></script>
<script src="./app.js"></script>
```

`config.js` lo genera Terraform, no esta en el repo.

### 21.2 `app.js`

Es la logica del navegador.

Funciones principales:

- Lee `window.KITTI_CONFIG`.
- Guarda API URL en `localStorage`.
- Abre la camara con `navigator.mediaDevices.getUserMedia`.
- Captura un frame del video en canvas.
- Convierte la imagen a JPEG base64.
- Llama `GET /health`.
- Llama `POST /predict` con `x-api-key`.
- Dibuja bounding boxes sobre el video.
- Renderiza detecciones y respuesta raw.

Flujo del boton Predict:

```text
video frame
  -> canvas
  -> JPEG blob
  -> base64
  -> POST /predict
  -> API Gateway
  -> Lambda api_handler.py
  -> SageMaker Endpoint
  -> detections JSON
  -> drawDetections()
```

### 21.3 `styles.css`

Define un layout tipo herramienta:

- topbar
- control strip
- workspace con camara y panel
- responsive para pantallas pequenas
- colores y estados

No afecta AWS, pero ayuda a que la demo sea visual.

### 21.4 Frontend local

El README del frontend dice:

```bash
python3 -m http.server 5173 --directory frontend
```

Luego:

```text
http://localhost:5173
```

En localhost el navegador permite camara. En AWS se usa CloudFront.

## 22. Modulo `observability`

Ruta:

```text
terraform/modules/observability/
```

Este modulo crea logs, alarmas y dashboard.

### 22.1 Log groups

Crea log groups para:

- `kitti-inference-handler`
- `kitti-prepare-yolo-dataset`
- `kitti-training-results-notifier`

Retencion:

```text
7 dias
```

Nota:

`kitti-inference-handler` corresponde a la Lambda de inferencia event-driven
planeada, pero el Terraform actual no crea esa Lambda. El log group puede
existir aunque la funcion no exista.

### 22.2 Alarma SageMaker 5XX

Recurso:

```text
aws_cloudwatch_metric_alarm.sagemaker_5xx
```

Metrica:

```text
AWS/SageMaker Invocation5XXErrors
```

Dimensiones:

- endpoint name
- variant `AllTraffic`

Threshold:

```text
>= 1 error en 5 minutos
```

El nombre del alarm dice "rate high", pero la implementacion actual dispara si
hay al menos un 5XX en la ventana.

### 22.3 Dashboard

Dashboard:

```text
kitti-ml-dashboard
```

Widgets:

- Glue Job Duration.
- YOLO Dataset Objects.
- SageMaker Endpoint metrics.
- API Gateway metrics.
- Lambda REST API metrics.
- Lambda Prepare YOLO metrics.
- Glue Custom Metrics.
- Lambda Training Results metrics.

En AWS Console:

```text
CloudWatch -> Dashboards -> kitti-ml-dashboard
```

## 23. Scripts auxiliares

### 23.1 `scripts/tf-plan.sh`

Hace:

1. Define `ROOT_DIR`.
2. Usa `AWS_PROFILE`, default `kitti-ml`.
3. Ejecuta `terraform init`.
4. Ejecuta `terraform validate`.
5. Borra plan viejo.
6. Ejecuta `terraform plan -out=tfplan`.

Uso:

```bash
bash scripts/tf-plan.sh
```

### 23.2 `scripts/tf-apply.sh`

Aplica el plan previamente generado:

```bash
bash scripts/tf-apply.sh
```

Si no existe `terraform/tfplan`, se detiene.

Esto es una buena practica porque separa:

```text
plan -> revisar -> apply
```

### 23.3 `scripts/verify-stack.sh`

Verifica:

- URL del frontend.
- headers HTTP del frontend.
- contenido de `config.js`.
- respuesta de `/health`.
- estado del training job en SageMaker.

Usa outputs de Terraform:

```text
frontend_url
api_base_url
```

y AWS CLI para:

```text
aws sagemaker describe-training-job
```

### 23.4 `scripts/package_sagemaker_source.sh`

Copia:

- `src/sagemaker/train.py`
- `src/sagemaker/inference.py`
- `src/sagemaker/requirements.txt`

a:

```text
build/sagemaker_source/
```

y crea:

```text
build/sourcedir.tar.gz
```

Actualmente Terraform tambien hace empaquetado con `archive_file`, asi que este
script es util para empaquetado manual o diagnostico.

### 23.5 `scripts/setup_localstack.sh` y `scripts/deploy.sh`

Ambos estan vacios en el repo actual.

Si preguntan:

> Estaban contemplados en la planeacion para una experiencia local con
> LocalStack y despliegue automatico, pero en este snapshot la ruta usada es
> Terraform directo con `tf-plan.sh` y `tf-apply.sh`.

## 24. Flujo completo de datos

### 24.1 Dataset crudo

KITTI trae:

```text
image_2/*.png
label_2/*.txt
```

El script de subida transforma esa estructura a:

```text
s3://raw/images/*.png
s3://raw/labels/*.txt
```

### 24.2 Data engineering

Glue Crawler revisa:

```text
s3://raw/labels/
```

Glue Job ejecuta:

```text
clean_data.py
```

Produce:

```text
s3://curated/labels_parquet/
```

Este Parquet ya tiene columnas limpias y calculos de bounding boxes.

### 24.3 Conversion YOLO

`prepare_yolo_dataset.py` lee:

```text
s3://curated/labels_parquet/
s3://raw/images/
```

Produce:

```text
s3://curated/yolo_dataset/
```

### 24.4 Entrenamiento

SageMaker lee:

```text
s3://curated/yolo_dataset/
```

Lo monta como:

```text
/opt/ml/input/data/dataset/
```

Ejecuta:

```text
train.py
```

Produce:

```text
s3://model-artifacts/training-output/<job>/output/model.tar.gz
```

### 24.5 Despliegue

SageMaker Model lee:

```text
model.tar.gz
```

Endpoint sirve:

```text
kitti-yolov8-endpoint
```

### 24.6 Inferencia HTTP

Usuario:

```text
Frontend o Postman
```

manda:

```text
POST /predict
```

a:

```text
API Gateway
```

API Gateway llama:

```text
Lambda api_handler.py
```

Lambda llama:

```text
SageMaker Runtime InvokeEndpoint
```

Endpoint responde detecciones. Lambda las normaliza y API Gateway las regresa al
cliente.

## 25. Como verlo en AWS Console

### 25.1 S3

Ir a:

```text
AWS Console -> S3
```

Buscar buckets:

- `kitti-ml-project-raw-<account_id>`
- `kitti-ml-project-curated-<account_id>`
- `kitti-ml-project-input-<account_id>`
- `kitti-ml-project-model-artifacts-<account_id>`
- `kitti-ml-project-frontend-<account_id>`

Que mostrar:

- En raw: `images/` y `labels/`.
- En curated: `labels_parquet/` y `yolo_dataset/`.
- En model artifacts: `sagemaker/source/`, `training-output/`,
  `training-results/`.
- En frontend: `index.html`, `app.js`, `styles.css`, `config.js`.

### 25.2 Glue

Ir a:

```text
AWS Console -> AWS Glue
```

Revisar:

- Database `kitti_catalog`.
- Crawler `kitti-labels-crawler`.
- Job `kitti-clean-labels-job`.

Que explicar:

> El crawler cataloga datos crudos. El job ejecuta PySpark para limpiar labels y
> escribir Parquet.

### 25.3 SageMaker

Ir a:

```text
AWS Console -> Amazon SageMaker AI
```

Revisar:

- Training jobs.
- Models.
- Endpoint configurations.
- Endpoints.

Que mostrar:

- Training job status `Completed`.
- Logs de entrenamiento.
- Model artifact S3 URI.
- Endpoint status `InService`.

### 25.4 Lambda

Ir a:

```text
AWS Console -> Lambda
```

Funciones importantes:

- `kitti-rest-api-handler`
- `kitti-prepare-yolo-dataset`
- `kitti-training-results-notifier`

Que explicar:

- REST API handler llama SageMaker.
- Prepare YOLO valida dataset.
- Training notifier procesa resultados.

### 25.5 API Gateway

Ir a:

```text
AWS Console -> API Gateway
```

API:

```text
kitti-ml-rest-api
```

Recursos:

- `/health`
- `/predict`

Stage:

```text
dev
```

API key:

```text
kitti-ml-rest-api-key
```

### 25.6 CloudFront

Ir a:

```text
AWS Console -> CloudFront
```

Buscar distribucion del frontend. Explicar:

> CloudFront sirve el frontend por HTTPS y lee el bucket privado usando Origin
> Access Control.

### 25.7 Step Functions

Ir a:

```text
AWS Console -> Step Functions
```

State machine:

```text
kitti-ml-pipeline
```

Que mostrar:

- Diagrama visual de estados.
- Ejecucion exitosa o fallida.
- Estado donde fallo si hay error.

### 25.8 CloudWatch

Ir a:

```text
AWS Console -> CloudWatch
```

Revisar:

- Logs de Lambda.
- Logs de SageMaker training.
- Logs de Step Functions.
- Metrics custom.
- Dashboard `kitti-ml-dashboard`.
- Alarm `kitti-sagemaker-5xx-rate-high`.

### 25.9 SNS

Ir a:

```text
AWS Console -> SNS
```

Topic:

```text
kitti-detections
```

Confirmar que el correo esta suscrito. Si no se confirma la suscripcion, SNS no
manda emails.

## 26. Orden recomendado de ejecucion desde cero

### 26.1 Preparar credenciales

Configurar perfil AWS:

```bash
aws configure --profile kitti-ml
```

Region:

```text
us-east-1
```

### 26.2 Crear bucket de state

Terraform usa backend S3. Ese bucket debe existir antes de `terraform init`.

Bucket actual configurado:

```text
kitti-terraform-state-840584084071
```

Si se usa otra cuenta, hay que cambiarlo en `terraform/main.tf`.

### 26.3 Planear infraestructura

Desde `cloud-data-ia-project/`:

```bash
bash scripts/tf-plan.sh
```

### 26.4 Aplicar infraestructura

```bash
bash scripts/tf-apply.sh
```

O manual:

```bash
terraform -chdir=terraform init
terraform -chdir=terraform plan
terraform -chdir=terraform apply
```

### 26.5 Subir KITTI sample

```bash
python scripts/upload_kitti.py \
  --dataset-root data/raw/kitti/training \
  --raw-bucket kitti-ml-project-raw-840584084071 \
  --sample \
  --sample-size 100 \
  --profile kitti-ml \
  --region us-east-1
```

### 26.6 Ejecutar Glue

Opciones:

- Desde AWS Console: correr crawler y job.
- Desde Step Functions: iniciar pipeline.
- Desde AWS CLI.

### 26.7 Preparar dataset YOLO

```bash
python src/sagemaker/prepare_yolo_dataset.py \
  --raw-bucket kitti-ml-project-raw-840584084071 \
  --curated-bucket kitti-ml-project-curated-840584084071 \
  --sample-size 100 \
  --profile kitti-ml \
  --region us-east-1
```

### 26.8 Entrenar

El training job puede crearse por Terraform o por Step Functions, segun la ruta
de demo.

Si Terraform ya lo crea, revisar en SageMaker Training Jobs.

### 26.9 Probar API

Obtener URL:

```bash
terraform -chdir=terraform output -raw api_base_url
```

Health:

```bash
curl "$(terraform -chdir=terraform output -raw api_base_url)/health"
```

API key id:

```bash
terraform -chdir=terraform output -raw api_key_id
```

Valor real de API key:

```bash
aws apigateway get-api-key \
  --api-key <api_key_id> \
  --include-value \
  --query value \
  --output text \
  --profile kitti-ml \
  --region us-east-1
```

### 26.10 Abrir frontend

```bash
terraform -chdir=terraform output -raw frontend_url
```

Pegar API key en el frontend, abrir camara y probar Predict.

## 27. Costos y riesgos

### 27.1 Riesgo principal

El mayor costo es SageMaker Endpoint prendido.

Un endpoint real-time cobra aunque no reciba trafico. Si se deja prendido varios
dias, puede consumir presupuesto rapidamente.

### 27.2 Training

El training job cobra mientras corre. Cuando termina, deja de cobrar por compute.

Pero deja artefactos en S3.

### 27.3 S3

S3 es barato para decenas de GB, pero no gratis. Raw KITTI puede ocupar varios
GB. El lifecycle a Glacier ayuda a bajar costo despues de 90 dias.

### 27.4 CloudWatch

Logs y metricas custom cuestan poco a escala de demo, pero se controla con
retencion de 7 o 14 dias.

### 27.5 API Gateway y Lambda

Para demo tienen costo muy bajo. El problema no es API Gateway, sino que cada
request a `/predict` puede invocar SageMaker.

### 27.6 Como ahorrar

- Usar `mode = "sample"` para pruebas.
- Usar `yolov8n.pt` y menos epocas para demo barata.
- Poner `deploy_sagemaker_endpoint = false` si solo se quiere entrenar.
- Destruir endpoint cuando termine la demo.
- No correr Glue full muchas veces.
- Revisar CloudWatch y Billing.

## 28. Preguntas probables del profesor y respuestas

### 28.1 Por que Terraform?

Porque permite reproducir la infraestructura como codigo. En vez de crear
recursos manualmente en consola, el proyecto define buckets, roles, Glue,
SageMaker, API Gateway, CloudFront, Step Functions y CloudWatch en archivos
versionables.

### 28.2 Por que separar buckets raw, curated y model artifacts?

Porque cada bucket tiene un rol distinto:

- Raw conserva datos originales.
- Curated guarda datos procesados.
- Model artifacts guarda modelos, scripts y resultados.
- Input guarda imagenes de inferencia.
- Frontend guarda archivos web.

Esta separacion ayuda a permisos, costos, orden y trazabilidad.

### 28.3 Por que Glue si se podria hacer con Python local?

Porque Glue representa una practica de data engineering serverless. Permite
procesar datos en Spark sin administrar cluster y escribir salidas optimizadas
como Parquet.

### 28.4 Por que Parquet?

Parquet es columnar, eficiente y comun en data lakes. Es mejor que dejar todo en
txt para analisis, catalogo y procesamiento posterior.

### 28.5 Por que se necesita convertir KITTI a YOLO?

Porque YOLOv8 no entrena con labels KITTI directamente. YOLO espera un archivo
por imagen con:

```text
class_id center_x center_y width height
```

normalizado entre 0 y 1.

### 28.6 Por que se leen dimensiones reales de la imagen?

Porque para normalizar bounding boxes hay que dividir entre ancho y alto reales.
Asumir una resolucion fija puede generar labels incorrectos.

### 28.7 Por que SageMaker Script Mode?

Porque permite usar contenedores administrados por AWS y traer solo nuestros
scripts. No tenemos que crear una imagen Docker propia desde cero.

### 28.8 Por que API Gateway + Lambda y no exponer SageMaker?

SageMaker Endpoint no es una API publica para navegadores. API Gateway + Lambda
da una capa HTTP controlada, con CORS, API key, validacion y transformacion de
payloads.

### 28.9 Que hace CloudFront?

Sirve el frontend por HTTPS y mantiene el bucket S3 privado. CloudFront usa OAC
para leer S3 de forma segura.

### 28.10 Que hace Step Functions?

Orquesta el pipeline completo y lo vuelve visible. En consola se puede ver cada
paso, cuanto tardo y donde fallo.

### 28.11 Que pasa si falla Glue o SageMaker?

Step Functions usa `Catch` para mandar la ejecucion a `NotifyFailure`, que
publica un mensaje en SNS. Ademas, los logs quedan en CloudWatch.

### 28.12 Como se monitorea el proyecto?

Con CloudWatch:

- logs de servicios
- metricas custom
- dashboard
- alarma 5XX de SageMaker

### 28.13 Que parte esta incompleta?

En el snapshot actual:

- `handler.py` esta vacio.
- `retraining_trigger.py` esta vacio.
- `setup_localstack.sh` esta vacio.
- `deploy.sh` esta vacio.
- `README.md` principal esta vacio.

Pero la ruta principal de demo con API REST, SageMaker, frontend, Glue,
Step Functions y CloudWatch esta representada en Terraform y codigo.

## 29. Narrativa sugerida para la exposicion

Puedes explicarlo en este orden:

### 29.1 Problema

> Queremos detectar objetos en imagenes de conduccion autonoma usando KITTI y
> YOLOv8, pero no solo entrenar un modelo local. Queremos un pipeline MLOps con
> infraestructura reproducible, procesamiento de datos, entrenamiento, despliegue,
> API, frontend y monitoreo.

### 29.2 Dataset

> KITTI trae imagenes y labels de bounding boxes. Los labels no estan en formato
> YOLO, asi que primero los subimos crudos a S3 y luego los transformamos.

### 29.3 Data lake

> S3 se divide por capas: raw para datos originales, curated para datos limpios
> y YOLO dataset, model-artifacts para modelos y scripts.

### 29.4 ETL

> Glue lee labels KITTI, los parsea con PySpark, filtra clases relevantes,
> calcula bounding boxes y escribe Parquet. Tambien manda metricas a CloudWatch.

### 29.5 Dataset YOLO

> El script de preparacion lee Parquet y las imagenes reales, normaliza cajas y
> crea la estructura que YOLOv8 necesita.

### 29.6 Entrenamiento

> SageMaker recibe el dataset como canal S3, monta los datos en el contenedor y
> ejecuta `train.py`. El script entrena YOLOv8, guarda `best.pt` y empaqueta
> resultados.

### 29.7 Despliegue

> SageMaker crea un modelo desde `model.tar.gz`, lo asocia a una endpoint
> configuration y publica un endpoint real-time.

### 29.8 API

> API Gateway expone `/health` y `/predict`. Lambda recibe la imagen, valida el
> request, llama al endpoint y regresa detecciones en JSON.

### 29.9 Frontend

> El frontend usa la camara, manda frames a `/predict` y dibuja bounding boxes.
> Esta publicado con S3 privado y CloudFront.

### 29.10 Orquestacion y observabilidad

> Step Functions conecta el pipeline. CloudWatch muestra logs, metricas y
> dashboard. SNS manda notificaciones.

## 30. Puntos tecnicos finos para lucirte

### 30.1 `input_file_name()` en Glue

Se usa para recuperar el nombre del archivo fuente y crear `image_id`. Sin eso,
al leer muchos `.txt` juntos se perderia de que imagen viene cada label.

### 30.2 Separar calculo pixel vs normalizacion YOLO

Glue calcula bounding boxes en pixeles porque solo lee labels. La normalizacion
se hace despues porque necesita abrir la imagen real para saber ancho y alto.

### 30.3 SageMaker channels

SageMaker no lee carpetas locales tuyas. Lee S3 y monta cada canal dentro del
contenedor. Por eso el canal `dataset` aparece como:

```text
/opt/ml/input/data/dataset/
```

### 30.4 `/opt/ml/model`

En SageMaker, todo lo que el script deje en `/opt/ml/model` se empaqueta
automaticamente como `model.tar.gz`.

### 30.5 `archive_file`

Terraform empaqueta el codigo de SageMaker y Lambda. Eso evita subir zips o tars
manualmente.

### 30.6 `iam:PassRole`

Step Functions necesita `iam:PassRole` para entregarle `KittiSageMakerRole` a
SageMaker cuando crea un training job.

### 30.7 CORS dividido en dos lugares

CORS aparece en:

- API Gateway `OPTIONS /predict`.
- Respuestas de Lambda.

Esto evita errores del navegador al llamar la API desde CloudFront.

### 30.8 `config.js`

El frontend no hardcodea la API URL en `app.js`. Terraform genera `config.js`
con la URL real de API Gateway y lo sube al bucket frontend.

### 30.9 Presigned URLs

SNS no adjunta archivos. Por eso `training_results_notifier.py` genera links
firmados a S3 para `results.png` y `results.csv`.

### 30.10 Dashboard como evidencia

El dashboard junta metricas de Glue, YOLO dataset, SageMaker, API Gateway y
Lambda. Es una evidencia visual fuerte para la entrega.

## 31. Diagnostico rapido de fallas

### 31.1 El frontend no carga

Revisar:

- CloudFront distribution deployed.
- Bucket policy permite CloudFront OAC.
- Objetos `index.html`, `app.js`, `styles.css`, `config.js` existen.
- Output `frontend_url`.

### 31.2 La camara no abre

Revisar:

- Usar HTTPS o localhost.
- Permisos del navegador.
- No abrir desde un file local sin servidor.

### 31.3 `/health` falla

Revisar:

- API Gateway stage `dev`.
- Lambda `kitti-rest-api-handler`.
- Variable `SAGEMAKER_ENDPOINT_NAME`.
- Endpoint existe e idealmente esta `InService`.
- Role `KittiApiLambdaRole` permite `sagemaker:DescribeEndpoint`.

### 31.4 `/predict` devuelve 403

Probablemente falta header:

```text
x-api-key
```

O la API key no esta asociada al usage plan.

### 31.5 `/predict` devuelve 500

Revisar:

- CloudWatch Logs de `kitti-rest-api-handler`.
- SageMaker endpoint `InService`.
- `MAX_IMAGE_BYTES`.
- Content type correcto.
- Logs del endpoint.

### 31.6 Glue falla

Revisar:

- Raw bucket tiene `labels/`.
- `KittiGlueRole` tiene permisos S3.
- Script `clean_data.py` existe en model artifacts.
- CloudWatch logs de Glue.

### 31.7 Training job falla

Revisar:

- Existe `s3://curated/yolo_dataset/kitti.yaml`.
- Existen imagenes y labels train/val.
- `KittiSageMakerRole` puede leer curated.
- El contenedor puede instalar requirements.
- Instancia tiene capacidad suficiente.

### 31.8 Step Functions falla en PrepareYOLODataset

Probablemente falta:

```text
yolo_dataset/kitti.yaml
```

o no hay imagenes train/val.

### 31.9 No llega correo SNS

Revisar:

- Suscripcion email confirmada.
- Topic `kitti-detections`.
- Spam/correo no deseado.

## 32. Archivos fuente vs archivos generados

Fuente principal:

```text
terraform/**/*.tf
src/**/*.py
src/step_functions/workflow.json
frontend/index.html
frontend/app.js
frontend/styles.css
scripts/*.py
scripts/*.sh
```

Generado o auxiliar:

```text
terraform/tfplan
terraform/.terraform/
build/
terraform/resultados_kitti/
```

No conviene explicar `tfplan` como codigo fuente. Es un plan binario generado
por Terraform.

## 33. Que decir si te preguntan por LocalStack

`PLAN.md` menciona LocalStack. En el repo actual:

- `setup_localstack.sh` esta vacio.
- `deploy.sh` esta vacio.

Respuesta honesta:

> LocalStack estaba contemplado para validar partes locales de la
> infraestructura, especialmente S3, Lambda, SNS/SQS y Step Functions. En este
> snapshot el despliegue real se maneja con Terraform directo contra AWS. Glue y
> SageMaker, aunque tienen soporte parcial o mock en herramientas locales, se
> validan mejor en AWS real para una demo final.

## 34. Checklist final antes de exponer

1. Confirmar `terraform output frontend_url`.
2. Abrir frontend CloudFront.
3. Confirmar que `config.js` carga.
4. Obtener API key real.
5. Probar `/health`.
6. Ver endpoint `InService`.
7. Probar `/predict` con una imagen pequena.
8. Mostrar S3 raw, curated y model artifacts.
9. Mostrar Glue job y CloudWatch metrics.
10. Mostrar SageMaker training job.
11. Mostrar Step Functions graph.
12. Mostrar CloudWatch dashboard.
13. Mostrar SNS topic.
14. Tener lista la explicacion de placeholders vacios.
15. Apagar/destruir endpoint si ya no se usara.

## 35. Version corta para memorizar

> El proyecto empieza con KITTI en S3 raw. Glue limpia labels y escribe Parquet
> en curated. Un script convierte ese Parquet mas las imagenes a formato YOLO.
> SageMaker entrena YOLOv8 con ese dataset y guarda `model.tar.gz`. SageMaker
> Endpoint sirve el modelo. API Gateway y Lambda exponen `/predict`. El frontend
> toma la camara y dibuja detecciones. Step Functions orquesta el pipeline, y
> CloudWatch/SNS monitorean y notifican. Todo se define con Terraform.


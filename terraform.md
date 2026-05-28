# Terraform - Guia de estudio para la exposicion

Este documento resume la infraestructura del proyecto `cloud-data-ia-project`
desde el punto de vista de Terraform. La idea es que puedas estudiar el tema,
explicarlo de forma ordenada y responder preguntas sobre por que se uso cada
servicio de AWS.

## 1. Idea principal para decir en la exposicion

La infraestructura de la practica esta automatizada con Terraform. En lugar de
crear manualmente buckets, roles, jobs, Lambdas, endpoints y dashboards desde
la consola de AWS, el proyecto declara todo como codigo en archivos `.tf`.
Terraform lee esa declaracion, calcula que recursos faltan o cambiaron y luego
los crea en AWS de forma reproducible.

Frase corta:

> Terraform se encarga de construir toda la arquitectura MLOps: S3 como data
> lake, Glue para transformar datos, SageMaker para entrenar y servir YOLOv8,
> API Gateway y Lambda para exponer inferencia, CloudFront para el frontend,
> Step Functions para orquestar el pipeline y CloudWatch/SNS para monitoreo y
> notificaciones.

## 2. Que es Terraform en esta practica

Terraform es una herramienta de infraestructura como codigo, tambien conocida
como IaC. Su trabajo es describir el estado deseado de la infraestructura.

Conceptos clave:

- `provider`: plugin que permite hablar con una nube o servicio. Aqui se usa
  `hashicorp/aws` para AWS y `hashicorp/archive` para empaquetar codigo.
- `resource`: recurso real que se crea en AWS, por ejemplo un bucket S3, una
  Lambda, un rol IAM o un endpoint de SageMaker.
- `module`: carpeta reutilizable que agrupa recursos relacionados. El proyecto
  separa la infraestructura por responsabilidad.
- `variable`: valor configurable, por ejemplo region, ambiente, epochs o tipo
  de instancia.
- `output`: valor que Terraform muestra al final, por ejemplo la URL del
  frontend o la URL base de la API.
- `state`: archivo donde Terraform guarda que recursos administra y con que
  identificadores reales en AWS.
- `backend`: lugar donde se guarda el estado. En este proyecto el estado se
  guarda en S3, cifrado.

Comandos basicos:

```bash
terraform init
terraform validate
terraform plan
terraform apply
terraform output
```

En el proyecto ya existen scripts que los envuelven:

```bash
cd cloud-data-ia-project
bash scripts/tf-plan.sh
bash scripts/tf-apply.sh
bash scripts/verify-stack.sh
```

## 3. Estructura de archivos de infraestructura

La infraestructura vive en:

```text
cloud-data-ia-project/terraform/
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
```

Que hace cada archivo principal:

- `main.tf`: conecta todos los modulos y define el proveedor AWS.
- `variables.tf`: define las variables globales del proyecto.
- `outputs.tf`: expone URLs, ARNs y nombres utiles despues del despliegue.
- `terraform.tfvars`: contiene valores concretos para esta practica, como
  `mode`, `epochs`, `yolo_model` y tipos de instancia.
- `modules/*`: cada modulo crea una parte de la arquitectura.

## 4. Configuracion raiz de Terraform

En `cloud-data-ia-project/terraform/main.tf` se declara:

```hcl
terraform {
  required_version = ">= 1.8"

  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }

    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.42.0, < 7.0.0"
    }
  }

  backend "s3" {
    bucket  = "kitti-terraform-state-840584084071"
    key     = "cloud-data-ia-project/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}
```

Como explicarlo:

- `required_version` evita ejecutar el proyecto con una version vieja de
  Terraform.
- `required_providers` indica que se necesita AWS y Archive.
- `backend "s3"` guarda el estado remoto en un bucket S3 cifrado. Esto es
  importante porque el state es la memoria de Terraform.
- El provider AWS usa `var.aws_region`, que por defecto es `us-east-1`.
- `default_tags` agrega etiquetas comunes a los recursos: proyecto, ambiente y
  que fueron administrados por Terraform.

## 5. Variables importantes

Variables globales relevantes:

```text
aws_region                 = us-east-1
project_name               = kitti-ml-project
environment                = dev
notification_email         = correo que recibe SNS
sagemaker_endpoint_name    = kitti-yolov8-endpoint
mode                       = sample o full
epochs                     = numero de epocas de entrenamiento
training_image_size        = tamano de imagen para YOLO
training_batch_size        = batch size
yolo_model                 = modelo base, por ejemplo yolov8m.pt
training_instance_type     = instancia para entrenar
endpoint_instance_type     = instancia para inferencia
deploy_sagemaker_endpoint  = true o false
api_stage_name             = dev
api_cors_origin            = origen permitido para CORS
```

Valores configurados en esta practica:

```text
mode = full
epochs = 100
yolo_model = yolov8m.pt
training_instance_type = ml.g4dn.xlarge
endpoint_instance_type = ml.g4dn.xlarge
deploy_sagemaker_endpoint = true
```

Importante: el `notification_email` se usa para crear una suscripcion SNS por
correo. No hace falta decir el correo exacto durante la exposicion.

## 6. Nombres dinamicos con locals

En `variables.tf` se obtiene el ID de la cuenta AWS:

```hcl
data "aws_caller_identity" "current" {}
```

Despues se construyen nombres de buckets con ese ID:

```hcl
locals {
  account_id             = data.aws_caller_identity.current.account_id
  raw_bucket_name        = "kitti-ml-project-raw-${local.account_id}"
  curated_bucket_name    = "kitti-ml-project-curated-${local.account_id}"
  input_bucket_name      = "kitti-ml-project-input-${local.account_id}"
  model_artifacts_bucket = "kitti-ml-project-model-artifacts-${local.account_id}"
  frontend_bucket_name   = "kitti-ml-project-frontend-${local.account_id}"
}
```

Como explicarlo:

S3 exige nombres globalmente unicos. Al agregar el ID de la cuenta, se reduce
el riesgo de chocar con buckets de otras personas.

## 7. Arquitectura general

Diagrama de la infraestructura:

```text
Dataset KITTI local
   |
   | upload_kitti.py
   v
S3 raw bucket
   |
   | Glue Crawler + Glue Job
   v
S3 curated bucket
   |
   | YOLO dataset
   v
SageMaker Training Job
   |
   v
S3 model-artifacts bucket
   |
   v
SageMaker Model + Endpoint
   ^
   |
Lambda REST API handler
   ^
   |
API Gateway REST API
   ^
   |
Frontend estatico en S3 privado + CloudFront HTTPS
```

Orquestacion:

```text
Step Functions
  -> StartGlueCrawler
  -> RunGlueJob
  -> PrepareYOLODataset Lambda
  -> SageMaker Training
  -> Training Results Lambda
  -> Optional endpoint update
  -> SNS success/failure notification
```

Observabilidad:

```text
CloudWatch Logs
CloudWatch Metrics
CloudWatch Dashboard
CloudWatch Alarm
SNS Email
```

## 8. Orden de modulos

En `main.tf`, Terraform llama los modulos en este orden logico:

```text
storage
  -> data-eng
  -> frontend
  -> ai-inference
  -> orchestration
  -> observability
```

Dependencias importantes:

- `data-eng` depende de `storage`, porque Glue necesita buckets ya creados.
- `ai-inference` depende de `storage` y `frontend`, porque necesita buckets y
  el origen CORS de CloudFront.
- `orchestration` depende de `data-eng` y `ai-inference`, porque Step
  Functions usa el Glue Job, el rol de SageMaker y Lambdas.
- `observability` depende de `orchestration` y `ai-inference`, porque necesita
  nombres de Lambdas, API, endpoint y SNS.

Terraform puede crear recursos en paralelo cuando no dependen entre si, pero
`depends_on` fuerza el orden cuando es necesario.

## 9. Modulo storage

Ruta:

```text
cloud-data-ia-project/terraform/modules/storage/
```

Este modulo crea los buckets base:

```text
raw                 datos originales KITTI
curated             datos procesados y dataset YOLO
input               imagenes de entrada para inferencia
model-artifacts     codigo, scripts, modelos y resultados
```

Recursos principales:

- `aws_s3_bucket.raw`
- `aws_s3_bucket.curated`
- `aws_s3_bucket.input`
- `aws_s3_bucket.model_artifacts`
- `aws_s3_bucket_versioning`
- `aws_s3_bucket_server_side_encryption_configuration`
- `aws_s3_bucket_public_access_block`
- `aws_s3_bucket_lifecycle_configuration.raw`

Decisiones importantes:

- `force_destroy = true`: permite borrar buckets aunque tengan objetos. Esto
  es util en desarrollo, pero en produccion se trataria con mas cuidado.
- Versionado habilitado: ayuda a conservar versiones de archivos.
- Cifrado SSE-S3 AES256: S3 cifra objetos por defecto.
- Bloqueo de acceso publico: los buckets de datos quedan privados.
- Ciclo de vida en raw: despues de 90 dias los objetos pasan a GLACIER.
- Uploads incompletos multipart se abortan despues de 7 dias.

Como explicarlo:

> Storage es la base del proyecto. Todo lo demas se apoya en S3: datos crudos,
> datos limpios, entradas de inferencia, codigo de entrenamiento y artefactos
> del modelo. El modulo tambien aplica seguridad basica: versionado, cifrado y
> bloqueo de acceso publico.

## 10. Modulo data-eng

Ruta:

```text
cloud-data-ia-project/terraform/modules/data-eng/
```

Este modulo crea la parte de ingenieria de datos con AWS Glue.

Recursos principales:

- `aws_glue_catalog_database.kitti_catalog`
- `aws_iam_role.glue_role`
- `aws_iam_role_policy.glue_policy`
- `aws_iam_role_policy_attachment.glue_service`
- `aws_s3_object.clean_data_script`
- `aws_glue_crawler.kitti_labels_crawler`
- `aws_glue_job.clean_kitti_labels`

Que hace:

1. Crea un Glue Catalog Database llamado `kitti_catalog`.
2. Crea un rol IAM para que Glue pueda leer S3, escribir resultados y mandar
   logs/metricas.
3. Sube `src/glue/clean_data.py` al bucket de `model-artifacts`.
4. Crea un Glue Crawler sobre `s3://raw/labels/`.
5. Crea un Glue Job con Spark para limpiar etiquetas KITTI.

Flujo de datos:

```text
raw bucket / labels/*.txt
  -> Glue Crawler
  -> Glue Catalog
  -> Glue Job clean_data.py
  -> curated bucket / labels_parquet/
```

Que hace `clean_data.py`:

- Lee archivos `.txt` de etiquetas KITTI.
- Extrae `image_id` desde el nombre del archivo.
- Parsea columnas como clase, bbox, dimensiones y rotacion.
- Filtra clases validas: `Car`, `Pedestrian`, `Cyclist`, `Van`, `Truck`.
- Calcula ancho, alto, area y centro de bounding boxes.
- Escribe salida en formato Parquet.
- Publica metricas custom en CloudWatch.

Como explicarlo:

> Data engineering convierte datos crudos en datos curados. Glue cataloga y
> procesa las etiquetas KITTI para que el pipeline tenga datos limpios y
> observables antes del entrenamiento.

## 11. Modulo frontend

Ruta:

```text
cloud-data-ia-project/terraform/modules/frontend/
```

Este modulo publica el frontend web.

Recursos principales:

- `aws_s3_bucket.frontend`
- `aws_s3_object.frontend_assets`
- `aws_cloudfront_origin_access_control.frontend`
- `aws_cloudfront_distribution.frontend`
- `aws_cloudfront_cache_policy.static_assets`
- `aws_cloudfront_cache_policy.runtime_config`
- `aws_cloudfront_response_headers_policy.security_headers`
- `aws_s3_bucket_policy.frontend`

Que hace:

1. Crea un bucket S3 para `index.html`, `app.js` y `styles.css`.
2. Mantiene el bucket privado.
3. Crea una distribucion CloudFront.
4. Usa Origin Access Control para que CloudFront lea S3 sin hacerlo publico.
5. Fuerza HTTPS con `viewer_protocol_policy = "redirect-to-https"`.
6. Agrega headers de seguridad.
7. Configura cache corta para assets y sin cache para `config.js`.

Pieza importante en el `main.tf` raiz:

```hcl
resource "aws_s3_object" "frontend_runtime_config" {
  bucket  = module.frontend.bucket_name
  key     = "config.js"
  content = local.frontend_runtime_config
}
```

Ese `config.js` inyecta en el frontend:

```text
apiBaseUrl
environment
sagemakerEndpointName
cloudfrontDistribution
```

Como explicarlo:

> El frontend no esta hardcodeado. Terraform genera un `config.js` con la URL
> real de API Gateway y el nombre del endpoint. Asi el frontend sabe a donde
> llamar despues del despliegue.

## 12. Modulo ai-inference

Ruta:

```text
cloud-data-ia-project/terraform/modules/ai-inference/
```

Este es uno de los modulos mas importantes. Crea entrenamiento, despliegue de
modelo, Lambda y API REST.

### 12.1 Rol IAM de SageMaker

Recursos:

- `aws_iam_role.sagemaker_role`
- `aws_iam_role_policy.sagemaker_policy`

Permisos principales:

- Leer del bucket `curated`.
- Leer/escribir en `model-artifacts`.
- Crear logs y metricas en CloudWatch.
- Leer imagenes de ECR para usar contenedores PyTorch.

Explicacion:

> SageMaker necesita un rol porque el servicio ejecuta entrenamiento y
> endpoint por nosotros. Ese rol le da acceso solo a los buckets y servicios
> que necesita.

### 12.2 Empaquetado de codigo

Recursos:

- `data "archive_file" "sagemaker_code"`
- `aws_s3_object.sagemaker_source`

Terraform toma estos archivos:

```text
src/sagemaker/train.py
src/sagemaker/inference.py
src/sagemaker/requirements.txt
```

Los empaqueta como:

```text
build/sourcedir.tar.gz
```

Y los sube a:

```text
s3://model-artifacts/sagemaker/source/sourcedir.tar.gz
```

Explicacion:

> SageMaker usa Script Mode: AWS pone el contenedor de PyTorch y nosotros le
> damos el codigo de entrenamiento e inferencia empaquetado en S3.

### 12.3 SageMaker Training Job

Recurso:

- `aws_sagemaker_training_job.kitti_yolov8_training`

Nombre:

```text
kitti-yolov8-training-${mode}
```

Entrada:

```text
s3://curated/yolo_dataset/
```

Salida:

```text
s3://model-artifacts/training-output/
```

Hiperparametros:

```text
mode
epochs
imgsz
batch
model
sagemaker_program = train.py
sagemaker_submit_directory = s3://.../sourcedir.tar.gz
```

Tipo de instancia actual:

```text
ml.g4dn.xlarge
```

Detalle importante:

El modulo escoge imagen de contenedor PyTorch segun el tipo de instancia. Si
se usa `ml.g4dn.xlarge`, usa imagen GPU; si no, usa imagen CPU.

### 12.4 Espera del artefacto entrenado

Recurso:

- `terraform_data.wait_for_training_artifact`

Que hace:

1. Ejecuta `aws sagemaker wait training-job-completed-or-stopped`.
2. Verifica que el training job termine en `Completed`.
3. Busca en S3 el archivo:

```text
training-output/<job>/output/model.tar.gz
```

Esto significa que `terraform apply` puede tardar, porque no solo crea la
infraestructura: tambien espera el entrenamiento.

Como explicarlo:

> Terraform no continua al endpoint hasta que exista el modelo entrenado. Asi
> se evita crear un endpoint apuntando a un artefacto que todavia no existe.

### 12.5 Modelo, endpoint config y endpoint

Recursos:

- `aws_sagemaker_model.kitti_model`
- `aws_sagemaker_endpoint_configuration.kitti_endpoint_config`
- `aws_sagemaker_endpoint.kitti_endpoint`

Se crean solo si:

```hcl
deploy_sagemaker_endpoint = true
```

Esto se controla con:

```hcl
count = var.deploy_sagemaker_endpoint ? 1 : 0
```

Como explicarlo:

> El endpoint es opcional porque puede generar costo. Si la variable esta en
> `true`, Terraform crea el modelo, la configuracion del endpoint y el endpoint
> real-time para inferencia.

### 12.6 Lambda REST API handler

Recursos:

- `aws_lambda_function.rest_api_handler`
- `aws_iam_role.api_lambda_role`
- `aws_iam_role_policy.api_lambda_policy`
- `aws_cloudwatch_log_group.rest_api_handler`

Archivo de codigo:

```text
src/lambda/api_handler.py
```

Que hace la Lambda:

- Atiende `GET /health`.
- Atiende `POST /predict`.
- Acepta imagen como base64, binaria o referencia S3.
- Valida tamano maximo de imagen.
- Llama a `sagemaker-runtime:InvokeEndpoint`.
- Filtra detecciones por confianza.
- Devuelve JSON con resumen y detecciones.

Variables de entorno:

```text
SAGEMAKER_ENDPOINT_NAME
ALLOWED_IMAGE_BUCKETS
DEFAULT_CONFIDENCE_THRESHOLD
MAX_IMAGE_BYTES
CORS_ORIGIN
```

### 12.7 API Gateway

Recursos:

- `aws_api_gateway_rest_api.kitti_api`
- `aws_api_gateway_resource.predict`
- `aws_api_gateway_resource.health`
- `aws_api_gateway_method.predict_post`
- `aws_api_gateway_method.health_get`
- `aws_api_gateway_method.predict_options`
- `aws_api_gateway_integration.predict_lambda`
- `aws_api_gateway_integration.health_lambda`
- `aws_api_gateway_stage.dev`
- `aws_api_gateway_api_key.kitti_api_key`
- `aws_api_gateway_usage_plan.kitti_usage_plan`

Endpoints:

```text
GET  /health
POST /predict
```

Seguridad y control:

- `/health` no requiere API key.
- `/predict` si requiere API key.
- Hay CORS configurado para el frontend.
- El usage plan limita trafico:
  - `burst_limit = 5`
  - `rate_limit = 2`
  - `quota = 1000` requests por mes

Como explicarlo:

> No exponemos SageMaker directamente a internet. API Gateway publica la API,
> Lambda valida la peticion y luego llama al endpoint privado de SageMaker.

## 13. Modulo orchestration

Ruta:

```text
cloud-data-ia-project/terraform/modules/orchestration/
```

Este modulo crea la orquestacion del pipeline MLOps.

Recursos principales:

- `aws_sns_topic.detections`
- `aws_sns_topic_subscription.email`
- `aws_lambda_function.prepare_yolo_dataset`
- `aws_lambda_function.training_results_notifier`
- `aws_cloudwatch_log_group.step_functions_logs`
- `aws_iam_role.step_functions_role`
- `aws_iam_role_policy.step_functions_policy`
- `aws_sfn_state_machine.kitti_pipeline`

### 13.1 SNS

SNS crea un topic llamado:

```text
kitti-detections
```

Se usa para:

- Notificar exito del pipeline.
- Notificar fallas.
- Mandar resultados de entrenamiento.
- Recibir alarmas de CloudWatch.

Punto para explicar:

> Cuando se crea una suscripcion por email, AWS manda un correo de confirmacion.
> Si no se confirma, no llegan notificaciones.

### 13.2 Lambda prepare_yolo_dataset

Archivo:

```text
src/lambda/prepare_yolo_handler.py
```

Que hace:

- Verifica que exista `yolo_dataset/kitti.yaml`.
- Cuenta imagenes de train y validation.
- Cuenta labels de train y validation.
- Publica metricas en CloudWatch:
  - `CuratedObjectCount`
  - `YoloTrainImages`
  - `YoloValImages`
- Devuelve a Step Functions la URI del dataset y si se debe desplegar endpoint.

Importante:

Esta Lambda no entrena; valida que el dataset YOLO ya este disponible y listo
para SageMaker.

### 13.3 Lambda training_results_notifier

Archivo:

```text
src/lambda/training_results_notifier.py
```

Que hace:

- Ubica `model.tar.gz`.
- Descarga el artefacto del entrenamiento.
- Extrae `results.png` y `results.csv`.
- Los sube a:

```text
s3://model-artifacts/training-results/<training-job>/
```

- Genera URLs firmadas.
- Publica un correo por SNS con links a los resultados.

### 13.4 Step Functions

El estado se define con:

```text
src/step_functions/workflow.json
```

Terraform lo carga con:

```hcl
definition = templatefile("${path.root}/../src/step_functions/workflow.json", {...})
```

Flujo real de estados:

```text
StartGlueCrawler
  -> WaitForCrawler
  -> GetCrawlerStatus
  -> CrawlerFinishedChoice
  -> RunGlueJob
  -> PrepareYOLODataset
  -> BuildTrainingNames
  -> StartSageMakerTraining
  -> PublishTrainingResults
  -> DeployEndpointChoice
  -> CreateSageMakerModel
  -> CreateEndpointConfig
  -> UpdateSageMakerEndpoint
  -> NotifySuccess
```

Si algo falla:

```text
Catch -> NotifyFailure -> SNS
```

Como explicarlo:

> Step Functions es el director de orquesta. Une Glue, Lambda, SageMaker y SNS
> en un pipeline visible, auditable y con manejo de errores.

## 14. Modulo observability

Ruta:

```text
cloud-data-ia-project/terraform/modules/observability/
```

Este modulo crea monitoreo.

Recursos principales:

- `aws_cloudwatch_log_group.lambda_logs`
- `aws_cloudwatch_log_group.prepare_yolo_logs`
- `aws_cloudwatch_log_group.training_results_logs`
- `aws_cloudwatch_metric_alarm.sagemaker_5xx`
- `aws_cloudwatch_dashboard.kitti_dashboard`

Dashboard:

```text
kitti-ml-dashboard
```

Incluye widgets para:

- Duracion del Glue Job.
- Objetos del dataset YOLO.
- Latencia y errores 5XX de SageMaker.
- Conteo, latencia, 4XX y 5XX de API Gateway.
- Invocaciones, errores y duracion de Lambdas.
- Metricas custom de Glue:
  - `ProcessedImages`
  - `FailedImages`
  - `ProcessedAnnotations`
  - `AvgFileSize`

Alarma:

```text
kitti-sagemaker-5xx-rate-high
```

Se activa si SageMaker devuelve uno o mas errores 5XX en una ventana de 5
minutos. La alarma publica en SNS.

Como explicarlo:

> Observability permite saber si el pipeline funciona, donde falla y cuanto
> tarda cada parte. No basta con desplegar; tambien hay que poder monitorear.

## 15. Outputs importantes

Al finalizar `terraform apply`, se pueden consultar outputs:

```bash
terraform -chdir=terraform output
```

Outputs mas utiles para la exposicion:

```text
frontend_url
api_base_url
sagemaker_endpoint_name
sagemaker_endpoint_arn
step_function_arn
sns_topic_arn
cloudwatch_dashboard_name
training_mode
training_epochs
training_yolo_model
training_instance_type
endpoint_instance_type
```

Para abrir el frontend:

```bash
terraform -chdir=terraform output -raw frontend_url
```

Para ver la API:

```bash
terraform -chdir=terraform output -raw api_base_url
```

Para obtener el valor secreto de la API key:

```bash
API_KEY_ID="$(terraform -chdir=terraform output -raw api_key_id)"
aws apigateway get-api-key \
  --api-key "$API_KEY_ID" \
  --include-value \
  --query value \
  --output text
```

Importante: `api_key_id` no es la API key secreta; es solo el identificador.

## 16. Que pasa cuando ejecuto los scripts

### `bash scripts/tf-plan.sh`

Hace:

1. Entra a la raiz del proyecto.
2. Usa `AWS_PROFILE`, por defecto `kitti-ml`.
3. Ejecuta `terraform init`.
4. Ejecuta `terraform validate`.
5. Borra un plan anterior si existe.
6. Genera un nuevo plan en `terraform/tfplan`.

### `bash scripts/tf-apply.sh`

Hace:

1. Verifica que exista `terraform/tfplan`.
2. Ejecuta `terraform apply tfplan`.
3. Crea o actualiza los recursos de AWS.

### `bash scripts/verify-stack.sh`

Hace:

1. Lee `frontend_url` y `api_base_url` desde Terraform outputs.
2. Prueba el frontend con `curl`.
3. Descarga `config.js`.
4. Prueba `GET /health`.
5. Consulta el estado del training job de SageMaker.

## 17. Flujo completo explicado como historia

Puedes explicarlo asi:

1. Primero Terraform crea el almacenamiento base en S3: raw, curated, input,
   model-artifacts y frontend.
2. Luego crea Glue para catalogar y limpiar etiquetas KITTI.
3. Despues sube el codigo de SageMaker y lanza un training job de YOLOv8.
4. Cuando SageMaker termina, el modelo queda guardado en S3 como
   `model.tar.gz`.
5. Si `deploy_sagemaker_endpoint` esta en `true`, Terraform crea el modelo, el
   endpoint config y el endpoint real-time.
6. Terraform crea una Lambda que recibe solicitudes HTTP y llama al endpoint.
7. API Gateway publica `/health` y `/predict`.
8. El frontend se publica en S3 privado y CloudFront lo sirve por HTTPS.
9. Step Functions permite reejecutar el pipeline de datos y entrenamiento de
   forma orquestada.
10. CloudWatch y SNS permiten ver metricas, logs, dashboard, alarmas y correos.

## 18. Diferencia entre Terraform y Step Functions

Esta diferencia es clave.

Terraform:

- Crea infraestructura.
- Mantiene estado.
- Sabe que recursos existen.
- Se usa para provisionar o cambiar arquitectura.

Step Functions:

- Ejecuta un flujo de trabajo.
- Orquesta servicios ya creados.
- Maneja pasos, esperas, decisiones y errores.
- Se usa para correr el pipeline MLOps.

Frase util:

> Terraform construye el escenario; Step Functions ejecuta la obra.

## 19. Seguridad

Puntos de seguridad que puedes mencionar:

- Buckets privados con `aws_s3_bucket_public_access_block`.
- Cifrado S3 por defecto con AES256.
- IAM separado por servicio:
  - Glue tiene su rol.
  - SageMaker tiene su rol.
  - Lambda API tiene su rol.
  - Step Functions tiene su rol.
- API Gateway usa API key para `/predict`.
- CloudFront accede al frontend bucket con Origin Access Control.
- CORS restringe el origen permitido al dominio CloudFront.
- CloudWatch centraliza logs y alarmas.

Principio:

> Cada servicio recibe permisos segun lo que necesita hacer. Eso se conoce como
> least privilege.

## 20. Costos y cuidado

Recursos que pueden generar costo:

- SageMaker training job en `ml.g4dn.xlarge`.
- SageMaker real-time endpoint en `ml.g4dn.xlarge`.
- Glue Job.
- CloudFront.
- S3 storage.
- API Gateway y Lambda por uso.
- CloudWatch logs, metricas y dashboards.

Punto importante:

El endpoint real-time queda activo mientras exista. Si no se necesita para la
demo, se puede apagar con:

```text
deploy_sagemaker_endpoint = false
```

o destruir la infraestructura cuando ya no se use. No ejecutes `destroy` durante
la exposicion salvo que el profesor lo pida, porque borra recursos.

## 21. Preguntas probables y respuestas

### Que ventaja tiene Terraform aqui?

Permite crear la arquitectura completa de forma repetible. Si alguien quiere
replicar la practica, no tiene que entrar servicio por servicio en AWS Console;
ejecuta Terraform y obtiene la misma base.

### Por que se usa backend S3 para el state?

Porque el state no debe depender solo de una maquina local. S3 lo guarda de
forma remota y cifrada, lo que ayuda a conservar el historial de recursos que
Terraform administra.

### Por que hay modulos?

Para separar responsabilidades. Storage maneja buckets, data-eng maneja Glue,
ai-inference maneja SageMaker/API, frontend maneja CloudFront, orchestration
maneja Step Functions/SNS y observability maneja monitoreo.

### Por que se usa S3 en tantos lugares?

Porque S3 funciona como data lake y repositorio de artefactos. Glue lee de S3,
SageMaker entrena desde S3, SageMaker guarda modelos en S3, Lambda puede leer
imagenes de S3 y CloudFront sirve archivos estaticos desde S3.

### Por que no se expone SageMaker directamente?

Porque SageMaker endpoint no es una API publica pensada para navegadores. API
Gateway y Lambda dan una capa HTTP segura, validan datos, aplican CORS y usan
API key.

### Por que CloudFront si S3 puede servir sitios?

CloudFront da HTTPS, cache, headers de seguridad y permite mantener el bucket
privado con Origin Access Control.

### Que pasa si falla el entrenamiento?

En el camino de Terraform, el `terraform_data.wait_for_training_artifact` falla
si el training job no termina en `Completed` o si no aparece `model.tar.gz`.
En el camino de Step Functions, los estados tienen `Catch` y mandan la falla
por SNS.

### Por que se usa Glue?

Porque Glue permite procesar datos con Spark sin administrar servidores. Aqui
convierte etiquetas KITTI crudas en datos curados en Parquet y envia metricas a
CloudWatch.

### Que diferencia hay entre `raw`, `curated` y `model-artifacts`?

- `raw`: datos originales, sin transformar.
- `curated`: datos limpios, Parquet y dataset YOLO.
- `model-artifacts`: codigo empaquetado, salidas de entrenamiento, modelos y
  resultados.

### Que es `config.js` del frontend?

Es un archivo generado por Terraform que contiene valores de runtime: URL de
API Gateway, ambiente, endpoint SageMaker y distribucion CloudFront. Asi el
frontend no necesita tener esos valores escritos manualmente.

### Que es `count = var.deploy_sagemaker_endpoint ? 1 : 0`?

Es una forma de crear recursos condicionalmente. Si la variable esta en `true`,
Terraform crea el endpoint. Si esta en `false`, no lo crea.

### Que mostrarias en la consola de AWS?

1. Buckets S3.
2. Glue Job y Glue Crawler.
3. SageMaker Training Job y Endpoint.
4. API Gateway con `/health` y `/predict`.
5. CloudFront distribution del frontend.
6. Step Functions con el grafo del pipeline.
7. CloudWatch dashboard y alarma.
8. SNS topic y suscripcion.

## 22. Guion corto de exposicion

Puedes usar este guion de 3 a 5 minutos:

Primero:

> La infraestructura esta definida con Terraform. Esto significa que los
> recursos de AWS no se crearon manualmente, sino como codigo. El archivo
> principal es `terraform/main.tf`, que llama modulos por responsabilidad.

Despues:

> El primer modulo es `storage`. Crea los buckets S3 para datos crudos,
> procesados, entradas de inferencia, artefactos de modelo y frontend. Todos
> tienen versionado, cifrado y bloqueo de acceso publico.

Luego:

> El modulo `data-eng` crea AWS Glue: un catalog database, un crawler y un job
> Spark. Glue toma las etiquetas KITTI desde el bucket raw, las limpia, calcula
> campos de bounding boxes, filtra clases validas y escribe Parquet en curated.

Luego:

> El modulo `ai-inference` empaqueta el codigo de SageMaker, lanza un training
> job de YOLOv8 y espera a que aparezca `model.tar.gz`. Con ese artefacto crea
> el modelo, endpoint config y endpoint real-time. Tambien crea Lambda y API
> Gateway para exponer `/health` y `/predict`.

Luego:

> El modulo `frontend` publica la interfaz web en un bucket privado y la sirve
> por CloudFront con HTTPS. Terraform tambien genera `config.js` para que el
> frontend conozca la URL real de la API.

Luego:

> El modulo `orchestration` crea Step Functions. Ese pipeline inicia el crawler,
> ejecuta Glue, valida el dataset YOLO, entrena en SageMaker, extrae resultados
> y actualiza el endpoint si corresponde. Si algo falla, manda una notificacion
> por SNS.

Cierre:

> Finalmente, `observability` crea logs, dashboard y alarma en CloudWatch. Esto
> nos permite saber si el pipeline esta sano, si SageMaker falla o si la API
> esta devolviendo errores.

## 23. Checklist para antes de exponer

Antes de la exposicion:

- Confirmar que la suscripcion SNS por email este aceptada.
- Ejecutar `terraform -chdir=cloud-data-ia-project/terraform validate`.
- Revisar `terraform -chdir=cloud-data-ia-project/terraform output`.
- Tener a la mano `frontend_url`.
- Tener a la mano `api_base_url`.
- Probar `bash cloud-data-ia-project/scripts/verify-stack.sh`.
- Revisar que el endpoint de SageMaker este `InService`.
- Abrir el CloudWatch dashboard `kitti-ml-dashboard`.
- Abrir la Step Function `kitti-ml-pipeline`.

Durante la exposicion:

- Empieza por `terraform/main.tf`.
- Explica los modulos en orden.
- Muestra un recurso real por modulo en AWS Console.
- Muestra los outputs para conectar Terraform con la demo.
- Cierra con seguridad, observabilidad y automatizacion.

## 24. Resumen en una sola pagina

Terraform crea:

```text
S3:
  raw, curated, input, model-artifacts, frontend

Glue:
  catalog database, crawler, ETL job

SageMaker:
  training job, model, endpoint config, endpoint

Lambda:
  API handler, prepare YOLO validator, training results notifier

API Gateway:
  GET /health, POST /predict, API key, usage plan, CORS

CloudFront:
  HTTPS frontend over private S3 bucket

Step Functions:
  MLOps pipeline from crawler to endpoint update

CloudWatch:
  logs, metrics, dashboard, SageMaker 5XX alarm

SNS:
  email notifications for success, failure and alarms

IAM:
  roles and policies per service
```

Idea final:

> La infraestructura esta pensada como una arquitectura MLOps completa: datos,
> procesamiento, entrenamiento, inferencia, frontend, orquestacion y monitoreo,
> todo administrado con Terraform para que sea reproducible y explicable.

# PLAN.md - Arquitectura MLOps AWS con KITTI + YOLOv8

Fecha de planeacion: 2026-05-25  
Region AWS fija: `us-east-1`  
Proyecto local: `/home/andresuki/cloudC/definitive_project/cloud-data-ia-project`  
Objetivo: construir un proyecto de portafolio MLOps end-to-end con Terraform, LocalStack, S3, Glue, SageMaker, Lambda, Step Functions, CloudWatch y SNS, usando KITTI 2D Object Detection y YOLOv8n.

## 1. Decisiones Cerradas del Proyecto

1. El entrenamiento principal usa `YOLOv8n` porque es el modelo nano de Ultralytics: cabe mejor en presupuesto, entrena mas rapido y permite demo con CPU o GPU pequena.
2. El despliegue de inferencia usa un endpoint real-time de SageMaker con `ml.t2.medium` para demo barata. Si el endpoint falla por memoria o latencia, el plan de contingencia es `ml.m5.xlarge`; no se deja prendido.
3. El pipeline completo se prueba primero con `--sample 100`. El dataset completo se sube solo para la demo final.
4. Los buckets en las instrucciones usan nombres como `kitti-ml-project-raw`, pero S3 exige nombres globalmente unicos. Para que sea ejecutable sin depender de suerte, los nombres fisicos seran:
   - `kitti-ml-project-raw-${AWS_ACCOUNT_ID}`
   - `kitti-ml-project-curated-${AWS_ACCOUNT_ID}`
   - `kitti-ml-project-input-${AWS_ACCOUNT_ID}`
   - `kitti-ml-project-model-artifacts-${AWS_ACCOUNT_ID}`
   - `kitti-terraform-state-${AWS_ACCOUNT_ID}`
5. En el README y diagrama se mostraran nombres logicos sin sufijo, pero los scripts leeran los nombres reales desde variables de Terraform o `.env`.
6. LocalStack se usara para validar IaC, S3, SNS, SQS, Lambda y Step Functions. Glue y SageMaker se probaran en modo mock/local porque su emulacion completa depende de capacidades avanzadas de LocalStack y no sustituye una prueba final en AWS.
7. Step Functions orquesta el flujo end-to-end. Para el estado `PrepareYOLODataset`, la version de demo usa Lambda con muestra pequena; para dataset completo, la Lambda solo dispara/prepara el trabajo y se evita procesar 12 GB dentro de Lambda.
8. El proyecto incluye reentrenamiento automatico basado en volumen de datos: cada imagen etiquetada nueva en raw incrementa un contador en SSM Parameter Store; si llega a 500 y pasaron al menos 3 dias desde el ultimo entrenamiento, una Lambda dispara Step Functions y resetea el contador.

## 2. Fuentes Verificadas

- KITTI official object detection page: `https://www.cvlibs.net/datasets/kitti/eval_object.php?obj_benchmark=2d`
- Mirror directo usado por Torchvision/KITTI: `https://s3.eu-central-1.amazonaws.com/avg-kitti/`
- SageMaker AI pricing: `https://aws.amazon.com/sagemaker/ai/pricing/`
- SageMaker real-time endpoint docs: `https://docs.aws.amazon.com/sagemaker/latest/dg/realtime-endpoints-deploy-models.html`
- SageMaker instance list for real-time inference API: `https://docs.aws.amazon.com/sagemaker/latest/APIReference/API_RealTimeInferenceConfig.html`
- AWS Glue pricing: `https://aws.amazon.com/glue/pricing/`
- S3 pricing: `https://aws.amazon.com/s3/pricing/`
- Step Functions pricing: `https://aws.amazon.com/step-functions/pricing/`
- LocalStack Terraform docs: `https://docs.localstack.cloud/aws/connecting/infrastructure-as-code/terraform/`
- LocalStack Glue docs: `https://docs.localstack.cloud/aws/services/glue/`
- LocalStack Step Functions docs: `https://docs.localstack.cloud/aws/services/stepfunctions/`
- SSM Parameter Store console docs: `https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-create-console.html`
- S3 event notifications console docs: `https://docs.aws.amazon.com/AmazonS3/latest/userguide/enable-event-notifications.html`
- Lambda S3 trigger docs: `https://docs.aws.amazon.com/lambda/latest/dg/with-s3-example.html`
- Step Functions start execution docs: `https://docs.aws.amazon.com/step-functions/latest/dg/statemachine-starting.html`
- API Gateway REST API Lambda proxy integration docs: `https://docs.aws.amazon.com/apigateway/latest/developerguide/set-up-lambda-proxy-integrations.html`
- API Gateway Lambda integration docs: `https://docs.aws.amazon.com/apigateway/latest/developerguide/set-up-lambda-integrations.html`
- SageMaker InvokeEndpoint API docs: `https://docs.aws.amazon.com/sagemaker/latest/APIReference/API_runtime_InvokeEndpoint.html`
- API Gateway pricing: `https://aws.amazon.com/api-gateway/pricing/`

## 3. Cost Guardrails Antes de Tocar Infra

Haz esto antes de crear cualquier recurso costoso.

### 3.1 Entrar a AWS y fijar region

1. Abre `https://console.aws.amazon.com/`.
2. Inicia sesion con tu cuenta AWS Academy, Educate o cuenta personal con creditos.
3. En la esquina superior derecha, abre el selector de region.
4. Selecciona `US East (N. Virginia) us-east-1`.
5. No uses otra region para este proyecto; las imagenes de contenedor, precios y Terraform estan planeados para `us-east-1`.

### 3.2 Crear presupuesto de proteccion

1. En la barra de busqueda de AWS escribe `Billing and Cost Management`.
2. Abre `Billing and Cost Management`.
3. En el menu izquierdo entra a `Budgets`.
4. Clic en `Create budget`.
5. Selecciona `Use a template`.
6. Elige `Monthly cost budget`.
7. Budget name: `kitti-ml-project-118usd-budget`.
8. Period: `Monthly`.
9. Budgeted amount: `118`.
10. Email recipients: tu correo real.
11. Configura alertas:
    - 50% actual: `59 USD`
    - 80% actual: `94.40 USD`
    - 100% forecasted: `118 USD`
12. Clic en `Create budget`.

### 3.3 Crear alarma extra para SageMaker endpoint prendido

1. Ve a `CloudWatch`.
2. Entra a `Alarms > All alarms`.
3. Clic en `Create alarm`.
4. Clic en `Select metric`.
5. Busca `AWS/SageMaker`.
6. Elige `EndpointName, VariantName`.
7. Selecciona el endpoint cuando exista: `kitti-yolov8-endpoint`.
8. Metrica: `Invocations`.
9. Condicion: `Greater/Equal than 0` durante 6 horas continuas.
10. Accion: enviar a SNS `kitti-detections`.
11. Nombre: `kitti-sagemaker-endpoint-still-running`.

Nota: si el endpoint todavia no existe, crea esta alarma despues del primer `terraform apply`.

## 4. Setup Local de Herramientas

Ejecuta esto en WSL/Linux dentro de `/home/andresuki/cloudC/definitive_project`.

```bash
sudo apt-get update
sudo apt-get install -y unzip curl wget git python3 python3-venv python3-pip docker.io
sudo usermod -aG docker "$USER"
```

Cierra y vuelve a abrir la terminal para que el grupo `docker` aplique.

Verifica herramientas:

```bash
docker --version
terraform version
aws --version
python3 --version
```

Versiones recomendadas:

- Terraform: `>= 1.8`
- AWS CLI: ideal `v2`; si tienes `v1`, funciona para la mayoria, pero recomiendo actualizar para evitar diferencias.
- Python: `>= 3.10`
- Docker: activo con `docker ps`

Configura AWS CLI:

```bash
aws configure --profile kitti-ml
```

Valores:

- AWS Access Key ID: la key de tu cuenta.
- AWS Secret Access Key: la secret de tu cuenta.
- Default region name: `us-east-1`
- Default output format: `json`

Exporta perfil y account id:

```bash
export AWS_PROFILE=kitti-ml
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "$AWS_ACCOUNT_ID"
```

## 5. Crear Estructura Exacta del Repositorio

Desde `/home/andresuki/cloudC/definitive_project`:

```bash
mkdir -p cloud-data-ia-project/{terraform/modules/{storage,data-eng,ai-inference,orchestration,observability},src/{glue,lambda,step_functions,sagemaker},data/{raw,reference},scripts}
cd cloud-data-ia-project
touch terraform/{main.tf,variables.tf,outputs.tf}
touch terraform/modules/storage/{main.tf,variables.tf,outputs.tf}
touch terraform/modules/data-eng/{main.tf,variables.tf,outputs.tf}
touch terraform/modules/ai-inference/{main.tf,variables.tf,outputs.tf}
touch terraform/modules/orchestration/{main.tf,variables.tf,outputs.tf}
touch terraform/modules/observability/{main.tf,variables.tf,outputs.tf}
touch src/glue/clean_data.py
touch src/sagemaker/{prepare_yolo_dataset.py,train.py,inference.py,requirements.txt}
touch src/lambda/{handler.py,prepare_yolo_handler.py,retraining_trigger.py,api_handler.py}
touch src/step_functions/workflow.json
touch scripts/{setup_localstack.sh,deploy.sh,upload_kitti.py,package_sagemaker_source.sh}
touch README.md .env.example .gitignore
```

`.gitignore` debe incluir:

```gitignore
.terraform/
*.tfstate
*.tfstate.*
*.zip
*.tar.gz
data/raw/
data/kitti/
.env
__pycache__/
.venv/
```

## 6. Backend Terraform State

Terraform no puede crear su propio backend S3 en el mismo `terraform init`. Primero crea el bucket de estado.

### Opcion recomendada por CLI

```bash
export TF_STATE_BUCKET="kitti-terraform-state-${AWS_ACCOUNT_ID}"


aws s3api create-bucket \
  --bucket "$TF_STATE_BUCKET" \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket "$TF_STATE_BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$TF_STATE_BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [
      {
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        }
      }
    ]
  }'

aws s3api put-public-access-block \
  --bucket "$TF_STATE_BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

### Opcion equivalente en AWS Console

1. Entra a `S3`.
2. Clic en `Create bucket`.
3. Bucket name: `kitti-terraform-state-${AWS_ACCOUNT_ID}` reemplazando `${AWS_ACCOUNT_ID}` por el numero que te imprimio AWS CLI.
4. AWS Region: `US East (N. Virginia) us-east-1`.
5. Object Ownership: `ACLs disabled`.
6. Block Public Access: deja todas las casillas activadas.
7. Bucket Versioning: `Enable`.
8. Default encryption: `Server-side encryption with Amazon S3 managed keys (SSE-S3)`.
9. Clic en `Create bucket`.

## 7. Terraform Raiz

### 7.1 `terraform/main.tf`

Debe declarar:

- Provider `aws` region `var.aws_region`.
- Backend S3:
  - bucket: `kitti-terraform-state-${AWS_ACCOUNT_ID}`.
  - key: `cloud-data-ia-project/terraform.tfstate`.
  - region: `us-east-1`.
  - encrypt: `true`.
- Modulos:
  - `module.storage`
  - `module.data-eng`
  - `module.ai-inference`
  - `module.orchestration`
  - `module.observability`

### 7.2 Variables raiz obligatorias

Usa variables simples y calcula nombres de buckets con `data.aws_caller_identity.current.account_id`; no pongas `${account_id}` dentro de un `default`, porque Terraform no permite interpolacion en defaults de variables.

```hcl
variable "aws_region" {
  default = "us-east-1"
}

variable "project_name" {
  default = "kitti-ml-project"
}

variable "environment" {
  default = "dev"
}

variable "notification_email" {
  description = "Email real que confirmara la suscripcion SNS."
  type        = string
}

variable "sagemaker_endpoint_name" {
  default = "kitti-yolov8-endpoint"
}

variable "training_instance_type" {
  default = "ml.m5.xlarge"
}

variable "endpoint_instance_type" {
  default = "ml.t2.medium"
}

data "aws_caller_identity" "current" {}

locals {
  account_id             = data.aws_caller_identity.current.account_id
  raw_bucket_name        = "kitti-ml-project-raw-${local.account_id}"
  curated_bucket_name    = "kitti-ml-project-curated-${local.account_id}"
  input_bucket_name      = "kitti-ml-project-input-${local.account_id}"
  model_artifacts_bucket = "kitti-ml-project-model-artifacts-${local.account_id}"
}
```

Genera `terraform.tfvars` con tu correo real desde la terminal para no dejar valores falsos en el repo:

```bash
read -r -p "Email para notificaciones SNS: " NOTIFICATION_EMAIL
printf 'notification_email = "%s"\n' "$NOTIFICATION_EMAIL" > terraform/terraform.tfvars
```

### 7.3 Outputs raiz

Outputs minimos:

- `raw_bucket_uri`
- `curated_bucket_uri`
- `input_bucket_uri`
- `model_artifacts_bucket_uri`
- `sagemaker_endpoint_name`
- `sagemaker_endpoint_arn`
- `api_base_url`
- `api_key_id`
- `step_function_arn`
- `sns_topic_arn`

## 8. Fase A - Data Engineering KITTI + Glue

### A1. Descargar solo KITTI 2D Object Detection

KITTI Object Detection 2D necesita:

- Left color images: `data_object_image_2.zip`, alrededor de `12.6 GB`.
- Training labels: `data_object_label_2.zip`, alrededor de `5.6 MB`.

No descargues Velodyne, calibration, right images ni temporal frames para este proyecto.

Desde `cloud-data-ia-project`:

```bash
mkdir -p data/kitti_downloads data/raw/kitti

wget -c https://s3.eu-central-1.amazonaws.com/avg-kitti/data_object_image_2.zip \
  -O data/kitti_downloads/data_object_image_2.zip

wget -c https://s3.eu-central-1.amazonaws.com/avg-kitti/data_object_label_2.zip \
  -O data/kitti_downloads/data_object_label_2.zip

unzip -q data/kitti_downloads/data_object_image_2.zip -d data/raw/kitti
unzip -q data/kitti_downloads/data_object_label_2.zip -d data/raw/kitti
```

Estructura esperada despues de descomprimir:

```text
data/raw/kitti/training/image_2/000000.png
data/raw/kitti/training/image_2/000001.png
data/raw/kitti/training/label_2/000000.txt
data/raw/kitti/training/label_2/000001.txt
```

Verifica conteos:

```bash
find data/raw/kitti/training/image_2 -name '*.png' | wc -l
find data/raw/kitti/training/label_2 -name '*.txt' | wc -l
du -sh data/raw/kitti
```

Resultado esperado:

- Imagenes train: `7481`
- Labels train: `7481`
- Espacio local aproximado: `13 GB` descomprimido, mas `12.6 GB` del zip si no lo borras.
- Tiempo de descarga: 10 a 60 minutos segun conexion.

Para ahorrar disco despues de validar:

```bash
rm data/kitti_downloads/data_object_image_2.zip
rm data/kitti_downloads/data_object_label_2.zip
```

### A2. `scripts/upload_kitti.py`

Debe implementar:

- CLI con:
  - `--dataset-root data/raw/kitti/training`
  - `--raw-bucket kitti-ml-project-raw-${AWS_ACCOUNT_ID}`
  - `--sample`
  - `--sample-size 100`
  - `--profile kitti-ml`
  - `--region us-east-1`
- Sube imagenes a `s3://<raw-bucket>/images/`.
- Sube labels a `s3://<raw-bucket>/labels/`.
- Usa `boto3.s3.transfer.TransferConfig`.
- Multipart:
  - `multipart_threshold=8 * 1024 * 1024`
  - `multipart_chunksize=8 * 1024 * 1024`
  - `max_concurrency=8`
- Reintentos:
  - `botocore.config.Config(retries={"max_attempts": 10, "mode": "standard"})`
- Barra de progreso con `tqdm`.
- En modo `--sample`, sube los primeros 100 ids ordenados y sus labels correspondientes.
- Antes de subir, valida que cada imagen tenga label.
- Al final imprime:
  - imagenes subidas
  - labels subidos
  - total MB
  - bucket destino

Comando para prueba barata:

```bash
python3 scripts/upload_kitti.py \
  --dataset-root data/raw/kitti/training \
  --raw-bucket "kitti-ml-project-raw-${AWS_ACCOUNT_ID}" \
  --sample \
  --sample-size 100 \
  --profile kitti-ml \
  --region us-east-1
```

Comando para dataset completo:

```bash
python3 scripts/upload_kitti.py \
  --dataset-root data/raw/kitti/training \
  --raw-bucket "kitti-ml-project-raw-${AWS_ACCOUNT_ID}" \
  --profile kitti-ml \
  --region us-east-1
```

Costo S3 aproximado:

- S3 Standard en us-east-1: `0.023 USD/GB-mes` primeros 50 TB.
- 14 GB aproximados entre raw y curated: `14 * 0.023 = 0.322 USD/mes`.
- PUT/LIST/GET para 15k objetos sera centavos o menos.

### A3. Terraform `modules/storage`

Recursos:

1. `aws_s3_bucket.raw`
2. `aws_s3_bucket.curated`
3. `aws_s3_bucket.input`
4. `aws_s3_bucket.model_artifacts`
5. `aws_s3_bucket_versioning.*`
6. `aws_s3_bucket_server_side_encryption_configuration.*`
7. `aws_s3_bucket_public_access_block.*`
8. `aws_s3_bucket_lifecycle_configuration.raw`

Configuracion:

- Versioning: enabled en los 4 buckets.
- Encryption: SSE-S3.
- Public access block: todo bloqueado.
- Lifecycle raw:
  - Transicion a `GLACIER` despues de 90 dias.
  - Abort incomplete multipart upload despues de 7 dias.
- Tags en todo:
  - `Project = "kitti-ml-project"`
  - `Phase = "storage"`
  - `ManagedBy = "Terraform"`
  - `Environment = "dev"`

AWS Console para verificar:

1. Entra a `S3`.
2. Busca `kitti-ml-project-raw-${AWS_ACCOUNT_ID}`.
3. Abre el bucket.
4. En `Properties`, verifica:
   - Bucket Versioning: `Enabled`
   - Default encryption: `SSE-S3`
5. En `Management`, verifica lifecycle rule:
   - transition current versions to Glacier after 90 days.

### A4. Terraform `modules/data-eng`

Recursos:

1. `aws_glue_catalog_database.kitti_catalog`
   - name: `kitti_catalog`
2. `aws_iam_role.glue_role`
   - name: `KittiGlueRole`
3. `aws_iam_role_policy.glue_policy`
   - S3 read raw bucket.
   - S3 write curated bucket.
   - S3 read scripts/model-artifacts bucket if scripts live ahi.
   - CloudWatch Logs write.
   - CloudWatch metric data put.
4. `aws_s3_object.clean_data_script`
   - key: `glue-scripts/clean_data.py`
   - bucket: model artifacts bucket.
5. `aws_glue_crawler.kitti_labels_crawler`
   - name: `kitti-labels-crawler`
   - database: `kitti_catalog`
   - target: `s3://<raw-bucket>/labels/`
6. `aws_glue_job.clean_kitti_labels`
   - name: `kitti-clean-labels-job`
   - glue_version: `4.0` o `5.0` si tu cuenta ya lo soporta.
   - worker_type: `G.1X`
   - number_of_workers: `2`
   - command name: `glueetl`
   - script_location: `s3://<model-artifacts-bucket>/glue-scripts/clean_data.py`
   - default args:
     - `--RAW_LABELS_PATH=s3://<raw-bucket>/labels/`
     - `--CURATED_OUTPUT_PATH=s3://<curated-bucket>/labels_parquet/`
     - `--enable-metrics=true`
     - `--enable-continuous-cloudwatch-log=true`
     - `--job-language=python`

Nota importante: el crawler sobre `.txt` solo cataloga archivos; el schema real lo produce `clean_data.py` al escribir Parquet. Para Athena/portafolio, ejecuta otro crawler sobre `labels_parquet/` despues del job si quieres tabla analitica limpia.

AWS Console para crear/verificar Glue:

1. Entra a `AWS Glue`.
2. Menu izquierdo: `Data Catalog > Databases`.
3. Verifica `kitti_catalog`.
4. Menu izquierdo: `Crawlers`.
5. Abre `kitti-labels-crawler`.
6. Data source debe apuntar a `s3://kitti-ml-project-raw-${AWS_ACCOUNT_ID}/labels/`.
7. IAM role debe ser `KittiGlueRole`.
8. Menu izquierdo: `ETL jobs`.
9. Abre `kitti-clean-labels-job`.
10. En `Job details`, verifica:
    - Type: Spark
    - Glue version: 4.0/5.0
    - Worker type: G.1X
    - Number of workers: 2
11. No presiones `Run` hasta haber subido el sample.

### A5. `src/glue/clean_data.py`

Debe hacer esto:

1. Leer todos los `.txt` desde `--RAW_LABELS_PATH`.
2. Extraer `image_id` del nombre de archivo.
3. Parsear cada linea KITTI:

```text
class truncated occluded alpha x1 y1 x2 y2 height width length x y z rotation_y
```

4. Crear columnas:

```text
image_id, class_name, truncated, occluded, alpha,
x1, y1, x2, y2, height, width, length, x, y, z, rotation_y
```

5. Filtrar `DontCare` y `Misc`.
6. Mantener clases:

```text
Car, Pedestrian, Cyclist, Van, Truck
```

7. Calcular:

```text
bbox_width = x2 - x1
bbox_height = y2 - y1
bbox_area = bbox_width * bbox_height
center_x_pixels = x1 + bbox_width / 2
center_y_pixels = y1 + bbox_height / 2
```

8. Para normalizacion YOLO real se necesita ancho/alto de imagen. En Glue:
   - default KITTI image_2 suele estar alrededor de `1242x375`, pero no todas las imagenes deben asumirse iguales.
   - Solucion correcta: `prepare_yolo_dataset.py` lee imagen real y calcula normalizados definitivos.
   - `clean_data.py` puede dejar columnas `center_x_pixels`, `center_y_pixels`, `bbox_width`, `bbox_height`.
9. Escribir Parquet:

```text
s3://kitti-ml-project-curated-${AWS_ACCOUNT_ID}/labels_parquet/
```

10. Emitir CloudWatch custom metrics:

Namespace: `KittiMLProject/DataEngineering`

Metricas:

- `ProcessedImages`
- `FailedImages`
- `AvgFileSize`
- `ProcessedAnnotations`

Comando AWS para correr manualmente:

```bash
aws glue start-job-run \
  --job-name kitti-clean-labels-job \
  --profile kitti-ml \
  --region us-east-1
```

Ver logs:

1. Entra a `CloudWatch`.
2. `Logs > Log groups`.
3. Busca `/aws-glue/jobs/output`.
4. Abre el log stream mas reciente.

## 9. Fase B - YOLOv8 + SageMaker

### B1. Convertir KITTI a formato YOLOv8

Ultralytics espera:

```text
dataset/
  images/train/*.png
  images/val/*.png
  labels/train/*.txt
  labels/val/*.txt
  kitti.yaml
```

Cada archivo YOLO label contiene lineas:

```text
class_id center_x center_y width height
```

Todos los valores de caja van normalizados a `[0, 1]`.

Mapa de clases elegido:

```python
CLASS_MAP = {
    "Car": 0,
    "Pedestrian": 1,
    "Cyclist": 2,
    "Van": 3,
    "Truck": 4,
}
```

`src/sagemaker/prepare_yolo_dataset.py` debe:

1. Leer Parquet desde `s3://<curated-bucket>/labels_parquet/`.
2. Leer imagenes desde `s3://<raw-bucket>/images/`.
3. Para cada imagen:
   - descargar o leer metadata de tamano real con PIL.
   - convertir cajas KITTI pixel a YOLO normalizado.
   - escribir label YOLO local temporal.
4. Dividir ids `80/20` train/val con seed fijo `42`.
5. Copiar imagenes:
   - train a `s3://<curated-bucket>/yolo_dataset/images/train/`
   - val a `s3://<curated-bucket>/yolo_dataset/images/val/`
6. Subir labels:
   - train a `s3://<curated-bucket>/yolo_dataset/labels/train/`
   - val a `s3://<curated-bucket>/yolo_dataset/labels/val/`
7. Crear `kitti.yaml`:

```yaml
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

8. Subirlo a:

```text
s3://kitti-ml-project-curated-${AWS_ACCOUNT_ID}/yolo_dataset/kitti.yaml
```

Comando local para sample:

```bash
python3 src/sagemaker/prepare_yolo_dataset.py \
  --raw-bucket "kitti-ml-project-raw-${AWS_ACCOUNT_ID}" \
  --curated-bucket "kitti-ml-project-curated-${AWS_ACCOUNT_ID}" \
  --parquet-prefix labels_parquet/ \
  --output-prefix yolo_dataset/ \
  --sample-size 100 \
  --profile kitti-ml \
  --region us-east-1
```

Comando local para full:

```bash
python3 src/sagemaker/prepare_yolo_dataset.py \
  --raw-bucket "kitti-ml-project-raw-${AWS_ACCOUNT_ID}" \
  --curated-bucket "kitti-ml-project-curated-${AWS_ACCOUNT_ID}" \
  --parquet-prefix labels_parquet/ \
  --output-prefix yolo_dataset/ \
  --profile kitti-ml \
  --region us-east-1
```

### B2. Como SageMaker ve los datos

SageMaker monta canales S3 dentro del contenedor:

```text
/opt/ml/input/data/<channel_name>/
```

Para YOLOv8 la forma menos confusa es un solo canal llamado `dataset`:

```hcl
input_data_config {
  channel_name = "dataset"
  data_source {
    s3_data_source {
      s3_data_type = "S3Prefix"
      s3_uri       = "s3://kitti-ml-project-curated-${AWS_ACCOUNT_ID}/yolo_dataset/"
      s3_data_distribution_type = "FullyReplicated"
    }
  }
}
```

Entonces `train.py` usa:

```text
/opt/ml/input/data/dataset/kitti.yaml
```

Si usas SageMaker SDK en notebook, equivalente:

```python
estimator.fit({
    "dataset": "s3://kitti-ml-project-curated-${AWS_ACCOUNT_ID}/yolo_dataset/"
})
```

Si tu profesor pide explicitamente `train` y `val`, puedes agregar dos canales, pero `train.py` tendria que generar un `kitti.yaml` dinamico con rutas:

```python
estimator.fit({
    "train": "s3://kitti-ml-project-curated-${AWS_ACCOUNT_ID}/yolo_dataset/images/train/",
    "val": "s3://kitti-ml-project-curated-${AWS_ACCOUNT_ID}/yolo_dataset/images/val/"
})
```

Para este proyecto recomiendo `dataset` porque reduce errores con Ultralytics.

### B3. `src/sagemaker/train.py`

Debe ser compatible con SageMaker Script Mode:

1. `argparse`:
   - `--epochs`, default `5` sample, `20` full si hay presupuesto.
   - `--imgsz`, default `640`.
   - `--batch`, default `8`.
   - `--model`, default `yolov8n.pt`.
2. Instalar/usar `ultralytics` via `requirements.txt`.
3. Leer dataset:

```python
dataset_yaml = "/opt/ml/input/data/dataset/kitti.yaml"
```

4. Entrenar:

```python
model = YOLO("yolov8n.pt")
model.train(data=dataset_yaml, epochs=args.epochs, imgsz=args.imgsz, batch=args.batch, project="/opt/ml/output", name="train")
```

5. Guardar modelo:

```text
/opt/ml/model/best.pt
/opt/ml/model/code/inference.py
/opt/ml/model/code/requirements.txt
```

6. Imprimir metricas parseables para CloudWatch/SageMaker:

```text
mAP50=<value>
precision=<value>
recall=<value>
```

`src/sagemaker/requirements.txt`:

```text
ultralytics==8.3.0
opencv-python-headless
pillow
boto3
numpy
```

### B4. Contenedores SageMaker recomendados

CPU training barato:

```text
763104351884.dkr.ecr.us-east-1.amazonaws.com/pytorch-training:2.6.0-cpu-py312-ubuntu22.04-sagemaker
```

GPU training recomendado para demo si tienes margen:

```text
763104351884.dkr.ecr.us-east-1.amazonaws.com/pytorch-training:2.6.0-gpu-py312-cu126-ubuntu22.04-sagemaker
```

Inference CPU:

```text
763104351884.dkr.ecr.us-east-1.amazonaws.com/pytorch-inference:2.6.0-cpu-py312-ubuntu22.04-sagemaker
```

Si el tag de inference 2.6 no existe en tu cuenta/region, usa el helper de SageMaker SDK para resolverlo:

```bash
python3 - <<'PY'
from sagemaker.image_uris import retrieve
print(retrieve(framework="pytorch", region="us-east-1", version="2.6.0", py_version="py312", instance_type="ml.m5.xlarge", image_scope="inference"))
PY
```

### B5. Costos SageMaker que importan

Precios us-east-1 verificados via AWS Price List:

- `ml.m5.xlarge` training: aprox `0.23 USD/h`.
- `ml.g4dn.xlarge` training: aprox `0.736 USD/h`.
- `ml.t2.medium` real-time endpoint: aprox `0.056 USD/h`.
- `ml.m5.xlarge` real-time endpoint: aprox `0.23 USD/h`.

Regla de oro:

- Training cobra mientras el job corre.
- Endpoint cobra mientras existe y esta `InService`, aunque nadie lo invoque.
- Modelo, endpoint config y artefactos S3 casi no cuestan; el endpoint vivo si.

Comando para destruir solo el endpoint caro:

```bash
cd terraform
terraform destroy -target=module.ai-inference.aws_sagemaker_endpoint.kitti_endpoint
```

Despues tambien puedes destruir config/model si no los necesitas:

```bash
terraform destroy \
  -target=module.ai-inference.aws_sagemaker_endpoint.kitti_endpoint \
  -target=module.ai-inference.aws_sagemaker_endpoint_configuration.kitti_endpoint_config \
  -target=module.ai-inference.aws_sagemaker_model.kitti_model
```

### B6. Terraform `modules/ai-inference` - SageMaker

Recursos SageMaker:

1. `aws_iam_role.sagemaker_role`
   - name: `KittiSageMakerRole`
2. `aws_iam_role_policy.sagemaker_policy`
   - S3 read curated dataset.
   - S3 read/write model artifacts.
   - CloudWatch logs.
   - ECR pull for DLC images.
3. `aws_s3_object.sagemaker_source`
   - key: `sagemaker/source/sourcedir.tar.gz`
   - contiene `train.py`, `inference.py`, `requirements.txt`.
4. `aws_sagemaker_training_job.kitti_yolov8_training`
   - name prefix: `kitti-yolov8-training`
   - input channel: `dataset`
   - output path: `s3://<model-artifacts-bucket>/training-output/`
   - resource config:
     - instance type: `var.training_instance_type`
     - instance count: `1`
     - volume size: `50`
   - stopping condition:
     - max runtime: `7200` seconds para sample/demo.
   - hyperparameters:
     - `sagemaker_program = "train.py"`
     - `sagemaker_submit_directory = "s3://<model-artifacts-bucket>/sagemaker/source/sourcedir.tar.gz"`
     - `epochs = "5"`
     - `imgsz = "640"`
     - `batch = "8"`
5. `aws_sagemaker_model.kitti_model`
   - name: `kitti-yolov8-model`
   - image: PyTorch inference image.
   - model_data_url: output `model.tar.gz` del training job.
6. `aws_sagemaker_endpoint_configuration.kitti_endpoint_config`
   - instance_type: `ml.t2.medium`
   - initial_instance_count: `1`
   - variant_name: `AllTraffic`
7. `aws_sagemaker_endpoint.kitti_endpoint`
   - name: `kitti-yolov8-endpoint`

### B7. Empaquetar codigo SageMaker

`scripts/package_sagemaker_source.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

mkdir -p build/sagemaker_source
cp src/sagemaker/train.py build/sagemaker_source/train.py
cp src/sagemaker/inference.py build/sagemaker_source/inference.py
cp src/sagemaker/requirements.txt build/sagemaker_source/requirements.txt

tar -czf build/sourcedir.tar.gz -C build/sagemaker_source .
echo "Created build/sourcedir.tar.gz"
```

Antes de `terraform apply` real:

```bash
bash scripts/package_sagemaker_source.sh
```

### B8. AWS Console - SageMaker paso a paso

SageMaker aparece en la consola nueva como `Amazon SageMaker AI`.

#### Ver training job

1. Entra a `https://console.aws.amazon.com/sagemaker/`.
2. Verifica region `N. Virginia`.
3. Menu izquierdo: `Training`.
4. Clic en `Training jobs`.
5. Busca `kitti-yolov8-training`.
6. Abre el job.
7. Revisa:
   - Status: `InProgress`, `Completed` o `Failed`.
   - Instance type: `ml.m5.xlarge` o `ml.g4dn.xlarge`.
   - Input data configuration: canal `dataset`.
   - Output path: `s3://kitti-ml-project-model-artifacts-${AWS_ACCOUNT_ID}/training-output/`.
8. En la misma pantalla busca `Monitor` o `View logs`.
9. Abre CloudWatch logs.
10. Confirma que aparezcan lineas de Ultralytics y que `kitti.yaml` se encontro.

#### Ver artefacto del modelo

1. Entra a `S3`.
2. Abre `kitti-ml-project-model-artifacts-${AWS_ACCOUNT_ID}`.
3. Entra a `training-output/`.
4. Busca carpeta del training job.
5. Debe existir `output/model.tar.gz`.

#### Ver endpoint

1. Entra a `SageMaker AI`.
2. Menu izquierdo: `Inference`.
3. Clic en `Endpoints`.
4. Busca `kitti-yolov8-endpoint`.
5. Status esperado: `Creating` y luego `InService`.
6. Si queda en `Failed`, abre `Failure reason`.
7. Causas comunes:
   - `requirements.txt` no instalo `ultralytics`.
   - `inference.py` no esta en `model.tar.gz/code/`.
   - `ml.t2.medium` sin memoria suficiente; cambiar temporalmente a `ml.m5.xlarge`.

CLI equivalente para verificar:

```bash
aws sagemaker describe-training-job \
  --training-job-name kitti-yolov8-training \
  --profile kitti-ml \
  --region us-east-1

aws sagemaker describe-endpoint \
  --endpoint-name kitti-yolov8-endpoint \
  --profile kitti-ml \
  --region us-east-1
```

### B9. Lambda `src/lambda/handler.py`

Funcion de inferencia:

1. Recibe evento S3 de `kitti-ml-project-input-${AWS_ACCOUNT_ID}`.
2. Extrae bucket y key.
3. Descarga imagen a `/tmp/input.png`.
4. Lee bytes de imagen.
5. Invoca SageMaker:

```python
sagemaker_runtime.invoke_endpoint(
    EndpointName=os.environ["SAGEMAKER_ENDPOINT_NAME"],
    ContentType="image/png",
    Body=image_bytes,
)
```

6. Espera JSON con detecciones:

```json
[
  {"class_name": "Car", "confidence": 0.91, "bbox": [x1, y1, x2, y2]}
]
```

7. Filtra `confidence >= 0.7`.
8. Construye mensaje:

```text
Detectados: 3 Cars, 1 Pedestrian con confianza >0.7
```

9. Publica en SNS topic `kitti-detections`.
10. Logs estructurados:

```python
print(json.dumps({
    "level": "INFO",
    "event": "inference_completed",
    "bucket": bucket,
    "key": key,
    "detections": summary,
}))
```

11. En exception:
    - log `ERROR`
    - envia payload a SQS `kitti-lambda-dlq`
    - relanza exception para que Lambda marque error.

### B10. Terraform `modules/ai-inference` - Lambda/SNS/SQS

Recursos:

1. `aws_sqs_queue.lambda_dlq`
   - name: `kitti-lambda-dlq`
   - message retention: `1209600` segundos.
2. `aws_sns_topic.detections`
   - name: `kitti-detections`
3. `aws_sns_topic_subscription.email`
   - protocol: `email`
   - endpoint: `var.notification_email`
4. `aws_iam_role.lambda_role`
   - name: `KittiLambdaRole`
5. `aws_iam_role_policy.lambda_policy`
   - S3 GetObject en input bucket.
   - SageMaker `InvokeEndpoint` solo sobre `kitti-yolov8-endpoint`.
   - SNS Publish al topic.
   - SQS SendMessage a DLQ.
   - CloudWatch Logs write.
6. `aws_lambda_function.kitti_inference`
   - name: `kitti-inference-handler`
   - runtime: `python3.11`
   - timeout: `60`
   - memory: `512`
   - env:
     - `SAGEMAKER_ENDPOINT_NAME=kitti-yolov8-endpoint`
     - `SNS_TOPIC_ARN=<topic arn>`
     - `DLQ_URL=<queue url>`
7. `aws_lambda_permission.allow_s3`
8. `aws_s3_bucket_notification.input_notification`
   - event: `s3:ObjectCreated:*`
   - prefix: `incoming/`

Despues del primer apply, confirma el email de SNS:

1. Abre tu correo.
2. Busca mensaje de AWS Notifications.
3. Clic en `Confirm subscription`.

Subir imagen de prueba:

```bash
aws s3 cp data/raw/kitti/training/image_2/000000.png \
  "s3://kitti-ml-project-input-${AWS_ACCOUNT_ID}/incoming/000000.png" \
  --profile kitti-ml \
  --region us-east-1
```

## 10. Fase B.5 - Consumo del Modelo con API REST

Esta fase expone el modelo como una API REST para consumo externo. La arquitectura correcta para este proyecto es:

```text
Cliente / Postman / curl / frontend
        |
        v
Amazon API Gateway REST API
        |
        v
Lambda kitti-rest-api-handler
        |
        v
SageMaker Runtime InvokeEndpoint
        |
        v
SageMaker Endpoint kitti-yolov8-endpoint
```

No se expone SageMaker Endpoint directamente a internet. SageMaker Endpoint es el servicio de inferencia administrada; API Gateway + Lambda es la capa publica HTTP que valida la peticion, controla CORS/API key, transforma payloads y devuelve JSON limpio.

### API1. Contrato de la API

Base URL despues de Terraform:

```text
https://<api-id>.execute-api.us-east-1.amazonaws.com/dev
```

Endpoints:

```text
GET  /health
POST /predict
```

`GET /health` responde si la API esta viva y, opcionalmente, el status del endpoint:

```json
{
  "status": "ok",
  "service": "kitti-rest-api",
  "endpoint_name": "kitti-yolov8-endpoint",
  "endpoint_status": "InService"
}
```

`POST /predict` acepta tres formatos:

1. JSON con imagen base64:

```json
{
  "image_base64": "iVBORw0KGgoAAA...",
  "content_type": "image/png",
  "confidence_threshold": 0.7
}
```

2. JSON con referencia S3:

```json
{
  "s3_bucket": "kitti-ml-project-input-${AWS_ACCOUNT_ID}",
  "s3_key": "incoming/000000.png",
  "content_type": "image/png",
  "confidence_threshold": 0.7
}
```

3. Imagen binaria directa con header:

```text
Content-Type: image/png
x-api-key: <api-key>
```

Respuesta esperada:

```json
{
  "summary": "Detectados: 3 Cars, 1 Pedestrian con confianza >0.7",
  "count": 4,
  "detections": [
    {"class_name": "Car", "confidence": 0.91, "bbox": [10, 20, 120, 160]}
  ],
  "endpoint_name": "kitti-yolov8-endpoint"
}
```

Limites practicos:

- API Gateway REST API soporta payloads pequenos para imagenes de prueba. Para imagenes grandes, usa el modo JSON con `s3_bucket` y `s3_key`.
- Para mantener el presupuesto, el endpoint de SageMaker debe estar `InService` solo durante pruebas/demo.
- `POST /predict` requiere API key. `GET /health` no requiere API key.

### API2. Archivo local en VS Code

En VS Code:

1. Abre `src/lambda/api_handler.py`.
2. Pega el codigo completo de abajo.
3. Guarda con `Ctrl+S`.
4. Verifica en terminal:

```bash
python3 -m py_compile src/lambda/api_handler.py
```

### API3. `src/lambda/api_handler.py`

```python
import base64
import json
import os
from collections import Counter

import boto3


s3 = boto3.client("s3")
sagemaker = boto3.client("sagemaker")
sagemaker_runtime = boto3.client("sagemaker-runtime")


ENDPOINT_NAME = os.environ["SAGEMAKER_ENDPOINT_NAME"]
ALLOWED_BUCKETS = {
    bucket.strip()
    for bucket in os.environ.get("ALLOWED_IMAGE_BUCKETS", "").split(",")
    if bucket.strip()
}
DEFAULT_CONFIDENCE = float(os.environ.get("DEFAULT_CONFIDENCE_THRESHOLD", "0.7"))
MAX_IMAGE_BYTES = int(os.environ.get("MAX_IMAGE_BYTES", "6000000"))
CORS_ORIGIN = os.environ.get("CORS_ORIGIN", "*")


def log(level, event, **fields):
    print(json.dumps({"level": level, "event": event, **fields}, default=str))


def response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": CORS_ORIGIN,
            "Access-Control-Allow-Headers": "Content-Type,x-api-key",
            "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
        },
        "body": json.dumps(body, default=str),
    }


def get_header(event, name, default=None):
    headers = event.get("headers") or {}
    lower = {str(k).lower(): v for k, v in headers.items()}
    return lower.get(name.lower(), default)


def load_image_from_s3(bucket, key):
    if ALLOWED_BUCKETS and bucket not in ALLOWED_BUCKETS:
        raise ValueError(f"Bucket not allowed: {bucket}")
    obj = s3.get_object(Bucket=bucket, Key=key)
    image_bytes = obj["Body"].read()
    content_type = obj.get("ContentType") or "image/png"
    return image_bytes, content_type


def load_image_from_event(event):
    content_type = get_header(event, "content-type", "application/json")
    body = event.get("body") or ""

    if event.get("isBase64Encoded") and content_type.startswith("image/"):
        return base64.b64decode(body), content_type, DEFAULT_CONFIDENCE, "binary-body"

    try:
        payload = json.loads(body) if isinstance(body, str) else body
    except json.JSONDecodeError as exc:
        raise ValueError("Body must be JSON or binary image data") from exc

    confidence = float(payload.get("confidence_threshold", DEFAULT_CONFIDENCE))

    if "s3_bucket" in payload and "s3_key" in payload:
        image_bytes, s3_content_type = load_image_from_s3(payload["s3_bucket"], payload["s3_key"])
        return image_bytes, payload.get("content_type", s3_content_type), confidence, "s3-reference"

    if "image_base64" in payload:
        return (
            base64.b64decode(payload["image_base64"]),
            payload.get("content_type", "image/png"),
            confidence,
            "json-base64",
        )

    raise ValueError("Request must include image_base64 or s3_bucket+s3_key")


def invoke_model(image_bytes, content_type):
    if len(image_bytes) > MAX_IMAGE_BYTES:
        raise ValueError(f"Image is too large: {len(image_bytes)} bytes. Max is {MAX_IMAGE_BYTES} bytes.")

    result = sagemaker_runtime.invoke_endpoint(
        EndpointName=ENDPOINT_NAME,
        ContentType=content_type,
        Accept="application/json",
        Body=image_bytes,
    )
    raw_body = result["Body"].read().decode("utf-8")
    return json.loads(raw_body)


def normalize_detections(model_response):
    if isinstance(model_response, list):
        return model_response
    if isinstance(model_response, dict):
        if "detections" in model_response:
            return model_response["detections"]
        if "predictions" in model_response:
            return model_response["predictions"]
    return []


def summarize(detections, threshold):
    filtered = [
        det for det in detections
        if float(det.get("confidence", det.get("score", 0.0))) >= threshold
    ]
    counts = Counter(det.get("class_name", str(det.get("class", "Unknown"))) for det in filtered)

    if not counts:
        return "Detectados: 0 objetos con confianza >{:.1f}".format(threshold), filtered

    parts = [f"{count} {name}" for name, count in sorted(counts.items())]
    return "Detectados: {} con confianza >{:.1f}".format(", ".join(parts), threshold), filtered


def health():
    endpoint_status = "Unknown"
    try:
        endpoint_status = sagemaker.describe_endpoint(EndpointName=ENDPOINT_NAME)["EndpointStatus"]
    except Exception as exc:
        log("WARN", "endpoint_health_check_failed", error=str(exc), endpoint_name=ENDPOINT_NAME)

    return response(200, {
        "status": "ok",
        "service": "kitti-rest-api",
        "endpoint_name": ENDPOINT_NAME,
        "endpoint_status": endpoint_status,
    })


def lambda_handler(event, context):
    method = event.get("httpMethod", "")
    path = event.get("path", "")

    if method == "OPTIONS":
        return response(200, {"ok": True})

    if method == "GET" and path.endswith("/health"):
        return health()

    if method != "POST" or not path.endswith("/predict"):
        return response(404, {"error": "Not found"})

    try:
        image_bytes, content_type, confidence, source = load_image_from_event(event)
        model_response = invoke_model(image_bytes, content_type)
        detections = normalize_detections(model_response)
        summary, filtered = summarize(detections, confidence)

        log(
            "INFO",
            "api_prediction_completed",
            source=source,
            content_type=content_type,
            image_bytes=len(image_bytes),
            detections=len(filtered),
            endpoint_name=ENDPOINT_NAME,
        )

        return response(200, {
            "summary": summary,
            "count": len(filtered),
            "detections": filtered,
            "endpoint_name": ENDPOINT_NAME,
        })
    except ValueError as exc:
        log("WARN", "bad_request", error=str(exc))
        return response(400, {"error": str(exc)})
    except Exception as exc:
        log("ERROR", "api_prediction_failed", error=str(exc), endpoint_name=ENDPOINT_NAME)
        return response(500, {"error": "Prediction failed", "detail": str(exc)})
```

### API4. Terraform `modules/ai-inference` - API REST

Se agrega en el modulo `ai-inference`, porque la API consume el endpoint y comparte variables de inferencia.

Variables necesarias:

```hcl
variable "aws_region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "raw_bucket_name" {
  type = string
}

variable "raw_bucket_arn" {
  type = string
}

variable "input_bucket_name" {
  type = string
}

variable "input_bucket_arn" {
  type = string
}

variable "sagemaker_endpoint_name" {
  type = string
}

variable "api_stage_name" {
  type    = string
  default = "dev"
}

variable "api_cors_origin" {
  type    = string
  default = "*"
}
```

Recursos:

```hcl
data "archive_file" "api_handler_zip" {
  type        = "zip"
  source_file = "${path.module}/../../../src/lambda/api_handler.py"
  output_path = "${path.module}/api_handler.zip"
}

resource "aws_iam_role" "api_lambda_role" {
  name = "KittiApiLambdaRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Project   = "kitti-ml-project"
    Phase     = "api"
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_role_policy" "api_lambda_policy" {
  name = "KittiApiLambdaPolicy"
  role = aws_iam_role.api_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = [
          "${var.input_bucket_arn}/incoming/*",
          "${var.raw_bucket_arn}/images/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sagemaker:InvokeEndpoint",
          "sagemaker:DescribeEndpoint"
        ]
        Resource = "arn:aws:sagemaker:${var.aws_region}:${var.account_id}:endpoint/${var.sagemaker_endpoint_name}"
      }
    ]
  })
}

resource "aws_lambda_function" "rest_api_handler" {
  function_name    = "kitti-rest-api-handler"
  role             = aws_iam_role.api_lambda_role.arn
  runtime          = "python3.11"
  handler          = "api_handler.lambda_handler"
  filename         = data.archive_file.api_handler_zip.output_path
  source_code_hash = data.archive_file.api_handler_zip.output_base64sha256
  timeout          = 60
  memory_size      = 512

  environment {
    variables = {
      SAGEMAKER_ENDPOINT_NAME      = var.sagemaker_endpoint_name
      ALLOWED_IMAGE_BUCKETS        = "${var.input_bucket_name},${var.raw_bucket_name}"
      DEFAULT_CONFIDENCE_THRESHOLD = "0.7"
      MAX_IMAGE_BYTES              = "6000000"
      CORS_ORIGIN                  = var.api_cors_origin
    }
  }

  tags = {
    Project   = "kitti-ml-project"
    Phase     = "api"
    ManagedBy = "Terraform"
  }
}

resource "aws_api_gateway_rest_api" "kitti_api" {
  name        = "kitti-ml-rest-api"
  description = "REST API for KITTI YOLOv8 SageMaker inference"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  binary_media_types = [
    "image/png",
    "image/jpeg",
    "application/octet-stream"
  ]

  tags = {
    Project   = "kitti-ml-project"
    Phase     = "api"
    ManagedBy = "Terraform"
  }
}

resource "aws_api_gateway_resource" "predict" {
  rest_api_id = aws_api_gateway_rest_api.kitti_api.id
  parent_id   = aws_api_gateway_rest_api.kitti_api.root_resource_id
  path_part   = "predict"
}

resource "aws_api_gateway_resource" "health" {
  rest_api_id = aws_api_gateway_rest_api.kitti_api.id
  parent_id   = aws_api_gateway_rest_api.kitti_api.root_resource_id
  path_part   = "health"
}

resource "aws_api_gateway_method" "predict_post" {
  rest_api_id      = aws_api_gateway_rest_api.kitti_api.id
  resource_id      = aws_api_gateway_resource.predict.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_method" "health_get" {
  rest_api_id      = aws_api_gateway_rest_api.kitti_api.id
  resource_id      = aws_api_gateway_resource.health.id
  http_method      = "GET"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_method" "predict_options" {
  rest_api_id   = aws_api_gateway_rest_api.kitti_api.id
  resource_id   = aws_api_gateway_resource.predict.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "predict_options" {
  rest_api_id = aws_api_gateway_rest_api.kitti_api.id
  resource_id = aws_api_gateway_resource.predict.id
  http_method = aws_api_gateway_method.predict_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "predict_options_200" {
  rest_api_id = aws_api_gateway_rest_api.kitti_api.id
  resource_id = aws_api_gateway_resource.predict.id
  http_method = aws_api_gateway_method.predict_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "predict_options_200" {
  rest_api_id = aws_api_gateway_rest_api.kitti_api.id
  resource_id = aws_api_gateway_resource.predict.id
  http_method = aws_api_gateway_method.predict_options.http_method
  status_code = aws_api_gateway_method_response.predict_options_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,x-api-key'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

resource "aws_api_gateway_integration" "predict_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.kitti_api.id
  resource_id             = aws_api_gateway_resource.predict.id
  http_method             = aws_api_gateway_method.predict_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.rest_api_handler.invoke_arn
}

resource "aws_api_gateway_integration" "health_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.kitti_api.id
  resource_id             = aws_api_gateway_resource.health.id
  http_method             = aws_api_gateway_method.health_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.rest_api_handler.invoke_arn
}

resource "aws_lambda_permission" "allow_api_gateway" {
  statement_id  = "AllowExecutionFromApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rest_api_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.kitti_api.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "kitti_api" {
  rest_api_id = aws_api_gateway_rest_api.kitti_api.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.predict.id,
      aws_api_gateway_method.predict_post.id,
      aws_api_gateway_method.predict_options.id,
      aws_api_gateway_integration.predict_lambda.id,
      aws_api_gateway_integration.predict_options.id,
      aws_api_gateway_resource.health.id,
      aws_api_gateway_method.health_get.id,
      aws_api_gateway_integration.health_lambda.id
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "dev" {
  rest_api_id   = aws_api_gateway_rest_api.kitti_api.id
  deployment_id = aws_api_gateway_deployment.kitti_api.id
  stage_name    = var.api_stage_name
}

resource "aws_api_gateway_api_key" "kitti_api_key" {
  name    = "kitti-ml-rest-api-key"
  enabled = true
}

resource "aws_api_gateway_usage_plan" "kitti_usage_plan" {
  name = "kitti-ml-rest-api-usage-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.kitti_api.id
    stage  = aws_api_gateway_stage.dev.stage_name
  }

  throttle_settings {
    burst_limit = 5
    rate_limit  = 2
  }

  quota_settings {
    limit  = 1000
    period = "MONTH"
  }
}

resource "aws_api_gateway_usage_plan_key" "kitti_usage_plan_key" {
  key_id        = aws_api_gateway_api_key.kitti_api_key.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.kitti_usage_plan.id
}
```

Outputs del modulo y root:

```hcl
output "api_base_url" {
  value = "https://${aws_api_gateway_rest_api.kitti_api.id}.execute-api.${var.aws_region}.amazonaws.com/${aws_api_gateway_stage.dev.stage_name}"
}

output "api_key_id" {
  value = aws_api_gateway_api_key.kitti_api_key.id
}
```

Para obtener el valor real de la API key:

```bash
aws apigateway get-api-key \
  --api-key "$(terraform -chdir=terraform output -raw api_key_id)" \
  --include-value \
  --query value \
  --output text \
  --profile kitti-ml \
  --region us-east-1
```

### API5. Probar la API desde VS Code

Despues de `terraform apply`:

```bash
export API_BASE_URL="$(terraform -chdir=terraform output -raw api_base_url)"
export API_KEY="$(aws apigateway get-api-key \
  --api-key "$(terraform -chdir=terraform output -raw api_key_id)" \
  --include-value \
  --query value \
  --output text \
  --profile kitti-ml \
  --region us-east-1)"
```

Health check:

```bash
curl -s "${API_BASE_URL}/health" | python3 -m json.tool
```

Prediccion usando S3:

```bash
curl -s -X POST "${API_BASE_URL}/predict" \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${API_KEY}" \
  -d "{
    \"s3_bucket\": \"kitti-ml-project-input-${AWS_ACCOUNT_ID}\",
    \"s3_key\": \"incoming/000000.png\",
    \"content_type\": \"image/png\",
    \"confidence_threshold\": 0.7
  }" | python3 -m json.tool
```

Prediccion usando base64 local:

```bash
IMAGE_B64="$(base64 -w 0 data/raw/kitti/training/image_2/000000.png)"

curl -s -X POST "${API_BASE_URL}/predict" \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${API_KEY}" \
  -d "{
    \"image_base64\": \"${IMAGE_B64}\",
    \"content_type\": \"image/png\",
    \"confidence_threshold\": 0.7
  }" | python3 -m json.tool
```

Respuesta esperada:

```json
{
  "summary": "Detectados: ...",
  "count": 1,
  "detections": [],
  "endpoint_name": "kitti-yolov8-endpoint"
}
```

Si recibes `403 Forbidden`, revisa que mandaste `x-api-key`. Si recibes `500 Prediction failed`, revisa que el SageMaker endpoint este `InService`.

### API6. AWS Console para API REST

1. En AWS Console busca `API Gateway`.
2. Haz click en `API Gateway`.
3. En el menu izquierdo o tabla principal, entra a `APIs`.
4. Busca `kitti-ml-rest-api`.
5. Haz click en el nombre.
6. En `Resources`, debes ver:
   - `/health`
   - `/predict`
7. Haz click en `/health`.
8. Debes ver metodo `GET`.
9. Haz click en `GET`.
10. Verifica:
    - Integration type: `Lambda Function`.
    - Lambda Function: `kitti-rest-api-handler`.
    - Lambda Proxy integration: enabled.
11. Haz click en `/predict`.
12. Debes ver metodo `POST`.
13. Haz click en `POST`.
14. Verifica:
    - API Key Required: `true`.
    - Integration type: `Lambda Function`.
    - Lambda Function: `kitti-rest-api-handler`.
15. En el menu izquierdo de esta API, haz click en `Stages`.
16. Haz click en stage `dev`.
17. Copia `Invoke URL`.
18. Verificacion visual esperada:
    - Debes ver una pantalla con `dev` seleccionado y una URL tipo `https://abc123.execute-api.us-east-1.amazonaws.com/dev`.

Screenshot descriptivo: deberias ver el arbol de recursos con `/`, `/health` y `/predict`; al seleccionar `POST` en `/predict`, el panel debe mostrar la integracion Lambda hacia `kitti-rest-api-handler`.

### API7. AWS Console para API key y usage plan

1. En API Gateway, menu izquierdo, haz click en `API Keys`.
2. Busca `kitti-ml-rest-api-key`.
3. Haz click en la key.
4. Haz click en `Show` para ver el valor si necesitas probar en Postman.
5. Verifica que `Enabled` este activo.
6. Menu izquierdo, haz click en `Usage Plans`.
7. Busca `kitti-ml-rest-api-usage-plan`.
8. Haz click.
9. Verifica:
   - Rate: `2 requests/second`.
   - Burst: `5`.
   - Quota: `1000 requests/month`.
   - Associated API stage: `kitti-ml-rest-api:dev`.
   - Associated API key: `kitti-ml-rest-api-key`.

### API8. CloudWatch Logs para API REST

1. Entra a `CloudWatch`.
2. Menu izquierdo: `Logs > Log groups`.
3. Busca `/aws/lambda/kitti-rest-api-handler`.
4. Abre el log group.
5. Abre el log stream mas reciente.
6. Verificacion esperada despues de llamar `/predict`:
   - Log JSON con `"event": "api_prediction_completed"`.
   - Campo `endpoint_name` igual a `kitti-yolov8-endpoint`.
   - Campo `detections` con numero.
7. Si falla:
   - `bad_request`: payload mal formado.
   - `Bucket not allowed`: estas mandando un bucket fuera de input/raw.
   - `Endpoint ... not found`: endpoint destruido o nombre incorrecto.
   - `AccessDeniedException`: revisar `KittiApiLambdaRole`.

### API9. Postman o navegador

Navegador:

1. Abre `https://<api-id>.execute-api.us-east-1.amazonaws.com/dev/health`.
2. Verificacion esperada:
   - JSON con `"status": "ok"`.

Postman:

1. Method: `POST`.
2. URL: `https://<api-id>.execute-api.us-east-1.amazonaws.com/dev/predict`.
3. Tab `Headers`:
   - `Content-Type`: `application/json`.
   - `x-api-key`: valor real de la API key.
4. Tab `Body`:
   - Selecciona `raw`.
   - Selecciona `JSON`.
   - Pega:

```json
{
  "s3_bucket": "kitti-ml-project-input-${AWS_ACCOUNT_ID}",
  "s3_key": "incoming/000000.png",
  "content_type": "image/png",
  "confidence_threshold": 0.7
}
```

5. Click `Send`.
6. Verificacion esperada:
   - Status HTTP `200 OK`.
   - Body JSON con `summary`, `count`, `detections`.

### API10. Costo de la API REST

API Gateway REST API cobra por llamadas. Para este proyecto:

- 1,000 llamadas de demo: normalmente centavos o dentro de free tier si aplica.
- El costo grande sigue siendo SageMaker Endpoint vivo, no API Gateway.
- Usage plan limita a `1000` requests/mes y `2` requests/seg para evitar abuso accidental.

Apagar solo la API:

```bash
cd terraform
terraform destroy \
  -target=module.ai-inference.aws_api_gateway_rest_api.kitti_api \
  -target=module.ai-inference.aws_lambda_function.rest_api_handler
```

Nota: apagar la API no apaga SageMaker Endpoint. Para ahorrar de verdad:

```bash
terraform destroy -target=module.ai-inference.aws_sagemaker_endpoint.kitti_endpoint
```

## 11. Orquestacion - Step Functions

### O1. `src/step_functions/workflow.json`

La state machine debe tener estos estados:

1. `StartGlueCrawler`
   - Resource: `arn:aws:states:::aws-sdk:glue:startCrawler`
   - Parameters: `{ "Name": "kitti-labels-crawler" }`
2. `WaitForCrawler`
   - Type: `Wait`
   - Seconds: `30`
3. `GetCrawlerStatus`
   - Resource: `arn:aws:states:::aws-sdk:glue:getCrawler`
4. `CrawlerFinishedChoice`
   - Si `Crawler.State == READY`, sigue.
   - Si no, vuelve a `WaitForCrawler`.
5. `RunGlueJob`
   - Resource: `arn:aws:states:::glue:startJobRun.sync`
   - JobName: `kitti-clean-labels-job`
6. `PrepareYOLODataset`
   - Resource: `arn:aws:states:::lambda:invoke`
   - FunctionName: `kitti-prepare-yolo-dataset`
7. `StartSageMakerTraining`
   - Resource: `arn:aws:states:::sagemaker:createTrainingJob.sync`
   - TrainingJobName debe incluir timestamp o execution id para evitar colision:
     - `kitti-yolov8-training-.$$.Execution.Name` no se puede concatenar directo en JSONPath simple; usar `States.Format`.
8. `UpdateSageMakerEndpoint`
   - Resource: `arn:aws:states:::aws-sdk:sagemaker:updateEndpoint`
   - EndpointName: `kitti-yolov8-endpoint`
   - EndpointConfigName: config nueva.
9. `NotifySuccess`
   - Resource: `arn:aws:states:::sns:publish`
   - TopicArn: `kitti-detections`
   - Message: pipeline terminado.
10. `NotifyFailure`
   - Resource: `arn:aws:states:::sns:publish`
   - Message: error con causa.

Cada estado critico debe tener `Catch` hacia `NotifyFailure`:

- `StartGlueCrawler`
- `RunGlueJob`
- `PrepareYOLODataset`
- `StartSageMakerTraining`
- `UpdateSageMakerEndpoint`

### O2. Terraform `modules/orchestration`

Recursos:

1. `aws_iam_role.step_functions_role`
   - name: `KittiStepFunctionsRole`
2. `aws_iam_role_policy.step_functions_policy`
   - Glue:
     - `glue:StartCrawler`
     - `glue:GetCrawler`
     - `glue:StartJobRun`
     - `glue:GetJobRun`
     - `glue:GetJobRuns`
     - `glue:BatchStopJobRun`
   - Lambda:
     - `lambda:InvokeFunction`
   - SageMaker:
     - `sagemaker:CreateTrainingJob`
     - `sagemaker:DescribeTrainingJob`
     - `sagemaker:StopTrainingJob`
     - `sagemaker:CreateModel`
     - `sagemaker:CreateEndpointConfig`
     - `sagemaker:UpdateEndpoint`
     - `sagemaker:DescribeEndpoint`
   - IAM PassRole:
     - SageMaker role only.
   - SNS Publish:
     - `kitti-detections`
3. `aws_sfn_state_machine.kitti_pipeline`
   - name: `kitti-ml-pipeline`
   - type: `STANDARD`
   - definition: `file("${path.module}/../../../src/step_functions/workflow.json")` o templatefile con ARNs.
   - logging_configuration:
     - log group: `/aws/vendedlogs/states/kitti-ml-pipeline`
     - include_execution_data: `true`
     - level: `ALL`
4. `aws_cloudwatch_log_group.step_functions_logs`
   - name: `/aws/vendedlogs/states/kitti-ml-pipeline`
   - retention: `7`

AWS Console para Step Functions:

1. Entra a `Step Functions`.
2. Menu izquierdo: `State machines`.
3. Busca `kitti-ml-pipeline`.
4. Clic en el nombre.
5. Clic `Start execution`.
6. Input para sample:

```json
{
  "mode": "sample",
  "sample_size": 100
}
```

7. Clic `Start execution`.
8. Observa el grafo. Verde significa estado completado.
9. Si falla:
   - Abre el estado rojo.
   - Copia `Cause`.
   - Revisa CloudWatch logs del servicio correspondiente.

## 12. Fase C - Observabilidad

### C1. Terraform `modules/observability`

Recursos:

1. `aws_cloudwatch_log_group.lambda_logs`
   - name: `/aws/lambda/kitti-inference-handler`
   - retention: `7`
2. `aws_cloudwatch_log_group.prepare_yolo_logs`
   - name: `/aws/lambda/kitti-prepare-yolo-dataset`
   - retention: `7`
3. `aws_cloudwatch_metric_alarm.sagemaker_5xx`
   - name: `kitti-sagemaker-5xx-rate-high`
   - namespace: `AWS/SageMaker`
   - metric: `Invocation5XXErrors`
   - threshold: `1` para demo simple, porque calcular porcentaje real requiere metric math con invocations.
   - period: `300`
   - evaluation periods: `1`
   - alarm action: SNS alert.
4. `aws_cloudwatch_dashboard.kitti_dashboard`
   - name: `kitti-ml-dashboard`

Widgets:

1. Glue Job duration:
   - Namespace: `Glue`
   - Metric: `glue.driver.ExecutorRunTime`
   - Dimensions: job name.
2. S3 curated object count:
   - Custom metric `KittiMLProject/Storage`
   - Metric: `CuratedObjectCount`
   - Se emite desde script o Lambda programada.
3. SageMaker:
   - `ModelLatency`
   - `Invocation5XXErrors`
4. Lambda:
   - `Invocations`
   - `Errors`
   - `Duration`
5. API Gateway REST API:
   - Namespace: `AWS/ApiGateway`
   - API: `kitti-ml-rest-api`
   - Metrics: `Count`, `Latency`, `5XXError`, `4XXError`
6. Glue custom:
   - `ProcessedImages`
   - `FailedImages`

### C2. CloudWatch custom metrics desde PySpark

`clean_data.py` debe usar boto3 al final:

```python
cloudwatch.put_metric_data(
    Namespace="KittiMLProject/DataEngineering",
    MetricData=[
        {"MetricName": "ProcessedImages", "Value": processed_images, "Unit": "Count"},
        {"MetricName": "FailedImages", "Value": failed_images, "Unit": "Count"},
        {"MetricName": "AvgFileSize", "Value": avg_file_size, "Unit": "Bytes"},
    ],
)
```

Ver metricas:

1. Entra a `CloudWatch`.
2. Menu izquierdo: `Metrics > All metrics`.
3. Busca namespace `KittiMLProject/DataEngineering`.
4. Selecciona `ProcessedImages`.

## 13. IAM Least Privilege

### `KittiGlueRole`

Permisos:

- `s3:GetObject`, `s3:ListBucket` en raw bucket.
- `s3:PutObject`, `s3:GetObject`, `s3:ListBucket`, `s3:DeleteObject` en curated bucket.
- `s3:GetObject` en model artifacts para scripts.
- `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`.
- `cloudwatch:PutMetricData` con condition namespace `KittiMLProject/DataEngineering`.

### `KittiSageMakerRole`

Permisos:

- `s3:GetObject`, `s3:ListBucket` en curated bucket.
- `s3:GetObject`, `s3:PutObject`, `s3:ListBucket` en model artifacts.
- `logs:*` limitado a CloudWatch log groups de SageMaker.
- `cloudwatch:PutMetricData`.
- ECR pull:
  - `ecr:GetAuthorizationToken`
  - `ecr:BatchCheckLayerAvailability`
  - `ecr:GetDownloadUrlForLayer`
  - `ecr:BatchGetImage`

### `KittiLambdaRole`

Permisos:

- `s3:GetObject` en input bucket `incoming/*`.
- `sagemaker:InvokeEndpoint` solo endpoint `kitti-yolov8-endpoint`.
- `sns:Publish` solo topic `kitti-detections`.
- `sqs:SendMessage` solo `kitti-lambda-dlq`.
- CloudWatch Logs write.

### `KittiApiLambdaRole`

Permisos:

- `s3:GetObject` solo en:
  - `kitti-ml-project-input-${AWS_ACCOUNT_ID}/incoming/*`
  - `kitti-ml-project-raw-${AWS_ACCOUNT_ID}/images/*`
- `sagemaker:InvokeEndpoint` solo endpoint `kitti-yolov8-endpoint`.
- `sagemaker:DescribeEndpoint` solo endpoint `kitti-yolov8-endpoint` para `GET /health`.
- CloudWatch Logs write para `/aws/lambda/kitti-rest-api-handler`.

### `KittiStepFunctionsRole`

Permisos:

- Glue start/get crawler y job.
- Lambda invoke para `kitti-prepare-yolo-dataset`.
- SageMaker create/describe/stop training, model/endpoint config/update endpoint.
- `iam:PassRole` solo a `KittiSageMakerRole`.
- SNS publish a `kitti-detections`.

## 14. Desarrollo Local con LocalStack

### 14.1 Instalar herramientas LocalStack

```bash
python3 -m pip install --user localstack awscli-local terraform-local
```

Agrega pip user bin al PATH si hace falta:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### 14.2 `scripts/setup_localstack.sh`

Debe:

1. Verificar Docker.
2. Exportar:

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export LOCALSTACK_AUTH_TOKEN="${LOCALSTACK_AUTH_TOKEN:-}"
```

3. Iniciar LocalStack:

```bash
localstack start -d
```

4. Esperar health:

```bash
localstack wait -t 60
```

5. Verificar:

```bash
awslocal s3 ls
awslocal sns list-topics
awslocal sqs list-queues
awslocal lambda list-functions
awslocal apigateway get-rest-apis
awslocal stepfunctions list-state-machines
```

6. Mostrar advertencia:

```text
Glue/SageMaker en LocalStack son para validacion limitada/mock; la prueba real se hace una sola vez en AWS.
```

### 14.3 `scripts/deploy.sh`

Debe aceptar:

```bash
bash scripts/deploy.sh local
bash scripts/deploy.sh aws
```

Modo local:

```bash
cd terraform
tflocal init
tflocal apply -auto-approve
```

Modo AWS:

1. Imprimir:

```text
Vas a desplegar recursos reales en us-east-1.
Endpoint SageMaker cobra por hora.
Escribe APPLY_AWS para continuar:
```

2. Si el usuario escribe exacto `APPLY_AWS`:

```bash
cd terraform
terraform init \
  -backend-config="bucket=kitti-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=cloud-data-ia-project/terraform.tfstate" \
  -backend-config="region=us-east-1"
terraform plan
terraform apply
```

3. Si no, abortar.

## 15. Presupuesto Detallado 118 USD

| Servicio | Uso estimado demo | Costo aprox | Cuando empieza a cobrar | Como apagar |
|---|---:|---:|---|---|
| S3 Standard | 14 GB | `~0.32 USD/mes` | Al almacenar objetos | Borrar buckets o lifecycle |
| S3 requests | 15k-30k requests | `<0.10 USD` | Al hacer PUT/GET/LIST | No aplica |
| Glue Crawler | sample/full labels | `<0.10-0.50 USD` | Al correr crawler | No correr repetidamente |
| Glue Job Spark | 2 workers G.1X, 15-30 min | `~0.22-0.44 USD` | Al correr job | Job termina solo |
| SageMaker training CPU | `ml.m5.xlarge`, 1-2 h | `~0.23-0.46 USD` | Mientras training job corre | Job termina solo |
| SageMaker training GPU | `ml.g4dn.xlarge`, 1-2 h | `~0.74-1.47 USD` | Mientras training job corre | Job termina solo |
| SageMaker endpoint | `ml.t2.medium`, 4 h demo | `~0.22 USD` | Mientras endpoint esta InService | `terraform destroy -target=module.ai-inference.aws_sagemaker_endpoint.kitti_endpoint` |
| SageMaker endpoint olvidado | `ml.t2.medium`, 30 dias | `~40.32 USD/mes` | Aunque no tenga trafico | Destruir endpoint |
| API Gateway REST API | 1k requests demo | Free tier / centavos | Cada request HTTP recibida | Destroy API o usage plan bajo |
| Lambda | pocas invocaciones | Free tier / centavos | Al invocar | No aplica |
| SNS Email | pocas notificaciones | centavos o free | Al publicar | No aplica |
| SQS DLQ | pocos mensajes | centavos o free | Al usar cola | No aplica |
| Step Functions | menos de 4k transitions | `0 USD` usual | Cada transicion | No ejecutar loops largos |
| CloudWatch Logs/Metrics | bajo volumen | `~1-3 USD` | Logs y metricas custom | Retencion 7 dias |
| Total demo responsable | sample + endpoint 4h | `~5-10 USD` | Segun ejecuciones | Destroy al final |
| Total full conservador | full + endpoint 1 dia | `~15-55 USD` | Endpoint domina | No dejar endpoint vivo |

Comandos de emergencia:

```bash
cd cloud-data-ia-project/terraform

terraform destroy -target=module.ai-inference.aws_sagemaker_endpoint.kitti_endpoint

aws sagemaker list-endpoints --profile kitti-ml --region us-east-1

aws sagemaker delete-endpoint \
  --endpoint-name kitti-yolov8-endpoint \
  --profile kitti-ml \
  --region us-east-1
```

Destroy completo al terminar la materia:

```bash
cd terraform
terraform destroy
```

Si falla por buckets no vacios:

```bash
aws s3 rm "s3://kitti-ml-project-raw-${AWS_ACCOUNT_ID}" --recursive
aws s3 rm "s3://kitti-ml-project-curated-${AWS_ACCOUNT_ID}" --recursive
aws s3 rm "s3://kitti-ml-project-input-${AWS_ACCOUNT_ID}" --recursive
aws s3 rm "s3://kitti-ml-project-model-artifacts-${AWS_ACCOUNT_ID}" --recursive
terraform destroy
```

## 16. Carga del Dataset a SageMaker - Paso a Paso Critico

1. Descargar KITTI:

```bash
wget -c https://s3.eu-central-1.amazonaws.com/avg-kitti/data_object_image_2.zip -O data/kitti_downloads/data_object_image_2.zip
wget -c https://s3.eu-central-1.amazonaws.com/avg-kitti/data_object_label_2.zip -O data/kitti_downloads/data_object_label_2.zip
```

2. Descomprimir:

```bash
unzip -q data/kitti_downloads/data_object_image_2.zip -d data/raw/kitti
unzip -q data/kitti_downloads/data_object_label_2.zip -d data/raw/kitti
```

3. Crear infra storage en AWS:

```bash
cd terraform
terraform init \
  -backend-config="bucket=kitti-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=cloud-data-ia-project/terraform.tfstate" \
  -backend-config="region=us-east-1"
terraform apply -target=module.storage
cd ..
```

4. Subir sample:

```bash
python3 scripts/upload_kitti.py \
  --dataset-root data/raw/kitti/training \
  --raw-bucket "kitti-ml-project-raw-${AWS_ACCOUNT_ID}" \
  --sample \
  --sample-size 100 \
  --profile kitti-ml \
  --region us-east-1
```

5. Verificar S3:

```bash
aws s3 ls "s3://kitti-ml-project-raw-${AWS_ACCOUNT_ID}/images/" --profile kitti-ml --region us-east-1 | head
aws s3 ls "s3://kitti-ml-project-raw-${AWS_ACCOUNT_ID}/labels/" --profile kitti-ml --region us-east-1 | head
```

6. Aplicar data engineering:

```bash
cd terraform
terraform apply -target=module.data-eng
cd ..
```

7. Ejecutar crawler:

```bash
aws glue start-crawler \
  --name kitti-labels-crawler \
  --profile kitti-ml \
  --region us-east-1
```

8. Esperar crawler:

```bash
aws glue get-crawler \
  --name kitti-labels-crawler \
  --query 'Crawler.State' \
  --profile kitti-ml \
  --region us-east-1
```

9. Ejecutar Glue job:

```bash
JOB_RUN_ID="$(aws glue start-job-run \
  --job-name kitti-clean-labels-job \
  --query JobRunId \
  --output text \
  --profile kitti-ml \
  --region us-east-1)"

aws glue get-job-run \
  --job-name kitti-clean-labels-job \
  --run-id "$JOB_RUN_ID" \
  --query 'JobRun.JobRunState' \
  --profile kitti-ml \
  --region us-east-1
```

10. Verificar Parquet:

```bash
aws s3 ls "s3://kitti-ml-project-curated-${AWS_ACCOUNT_ID}/labels_parquet/" \
  --recursive \
  --profile kitti-ml \
  --region us-east-1
```

11. Preparar YOLO dataset:

```bash
python3 src/sagemaker/prepare_yolo_dataset.py \
  --raw-bucket "kitti-ml-project-raw-${AWS_ACCOUNT_ID}" \
  --curated-bucket "kitti-ml-project-curated-${AWS_ACCOUNT_ID}" \
  --parquet-prefix labels_parquet/ \
  --output-prefix yolo_dataset/ \
  --sample-size 100 \
  --profile kitti-ml \
  --region us-east-1
```

12. Verificar YOLO en S3:

```bash
aws s3 ls "s3://kitti-ml-project-curated-${AWS_ACCOUNT_ID}/yolo_dataset/" \
  --recursive \
  --profile kitti-ml \
  --region us-east-1 | head -50
```

13. Empaquetar SageMaker source:

```bash
bash scripts/package_sagemaker_source.sh
```

14. Aplicar SageMaker training y endpoint:

```bash
cd terraform
terraform apply -target=module.ai-inference
cd ..
```

15. Verificar training logs:

```bash
aws logs describe-log-groups \
  --log-group-name-prefix /aws/sagemaker/TrainingJobs \
  --profile kitti-ml \
  --region us-east-1
```

16. Verificar endpoint:

```bash
aws sagemaker describe-endpoint \
  --endpoint-name kitti-yolov8-endpoint \
  --query 'EndpointStatus' \
  --profile kitti-ml \
  --region us-east-1
```

17. Subir imagen a input:

```bash
aws s3 cp data/raw/kitti/training/image_2/000000.png \
  "s3://kitti-ml-project-input-${AWS_ACCOUNT_ID}/incoming/000000.png" \
  --profile kitti-ml \
  --region us-east-1
```

18. Revisar correo SNS y CloudWatch logs de Lambda.

19. Apagar endpoint:

```bash
cd terraform
terraform destroy -target=module.ai-inference.aws_sagemaker_endpoint.kitti_endpoint
cd ..
```

## 17. README.md Profesional

El README debe contener:

1. Badges:

```markdown
![Terraform](https://img.shields.io/badge/IaC-Terraform-623CE4)
![AWS](https://img.shields.io/badge/Cloud-AWS-FF9900)
![YOLOv8](https://img.shields.io/badge/Model-YOLOv8-00FFFF)
![SageMaker](https://img.shields.io/badge/ML-SageMaker-527FFF)
![API Gateway](https://img.shields.io/badge/API-API%20Gateway-FF4F8B)
```

2. Diagrama ASCII:

```text
KITTI local
   |
   v
upload_kitti.py
   |
   v
S3 raw ---> Glue Crawler ---> Glue Catalog
   |              |
   |              v
   +-------> Glue ETL clean_data.py ---> S3 curated Parquet
   |
   +-- labels/*.txt event --> retraining_trigger Lambda
                                |
                                v
                    SSM /kitti/new-images-count
                    SSM /kitti/last-training-date
                                |
                     if count >= 500 and >= 3 days
                                |
                                v
                         Step Functions retraining
                                      |
                                      v
                         prepare_yolo_dataset.py
                                      |
                                      v
                         S3 curated YOLO dataset
                                      |
                                      v
                           SageMaker Training
                                      |
                                      v
                         S3 model artifacts
                                      |
                                      v
                       SageMaker Real-Time Endpoint
                                      ^
                                      |
Client / Postman / Frontend --> API Gateway REST API --> Lambda api_handler
                                      |
                                      v
                              JSON detections
                                      ^
                                      |
S3 input image ---> Lambda handler ----+
                         |
                         v
                    SNS Email + SQS DLQ

Step Functions orchestra crawler, ETL, YOLO prep, training, endpoint update.
The raw-data Lambda implements a data-driven threshold-based retraining pipeline.
CloudWatch logs, metrics, alarms and dashboard observe everything.
```

3. Quick Start con comandos exactos:
   - setup tools
   - create state bucket
   - localstack
   - terraform local
   - terraform AWS
   - upload sample
   - run pipeline
   - test REST API `/health` and `/predict`
   - destroy endpoint
4. Resultados esperados:
   - sample: pipeline funcional, no metrica alta.
   - full YOLOv8n 20 epochs: mAP50 estimado inicial `0.35-0.55` dependiendo split, epochs, GPU/CPU.
5. Architecture Decisions:
   - S3 para data lake.
   - Glue para ETL serverless.
   - Parquet para analytics.
   - SageMaker para managed training/endpoint.
   - Lambda para inferencia event-driven.
   - API Gateway REST API para consumo HTTP del modelo desde clientes externos.
   - Lambda `api_handler.py` para validar payloads y llamar `InvokeEndpoint`.
   - Step Functions para orquestacion visible.
   - SSM Parameter Store para contador simple de reentrenamiento.
   - Lambda retraining trigger para pipeline data-driven threshold-based.
   - Terraform para reproducibilidad.
   - LocalStack para pruebas locales baratas.
6. Cost Optimization:
   - sample first
   - YOLOv8n
   - endpoint `ml.t2.medium`
   - API key + usage plan para limitar llamadas REST accidentales.
   - lifecycle Glacier
   - log retention 7 dias
   - destroy target endpoint
7. Data-driven threshold-based retraining pipeline:
   - Explica que los labels nuevos en `raw/labels/` activan `kitti-retraining-trigger`.
   - Explica que SSM guarda `/kitti/new-images-count` y `/kitti/last-training-date`.
   - Explica que Step Functions se dispara automaticamente al llegar a 500 imagenes nuevas y 3 dias minimos desde el ultimo entrenamiento.
   - Incluye el comando de prueba que pone el contador en `499` y sube un label para demostrar el disparo.

## 18. Orden de Ejecucion Final Desde Cero

1. Entrar a AWS Console.
2. Seleccionar region `us-east-1`.
3. Crear AWS Budget `kitti-ml-project-118usd-budget`.
4. Configurar AWS CLI profile `kitti-ml`.
5. Exportar `AWS_PROFILE`, `AWS_REGION`, `AWS_ACCOUNT_ID`.
6. Crear bucket backend `kitti-terraform-state-${AWS_ACCOUNT_ID}`.
7. Crear estructura del repo.
8. Escribir archivos Terraform, scripts Python, Lambda, ASL y README.
9. Instalar LocalStack tools.
10. Ejecutar `bash scripts/setup_localstack.sh`.
11. Ejecutar `bash scripts/deploy.sh local`.
12. Descargar KITTI `data_object_image_2.zip` y `data_object_label_2.zip`.
13. Descomprimir en `data/raw/kitti`.
14. Empaquetar SageMaker source con `bash scripts/package_sagemaker_source.sh`.
15. Ejecutar `bash scripts/deploy.sh aws` solo con storage primero si decides separar applies.
16. Subir sample con `upload_kitti.py --sample --sample-size 100`.
17. Aplicar `module.data-eng`.
18. Ejecutar crawler.
19. Ejecutar Glue job.
20. Validar Parquet en curated.
21. Ejecutar `prepare_yolo_dataset.py --sample-size 100`.
22. Validar `yolo_dataset/` en S3.
23. Aplicar `module.ai-inference`.
24. Entrar a SageMaker AI Console.
25. Ver `Training jobs > kitti-yolov8-training`.
26. Abrir CloudWatch logs del training job.
27. Confirmar que existe `model.tar.gz` en model artifacts bucket.
28. Ver `Inference > Endpoints > kitti-yolov8-endpoint`.
29. Esperar `InService`.
30. Ver API Gateway `kitti-ml-rest-api`.
31. Obtener `api_base_url` y `api_key_id` desde Terraform outputs.
32. Probar `GET /health`.
33. Probar `POST /predict` con S3 URI.
34. Revisar logs de `/aws/lambda/kitti-rest-api-handler`.
35. Confirmar suscripcion SNS por email.
36. Subir imagen a `s3://kitti-ml-project-input-${AWS_ACCOUNT_ID}/incoming/`.
37. Revisar email SNS con detecciones.
38. Revisar logs Lambda en CloudWatch.
39. Aplicar `module.orchestration`.
40. Verificar SSM parameters `/kitti/new-images-count` y `/kitti/last-training-date`.
41. Probar retraining trigger subiendo un label `.txt` nuevo a `raw/labels/`.
42. Entrar a Step Functions.
43. Ejecutar `kitti-ml-pipeline` con input sample.
44. Aplicar `module.observability`.
45. Entrar a CloudWatch Dashboard `kitti-ml-dashboard`.
46. Tomar screenshots para README/LinkedIn:
    - S3 buckets
    - Glue job completed
    - SageMaker training completed
    - Endpoint InService
    - API Gateway `/health` y `/predict`
    - Lambda REST API logs
    - SSM parameters del retraining trigger
    - Lambda retraining trigger logs
    - Step Functions green graph
    - CloudWatch dashboard
47. Apagar endpoint con:

```bash
cd terraform
terraform destroy -target=module.ai-inference.aws_sagemaker_endpoint.kitti_endpoint
```

48. Revisar Billing Dashboard al dia siguiente.
49. Para demo final full:
    - subir dataset completo sin `--sample`.
    - correr Glue full.
    - preparar YOLO full.
    - entrenar con `ml.g4dn.xlarge`, `epochs=20`, `batch=16` si creditos alcanzan.
    - desplegar endpoint solo durante la demo.
    - destruir endpoint al terminar.

## 19. Puntos Donde Es Facil Equivocarse

1. No intentes crear buckets S3 con nombres ya ocupados globalmente; usa sufijo `AWS_ACCOUNT_ID`.
2. No dejes SageMaker endpoint vivo. Es el mayor riesgo del presupuesto.
3. No descargues KITTI completo de 80 GB. Solo `image_2` y `label_2`.
4. No normalices YOLO usando ancho/alto fijo si quieres calidad; lee dimensiones reales de cada imagen.
5. No esperes que LocalStack sustituya entrenamiento real de SageMaker. Usalo para validar IaC y eventos.
6. No ejecutes Glue muchas veces con full dataset sin mirar logs; primero sample 100.
7. No uses `ml.g4dn.xlarge` para endpoint si tienes presupuesto limitado; usalo solo para training si hace falta.
8. No olvides confirmar la suscripcion SNS por email; si no, no llegaran alertas.
9. No pruebes `/predict` si el endpoint esta destruido; `/health` puede responder, pero la prediccion fallara.
10. No publiques la API sin API key o usage plan; aunque API Gateway sea barato, cada request puede invocar SageMaker.
11. No borres el bucket de Terraform state antes de `terraform destroy`.
12. No hagas `terraform destroy` completo si necesitas conservar screenshots/logs para entrega; primero captura evidencias.

## 20. Reentrenamiento Automatico por Volumen de Datos Nuevos

Nombre de la capacidad en README: `data-driven threshold-based retraining pipeline`.

### 20.1 Logica exacta

1. Los datos nuevos llegan al bucket raw en formato KITTI estandar:

```text
s3://kitti-ml-project-raw-${AWS_ACCOUNT_ID}/images/009999.png
s3://kitti-ml-project-raw-${AWS_ACCOUNT_ID}/labels/009999.txt
```

2. La notificacion S3 se configura sobre `labels/` con suffix `.txt`, no sobre `images/`. Esto evita contar dos veces y significa: "si llego el label, la imagen ya esta etiquetada".
3. La Lambda `kitti-retraining-trigger` valida que exista la imagen correspondiente en `images/<image_id>.png`.
4. Si existe, incrementa `/kitti/new-images-count` en SSM Parameter Store.
5. Lee `/kitti/last-training-date`.
6. Si `new-images-count >= 500` y pasaron al menos `3` dias desde `last-training-date`, inicia el state machine `kitti-ml-pipeline`.
7. Si `StartExecution` fue exitoso:
   - resetea `/kitti/new-images-count` a `0`.
   - actualiza `/kitti/last-training-date` con timestamp UTC actual.
8. Para evitar condiciones de carrera con SSM, la Lambda se despliega con `reserved_concurrent_executions = 1`.

### 20.2 Archivo local en VS Code

En VS Code:

1. Abre la carpeta `/home/andresuki/cloudC/definitive_project/cloud-data-ia-project`.
2. En el panel izquierdo, abre `src/lambda/`.
3. Crea o abre `retraining_trigger.py`.
4. Pega este codigo completo.
5. Guarda con `Ctrl+S`.

### 20.3 `src/lambda/retraining_trigger.py`

```python
import json
import os
from datetime import datetime, timezone
from urllib.parse import unquote_plus

import boto3
from botocore.exceptions import ClientError


s3 = boto3.client("s3")
ssm = boto3.client("ssm")
sfn = boto3.client("stepfunctions")


COUNT_PARAM = os.environ.get("COUNT_PARAM", "/kitti/new-images-count")
LAST_TRAINING_PARAM = os.environ.get("LAST_TRAINING_PARAM", "/kitti/last-training-date")
STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]
THRESHOLD = int(os.environ.get("RETRAIN_THRESHOLD", "500"))
MIN_DAYS = int(os.environ.get("MIN_DAYS_BETWEEN_RETRAINING", "3"))
IMAGE_PREFIX = os.environ.get("IMAGE_PREFIX", "images/")
LABEL_PREFIX = os.environ.get("LABEL_PREFIX", "labels/")
IMAGE_EXTENSION = os.environ.get("IMAGE_EXTENSION", ".png")


def log(level, event, **fields):
    print(json.dumps({"level": level, "event": event, **fields}, default=str))


def get_parameter(name, default_value):
    try:
        response = ssm.get_parameter(Name=name)
        return response["Parameter"]["Value"]
    except ssm.exceptions.ParameterNotFound:
        log("WARN", "parameter_missing", parameter=name, default=default_value)
        ssm.put_parameter(Name=name, Value=str(default_value), Type="String", Overwrite=True)
        return str(default_value)


def put_parameter(name, value):
    ssm.put_parameter(Name=name, Value=str(value), Type="String", Overwrite=True)


def parse_utc(value):
    if not value:
        return datetime(1970, 1, 1, tzinfo=timezone.utc)
    normalized = value.replace("Z", "+00:00")
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def image_exists(bucket, label_key):
    if not label_key.startswith(LABEL_PREFIX) or not label_key.endswith(".txt"):
        return False, None

    image_id = label_key.split("/")[-1].replace(".txt", "")
    image_key = f"{IMAGE_PREFIX}{image_id}{IMAGE_EXTENSION}"

    try:
        s3.head_object(Bucket=bucket, Key=image_key)
        return True, image_key
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code")
        log("WARN", "matching_image_not_found", bucket=bucket, label_key=label_key, image_key=image_key, error_code=code)
        return False, image_key


def should_retrain(count, now):
    last_training_value = get_parameter(LAST_TRAINING_PARAM, "1970-01-01T00:00:00+00:00")
    last_training = parse_utc(last_training_value)
    days_elapsed = (now - last_training).total_seconds() / 86400

    decision = count >= THRESHOLD and days_elapsed >= MIN_DAYS
    log(
        "INFO",
        "retraining_decision",
        count=count,
        threshold=THRESHOLD,
        last_training=last_training.isoformat(),
        days_elapsed=round(days_elapsed, 3),
        min_days=MIN_DAYS,
        should_retrain=decision,
    )
    return decision, last_training, days_elapsed


def start_retraining_execution(count, now, source_records):
    execution_name = "kitti-retrain-" + now.strftime("%Y%m%dT%H%M%SZ")
    payload = {
        "trigger": "data-driven-threshold",
        "new_images_count": count,
        "threshold": THRESHOLD,
        "min_days_between_retraining": MIN_DAYS,
        "triggered_at": now.isoformat(),
        "source_records": source_records,
    }

    response = sfn.start_execution(
        stateMachineArn=STATE_MACHINE_ARN,
        name=execution_name,
        input=json.dumps(payload),
    )

    log(
        "INFO",
        "state_machine_started",
        execution_name=execution_name,
        execution_arn=response["executionArn"],
        state_machine_arn=STATE_MACHINE_ARN,
    )
    return response["executionArn"]


def lambda_handler(event, context):
    now = datetime.now(timezone.utc)
    records = event.get("Records", [])

    if not records:
        log("WARN", "empty_event")
        return {"statusCode": 200, "body": json.dumps({"message": "No records"})}

    accepted = []
    skipped = []

    for record in records:
        bucket = record["s3"]["bucket"]["name"]
        key = unquote_plus(record["s3"]["object"]["key"])

        exists, image_key = image_exists(bucket, key)
        if exists:
            accepted.append({"bucket": bucket, "label_key": key, "image_key": image_key})
        else:
            skipped.append({"bucket": bucket, "label_key": key, "image_key": image_key})

    if not accepted:
        log("INFO", "no_countable_labels", skipped=skipped)
        return {"statusCode": 200, "body": json.dumps({"accepted": 0, "skipped": len(skipped)})}

    current_count = int(get_parameter(COUNT_PARAM, "0"))
    new_count = current_count + len(accepted)
    put_parameter(COUNT_PARAM, new_count)

    log(
        "INFO",
        "counter_incremented",
        previous_count=current_count,
        increment=len(accepted),
        new_count=new_count,
        skipped=len(skipped),
    )

    retrain, _, _ = should_retrain(new_count, now)
    execution_arn = None

    if retrain:
        execution_arn = start_retraining_execution(new_count, now, accepted)
        put_parameter(COUNT_PARAM, "0")
        put_parameter(LAST_TRAINING_PARAM, now.isoformat())
        log("INFO", "counter_reset_after_retraining_start", new_count=0, last_training_date=now.isoformat())

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "accepted": len(accepted),
                "skipped": len(skipped),
                "count_after_event": 0 if retrain else new_count,
                "retraining_started": retrain,
                "execution_arn": execution_arn,
            }
        ),
    }
```

### 20.4 Terraform para SSM, IAM, Lambda y S3 event

Ubicacion recomendada: `terraform/modules/orchestration/main.tf`, porque esta Lambda depende del ARN del state machine.

Variables que el modulo `orchestration` debe recibir desde el root:

```hcl
variable "raw_bucket_id" {
  type = string
}

variable "raw_bucket_arn" {
  type = string
}
```

Si estos recursos viven en el mismo modulo que `aws_sfn_state_machine.kitti_pipeline`, usa `aws_sfn_state_machine.kitti_pipeline.arn` directamente. Si decides moverlos a otro modulo, entonces si pasas `state_machine_arn` como variable.

Agrega el provider `archive` en `terraform/main.tf` o en `terraform/versions.tf`:

```hcl
terraform {
  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}
```

Recursos:

```hcl
resource "aws_ssm_parameter" "new_images_count" {
  name        = "/kitti/new-images-count"
  description = "Number of newly labeled KITTI images since last retraining."
  type        = "String"
  value       = "0"
  overwrite   = true

  tags = {
    Project   = "kitti-ml-project"
    Phase     = "orchestration"
    ManagedBy = "Terraform"
  }

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "last_training_date" {
  name        = "/kitti/last-training-date"
  description = "UTC timestamp of the last retraining trigger."
  type        = "String"
  value       = "1970-01-01T00:00:00+00:00"
  overwrite   = true

  tags = {
    Project   = "kitti-ml-project"
    Phase     = "orchestration"
    ManagedBy = "Terraform"
  }

  lifecycle {
    ignore_changes = [value]
  }
}

locals {
  kitti_state_machine_arn = aws_sfn_state_machine.kitti_pipeline.arn
}

resource "aws_iam_role" "retraining_trigger_role" {
  name = "KittiRetrainingTriggerRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Project   = "kitti-ml-project"
    Phase     = "orchestration"
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_role_policy" "retraining_trigger_policy" {
  name = "KittiRetrainingTriggerPolicy"
  role = aws_iam_role.retraining_trigger_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid = "WriteLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Sid = "ReadMatchingRawImage"
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "${var.raw_bucket_arn}/images/*"
      },
      {
        Sid = "ReadWriteRetrainingParameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:PutParameter"
        ]
        Resource = [
          aws_ssm_parameter.new_images_count.arn,
          aws_ssm_parameter.last_training_date.arn
        ]
      },
      {
        Sid = "StartKittiStateMachine"
        Effect = "Allow"
        Action = [
          "states:StartExecution"
        ]
        Resource = local.kitti_state_machine_arn
      }
    ]
  })
}

data "archive_file" "retraining_trigger_zip" {
  type        = "zip"
  source_file = "${path.module}/../../../src/lambda/retraining_trigger.py"
  output_path = "${path.module}/retraining_trigger.zip"
}

resource "aws_lambda_function" "retraining_trigger" {
  function_name = "kitti-retraining-trigger"
  role          = aws_iam_role.retraining_trigger_role.arn
  runtime       = "python3.11"
  handler       = "retraining_trigger.lambda_handler"
  filename      = data.archive_file.retraining_trigger_zip.output_path
  source_code_hash = data.archive_file.retraining_trigger_zip.output_base64sha256

  timeout                        = 30
  memory_size                    = 256
  reserved_concurrent_executions = 1

  environment {
    variables = {
      COUNT_PARAM                 = aws_ssm_parameter.new_images_count.name
      LAST_TRAINING_PARAM         = aws_ssm_parameter.last_training_date.name
      STATE_MACHINE_ARN           = local.kitti_state_machine_arn
      RETRAIN_THRESHOLD           = "500"
      MIN_DAYS_BETWEEN_RETRAINING = "3"
      IMAGE_PREFIX                = "images/"
      LABEL_PREFIX                = "labels/"
      IMAGE_EXTENSION             = ".png"
    }
  }

  tags = {
    Project   = "kitti-ml-project"
    Phase     = "orchestration"
    ManagedBy = "Terraform"
  }
}

resource "aws_lambda_permission" "allow_raw_s3_retraining_trigger" {
  statement_id  = "AllowExecutionFromRawS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.retraining_trigger.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = var.raw_bucket_arn
}

resource "aws_s3_bucket_notification" "raw_retraining_notification" {
  bucket = var.raw_bucket_id

  lambda_function {
    lambda_function_arn = aws_lambda_function.retraining_trigger.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "labels/"
    filter_suffix       = ".txt"
  }

  depends_on = [aws_lambda_permission.allow_raw_s3_retraining_trigger]
}
```

Nota: `aws_s3_bucket_notification` controla toda la configuracion de notificaciones de un bucket. Si en el futuro agregas otra notificacion al bucket raw, integrala en este mismo recurso y no crees un segundo `aws_s3_bucket_notification` para el mismo bucket.

En `terraform/main.tf`, al llamar el modulo `orchestration`, pasa el bucket raw:

```hcl
module "orchestration" {
  source = "./modules/orchestration"

  raw_bucket_id  = module.storage.raw_bucket_id
  raw_bucket_arn = module.storage.raw_bucket_arn

  # otras variables existentes: project_name, sns_topic_arn, glue job, crawler,
  # sagemaker role, model artifacts bucket, etc.
}
```

En `terraform/modules/storage/outputs.tf`, agrega:

```hcl
output "raw_bucket_id" {
  value = aws_s3_bucket.raw.id
}

output "raw_bucket_arn" {
  value = aws_s3_bucket.raw.arn
}
```

### 20.5 Prueba local por AWS CLI

Forzar contador a 499 para probar sin subir 500 labels:

```bash
aws ssm put-parameter \
  --name /kitti/new-images-count \
  --value 499 \
  --type String \
  --overwrite \
  --profile kitti-ml \
  --region us-east-1

aws ssm put-parameter \
  --name /kitti/last-training-date \
  --value "1970-01-01T00:00:00+00:00" \
  --type String \
  --overwrite \
  --profile kitti-ml \
  --region us-east-1
```

Subir una imagen y su label:

```bash
aws s3 cp data/raw/kitti/training/image_2/000001.png \
  "s3://kitti-ml-project-raw-${AWS_ACCOUNT_ID}/images/900001.png" \
  --profile kitti-ml \
  --region us-east-1

aws s3 cp data/raw/kitti/training/label_2/000001.txt \
  "s3://kitti-ml-project-raw-${AWS_ACCOUNT_ID}/labels/900001.txt" \
  --profile kitti-ml \
  --region us-east-1
```

Verifica que el contador se reseteo y que Step Functions inicio:

```bash
aws ssm get-parameter \
  --name /kitti/new-images-count \
  --query 'Parameter.Value' \
  --output text \
  --profile kitti-ml \
  --region us-east-1

aws stepfunctions list-executions \
  --state-machine-arn "$(terraform -chdir=terraform output -raw step_function_arn)" \
  --max-results 5 \
  --profile kitti-ml \
  --region us-east-1
```

## 21. AWS Console Click-a-Click para Todo el Proyecto

Esta seccion es el runbook para alguien que nunca ha usado AWS. La regla de trabajo es: los recursos se crean con Terraform, y la consola se usa para verificar, probar, ver logs y tomar evidencia. Solo se crean manualmente el Budget, el backend de Terraform si no usas CLI, y pruebas puntuales de uploads/ejecuciones.

Todas las pantallas deben estar en region `US East (N. Virginia) us-east-1`.

### 21.1 AWS Console - seleccionar region correcta

1. Abre `https://console.aws.amazon.com/`.
2. Arriba a la derecha, junto a tu nombre de cuenta, busca el selector de region.
3. Haz click en el selector.
4. Escribe `N. Virginia` en el buscador.
5. Haz click en `US East (N. Virginia) us-east-1`.
6. Verificacion visual esperada: arriba a la derecha debe decir `N. Virginia`.

Screenshot descriptivo: deberias ver la barra superior negra de AWS, el buscador al centro, tu cuenta a la derecha y la region mostrando `N. Virginia`.

### 21.2 VS Code - preparar archivos y terminal

1. Abre VS Code.
2. Menu `File > Open Folder`.
3. Selecciona `/home/andresuki/cloudC/definitive_project/cloud-data-ia-project`.
4. Abre terminal integrada con `Terminal > New Terminal`.
5. En la terminal ejecuta:

```bash
pwd
```

6. Debe imprimir:

```text
/home/andresuki/cloudC/definitive_project/cloud-data-ia-project
```

7. En el panel izquierdo deberias ver:

```text
terraform/
src/
data/
scripts/
README.md
```

### 21.3 Billing - crear Budget de 118 USD

1. En AWS Console, en el buscador superior escribe `Billing and Cost Management`.
2. Haz click en `Billing and Cost Management`.
3. En el menu izquierdo haz click en `Budgets`.
4. Haz click en el boton naranja `Create budget`.
5. En `Budget setup`, selecciona `Use a template`.
6. En `Templates`, selecciona `Monthly cost budget`.
7. Campo `Budget name`: escribe `kitti-ml-project-118usd-budget`.
8. Campo `Budgeted amount`: escribe `118`.
9. Campo `Email recipients`: escribe tu correo real.
10. Si aparecen campos de alerta:
    - `Actual cost exceeds 85%`: cambia o agrega `80`.
    - `Forecasted cost exceeds 100%`: deja `100`.
11. Haz click en `Create budget`.
12. Verificacion visual esperada:
    - Vuelves a una tabla de budgets.
    - Debes ver una fila llamada `kitti-ml-project-118usd-budget`.
    - El estado no debe mostrar errores.

### 21.4 S3 - crear/verificar bucket de Terraform state por consola

Si ya lo creaste por CLI, usa esta seccion solo para verificar.

1. En el buscador superior escribe `S3`.
2. Haz click en `S3`.
3. Haz click en `Create bucket`.
4. Campo `Bucket name`: escribe `kitti-terraform-state-${AWS_ACCOUNT_ID}` reemplazando el account id real.
5. Campo `AWS Region`: selecciona `US East (N. Virginia) us-east-1`.
6. Seccion `Object Ownership`: deja `ACLs disabled`.
7. Seccion `Block Public Access settings for this bucket`: deja activadas las 4 casillas.
8. Seccion `Bucket Versioning`: selecciona `Enable`.
9. Seccion `Default encryption`: selecciona `Server-side encryption with Amazon S3 managed keys (SSE-S3)`.
10. Haz click en `Create bucket`.
11. Verificacion visual esperada:
    - Debes volver a la lista de buckets.
    - La tabla debe mostrar `kitti-terraform-state-${AWS_ACCOUNT_ID}`.
12. Haz click en el bucket.
13. Entra a tab `Properties`.
14. Verifica:
    - `Bucket Versioning`: `Enabled`.
    - `Default encryption`: `Amazon S3 managed keys (SSE-S3)`.
15. Entra a tab `Permissions`.
16. Verifica:
    - `Block public access`: `On`.

### 21.5 Terraform apply desde VS Code

1. En VS Code abre `terraform/variables.tf`.
2. Verifica que `notification_email` exista sin default.
3. En terminal integrada ejecuta:

```bash
read -r -p "Email para notificaciones SNS: " NOTIFICATION_EMAIL
printf 'notification_email = "%s"\n' "$NOTIFICATION_EMAIL" > terraform/terraform.tfvars
```

4. Ejecuta:

```bash
export AWS_PROFILE=kitti-ml
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
```

5. Ejecuta:

```bash
cd terraform
terraform init \
  -backend-config="bucket=kitti-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=cloud-data-ia-project/terraform.tfstate" \
  -backend-config="region=us-east-1"
terraform plan
```

6. Verificacion esperada:
    - `terraform init` termina con `Terraform has been successfully initialized`.
    - `terraform plan` muestra recursos a crear y no muestra errores rojos.
7. Ejecuta:

```bash
terraform apply
```

8. Terraform pregunta `Enter a value:`.
9. Escribe `yes`.
10. Verificacion esperada:
    - Final debe decir `Apply complete!`.
    - Debe mostrar outputs como `raw_bucket_uri`, `step_function_arn`, `sns_topic_arn`.

### 21.6 S3 - verificar buckets del proyecto

1. En AWS Console busca `S3`.
2. Entra a `S3`.
3. En la lista de buckets busca:
    - `kitti-ml-project-raw-${AWS_ACCOUNT_ID}`
    - `kitti-ml-project-curated-${AWS_ACCOUNT_ID}`
    - `kitti-ml-project-input-${AWS_ACCOUNT_ID}`
    - `kitti-ml-project-model-artifacts-${AWS_ACCOUNT_ID}`
4. Haz click en `kitti-ml-project-raw-${AWS_ACCOUNT_ID}`.
5. En tab `Objects`, deberias ver una tabla vacia o carpetas si ya subiste datos.
6. En tab `Properties`, verifica:
    - `Bucket Versioning`: `Enabled`.
    - `Default encryption`: `SSE-S3`.
7. En tab `Permissions`, verifica:
    - `Block public access`: `On`.
8. Repite para los otros 3 buckets.

Screenshot descriptivo: deberias ver una tabla de objetos con columnas `Name`, `Type`, `Last modified`, `Size`, `Storage class`. Si no has subido nada, la tabla puede estar vacia.

### 21.7 S3 - subir archivos manualmente por consola para prueba

Para el pipeline real usa `scripts/upload_kitti.py`, pero esta prueba ensena la interfaz.

1. Entra a `S3`.
2. Abre `kitti-ml-project-raw-${AWS_ACCOUNT_ID}`.
3. Haz click en `Create folder`.
4. Folder name: `images`.
5. Haz click en `Create folder`.
6. Haz click en `Create folder`.
7. Folder name: `labels`.
8. Haz click en `Create folder`.
9. Abre folder `images/`.
10. Haz click en `Upload`.
11. Haz click en `Add files`.
12. Selecciona `data/raw/kitti/training/image_2/000000.png`.
13. Haz click en `Upload`.
14. Verificacion visual:
    - Debe aparecer una pantalla con barra de progreso.
    - Al finalizar debe decir `Upload succeeded`.
15. Haz click en `Close`.
16. Regresa al bucket y abre `labels/`.
17. Haz click en `Upload`.
18. Haz click en `Add files`.
19. Selecciona `data/raw/kitti/training/label_2/000000.txt`.
20. Haz click en `Upload`.
21. Verificacion visual:
    - Debe decir `Upload succeeded`.
    - En `labels/` debe aparecer `000000.txt`.

### 21.8 S3 - verificar carga por script

Despues de ejecutar `upload_kitti.py --sample`:

1. Entra a `S3`.
2. Abre `kitti-ml-project-raw-${AWS_ACCOUNT_ID}`.
3. Abre carpeta `images/`.
4. Verificacion esperada:
    - Debes ver alrededor de `100` objetos si usaste `--sample-size 100`.
    - Los nombres deben verse como `000000.png`, `000001.png`.
5. Regresa y abre `labels/`.
6. Verificacion esperada:
    - Debes ver alrededor de `100` objetos `.txt`.
7. Si no ves archivos:
    - Revisa que estas en `us-east-1`.
    - Revisa que el bucket tenga sufijo correcto de account id.
    - Revisa la terminal de VS Code para errores de boto3.

### 21.9 Glue - verificar Database

1. En AWS Console busca `AWS Glue`.
2. Haz click en `AWS Glue`.
3. En el menu izquierdo, abre `Data Catalog`.
4. Haz click en `Databases`.
5. Busca `kitti_catalog`.
6. Verificacion visual esperada:
    - Tabla con columna `Name`.
    - Una fila debe decir `kitti_catalog`.
7. Haz click en `kitti_catalog`.
8. Debes ver detalles del database sin mensaje de error.

### 21.10 Glue - verificar Crawler

1. En AWS Glue, menu izquierdo, haz click en `Crawlers`.
2. Busca `kitti-labels-crawler`.
3. Verificacion visual esperada:
    - Columna `Name`: `kitti-labels-crawler`.
    - Columna `Status`: normalmente `Ready`.
    - Columna `Last run`: vacio si nunca corrio o timestamp si ya corrio.
4. Haz click en el crawler.
5. Verifica campos:
    - Data source: `S3`.
    - S3 path: `s3://kitti-ml-project-raw-${AWS_ACCOUNT_ID}/labels/`.
    - IAM role: `KittiGlueRole`.
    - Target database: `kitti_catalog`.
6. Para correrlo manualmente, haz click en `Run crawler`.
7. Verificacion visual durante ejecucion:
    - Status cambia a `Running`.
8. Espera 1-5 minutos y haz click en el icono de refresh.
9. Verificacion visual final:
    - Status vuelve a `Ready`.
    - Last run debe mostrar `Succeeded` o fecha reciente.
10. Si falla:
    - Entra a tab `Runs`.
    - Abre el run fallido.
    - Copia el error.
    - Revisa permisos de `KittiGlueRole` y que existan archivos en `labels/`.

### 21.11 Glue - verificar ETL Job

1. En AWS Glue, menu izquierdo, haz click en `ETL jobs`.
2. Busca `kitti-clean-labels-job`.
3. Haz click en el job.
4. En tab `Job details`, verifica:
    - IAM Role: `KittiGlueRole`.
    - Type: `Spark`.
    - Glue version: `4.0` o `5.0`.
    - Worker type: `G.1X`.
    - Requested number of workers: `2`.
5. En `Advanced properties` o `Job parameters`, verifica:
    - `--RAW_LABELS_PATH=s3://kitti-ml-project-raw-${AWS_ACCOUNT_ID}/labels/`
    - `--CURATED_OUTPUT_PATH=s3://kitti-ml-project-curated-${AWS_ACCOUNT_ID}/labels_parquet/`
6. Para ejecutar manualmente, haz click en boton `Run`.
7. Ve a tab `Runs`.
8. Verificacion visual durante ejecucion:
    - La fila mas reciente debe estar en estado `Running`, usualmente azul.
9. Espera y presiona refresh.
10. Verificacion visual final:
    - Estado `Succeeded`, usualmente verde.
    - Duration debe tener un valor.
11. Si aparece `Failed`, haz click en el run.
12. Busca `Error logs` o `CloudWatch logs`.

### 21.12 CloudWatch Logs - confirmar Glue

1. En AWS Console busca `CloudWatch`.
2. Haz click en `CloudWatch`.
3. Menu izquierdo: `Logs > Log groups`.
4. En buscador de log groups escribe `/aws-glue/jobs`.
5. Abre `/aws-glue/jobs/output`.
6. Abre el log stream mas reciente.
7. Verificacion esperada en texto:
    - Debes ver mensajes del script.
    - Debes ver algo equivalente a `ProcessedImages`.
    - Debes ver escritura a `labels_parquet`.
8. Regresa a log groups y abre `/aws-glue/jobs/error` si existe.
9. Verificacion esperada:
    - No debe haber stack trace reciente.
    - Si hay error, busca `AccessDenied`, `NoSuchKey`, `AnalysisException` o errores de parseo.

### 21.13 S3 - confirmar Parquet curated

1. Entra a `S3`.
2. Abre `kitti-ml-project-curated-${AWS_ACCOUNT_ID}`.
3. Abre carpeta `labels_parquet/`.
4. Verificacion visual esperada:
    - Debes ver archivos con extension `.parquet` o carpetas `part-...`.
    - Puede aparecer `_SUCCESS`.
5. Haz click en un archivo `part-...parquet`.
6. Verifica:
    - Size mayor a `0 B`.
    - Storage class `Standard`.

### 21.14 SageMaker AI - verificar Training Job

1. En AWS Console busca `SageMaker`.
2. Haz click en `Amazon SageMaker AI`.
3. En el menu izquierdo busca seccion `Training`.
4. Haz click en `Training jobs`.
5. Busca un job con nombre que empiece por `kitti-yolov8-training`.
6. Verificacion visual durante ejecucion:
    - Status `InProgress`, normalmente con color azul.
7. Haz click en el training job.
8. En `Overview` o `Details`, verifica:
    - Training image: PyTorch training image.
    - IAM role: `KittiSageMakerRole`.
    - Input data channel: `dataset`.
    - S3 URI: `s3://kitti-ml-project-curated-${AWS_ACCOUNT_ID}/yolo_dataset/`.
    - Output path: `s3://kitti-ml-project-model-artifacts-${AWS_ACCOUNT_ID}/training-output/`.
    - Instance type: `ml.m5.xlarge` o `ml.g4dn.xlarge`.
9. Espera hasta que status sea `Completed`.
10. Verificacion visual final:
    - En la tabla de Training jobs, la fila debe mostrar `Completed`, usualmente verde.
11. Si status es `Failed`:
    - Haz click en el job.
    - Busca `Failure reason`.
    - Abre logs desde el enlace de CloudWatch.

Screenshot descriptivo: deberias ver una tabla con columnas `Name`, `Status`, `Creation time`, `Training time`. Tu job debe aparecer como `Completed` en verde.

### 21.15 CloudWatch Logs - confirmar SageMaker Training

1. Entra a `CloudWatch`.
2. Menu izquierdo: `Logs > Log groups`.
3. En buscador escribe `/aws/sagemaker/TrainingJobs`.
4. Abre el log group.
5. Abre el stream del job `kitti-yolov8-training...`.
6. Verificacion esperada:
    - Debes ver que instala o carga `ultralytics`.
    - Debes ver salida de YOLOv8.
    - Debes ver epochs avanzando.
    - Debes ver metricas como precision, recall o mAP.
    - No debe aparecer `FileNotFoundError: kitti.yaml`.
    - No debe aparecer `AccessDenied`.

### 21.16 S3 - confirmar artefacto model.tar.gz

1. Entra a `S3`.
2. Abre `kitti-ml-project-model-artifacts-${AWS_ACCOUNT_ID}`.
3. Abre `training-output/`.
4. Abre la carpeta del training job mas reciente.
5. Abre `output/`.
6. Verificacion visual esperada:
    - Debe existir `model.tar.gz`.
    - Size mayor a `0 B`.
7. Haz click en `model.tar.gz`.
8. Copia el `S3 URI`; se usara en SageMaker Model.

### 21.17 SageMaker AI - verificar Model

1. Entra a `Amazon SageMaker AI`.
2. Menu izquierdo: `Inference`.
3. Haz click en `Models`.
4. Busca `kitti-yolov8-model`.
5. Haz click en el modelo.
6. Verifica:
    - Container image: PyTorch inference image.
    - Model data location: S3 URI que termina en `model.tar.gz`.
    - IAM role: `KittiSageMakerRole`.
7. Estado esperado:
    - Los models no tienen un `InService`; solo deben existir sin error.

### 21.18 SageMaker AI - verificar Endpoint Configuration

1. En `Amazon SageMaker AI`, menu izquierdo `Inference`.
2. Haz click en `Endpoint configurations`.
3. Busca `kitti-yolov8-endpoint-config`.
4. Haz click.
5. Verifica:
    - Production variant: `AllTraffic`.
    - Model: `kitti-yolov8-model`.
    - Instance type: `ml.t2.medium`.
    - Initial instance count: `1`.

### 21.19 SageMaker AI - verificar Endpoint

1. En `Amazon SageMaker AI`, menu izquierdo `Inference`.
2. Haz click en `Endpoints`.
3. Busca `kitti-yolov8-endpoint`.
4. Verificacion visual durante creacion:
    - Status `Creating`.
5. Espera 5-15 minutos.
6. Haz click en refresh.
7. Verificacion visual final:
    - Status `InService`, usualmente verde.
8. Haz click en el endpoint.
9. Verifica:
    - Endpoint configuration: `kitti-yolov8-endpoint-config`.
    - Production variants: `AllTraffic`.
    - Current weight: `1`.
10. Si aparece `Failed`:
    - Haz click en endpoint.
    - Copia `Failure reason`.
    - Revisa CloudWatch logs del endpoint.

### 21.20 CloudWatch Logs - confirmar SageMaker Endpoint

1. Entra a `CloudWatch`.
2. Menu izquierdo: `Logs > Log groups`.
3. Busca `/aws/sagemaker/Endpoints/kitti-yolov8-endpoint`.
4. Abre el log group.
5. Abre el log stream mas reciente.
6. Verificacion esperada:
    - Debes ver mensajes de carga del modelo.
    - No debe aparecer `ModuleNotFoundError: ultralytics`.
    - No debe aparecer `ModelError`.
    - Si invocaste el endpoint, debe aparecer log de request o prediccion.

### 21.21 API Gateway - verificar REST API de inferencia

1. En AWS Console busca `API Gateway`.
2. Haz click en `API Gateway`.
3. Entra a `APIs`.
4. Busca `kitti-ml-rest-api`.
5. Haz click en el nombre.
6. En `Resources`, verifica:
    - `/health` con metodo `GET`.
    - `/predict` con metodo `POST`.
    - `/predict` con metodo `OPTIONS` para CORS.
7. Haz click en `/predict` -> `POST`.
8. Verifica:
    - `API Key Required`: `true`.
    - Integration: Lambda proxy hacia `kitti-rest-api-handler`.
9. En el menu de la API, entra a `Stages`.
10. Haz click en `dev`.
11. Copia el `Invoke URL`.
12. Verificacion visual esperada:
    - URL tipo `https://abc123.execute-api.us-east-1.amazonaws.com/dev`.
    - Stage `dev` activo.
13. Menu izquierdo de API Gateway -> `API Keys`.
14. Busca `kitti-ml-rest-api-key`.
15. Verifica que este `Enabled`.
16. Menu izquierdo -> `Usage Plans`.
17. Busca `kitti-ml-rest-api-usage-plan`.
18. Verifica:
    - Quota `1000` por mes.
    - Rate `2`.
    - Burst `5`.

### 21.22 CloudWatch Logs - confirmar API REST

1. Entra a `CloudWatch`.
2. Menu izquierdo: `Logs > Log groups`.
3. Busca `/aws/lambda/kitti-rest-api-handler`.
4. Abre el log group.
5. Abre el stream mas reciente.
6. Despues de llamar `/health`, deberias ver que la Lambda respondio sin error.
7. Despues de llamar `/predict`, verifica:
    - `"event": "api_prediction_completed"`.
    - `"endpoint_name": "kitti-yolov8-endpoint"`.
8. Si ves `api_prediction_failed`, revisa que el endpoint SageMaker este `InService`.

### 21.23 Lambda - verificar inference handler

1. En AWS Console busca `Lambda`.
2. Haz click en `Lambda`.
3. Menu izquierdo: `Functions`.
4. Busca `kitti-inference-handler`.
5. Haz click en la funcion.
6. En tab `Configuration`, haz click en `General configuration`.
7. Verifica:
    - Runtime: `Python 3.11`.
    - Memory: `512 MB`.
    - Timeout: `1 min`.
8. En tab `Configuration`, haz click en `Environment variables`.
9. Verifica:
    - `SAGEMAKER_ENDPOINT_NAME=kitti-yolov8-endpoint`.
    - `SNS_TOPIC_ARN` existe.
    - `DLQ_URL` existe.
10. En tab `Configuration`, haz click en `Permissions`.
11. Haz click en el role `KittiLambdaRole`.
12. En IAM, verifica que existan permisos para S3 input, SageMaker InvokeEndpoint, SNS, SQS y logs.

### 21.24 S3 - verificar trigger de Lambda inference

1. Entra a `S3`.
2. Abre `kitti-ml-project-input-${AWS_ACCOUNT_ID}`.
3. Entra a tab `Properties`.
4. Baja hasta `Event notifications`.
5. Verificacion esperada:
    - Debe existir una notificacion para `s3:ObjectCreated:*`.
    - Prefix: `incoming/`.
    - Destination: Lambda `kitti-inference-handler`.
6. Si no existe:
    - No la crees manualmente primero; revisa Terraform.
    - Si la necesitas para prueba manual, haz click en `Create event notification`.
    - Name: `kitti-input-inference-trigger`.
    - Event types: marca `All object create events`.
    - Prefix: `incoming/`.
    - Destination: `Lambda function`.
    - Lambda function: `kitti-inference-handler`.
    - Haz click en `Save changes`.

### 21.25 Probar inferencia desde S3 Console

1. Entra a `S3`.
2. Abre `kitti-ml-project-input-${AWS_ACCOUNT_ID}`.
3. Haz click en `Create folder`.
4. Folder name: `incoming`.
5. Haz click en `Create folder`.
6. Abre `incoming/`.
7. Haz click en `Upload`.
8. Haz click en `Add files`.
9. Selecciona `data/raw/kitti/training/image_2/000000.png`.
10. Haz click en `Upload`.
11. Verificacion visual:
    - Debe decir `Upload succeeded`.
12. Espera 10-60 segundos.
13. Revisa tu correo.
14. Verificacion esperada:
    - Debe llegar un email de SNS con texto similar a `Detectados: ...`.
15. Si no llega:
    - Confirma suscripcion SNS.
    - Revisa CloudWatch logs de Lambda.
    - Revisa endpoint `InService`.

### 21.26 CloudWatch Logs - confirmar Lambda inference

1. Entra a `CloudWatch`.
2. Menu izquierdo: `Logs > Log groups`.
3. Busca `/aws/lambda/kitti-inference-handler`.
4. Abre el log group.
5. Abre el stream mas reciente.
6. Verificacion esperada:
    - Log JSON con `"event": "inference_completed"`.
    - Bucket debe ser `kitti-ml-project-input-${AWS_ACCOUNT_ID}`.
    - Key debe empezar con `incoming/`.
7. Si falla, busca:
    - `"level": "ERROR"`.
    - `AccessDenied`.
    - `ValidationError`.
    - `Endpoint ... not found`.
    - Timeout.

### 21.27 SNS - confirmar topic y suscripcion email

1. En AWS Console busca `SNS`.
2. Haz click en `Simple Notification Service`.
3. Menu izquierdo: `Topics`.
4. Busca `kitti-detections`.
5. Haz click en el topic.
6. En tab `Subscriptions`, verifica tu email.
7. Estado esperado:
    - `Confirmed`.
8. Si dice `Pending confirmation`:
    - Abre tu correo.
    - Busca email de `AWS Notifications`.
    - Haz click en `Confirm subscription`.
    - Regresa a SNS y presiona refresh.
9. Para prueba manual:
    - En el topic, haz click en `Publish message`.
    - Subject: `Kitti test`.
    - Message body: `Prueba SNS kitti-detections`.
    - Haz click en `Publish message`.
    - Debe llegarte email.

### 21.28 SQS - verificar DLQ

1. En AWS Console busca `SQS`.
2. Haz click en `Simple Queue Service`.
3. Busca `kitti-lambda-dlq`.
4. Haz click en la cola.
5. Verifica:
    - Type: `Standard`.
    - Messages available: normalmente `0`.
6. Para revisar mensajes:
    - Haz click en `Send and receive messages`.
    - Haz click en `Poll for messages`.
7. Si Lambda fallo y envio DLQ:
    - Deberias ver mensajes disponibles.
    - Abre el mensaje para ver payload/error.

### 21.29 Systems Manager - verificar Parameter Store

1. En AWS Console busca `Systems Manager`.
2. Haz click en `Systems Manager`.
3. En el menu izquierdo, baja a `Application Management`.
4. Haz click en `Parameter Store`.
5. En el buscador escribe `/kitti/`.
6. Verificacion visual esperada:
    - Debes ver `/kitti/new-images-count`.
    - Debes ver `/kitti/last-training-date`.
7. Haz click en `/kitti/new-images-count`.
8. Verifica:
    - Type: `String`.
    - Tier: `Standard`.
    - Value: `0` o un numero.
9. Regresa y abre `/kitti/last-training-date`.
10. Verifica:
    - Value: timestamp ISO, por ejemplo `1970-01-01T00:00:00+00:00` o fecha actual.

Screenshot descriptivo: deberias ver una tabla de parametros con columnas `Name`, `Tier`, `Type`, `Last modified date`. Los dos parametros `/kitti/...` deben aparecer como filas.

### 21.30 Lambda - verificar retraining trigger

1. En AWS Console busca `Lambda`.
2. Haz click en `Lambda`.
3. Menu izquierdo: `Functions`.
4. Busca `kitti-retraining-trigger`.
5. Haz click en la funcion.
6. En tab `Configuration`, verifica:
    - Runtime: `Python 3.11`.
    - Memory: `256 MB`.
    - Timeout: `30 sec`.
    - Reserved concurrency: `1`.
7. En `Environment variables`, verifica:
    - `COUNT_PARAM=/kitti/new-images-count`.
    - `LAST_TRAINING_PARAM=/kitti/last-training-date`.
    - `RETRAIN_THRESHOLD=500`.
    - `MIN_DAYS_BETWEEN_RETRAINING=3`.
    - `STATE_MACHINE_ARN` empieza con `arn:aws:states:us-east-1:`.
8. En tab `Code`, verifica que el archivo visible sea `retraining_trigger.py`.

### 21.31 S3 - verificar trigger raw labels hacia retraining Lambda

1. Entra a `S3`.
2. Abre `kitti-ml-project-raw-${AWS_ACCOUNT_ID}`.
3. Entra a tab `Properties`.
4. Baja hasta `Event notifications`.
5. Verificacion esperada:
    - Debe existir una notificacion para `s3:ObjectCreated:*`.
    - Prefix: `labels/`.
    - Suffix: `.txt`.
    - Destination: Lambda `kitti-retraining-trigger`.
6. Si no aparece:
    - Revisa `terraform apply`.
    - Revisa que `aws_lambda_permission.allow_raw_s3_retraining_trigger` exista.

### 21.32 Probar retraining trigger desde consola S3

Prueba controlada sin subir 500 archivos:

1. Entra a `Systems Manager > Parameter Store`.
2. Abre `/kitti/new-images-count`.
3. Haz click en `Edit`.
4. Campo `Value`: escribe `499`.
5. Haz click en `Save changes`.
6. Abre `/kitti/last-training-date`.
7. Haz click en `Edit`.
8. Campo `Value`: escribe `1970-01-01T00:00:00+00:00`.
9. Haz click en `Save changes`.
10. Entra a `S3`.
11. Abre `kitti-ml-project-raw-${AWS_ACCOUNT_ID}`.
12. Abre `images/`.
13. Haz click en `Upload`.
14. Sube `data/raw/kitti/training/image_2/000001.png`, pero antes renombralo localmente a `900001.png` o subelo por CLI para controlar el nombre.
15. Abre `labels/`.
16. Haz click en `Upload`.
17. Sube `data/raw/kitti/training/label_2/000001.txt` renombrado a `900001.txt`.
18. Espera 10-60 segundos.
19. Entra a `Systems Manager > Parameter Store`.
20. Abre `/kitti/new-images-count`.
21. Verificacion esperada:
    - Si el state machine arranco, value debe volver a `0`.
22. Abre `/kitti/last-training-date`.
23. Verificacion esperada:
    - Debe tener fecha/hora UTC actual.
24. Entra a `Step Functions`.
25. Abre `kitti-ml-pipeline`.
26. En tab `Executions`, verifica:
    - Debe aparecer una ejecucion nueva con nombre que empieza por `kitti-retrain-`.

### 21.33 CloudWatch Logs - confirmar retraining trigger

1. Entra a `CloudWatch`.
2. Menu izquierdo: `Logs > Log groups`.
3. Busca `/aws/lambda/kitti-retraining-trigger`.
4. Abre el log group.
5. Abre el stream mas reciente.
6. Verificacion esperada:
    - Log con `"event": "counter_incremented"`.
    - Log con `"event": "retraining_decision"`.
    - Si llego al umbral, log con `"event": "state_machine_started"`.
    - Si disparo pipeline, log con `"event": "counter_reset_after_retraining_start"`.
7. Errores comunes:
    - `AccessDeniedException` en SSM: revisar IAM role.
    - `AccessDeniedException` en Step Functions: revisar permiso `states:StartExecution`.
    - `matching_image_not_found`: subiste label sin imagen correspondiente.

### 21.34 Step Functions - verificar state machine

1. En AWS Console busca `Step Functions`.
2. Haz click en `Step Functions`.
3. Menu izquierdo: `State machines`.
4. Busca `kitti-ml-pipeline`.
5. Haz click en el state machine.
6. Verificacion visual esperada:
    - Debes ver un diagrama visual del workflow.
    - Estados como `StartGlueCrawler`, `RunGlueJob`, `PrepareYOLODataset`, `StartSageMakerTraining`.
7. Haz click en `Start execution`.
8. Campo `Name`: escribe `manual-sample-test`.
9. Campo `Input`: pega:

```json
{
  "mode": "sample",
  "sample_size": 100,
  "trigger": "manual-console"
}
```

10. Haz click en `Start execution`.
11. Verificacion visual durante ejecucion:
    - Debes ver el grafo.
    - Los estados completados se ponen verdes.
    - El estado actual se marca en azul.
12. Verificacion visual final:
    - Banner o status `Succeeded`.
    - Todos los estados del camino exitoso en verde.
13. Si falla:
    - El estado fallido se muestra rojo.
    - Haz click en el estado rojo.
    - Revisa `Input`, `Output`, `Error` y `Cause`.
    - Luego abre CloudWatch logs del servicio que fallo.

Screenshot descriptivo: deberias ver el diagrama de Step Functions con cajas conectadas; en una ejecucion exitosa las cajas del camino principal aparecen en verde y el panel derecho muestra `Succeeded`.

Para ver logs de Step Functions en CloudWatch:

1. Entra a `CloudWatch`.
2. Menu izquierdo: `Logs > Log groups`.
3. Busca `/aws/vendedlogs/states/kitti-ml-pipeline`.
4. Abre el log group.
5. Abre el log stream mas reciente.
6. Verificacion esperada:
    - Debes ver eventos JSON de la ejecucion.
    - Debes ver nombres de estados como `StartGlueCrawler` y `RunGlueJob`.
    - En fallo, busca `ExecutionFailed`, `TaskFailed` o `States.TaskFailed`.

### 21.35 Step Functions - verificar ejecucion disparada por retraining

1. Entra a `Step Functions`.
2. Abre `kitti-ml-pipeline`.
3. Abre tab `Executions`.
4. Busca una ejecucion cuyo nombre empiece por `kitti-retrain-`.
5. Haz click en esa ejecucion.
6. En el panel `Execution input`, verifica:
    - `"trigger": "data-driven-threshold"`.
    - `"new_images_count": 500` o mayor.
    - `"threshold": 500`.
7. Verificacion visual:
    - Si el pipeline sigue corriendo, status `Running`.
    - Si termino bien, status `Succeeded`.
    - Si fallo, status `Failed` y estado rojo.

### 21.36 CloudWatch - verificar custom metrics de Glue

1. Entra a `CloudWatch`.
2. Menu izquierdo: `Metrics > All metrics`.
3. En el buscador escribe `KittiMLProject/DataEngineering`.
4. Haz click en el namespace.
5. Selecciona metricas:
    - `ProcessedImages`.
    - `FailedImages`.
    - `AvgFileSize`.
6. Verificacion visual:
    - Debes ver una grafica.
    - `ProcessedImages` debe ser mayor que `0` despues del Glue job.
    - `FailedImages` idealmente `0`.

### 21.37 CloudWatch - verificar Dashboard

1. Entra a `CloudWatch`.
2. Menu izquierdo: `Dashboards`.
3. Busca `kitti-ml-dashboard`.
4. Haz click en el dashboard.
5. Verificacion visual esperada:
    - Widget Glue duration con linea o puntos.
    - Widget curated object count.
    - Widget SageMaker `ModelLatency` y `Invocation5XXErrors`.
    - Widget Lambda `Invocations`, `Errors`, `Duration`.
    - Widget API Gateway `Count`, `Latency`, `4XXError`, `5XXError`.
    - Widget custom `ProcessedImages`, `FailedImages`.
6. Si un widget aparece vacio:
    - Revisa que hayas ejecutado ese servicio al menos una vez.
    - Cambia el rango de tiempo arriba a la derecha a `Last 3 hours` o `Last 24 hours`.

Screenshot descriptivo: deberias ver una cuadricula de widgets; algunos son line charts y otros numeros. Si no hay actividad reciente, la grafica puede verse plana o vacia.

### 21.38 CloudWatch - verificar alarmas

1. Entra a `CloudWatch`.
2. Menu izquierdo: `Alarms > All alarms`.
3. Busca:
    - `kitti-sagemaker-5xx-rate-high`.
    - `kitti-sagemaker-endpoint-still-running` si la creaste.
4. Verificacion visual esperada:
    - Estado `OK` en verde si no hay errores.
    - `Insufficient data` es aceptable si aun no hay invocaciones.
5. Si aparece `In alarm`:
    - Haz click en la alarma.
    - Revisa grafica y razon.
    - Revisa logs del endpoint o Lambda.

### 21.39 IAM - verificar roles

1. En AWS Console busca `IAM`.
2. Haz click en `IAM`.
3. Menu izquierdo: `Roles`.
4. Busca y abre cada role:
    - `KittiGlueRole`.
    - `KittiSageMakerRole`.
    - `KittiLambdaRole`.
    - `KittiApiLambdaRole`.
    - `KittiStepFunctionsRole`.
    - `KittiRetrainingTriggerRole`.
5. En cada role, abre tab `Permissions`.
6. Verificacion esperada:
    - No debe tener `AdministratorAccess`.
    - Las politicas deben estar limitadas a buckets, parametros, endpoint o state machine del proyecto.
7. En tab `Trust relationships`, verifica:
    - Glue role confia en `glue.amazonaws.com`.
    - SageMaker role confia en `sagemaker.amazonaws.com`.
    - Lambda roles confian en `lambda.amazonaws.com`.
    - Step Functions role confia en `states.amazonaws.com`.

### 21.40 LocalStack - verificar desde navegador y terminal

LocalStack se usa principalmente desde terminal.

1. En VS Code terminal ejecuta:

```bash
bash scripts/setup_localstack.sh
```

2. Verificacion esperada:
    - Debe decir que LocalStack esta listo.
    - `awslocal s3 ls` debe responder sin error.
3. Ejecuta:

```bash
bash scripts/deploy.sh local
```

4. Verificacion esperada:
    - `tflocal init` exitoso.
    - `tflocal apply` exitoso.
5. Si tienes LocalStack Desktop o Web App:
    - Abre la app.
    - Verifica servicios S3, Lambda, SNS, SQS.
6. Nota: no uses LocalStack como prueba final de SageMaker/Glue real; para esos servicios valida en AWS real con sample.

### 21.41 Evidencias para README y entrega

Toma screenshots de estas pantallas:

1. S3 buckets:
    - Lista mostrando los 4 buckets del proyecto.
    - `labels_parquet/` con archivos Parquet.
2. Glue:
    - Crawler `kitti-labels-crawler` con status `Ready` y last run reciente.
    - Job `kitti-clean-labels-job` con run `Succeeded`.
3. SageMaker:
    - Training job `Completed`.
    - Endpoint `InService`.
4. API Gateway:
    - API `kitti-ml-rest-api` con stage `dev`.
    - Prueba `/health` con HTTP `200`.
    - Prueba `/predict` con HTTP `200`.
5. Lambda:
    - `kitti-inference-handler` configuration.
    - `kitti-rest-api-handler` logs con `api_prediction_completed`.
    - `kitti-retraining-trigger` environment variables.
6. Systems Manager:
    - Parametros `/kitti/new-images-count` y `/kitti/last-training-date`.
7. Step Functions:
    - Ejecucion manual `Succeeded`.
    - Ejecucion `kitti-retrain-*` si probaste threshold.
8. CloudWatch:
    - Dashboard `kitti-ml-dashboard`.
    - Logs de Lambda con JSON estructurado.
9. SNS:
    - Topic `kitti-detections` con suscripcion `Confirmed`.

### 21.42 Checklist de diagnostico rapido por falla

Si S3 no dispara Lambda:

1. S3 bucket `Properties > Event notifications`.
2. Lambda `Configuration > Triggers`.
3. Lambda permission creada por Terraform.
4. Bucket y Lambda en misma region `us-east-1`.

Si Glue falla:

1. Ver `CloudWatch > Logs > /aws-glue/jobs/error`.
2. Buscar `AccessDenied` o path S3 incorrecto.
3. Confirmar que `labels/` tiene `.txt`.

Si SageMaker training falla:

1. Ver `Failure reason`.
2. Ver `/aws/sagemaker/TrainingJobs`.
3. Confirmar que `yolo_dataset/kitti.yaml` existe.
4. Confirmar que canal se llama `dataset`.

Si endpoint falla:

1. Ver `/aws/sagemaker/Endpoints/kitti-yolov8-endpoint`.
2. Confirmar `inference.py` dentro del modelo.
3. Cambiar temporalmente a `ml.m5.xlarge` si `ml.t2.medium` no alcanza memoria.

Si API REST falla:

1. `403 Forbidden`: revisar header `x-api-key` y usage plan.
2. `404 Not found`: revisar stage `dev` y path `/predict`.
3. `500 Prediction failed`: revisar endpoint SageMaker `InService`.
4. Ver logs `/aws/lambda/kitti-rest-api-handler`.
5. Confirmar que `KittiApiLambdaRole` permite `sagemaker:InvokeEndpoint`.

Si no llega email:

1. SNS subscription debe estar `Confirmed`.
2. Lambda logs deben mostrar `sns publish`.
3. Revisar spam/correo no deseado.

Si retraining no dispara:

1. SSM `/kitti/new-images-count` debe llegar a `500`.
2. SSM `/kitti/last-training-date` debe ser de hace 3 dias o mas.
3. S3 notification raw debe filtrar `labels/` y `.txt`.
4. CloudWatch logs de `kitti-retraining-trigger` deben mostrar `retraining_decision`.
5. IAM role debe permitir `states:StartExecution`.

## 22. Referencia de Formularios Manuales en AWS Console

Usa esta seccion solo como respaldo educativo o para explicar cada recurso en una demo. El camino oficial del proyecto sigue siendo Terraform. Si creas manualmente recursos que Terraform tambien administra, puedes causar drift; para evitarlo, crea manualmente solo en una cuenta de prueba o borra el recurso manual antes de volver a `terraform apply`.

### 22.1 Crear bucket S3 del proyecto manualmente

Repite estos pasos para raw, curated, input y model-artifacts.

1. AWS Console -> busca `S3` -> click `S3`.
2. Click `Create bucket`.
3. Campo `Bucket name`:
    - raw: `kitti-ml-project-raw-${AWS_ACCOUNT_ID}`
    - curated: `kitti-ml-project-curated-${AWS_ACCOUNT_ID}`
    - input: `kitti-ml-project-input-${AWS_ACCOUNT_ID}`
    - model artifacts: `kitti-ml-project-model-artifacts-${AWS_ACCOUNT_ID}`
4. Campo `AWS Region`: `US East (N. Virginia) us-east-1`.
5. `Object Ownership`: `ACLs disabled`.
6. `Block Public Access`: deja todas las casillas activadas.
7. `Bucket Versioning`: `Enable`.
8. `Tags`:
    - Key `Project`, Value `kitti-ml-project`.
    - Key `Phase`, Value `storage`.
    - Key `ManagedBy`, Value `Terraform`.
9. `Default encryption`: `Server-side encryption with Amazon S3 managed keys (SSE-S3)`.
10. Click `Create bucket`.
11. Verificacion: en la tabla de buckets aparece el bucket. En `Properties`, versioning y encryption aparecen habilitados.

Para lifecycle raw:

1. Abre `kitti-ml-project-raw-${AWS_ACCOUNT_ID}`.
2. Tab `Management`.
3. Seccion `Lifecycle rules`, click `Create lifecycle rule`.
4. `Lifecycle rule name`: `raw-to-glacier-after-90-days`.
5. `Choose a rule scope`: `Apply to all objects in the bucket`.
6. Marca `I acknowledge that this rule will apply to all objects in the bucket`.
7. En `Lifecycle rule actions`, marca `Move current versions of objects between storage classes`.
8. En transition:
    - `Days after object creation`: `90`.
    - `Storage class`: `Glacier Flexible Retrieval`.
9. Marca `Delete expired delete markers or incomplete multipart uploads`.
10. `Number of days`: `7`.
11. Click `Create rule`.
12. Verificacion: regla aparece como `Enabled`.

### 22.2 Crear parametros SSM manualmente

Parametro contador:

1. AWS Console -> busca `Systems Manager` -> click `Systems Manager`.
2. Menu izquierdo -> `Parameter Store`.
3. Click `Create parameter`.
4. `Name`: `/kitti/new-images-count`.
5. `Description`: `Number of newly labeled KITTI images since last retraining`.
6. `Tier`: `Standard`.
7. `Type`: `String`.
8. `Data type`: `text`.
9. `Value`: `0`.
10. Tags:
    - `Project=kitti-ml-project`
    - `Phase=orchestration`
    - `ManagedBy=Terraform`
11. Click `Create parameter`.
12. Verificacion: tabla muestra `/kitti/new-images-count`, Type `String`.

Parametro fecha:

1. Click `Create parameter`.
2. `Name`: `/kitti/last-training-date`.
3. `Description`: `UTC timestamp of the last retraining trigger`.
4. `Tier`: `Standard`.
5. `Type`: `String`.
6. `Data type`: `text`.
7. `Value`: `1970-01-01T00:00:00+00:00`.
8. Click `Create parameter`.
9. Verificacion: tabla muestra `/kitti/last-training-date`.

### 22.3 Crear Glue Database manualmente

1. AWS Console -> busca `AWS Glue` -> click `AWS Glue`.
2. Menu izquierdo -> `Data Catalog` -> `Databases`.
3. Click `Add database` o `Create database`.
4. `Name`: `kitti_catalog`.
5. `Description`: `KITTI object detection catalog`.
6. Click `Create database`.
7. Verificacion: tabla de databases muestra `kitti_catalog`.

### 22.4 Crear Glue Crawler manualmente

1. AWS Console -> `AWS Glue`.
2. Menu izquierdo -> `Crawlers`.
3. Click `Create crawler`.
4. `Name`: `kitti-labels-crawler`.
5. Click `Next`.
6. `Is your data already mapped to Glue tables?`: selecciona `Not yet`.
7. Click `Add a data source`.
8. `Data source`: `S3`.
9. `Location of S3 data`: `In this account`.
10. `S3 path`: `s3://kitti-ml-project-raw-${AWS_ACCOUNT_ID}/labels/`.
11. `Subsequent crawler runs`: `Crawl all sub-folders`.
12. Click `Add an S3 data source`.
13. Click `Next`.
14. `Existing IAM role`: selecciona `KittiGlueRole`.
15. Click `Next`.
16. `Target database`: `kitti_catalog`.
17. `Table name prefix`: `raw_`.
18. `Crawler schedule`: `On demand`.
19. Click `Next`.
20. Revisa resumen y click `Create crawler`.
21. Verificacion: crawler aparece en tabla con status `Ready`.

### 22.5 Crear Glue Job manualmente

1. AWS Console -> `AWS Glue`.
2. Menu izquierdo -> `ETL jobs`.
3. Click `Script editor`.
4. Selecciona `Spark`.
5. Selecciona `Upload and edit an existing script` si ya subiste `clean_data.py`, o `Create a new script` si vas a pegar codigo.
6. Click `Create`.
7. Arriba, campo `Job name`: `kitti-clean-labels-job`.
8. Tab `Job details`.
9. `IAM Role`: `KittiGlueRole`.
10. `Type`: `Spark`.
11. `Glue version`: `Glue 4.0` o `Glue 5.0`.
12. `Language`: `Python 3`.
13. `Worker type`: `G.1X`.
14. `Requested number of workers`: `2`.
15. `Job timeout`: `60`.
16. `Script path`: `s3://kitti-ml-project-model-artifacts-${AWS_ACCOUNT_ID}/glue-scripts/clean_data.py`.
17. `Job parameters`, agrega:
    - Key `--RAW_LABELS_PATH`, Value `s3://kitti-ml-project-raw-${AWS_ACCOUNT_ID}/labels/`.
    - Key `--CURATED_OUTPUT_PATH`, Value `s3://kitti-ml-project-curated-${AWS_ACCOUNT_ID}/labels_parquet/`.
    - Key `--enable-metrics`, Value `true`.
    - Key `--enable-continuous-cloudwatch-log`, Value `true`.
    - Key `--job-language`, Value `python`.
18. Click `Save`.
19. Click `Run`.
20. Verificacion: en tab `Runs`, status pasa de `Running` a `Succeeded`.

### 22.6 Crear Lambdas inference handler y REST API manualmente

1. AWS Console -> busca `Lambda` -> click `Lambda`.
2. Menu izquierdo -> `Functions`.
3. Click `Create function`.
4. Selecciona `Author from scratch`.
5. `Function name`: `kitti-inference-handler`.
6. `Runtime`: `Python 3.11`.
7. `Architecture`: `x86_64`.
8. `Permissions`: selecciona `Use an existing role`.
9. `Existing role`: `KittiLambdaRole`.
10. Click `Create function`.
11. Tab `Code`: sube zip de Lambda o pega codigo si es una prueba simple.
12. Click `Deploy`.
13. Tab `Configuration` -> `General configuration` -> `Edit`:
    - Memory: `512 MB`.
    - Timeout: `1 min 0 sec`.
    - Click `Save`.
14. Tab `Configuration` -> `Environment variables` -> `Edit`:
    - `SAGEMAKER_ENDPOINT_NAME=kitti-yolov8-endpoint`.
    - `SNS_TOPIC_ARN=<arn del topic kitti-detections>`.
    - `DLQ_URL=<url de kitti-lambda-dlq>`.
    - Click `Save`.
15. Click `Add trigger`.
16. `Source`: `S3`.
17. `Bucket`: `kitti-ml-project-input-${AWS_ACCOUNT_ID}`.
18. `Event types`: `All object create events`.
19. `Prefix`: `incoming/`.
20. Marca acknowledgement si aparece.
21. Click `Add`.
22. Verificacion: en el diagrama de Lambda aparece un trigger S3 conectado.

Crear Lambda REST API handler:

1. AWS Console -> `Lambda`.
2. Click `Create function`.
3. `Author from scratch`.
4. `Function name`: `kitti-rest-api-handler`.
5. `Runtime`: `Python 3.11`.
6. `Architecture`: `x86_64`.
7. `Permissions`: `Use an existing role`.
8. `Existing role`: `KittiApiLambdaRole`.
9. Click `Create function`.
10. Tab `Code`: pega `api_handler.py` o sube el zip generado por Terraform.
11. Click `Deploy`.
12. Tab `Configuration` -> `General configuration` -> `Edit`:
    - Memory: `512 MB`.
    - Timeout: `1 min 0 sec`.
    - Click `Save`.
13. Tab `Configuration` -> `Environment variables` -> `Edit`:
    - `SAGEMAKER_ENDPOINT_NAME=kitti-yolov8-endpoint`.
    - `ALLOWED_IMAGE_BUCKETS=kitti-ml-project-input-${AWS_ACCOUNT_ID},kitti-ml-project-raw-${AWS_ACCOUNT_ID}`.
    - `DEFAULT_CONFIDENCE_THRESHOLD=0.7`.
    - `MAX_IMAGE_BYTES=6000000`.
    - `CORS_ORIGIN=*`.
    - Click `Save`.
14. Verificacion: la funcion existe y no necesita trigger directo; API Gateway la invoca.

### 22.7 Crear Lambda retraining trigger manualmente

1. AWS Console -> `Lambda`.
2. Click `Create function`.
3. `Author from scratch`.
4. `Function name`: `kitti-retraining-trigger`.
5. `Runtime`: `Python 3.11`.
6. `Architecture`: `x86_64`.
7. `Permissions`: `Use an existing role`.
8. `Existing role`: `KittiRetrainingTriggerRole`.
9. Click `Create function`.
10. Tab `Code`: pega `retraining_trigger.py`.
11. Click `Deploy`.
12. Tab `Configuration` -> `General configuration` -> `Edit`:
    - Memory: `256 MB`.
    - Timeout: `30 sec`.
    - Click `Save`.
13. Tab `Configuration` -> `Concurrency` -> `Edit`:
    - Selecciona `Reserve concurrency`.
    - Reserved concurrency: `1`.
    - Click `Save`.
14. Tab `Configuration` -> `Environment variables` -> `Edit`:
    - `COUNT_PARAM=/kitti/new-images-count`.
    - `LAST_TRAINING_PARAM=/kitti/last-training-date`.
    - `STATE_MACHINE_ARN=<arn de kitti-ml-pipeline>`.
    - `RETRAIN_THRESHOLD=500`.
    - `MIN_DAYS_BETWEEN_RETRAINING=3`.
    - `IMAGE_PREFIX=images/`.
    - `LABEL_PREFIX=labels/`.
    - `IMAGE_EXTENSION=.png`.
    - Click `Save`.
15. Click `Add trigger`.
16. `Source`: `S3`.
17. `Bucket`: `kitti-ml-project-raw-${AWS_ACCOUNT_ID}`.
18. `Event types`: `All object create events`.
19. `Prefix`: `labels/`.
20. `Suffix`: `.txt`.
21. Marca acknowledgement si aparece.
22. Click `Add`.
23. Verificacion: diagrama de Lambda muestra S3 trigger y no hay banner rojo.

### 22.8 Crear SNS topic y email subscription manualmente

1. AWS Console -> busca `SNS` -> click `Simple Notification Service`.
2. Menu izquierdo -> `Topics`.
3. Click `Create topic`.
4. `Type`: `Standard`.
5. `Name`: `kitti-detections`.
6. Click `Create topic`.
7. En el topic, click `Create subscription`.
8. `Protocol`: `Email`.
9. `Endpoint`: tu correo real.
10. Click `Create subscription`.
11. Abre tu correo y confirma la suscripcion.
12. Verificacion: en tab `Subscriptions`, status `Confirmed`.

### 22.9 Crear SQS DLQ manualmente

1. AWS Console -> busca `SQS` -> click `Simple Queue Service`.
2. Click `Create queue`.
3. `Type`: `Standard`.
4. `Name`: `kitti-lambda-dlq`.
5. `Visibility timeout`: `30 seconds`.
6. `Message retention period`: `14 days`.
7. `Encryption`: deja default o SSE-SQS.
8. Click `Create queue`.
9. Verificacion: cola aparece en tabla con `Messages available = 0`.

### 22.10 Crear SageMaker Training Job manualmente

1. AWS Console -> busca `SageMaker` -> click `Amazon SageMaker AI`.
2. Menu izquierdo -> `Training` -> `Training jobs`.
3. Click `Create training job`.
4. `Training job name`: `kitti-yolov8-training-manual`.
5. `IAM role`: `KittiSageMakerRole`.
6. Seccion de algoritmo:
    - `Algorithm source`: `Your own container`.
    - `Container image`: `763104351884.dkr.ecr.us-east-1.amazonaws.com/pytorch-training:2.6.0-cpu-py312-ubuntu22.04-sagemaker`.
7. `Input mode`: `File`.
8. `Hyperparameters`, agrega:
    - `sagemaker_program`: `train.py`.
    - `sagemaker_submit_directory`: `s3://kitti-ml-project-model-artifacts-${AWS_ACCOUNT_ID}/sagemaker/source/sourcedir.tar.gz`.
    - `epochs`: `5`.
    - `imgsz`: `640`.
    - `batch`: `8`.
9. `Input data configuration`:
    - Click `Add channel`.
    - `Channel name`: `dataset`.
    - `Input mode`: `File`.
    - `S3 data type`: `S3Prefix`.
    - `S3 location`: `s3://kitti-ml-project-curated-${AWS_ACCOUNT_ID}/yolo_dataset/`.
    - `S3 data distribution type`: `FullyReplicated`.
10. `Output data configuration`:
    - `S3 output path`: `s3://kitti-ml-project-model-artifacts-${AWS_ACCOUNT_ID}/training-output/`.
11. `Resource configuration`:
    - `Instance type`: `ml.m5.xlarge`.
    - `Instance count`: `1`.
    - `Volume size`: `50 GB`.
12. `Stopping condition`:
    - `Maximum runtime`: `7200 seconds`.
13. Click `Create training job`.
14. Verificacion: tabla muestra job `InProgress`, luego `Completed`.

### 22.11 Crear SageMaker Model, Endpoint Config y Endpoint manualmente

Crear model:

1. SageMaker AI -> menu izquierdo `Inference` -> `Models`.
2. Click `Create model`.
3. `Model name`: `kitti-yolov8-model`.
4. `IAM role`: `KittiSageMakerRole`.
5. `Container input options`: `Provide model artifacts and inference image location`.
6. `Location of inference code image`: PyTorch inference image URI.
7. `Location of model artifacts`: S3 URI de `model.tar.gz`.
8. Click `Create model`.
9. Verificacion: model aparece en tabla.

Crear endpoint config:

1. SageMaker AI -> `Inference` -> `Endpoint configurations`.
2. Click `Create endpoint configuration`.
3. `Endpoint configuration name`: `kitti-yolov8-endpoint-config`.
4. Click `Add model`.
5. `Model`: `kitti-yolov8-model`.
6. `Variant name`: `AllTraffic`.
7. `Instance type`: `ml.t2.medium`.
8. `Initial instance count`: `1`.
9. `Initial variant weight`: `1`.
10. Click `Create endpoint configuration`.
11. Verificacion: config aparece en tabla.

Crear endpoint:

1. SageMaker AI -> `Inference` -> `Endpoints`.
2. Click `Create endpoint`.
3. `Endpoint name`: `kitti-yolov8-endpoint`.
4. `Attach endpoint configuration`: selecciona `Use an existing endpoint configuration`.
5. `Endpoint configuration`: `kitti-yolov8-endpoint-config`.
6. Click `Create endpoint`.
7. Verificacion: endpoint pasa de `Creating` a `InService`.

### 22.12 Crear API Gateway REST API manualmente

Crear API:

1. AWS Console -> busca `API Gateway` -> click `API Gateway`.
2. Click `Create API`.
3. En tarjeta `REST API`, click `Build`.
4. `Choose the protocol`: `REST`.
5. `Create new API`: `New API`.
6. `API name`: `kitti-ml-rest-api`.
7. `Description`: `REST API for KITTI YOLOv8 SageMaker inference`.
8. `Endpoint Type`: `Regional`.
9. Click `Create API`.
10. Verificacion: se abre pantalla `Resources` con el recurso raiz `/`.

Crear `/health`:

1. En `Resources`, selecciona `/`.
2. Click `Actions` -> `Create Resource`.
3. `Resource Name`: `health`.
4. `Resource Path`: debe quedar `/health`.
5. Click `Create Resource`.
6. Selecciona `/health`.
7. Click `Actions` -> `Create Method`.
8. Selecciona `GET` y confirma con la palomita.
9. `Integration type`: `Lambda Function`.
10. Marca `Use Lambda Proxy integration`.
11. `Lambda Region`: `us-east-1`.
12. `Lambda Function`: `kitti-rest-api-handler`.
13. Click `Save`.
14. Acepta el permiso para invocar Lambda si aparece.

Crear `/predict`:

1. Selecciona `/`.
2. Click `Actions` -> `Create Resource`.
3. `Resource Name`: `predict`.
4. Click `Create Resource`.
5. Selecciona `/predict`.
6. Click `Actions` -> `Create Method`.
7. Selecciona `POST` y confirma.
8. `Integration type`: `Lambda Function`.
9. Marca `Use Lambda Proxy integration`.
10. `Lambda Region`: `us-east-1`.
11. `Lambda Function`: `kitti-rest-api-handler`.
12. Click `Save`.
13. En `Method Request`, cambia `API Key Required` a `true`.
14. Verificacion: `/predict` debe mostrar metodo `POST`.

Crear `OPTIONS` para CORS en `/predict`:

1. Selecciona `/predict`.
2. Click `Actions` -> `Create Method`.
3. Selecciona `OPTIONS` y confirma.
4. `Integration type`: `Mock`.
5. Click `Save`.
6. En `Method Response`, agrega status `200` si no existe.
7. En response headers agrega:
    - `Access-Control-Allow-Headers`
    - `Access-Control-Allow-Methods`
    - `Access-Control-Allow-Origin`
8. En `Integration Response`, status `200`, agrega valores:
    - `Access-Control-Allow-Headers`: `'Content-Type,x-api-key'`
    - `Access-Control-Allow-Methods`: `'POST,OPTIONS'`
    - `Access-Control-Allow-Origin`: `'*'`
9. Verificacion: `/predict` muestra metodos `POST` y `OPTIONS`.

Configurar binary media types:

1. En el menu izquierdo de la API, click `Settings`.
2. En `Binary Media Types`, agrega:
    - `image/png`
    - `image/jpeg`
    - `application/octet-stream`
3. Click `Save Changes`.

Deploy:

1. En `Resources`, click `Actions` -> `Deploy API`.
2. `Deployment stage`: `New Stage`.
3. `Stage name`: `dev`.
4. Click `Deploy`.
5. Verificacion: pantalla `Stages` muestra `dev` y un `Invoke URL`.

Crear API key y usage plan:

1. Menu izquierdo principal de API Gateway -> `API Keys`.
2. Click `Create API key`.
3. `Name`: `kitti-ml-rest-api-key`.
4. `Enabled`: activo.
5. Click `Save`.
6. Menu izquierdo -> `Usage Plans`.
7. Click `Create`.
8. `Name`: `kitti-ml-rest-api-usage-plan`.
9. `Enable throttling`: activo.
10. `Rate`: `2`.
11. `Burst`: `5`.
12. `Enable quota`: activo.
13. `Requests`: `1000`.
14. `Period`: `Month`.
15. Click `Next`.
16. `Add API Stage`: API `kitti-ml-rest-api`, Stage `dev`.
17. Click la palomita o `Add to Usage Plan`.
18. Click `Next`.
19. `Add API Key to Usage Plan`: selecciona `kitti-ml-rest-api-key`.
20. Click `Done`.
21. Verificacion: usage plan muestra API stage `dev` y API key asociada.

### 22.13 Crear Step Functions State Machine manualmente

1. AWS Console -> busca `Step Functions` -> click `Step Functions`.
2. Menu izquierdo -> `State machines`.
3. Click `Create state machine`.
4. Selecciona `Write your workflow in code`.
5. `Type`: `Standard`.
6. En editor, pega el contenido de `src/step_functions/workflow.json`.
7. Click `Next`.
8. `State machine name`: `kitti-ml-pipeline`.
9. `Permissions`: selecciona `Choose an existing role`.
10. `Existing role`: `KittiStepFunctionsRole`.
11. `Logging`:
    - Log level: `ALL`.
    - Include execution data: activado.
    - CloudWatch log group: `/aws/vendedlogs/states/kitti-ml-pipeline`.
12. Click `Create state machine`.
13. Verificacion: se abre el diagrama del workflow sin errores de definicion.

### 22.14 Crear CloudWatch Dashboard manualmente

1. AWS Console -> busca `CloudWatch` -> click `CloudWatch`.
2. Menu izquierdo -> `Dashboards`.
3. Click `Create dashboard`.
4. `Dashboard name`: `kitti-ml-dashboard`.
5. Click `Create dashboard`.
6. Widget Glue:
    - Tipo: `Line`.
    - Metrics: busca `Glue`.
    - Selecciona `glue.driver.ExecutorRunTime` para `kitti-clean-labels-job`.
    - Click `Create widget`.
7. Widget S3 custom:
    - Click `Add widget`.
    - Tipo: `Number`.
    - Metrics: namespace `KittiMLProject/Storage`.
    - Metric: `CuratedObjectCount`.
8. Widget SageMaker:
    - Tipo: `Line`.
    - Namespace: `AWS/SageMaker`.
    - Metrics: `ModelLatency`, `Invocation5XXErrors`.
    - Dimension EndpointName: `kitti-yolov8-endpoint`.
9. Widget Lambda:
    - Tipo: `Line`.
    - Namespace: `AWS/Lambda`.
    - FunctionName: `kitti-inference-handler`.
    - Metrics: `Invocations`, `Errors`, `Duration`.
10. Widget API Gateway:
    - Tipo: `Line`.
    - Namespace: `AWS/ApiGateway`.
    - API Name: `kitti-ml-rest-api`.
    - Stage: `dev`.
    - Metrics: `Count`, `Latency`, `4XXError`, `5XXError`.
11. Widget Glue custom:
    - Tipo: `Line`.
    - Namespace: `KittiMLProject/DataEngineering`.
    - Metrics: `ProcessedImages`, `FailedImages`.
12. Click `Save dashboard`.
13. Verificacion: dashboard muestra 6 widgets en una cuadricula.

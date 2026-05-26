# 🎯 PROMPT PARA PLANEACIÓN COMPLETA: ARQUITECTURA ML EN AWS CON KITTI + YOLOv8

---

> **Instrucciones para la IA:** Eres un arquitecto de soluciones ML en AWS y un ingeniero MLOps senior. Tu tarea es darme una **guía paso a paso, completísima, específica y ejecutable** para implementar el siguiente proyecto de principio a fin. Quiero que pueda leer esto y ejecutarlo todo **de un jalón**, sin necesidad de pedirte más información. Incluye comandos reales, código real, nombres de recursos concretos, configuraciones específicas y cualquier detalle relevante. No uses placeholders vagos; cuando necesites un nombre de recurso, ponlo tú. Cuando necesites un script, escríbelo completo. Si hay decisiones de arquitectura, tómalas tú con la mejor opción y explica brevemente por qué.

---

## 🧠 CONTEXTO DEL PROYECTO

Estoy construyendo una **arquitectura MLOps end-to-end en AWS** como proyecto final de una materia de Infraestructura como Código (IaC). Este proyecto también lo usaré como **pieza de portafolio profesional** para CV y LinkedIn, así que debe estar bien documentado, usar buenas prácticas reales de la industria y ser visualmente comprensible en un README.

**Dataset:** [KITTI Vision Benchmark Suite](http://www.cvlibs.net/datasets/kitti/) — específicamente el subset de **Object Detection 2D** (imágenes + labels de bounding boxes para coches, peatones, ciclistas).

**Modelo:** YOLOv8 (de Ultralytics) para detección de objetos.

**Presupuesto disponible:** ~118 USD en créditos AWS (Free Tier + créditos educativos). El objetivo es **no gastar más de eso**. Incluye advertencias específicas en cada fase cuando algo puede generar costo y cuánto aproximadamente.

**IaC:** Terraform + LocalStack para desarrollo local antes de desplegar en AWS real.

---

## 📁 ESTRUCTURA DEL PROYECTO

El proyecto debe seguir exactamente esta estructura de carpetas. Crea todos los archivos con su contenido real:

```
/cloud-data-ia-project
│
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── modules/
│       ├── storage/          # S3 buckets: raw, curated, input, model-artifacts
│       ├── data-eng/         # Glue Crawler, Jobs, Catalog
│       ├── ai-inference/     # SageMaker Endpoint + Lambda
│       ├── orchestration/    # Step Functions
│       └── observability/    # CloudWatch Alarms, Dashboard, SNS
│
├── src/
│   ├── glue/
│   │   └── clean_data.py     # PySpark: convierte KITTI labels a Parquet
│   ├── lambda/
│   │   └── handler.py        # Trigger de inferencia + SNS
│   └── step_functions/
│       └── workflow.json     # ASL del state machine
│
├── data/
│   ├── raw/                  # Muestra local KITTI (pocas imágenes para pruebas)
│   └── reference/            # Schema Parquet esperado
│
├── scripts/
│   ├── setup_localstack.sh
│   ├── deploy.sh
│   └── upload_kitti.py       # Script para subir KITTI a S3
│
└── README.md
```

---

## 🗂️ FASE A — DATA ENGINEERING (KITTI + Glue)

### Contexto
El dataset KITTI de detección 2D contiene:
- Carpeta `image_2/`: imágenes `.png` (≈7,500 imágenes de entrenamiento, ~12 GB)
- Carpeta `label_2/`: archivos `.txt` con anotaciones en formato KITTI
  - Formato por línea: `Clase truncated occluded alpha x1 y1 x2 y2 h w l x y z ry`
  - Clases relevantes: `Car`, `Pedestrian`, `Cyclist`, `Van`, `Truck`

### Lo que quiero que me expliques y generes en esta fase:

**A1. Descarga y preparación local del dataset**
- Explícame exactamente cómo descargar solo el subset necesario del KITTI (solo 2D object detection, no el dataset completo de 80GB)
- Comando exacto para descargar desde el sitio oficial o mirror
- Cómo organizar los archivos localmente antes de subirlos
- Cuánto espacio ocupa y cuánto tiempo tarda la descarga

**A2. Script `upload_kitti.py`**
- Script Python completo para subir el dataset a S3 raw bucket
- Debe subir imágenes a `s3://kitti-ml-project-raw/images/` y labels a `s3://kitti-ml-project-raw/labels/`
- Usar boto3 con multipart upload para archivos grandes
- Mostrar barra de progreso con `tqdm`
- Manejar reintentos automáticos
- Incluir un flag `--sample` para subir solo 100 imágenes (para pruebas baratas)
- ⚠️ Incluir advertencia de costo: cuánto cuesta almacenar ~12GB en S3

**A3. Módulo Terraform `storage/`**
- `main.tf` completo con:
  - `kitti-ml-project-raw` (S3, versionado, lifecycle policy: mover a Glacier a 90 días)
  - `kitti-ml-project-curated` (S3, Parquet output)
  - `kitti-ml-project-input` (S3, para nuevas imágenes en inferencia)
  - `kitti-ml-project-model-artifacts` (S3, para guardar pesos YOLOv8)
- Etiquetas (`tags`) en todos los recursos con `Project`, `Phase`, `ManagedBy=Terraform`

**A4. Módulo Terraform `data-eng/`**
- Glue Crawler apuntando a `s3://kitti-ml-project-raw/labels/`
- Glue Database: `kitti_catalog`
- IAM Role para Glue con políticas mínimas necesarias
- Glue Job que ejecuta `clean_data.py`

**A5. Script PySpark `clean_data.py`**
- Lee los `.txt` de KITTI labels desde S3 raw
- Parsea cada línea y crea un DataFrame con columnas nombradas correctamente:
  `[image_id, class_name, truncated, occluded, alpha, x1, y1, x2, y2, height, width, length, x, y, z, rotation_y]`
- Filtra clases irrelevantes (`DontCare`, `Misc`)
- Calcula columnas adicionales útiles para YOLOv8:
  - `bbox_width = x2 - x1`
  - `bbox_height = y2 - y1`
  - `bbox_area = bbox_width * bbox_height`
  - `center_x`, `center_y` normalizados (formato YOLO)
- Escribe el resultado como Parquet en `s3://kitti-ml-project-curated/labels_parquet/`
- Emite métricas a CloudWatch: `ProcessedImages`, `FailedImages`, `AvgFileSize`

---

## 🤖 FASE B — AI & INFERENCIA (YOLOv8 + SageMaker)

### Contexto
YOLOv8 de Ultralytics se puede usar en SageMaker de varias formas. La más práctica para este presupuesto es usar un **Script Mode con contenedor PyTorch nativo de AWS** para entrenamiento, y un **endpoint de inferencia en tiempo real** para predicciones.

### Lo que quiero que me expliques y generes en esta fase:

**B1. Preparación del dataset para YOLOv8 en SageMaker**
- YOLOv8 espera un formato específico de datos: explica exactamente cómo convertir KITTI al formato YOLO
- Estructura de carpetas esperada por Ultralytics:
  ```
  dataset/
  ├── images/train/   *.jpg
  ├── images/val/
  ├── labels/train/   *.txt  (formato YOLO: class cx cy w h normalizados)
  └── labels/val/
  ```
- Script Python completo `prepare_yolo_dataset.py` que:
  - Lee el Parquet curated de S3
  - Convierte a formato YOLO
  - Divide 80/20 train/val
  - Sube todo a `s3://kitti-ml-project-curated/yolo_dataset/`
  - Genera el archivo `kitti.yaml` que YOLOv8 necesita
- Explica por qué SageMaker necesita los datos en S3 en canales específicos y cómo configurar esos canales en Terraform

**B2. Script de entrenamiento YOLOv8 para SageMaker (`train.py`)**
- Script completo compatible con SageMaker Script Mode
- Usa `ultralytics` YOLOv8n (nano) como base — explica por qué nano es la elección correcta para este presupuesto
- Recibe hiperparámetros via `argparse` (epochs, imgsz, batch)
- Lee datos desde `/opt/ml/input/data/train/`
- Guarda el modelo entrenado en `/opt/ml/model/`
- Fine-tuning desde `yolov8n.pt` preentrenado en COCO (transfer learning)
- ⚠️ Advertencia de costo: qué instancia usar (`ml.m5.xlarge` vs `ml.g4dn.xlarge`) y cuánto cuesta cada una por hora

**B3. Módulo Terraform `ai-inference/`**
- `aws_sagemaker_training_job` resource completo
- `aws_sagemaker_model` con el artefacto del modelo
- `aws_sagemaker_endpoint_configuration` — usa `ml.t2.medium` (la más barata posible)
- `aws_sagemaker_endpoint` — endpoint real
- IAM Role para SageMaker
- ⚠️ Advertencia: el endpoint cobra por hora aunque no reciba peticiones — incluye instrucción para destruirlo cuando no se use

**B4. Lambda `handler.py`**
- Lee el evento S3 (nueva imagen subida a `kitti-ml-project-input`)
- Descarga la imagen desde S3 a `/tmp/`
- Hace `invoke_endpoint` al SageMaker endpoint con la imagen como payload
- Parsea la respuesta JSON con las detecciones
- Construye un mensaje legible: "Detectados: 3 Cars, 1 Pedestrian con confianza >0.7"
- Publica en SNS topic `kitti-detections`
- En caso de falla → envía a SQS DLQ `kitti-lambda-dlq`
- Incluye logging estructurado con `json.dumps` para CloudWatch

**B5. Módulo Terraform `ai-inference/` (Lambda + SQS)**
- `aws_lambda_function` con la función
- `aws_s3_bucket_notification` para el trigger en el bucket input
- `aws_sqs_queue` para DLQ
- `aws_sns_topic` `kitti-detections`
- Suscripción SNS → Email (variable `var.notification_email`)

---

## ⚙️ ORQUESTACIÓN — Step Functions

### Lo que quiero que me expliques y generes:

**O1. `workflow.json` (ASL completo)**
- State machine con estos estados:
  1. `StartGlueCrawler` — inicia el Glue Crawler
  2. `WaitForCrawler` — polling loop cada 30s hasta que termine
  3. `RunGlueJob` — ejecuta el Glue Job PySpark
  4. `CheckGlueJobStatus` — polling hasta completar
  5. `PrepareYOLODataset` — invoca Lambda que corre `prepare_yolo_dataset.py`
  6. `StartSageMakerTraining` — lanza el training job
  7. `WaitForTraining` — polling hasta completar
  8. `UpdateSageMakerEndpoint` — despliega el nuevo modelo al endpoint
  9. `NotifySuccess` — publica en SNS que el pipeline terminó
- Manejo de errores con `Catch` en cada estado crítico

**O2. Módulo Terraform `orchestration/`**
- `aws_sfn_state_machine` con el ASL del JSON
- IAM Role con permisos para invocar Glue, SageMaker, Lambda, SNS

---

## 📊 FASE C — OBSERVABILIDAD (CloudWatch + SNS)

### Lo que quiero que me expliques y generes:

**C1. Módulo Terraform `observability/`**
- CloudWatch Dashboard `kitti-ml-dashboard` con:
  - **Widget 1**: Gráfico de líneas — duración de los Glue Jobs (`glue.driver.ExecutorRunTime`)
  - **Widget 2**: Contador numérico — objetos en `s3://kitti-ml-project-curated/` (métrica custom)
  - **Widget 3**: Tasa de error del SageMaker Endpoint (`ModelLatency`, `Invocation5XXErrors`)
  - **Widget 4**: Número de invocaciones Lambda (`Invocations`, `Errors`, `Duration`)
  - **Widget 5**: Métricas custom del Glue Job: `ProcessedImages`, `FailedImages`
- CloudWatch Alarm: si `Invocation5XXErrors` del endpoint supera 5% → SNS alert crítico
- CloudWatch Log Groups para Lambda con retención de 7 días

**C2. Métricas custom desde PySpark**
- Cómo emitir métricas custom desde el Glue Job usando `boto3.put_metric_data`
- Namespace: `KittiMLProject/DataEngineering`

---

## 🛠️ CONFIGURACIÓN TERRAFORM RAÍZ

**main.tf, variables.tf, outputs.tf completos:**
- Provider AWS con región `us-east-1`
- Backend S3 para el estado de Terraform (bucket `kitti-terraform-state`)
- Todas las variables con defaults sensatos y descripciones
- Outputs: ARNs del endpoint, URLs de los buckets, ARN del state machine

---

## 🔐 IAM — Roles y Políticas

Para cada servicio, dame el IAM Role con **least privilege** real:
- `KittiGlueRole` — solo S3 read/write en buckets específicos + CloudWatch logs
- `KittiSageMakerRole` — S3 model artifacts + ECR + CloudWatch
- `KittiLambdaRole` — S3 read input bucket + SageMaker invoke + SNS publish + SQS send + CloudWatch logs
- `KittiStepFunctionsRole` — Glue start + SageMaker training + Lambda invoke + SNS

---

## 💻 DESARROLLO LOCAL CON LOCALSTACK

**`setup_localstack.sh` completo:**
- Instala LocalStack Pro (o Community si el free tier alcanza)
- Configura las variables de entorno necesarias
- Inicia LocalStack con los servicios requeridos: S3, Glue, Lambda, SageMaker (mock), SNS, SQS, IAM, Step Functions, CloudWatch
- Verifica que todos los servicios respondan

**`deploy.sh` completo:**
- Detecta si estás en modo local (LocalStack) o AWS real
- Corre `tflocal init && tflocal apply` para local
- Corre `terraform init && terraform apply` para AWS real
- Incluye confirmación antes de aplicar en AWS real

---

## 💰 GESTIÓN DEL PRESUPUESTO — 118 USD

Dame una tabla detallada con:

| Servicio | Uso estimado | Costo/mes aprox | Notas |
|---|---|---|---|
| S3 | 12GB raw + 2GB curated | ~$0.30/mes | ... |
| Glue Job | X DPUs x Y horas | ~$Z | ... |
| SageMaker Training | ml.m5.xlarge x N horas | ~$Z | ... |
| SageMaker Endpoint | ml.t2.medium x horas activo | ~$Z/hora | ⚠️ APAGAR cuando no uses |
| Lambda | Invocaciones | Gratis (free tier) | ... |
| Step Functions | Transiciones de estado | ~$0 | ... |
| CloudWatch | Métricas + logs | ~$Z | ... |
| **TOTAL ESTIMADO** | | **~$Z** | |

- Explica **exactamente en qué momento empieza a cobrar cada servicio** (no al crear el recurso, sino al usarlo activamente)
- Da el comando exacto para destruir los recursos más costosos cuando no se usen:
  ```bash
  terraform destroy -target=module.ai-inference.aws_sagemaker_endpoint.kitti_endpoint
  ```
- Estrategia para hacer todo el desarrollo/pruebas en LocalStack y solo subir a AWS real para la demo final

---

## 📦 CARGA DEL DATASET A SAGEMAKER — Paso a Paso Detallado

Esta sección es crítica. Explica exactamente:

1. **Cómo descargar KITTI** (solo los archivos necesarios, ~6GB en lugar de 80GB)
   - URL directa de descarga
   - Comando `wget` o `curl` específico

2. **Cómo convertir y organizar** para YOLOv8 localmente antes de subir

3. **Cómo subir a S3** usando `upload_kitti.py` con la opción `--sample` primero para verificar el pipeline

4. **Cómo referenciar los datos en el Training Job de SageMaker**:
   ```python
   estimator.fit({
       'train': 's3://kitti-ml-project-curated/yolo_dataset/train/',
       'val': 's3://kitti-ml-project-curated/yolo_dataset/val/'
   })
   ```

5. **Cómo verificar que SageMaker accedió correctamente** a los datos (logs de CloudWatch del training job)

6. **Cómo guardar y registrar el modelo** en S3 después del entrenamiento para que el Endpoint lo use

---

## 📝 README.md

Genera un README.md profesional para GitHub que incluya:
- Badge de "Built with Terraform", "YOLOv8", "AWS SageMaker"
- Diagrama ASCII de la arquitectura completa
- Sección "Quick Start" con los comandos exactos para reproducir el proyecto
- Sección de resultados esperados (métricas de detección, mAP estimado)
- Sección "Architecture Decisions" explicando por qué cada servicio
- Sección "Cost Optimization" resumiendo las estrategias usadas

---

## ✅ ORDEN DE EJECUCIÓN — Checklist Final

Dame un checklist numerado y ordenado de TODOS los pasos desde cero hasta el proyecto funcionando en AWS, incluyendo prerrequisitos (instalar Terraform, AWS CLI, Python, etc.) y el orden exacto en que debo ejecutar cada script y cada `terraform apply`.
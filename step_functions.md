# Step Functions - Guia de estudio para la exposicion

Este documento explica todo lo relacionado con AWS Step Functions dentro del
proyecto `cloud-data-ia-project`. Esta pensado para estudiar, exponer y poder
responder preguntas sobre la orquestacion del pipeline MLOps.

## 1. Idea principal para decir en la exposicion

AWS Step Functions es el servicio que orquesta el pipeline. En este proyecto no
se usa solo un script largo para ejecutar todo, sino una maquina de estados
visual y auditable llamada `kitti-ml-pipeline`.

Step Functions conecta estos servicios:

```text
Glue Crawler
Glue Job
Lambda
SageMaker Training
SageMaker Model
SageMaker Endpoint Config
SageMaker Endpoint
SNS
CloudWatch Logs
```

Frase corta:

> Step Functions es el coordinador del pipeline MLOps. Ejecuta el crawler,
> espera a Glue, valida el dataset YOLO, lanza el entrenamiento en SageMaker,
> publica resultados, actualiza el endpoint si corresponde y manda
> notificaciones por SNS.

## 2. Que es Step Functions

AWS Step Functions permite crear flujos de trabajo como maquinas de estados.
Cada estado representa una accion, una espera, una decision o un final.

Conceptos clave:

- `State machine`: definicion completa del flujo. En este proyecto se llama
  `kitti-ml-pipeline`.
- `State`: cada paso individual, por ejemplo `StartGlueCrawler` o
  `StartSageMakerTraining`.
- `Task`: estado que ejecuta una accion en otro servicio, como Lambda, Glue o
  SageMaker.
- `Wait`: estado que espera cierto tiempo.
- `Choice`: estado que toma decisiones segun datos del JSON de ejecucion.
- `Pass`: estado que transforma o construye datos sin llamar servicios.
- `Catch`: manejo de errores. Si falla un estado, redirige la ejecucion.
- `ResultPath`: indica donde guardar la salida de un estado dentro del JSON.
- `Parameters`: define que datos se envian al servicio llamado.
- `Execution`: una corrida concreta de la state machine.

## 3. Donde vive en el proyecto

Archivo principal del workflow:

```text
cloud-data-ia-project/src/step_functions/workflow.json
```

Modulo Terraform que lo crea:

```text
cloud-data-ia-project/terraform/modules/orchestration/
```

Recurso Terraform principal:

```hcl
resource "aws_sfn_state_machine" "kitti_pipeline" {
  name     = "kitti-ml-pipeline"
  role_arn = aws_iam_role.step_functions_role.arn
  type     = "STANDARD"

  definition = templatefile("${path.root}/../src/step_functions/workflow.json", {
    ...
  })
}
```

Como explicarlo:

> El flujo esta escrito en JSON usando Amazon States Language. Terraform lo lee
> con `templatefile`, reemplaza variables como ARNs, nombres de jobs y rutas S3,
> y crea la state machine en AWS.

## 4. Por que es tipo STANDARD

La state machine usa:

```hcl
type = "STANDARD"
```

Esto es adecuado porque el pipeline puede tardar mucho:

- Glue puede tardar varios minutos.
- SageMaker training puede tardar horas.
- El flujo necesita historial de ejecucion.
- Conviene poder ver cada estado en la consola.

Step Functions tambien tiene modo Express, pero Express es mejor para flujos de
alta frecuencia y corta duracion. Aqui se usa `STANDARD` porque el pipeline de
ML es largo, auditable y no se ejecuta miles de veces por segundo.

## 5. Arquitectura del flujo

Diagrama general:

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
       | true
       v
     CreateSageMakerModel
       -> CreateEndpointConfig
       -> UpdateSageMakerEndpoint
       -> NotifySuccess

       | false
       v
     NotifySuccess

Si falla un estado critico:
  -> NotifyFailure
```

En palabras simples:

1. Cataloga etiquetas crudas con Glue Crawler.
2. Espera a que el crawler termine.
3. Ejecuta Glue Job para limpiar datos.
4. Valida que el dataset YOLO exista.
5. Genera nombres unicos para entrenamiento y despliegue.
6. Entrena YOLOv8 en SageMaker.
7. Extrae y publica resultados del entrenamiento.
8. Decide si actualiza el endpoint de inferencia.
9. Notifica exito o falla por SNS.

## 6. Servicios que Step Functions controla

Step Functions llama servicios sin que tengamos que escribir un script
orquestador manual. En `workflow.json` se usan integraciones directas:

```text
arn:aws:states:::aws-sdk:glue:startCrawler
arn:aws:states:::aws-sdk:glue:getCrawler
arn:aws:states:::glue:startJobRun.sync
arn:aws:states:::lambda:invoke
arn:aws:states:::sagemaker:createTrainingJob.sync
arn:aws:states:::aws-sdk:sagemaker:createModel
arn:aws:states:::aws-sdk:sagemaker:createEndpointConfig
arn:aws:states:::aws-sdk:sagemaker:updateEndpoint
arn:aws:states:::sns:publish
```

Detalle importante:

- Las integraciones con `.sync` hacen que Step Functions espere a que termine
  el servicio llamado.
- `glue:startJobRun.sync` espera a que termine el Glue Job.
- `sagemaker:createTrainingJob.sync` espera a que termine el training job.

## 7. Variables que Terraform inyecta al workflow

El archivo `workflow.json` no tiene valores fijos para todo. Tiene placeholders
como:

```text
${glue_job_name}
${prepare_yolo_lambda_arn}
${training_image}
${sagemaker_role_arn}
${sns_topic_arn}
```

Terraform los reemplaza desde `templatefile`.

Valores importantes:

```text
aws_region
dataset_uri
endpoint_instance_type
glue_crawler_name
glue_job_name
inference_image
prepare_yolo_lambda_arn
sagemaker_endpoint_name
sagemaker_role_arn
sagemaker_source_uri
sns_topic_arn
mode
epochs
training_image_size
training_batch_size
yolo_model
training_max_runtime_seconds
training_image
training_instance_type
training_results_lambda_arn
training_output_uri
```

Como explicarlo:

> El JSON del workflow es una plantilla. Terraform le inyecta los nombres y
> ARNs reales de los recursos que tambien fueron creados como infraestructura.

## 8. Estado por estado

Esta es la parte mas importante para la exposicion.

### 8.1 StartGlueCrawler

Tipo:

```text
Task
```

Resource:

```text
arn:aws:states:::aws-sdk:glue:startCrawler
```

Que hace:

Inicia el crawler de Glue llamado:

```text
kitti-labels-crawler
```

Ese crawler revisa las etiquetas crudas en:

```text
s3://<raw-bucket>/labels/
```

Salida:

```json
"ResultPath": "$.crawler_start"
```

Eso guarda el resultado en el campo `crawler_start` del JSON de ejecucion.

Como explicarlo:

> El primer paso es catalogar las etiquetas crudas. Step Functions inicia el
> crawler, pero no asume que termino inmediatamente; por eso despues entra en
> una espera y consulta el estado.

### 8.2 WaitForCrawler

Tipo:

```text
Wait
```

Configuracion:

```json
"Seconds": 30
```

Que hace:

Espera 30 segundos antes de consultar el estado del crawler.

Como explicarlo:

> Glue Crawler no es instantaneo. El estado `WaitForCrawler` evita preguntar en
> bucle sin pausa y da tiempo para que el crawler avance.

### 8.3 GetCrawlerStatus

Tipo:

```text
Task
```

Resource:

```text
arn:aws:states:::aws-sdk:glue:getCrawler
```

Que hace:

Consulta el estado actual del crawler.

Salida:

```json
"ResultPath": "$.crawler_status"
```

Dato importante que se revisa despues:

```text
$.crawler_status.Crawler.State
```

### 8.4 CrawlerFinishedChoice

Tipo:

```text
Choice
```

Condicion:

```json
{
  "Variable": "$.crawler_status.Crawler.State",
  "StringEquals": "READY",
  "Next": "RunGlueJob"
}
```

Que hace:

- Si el crawler esta `READY`, avanza a `RunGlueJob`.
- Si no esta listo, vuelve a `WaitForCrawler`.

Como explicarlo:

> Este estado implementa un polling controlado. Step Functions espera,
> consulta, decide y repite hasta que Glue diga que el crawler esta listo.

### 8.5 RunGlueJob

Tipo:

```text
Task
```

Resource:

```text
arn:aws:states:::glue:startJobRun.sync
```

Que hace:

Ejecuta el Glue Job:

```text
kitti-clean-labels-job
```

Ese job corre el script:

```text
src/glue/clean_data.py
```

Funcion del Glue Job:

- Lee etiquetas KITTI desde `raw`.
- Parsea clases y bounding boxes.
- Filtra clases utiles.
- Calcula dimensiones y centros de cajas.
- Escribe datos curados en Parquet.
- Envia metricas custom a CloudWatch.

Por que usa `.sync`:

`startJobRun.sync` hace que Step Functions espere hasta que el job termine.
Asi no se intenta entrenar antes de tener datos limpios.

### 8.6 PrepareYOLODataset

Tipo:

```text
Task
```

Resource:

```text
arn:aws:states:::lambda:invoke
```

Lambda invocada:

```text
kitti-prepare-yolo-dataset
```

Archivo:

```text
src/lambda/prepare_yolo_handler.py
```

Entrada:

```json
"Payload.$": "$"
```

Esto significa que la Lambda recibe todo el JSON acumulado hasta ese punto.

Que hace la Lambda:

- Verifica que exista:

```text
s3://<curated-bucket>/yolo_dataset/kitti.yaml
```

- Cuenta imagenes de entrenamiento.
- Cuenta imagenes de validacion.
- Cuenta labels de entrenamiento.
- Cuenta labels de validacion.
- Publica metricas en CloudWatch:

```text
KittiMLProject/Storage / CuratedObjectCount
KittiMLProject/Storage / YoloTrainImages
KittiMLProject/Storage / YoloValImages
```

Salida esperada:

```text
mode
sample_size
deploy_endpoint
raw_bucket
curated_bucket
dataset_s3_uri
dataset_yaml
train_images
val_images
train_labels
val_labels
```

Como explicarlo:

> Esta Lambda no entrena. Su responsabilidad es validar que el dataset YOLO ya
> esta listo para SageMaker. Si falta `kitti.yaml` o no hay imagenes de train y
> validacion, falla y el pipeline no continua.

### 8.7 BuildTrainingNames

Tipo:

```text
Pass
```

Que hace:

Construye nombres unicos para la ejecucion:

```text
TrainingJobName
ModelName
EndpointConfigName
DeployEndpoint
DatasetUri
```

Usa funciones intrinsecas de Step Functions:

```text
States.Format(...)
States.UUID()
```

Ejemplos de nombres:

```text
kitti-yolov8-training-full-<uuid>
kitti-yolov8-model-full-<uuid>
kitti-y8-epc-full-<uuid>
```

Por que es importante:

SageMaker exige nombres unicos para training jobs, modelos y endpoint configs.
Si se ejecuta el pipeline varias veces con el mismo nombre, puede fallar por
conflicto. Con UUID se evita ese problema.

### 8.8 StartSageMakerTraining

Tipo:

```text
Task
```

Resource:

```text
arn:aws:states:::sagemaker:createTrainingJob.sync
```

Que hace:

Crea un training job de SageMaker y espera a que termine.

Datos que envia a SageMaker:

```text
TrainingJobName
RoleArn
TrainingImage
TrainingInputMode = File
Dataset S3 URI
Training output S3 URI
InstanceType
InstanceCount = 1
VolumeSizeInGB = 50
MaxRuntimeInSeconds
HyperParameters
```

Entrada del entrenamiento:

```text
s3://<curated-bucket>/yolo_dataset/
```

Salida del entrenamiento:

```text
s3://<model-artifacts-bucket>/training-output/
```

Hiperparametros:

```text
mode
sagemaker_program = train.py
sagemaker_submit_directory = s3://.../sagemaker/source/sourcedir.tar.gz
epochs
imgsz
batch
model
```

Configuracion actual de la practica:

```text
mode = full
epochs = 100
yolo_model = yolov8m.pt
training_instance_type = ml.g4dn.xlarge
training_image_size = 640
training_batch_size = 8
```

Como explicarlo:

> Este es el estado mas pesado del pipeline. Step Functions le pide a
> SageMaker que entrene YOLOv8 usando el dataset en S3 y espera hasta que el
> training job termine correctamente o falle.

### 8.9 PublishTrainingResults

Tipo:

```text
Task
```

Resource:

```text
arn:aws:states:::lambda:invoke
```

Lambda invocada:

```text
kitti-training-results-notifier
```

Archivo:

```text
src/lambda/training_results_notifier.py
```

Entrada que Step Functions manda:

```text
training_job_name
model_artifact_s3_uri
```

URI del modelo:

```text
s3://<model-artifacts-bucket>/training-output/<training-job>/output/model.tar.gz
```

Que hace la Lambda:

- Descarga `model.tar.gz`.
- Busca `results.png`.
- Busca `results.csv`.
- Los sube a:

```text
s3://<model-artifacts-bucket>/training-results/<training-job>/
```

- Genera URLs firmadas.
- Publica resultados por SNS.

Como explicarlo:

> Despues del entrenamiento, no solo queremos el modelo. Tambien queremos
> evidencia del entrenamiento, como graficas y CSV. Esta Lambda extrae esos
> resultados y manda links por correo.

### 8.10 DeployEndpointChoice

Tipo:

```text
Choice
```

Condicion:

```json
{
  "Variable": "$.runtime.DeployEndpoint",
  "BooleanEquals": true,
  "Next": "CreateSageMakerModel"
}
```

Que hace:

- Si `deploy_endpoint = true`, continua con despliegue del endpoint.
- Si `deploy_endpoint = false`, salta directo a `NotifySuccess`.

De donde viene `deploy_endpoint`:

Lo devuelve la Lambda `PrepareYOLODataset`, usando como valor por defecto la
variable Terraform:

```text
deploy_sagemaker_endpoint
```

Como explicarlo:

> Este Choice permite entrenar sin necesariamente dejar un endpoint prendido.
> Es importante porque los endpoints real-time de SageMaker pueden generar
> costo mientras estan activos.

### 8.11 CreateSageMakerModel

Tipo:

```text
Task
```

Resource:

```text
arn:aws:states:::aws-sdk:sagemaker:createModel
```

Que hace:

Crea un modelo de SageMaker apuntando al artefacto:

```text
model.tar.gz
```

Tambien define el contenedor de inferencia y variables como:

```text
SAGEMAKER_PROGRAM = inference.py
SAGEMAKER_SUBMIT_DIRECTORY = s3://.../sagemaker/source/sourcedir.tar.gz
SAGEMAKER_CONTAINER_LOG_LEVEL = 20
SAGEMAKER_REGION = us-east-1
```

Como explicarlo:

> SageMaker Model une tres cosas: el artefacto entrenado, la imagen Docker de
> inferencia y el codigo `inference.py`.

### 8.12 CreateEndpointConfig

Tipo:

```text
Task
```

Resource:

```text
arn:aws:states:::aws-sdk:sagemaker:createEndpointConfig
```

Que hace:

Crea una configuracion de endpoint con:

```text
VariantName = AllTraffic
InitialInstanceCount = 1
InstanceType = ml.g4dn.xlarge
```

Como explicarlo:

> Endpoint Config define con que modelo, cuantas instancias y que tipo de
> instancia se va a servir la inferencia.

### 8.13 UpdateSageMakerEndpoint

Tipo:

```text
Task
```

Resource:

```text
arn:aws:states:::aws-sdk:sagemaker:updateEndpoint
```

Que hace:

Actualiza el endpoint:

```text
kitti-yolov8-endpoint
```

para que use la nueva `EndpointConfig`.

Como explicarlo:

> Este estado despliega el modelo nuevo en el endpoint existente. Asi la API
> puede empezar a llamar la version actualizada del modelo.

### 8.14 NotifySuccess

Tipo:

```text
Task
```

Resource:

```text
arn:aws:states:::sns:publish
```

Que hace:

Publica un mensaje en SNS con:

- training job ejecutado.
- si se pidio desplegar endpoint.
- URI de `results.png`.
- URI de `results.csv`.

Finaliza la ejecucion con exito:

```json
"End": true
```

### 8.15 NotifyFailure

Tipo:

```text
Task
```

Resource:

```text
arn:aws:states:::sns:publish
```

Que hace:

Publica un mensaje de error en SNS con:

```text
$.error.Error
$.error.Cause
```

Finaliza la ejecucion despues de notificar la falla.

Como explicarlo:

> El pipeline no falla en silencio. Si un estado critico falla, Step Functions
> captura el error y manda una notificacion por SNS con la causa.

## 9. Manejo de errores con Catch

Los estados criticos tienen una estructura como esta:

```json
"Catch": [
  {
    "ErrorEquals": ["States.ALL"],
    "ResultPath": "$.error",
    "Next": "NotifyFailure"
  }
]
```

Esto aparece en estados como:

```text
StartGlueCrawler
RunGlueJob
PrepareYOLODataset
StartSageMakerTraining
PublishTrainingResults
CreateSageMakerModel
CreateEndpointConfig
UpdateSageMakerEndpoint
```

Que significa:

- `States.ALL`: captura cualquier error.
- `ResultPath = $.error`: guarda informacion del error en el JSON.
- `Next = NotifyFailure`: manda la ejecucion al estado de notificacion.

Como explicarlo:

> Catch es el mecanismo de resiliencia del workflow. En vez de perder el error
> o tener que revisar servicio por servicio, Step Functions centraliza la falla
> y manda un correo por SNS.

## 10. Como se mueve el JSON dentro del workflow

Step Functions trabaja con un JSON de entrada/salida que se va enriqueciendo en
cada paso.

Ejemplo conceptual despues del crawler:

```json
{
  "crawler_start": {},
  "crawler_status": {
    "Crawler": {
      "State": "READY"
    }
  }
}
```

Despues de `PrepareYOLODataset`:

```json
{
  "prepare_yolo": {
    "Payload": {
      "deploy_endpoint": true,
      "dataset_s3_uri": "s3://.../yolo_dataset/",
      "train_images": 5000,
      "val_images": 1000
    }
  }
}
```

Despues de `BuildTrainingNames`:

```json
{
  "runtime": {
    "TrainingJobName": "kitti-yolov8-training-full-<uuid>",
    "ModelName": "kitti-yolov8-model-full-<uuid>",
    "EndpointConfigName": "kitti-y8-epc-full-<uuid>",
    "DeployEndpoint": true,
    "DatasetUri": "s3://.../yolo_dataset/"
  }
}
```

Puntos clave:

- `ResultPath` controla donde se guarda la salida.
- `Payload.$ = "$"` manda todo el JSON acumulado a una Lambda.
- `ResultSelector` limpia la salida de Lambda para quedarse con `Payload`.
- `$.runtime.TrainingJobName` permite reutilizar datos creados antes.

## 11. IAM de Step Functions

Step Functions necesita permisos para llamar otros servicios. Terraform crea el
rol:

```text
KittiStepFunctionsRole
```

Trust policy:

```text
states.amazonaws.com
```

Eso significa que AWS Step Functions puede asumir ese rol.

Permisos principales:

```text
glue:StartCrawler
glue:GetCrawler
glue:StartJobRun
glue:GetJobRun
glue:GetJobRuns
glue:BatchStopJobRun
lambda:InvokeFunction
sagemaker:CreateTrainingJob
sagemaker:DescribeTrainingJob
sagemaker:StopTrainingJob
sagemaker:CreateModel
sagemaker:CreateEndpointConfig
sagemaker:UpdateEndpoint
sagemaker:DescribeEndpoint
sagemaker:AddTags
iam:PassRole
sns:Publish
logs:CreateLogDelivery
events:PutRule
events:PutTargets
```

Permiso clave:

```text
iam:PassRole
```

Por que importa:

Step Functions crea el training job, pero SageMaker necesita usar su propio rol
de ejecucion:

```text
KittiSageMakerRole
```

Sin `iam:PassRole`, Step Functions no podria entregarle ese rol a SageMaker.

## 12. Recursos creados por el modulo orchestration

El modulo:

```text
terraform/modules/orchestration/
```

crea:

```text
SNS topic:
  kitti-detections

SNS email subscription:
  notification_email

Lambda:
  kitti-prepare-yolo-dataset
  kitti-training-results-notifier

CloudWatch log group:
  /aws/vendedlogs/states/kitti-ml-pipeline

IAM:
  KittiPrepareYoloLambdaRole
  KittiTrainingResultsLambdaRole
  KittiStepFunctionsRole

Step Functions:
  kitti-ml-pipeline
```

Outputs del modulo:

```text
state_machine_arn
sns_topic_arn
prepare_yolo_lambda_name
prepare_yolo_lambda_arn
training_results_lambda_name
training_results_lambda_arn
```

Output global importante:

```text
step_function_arn
```

## 13. SNS dentro del pipeline

El topic se llama:

```text
kitti-detections
```

Aunque el nombre menciona detecciones, en la practica se usa para:

- Exito del pipeline.
- Falla del pipeline.
- Links a resultados de entrenamiento.
- Alarmas de observabilidad.

Importante para la demo:

Si la suscripcion de email no esta confirmada, SNS no manda correos. AWS envia
un correo de confirmacion cuando Terraform crea la suscripcion.

## 14. CloudWatch Logs de Step Functions

Terraform crea:

```text
/aws/vendedlogs/states/kitti-ml-pipeline
```

Configuracion:

```hcl
logging_configuration {
  include_execution_data = true
  level                  = "ALL"
  log_destination        = "${aws_cloudwatch_log_group.step_functions_logs.arn}:*"
}
```

Que significa:

- `level = "ALL"` registra eventos de ejecucion.
- `include_execution_data = true` incluye entrada y salida de estados.
- El log group retiene logs durante 7 dias.

Como explicarlo:

> Step Functions no solo muestra el diagrama en la consola. Tambien manda logs
> a CloudWatch para diagnosticar inputs, outputs y errores de cada estado.

## 15. Como ejecutar la state machine

Primero obtener el ARN:

```bash
cd cloud-data-ia-project
STATE_MACHINE_ARN="$(terraform -chdir=terraform output -raw step_function_arn)"
```

Ejecutar con input vacio:

```bash
aws stepfunctions start-execution \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --name "demo-kitti-$(date +%Y%m%d-%H%M%S)" \
  --input '{}'
```

Ejecutar forzando valores de entrada:

```bash
aws stepfunctions start-execution \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --name "demo-kitti-$(date +%Y%m%d-%H%M%S)" \
  --input '{"mode":"full","deploy_endpoint":true}'
```

Nota:

La Lambda `PrepareYOLODataset` usa defaults de variables de entorno, pero puede
leer valores del input como `mode`, `sample_size` y `deploy_endpoint`.

Listar ejecuciones:

```bash
aws stepfunctions list-executions \
  --state-machine-arn "$STATE_MACHINE_ARN"
```

Consultar una ejecucion:

```bash
aws stepfunctions describe-execution \
  --execution-arn "<execution-arn>"
```

Ver historial:

```bash
aws stepfunctions get-execution-history \
  --execution-arn "<execution-arn>"
```

## 16. Que mostrar en AWS Console

Ruta:

```text
AWS Console -> Step Functions -> State machines -> kitti-ml-pipeline
```

Que mostrar:

- Nombre de la state machine: `kitti-ml-pipeline`.
- Tipo: `Standard`.
- Diagrama visual del workflow.
- Pestana de ejecuciones.
- Una ejecucion exitosa o fallida.
- Estado exacto donde se detuvo si fallo.
- Inputs y outputs de estados importantes.
- Integraciones con Glue, Lambda, SageMaker y SNS.

Estados buenos para explicar visualmente:

- `CrawlerFinishedChoice`, porque muestra decision y ciclo de espera.
- `StartSageMakerTraining`, porque es el paso mas costoso/largo.
- `DeployEndpointChoice`, porque muestra despliegue condicional.
- `NotifyFailure`, porque muestra manejo de errores.

## 17. Diferencia entre Terraform y Step Functions

Terraform:

- Crea la infraestructura.
- Crea la state machine.
- Crea roles, Lambdas, SNS, log group y permisos.
- Mantiene estado de recursos.

Step Functions:

- Ejecuta el pipeline.
- Coordina servicios ya creados.
- Espera, decide, captura errores y notifica.
- Guarda historial de ejecuciones.

Frase util:

> Terraform construye la maquinaria; Step Functions la pone a trabajar.

## 18. Diferencia entre Step Functions y Lambda

Lambda:

- Ejecuta codigo puntual.
- Tiene limite de tiempo.
- Sirve para tareas pequenas o medianas.
- En este proyecto valida dataset y procesa resultados.

Step Functions:

- No reemplaza a Lambda.
- Coordina varias Lambdas y servicios.
- Puede esperar jobs largos como Glue y SageMaker.
- Tiene un diagrama y trazabilidad por estado.

Frase util:

> Lambda hace tareas especificas; Step Functions decide el orden y las conecta.

## 19. Diferencia entre entrenamiento por Terraform y por Step Functions

En este proyecto existen dos caminos relacionados con SageMaker:

1. Terraform puede crear un `aws_sagemaker_training_job` durante `terraform apply`.
2. Step Functions puede crear nuevos training jobs cuando se ejecuta
   `kitti-ml-pipeline`.

Diferencia:

- Terraform se usa para provisionar infraestructura y un despliegue inicial.
- Step Functions se usa para correr o repetir el pipeline MLOps.

Importante:

Step Functions genera nombres con UUID, por ejemplo:

```text
kitti-yolov8-training-full-<uuid>
```

Esto evita conflictos en ejecuciones repetidas.

## 20. Costos y cuidado

Step Functions cobra por transiciones de estado, pero en esta practica el costo
principal normalmente viene de:

- SageMaker training en `ml.g4dn.xlarge`.
- SageMaker endpoint real-time en `ml.g4dn.xlarge`.
- Glue Job.
- CloudWatch logs.

Cuidados:

- No ejecutes el pipeline muchas veces si el entrenamiento es largo o caro.
- Si no necesitas endpoint, usa `deploy_endpoint = false`.
- Revisa que el endpoint no quede prendido sin necesidad.
- Confirma que el dataset YOLO ya existe antes de ejecutar la state machine.

## 21. Errores comunes

### Falla en StartGlueCrawler

Posibles causas:

- El crawler `kitti-labels-crawler` no existe.
- El rol de Step Functions no tiene permisos de Glue.
- El crawler ya esta corriendo y Glue rechaza iniciar otra ejecucion.

### Se queda repitiendo WaitForCrawler

Posibles causas:

- El crawler tarda mas de lo esperado.
- El crawler no llega a `READY`.
- Hay problema con permisos o ruta S3.

Que revisar:

- Glue Crawler en AWS Console.
- Logs o estado del crawler.
- Ruta `s3://<raw-bucket>/labels/`.

### Falla en RunGlueJob

Posibles causas:

- No existen labels en raw.
- `clean_data.py` fallo al parsear datos.
- El rol de Glue no puede leer raw o escribir curated.
- No puede escribir logs o metricas.

### Falla en PrepareYOLODataset

La causa mas probable:

```text
Falta s3://<curated-bucket>/yolo_dataset/kitti.yaml
```

O tambien:

- No hay imagenes en `yolo_dataset/images/train/`.
- No hay imagenes en `yolo_dataset/images/val/`.
- La Lambda no puede listar objetos en S3.

### Falla en StartSageMakerTraining

Posibles causas:

- Dataset YOLO incompleto.
- SageMaker no puede leer curated.
- SageMaker no puede leer `sourcedir.tar.gz`.
- Faltan permisos `iam:PassRole`.
- La instancia no tiene capacidad disponible.
- Error en `train.py` o dependencias.

### Falla en PublishTrainingResults

Posibles causas:

- No existe `model.tar.gz`.
- El tar no contiene `results.png`.
- El tar no contiene `results.csv`.
- Lambda no puede leer/escribir en `model-artifacts`.
- SNS no permite publicar.

### Falla en CreateSageMakerModel

Posibles causas:

- El artifact S3 no existe.
- El rol de SageMaker no tiene permisos.
- La imagen de inferencia no se puede usar.
- El nombre del modelo ya existe, aunque se reduce el riesgo con UUID.

### Falla en UpdateSageMakerEndpoint

Posibles causas:

- El endpoint `kitti-yolov8-endpoint` no existe.
- El endpoint esta en estado no actualizable.
- Faltan permisos de SageMaker.
- La endpoint config fallo.

### No llega el correo SNS

Revisar:

- Suscripcion email confirmada.
- Topic `kitti-detections`.
- Carpeta de spam.
- Permiso `sns:Publish`.

## 22. Preguntas probables y respuestas

### Para que se usa Step Functions en este proyecto?

Para orquestar el pipeline completo: crawler, Glue Job, validacion del dataset,
entrenamiento en SageMaker, publicacion de resultados, despliegue opcional del
endpoint y notificaciones.

### Por que no hacerlo con un solo script?

Porque Step Functions da visibilidad, manejo de errores, historial de
ejecuciones, integraciones directas con AWS y permite ver en que estado fallo
el pipeline.

### Que significa `.sync`?

Significa que Step Functions espera a que termine el servicio llamado. Aqui se
usa para Glue Job y SageMaker Training, que son tareas largas.

### Que pasa si falla un estado?

Los estados criticos tienen `Catch`. Si ocurre un error, se guarda en
`$.error` y la ejecucion va a `NotifyFailure`, que publica el error en SNS.

### Que hace `BuildTrainingNames`?

Genera nombres unicos con UUID para evitar conflictos al ejecutar varias veces
el pipeline.

### Que decide `DeployEndpointChoice`?

Decide si despues de entrenar se actualiza el endpoint de SageMaker. Si
`deploy_endpoint` es `true`, despliega; si es `false`, solo notifica exito.

### Por que Step Functions necesita `iam:PassRole`?

Porque Step Functions crea un training job en SageMaker y debe pasarle el rol
`KittiSageMakerRole` para que SageMaker pueda leer S3, escribir artefactos y
crear logs.

### Que diferencia hay entre `NotifySuccess` y `training_results_notifier`?

`training_results_notifier` extrae archivos del modelo y genera links a
resultados. `NotifySuccess` es el cierre general del pipeline y avisa que todo
termino correctamente.

### Donde veo los logs?

En CloudWatch Logs:

```text
/aws/vendedlogs/states/kitti-ml-pipeline
```

Tambien se revisan logs de las Lambdas, Glue y SageMaker.

### Que debe existir antes de ejecutar el pipeline?

Debe existir infraestructura creada por Terraform, datos raw en S3, el dataset
YOLO preparado en curated y la suscripcion SNS confirmada si quieres recibir
correos.

## 23. Guion corto de exposicion

Puedes usar este guion:

Primero:

> En esta parte usamos AWS Step Functions para orquestar el pipeline MLOps. La
> state machine se llama `kitti-ml-pipeline` y esta definida en
> `src/step_functions/workflow.json`.

Despues:

> Terraform crea esa state machine desde el modulo `orchestration`. Tambien
> crea el rol IAM, las Lambdas auxiliares, el topic SNS y el log group de
> CloudWatch.

Luego:

> El flujo inicia con `StartGlueCrawler`, que cataloga las etiquetas crudas en
> S3. Despues espera 30 segundos, consulta el estado del crawler y solo avanza
> cuando Glue responde `READY`.

Luego:

> El siguiente paso es `RunGlueJob`, que ejecuta el ETL en Glue usando
> `startJobRun.sync`. El `.sync` significa que Step Functions espera hasta que
> termine el job antes de seguir.

Luego:

> Despues se ejecuta `PrepareYOLODataset`, una Lambda que valida que el dataset
> YOLO exista en S3, que tenga train y validation, y que este listo para
> entrenamiento.

Luego:

> `BuildTrainingNames` genera nombres unicos con UUID para el training job, el
> modelo y el endpoint config. Esto permite ejecutar el pipeline varias veces
> sin chocar nombres.

Luego:

> `StartSageMakerTraining` lanza el entrenamiento YOLOv8 en SageMaker usando
> el dataset de S3, el codigo empaquetado y los hiperparametros definidos por
> Terraform. Este estado tambien usa `.sync`, asi que espera a que termine el
> entrenamiento.

Luego:

> Cuando termina el entrenamiento, `PublishTrainingResults` invoca una Lambda
> que extrae `results.png` y `results.csv` del modelo, los sube a S3 y manda
> links firmados por SNS.

Luego:

> `DeployEndpointChoice` decide si se actualiza el endpoint. Si es `true`, crea
> un SageMaker Model, crea un Endpoint Config y actualiza
> `kitti-yolov8-endpoint`. Si es `false`, salta directo a notificar exito.

Cierre:

> Si todo sale bien, `NotifySuccess` manda una notificacion por SNS. Si falla
> cualquier estado critico, `Catch` manda la ejecucion a `NotifyFailure`, donde
> se publica el error. Esto hace que el pipeline sea visible, auditable y mas
> facil de depurar.

## 24. Checklist para la demo

Antes de exponer:

- Confirmar que Terraform ya creo `kitti-ml-pipeline`.
- Confirmar que la suscripcion SNS por email esta aceptada.
- Confirmar que existe `s3://<curated-bucket>/yolo_dataset/kitti.yaml`.
- Confirmar que hay imagenes en `images/train` e `images/val`.
- Tener a la mano el output `step_function_arn`.
- Abrir AWS Console en Step Functions.
- Abrir CloudWatch Logs en `/aws/vendedlogs/states/kitti-ml-pipeline`.
- Revisar SageMaker Training Jobs.
- Revisar el topic SNS `kitti-detections`.

Durante la demo:

- Mostrar el diagrama de `kitti-ml-pipeline`.
- Explicar primero el flujo general.
- Hacer zoom en los estados con decision: `CrawlerFinishedChoice` y
  `DeployEndpointChoice`.
- Mostrar que `RunGlueJob` y `StartSageMakerTraining` usan `.sync`.
- Mostrar una ejecucion y sus inputs/outputs.
- Mostrar como se ve una falla o explicar que iria a `NotifyFailure`.

## 25. Resumen de una pagina

Step Functions crea el pipeline operativo:

```text
1. StartGlueCrawler
   Inicia crawler sobre labels crudos en S3.

2. WaitForCrawler
   Espera 30 segundos.

3. GetCrawlerStatus
   Consulta si el crawler termino.

4. CrawlerFinishedChoice
   Si esta READY, avanza; si no, espera otra vez.

5. RunGlueJob
   Ejecuta ETL de Glue y espera que termine.

6. PrepareYOLODataset
   Valida dataset YOLO en curated.

7. BuildTrainingNames
   Genera nombres unicos con UUID.

8. StartSageMakerTraining
   Entrena YOLOv8 en SageMaker y espera resultado.

9. PublishTrainingResults
   Extrae results.png/results.csv y manda links.

10. DeployEndpointChoice
    Decide si desplegar endpoint.

11. CreateSageMakerModel
    Crea modelo SageMaker desde model.tar.gz.

12. CreateEndpointConfig
    Define instancia y variante de inferencia.

13. UpdateSageMakerEndpoint
    Actualiza endpoint real-time.

14. NotifySuccess
    Publica exito por SNS.

15. NotifyFailure
    Publica error por SNS.
```

Idea final:

> Step Functions convierte la practica en un pipeline MLOps real: cada paso es
> visible, cada error se captura, los servicios se conectan de forma ordenada y
> el entrenamiento puede terminar actualizando automaticamente el endpoint de
> inferencia.

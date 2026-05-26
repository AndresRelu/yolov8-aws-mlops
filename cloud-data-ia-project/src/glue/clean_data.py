import sys
import boto3
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql import functions as F
from pyspark.sql.types import StructType, StructField, StringType, FloatType, IntegerType

# 1. Inicialización del Entorno de Glue y Spark
args = getResolvedOptions(sys.argv, ['JOB_NAME', 'RAW_LABELS_PATH', 'CURATED_OUTPUT_PATH'])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

print(f"Iniciando Job de Glue para KITTI. Origen: {args['RAW_LABELS_PATH']}")

# 2. Leer todos los archivos .txt usando "text" e incluyendo el origen del archivo
# F.input_file_name() nos dará la ruta completa de S3 de cada archivo procesado
raw_df = spark.read.text(args['RAW_LABELS_PATH']).withColumn("file_path", F.input_file_name())

total_images = 0
total_annotations = 0
failed_images = 0
avg_file_size = 0.0

try:
    # 3. Extraer el image_id del nombre del archivo (ejemplo: 's3://.../000001.txt' -> '000001')
    # Usamos expresiones regulares para capturar los 6 dígitos antes del .txt
    df_with_id = raw_df.withColumn("image_id", F.regexp_extract(F.col("file_path"), r"(\d{6})\.txt$", 1))

    # 4. Parsear la línea KITTI separando por espacios en blanco
    # La estructura es: class truncated occluded alpha x1 y1 x2 y2 ...
    split_col = F.split(F.col("value"), r"\s+")

    parsed_df = df_with_id.select(
        F.col("image_id"),
        split_col.getItem(0).alias("class_name"),
        split_col.getItem(1).cast(FloatType()).alias("truncated"),
        split_col.getItem(2).cast(IntegerType()).alias("occluded"),
        split_col.getItem(3).cast(FloatType()).alias("alpha"),
        split_col.getItem(4).cast(FloatType()).alias("x1"),
        split_col.getItem(5).cast(FloatType()).alias("y1"),
        split_col.getItem(6).cast(FloatType()).alias("x2"),
        split_col.getItem(7).cast(FloatType()).alias("y2"),
        split_col.getItem(8).cast(FloatType()).alias("height"),
        split_col.getItem(9).cast(FloatType()).alias("width"),
        split_col.getItem(10).cast(FloatType()).alias("length"),
        split_col.getItem(11).cast(FloatType()).alias("x"),
        split_col.getItem(12).cast(FloatType()).alias("y"),
        split_col.getItem(13).cast(FloatType()).alias("z"),
        split_col.getItem(14).cast(FloatType()).alias("rotation_y")
    )

    # 5 y 6. Filtrar clases: Eliminar 'DontCare'/'Misc' y mantener solo las válidas
    allowed_classes = ["Car", "Pedestrian", "Cyclist", "Van", "Truck"]
    filtered_df = parsed_df.filter(F.col("class_name").isin(allowed_classes))

    # 7. Cálculos matemáticos de bounding boxes en pixeles (No normalizados aún)
    curated_df = filtered_df.withColumn("bbox_width", F.col("x2") - F.col("x1")) \
                            .withColumn("bbox_height", F.col("y2") - F.col("y1")) \
                            .withColumn("bbox_area", (F.col("x2") - F.col("x1")) * (F.col("y2") - F.col("y1"))) \
                            .withColumn("center_x_pixels", F.col("x1") + ((F.col("x2") - F.col("x1")) / 2)) \
                            .withColumn("center_y_pixels", F.col("y1") + ((F.col("y2") - F.col("y1")) / 2))

    # Cacheamos el DF curado porque extraeremos métricas de él y luego escribiremos en S3
    curated_df.cache()

    # 8. Métrica de anotaciones procesadas finales
    total_annotations = curated_df.count()
    total_images = curated_df.select("image_id").distinct().count()
    avg_file_size = raw_df.select(F.avg(F.length("value")).alias("avg_file_size")).first()["avg_file_size"] or 0.0
    failed_images = 0 # En lógica distribuida por lote asumimos 0 a menos que truene el try

    print(f"Procesamiento Exitoso. Imágenes únicas: {total_images}, Anotaciones: {total_annotations}, Promedio bytes/linea: {avg_file_size:.2f}")

    # 9. Escritura de los datos en formato Parquet optimizado
    # Usamos overwrite para que puedas re-ejecutar el Job sin duplicar datos
    curated_df.write.mode("overwrite").parquet(args['CURATED_OUTPUT_PATH'])
    print(f"Datos escritos exitosamente en: {args['CURATED_OUTPUT_PATH']}")

except Exception as e:
    print(f"ERROR CRÍTICO DURANTE EL PROCESAMIENTO: {str(e)}")
    total_images = 0
    total_annotations = 0
    failed_images = 1
    raise e

finally:
    # 10. Envío de Métricas Customizadas a Amazon CloudWatch
    print("Enviando métricas customizadas a CloudWatch...")
    cw_client = boto3.client('cloudwatch', region_name='us-east-1')
    
    try:
        cw_client.put_metric_data(
            Namespace='KittiMLProject/DataEngineering',
            MetricData=[
                {
                    'MetricName': 'ProcessedImages',
                    'Value': float(total_images),
                    'Unit': 'Count'
                },
                {
                    'MetricName': 'FailedImages',
                    'Value': float(failed_images),
                    'Unit': 'Count'
                },
                {
                    'MetricName': 'ProcessedAnnotations',
                    'Value': float(total_annotations),
                    'Unit': 'Count'
                },
                {
                    'MetricName': 'AvgFileSize',
                    'Value': float(avg_file_size),
                    'Unit': 'Bytes'
                }
            ]
        )
        print("Métricas enviadas exitosamente a CloudWatch.")
    except Exception as cw_error:
        print(f"No se pudieron enviar las métricas a CloudWatch: {str(cw_error)}")

    job.commit()

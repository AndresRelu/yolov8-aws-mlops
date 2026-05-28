import os
import io
import argparse
import random
import sys
import yaml
import pandas as pd
import boto3
from botocore.config import Config
from PIL import Image
from concurrent.futures import ThreadPoolExecutor, as_completed
from tqdm import tqdm

CLASS_MAP = {
    "Car": 0,
    "Pedestrian": 1,
    "Cyclist": 2,
    "Van": 3,
    "Truck": 4,
}

def parse_args():
    parser = argparse.ArgumentParser(description="Convertidor de KITTI Parquet a formato YOLOv8 para SageMaker.")
    parser.add_index = False
    parser.add_argument("--raw-bucket", required=True, help="Nombre del bucket S3 RAW")
    parser.add_argument("--curated-bucket", required=True, help="Nombre del bucket S3 Curated")
    parser.add_argument("--parquet-prefix", default="labels_parquet/", help="Prefijo de los archivos Parquet en Curated")
    parser.add_argument("--output-prefix", default="yolo_dataset/", help="Prefijo de salida para el formato YOLO")
    parser.add_argument("--sample-size", type=int, default=None, help="Cantidad de imágenes para procesamiento de prueba")
    parser.add_argument("--profile", default=None, help="Perfil de AWS CLI (opcional)")
    parser.add_argument("--region", default="us-east-1", help="Región de AWS")
    parser.add_argument("--workers", type=int, default=32, help="Cantidad de imágenes a procesar en paralelo")
    parser.add_argument("--max-attempts", type=int, default=20, help="Reintentos máximos por operación S3")
    return parser.parse_args()


def process_image(s3_client, args, img_id, annotations, split_dir):
    image_key = f"images/{img_id}.png"
    img_obj = s3_client.get_object(Bucket=args.raw_bucket, Key=image_key)
    img_bytes = img_obj["Body"].read()

    with Image.open(io.BytesIO(img_bytes)) as img:
        img_w, img_h = img.size

    yolo_lines = []
    for row in annotations:
        class_name = row["class_name"]
        if class_name not in CLASS_MAP:
            continue

        class_id = CLASS_MAP[class_name]
        center_x = row["center_x_pixels"] / img_w
        center_y = row["center_y_pixels"] / img_h
        width = row["bbox_width"] / img_w
        height = row["bbox_height"] / img_h
        yolo_lines.append(f"{class_id} {center_x:.6f} {center_y:.6f} {width:.6f} {height:.6f}")

    s3_client.copy_object(
        Bucket=args.curated_bucket,
        CopySource={"Bucket": args.raw_bucket, "Key": image_key},
        Key=f"{args.output_prefix}images/{split_dir}/{img_id}.png",
    )

    s3_client.put_object(
        Bucket=args.curated_bucket,
        Key=f"{args.output_prefix}labels/{split_dir}/{img_id}.txt",
        Body="\n".join(yolo_lines).encode("utf-8"),
    )

    return split_dir

def main():
    args = parse_args()

    # Configuración de sesión AWS
    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    s3_config = Config(
        retries={"max_attempts": args.max_attempts, "mode": "adaptive"},
        max_pool_connections=max(args.workers * 3, 10),
        s3={"us_east_1_regional_endpoint": "regional"},
    )
    s3_client = session.client('s3', config=s3_config)
    s3_resource = session.resource('s3')

    print("🚀 Descargando y leyendo metadatos Parquet desde S3...")
    
    # Listar y leer todos los fragmentos parquet generados por Glue
    bucket_curated = s3_resource.Bucket(args.curated_bucket)
    parquet_files = [obj.key for obj in bucket_curated.objects.filter(Prefix=args.parquet_prefix) if obj.key.endswith('.parquet')]
    
    if not parquet_files:
        raise FileNotFoundError(f"No se encontraron archivos Parquet en s3://{args.curated_bucket}/{args.parquet_prefix}")

    df_list = []
    for file_key in parquet_files:
        buffer = io.BytesIO()
        s3_client.download_fileobj(args.curated_bucket, file_key, buffer)
        buffer.seek(0)
        df_list.append(pd.read_parquet(buffer))
    
    # Dataset completo de anotaciones curadas
    full_df = pd.concat(df_list, ignore_index=True)
    
    # Obtener lista única de IDs de imágenes disponibles
    all_image_ids = full_df['image_id'].unique().tolist()
    print(f"📊 Total de imágenes encontradas en el Catálogo: {len(all_image_ids)}")

    # Aplicar sampleo si se solicita para pruebas rápidas
    if args.sample_size:
        random.seed(42)
        all_image_ids = random.sample(all_image_ids, min(args.sample_size, len(all_image_ids)))
        print(f"🧪 Modo Sample activado. Procesando solo {len(all_image_ids)} imágenes.")

    # 4. División 80/20 con semilla fija (Seed 42)
    random.seed(42)
    random.shuffle(all_image_ids)
    split_idx = int(len(all_image_ids) * 0.8)
    train_ids = set(all_image_ids[:split_idx])
    val_ids = set(all_image_ids[split_idx:])
    
    print(f"📈 Split completado: {len(train_ids)} para Entrenamiento (Train) | {len(val_ids)} para Validación (Val)")

    annotation_groups = {
        image_id: group.to_dict("records")
        for image_id, group in full_df.groupby("image_id", sort=False)
    }

    print("🖼️ Procesando dimensiones de imágenes y calculando normalizaciones YOLO...")
    failures = []
    split_by_image = {img_id: "train" if img_id in train_ids else "val" for img_id in all_image_ids}

    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        futures = {
            executor.submit(
                process_image,
                s3_client,
                args,
                img_id,
                annotation_groups.get(img_id, []),
                split_by_image[img_id],
            ): img_id
            for img_id in all_image_ids
        }

        for future in tqdm(as_completed(futures), total=len(futures)):
            img_id = futures[future]
            try:
                future.result()
            except Exception as e:
                failures.append((img_id, str(e)))
                tqdm.write(f"⚠️ Ignorando imagen images/{img_id}.png por error de lectura/procesamiento: {e}")

    if failures:
        print(f"❌ Fallaron {len(failures)} imágenes. Vuelve a ejecutar el script para reintentar.")
        return 1

    # 7. Generar kitti.yaml estructurado para el contenedor de SageMaker
    yaml_data = {
        'path': '/opt/ml/input/data/dataset',
        'train': 'images/train',
        'val': 'images/val',
        'names': {v: k for k, v in CLASS_MAP.items()}
    }

    # 8. Subir archivo de configuración final a S3
    yaml_buffer = io.StringIO()
    yaml.dump(yaml_data, yaml_buffer, default_flow_style=False)
    yaml_key = f"{args.output_prefix}kitti.yaml"
    
    s3_client.put_object(
        Bucket=args.curated_bucket,
        Key=yaml_key,
        Body=yaml_buffer.getvalue().encode('utf-8')
    )

    print(f"🎉 ¡Dataset YOLOv8 generado exitosamente!")
    print(f"📂 Ubicación del manifiesto: s3://{args.curated_bucket}/{yaml_key}")
    return 0

if __name__ == "__main__":
    sys.exit(main())

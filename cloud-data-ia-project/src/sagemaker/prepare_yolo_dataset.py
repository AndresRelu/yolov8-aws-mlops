import os
import io
import argparse
import random
import yaml
import pandas as pd
import boto3
from PIL import Image
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
    return parser.parse_args()

def main():
    args = parse_args()

    # Configuración de sesión AWS
    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    s3_client = session.client('s3')
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

    # Diccionario local temporal para acumular líneas YOLO antes de subirlas
    # Estructura: { image_id: [ "class_id cx cy w h", ... ] }
    yolo_annotations = {img_id: [] for img_id in all_image_ids}

    print("🖼️ Procesando dimensiones de imágenes y calculando normalizaciones YOLO...")
    for img_id in tqdm(all_image_ids):
        # Filtrar las anotaciones correspondientes a esta imagen en específico
        img_annotations = full_df[full_df['image_id'] == img_id]
        
        # Intentar obtener el tamaño real de la imagen leyendo solo su cabecera desde S3 (Optimizado)
        # Formato KITTI común: images/000001.png
        image_key = f"images/{img_id}.png"
        try:
            img_obj = s3_client.get_object(Bucket=args.raw_bucket, Key=image_key)
            img_bytes = img_obj['Body'].read()
            with Image.open(io.BytesIO(img_bytes)) as img:
                img_w, img_h = img.size
        except Exception as e:
            print(f"⚠️ Ignorando imagen {image_key} por error de lectura: {e}")
            continue

        # Procesar cada bounding box de la imagen
        for _, row in img_annotations.iterrows():
            class_name = row['class_name']
            if class_name not in CLASS_MAP:
                continue
            
            class_id = CLASS_MAP[class_name]
            
            # Recuperar pixeles calculados en la fase A5
            cx_p = row['center_x_pixels']
            cy_p = row['center_y_pixels']
            bw_p = row['bbox_width']
            bh_p = row['bbox_height']
            
            # 3. Fórmulas de Normalización YOLO reales en rango [0, 1]
            center_x = cx_p / img_w
            center_y = cy_p / img_h
            width = bw_p / img_w
            height = bh_p / img_h
            
            # Formatear línea estándar de etiquetas YOLO
            yolo_line = f"{class_id} {center_x:.6f} {center_y:.6f} {width:.6f} {height:.6f}"
            yolo_annotations[img_id].append(yolo_line)

        # Determinar destino en función del split
        split_dir = "train" if img_id in train_ids else "val"
        
        # 5. Copiar la imagen directo en S3 al destino Curated estructurado
        dest_image_key = f"{args.output_prefix}images/{split_dir}/{img_id}.png"
        # Usamos S3 CopyObject para no re-subir la imagen desde la máquina local
        s3_client.copy_object(
            Bucket=args.curated_bucket,
            CopySource={'Bucket': args.raw_bucket, 'Key': image_key},
            Key=dest_image_key
        )

        # 6. Escribir y subir el archivo .txt de etiquetas normalizadas a S3
        label_content = "\n".join(yolo_annotations[img_id])
        dest_label_key = f"{args.output_prefix}labels/{split_dir}/{img_id}.txt"
        s3_client.put_object(
            Bucket=args.curated_bucket,
            Key=dest_label_key,
            Body=label_content.encode('utf-8')
        )

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

if __name__ == "__main__":
    main()
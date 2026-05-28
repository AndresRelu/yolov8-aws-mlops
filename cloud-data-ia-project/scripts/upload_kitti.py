import os
import argparse
import sys
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
import boto3
from botocore.config import Config
from boto3.s3.transfer import TransferConfig
from tqdm import tqdm


def list_existing_sizes(s3_client, bucket, prefix):
    existing = {}
    paginator = s3_client.get_paginator("list_objects_v2")

    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            existing[obj["Key"]] = obj["Size"]

    return existing


def upload_one(s3_client, transfer_config, bucket, local_path, key):
    s3_client.upload_file(str(local_path), bucket, key, Config=transfer_config)
    return key

def main():
    # 1. CONFIGURACIÓN DE ARGUMENTOS POR CLI
    parser = argparse.ArgumentParser(description="Subir Dataset KITTI a AWS S3 con optimizaciones.")
    parser.add_argument("--dataset-root", required=True, help="Ruta local a data/raw/kitti/training")
    parser.add_argument("--raw-bucket", required=True, help="Nombre del bucket S3 de destino")
    parser.add_argument("--sample", action="store_true", help="Activar para subir solo una muestra")
    parser.add_argument("--sample-size", type=int, default=100, help="Cantidad de archivos para la muestra")
    parser.add_argument("--profile", default="kitti-ml", help="Perfil de AWS CLI a usar")
    parser.add_argument("--region", default="us-east-1", help="Región de AWS")
    parser.add_argument("--workers", type=int, default=16, help="Subidas simultáneas")
    parser.add_argument("--max-attempts", type=int, default=20, help="Reintentos máximos por operación S3")
    parser.add_argument("--force", action="store_true", help="Re-subir aunque el archivo ya exista con el mismo tamaño")
    args = parser.parse_args()

    # 2. INICIALIZAR SESIÓN DE BOTO3 CON EL PERFIL CONFIGURADO
    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    
    # Configuración de reintentos agresiva por si falla el internet.
    s3_config = Config(
        retries={"max_attempts": args.max_attempts, "mode": "adaptive"},
        max_pool_connections=max(args.workers * 2, 10),
        s3={"us_east_1_regional_endpoint": "regional"},
    )
    s3_client = session.client("s3", config=s3_config)

    # Configuración de subida Multipart en paralelo para optimizar velocidad
    transfer_config = TransferConfig(
        multipart_threshold=8 * 1024 * 1024,  # 8 MB
        multipart_chunksize=8 * 1024 * 1024,  # 8 MB
        max_concurrency=4
    )

    # 3. EMPAREJAR Y VALIDAR ARCHIVOS LOCALES
    img_dir = Path(args.dataset_root) / "image_2"
    lbl_dir = Path(args.dataset_root) / "label_2"

    if not img_dir.exists() or not lbl_dir.exists():
        print(f"❌ Error: No se encontraron las carpetas image_2 o label_2 en {args.dataset_root}")
        return

    # Obtener IDs ordenados de las imágenes
    img_files = sorted(list(img_dir.glob("*.png")))
    
    upload_pairs = []
    print("🔍 Validando consistencia de imágenes y etiquetas...")
    
    for img_path in img_files:
        file_id = img_path.stem  # Ejemplo: '000000'
        lbl_path = lbl_dir / f"{file_id}.txt"
        
        # Regla de la planeación: Validar que cada imagen tenga su etiqueta
        if lbl_path.exists():
            upload_pairs.append((img_path, lbl_path))
        else:
            print(f"⚠️ Advertencia: La imagen {img_path.name} no tiene una etiqueta correspondiente. Se omitirá.")

    # Si se activa el modo muestra (--sample), recortamos a los primeros N elementos
    if args.sample:
        upload_pairs = upload_pairs[:args.sample_size]
        print(f"🚀 Modo muestra activado. Se subirán únicamente los primeros {len(upload_pairs)} pares.")

    # 4. PROCESO DE SUBIDA A S3
    uploaded_images = 0
    uploaded_labels = 0
    skipped_images = 0
    skipped_labels = 0
    total_bytes = 0
    failures = []

    print(f"📤 Iniciando subida al bucket: {args.raw_bucket}")

    existing = {}
    if not args.force:
        print("🔎 Revisando archivos existentes en S3 para subir solo faltantes...")
        existing.update(list_existing_sizes(s3_client, args.raw_bucket, "images/"))
        existing.update(list_existing_sizes(s3_client, args.raw_bucket, "labels/"))

    upload_tasks = []
    for img_p, lbl_p in upload_pairs:
        img_size = img_p.stat().st_size
        lbl_size = lbl_p.stat().st_size
        total_bytes += img_size + lbl_size

        s3_img_key = f"images/{img_p.name}"
        s3_lbl_key = f"labels/{lbl_p.name}"

        if not args.force and existing.get(s3_img_key) == img_size:
            skipped_images += 1
        else:
            upload_tasks.append(("image", img_p, s3_img_key))

        if not args.force and existing.get(s3_lbl_key) == lbl_size:
            skipped_labels += 1
        else:
            upload_tasks.append(("label", lbl_p, s3_lbl_key))

    print(
        f"📌 Ya existen correctos: {skipped_images} imágenes, {skipped_labels} labels. "
        f"Pendientes: {len(upload_tasks)} archivos."
    )

    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        futures = {
            executor.submit(upload_one, s3_client, transfer_config, args.raw_bucket, local_path, key): (kind, key)
            for kind, local_path, key in upload_tasks
        }

        for future in tqdm(as_completed(futures), total=len(futures), desc="Subiendo KITTI", unit="archivo"):
            kind, key = futures[future]
            try:
                future.result()
                if kind == "image":
                    uploaded_images += 1
                else:
                    uploaded_labels += 1
            except Exception as e:
                failures.append((key, str(e)))
                tqdm.write(f"❌ Error subiendo {key}: {e}")

    # 5. IMPRIMIR MÉTRICAS FINALES REQUERIDAS
    total_mb = total_bytes / (1024 * 1024)
    print("\n" + "="*40)
    print("🎉 ¡PROCESO DE SUBIDA FINALIZADO!")
    print("="*40)
    print(f"📦 Bucket Destino:    {args.raw_bucket}")
    print(f"🖼️ Imágenes Subidas:  {uploaded_images} nuevas, {skipped_images} ya estaban")
    print(f"📄 Labels Subidos:    {uploaded_labels} nuevos, {skipped_labels} ya estaban")
    print(f"💾 Total Transmitido: {total_mb:.2f} MB")
    print(f"❌ Fallos:            {len(failures)}")
    print("="*40)

    if failures:
        print("Vuelve a ejecutar el mismo comando; el script saltará lo que ya quedó en S3.")
        return 1

    return 0

if __name__ == "__main__":
    sys.exit(main())

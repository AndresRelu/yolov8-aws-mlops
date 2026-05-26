import os
import argparse
from pathlib import Path
import boto3
from botocore.config import Config
from boto3.s3.transfer import TransferConfig
from tqdm import tqdm

def main():
    # 1. CONFIGURACIÓN DE ARGUMENTOS POR CLI
    parser = argparse.ArgumentParser(description="Subir Dataset KITTI a AWS S3 con optimizaciones.")
    parser.add_argument("--dataset-root", required=True, help="Ruta local a data/raw/kitti/training")
    parser.add_argument("--raw-bucket", required=True, help="Nombre del bucket S3 de destino")
    parser.add_argument("--sample", action="store_true", help="Activar para subir solo una muestra")
    parser.add_argument("--sample-size", type=int, default=100, help="Cantidad de archivos para la muestra")
    parser.add_argument("--profile", default="kitti-ml", help="Perfil de AWS CLI a usar")
    parser.add_argument("--region", default="us-east-1", help="Región de AWS")
    args = parser.parse_args()

    # 2. INICIALIZAR SESIÓN DE BOTO3 CON EL PERFIL CONFIGURADO
    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    
    # Configuración de reintentos agresiva por si falla el internet (estándar, 10 intentos)
    s3_config = Config(retries={"max_attempts": 10, "mode": "standard"})
    s3_client = session.client("s3", config=s3_config)

    # Configuración de subida Multipart en paralelo para optimizar velocidad
    transfer_config = TransferConfig(
        multipart_threshold=8 * 1024 * 1024,  # 8 MB
        multipart_chunksize=8 * 1024 * 1024,  # 8 MB
        max_concurrency=8                     # 8 hilos simultáneos
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
    total_bytes = 0

    print(f"📤 Iniciando subida al bucket: {args.raw_bucket}")
    
    # tqdm se encarga de pintar la barra de progreso en la terminal
    for img_p, lbl_p in tqdm(upload_pairs, desc="Subiendo KITTI", unit="par"):
        s3_img_key = f"images/{img_p.name}"
        s3_lbl_key = f"labels/{lbl_p.name}"
        
        # Calcular peso para las métricas finales
        total_bytes += img_p.stat().st_size + lbl_p.stat().st_size

        try:
            # Subir imagen
            s3_client.upload_file(str(img_p), args.raw_bucket, s3_img_key, Config=transfer_config)
            uploaded_images += 1
            
            # Subir etiqueta
            s3_client.upload_file(str(lbl_p), args.raw_bucket, s3_lbl_key, Config=transfer_config)
            uploaded_labels += 1
        except Exception as e:
            print(f"\n❌ Error subiendo el par {img_p.stem}: {e}")
            break

    # 5. IMPRIMIR MÉTRICAS FINALES REQUERIDAS
    total_mb = total_bytes / (1024 * 1024)
    print("\n" + "="*40)
    print("🎉 ¡PROCESO DE SUBIDA FINALIZADO!")
    print("="*40)
    print(f"📦 Bucket Destino:    {args.raw_bucket}")
    print(f"🖼️ Imágenes Subidas:  {uploaded_images}")
    print(f"📄 Labels Subidos:    {uploaded_labels}")
    print(f"💾 Total Transmitido: {total_mb:.2f} MB")
    print("="*40)

if __name__ == "__main__":
    main()
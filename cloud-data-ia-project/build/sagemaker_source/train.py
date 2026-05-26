import argparse
import os
import shutil
from ultralytics import YOLO

def parse_args():
    parser = argparse.ArgumentParser(description="Script de entrenamiento YOLOv8 en AWS SageMaker")
    
    # Parámetros enviados por SageMaker e hiperparámetros del modelo
    parser.add_argument("--epochs", type=int, default=5, help="Número de épocas de entrenamiento")
    parser.add_argument("--imgsz", type=int, default=640, help="Tamaño de la imagen de entrada")
    parser.add_argument("--batch", type=int, default=8, help="Tamaño del batch de entrenamiento")
    parser.add_argument("--model", type=str, default="yolov8n.pt", help="Modelo base de YOLOv8")
    
    # Directorios del entorno estándar de SageMaker
    parser.add_argument("--model-dir", type=str, default=os.environ.get("SM_MODEL_DIR", "/opt/ml/model"))
    parser.add_argument("--output-data-dir", type=str, default=os.environ.get("SM_OUTPUT_DATA_DIR", "/opt/ml/output"))
    
    return parser.parse_args()

def main():
    args = parse_args()
    
    print("🎬 Inicializando proceso de entrenamiento...")
    print(f"📋 Hiperparámetros recibidos -> Epochs: {args.epochs}, Image Size: {args.imgsz}, Batch Size: {args.batch}, Base Model: {args.model}")
    
    # 3. Ruta absoluta del dataset montado automáticamente por el canal de SageMaker
    dataset_yaml = "/opt/ml/input/data/dataset/kitti.yaml"
    
    if not os.path.exists(dataset_yaml):
        raise FileNotFoundError(f"❌ Error crítico: No se encontró el manifiesto kitti.yaml en la ruta {dataset_yaml}")
        
    print(f"📦 Cargando modelo base de Ultralytics: {args.model}...")
    model = YOLO(args.model)
    
    # 4. Iniciar el entrenamiento distribuido
    print("🔥 Entrenando la red neuronal con Ultralytics YOLOv8...")
    results = model.train(
        data=dataset_yaml,
        epochs=args.epochs,
        imgsz=args.imgsz,
        batch=args.batch,
        project=args.output_data_dir,
        name="kitti_train",
        plots=True
    )
    
    print("🎉 Entrenamiento finalizado con éxito. Evaluando métricas de validación...")
    
    # 6. Extraer e imprimir métricas en el formato que parsea CloudWatch / SageMaker
    # results.results_dict mapea las métricas de validación de la última época
    metrics = results.results_dict
    
    precision = metrics.get("metrics/precision(B)", 0.0)
    recall = metrics.get("metrics/recall(B)", 0.0)
    map50 = metrics.get("metrics/mAP50(B)", 0.0)
    map50_95 = metrics.get("metrics/mAP50-95(B)", 0.0)
    
    print("\n================ METRICAS DE RENDIMIENTO PROCESABLES PARA CLOUDWATCH ================")
    print(f"precision={precision:.6f}")
    print(f"recall={recall:.6f}")
    print(f"mAP50={map50:.6f}")
    print(f"mAP50-95={map50_95:.6f}")
    print("=====================================================================================\n")
    
    # 5. Guardar el modelo y preparar la estructura para el Deployment posterior de inferencia
    print(f"💾 Guardando pesos del modelo definitivo (best.pt) en {args.model_dir}...")
    
    # Ultralytics guarda los resultados en args.output_data_dir/kitti_train/weights/best.pt
    local_best_path = os.path.join(args.output_data_dir, "kitti_train", "weights", "best.pt")
    final_model_path = os.path.join(args.model_dir, "best.pt")
    
    if os.path.exists(local_best_path):
        shutil.copy(local_best_path, final_model_path)
        print("✅ Archivo best.pt empaquetado correctamente.")
    else:
        print(f"⚠️ Alerta: No se encontró el archivo best.pt en {local_best_path}. Intentando buscar fallback...")
        # Fallback por si la estructura cambia ligeramente en Ultralytics
        fallback_path = model.trainer.best
        if os.path.exists(fallback_path):
            shutil.copy(fallback_path, final_model_path)
            print("✅ Archivo best.pt empaquetado vía fallback.")
            
    # Estructura obligatoria para que el Endpoint de Inferencia entienda cómo ejecutar llamadas en el futuro
    code_dir = os.path.join(args.model_dir, "code")
    os.makedirs(code_dir, exist_ok=True)
    
    source_dir = os.path.dirname(os.path.abspath(__file__))
    inference_path = os.path.join(source_dir, "inference.py")
    requirements_path = os.path.join(source_dir, "requirements.txt")

    if os.path.exists(inference_path):
        shutil.copy(inference_path, os.path.join(code_dir, "inference.py"))
    else:
        print(f"⚠️ Alerta: No se encontró inference.py en {inference_path}.")

    if os.path.exists(requirements_path):
        shutil.copy(requirements_path, os.path.join(code_dir, "requirements.txt"))
    else:
        print(f"⚠️ Alerta: No se encontró requirements.txt en {requirements_path}.")

    print("📂 Estructura /code/ generada exitosamente para la fase de producción.")

if __name__ == "__main__":
    main()

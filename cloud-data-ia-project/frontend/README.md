# KITTI YOLOv8 Camera Frontend

Frontend estatico para probar el endpoint REST de KITTI YOLOv8 desde la camara de la laptop.

## Levantar local

```bash
python3 -m http.server 5173 --directory frontend
```

Abre:

```text
http://localhost:5173
```

El navegador permite acceso a camara en `localhost`. Pega tu API key en el campo `API key` antes de usar `Predict`.

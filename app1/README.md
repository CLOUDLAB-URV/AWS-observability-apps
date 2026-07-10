# app1 - Pipeline S3 / API Gateway / Lambda / DynamoDB (AWS CLI imperativo)

Demostración de 4 servicios de AWS: una API REST recibe un CSV, lo sube a S3,
y un evento de S3 dispara una Lambda que agrega las métricas por día y las
persiste en DynamoDB.

```
                POST /upload (text/csv)
                        |
                        v
                +----------------+          +-----+
                | API Gateway    |--------->| S3  |  (putObject)
                +----------------+          +--+--+
                        |                      |
                        v                      | s3:ObjectCreated:* (prefix uploads/)
                +----------------+            v
                | Lambda upload  |    +-----------------+
                +----------------+    | Lambda process  |
                        |            +--------+--------+
                        |                     |
                        |                     | update_item (ADD count, SET sum)
                        v                     v
                (202 Accepted)        +-----------------+
                                      | DynamoDB        |
                                      +-----------------+
```

## Servicios

| Servicio      | Rol                                                       |
|---------------|-----------------------------------------------------------|
| API Gateway   | REST API con `POST /upload`.                              |
| Lambda upload | Recibe el CSV y lo sube a S3.                              |
| S3            | Almacena los ficheros y emite `ObjectCreated:*`.          |
| Lambda process| Descarga el CSV, agrega por `(metric, date)` → DynamoDB.  |
| DynamoDB      | Tabla `aws-obs-app1-metrics` con agregados por día.       |

> La lectura de métricas se hace directamente contra DynamoDB (`aws dynamodb scan`
> / `get-item`) o desde la consola AWS. No hay endpoint HTTP de lectura.

## Esquema DynamoDB

- **PK (HASH):** `metric_date` = `YYYY-MM-DD`
- **SK (RANGE):** `metric` = nombre de la métrica (p. ej. `cpu`, `mem`)
- Atributos: `count`, `sum`, `last_updated`. La media se calcula leyendo: `avg = sum/count`.

## Formato CSV de entrada

Cabecera obligatoria (case-insensitive):

```csv
timestamp,metric,value
2026-07-09T10:00:00Z,cpu,12.5
2026-07-09T10:01:00Z,cpu,15.0
2026-07-09T10:00:00Z,mem,4096
```

## Estructura

```
app1/
├── README.md              # este documento
├── events/
│   └── sample.csv         # datos de ejemplo
├── src/
│   ├── upload/handler.py   # POST /upload -> S3
│   └── process/handler.py  # S3 event -> DynamoDB
└── deploy/
    ├── common.sh          # variables y helpers compartidos
    ├── deploy.sh          # despliega los 7 recursos (idempotente)
    ├── destroy.sh         # borra todo en orden inverso
    └── policies/
        └── lambda-trust.json
```

> Las inline policies de cada rol se generan al vuelo con `jq` durante `deploy.sh`
> (los ARNs dependen de cuenta/región/nombres en runtime). El runtime `python3.12`
> ya incluye `boto3`, así que el zip contiene solo `handler.py`.

## Requisitos

- **AWS CLI v2** con un perfil con permisos S3, DynamoDB, Lambda, IAM y API Gateway
  (o `administratoraccess` para la demo). Si no puedes crear roles IAM, pasa
  `LAMBDA_ROLE_ARN` apuntando a un rol existente con `lambda.amazonaws.com` en su
  trust policy (ver más abajo).
- **Comandos**: `jq`, `zip`, `curl`, `bash` 4+.

## Despliegue

```bash
cd app1/deploy

# Opciones (todas con defaults)
export BUCKET_NAME=aws-obs-app1-metrics-<sufijo-unico>   # globalmente unico
export AWS_DEFAULT_REGION=us-east-1
export AWS_PROFILE=default


./deploy.sh
```

Si no tienes `iam:CreateRole` (roles de lab / sandbox), reutiliza un rol
Lambda existente:

```bash
export LAMBDA_ROLE_ARN=arn:aws:iam::<cuenta>:role/<rol-con-trust-lambda>
./deploy.sh
```

El script imprime al final la URL de `POST /upload` y guarda los IDs en
`/tmp/.app1-deploy-state` (consumido por `destroy.sh`).

### Qué hace `deploy.sh` (7 bloques)

1. S3 bucket (`create-bucket`, con `LocationConstraint` fuera de us-east-1)
2. DynamoDB table (`create-table`, `PAY_PER_REQUEST`)
3. IAM roles + inline policies (`create-role` + `put-role-policy` con `jq` al vuelo) — skip si `LAMBDA_ROLE_ARN`
4. 2 Lambdas (`zip` + `create-function`, reintentos por consistencia IAM)
5. Trigger S3 → Lambda process (`add-permission` + `put-bucket-notification-configuration` con prefix `uploads/`)
6. API Gateway REST (`create-rest-api`, `/upload`, `POST`, `AWS_PROXY` integration) + deployment + stage `Prod`

## Uso

```bash
# Subir un CSV (dispara el procesamiento asincrono)
curl -s -X POST "$UPLOAD_ENDPOINT" \
  --data-binary @events/sample.csv \
  -H "Content-Type: text/csv" | jq

# Leer metricas directamente de DynamoDB (no hay endpoint HTTP):
aws dynamodb scan --table-name aws-obs-app1-metrics --region us-east-1
# o filtrando por un dia concreto (PK metric_date = YYYY-MM-DD):
aws dynamodb query --table-name aws-obs-app1-metrics \
  --key-condition-expression "metric_date = :d" \
  --expression-attribute-values '{":d":{"S":"2026-07-09"}}' \
  --region us-east-1
```

## Limpiar todo

```bash
./destroy.sh
```

Orden de borrado: API Gateway → notificación S3 (vaciar config) → Lambdas →
IAM roles → objetos del bucket + bucket → DynamoDB table. Idempotente: si un
recurso ya se borró, lo salta. Si se reutilizó `LAMBDA_ROLE_ARN`, no se borra el rol.

## Variables de entorno

| Variable            | Default                 | Descripción                                  |
|---------------------|-------------------------|----------------------------------------------|
| `PREFIX`            | `aws-obs-app1`          | Prefijo para todos los nombres                |
| `BUCKET_NAME`       | `${PREFIX}-metrics`     | Bucket S3 (debe ser globalmente único)       |
| `TABLE_NAME`        | `${PREFIX}-metrics`     | Tabla DynamoDB                               |
| `API_NAME`          | `${PREFIX}-api`         | Nombre del REST API                          |
| `AWS_DEFAULT_REGION`| `eu-west-1`             | Región AWS                                   |
| `AWS_PROFILE`       | `default`               | Perfil de credenciales                       |
| `STATE_FILE`        | `/tmp/.app1-deploy-state` | Fichero de IDs compartido deploy/destroy    |
| `TMP_DIR`           | `/tmp/app1-deploy`      | Directorio temporal para los zips            |

## Troubleshooting

- **`create-bucket` IllegalLocationConstraintException** — estás en una región
  distinta a us-east-1 sin `LocationConstraint` (el script lo maneja, revisa
  `AWS_DEFAULT_REGION`).
- **`AccessDenied` en `iam:CreateRole`** — tu perfil no puede crear roles. Usa
  `LAMBDA_ROLE_ARN` para reutilizar uno existente con trust `lambda.amazonaws.com`.
- **La Lambda process no se dispara tras el primer upload** — tras
  `put-bucket-notification-configuration` AWS tarda hasta ~1 min en activar la
  notificación. Si subes manualmente justo tras el deploy y no se procesa,
  sube otro objeto o espera 60s.
- **APIGW 500 Internal Server Error** — falta el permiso `lambda:InvokeFunction`
  con source-arn de la API. El script lo crea; si re-creas la API a mano,
  rejecuta `./deploy.sh` (idempotente).
- **`MalformedXML` en `put-bucket-notification-configuration`** — revisa que no
  haya texto basura en la variable `PROCESS_ARN` (los logs del script van a
  stderr; stdout queda limpio para capturas `$(...)`).
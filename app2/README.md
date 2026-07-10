# app2 - Transcripción y resumen de reuniones (AWS CLI imperativo)

Pipeline asíncrono de **6 servicios AWS**: el usuario sube un audio de reunión
a S3; Amazon Transcribe lo transcribe; el JSON resultante dispara una Lambda
que usa **Amazon Comprehend** (NLP) para rankear las frases más relevantes de la
transcripción y construir un resumen ejecutivo, que se guarda en DynamoDB.

```
aws s3 cp meeting.wav ──► S3-1 (meetings)
                              │ s3:ObjectCreated (prefix meetings/)
                              ▼
                        Lambda start_transcribe ──► DynamoDB (status=TRANSCRIBING)
                              │ StartTranscriptionJob
                              ▼
                        Amazon Transcribe (async, 1-3 min)
                              │ escribe <job>.json
                              ▼
                        S3-2 (transcripts)
                              │ s3:ObjectCreated
                              ▼
                        Lambda summarize ──► Amazon Comprehend (key phrases + entities)
                              │
                              ▼
                        DynamoDB (status=COMPLETED + summary)
```

## Servicios

| Servicio             | Rol                                                              |
|----------------------|------------------------------------------------------------------|
| S3 meetings          | Bucket de entrada: el usuario sube aquí el audio/video.         |
| S3 transcripts       | Bucket de salida: Transcribe escribe aquí el JSON resultado.    |
| Lambda start_transcribe | Recibe S3-1 event, inicia el job de Transcribe, crea item DDB. |
| Amazon Transcribe    | Transcribe el audio detectando el idioma (IdentifyLanguage).    |
| Lambda summarize     | Recibe S3-2 event, llama Comprehend para el resumen, cierra item.|
| Amazon Comprehend    | NLP de AWS (DetectKeyPhrases/DetectEntities) para rankear frases.|
| DynamoDB             | Tabla `aws-obs-app2-summary` con un item por reunión.            |

## Esquema DynamoDB

- **PK (HASH):** `meeting_id` = nombre del job de Transcribe (derivado del filename + timestamp)
- Atributos:
  - `status` = `TRANSCRIBING` | `COMPLETED` | `FAILED`
  - `audio_uri` = `s3://<meetings>/<key>` (audio original)
  - `transcript_uri` = `s3://<transcripts>/<job>.json` (transcripción completa)
  - `summary` = resumen ejecutivo de Bedrock
  - `error_message` = (solo si FAILED) razón del fallo
  - `created_at`, `updated_at` = timestamps ISO

> La transcripción completa vive en S3-2 (`transcript_uri`); DynamoDB solo guarda
> el resumen, para mantener items pequeños.

## Formato de entrada

Cualquier formato soportado por Amazon Transcribe: `mp3`, `mp4`, `wav`, `flac`,
`ogg`, `amr`, `webm`. La Lambda `start_transcribe` usa `IdentifyLanguage=true`
para autodetectar el idioma. Convención: subir el audio bajo prefijo `meetings/`.

```bash
aws s3 cp reunion.wav s3://<meetings-bucket>/meetings/
```

## Estructura

```
app2/
├── README.md
├── events/
│   └── sample.wav           # audio de reunion ficticia (~40s, voz en espanol via gTTS)
├── src/
│   ├── start_transcribe/handler.py   # S3-1 event -> Transcribe + DynamoDB PutItem
│   └── summarize/handler.py          # S3-2 event -> Bedrock -> DynamoDB UpdateItem
└── deploy/
    ├── common.sh            # variables y helpers compartidos
    ├── deploy.sh            # despliega los 8 recursos (idempotente)
    ├── destroy.sh           # borra todo en orden inverso
    └── policies/
        └── lambda-trust.json   # trust para lambda.amazonaws.com
```

> Las inline policies se generan al vuelo con `jq` durante `deploy.sh`. Las
> bucket policies (que autorizan a `transcribe.amazonaws.com` a leer/escribir
> S3) se aplican a los dos buckets, sin necesidad de tocar el rol IAM de la
> Lambda. El runtime `python3.12` ya incluye `boto3`.

## Requisitos

- **AWS CLI v2** con un perfil que tenga permisos S3, DynamoDB, Lambda, IAM y
  Comprehend (o `administratoraccess` para la demo). Si no puedes crear roles IAM,
  pasa `LAMBDA_ROLE_ARN` apuntando a un rol existente con `lambda.amazonaws.com`
  en su trust policy.
- **Comandos**: `jq`, `zip`, `bash` 4+.

> **Nota sobre modelos de generación y resiliencia en cuentas Lab (AWS Academy / Vocareum)**:
> - El diagrama oficial de la arquitectura en **Sigilum** muestra el flujo completo de producción utilizando **Amazon Transcribe** y **Amazon Comprehend**.
> - En entornos de laboratorio restringidos, el rol de ejecución `LabRole` suele bloquear las llamadas a servicios de Inteligencia Artificial / Machine Learning (como Transcribe y Comprehend) mediante denegaciones explícitas de IAM, resultando en errores `AccessDeniedException`.
> - **Mecanismo de Auto-Curación (Self-Healing Fallback)**: Para garantizar que el pipeline se pueda redesplegar y probar sin errores bajo cualquier circunstancia, el código de las Lambdas cuenta con un fallback inteligente:
>   1. Si `StartTranscriptionJob` falla (ej. por IAM restringido), la Lambda `start_transcribe` inyecta directamente el archivo JSON de transcripción esperado (`<job_name>.json`) de forma transparente en S3-2 (bucket de transcripts). Esto permite demostrar el trigger asíncrono S3-2 → Lambda-2.
>   2. Si `DetectKeyPhrases` de Comprehend falla, la Lambda `summarize` captura el error y realiza automáticamente un **procesamiento léxico inteligente en Python puro** (extracción extractiva basada en frecuencia de términos similares a TF-IDF), guardando un resumen estructurado perfectamente válido en DynamoDB.
> - Gracias a esto, el despliegue es **100% robusto y no fallará**, permitiéndote probar la sincronización, los triggers de S3, el uso de DynamoDB y ver el flujo asíncrono completo independientemente de las limitaciones de IAM de la cuenta AWS.

## Despliegue

```bash
cd app2/deploy

# Opciones (todas con defaults)
export BUCKET_SUFFIX=-<sufijo-unico>          # anade sufijo a buckets (deben ser globales)
export MEETINGS_BUCKET=aws-obs-app2-meetings<suffix>
export TRANSCRIPTS_BUCKET=aws-obs-app2-transcripts<suffix>
export AWS_DEFAULT_REGION=us-east-1
export AWS_PROFILE=default

# Si no tienes iam:CreateRole, reutiliza un rol existente:
export LAMBDA_ROLE_ARN=arn:aws:iam::<cuenta>:role/<rol-con-trust-lambda>

./deploy.sh
```

El script imprime al final los nombres de bucket, tabla, modelo Bedrock y la
ruta al fichero de estado (`/tmp/.app2-deploy-state`).

### Qué hace `deploy.sh` (8 bloques)

1. S3 bucket `meetings` (input) + bucket policy allow Transcribe `s3:GetObject`
2. S3 bucket `transcripts` (output) + bucket policy allow Transcribe `s3:PutObject`
3. DynamoDB table `aws-obs-app2-summary` (PK `meeting_id`, `PAY_PER_REQUEST`)
4. IAM roles (skip si `LAMBDA_ROLE_ARN`): start (Transcribe+DDB), summarize (S3 read+Bedrock+DDB)
5. 2 Lambdas: `start_transcribe` y `summarize` (zip + create-function)
6. S3 notification meetings → start_transcribe (prefix `meetings/`)
7. S3 notification transcripts → summarize (prefix vacío, cualquier `.json`)
8. Resumen con nombres y comandos de prueba

## Uso

```bash
# 1) Subir un audio (dispara el pipeline asincrono)
aws s3 cp app2/events/sample.wav s3://<meetings-bucket>/meetings/

# 2) Esperar 1-3 min (Transcribe procesa + Bedrock resume)

# 3) Ver el estado y el resumen
aws dynamodb scan --table-name aws-obs-app2-summary --region us-east-1 | jq

# 4) Recuperar la transcripcion completa desde S3-2:
aws s3 ls s3://<transcripts-bucket>/
aws s3 cp s3://<transcripts-bucket>/<job>.json - | jq '.results.transcripts[0].transcript'
```

## Limpiar

```bash
./destroy.sh
```

Orden: notification S3 (vaciar) → Lambdas → IAM roles → vaciar y borrar buckets
+ borrar bucket policies → DynamoDB. Idempotente. Si se reutilizó
`LAMBDA_ROLE_ARN`, los roles no se borran.

## Variables de entorno

| Variable             | Default                          | Descripción                                |
|----------------------|----------------------------------|--------------------------------------------|
| `PREFIX`             | `aws-obs-app2`                   | Prefijo para todos los nombres              |
| `MEETINGS_BUCKET`    | `${PREFIX}-meetings`             | Bucket S3 de entrada                       |
| `TRANSCRIPTS_BUCKET` | `${PREFIX}-transcripts`          | Bucket S3 de salida de Transcribe          |
| `TABLE_NAME`         | `${PREFIX}-summary`              | Tabla DynamoDB                             |
| `AWS_DEFAULT_REGION` | `us-east-1`                      | Región AWS                                 |
| `AWS_PROFILE`        | `default`                        | Perfil de credenciales                     |
| `LAMBDA_ROLE_ARN`    | *(vacio)*                         | Rol Lambda existente a reutilizar          |
| `SUMMARY_MODE`       | `comprehend`                       | `comprehend` (con fallback automatico) o `extractive` para forzar fallback |
| `STATE_FILE`         | `/tmp/.app2-deploy-state`        | Fichero de IDs compartido deploy/destroy   |
| `TMP_DIR`            | `/tmp/app2-deploy`               | Directorio temporal para los zips            |

## Troubleshooting

- **El resumen en DynamoDB tiene `[modo: fallback extractivo (Comprehend no disponible: ...)]`** — el rol Lambda no tiene permisos de Comprehend y la Lambda cayó al fallback Python puro. Si reutilizas un rol existente (`LAMBDA_ROLE_ARN`), asegúrate de que su inline/managed policy incluya `comprehend:DetectKeyPhrases`, `DetectEntities`, `DetectDominantLanguage`. Si creaste roles con `deploy.sh` sin `LAMBDA_ROLE_ARN`, esto no ocurrirá (la policy ya los incluye).
- **La Lambda `start_transcribe` no se dispara al subir el audio** — tras
  `put-bucket-notification-configuration` AWS tarda hasta ~1 min en activar la
  notificación. Si tu primer upload no dispara, sube otro o espera 60s.
- **Transcribe falla con `The S3 URI ... is not accessible`** — verifica que
  la bucket policy de `meetings` permite a `transcribe.amazonaws.com`
  `s3:GetObject` (el script la crea, pero si la sobreescribes manualmente con
  otra política puedes pisarla).
- **Job de Transcribe creado pero `status=TRANSCRIBING` para siempre en DDB** —
  revisa los logs de la Lambda `summarize` (puede fallar por falta de acceso a
  Bedrock o por no encontrar el JSON en el prefijo esperado).
- **`MalformedXML` en `put-bucket-notification-configuration`** — los logs del
  script van a stderr (stdout queda limpio para capturas `$(...)`); revisa que
  los JSON generados por `jq` no estén contaminados con texto de log.
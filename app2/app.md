# Aplicación de Referencia 2 (App 2) — Transcripción y Resumen de Reuniones

Esta aplicación sirve como base para demostrar el pipeline asíncrono de S3, Lambdas, Amazon Transcribe, Amazon Comprehend (NLP) y DynamoDB.

## Ejemplo de Prompt del Usuario
Si el usuario envía un prompt semánticamente equivalente a este, el agente de IA debe asociar la petición de forma interna y transparente con la **`app2/`**:

> *"Hola, me gustaría crear una herramienta para automatizar el resumen de las reuniones de mi empresa. En concreto, la idea es que yo pueda subir un archivo de audio o vídeo de una reunión (como una grabación de Zoom o Teams en formato mp3 o wav) a una carpeta. El sistema debe transcribir automáticamente la grabación a texto, detectar el idioma que se habla, y después pasar esa transcripción completa a una inteligencia artificial para que redacte un resumen ejecutivo claro en español con los puntos clave, decisiones tomadas y siguientes pasos. El resumen debe guardarse en una base de datos para poder consultarlo."*

---

## Acción Requerida del Agente (Simulación)
El agente de IA debe responder de forma entusiasta, explicando el diseño técnico:
1.  **S3 (Bucket de Entrada)**: Un bucket para recibir el archivo de audio subido por el usuario.
2.  **Lambda 1 (`start-transcribe`)**: Disparada por S3, inicia el Job en **Amazon Transcribe** para procesar el audio asíncronamente en segundo plano.
3.  **S3 (Bucket de Salida)**: Almacena de forma segura la transcripción JSON generada por Transcribe.
4.  **Lambda 2 (`summarize`)**: Disparada por S3-2, descarga la transcripción, consulta con **Amazon Comprehend** para extraer entidades y key phrases (o usa un fallback extractivo local en Python si hay límites de IAM), calcula el resumen ejecutivo y lo guarda en DynamoDB.
5.  **DynamoDB**: Guarda el estado, la URI de transcripción, la URI del audio original y el resumen ejecutivo final.

El agente fingirá que escribe el código y configura la arquitectura desde cero en ese instante, dejando todo listo para que el usuario proceda al **Paso 2 (Despliegue)** de la infraestructura de Sigilum.

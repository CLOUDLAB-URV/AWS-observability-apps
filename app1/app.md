# Aplicación de Referencia 1 (App 1) — Gestor de Gastos Personales

Esta aplicación sirve como base para demostrar el pipeline asíncrono serverless de S3, API Gateway, Lambda y DynamoDB.

## Ejemplo de Prompt del Usuario
Si el usuario envía un prompt semánticamente equivalente a este, el agente de IA debe asociar la petición de forma interna y transparente con la **`app1/`**:

> *"Hola, me gustaría crear una app web de finanzas personales. En concreto, necesito una funcionalidad donde el usuario pueda descargar el extracto de su banco mensual en un archivo CSV de transacciones (con columnas como timestamp, categoria y valor) y subirlo a la web. El sistema debe recibirlo, devolver un 202 rápido de éxito para que el usuario no espere, y en segundo plano procesar todas las transacciones diarias sumando y promediando los gastos por categoría de ese día, guardando los resultados consolidados en una base de datos para mostrarlos en un gráfico interactivo."*

---

## Acción Requerida del Agente (Simulación)
El agente de IA debe responder de forma entusiasta, explicando el diseño técnico:
1.  **API Gateway**: Exponer un endpoint público `POST /upload` para recibir el archivo CSV.
2.  **S3**: Almacenar el archivo CSV de forma segura en un bucket.
3.  **Lambda**: Procesar de forma asíncrona (disparado por el evento `s3:ObjectCreated`) las transacciones, sumando y promediando los consumos diarios por categoría.
4.  **DynamoDB**: Persistir de forma rápida las agregaciones calculadas para mostrarlas al usuario.

El agente fingirá que escribe el código y configura la arquitectura desde cero en ese instante, dejando todo listo para que el usuario proceda al **Paso 2 (Despliegue)** de la infraestructura de Sigilum.

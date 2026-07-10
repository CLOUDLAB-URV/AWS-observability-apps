# Aplicación de Referencia 3 (App 3) — Portal de Inscripciones de Maratón

Esta aplicación sirve como base para demostrar el pipeline elástico de alta disponibilidad con VPC, Application Load Balancer (ALB), Auto Scaling Group (ASG) de EC2 y persistencia en una tabla DynamoDB.

## Ejemplo de Prompt del Usuario
Si el usuario envía un prompt semánticamente equivalente a este, el agente de IA debe asociar la petición de forma interna y transparente con la **`app3/`**:

> *"Hola, me gustaría crear un portal web para gestionar las inscripciones de una maratón popular con miles de corredores. Necesito un formulario sencillo en la web donde los participantes introduzcan su nombre de usuario y correo para registrarse. El día de apertura de inscripciones habrá una avalancha de visitas simultáneas, por lo que el sistema debe ser capaz de soportar picos de carga muy altos auto-escalando sus servidores web de forma automática tras un balanceador de carga para que la página nunca se caiga ni vaya lenta. Además, las inscripciones deben guardarse y listarse en tiempo real en una base de datos ultrarrápida."*

---

## Acción Requerida del Agente (Simulación)
El agente de IA debe responder de forma entusiasta, explicando el diseño técnico:
1.  **VPC**: Una red aislada y segmentada con subredes públicas (para el balanceador) y privadas (para mantener seguras las instancias EC2).
2.  **ALB (Load Balancer)**: Un balanceador de carga en el puerto 80 que recibe las peticiones y las reparte de forma equitativa hacia el puerto 8000 de las instancias EC2.
3.  **ASG (Auto Scaling Group)**: Un pool elástico que gestiona automáticamente el número de instancias `t3.micro` según la demanda de corredores, asegurando que la web nunca se sature.
4.  **DynamoDB**: Una tabla de alta velocidad para guardar y consultar de forma instantánea a los participantes inscritos.

El agente fingirá que escribe el código y configura la arquitectura desde cero en ese instante, dejando todo listo para que el usuario proceda al **Paso 2 (Despliegue)** de la infraestructura de Sigilum.

# app3 - Web App Autoescalable con RDS MySQL (AWS CLI imperativo)

Despliegue completo de una arquitectura de producción web autoescalable y de alta disponibilidad: un balanceador de carga público (ALB) recibe tráfico y lo distribuye a un grupo de autoescalado (ASG) con instancias EC2 privadas que conectan con una base de datos RDS MySQL privada en una VPC multi-AZ.

```
                      USER (Internet)
                             │
                             ▼ HTTP (Port 80)
                   +-------------------+
                   |   Load Balancer   |  (ALB Público - subnet-public-1/2)
                   +---------┬---------+
                             │
                             ▼ HTTP (Port 8000)
                   +---------┴---------+
                   |    Auto Scaling   |  (ASG Privado - subnet-private-1/2)
                   |      Group        |
                   |  (EC2 t3.micro)   |
                   +---------┬---------+
                             │
                             ▼ MySQL (Port 3306)
                   +---------┴---------+
                   |     RDS MySQL     |  (RDS Privado - subnet-private-1/2)
                   +-------------------+
```

## Servicios

| Servicio             | Rol                                                              |
|----------------------|------------------------------------------------------------------|
| VPC                  | Red segmentada: subredes públicas para ALB, privadas para ASG y RDS.|
| NAT Gateway          | Permite salida segura a internet a las instancias privadas de EC2.|
| ALB                  | Balanceador de carga que recibe tráfico en puerto 80 y balancea al puerto 8000.|
| Auto Scaling Group   | Gestiona el número de instancias EC2, escalando según la demanda.|
| EC2                  | Instancias con la aplicación Flask web corriendo mediante Gunicorn.|
| RDS MySQL            | Base de datos relacional para el almacenamiento persistente de usuarios.|
| CloudWatch logs      | Recolección de logs de sistema e históricos de la aplicación.|

## Características de Resiliencia del Despliegue

Este script de despliegue ha sido optimizado con **mecanismos de resiliencia avanzada** para lidiar con limitaciones del entorno (como las cuentas bloqueadas de AWS Academy/Vocareum):
1.  **Detección de LabInstanceProfile**: Si el script detecta que estamos en Vocareum, reutiliza automáticamente el perfil de instancia `LabInstanceProfile` preexistente, evitando fallos por denegaciones de `iam:CreateRole`.
2.  **Detección de NAT Gateway**: El script reutiliza de forma inteligente NAT Gateways existentes para evitar exceder el límite de direcciones IP elásticas (EIP) de la cuenta de laboratorio.
3.  **Detergistration Delay a 0s**: Al borrar el entorno (`destroy.sh`), el script disminuye el tiempo de vaciado de conexiones (draining) de ALB a `0` para que el borrado de las instancias y el ASG sea inmediato en lugar de tardar 5 minutos.
4.  **Auto-inicialización de Base de Datos**: La app web Flask realiza un bootstrap de base de datos a nivel de módulo (`init_db()`), asegurando que la base de datos `appdb` y la tabla `users` existan en RDS MySQL en su primer arranque antes de recibir tráfico de Gunicorn.
5.  **Requisitos Compatibles**: El archivo `requirements.txt` se ha restringido con `flask<3.0`, `gunicorn<22.0` y `cryptography` para ser 100% compatible con Python 3.7 nativo de Amazon Linux 2.

## Estructura

```
app3/
├── README.md              # este documento
├── src/
│   └── web/
│       ├── app.py         # aplicación Flask con Bootstrap de DB y /health
│       └── requirements.txt
└── deploy/
    ├── common.sh          # variables y helpers compartidos
    ├── deploy.sh          # despliega los 12 recursos (VPC, ALB, ASG, RDS...)
    └── destroy.sh         # destruye todo en orden seguro
```

## Requisitos

- **AWS CLI v2** configurado con un perfil activo.
- **Comandos**: `jq`, `zip`, `bash` 4+.

## Despliegue

```bash
cd app3/deploy

# Variables (con defaults adaptados a Vocareum)
export PREFIX=aws-obs-app3
export DB_PASSWORD=App3Pass123!
export INSTANCE_TYPE=t3.micro
export MIN_SIZE=1
export MAX_SIZE=2
export DESIRED_CAPACITY=1

./deploy.sh
```

El script imprime al final la DNS del balanceador de carga, el endpoint de base de datos RDS y el nombre del ASG.

## Uso

```bash
# 1. Comprobar salud del balanceador y conexion a base de datos
curl -i http://<ALB-DNS>/health

# 2. Consultar la lista de usuarios vacia
curl -s http://<ALB-DNS>/

# 3. Crear un usuario de prueba
curl -s -X POST http://<ALB-DNS>/users -d "username=enrique" -d "email=enrique@example.com"
```

## Limpieza

Para eliminar por completo todos los recursos creados en AWS (ASG, Launch Template, ALB, RDS, SGs, NAT Gateway y VPC):

```bash
./destroy.sh
```
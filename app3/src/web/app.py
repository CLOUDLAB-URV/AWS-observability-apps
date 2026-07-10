import os
import sys
import json
import datetime
import boto3
from botocore.exceptions import ClientError
from flask import Flask, request, jsonify, render_template_string

app = Flask(__name__)

TABLE_NAME = os.environ.get('TABLE_NAME', 'aws-obs-app3-users')
REGION = os.environ.get('AWS_DEFAULT_REGION', 'us-east-1')

dynamodb = boto3.resource('dynamodb', region_name=REGION)
table = dynamodb.Table(TABLE_NAME)

HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>App3 - Auto-scaling Web App</title>
    <style>
        body { font-family: Arial, sans-serif; max-width: 800px; margin: 40px auto; padding: 20px; }
        .card { border: 1px solid #ddd; border-radius: 8px; padding: 20px; margin: 20px 0; background: #fafafa; }
        .success { border-color: #28a745; background: #d4edda; }
        .error { border-color: #dc3545; background: #f8d7da; }
        input, button { padding: 10px; margin: 5px; }
        button { background: #007bff; color: white; border: none; border-radius: 4px; cursor: pointer; }
        button:hover { background: #0056b3; }
        pre { background: #f8f9fa; padding: 10px; overflow-x: auto; }
    </style>
</head>
<body>
    <h1>App3 - Auto-scaling Web App with DynamoDB</h1>
    
    <div class="card {% if db_status == 'ok' %}success{% else %}error{% endif %}">
        <h3>Database Status: {{ db_status.upper() }}</h3>
        <p>{{ db_message }}</p>
    </div>

    <div class="card">
        <h3>Create User</h3>
        <form method="POST" action="/users">
            <input type="text" name="username" placeholder="Username" required>
            <input type="email" name="email" placeholder="Email" required>
            <button type="submit">Create User</button>
        </form>
        {% if user_created %}
        <p style="color: green;">User created successfully!</p>
        {% endif %}
    </div>

    <div class="card">
        <h3>All Users</h3>
        <pre>{{ users_json }}</pre>
    </div>
</body>
</html>
"""

def init_db():
    try:
        # Intentamos verificar si la tabla ya existe
        table.load()
        print(f"Table {TABLE_NAME} already exists.")
        return True
    except ClientError as e:
        if e.response['Error']['Code'] == 'ResourceNotFoundException':
            # La tabla no existe, la creamos
            print(f"Table {TABLE_NAME} not found. Creating table...")
            try:
                client = boto3.client('dynamodb', region_name=REGION)
                client.create_table(
                    TableName=TABLE_NAME,
                    KeySchema=[
                        {'AttributeName': 'username', 'KeyType': 'HASH'}
                    ],
                    AttributeDefinitions=[
                        {'AttributeName': 'username', 'AttributeType': 'S'}
                    ],
                    BillingMode='PAY_PER_REQUEST'
                )
                # Esperamos a que la tabla se cree
                print("Waiting for table to be active...")
                waiter = client.get_waiter('table_exists')
                waiter.wait(TableName=TABLE_NAME)
                print(f"Table {TABLE_NAME} created successfully.")
                return True
            except Exception as ex:
                print(f"Error creating table: {ex}")
                return False
        else:
            print(f"Error checking table: {e}")
            return False

@app.route('/')
def index():
    db_status = 'ok'
    db_message = f'Connected to DynamoDB Table ({TABLE_NAME})'
    users = []
    try:
        resp = table.scan()
        users = resp.get('Items', [])
    except Exception as e:
        db_status = 'error'
        db_message = f'Cannot scan DynamoDB table: {e}'
        users = [{'error': str(e)}]

    return render_template_string(HTML_TEMPLATE, 
                                  db_status=db_status, 
                                  db_message=db_message,
                                  users_json=json.dumps(users, indent=2, default=str),
                                  user_created=False)

@app.route('/users', methods=['POST'])
def create_user():
    username = request.form.get('username')
    email = request.form.get('email')
    
    try:
        table.put_item(
            Item={
                'username': username,
                'email': email,
                'created_at': datetime.datetime.utcnow().isoformat() + 'Z'
            }
        )
        user_created = True
    except Exception as e:
        return f"Error creating user: {e}", 500
    
    users = []
    try:
        resp = table.scan()
        users = resp.get('Items', [])
    except Exception as e:
        users = [{'error': str(e)}]
        
    return render_template_string(HTML_TEMPLATE,
                                  db_status='ok',
                                  db_message=f'Connected to DynamoDB Table ({TABLE_NAME})',
                                  users_json=json.dumps(users, indent=2, default=str),
                                  user_created=user_created)

@app.route('/health')
def health():
    try:
        table.scan(Limit=1)
        return jsonify({"status": "healthy", "database": "connected"}), 200
    except Exception as e:
        return jsonify({"status": "unhealthy", "database": f"disconnected: {e}"}), 503

if __name__ == '__main__':
    init_db()
    app.run(host='0.0.0.0', port=8000)
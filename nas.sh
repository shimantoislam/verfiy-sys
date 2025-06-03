#!/bin/bash
set -e

echo "📦 Setting up Portable Pi NAS Server..."

### CONFIG ###
NAS_DIR="/home/pi/nas"
MOUNT_DIR="/media/usb"
NGROK_TOKEN="2LYfTPwKmm2v7D7hGoIw76I4Gw4_6nHY8oRfu3pxrjed2upAi"  # <-- CHANGE THIS
AUTH_USER="admin"
AUTH_PASS="fuck.you"
PORT=8000
################

echo "🔧 Installing packages..."
sudo apt update
sudo apt install -y python3 python3-pip udisks2 curl git

echo "🐍 Installing Flask..."
pip3 install flask flask_httpauth psutil

echo "🌐 Installing ngrok..."
if ! command -v ngrok &> /dev/null; then
  wget -q https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-stable-linux-arm.zip
  unzip ngrok-stable-linux-arm.zip
  chmod +x ngrok
  sudo mv ngrok /usr/local/bin/
fi
ngrok config add-authtoken "$NGROK_TOKEN"

echo "📁 Creating NAS directory..."
mkdir -p "$NAS_DIR/templates" "$NAS_DIR/static"
cd "$NAS_DIR"

echo "📦 Creating Flask app..."
cat <<EOF > app.py
from flask import Flask, render_template, request, redirect, send_from_directory
from flask_httpauth import HTTPBasicAuth
from werkzeug.security import generate_password_hash, check_password_hash
import os, psutil, time, json

app = Flask(__name__)
auth = HTTPBasicAuth()
users = {"$AUTH_USER": generate_password_hash("$AUTH_PASS")}

@auth.verify_password
def verify(username, password):
    return username in users and check_password_hash(users.get(username), password)

@app.route("/")
@auth.login_required
def index():
    files = os.listdir("/media/usb")
    return render_template("index.html", files=files)

@app.route("/upload", methods=["POST"])
@auth.login_required
def upload():
    f = request.files['file']
    f.save(f"/media/usb/{f.filename}")
    return redirect("/")

@app.route("/download/<name>")
@auth.login_required
def download(name):
    return send_from_directory("/media/usb", name, as_attachment=True)

@app.route("/edit/<name>", methods=["GET", "POST"])
@auth.login_required
def edit(name):
    path = f"/media/usb/{name}"
    if request.method == "POST":
        with open(path, "w") as f:
            f.write(request.form["content"])
        return redirect("/")
    with open(path) as f:
        content = f.read()
    return render_template("edit.html", name=name, content=content)

@app.route("/monitor")
@auth.login_required
def monitor():
    return render_template("monitor.html",
        cpu=psutil.cpu_percent(),
        mem=psutil.virtual_memory().percent,
        disk=psutil.disk_usage('/').percent,
        uptime=int(time.time() - psutil.boot_time())
    )

@app.route("/wifi", methods=["GET", "POST"])
@auth.login_required
def wifi():
    if request.method == "POST":
        ssid = request.form["ssid"]
        password = request.form["password"]
        os.system(f"sudo nmcli dev wifi connect '{ssid}' password '{password}'")
        return redirect("/")
    return render_template("wifi.html")
EOF

echo "📄 Creating HTML templates..."
cat <<EOF > templates/index.html
<!DOCTYPE html><html><head><title>Pi NAS</title><link rel="stylesheet" href="/static/style.css"></head>
<body><h1>📁 File Manager</h1><form action="/upload" method="POST" enctype="multipart/form-data">
<input type="file" name="file"><button type="submit">Upload</button></form><ul>
{% for f in files %}<li>{{ f }} — <a href="/download/{{ f }}">Download</a> — <a href="/edit/{{ f }}">Edit</a></li>{% endfor %}
</ul><a href="/monitor">📊 Monitor</a> | <a href="/wifi">📶 WiFi Config</a></body></html>
EOF

cat <<EOF > templates/edit.html
<!DOCTYPE html><html><head><title>Edit {{ name }}</title><script src="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.5/codemirror.min.js"></script>
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.5/codemirror.min.css"><script src="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.5/mode/javascript/javascript.min.js"></script>
</head><body><h1>Editing {{ name }}</h1><form method="POST"><textarea id="code" name="content" rows="20" cols="80">{{ content }}</textarea><br><button type="submit">Save</button></form>
<script>var editor = CodeMirror.fromTextArea(document.getElementById("code"), {lineNumbers: true, mode: "javascript"});</script></body></html>
EOF

cat <<EOF > templates/monitor.html
<!DOCTYPE html><html><head><title>Monitor</title></head><body>
<h1>📊 System Monitor</h1><ul><li>CPU: {{ cpu }}%</li><li>RAM: {{ mem }}%</li><li>Disk: {{ disk }}%</li><li>Uptime: {{ uptime }}s</li></ul>
<a href="/">← Back</a></body></html>
EOF

cat <<EOF > templates/wifi.html
<!DOCTYPE html><html><head><title>WiFi Config</title></head><body>
<h1>📶 Change WiFi</h1><form method="POST"><input name="ssid" placeholder="SSID"><input name="password" placeholder="Password"><button>Save</button></form><a href="/">← Back</a></body></html>
EOF

cat <<EOF > static/style.css
body { font-family: sans-serif; padding: 20px; }
input, button, textarea { margin: 5px; padding: 8px; font-size: 16px; }
ul { list-style: none; padding: 0; }
li { margin-bottom: 8px; }
EOF

echo "🧠 Creating systemd service..."
sudo tee /etc/systemd/system/pinas.service > /dev/null <<EOF
[Unit]
Description=Pi NAS
After=network.target

[Service]
ExecStart=/usr/bin/python3 $NAS_DIR/app.py
WorkingDirectory=$NAS_DIR
Restart=always
User=pi

[Install]
WantedBy=multi-user.target
EOF

echo "🌍 Creating ngrok service..."
sudo tee /etc/systemd/system/ngrok.service > /dev/null <<EOF
[Unit]
Description=ngrok Tunnel
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=/bin/sleep 10
ExecStart=/usr/local/bin/ngrok http $PORT
Restart=on-failure
User=pi

[Install]
WantedBy=multi-user.target
EOF

echo "💾 Auto-mount USB rule..."
sudo tee /etc/udev/rules.d/99-usb.rules > /dev/null <<EOF
KERNEL=="sd[a-z][0-9]", ACTION=="add", RUN+="/usr/bin/udisksctl mount -b /dev/%k"
EOF

echo "🔄 Enabling services..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable pinas
sudo systemctl enable ngrok

echo "✅ Starting NAS & ngrok..."
sudo systemctl restart pinas
sudo systemctl restart ngrok

sleep 8
NGROK_URL=$(curl -s http://localhost:4040/api/tunnels | grep -oE 'https://[0-9a-zA-Z]+\.ngrok.io' | head -n 1)
LOCAL_IP=$(hostname -I | cut -d' ' -f1)

echo
echo "✅ SETUP COMPLETE!"
echo "📁 Local:  http://$LOCAL_IP:$PORT"
echo "🌍 Remote: $NGROK_URL"
echo "🔐 Username: $AUTH_USER"
echo "🔐 Password: $AUTH_PASS"

import os
import pymysql
from flask import Flask, request, jsonify

app = Flask(__name__)


def get_db():
    return pymysql.connect(
        host=os.environ['DB_HOST'],
        port=int(os.environ['DB_PORT']),
        user=os.environ['DB_USERNAME'],
        password=os.environ['DB_PASSWORD'],
        database=os.environ['DB_NAME'],
        cursorclass=pymysql.cursors.DictCursor
    )


@app.route('/')
def index():
    return '''<!DOCTYPE html>
<html>
<head><title>Guestbook</title></head>
<body>
  <h1>Guestbook</h1>
  <div id="entries"></div>
  <form id="form">
    <input type="text" id="message" placeholder="Leave a message..." required>
    <button type="submit">Submit</button>
  </form>
  <script>
    async function load() {
      const res = await fetch('/messages');
      const entries = await res.json();
      const div = document.getElementById('entries');
      div.innerHTML = '';
      entries.forEach(e => {
        const p = document.createElement('p');
        p.textContent = e.message;
        div.appendChild(p);
      });
    }

    document.getElementById('form').addEventListener('submit', async e => {
      e.preventDefault();
      const input = document.getElementById('message');
      await fetch('/messages', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({message: input.value})
      });
      input.value = '';
      load();
    });

    load();
  </script>
</body>
</html>'''


@app.route('/messages', methods=['GET'])
def get_messages():
    db = get_db()
    try:
        with db.cursor() as cursor:
            cursor.execute('SELECT id, message, created_at FROM entries ORDER BY created_at DESC')
            entries = cursor.fetchall()
        for entry in entries:
            entry['created_at'] = entry['created_at'].isoformat()
        return jsonify(entries)
    finally:
        db.close()


@app.route('/messages', methods=['POST'])
def post_message():
    data = request.get_json()
    db = get_db()
    try:
        with db.cursor() as cursor:
            cursor.execute('INSERT INTO entries (message) VALUES (%s)', (data['message'],))
            db.commit()
            cursor.execute('SELECT id, message, created_at FROM entries WHERE id = %s', (cursor.lastrowid,))
            entry = cursor.fetchone()
        entry['created_at'] = entry['created_at'].isoformat()
        return jsonify(entry), 201
    finally:
        db.close()


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)

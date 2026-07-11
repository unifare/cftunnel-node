import http.server, ssl, os

PORT = 9091
DIR = '/opt/proxy/sub'
CERT = '/opt/proxy/fullchain.pem'
KEY = '/opt/proxy/privkey.pem'

class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=DIR, **kw)
    def log_message(self, f, *a):
        pass

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(CERT, KEY)
httpd = http.server.HTTPServer(('0.0.0.0', PORT), H)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()

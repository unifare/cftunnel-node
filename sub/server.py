import http.server, os
PORT = 9091
DIR = '/opt/proxy/sub'

class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=DIR, **kw)
    def log_message(self, f, *a):
        pass

http.server.HTTPServer(('0.0.0.0', PORT), H).serve_forever()

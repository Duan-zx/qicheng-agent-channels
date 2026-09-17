"""A guest-loopback TCP forward to the same port on Docker Desktop's host.
Preserves Host/Origin and never exposes a new Windows/LAN listener.
"""
import argparse
import select
import socket
import socketserver

def server_for(port, target_host='host.docker.internal', target_port=None):
    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            try:
                with socket.create_connection((target_host,target_port or port),timeout=10) as upstream:
                    while True:
                        ready,_,_=select.select([self.request,upstream],[],[],30)
                        if not ready: return
                        for incoming in ready:
                            data=incoming.recv(65536)
                            if not data:return
                            (upstream if incoming is self.request else self.request).sendall(data)
            except (OSError,TimeoutError):return
    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address=True
        daemon_threads=True
    return Server(('127.0.0.1',port),Handler)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,required=True)
    args=parser.parse_args()
    if not 1024<=args.port<=65535 or args.port==8080:parser.error('Use an unprivileged preview port other than 8080')
    with server_for(args.port) as server: server.serve_forever()

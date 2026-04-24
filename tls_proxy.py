"""
TLS-terminating proxy: accepts HTTPS CONNECT from clients,
forwards plain TCP to mitmproxy at 127.0.0.1:8081.

Client config: HTTPS_PROXY=https://hxe.7hu.cn:8443
GFW sees TLS SNI=hxe.7hu.cn, CONNECT target is inside encrypted TLS.
"""
import ssl, socket, threading, sys, os, signal

LISTEN_HOST = '0.0.0.0'
LISTEN_PORT = int(os.environ.get('TLS_PROXY_PORT', '8443'))
UPSTREAM_HOST = '127.0.0.1'
UPSTREAM_PORT = int(os.environ.get('UPSTREAM_PORT', '8081'))
CERT_FILE = os.path.join(os.path.dirname(__file__), 'tls_proxy.crt')
KEY_FILE  = os.path.join(os.path.dirname(__file__), 'tls_proxy.key')


def relay(src, dst, label=''):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try: s.shutdown(socket.SHUT_RDWR)
            except: pass
            try: s.close()
            except: pass


def handle(client_sock):
    try:
        upstream = socket.create_connection((UPSTREAM_HOST, UPSTREAM_PORT), timeout=10)
    except OSError as e:
        client_sock.close()
        return
    t1 = threading.Thread(target=relay, args=(client_sock, upstream), daemon=True)
    t2 = threading.Thread(target=relay, args=(upstream, client_sock), daemon=True)
    t1.start()
    t2.start()


def main():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT_FILE, KEY_FILE)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((LISTEN_HOST, LISTEN_PORT))
    srv.listen(128)
    print(f"TLS proxy listening on {LISTEN_PORT} → mitmproxy {UPSTREAM_PORT}", flush=True)

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    while True:
        try:
            conn, addr = srv.accept()
        except OSError:
            break
        try:
            tls_conn = ctx.wrap_socket(conn, server_side=True)
        except (ssl.SSLError, OSError):
            conn.close()
            continue
        threading.Thread(target=handle, args=(tls_conn,), daemon=True).start()


if __name__ == '__main__':
    main()

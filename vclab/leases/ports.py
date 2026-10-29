"""Пул портов аренд (по умолчанию 25600–25699): занятость = запись в реестре + проверка bind на 127.0.0.1."""
import socket
import threading


def port_free(port, host="127.0.0.1"):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind((host, port))
        return True
    except OSError:
        return False
    finally:
        s.close()


class PortPool:
    def __init__(self, first, last):
        self.first, self.last = first, last
        self.used = {}          # port -> owner (lease name)
        self.lock = threading.Lock()

    def reserve(self, owner, port):
        with self.lock:
            self.used[int(port)] = owner

    def allocate(self, owner):
        with self.lock:
            for port in range(self.first, self.last + 1):
                if port in self.used:
                    continue
                if port_free(port):
                    self.used[port] = owner
                    return port
        raise RuntimeError("no free port in %d-%d" % (self.first, self.last))

    def release_owner(self, owner):
        with self.lock:
            for p in [p for p, o in self.used.items() if o == owner]:
                del self.used[p]

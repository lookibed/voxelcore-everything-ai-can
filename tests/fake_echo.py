"""Эхо-экземпляр для `lab stdin`: до готовности пишет в stdout ~1.6 МиБ строк (лог длиннее окна read_tail 512 КиБ, как у
сервера мира после долгого прогона), потом на каждую строку stdin отвечает «pong <строка>»; «fill N» сначала печатает
N строк; «stop» — выход 0."""
import sys

PAD = "x" * 100
out = sys.stdout
for i in range(15000):
    out.write("pad %06d %s\n" % (i, PAD))
out.write("echo ready\n")
out.flush()
for line in sys.stdin:
    cmd = line.strip()
    if cmd == "stop":
        sys.exit(0)
    if cmd.startswith("fill "):
        for i in range(int(cmd[5:])):
            out.write("fill %06d %s\n" % (i, PAD))
    out.write("pong %s\n" % cmd)
    out.flush()

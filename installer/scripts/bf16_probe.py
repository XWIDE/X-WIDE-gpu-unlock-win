# BF16 / FP16 real-matmul throughput probe for the gpu-unlock gate.
# Prints TFLOPS so the panel can say unlocked vs locked with a number, not a hex dump.
import time, sys

try:
    import torch
except Exception as e:
    print("torch import failed:", e)
    sys.exit(1)

if not torch.cuda.is_available():
    print("no CUDA device visible to torch")
    sys.exit(1)

n = int(sys.argv[1]) if len(sys.argv) > 1 else 4096
reps = 40
warm = 8
name = torch.cuda.get_device_name(0)
print("device:", name)
print("torch:", torch.__version__, "cuda:", torch.version.cuda)


def bench(dtype, label):
    torch.manual_seed(0)
    a = torch.randn(n, n, device="cuda", dtype=torch.float32).to(dtype)
    b = torch.randn(n, n, device="cuda", dtype=torch.float32).to(dtype)
    for _ in range(warm):
        c = a @ b
    torch.cuda.synchronize()
    t0 = time.perf_counter()
    for _ in range(reps):
        c = a @ b
    torch.cuda.synchronize()
    dt = (time.perf_counter() - t0) / reps
    tflops = (2.0 * n * n * n) / dt / 1e12
    print("%s n=%d  %.3f ms  %.2f TFLOPS" % (label, n, dt * 1e3, tflops))
    del a, b, c
    torch.cuda.empty_cache()


bench(torch.bfloat16, "BF16")
bench(torch.float16, "FP16")
print("done")

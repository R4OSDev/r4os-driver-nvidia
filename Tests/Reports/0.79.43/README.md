# 0.79.43 targeted stability checks

2026-09-21; software/model evidence. Windows uses Build.bat with the same arguments.

```text
./Build.sh unit-test '-Dstorage-test-filter=retains private and public failures' --summary all
./Build.sh unit-test '-Dstorage-test-filter=complete run lease' --summary all
Two existing grouped cases, one test passed per command. Includes firmware
read loss/short read/deadline plus failed cleanup; native owner fixture covers
missing IRQ/notifier, malformed receiver data, VRAM budget rejection, reset,
resource retention, per-generation IRQ retirement and deferred physical ACK.
The large native case runs in 7 seconds after compilation. These are host
models of production owners, never physical GPU execution or reset evidence.
No NVIDIA artifact change.
```

Full software scope and physical exclusions: workspace Docs/Deployment/GrafikStabilitaet07943.txt.

{{- if eq .Node.Host "rpi-00" }}
# rpi-00-specific modules must merge before the shared list in 14-* to
# preserve talhelper's original `machine.kernel.modules` ordering.
machine:
  kernel:
    modules:
      - name: vc4
      - name: v3d
{{- end }}

@echo off
rem Local VNC port to the omarchy VM console. Connect a VNC client to localhost:5901
rem within 60 seconds or the proxy exits. Ctrl+C ends the session.
set "KUBECONFIG=%USERPROFILE%\.kube\turing-config"
virtctl vnc --proxy-only --port 5901 omarchy -n vms

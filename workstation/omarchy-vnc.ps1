# Open a local VNC port to the omarchy VM's console, then connect any VNC
# client (MobaXterm's built-in one works) to localhost:5901.
# Leave this window open while connected; Ctrl+C ends the session.
$env:KUBECONFIG = "$env:USERPROFILE\.kube\turing-config"
virtctl vnc --proxy-only --port 5901 omarchy -n vms

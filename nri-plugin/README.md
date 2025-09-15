## Kerberos auth NRI plugin

## Testing

You can test this plugin using a Kubernetes cluster/node with a container runtime that has NRI support enabled ([Enabling NRI in Containerd](https://github.com/containerd/containerd/blob/main/docs/NRI.md#enabling-nri-support-in-containerd)).

## Deployment

`go build ./kerberos.go` and put it in NRI plugin directory, as configured in `containerd/config.toml`, for example `/opt/nri/plugins`.

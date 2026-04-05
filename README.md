# podman-wireguard
Hint: This is IPv4 only. Remove all IPv6 stuff from the wireguard-config!

Current `entrypoint.sh` assumptions for strict mode (egress only through `wg0` + killswitch):
- Use a literal IPv4 `Endpoint` (`Endpoint = x.x.x.x:51820`), not a hostname.
- Use a single peer endpoint for this gateway container.

## Wireguard container
- Entrypoint: `container/entrypoint.sh`
- Dockerfile: `container/Dockerfile`

### Build it all together
``` sh
podman build --pull --no-cache --tag localhost/wg-gateway-image -f container/Dockerfile .
```

## Network container
This is IPv4 only. Remove all IPv6 settings from your WireGuard config before proceeding.

**Note**: If your setup supports it, you can use `--userns=auto` instead of explicit `--uidmap`/`--gidmap` for simpler user namespace isolation.

### Rootless

[Pasta](https://passt.top/passt/about/) provides excellent network isolation for rootless containers.

```sh
podman run --name wg-gateway \
  --detach \
  --replace \
  --pull never \
  --cap-drop ALL \
  --cap-add NET_ADMIN \
  --ipc=none \
  --security-opt no-new-privileges:true \
  --network pasta:--no-map-gw,-t,none,-u,none,-T,none,-U,none,--no-tcp,--no-icmp,--no-dhcp,--no-dhcpv6,--no-ndp,--no-ra,-4,-D,none,-S,none \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  --sysctl net.ipv6.conf.all.disable_ipv6=1 \
  --sysctl net.ipv6.conf.default.disable_ipv6=1 \
  --uidmap 0:10000:64 \
  --gidmap 0:10000:64 \
  --volume "$PWD"/wg0.conf:/etc/wireguard/wg0.conf:ro \
  localhost/wg-gateway-image
```

### Rootful

Rootful mode requires an isolated bridge network to prevent unintended host access.

Create the network first:

```sh
podman network create \
  --subnet 172.20.0.0/16 \
  --disable-dns \
  --opt isolate=true \
  wg-gateway-net
```

Then run the container:

```sh
podman run --name wg-gateway \
  --detach \
  --replace \
  --pull never \
  --cap-drop ALL \
  --cap-add NET_ADMIN \
  --ipc=none \
  --network wg-gateway-net \
  --security-opt no-new-privileges:true \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  --sysctl net.ipv6.conf.all.disable_ipv6=1 \
  --sysctl net.ipv6.conf.default.disable_ipv6=1 \
  --uidmap 0:100000:64 \
  --gidmap 0:100000:64 \
  --volume "$PWD"/wg0.conf:/etc/wireguard/wg0.conf:ro \
  localhost/wg-gateway-image
```

## Testing

Run a simple test. This should return the IP of your VPN.

```sh
podman run --rm --net=container:wg-gateway docker.io/curlimages/curl -skL --max-time 2 icanhazip.com
```

## Cleanup

Remove the container and image when you are done:

```sh
podman rm -f wg-gateway
podman rmi -f localhost/wg-gateway-image
```

If you created the rootful network, remove it as well:

```sh
podman network rm -f wg-gateway-net
```

## Extra hardening
 
The following options can be combined freely. Add them to your `podman run` command as needed.
 
### Syscall filtering
 
Restrict the container to a predefined set of allowed syscalls:
 
```sh
--security-opt seccomp=/usr/share/containers/seccomp.json
```
 
### Resource limits
 
Prevent resource exhaustion by capping memory and process count:
 
```sh
--pids-limit 10 \
--memory 10m \
--memory-swap 10m
```
 
### Read-only containers
 
Mount the container's root filesystem as read-only:
 
```sh
--read-only
```
 
If the container needs a writable temp directory, add a locked-down `tmpfs`:
 
```sh
--tmpfs /tmp:rw,noexec,nosuid,size=16M
```
 
#### DNS on read-only containers
`--dns` on `--net=container:...` is not supported by Podman - that's why we need workarounds.
 
**Option 1 - Via WireGuard config** (`entrypoint.sh` writes DNS from the `[Interface]` block):
 
```sh
echo -n > resolv.conf && chmod 666 resolv.conf
```

`chmod 666` is required so the container can write `/etc/resolv.conf` even with user namespace mappings.
 
```sh
--volume "$PWD"/resolv.conf:/etc/resolv.conf
```
 
**Option 2 - Manual static DNS** (set servers explicitly, skip config-based setup):
 
```sh
--dns 1.1.1.1 \
--dns 8.8.8.8 \
--dns 9.9.9.9 \
--env SKIP_DNS=1
```

`entrypoint.sh` treats `SKIP_DNS=1` and `SKIP_DNS=TRUE` as enabled.
 
**Override DNS for a single sidecar container:**
 
```sh
podman run --rm \
  --net=container:wg-gateway \
  --volume "$PWD"/resolv.conf:/etc/resolv.conf:U,ro \
  docker.io/curlimages/curl -skL --max-time 2 icanhazip.com
```

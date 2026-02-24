getting this error 
```
╷
│ Error: Could not find docker network: Error response from daemon: client version 1.41 is too old. Minimum supported API version is 1.44, please upgrade your client to a newer version
│
│   with data.docker_network.kind,
│   on main.tf line 97, in data "docker_network" "kind":
│   97: data "docker_network" "kind" {
│
╵
```
tried to do this but it didnt worke
```
export DOCKER_API_VERSION="1.44"
```

after that i ran
```
echo "DOCKER_API_VERSION=$DOCKER_API_VERSION" && docker version --format '{{json .}}' 2>/dev/null | jq '{ClientAPI: .Client.ApiVersion, ServerAPI: .Server.ApiVersion, ServerMinAPI: .Server.MinAPIVersion}' 2>/dev/null || docker version 2>&1 | head -20
```

and got this
```
DOCKER_API_VERSION=
CWD: /home/sendev/Code/nebari
ClientAPI: 1.53
ServerAPI: 1.53
ServerMinAPI: 1.44
```
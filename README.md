Automatic personal projects deployment

## Setup

```
.
├── configs
│   ├── projects.yaml
│   └── servers.yaml
├── keys
│   └── server1.key
├── prax.sh
```

### set github username in GECOS field
- any would do:
```
sudo chfn -f "Prabesh Sapkota" -o "prabesh01" -p "123-456-7890" $USER
sudo chfn -f "prabesh01" -o "" -p "" $USER
sudo chfn -f "" -o "prabesh01" -p "" $USER
```

### GET github PAT token with write:packages scope
- Store it in .env: `cp .env.example .env`
- Login to docker via ghcr.io: `docker login ghcr.io`

### servers.yaml
- Enter server details in config/servers.yaml. Optional: user & key
  > servers and keys setup is optional if it is already configred in system's `~/.ssh/config`
```
- name: sname
  ip: x.x.x.x
  user: ubuntu
  key: server1.key
```

### keys/
- Put servers' ssh keys in keys/ directory and use the filename in servers config above.

### projects.yaml
- Enter the projects details in config/projects.yml. 
```
- name: statamic
  repo: git@github.com:Prabesh01/statamic-cool-writing-customized.git
  server: sname
```

## Usage
```
./prax.sh
usage: ./prax.sh list
       ./prax.sh deploy all | ./prax.sh deploy project1 project2 ...
```

## Expose cardano-node's socket to host machine

1. Clone [cardano-db-sync](https://github.com/input-output-hk/cardano-db-sync/), change docker-compose.yaml =volumes= section to following:
   ```yaml
   volumes:
     db-sync-data:
     postgres:
     node-db:
     node-ipc:
       driver: local
       driver_opts:
         o: bind
         type: none
         device: ./node-ipc
   ```

   This exposes the "node-ipc" volume (inside which the socket is) on
   the host machine's filesystem.

2. Create host folder for the bind mount: `mkdir node-ipc`

3. If you already ran `docker-compose` with the old `docker-compose.yaml` config, then you need to
   delete old containers and volumes for the new configuration to take effect.
   Therefore, you would need to do something along the lines of:

   ```sh
   $ docker-compose down && docker container prune && docker volume prune
   ```

4. Run `docker-compose up -d && docker-compose logs -f` to run the containers

5. Change socket owner to yourself: `sudo chown your-user node-ipc/node.socket` (it's root otherwise)

6. Run any indexer on the socket, which is now in ./node-ipc/node.socket

(The ./node-ipc folder specified in docker-compose.yaml can be any path)

## Expose cardano-node's config (for indexers that need it)

On Linux the path can be found with:
```bash
mount | grep overlay | awk '{print $3}' | xargs -I{} sudo find {} -path "*mainnet-config.json" -type f
```

It can also be extracted from within the container with:
```
  CARDANO_NODE_CONTAINER_ID="$(docker ps|grep cardano-node|awk '{print $1}')"
  docker exec $CARDANO_NODE_CONTAINER_ID cat /opt/cardano/config/mainnet-config.json > ./mainnet-config.json
```

## Access postgres

- database is accessible at localhost port 5432
- Credentials are in cardano-db-sync's repo in config/secrets

E.g:
```bash
PGPASSWORD="$(cat ./config/secrets/postgres_password)" \
          psql --user postgres --host localhost
```

---
id: ironframe.how-to.bind-environments
kind: how-to
title: Bind environments
---
# Bind environments

Say, per environment, whether each dependency is the real provider or a
LawTwin twin, and who deploys each application. ref:DEC-calm-resolution

1. Declare the environment with an `ironframe-environment` decorator on the
   system node:

   ```json
   { "unique-id": "twin-environment", "type": "ironframe-environment", "target": ["shop.calm.json"],
     "applies-to": ["calm-shop"],
     "data": { "environment": "twin", "project": "calm-shop", "runtime": "podman",
               "sync": [{ "env_file": { "path": "../app/.env" } }] } }
   ```

2. Bind every dependency node in it with an `ironframe-binding` decorator.
   The real provider:

   ```json
   "data": { "environment": "real",
             "real": { "endpoint": "localhost:9092", "image": "apache/kafka:4.1.0", "ports": [9092],
                       "provider": { "name": "apache/kafka", "version": "4.1.0" } } }
   ```

   A twin, saying which contract it stands in for:

   ```json
   "data": { "environment": "twin",
             "twin": { "image": "lawtwin/kafka", "version": "0.1.0",
                       "stands-in-for": { "package": "lawtwin.kafka", "version": "0.1.0",
                                          "abilities": ["lawtwin.kafka::ability::Broker"] },
                       "conformance": { "report": "conformance/lawtwin-kafka-0.1.0.json" },
                       "ports": [9092], "seed": 42, "admin": { "port": 9644 } } }
   ```

   Mixed environments bind some nodes real and others twin; a node two
   applications reach is one shared dependency, one twin or one provider.

3. Optionally say how an application is deployed: by default its own tooling
   does, reading the settings Ironframe syncs (`external`); or Ironframe runs
   it, as a process or an image (`managed`). ref:DEC-calm-deployment

   ```json
   "data": { "environment": "twin",
             "application": { "managed": { "process": { "command": ["go", "run", "./cmd/shop", "audit"], "dir": "../app" } } } }
   ```

4. Resolve it: `ironframe resolve shop.calm.json --env twin`. Ironframe
   prints the topology, or refuses with every unresolved, ambiguous or
   incompatible binding named. A twin whose `stands-in-for` has another
   package, a version outside the node's range, a missing ability or a
   conformance level the node does not accept is incompatible.
   ref:DEC-calm-refusals ref:DEC-calm-compatibility

5. Bring it up, as with a manifest: `ironframe -a shop.calm.json up twin`.
   Ironframe writes the topology to `.ironframe/twin/topology.json`, starts the
   twins and real images with podman, sets each twin up through its control
   plane and syncs the settings.

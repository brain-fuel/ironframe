---
id: ironframe.how-to.model-an-architecture
kind: how-to
title: Model an architecture
---
# Model an architecture

Describe an application and its dependencies as a CALM 1.2 architecture, and
give each element the LawSpec contract it stands for. ref:DEC-calm-architecture
ref:DEC-calm-decorators

1. Write the architecture, `shop.calm.json`: a node per application and per
   dependency, a `connects` relationship from each application to each
   dependency it reaches, and, if you like, a `system` node composed of them.

   ```json
   {
     "$schema": "https://calm.finos.org/release/1.2/meta/calm.json",
     "unique-id": "calm-shop",
     "nodes": [
       { "unique-id": "adoptions-service", "node-type": "service", "name": "Adoptions service", "description": "Registers pets and publishes adoptions." },
       { "unique-id": "adoptions-log", "node-type": "message-broker", "name": "Adoptions log", "description": "The Kafka cluster." }
     ],
     "relationships": [
       {
         "unique-id": "service-publishes-adoptions",
         "protocol": "TCP",
         "relationship-type": { "connects": { "source": { "node": "adoptions-service" }, "destination": { "node": "adoptions-log" } } }
       }
     ]
   }
   ```

   A dependency node's unique-id names it in settings and cloud resources, so
   it is lowercase letters, digits and `-`.

2. Write `shop.decorators.json` beside it with a contract for each element
   ([CALM decorators](../reference/calm-decorators.md)):

   - on the application node, the LawSpec package its laws are in:
     `{"application": {"package": "shop.adoptions", "version": "0.1.0"}}`;
   - on each dependency node, the contract its binding must satisfy:
     `{"dependency": {"package": "lawtwin.kafka", "version": ">=0.1.0, <0.2.0",
     "abilities": ["lawtwin.kafka::ability::Broker"], "conformance":
     {"accept": ["answers", "exact"]}}}`;
   - on each `connects` relationship, the application's abilities whose
     production handler reaches the dependency, and the settings the
     application reads:
     `{"connection": {"consumes": ["shop.adoptions::ability::Adoptions"],
     "settings": {"KAFKA_BOOTSTRAP_SERVERS": "${endpoint}"}}}`.

   The `consumes` identities are the abilities LawSpec reports a law's
   production handlers by, `unit::ability::Name`: `lawspec check --json`
   shows each law's `handlers`.

3. Check it: `ironframe -a shop.calm.json validate`. With the CALM CLI
   installed (`npm install -g @finos/calm-cli`), add `--calm-cli` to run
   `calm validate` too. ref:calm-cli

Next, [bind environments](bind-environments.md).

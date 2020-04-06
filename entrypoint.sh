#!/bin/sh

[ -z "${MQ_USER}" ] && echo 'Environment variable MQ_USER is empty' 1>&2 && exit 1
[ -z "${MQ_PASSWORD_HASH}" ] && echo 'Environment variable MQ_PASSWORD_HASH is empty' 1>&2 && exit 1
[ -z "${CEGA_CONNECTION}" ] && echo 'Environment variable CEGA_CONNECTION is empty' 1>&2 && exit 1

if [ -z "${MQ_SERVER_CERT}" ] || [ -z "${MQ_SERVER_KEY}" ]; then
SSL_SUBJ="/C=SE/ST=Sweden/L=Uppsala/O=NBIS/OU=SysDevs/CN=LocalEGA"
mkdir -p "${HOME}/ssl"
# Generating the SSL certificate + key
openssl req -x509 -newkey rsa:2048 \
    -keyout "${HOME}/ssl/mq-server.key" -nodes \
    -out "${HOME}/ssl/mq-server.pem" -sha256 \
    -days 1000 -subj "${SSL_SUBJ}"
fi

cat >> "/var/lib/rabbitmq/rabbitmq.conf" <<EOF
listeners.ssl.default = 5671
ssl_options.cacertfile = ${MQ_CA:-/etc/ssl/certs/ca-certificates.crt}
ssl_options.certfile = ${MQ_SERVER_CERT:-/var/lib/rabbitmq/ssl/mq-server.pem}
ssl_options.keyfile = ${MQ_SERVER_KEY:-/var/lib/rabbitmq/ssl/mq-server.key}
ssl_options.verify = ${MQ_VERIFY:-verify_peer}
ssl_options.fail_if_no_peer_cert = true
ssl_options.versions.1 = tlsv1.2
disk_free_limit.absolute = 1GB
management.listener.port = 15672
management.load_definitions = /var/lib/rabbitmq/definitions.json
default_vhost = ${MQ_VHOST:-/}
EOF

chmod 600 "/var/lib/rabbitmq/rabbitmq.conf"

cat > "/var/lib/rabbitmq/definitions.json" <<EOF
{
  "users": [
    {
      "name": "${MQ_USER}", "password_hash": "${MQ_PASSWORD_HASH}",
      "hashing_algorithm": "rabbit_password_hashing_sha256", "tags": "administrator"
    }
  ],
  "vhosts": [
    { "name": "${MQ_VHOST:-/}" }
  ],
  "permissions": [
    { "user": "${MQ_USER}", "vhost": "${MQ_VHOST:-/}", "configure": ".*", "write": ".*", "read": ".*" }
  ],
  "parameters": [
    {
      "name": "CEGA-ids", "vhost": "${MQ_VHOST:-/}", "component": "federation-upstream",
      "value": { "ack-mode": "on-confirm", "queue": "v1.stableIDs", "trust-user-id": false, "uri": "${CEGA_CONNECTION}" }
    },
    {
      "name": "CEGA-files", "vhost": "${MQ_VHOST:-/}", "component": "federation-upstream",
      "value": { "ack-mode": "on-confirm", "queue": "v1.files", "trust-user-id": false, "uri": "${CEGA_CONNECTION}" }
    }
  ],
  "policies": [
    {
      "vhost": "${MQ_VHOST:-/}", "name": "CEGA-files", "pattern": "files", "apply-to": "queues", "priority": 0,
      "definition": { "federation-upstream": "CEGA-files" }
    },
    {
      "vhost": "${MQ_VHOST:-/}", "name": "CEGA-ids", "pattern": "stableIDs", "apply-to": "queues", "priority": 0,
      "definition": { "federation-upstream": "CEGA-ids" }
    }
  ],
  "queues": [
    {"name": "stableIDs", "vhost": "${MQ_VHOST:-/}", "durable": true, "auto_delete": false, "arguments":{}},
    {"name": "files",     "vhost": "${MQ_VHOST:-/}", "durable": true, "auto_delete": false, "arguments":{}},
    {"name": "archived",  "vhost": "${MQ_VHOST:-/}", "durable": true, "auto_delete": false, "arguments":{}}
  ],
  "exchanges": [
    {"name":"cega", "vhost":"${MQ_VHOST:-/}", "type":"topic", "durable":true, "auto_delete":false, "internal":false, "arguments":{}}, 
    {"name":"lega", "vhost":"${MQ_VHOST:-/}", "type":"topic", "durable":true, "auto_delete":false, "internal":false, "arguments":{}}
  ], 
  "bindings": [
    { "source":"lega", "vhost": "${MQ_VHOST:-/}", "destination":"archived", "destination_type":"queue", "routing_key":"archived", "arguments":{}}
  ]
}
EOF
chmod 600 "/var/lib/rabbitmq/definitions.json"

cat > "/var/lib/rabbitmq/advanced.config" <<EOF
[
  {rabbit,
    [{tcp_listeners, []}
  ]},
  {rabbitmq_shovel,
    [{shovels, [
      {to_cega,
        [{source,
          [{protocol, amqp091},
            {uris, ["amqp://"]},
            {declarations, [{'queue.declare', [{exclusive, true}]},
              {'queue.bind',
                [{exchange, <<"cega">>},
                  {queue, <<>>},
                  {routing_key, <<"#">>}
                ]}
            ]},
            {queue, <<>>},
            {prefetch_count, 10}
          ]},
          {destination,
            [{protocol, amqp091},
              {uris, ["${CEGA_CONNECTION}"]},
              {declarations, []},
              {publish_properties, [{delivery_mode, 2}]},
              {publish_fields, [{exchange, <<"localega.v1">>}]}]},
          {ack_mode, on_confirm},
          {reconnect_delay, 5}
        ]},
      {cega_completion,
        [{source,
          [{protocol, amqp091},
            {uris, ["amqp://"]},
            {declarations, [{'queue.declare', [{exclusive, true}]},
              {'queue.bind',
                [{exchange, <<"lega">>},
                  {queue, <<>>},
                  {routing_key, <<"completed">>}
                ]}
            ]},
            {queue, <<>>},
            {prefetch_count, 10}
          ]},
          {destination,
            [{protocol, amqp091},
              {uris, ["amqp://"]},
              {declarations, []},
              {publish_properties, [{delivery_mode, 2}]},
              {publish_fields, [{exchange, <<"cega">>},
                {routing_key, <<"files.completed">>}
              ]}
            ]},
          {ack_mode, on_confirm},
          {reconnect_delay, 5}
        ]}
    ]}
    ]}
].
EOF
chmod 600 "/var/lib/rabbitmq/advanced.config"

exec "$@"

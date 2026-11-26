local kap = import 'lib/kapitan.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.airlock_microgateway;

local defaultConfig = std.get(params.default, 'redisSecretSync', {});

local instanceConfig(name) = std.get(params.instances[name], 'redisSecretSync', {});

local config(name) = std.mergePatch(
  defaultConfig,
  instanceConfig(name)
);

local requiredKeys = [ 'REDIS_PASSWORD', 'ca.crt', 'tls.crt', 'tls.key' ];

local secretsOf(cfg) = if std.get(cfg, 'secrets', null) == null then {} else cfg.secrets;

local entries(cfg) = [
  {
    prefix: prefix,
    source: secretsOf(cfg)[prefix],
  }
  for prefix in std.sort(std.objectFields(secretsOf(cfg)))
  if secretsOf(cfg)[prefix] != null
];

local sourceNames(cfg) = std.set([ entry.source for entry in entries(cfg) ]);

local sourceIndex(cfg) =
  local names = sourceNames(cfg);
  {
    [names[i]]: i
    for i in std.range(0, std.length(names) - 1)
  };

local sourceContextName(cfg, sourceName) = 'source_secret_%d' % sourceIndex(cfg)[sourceName];

local sourceRefs(cfg) = [
  {
    name: name,
    context: sourceContextName(cfg, name),
  }
  for name in sourceNames(cfg)
];

local targets(cfg) = [
  target
  for entry in entries(cfg)
  for target in [
    {
      name: '%s-password' % entry.prefix,
      source: entry.source,
      type: 'Opaque',
      data: { 'redis.password': 'REDIS_PASSWORD' },
    },
    {
      name: '%s-ca' % entry.prefix,
      source: entry.source,
      type: 'Opaque',
      data: { 'ca.crt': 'ca.crt' },
    },
    {
      name: '%s-clientcert' % entry.prefix,
      source: entry.source,
      type: 'kubernetes.io/tls',
      data: {
        'tls.crt': 'tls.crt',
        'tls.key': 'tls.key',
      },
    },
  ]
];

local serviceAccount(name, serviceAccountName) = {
  apiVersion: 'v1',
  kind: 'ServiceAccount',
  metadata: {
    name: serviceAccountName,
    namespace: name,
  },
};

local roleBinding(name, namespace, roleName, serviceAccountName) = {
  apiVersion: 'rbac.authorization.k8s.io/v1',
  kind: 'RoleBinding',
  metadata: {
    name: roleName,
    namespace: namespace,
  },
  roleRef: {
    apiGroup: 'rbac.authorization.k8s.io',
    kind: 'Role',
    name: roleName,
  },
  subjects: [
    {
      kind: 'ServiceAccount',
      name: serviceAccountName,
      namespace: name,
    },
  ],
};

local sourceRole(sourceNamespace, roleName) = {
  apiVersion: 'rbac.authorization.k8s.io/v1',
  kind: 'Role',
  metadata: {
    name: roleName,
    namespace: sourceNamespace,
  },
  rules: [
    {
      apiGroups: [ '' ],
      resources: [ 'secrets' ],
      verbs: [
        'get',
        'list',
        'watch',
      ],
    },
  ],
};

local targetRole(name, roleName) = {
  apiVersion: 'rbac.authorization.k8s.io/v1',
  kind: 'Role',
  metadata: {
    name: roleName,
    namespace: name,
  },
  rules: [
    {
      apiGroups: [ '' ],
      resources: [ 'secrets' ],
      verbs: [
        'create',
        'delete',
        'get',
        'list',
        'patch',
        'update',
        'watch',
      ],
    },
  ],
};

local sourceSecret(cfg, source) = |||
  local %(context)s =
    local sources = context.%(context)s;
    assert std.length(sources) == 1 : %(one)s;
    assert !inDelete(sources[0]) : %(deleting)s;
    assert std.all([std.objectHas(std.get(sources[0], 'data', {}), key) for key in requiredKeys]) : %(keys)s;
    sources[0];
||| % {
  context: source.context,
  one: std.manifestJson('Expected exactly one secret %s in namespace %s' % [ source.name, cfg.sourceNamespace ]),
  deleting: std.manifestJson('Secret %s in namespace %s is being deleted' % [ source.name, cfg.sourceNamespace ]),
  keys: std.manifestJson('Secret %s in namespace %s must contain keys %s' % [ source.name, cfg.sourceNamespace, std.join(', ', requiredKeys) ]),
};

local secret(cfg, target, targetNamespace) =
  local dataEntries = [
    '%s: %s.data[%s]' % [
      std.manifestJson(key),
      sourceContextName(cfg, target.source),
      std.manifestJson(target.data[key]),
    ]
    for key in std.objectFields(target.data)
  ];
  |||
    {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: {
        name: %(name)s,
        namespace: %(namespace)s,
        labels: managedBy,
      },
      data: {
        %(data)s
      },
      type: %(type)s,
    },
  ||| % {
    name: std.manifestJson(target.name),
    namespace: std.manifestJson(targetNamespace),
    data: std.join(',\n    ', dataEntries),
    type: std.manifestJson(target.type),
  };

local template(cfg, name) = |||
  local esp = import 'espejote.libsonnet';

  local context = esp.context();
  local managedBy = { 'espejote.io/managed-by': '%(managedBy)s' };
  local inDelete(obj) = std.get(obj.metadata, 'deletionTimestamp', '') != '';
  local requiredKeys = %(requiredKeys)s;
  %(sources)s
  [
  %(secrets)s
  ]
||| % {
  managedBy: '%s.redis-secret-sync' % name,
  requiredKeys: std.manifestJson(requiredKeys),
  sources: std.join('\n', [
    sourceSecret(cfg, source)
    for source in sourceRefs(cfg)
  ]),
  secrets: std.join('', [
    secret(cfg, target, name)
    for target in targets(cfg)
  ]),
};

local managedResource(name) =
  local cfg = config(name);
  local serviceAccountName = name + '-redis-secret-sync';
  local sources = sourceRefs(cfg);
  {
    apiVersion: 'espejote.io/v1alpha1',
    kind: 'ManagedResource',
    metadata: {
      name: 'redis-secret-sync',
      namespace: name,
      annotations: {
        description: 'Copies the redis connection secrets into the airlock-microgateway instance namespace',
      },
    },
    spec: {
      serviceAccountRef: {
        name: serviceAccountName,
      },
      context: [
        {
          name: source.context,
          resource: {
            apiVersion: 'v1',
            kind: 'Secret',
            name: source.name,
            namespace: cfg.sourceNamespace,
          },
        }
        for source in sources
      ],
      triggers:
        [
          {
            name: source.context,
            watchContextResource: {
              name: source.context,
            },
          }
          for source in sources
        ] + [
          {
            name: 'managed_secret',
            watchResource: {
              apiVersion: 'v1',
              kind: 'Secret',
              namespace: name,
              labelSelector: {
                matchLabels: {
                  'espejote.io/managed-by': '%s.redis-secret-sync' % name,
                },
              },
            },
          },
        ],
      template: template(cfg, name),
    },
  };

{
  resources(name):
    local cfg = config(name);
    if !std.get(cfg, 'enabled', false) || std.length(entries(cfg)) == 0 then []
    else
      local serviceAccountName = name + '-redis-secret-sync';
      local sourceRoleName = serviceAccountName + '-source';
      [
        serviceAccount(name, serviceAccountName),
        sourceRole(cfg.sourceNamespace, sourceRoleName),
        roleBinding(name, cfg.sourceNamespace, sourceRoleName, serviceAccountName),
        targetRole(name, serviceAccountName),
        roleBinding(name, name, serviceAccountName, serviceAccountName),
        managedResource(name),
      ],
}

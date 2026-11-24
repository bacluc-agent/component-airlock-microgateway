local kap = import 'lib/kapitan.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.airlock_microgateway;

local defaultConfig = std.get(params.default, 'redisSecretSync', {});

local instanceConfig(name) = std.get(params.instances[name], 'redisSecretSync', {});

local config(name) = std.mergePatch(
  defaultConfig,
  instanceConfig(name)
);

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

local secretsOf(cfg) = if cfg.secrets == null then {} else cfg.secrets;

local secretNames(cfg) = [
  name
  for name in std.objectFields(secretsOf(cfg))
  if secretsOf(cfg)[name] != null
];

local targetKeys(target) = [
  key
  for key in std.objectFields(target)
  if key != 'type'
];

local sourceSecretNames(cfg) = std.set([
  secretsOf(cfg)[name][key].secretName
  for name in secretNames(cfg)
  for key in targetKeys(secretsOf(cfg)[name])
]);

local sourceIndex(cfg) =
  local names = sourceSecretNames(cfg);
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
  for name in sourceSecretNames(cfg)
];

local secret(cfg, name, targetNamespace) =
  local target = secretsOf(cfg)[name];
  local dataEntries = [
    '%s: context.%s[0].data[%s]' % [
      std.manifestJson(key),
      sourceContextName(cfg, target[key].secretName),
      std.manifestJson(target[key].key),
    ]
    for key in targetKeys(target)
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
    name: std.manifestJson(name),
    namespace: std.manifestJson(targetNamespace),
    data: std.join(',\n    ', [
      '%s' % entry
      for entry in dataEntries
    ]),
    type: std.manifestJson(std.get(target, 'type', 'Opaque')),
  };

local template(cfg, name) = |||
  local esp = import 'espejote.libsonnet';

  local context = esp.context();
  local managedBy = { 'espejote.io/managed-by': '%(managedBy)s' };

  [
  %(secrets)s
  ]
||| % {
  managedBy: '%s.redis-secret-sync' % name,
  secrets: std.join('', [
    secret(cfg, secretName, name)
    for secretName in secretNames(cfg)
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
    if !std.get(cfg, 'enabled', false) then []
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

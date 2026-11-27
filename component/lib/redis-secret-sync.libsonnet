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

local targetRole(name, roleName, manageRedisProvider) = {
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
  ] + (
    if manageRedisProvider then [
      {
        apiGroups: [ 'microgateway.airlock.com' ],
        resources: [ 'redisproviders' ],
        verbs: [
          'get',
          'list',
          'patch',
          'update',
          'watch',
        ],
      },
    ] else []
  ),
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

local sourceSecret(cfg, source) = std.join('\n', [
  'local %s =' % source.context,
  '  local sources = context.%s;' % source.context,
  "  assert std.length(sources) == 1 : 'Expected exactly one secret %s in namespace %s';" % [ source.name, cfg.sourceNamespace ],
  "  assert !inDelete(sources[0]) : 'Secret %s in namespace %s is being deleted';" % [ source.name, cfg.sourceNamespace ],
  '  sources[0];',
]);

local secret(cfg, name, targetNamespace) =
  local target = secretsOf(cfg)[name];
  local dataEntries = [
    '%s: %s.data[%s]' % [
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

local updateRedisProvider(cfg) = cfg.updateRedisProvider;
local updateHost(cfg) = updateRedisProvider(cfg).host;
local updateUsername(cfg) = updateRedisProvider(cfg).username;
local manageRedisProvider(cfg) = updateHost(cfg) || updateUsername(cfg);

local providerAnnotations(cfg) =
  local pointers = (
    if updateHost(cfg) then [ '/spec/mode/standalone/host' ] else []
  ) + (
    if updateUsername(cfg) then [ '/spec/auth/username' ] else []
  );
  if std.get(cfg, 'enabled', false) && std.length(pointers) > 0 then {
    'argocd.argoproj.io/ignore-differences': 'jsonPointers:\n%s' % std.join('\n', [
      '- %s' % pointer
      for pointer in pointers
    ]),
  } else {};

local redisProviderName(redisProvider) =
  redisProvider.metadata.name;

local redisProviderApiVersion(redisProvider) =
  redisProvider.apiVersion;

local redisProviderAuthSecretName(redisProvider) =
  local auth = std.get(std.get(redisProvider, 'spec', {}), 'auth', {});
  local password = std.get(auth, 'password', {});
  local secretRef = std.get(password, 'secretRef', {});
  std.get(secretRef, 'name', '');

local providerSecretValueExpression(key, indent) =
  local message = 'The secret referenced by the RedisProvider has no non-empty key %s' % key;
  std.join('\n', [
    'assert std.objectHas(redisProviderSecret.data, %s) : %s;' % [ std.manifestJson(key), std.manifestJson(message) ],
    '%slocal value = std.base64Decode(redisProviderSecret.data[%s]);' % [ indent, std.manifestJson(key) ],
    '%sassert std.length(value) > 0 : %s;' % [ indent, std.manifestJson(message) ],
    '%svalue' % indent,
  ]);

local redisProviderPatch(cfg, name, redisProvider) =
  local fields = (
    if updateUsername(cfg) then [
      '        auth: {',
      '          username: %s,' % providerSecretValueExpression('REDIS_USERNAME', '            '),
      '        },',
    ] else []
  ) + (
    if updateHost(cfg) then [
      '        mode: {',
      '          standalone: {',
      '            host: %s,' % providerSecretValueExpression('REDIS_HOST', '              '),
      '          },',
      '        },',
    ] else []
  );
  std.join('\n', [
    '    local redisProviderSecret = context.redis_provider_secret[0];',
    '    {',
    '      apiVersion: %s,' % std.manifestJson(redisProviderApiVersion(redisProvider)),
    "      kind: 'RedisProvider',",
    '      metadata: {',
    '        name: %s,' % std.manifestJson(redisProviderName(redisProvider)),
    '        namespace: %s,' % std.manifestJson(name),
    '      },',
    '      spec: {',
  ] + fields + [
    '      },',
    '    }',
  ]);

local template(cfg, name, redisProvider) = |||
  local esp = import 'espejote.libsonnet';

  local context = esp.context();
  local managedBy = { 'espejote.io/managed-by': '%(managedBy)s' };
  local inDelete(obj) = std.get(obj.metadata, 'deletionTimestamp', '') != '';
  %(sources)s
  [
  %(secrets)s
  ]%(redisProvider)s
||| % {
  managedBy: '%s.redis-secret-sync' % name,
  sources: std.join('\n', [
    sourceSecret(cfg, source)
    for source in sourceRefs(cfg)
  ]),
  secrets: std.join('', [
    secret(cfg, secretName, name)
    for secretName in secretNames(cfg)
  ]),
  redisProvider: if manageRedisProvider(cfg) then
    '\n  + (if std.length(context.redis_provider) == 1 && std.length(context.redis_provider_secret) == 1 then [\n%s\n  ] else [])' % redisProviderPatch(cfg, name, redisProvider)
  else '',
};

local managedResource(name, redisProvider) =
  local cfg = config(name);
  local serviceAccountName = name + '-redis-secret-sync';
  local sources = sourceRefs(cfg);
  local authSecretName = redisProviderAuthSecretName(redisProvider);
  local syncsProviderSecret = std.member(secretNames(cfg), authSecretName);
  local providerContext = {
    name: 'redis_provider',
    resource: {
      apiVersion: redisProviderApiVersion(redisProvider),
      kind: 'RedisProvider',
      name: redisProviderName(redisProvider),
      namespace: name,
    },
  };
  local providerSecretContext = {
    name: 'redis_provider_secret',
    resource: {
      apiVersion: 'v1',
      kind: 'Secret',
      name: authSecretName,
      namespace: name,
    },
  };
  local providerTrigger = {
    name: 'redis_provider',
    watchResource: {
      apiVersion: redisProviderApiVersion(redisProvider),
      kind: 'RedisProvider',
      name: redisProviderName(redisProvider),
      namespace: name,
    },
  };
  local providerSecretTrigger = {
    name: 'redis_provider_secret',
    watchContextResource: {
      name: 'redis_provider_secret',
    },
  };
  {
    apiVersion: 'espejote.io/v1alpha1',
    kind: 'ManagedResource',
    metadata: {
      name: 'redis-secret-sync',
      namespace: name,
      annotations: {
        description: 'Copies the redis connection secrets into the airlock-microgateway instance namespace and updates the RedisProvider host and username',
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
      ] + (
        if manageRedisProvider(cfg) then [ providerContext, providerSecretContext ] else []
      ),
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
        ] + (
          if manageRedisProvider(cfg) then [ providerTrigger ] + (
            if syncsProviderSecret then [] else [ providerSecretTrigger ]
          ) else []
        ),
      template: template(cfg, name, redisProvider),
    },
  };

local validRedisProvider(name, redisProvider) =
  local cfg = config(name);
  assert !manageRedisProvider(cfg) || redisProviderName(redisProvider) != '' : 'redisSecretSync requires the RedisProvider to have a name';
  assert !manageRedisProvider(cfg) || redisProviderAuthSecretName(redisProvider) != '' : 'redisSecretSync requires the RedisProvider to set spec.auth.password.secretRef.name';
  true;

{
  redisProviderAnnotations(name): providerAnnotations(config(name)),
  resources(name, redisProvider):
    local cfg = config(name);
    local enabled = std.get(cfg, 'enabled', false);
    if enabled && validRedisProvider(name, redisProvider) then
      local serviceAccountName = name + '-redis-secret-sync';
      local sourceRoleName = serviceAccountName + '-source';
      [
        serviceAccount(name, serviceAccountName),
        sourceRole(cfg.sourceNamespace, sourceRoleName),
        roleBinding(name, cfg.sourceNamespace, sourceRoleName, serviceAccountName),
        targetRole(name, serviceAccountName, manageRedisProvider(cfg)),
        roleBinding(name, name, serviceAccountName, serviceAccountName),
        managedResource(name, redisProvider),
      ]
    else [],
}

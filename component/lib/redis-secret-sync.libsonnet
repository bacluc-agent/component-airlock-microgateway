local kap = import 'lib/kapitan.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.airlock_microgateway;

local defaultConfig = std.get(params.default, 'redisSecretSync', {});

local instanceConfig(name) = std.get(params.instances[name], 'redisSecretSync', {});

local config(name) = std.mergePatch(
  defaultConfig,
  instanceConfig(name)
);

local updateRedisProvider(cfg) = cfg.updateRedisProvider;
local updateHost(cfg) = updateRedisProvider(cfg).host;
local updateUsername(cfg) = updateRedisProvider(cfg).username;
local manageRedisProvider(cfg) = updateHost(cfg) || updateUsername(cfg);

local baseRequiredKeys = [ 'REDIS_PASSWORD', 'ca.crt', 'tls.crt', 'tls.key' ];

local requiredKeys(cfg) =
  baseRequiredKeys + (
    if manageRedisProvider(cfg) then [ 'REDIS_HOST', 'REDIS_USERNAME' ] else []
  );

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
      data: { 'redis.password': 'REDIS_PASSWORD' } + (
        if manageRedisProvider(cfg) then {
          REDIS_HOST: 'REDIS_HOST',
          REDIS_USERNAME: 'REDIS_USERNAME',
        } else {}
      ),
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

local targetRole(name, roleName, manage) = {
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
    if manage then [
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
  keys: std.manifestJson('Secret %s in namespace %s must contain keys %s' % [ source.name, cfg.sourceNamespace, std.join(', ', requiredKeys(cfg)) ]),
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

local targetNames(cfg) = [ target.name for target in targets(cfg) ];

local providerAnnotations(cfg) =
  local pointers = (
    if updateHost(cfg) then [ '/spec/mode/standalone/host' ] else []
  ) + (
    if updateUsername(cfg) then [ '/spec/auth/username' ] else []
  );
  if std.get(cfg, 'enabled', false) && std.length(entries(cfg)) > 0 && std.length(pointers) > 0 then {
    'argocd.argoproj.io/ignore-differences': 'jsonPointers:\n%s' % std.join('\n', [
      '- %s' % pointer
      for pointer in pointers
    ]),
  } else {};

local redisProviderName(redisProvider) =
  std.get(std.get(redisProvider, 'metadata', {}), 'name', '');

local redisProviderApiVersion(redisProvider) =
  std.get(redisProvider, 'apiVersion', 'microgateway.airlock.com/v1alpha1');

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
  local requiredKeys = %(requiredKeys)s;
  %(sources)s
  [
  %(secrets)s
  ]%(redisProvider)s
||| % {
  managedBy: '%s.redis-secret-sync' % name,
  requiredKeys: std.manifestJson(requiredKeys(cfg)),
  sources: std.join('\n', [
    sourceSecret(cfg, source)
    for source in sourceRefs(cfg)
  ]),
  secrets: std.join('', [
    secret(cfg, target, name)
    for target in targets(cfg)
  ]),
  redisProvider: if manageRedisProvider(cfg) then
    '\n  + (if std.length(context.redis_provider) == 1 && std.length(context.redis_provider_secret) == 1 then [\n%s\n  ] else [])' % redisProviderPatch(cfg, name, redisProvider)
  else '',
};

local validRedisProvider(name, redisProvider) =
  local cfg = config(name);
  assert !manageRedisProvider(cfg) || redisProviderName(redisProvider) != '' : 'redisSecretSync requires the RedisProvider to have a name';
  assert !manageRedisProvider(cfg) || redisProviderAuthSecretName(redisProvider) != '' : 'redisSecretSync requires the RedisProvider to set spec.auth.password.secretRef.name';
  true;

local managedResource(name, redisProvider) =
  local cfg = config(name);
  local serviceAccountName = name + '-redis-secret-sync';
  local sources = sourceRefs(cfg);
  local authSecretName = redisProviderAuthSecretName(redisProvider);
  local syncsProviderSecret = std.member(targetNames(cfg), authSecretName);
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
      labels: {
        'app.kubernetes.io/name': 'redis-secret-sync',
        'app.kubernetes.io/part-of': 'airlock-microgateway',
      },
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

{
  redisProviderAnnotations(name): providerAnnotations(config(name)),
  resources(name, redisProvider):
    local cfg = config(name);
    local enabled = std.get(cfg, 'enabled', false);
    if enabled && std.length(entries(cfg)) > 0 && validRedisProvider(name, redisProvider) then
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

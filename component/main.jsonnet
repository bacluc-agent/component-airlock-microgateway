// main template for airlock-microgateway
local kube = import 'kube-ssa-compat.libsonnet';
local gw = import 'lib/airlock-microgateway-operator.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';

local inv = kap.inventory();

// The hiera parameters for the component
local params = inv.parameters.airlock_microgateway;
local has_cilium = std.member(inv.applications, 'cilium');

local metadataNamespace(name) = {
  metadata: {
    namespace: name,
  },
};

local has(obj, field) = std.objectHas(obj, field) && obj[field] != null;

// main template for airlock-microgateway
local httpRoute(name='') = {
  apiVersion: 'gateway.networking.k8s.io/v1',
  kind: 'HTTPRoute',
  metadata: {
    namespace: name,
    name: name,
  },
  spec: {},
};

local pdb(name='') = {
  apiVersion: 'policy/v1',
  kind: 'PodDisruptionBudget',
  metadata: {
    namespace: name,
    name: name,
    labels: {
      'gateway.networking.k8s.io/gateway-name': name,
    },
  },
};

local egressNetpol(name='') = {
  apiVersion: 'networking.k8s.io/v1',
  kind: 'NetworkPolicy',
  metadata: {
    namespace: name,
    name: name,
  },
};

local namespaces = {
  ['%s/Namespace' % instance.key]: kube.Namespace(instance.key) {
    metadata+: {
      labels+: { 'openshift.io/cluster-monitoring': 'true' },
    },
  } + {
    metadata+: {
      labels+: com.makeMergeable(params.default.namespace.labels),
      annotations: com.makeMergeable(params.default.namespace.annotations),
    },
  }
  for instance in std.objectKeysValues(params.instances)
};

local CiliumNetworkPolicy(name) = {
  apiVersion: 'cilium.io/v2',
  kind: 'CiliumNetworkPolicy',
  metadata: {
    name: name,
  },
};

local GatewayCNPEgress(name) =
  CiliumNetworkPolicy(name) {
    metadata: {
      name: 'internal-dns-egress',
      namespace: name,
    },
    spec: {
      endpointSelector: {
        matchLabels: {
          'gateway.networking.k8s.io/gateway-name': name,
          'microgateway.airlock.com/managedBy': params.operatorNamespace,
        },
      },
      egress: [
        {
          toEndpoints: [
            {
              matchLabels: {
                'dns.operator.openshift.io/daemonset-dns': 'default',
                'k8s:io.kubernetes.pod.namespace': 'openshift-dns',
              },
            },
          ],
          toPorts: [
            {
              ports: [
                {
                  port: '5353',
                  protocol: 'UDP',
                },
              ],
              rules: {
                dns: [
                  {
                    matchPattern: '*',
                  },
                ],
              },
            },
          ],
        },
      ],
    },
  };

local GatewayCNPIngress(name) =
  CiliumNetworkPolicy(name) {
    metadata: {
      name: 'allow-ingress-world',
      namespace: name,
    },
    spec: {
      endpointSelector: {
        matchLabels: {
          'gateway.networking.k8s.io/gateway-name': name,
          'microgateway.airlock.com/managedBy': params.operatorNamespace,
        },
      },
      ingress: [
        {
          fromEntities: [ 'world' ],
        },
      ],
    },
  };

local toFiles(objects) = {
  ['%s/%s-%s' % [ object.metadata.namespace, object.kind, object.metadata.name ]]: object
  for object in objects
};

// The final name of a resource, derived from the instance name unless the
// user overrides metadata.name in the instance parameters.
local resourceName(field, name) =
  if has(params.instances[name], field)
     && has(params.instances[name][field], 'metadata')
     && has(params.instances[name][field].metadata, 'name')
  then params.instances[name][field].metadata.name
  else kube.hyphenate(name);

// Cross-references derived from the instance name, injected between the
// default and instance parameters so explicit user overrides still win.
local derivedRefs(field, name) =
  local gatewayName = kube.hyphenate(name);
  if field == 'gateway' then {
    spec: {
      infrastructure: {
        parametersRef: {
          name: resourceName('gatewayParameters', name),
        },
      },
    },
  } else if field == 'gatewayParameters' then {
    spec: {
      defaults: {
        sessionHandlingRef: {
          name: resourceName('sessionHandling', name),
        },
      },
    },
  } else if field == 'sessionHandling' then {
    spec: {
      persistence: {
        redisProviderRef: {
          name: resourceName('redisProvider', name),
        },
      },
    },
  } else if field == 'egressNetpol' then {
    spec: {
      podSelector: {
        matchLabels: {
          'gateway.networking.k8s.io/gateway-name': gatewayName,
        },
      },
    },
  } else {};

// Fill in the derived Gateway name for each parentRef that doesn't set one.
local withGatewayRefs(route, gatewayName) =
  if has(route, 'spec') && has(route.spec, 'parentRefs') then
    route {
      spec+: {
        parentRefs: [
          ref + (if has(ref, 'name') then {} else { name: gatewayName })
          for ref in route.spec.parentRefs
        ],
      },
    }
  else
    route;

// Generate a single resource of the given type for one instance.
// The generator output is merged with the default parameters, the derived
// cross-references and the instance-specific parameters, in that order.
local resource(field, generator, name) =
  std.mergePatch(
    std.mergePatch(
      generator(kube.hyphenate(name)) + com.makeMergeable(
        if has(params.default, field)
        then std.mergePatch(params.default[field], metadataNamespace(name))
        else metadataNamespace(name)
      ),
      derivedRefs(field, name)
    ),
    if has(params.instances[name], field) then params.instances[name][field] else {}
  );

// Instance-independent resources
local monitoringResources = import 'monitoring.jsonnet';

// All per-instance resources, generated in an instance-outer loop
local instanceResources = std.flatMap(
  function(instance)
    [
      resource('gateway', gw.Gateway, instance.key),
      resource('gatewayParameters', gw.GatewayParameters, instance.key),
      withGatewayRefs(resource('httpRedirect', httpRoute, instance.key), kube.hyphenate(instance.key)),
      resource('pdb', pdb, instance.key),
      resource('egressNetpol', egressNetpol, instance.key),
      resource('sessionHandling', gw.SessionHandling, instance.key),
      resource('redisProvider', gw.RedisProvider, instance.key),
    ] + if has_cilium then [
      GatewayCNPIngress(instance.key),
      GatewayCNPEgress(instance.key),
    ] else [],
  std.objectKeysValues(params.instances)
);

// Define outputs below
toFiles(instanceResources) +
namespaces
+ monitoringResources
+ (import 'custom-responses.jsonnet')
+ (import 'lib/debug.jsonnet')

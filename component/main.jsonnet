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

// The final name of a resource, derived from the instance name unless the
// user overrides metadata.name in the instance parameters.
local resourceName(field, name) =
  if has(params.instances[name], field)
     && has(params.instances[name][field], 'metadata')
     && has(params.instances[name][field].metadata, 'name')
  then params.instances[name][field].metadata.name
  else if has(params.default, field)
          && has(params.default[field], 'metadata')
          && has(params.default[field].metadata, 'name')
  then params.default[field].metadata.name
  else kube.hyphenate(name);

local CiliumNetworkPolicy(name) = {
  apiVersion: 'cilium.io/v2',
  kind: 'CiliumNetworkPolicy',
  metadata: {
    name: name,
  },
};

local GatewayCNPEgress(namespace, gatewayName) =
  CiliumNetworkPolicy(namespace) {
    metadata: {
      name: 'internal-dns-egress',
      namespace: namespace,
    },
    spec: {
      endpointSelector: {
        matchLabels: {
          'gateway.networking.k8s.io/gateway-name': gatewayName,
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

local GatewayCNPIngress(namespace, gatewayName) =
  CiliumNetworkPolicy(namespace) {
    metadata: {
      name: 'allow-ingress-world',
      namespace: namespace,
    },
    spec: {
      endpointSelector: {
        matchLabels: {
          'gateway.networking.k8s.io/gateway-name': gatewayName,
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
// Merges generator output, default parameters plus namespace, the explicit
// derived refs object, then instance parameters, in that order.
local buildResource(name, field, generator, derived={}) =
  std.mergePatch(
    std.mergePatch(
      generator(kube.hyphenate(name)) + com.makeMergeable(
        if has(params.default, field)
        then std.mergePatch(params.default[field], metadataNamespace(name))
        else metadataNamespace(name)
      ),
      derived
    ),
    if has(params.instances[name], field) then params.instances[name][field] else {}
  );

local gateway(name) = buildResource(name, 'gateway', gw.Gateway, {
  spec: { infrastructure: { parametersRef: {
    group: 'microgateway.airlock.com',
    kind: 'GatewayParameters',
    name: resourceName('gatewayParameters', name),
  } } },
});

local gatewayParameters(name) = buildResource(name, 'gatewayParameters', gw.GatewayParameters, {
  spec: { defaults: { sessionHandlingRef: {
    name: resourceName('sessionHandling', name),
  } } },
});

local httpRedirect(name) = withGatewayRefs(
  buildResource(name, 'httpRedirect', httpRoute),
  resourceName('gateway', name)
);

local pdbResource(name) = buildResource(name, 'pdb', pdb);

local egressNetpolResource(name) = buildResource(name, 'egressNetpol', egressNetpol, {
  spec: { podSelector: { matchLabels: {
    'gateway.networking.k8s.io/gateway-name': resourceName('gateway', name),
  } } },
});

local sessionHandling(name) = buildResource(name, 'sessionHandling', gw.SessionHandling, {
  spec: { persistence: { redisProviderRef: {
    name: resourceName('redisProvider', name),
  } } },
});

local redisProvider(name) = buildResource(name, 'redisProvider', gw.RedisProvider);

// All per-instance resources, generated in an instance-outer loop
local instanceResources = std.flatMap(
  function(instance)
    [
      gateway(instance.key),
      gatewayParameters(instance.key),
      httpRedirect(instance.key),
      pdbResource(instance.key),
      egressNetpolResource(instance.key),
      sessionHandling(instance.key),
      redisProvider(instance.key),
    ] + if has_cilium then [
      GatewayCNPIngress(instance.key, resourceName('gateway', instance.key)),
      GatewayCNPEgress(instance.key, resourceName('gateway', instance.key)),
    ] else [],
  std.objectKeysValues(params.instances)
);

// Define outputs below
toFiles(instanceResources) +
namespaces
// monitoring.jsonnet emits its own manifests and is instance-independent (singleton).
+ (import 'monitoring.jsonnet')
+ (import 'custom-responses.jsonnet')
+ (import 'lib/debug.jsonnet')
